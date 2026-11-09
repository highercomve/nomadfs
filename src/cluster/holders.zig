//! Who probably holds what. Learned only inside traffic already flowing:
//! fs/ says with `noteKeeps` that a device keeps copies of a folder owner's
//! folders (it saw the owner's SHARES reply say so), and each peer's
//! announced roles (PING/PONG) are recorded by discovery. Readers ask
//! `forOrigin` / `forSwarm` for the list of likely holders and hand it to
//! the fetcher, which picks a source per block.
//!
//! Nothing here announces or asks: no new messages, and the tables are
//! bounded (a personal swarm is a handful of devices).

const std = @import("std");
const sync = @import("../sync.zig");
const NodeID = @import("../net/id.zig").NodeID;
const rpc = @import("../net/discovery/rpc.zig");
const fetcher = @import("fetcher.zig");

/// Entries in the keep table; the note replacing the least recent one
/// makes room past this.
pub const max_keeps = 256;
/// An entry nobody re-noted for this long is stale: skipped by the
/// readers and dropped when the table fills (seven days).
pub const keep_ttl_ms: i64 = 7 * std.time.ms_per_day;
/// Peers considered per forSwarm call (the personal-swarm scale; the
/// fetcher list is far shorter).
pub const max_known = 64;

pub const Holders = struct {
    mutex: sync.Mutex = .{},
    keeps: [max_keeps]Keep = undefined,
    keep_count: usize = 0,
    /// This node's own transport ID: never listed as a holder of anything.
    self_id: NodeID = NodeID{ .bytes = [_]u8{0} ** 32 },
    /// Where a peer's roles and the known peers come from (discovery).
    /// Null: only noted keepers count.
    peers: ?Peers = null,
    /// Clock, dodged in tests.
    clock: *const fn () i64 = sync.monotonicMillis,

    /// A peer's announced roles and the peers known, from the discovery
    /// node. Type-erased so the registry stays free of networking types.
    pub const Peers = struct {
        ctx: *anyopaque,
        /// The roles a peer announced last, or null when unknown.
        rolesFn: *const fn (ctx: *anyopaque, peer: NodeID) ?u8,
        /// Copies known peer IDs into `out`; returns how many.
        knownFn: *const fn (ctx: *anyopaque, out: []NodeID) usize,
        /// Copies the IDs of peers with a live connection (direct or
        /// relayed) into `out`; returns how many. Null: none known. This
        /// includes relay peers absent from the routing table.
        connectedFn: ?*const fn (ctx: *anyopaque, out: []NodeID) usize = null,
        /// Includes role announcements from peers currently disconnected.
        withRoleFn: ?*const fn (ctx: *anyopaque, bit: u8, out: []NodeID) usize = null,
        /// Whether `peer` is connected right now (not just remembered).
        knowsFn: ?*const fn (ctx: *anyopaque, peer: NodeID) bool = null,
    };

    /// `holder` keeps copies of `origin`'s folders (re-noting refreshes).
    /// Errors are never propagated: an unrecorded copy only costs a read
    /// a round trip, not correctness.
    pub fn noteKeeps(self: *Holders, holder: NodeID, origin: NodeID) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        const now = self.clock();
        for (self.keeps[0..self.keep_count]) |*e| {
            if (e.holder.eql(holder) and e.origin.eql(origin)) {
                e.last_seen = now;
                return;
            }
        }
        if (self.keep_count < max_keeps) {
            self.keeps[self.keep_count] = .{ .holder = holder, .origin = origin, .last_seen = now };
            self.keep_count += 1;
            return;
        }
        // Full: stale entries go, then the one seen longest ago.
        var n: usize = 0;
        for (self.keeps[0..self.keep_count]) |e| {
            if (now - e.last_seen < keep_ttl_ms) {
                self.keeps[n] = e;
                n += 1;
            }
        }
        self.keep_count = n;
        const victim = self.oldestLocked();
        self.keeps[victim] = .{ .holder = holder, .origin = origin, .last_seen = now };
    }

    /// Drops a peer entirely, as holder or as origin (its copies and its
    /// folders): after it was revoked, say.
    pub fn forget(self: *Holders, peer: NodeID) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        var n: usize = 0;
        for (self.keeps[0..self.keep_count]) |e| {
            if (e.holder.eql(peer) or e.origin.eql(peer)) continue;
            self.keeps[n] = e;
            n += 1;
        }
        self.keep_count = n;
    }

    /// Likely holders of a shared folder's files: `origin` first (the
    /// device sharing them), then the devices noted as keeping copies of
    /// its folders. The result excludes this node, is bounded to
    /// `fetcher.max_holders`, and lives in the caller's buffer.
    pub fn forOrigin(self: *Holders, origin: NodeID, out: *[fetcher.max_holders]NodeID) []NodeID {
        self.mutex.lock();
        defer self.mutex.unlock();
        const now = self.clock();
        var n: usize = 0;
        if (!origin.eql(self.self_id)) {
            out[0] = origin;
            n = 1;
        }
        for (self.keeps[0..self.keep_count]) |e| {
            if (n >= out.len) break;
            if (!e.origin.eql(origin)) continue;
            if (now - e.last_seen >= keep_ttl_ms) continue;
            if (e.holder.eql(self.self_id) or e.holder.eql(origin)) continue;
            if (contains(out[0..n], e.holder)) continue;
            out[n] = e.holder;
            n += 1;
        }
        return out[0..n];
    }

    /// Likely holders of a swarm file: the author first, then the peers
    /// whose roles say they keep swarm backups, then the rest of the known
    /// peers, so no read ever has fewer sources than before the registry
    /// existed. Within each group the peers connected right now come first
    /// and peers on a metered network last, so a cap of
    /// `fetcher.max_holders` drops stale peers, not the reachable backup.
    /// Connected peers missing from the known list (reached through a
    /// relay) and disconnected announced backups count as known.
    /// The result excludes this node, is bounded to
    /// `fetcher.max_holders`, and lives in the caller's buffer.
    pub fn forSwarm(self: *Holders, author: NodeID, out: *[fetcher.max_holders]NodeID) []NodeID {
        return self.forSwarmSplit(author, out).ids;
    }

    pub const SwarmHints = struct { ids: []NodeID, backups_end: usize };

    /// The boundary lets fs insert placement replicas after backups.
    pub fn forSwarmSplit(self: *Holders, author: NodeID, out: *[fetcher.max_holders]NodeID) SwarmHints {
        self.mutex.lock();
        defer self.mutex.unlock();
        const peers = self.peers orelse {
            const ids = self.swarmWithoutKnown(author, out);
            return .{ .ids = ids, .backups_end = ids.len };
        };

        // The connected peers first, so a full routing table can't crowd
        // out a device reached only through a relay; then the table.
        var connected: [max_known]NodeID = undefined;
        const connected_count = if (peers.connectedFn) |f| f(peers.ctx, &connected) else 0;
        const live = connected[0..connected_count];
        var known: [max_known]NodeID = undefined;
        @memcpy(known[0..connected_count], live);
        // The table after them, then compacted in place without the
        // connected ones it lists too. With a table larger than what is
        // left, a connected peer it also lists takes the slot of one more
        // table entry (accepted: only past max_known peers, and the
        // connected peers are the ones a read can use now).
        const routing_count = peers.knownFn(peers.ctx, known[connected_count..]);
        var count = connected_count;
        for (connected_count..connected_count + routing_count) |i| {
            if (contains(live, known[i])) continue;
            known[count] = known[i];
            count += 1;
        }

        var n: usize = 0;
        if (!author.eql(self.self_id)) {
            out[0] = author;
            n = 1;
        }
        // Swarm backup devices: they keep every file.
        self.appendBackups(out, &n, known[0..count], live);
        const backups_end = n;
        // Everyone else: sources in reserve.
        var rest: [max_known]NodeID = undefined;
        var m: usize = 0;
        for (known[0..count]) |p| {
            const roles = peers.rolesFn(peers.ctx, p);
            if (roles == null or roles.? & rpc.Roles.swarm_backup == 0) {
                rest[m] = p;
                m += 1;
            }
        }
        self.appendGroup(out, &n, rest[0..m], live);
        return .{ .ids = out[0..n], .backups_end = backups_end };
    }

    fn appendBackups(self: *Holders, out: *[fetcher.max_holders]NodeID, n: *usize, known: []const NodeID, live: []const NodeID) void {
        const peers = self.peers.?;
        var backup: [max_known]NodeID = undefined;
        var count: usize = 0;
        // Keep connected backups ahead of older role-only announcements
        // even when the bounded role list fills up.
        for (known) |peer| {
            if (count == backup.len) break;
            if (contains(backup[0..count], peer)) continue;
            const roles = peers.rolesFn(peers.ctx, peer) orelse continue;
            if (roles & rpc.Roles.swarm_backup == 0) continue;
            backup[count] = peer;
            count += 1;
        }
        if (peers.withRoleFn) |f| {
            var announced: [max_known]NodeID = undefined;
            const copied = f(peers.ctx, rpc.Roles.swarm_backup, &announced);
            for (announced[0..copied]) |peer| {
                if (count == backup.len) break;
                if (contains(backup[0..count], peer)) continue;
                backup[count] = peer;
                count += 1;
            }
        }
        self.appendGroup(out, n, backup[0..count], live);
    }

    /// Whether `peer` is connected right now, without looking it up or
    /// dialing it. (Remembered IDs don't count: an ID from before a re-join
    /// can linger in routing tables.)
    pub fn knowsPeer(self: *Holders, peer: NodeID) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        const peers = self.peers orelse return false;
        if (peers.knowsFn) |f| return f(peers.ctx, peer);
        var ids: [max_known]NodeID = undefined;
        const f = peers.connectedFn orelse return false;
        return contains(ids[0..f(peers.ctx, &ids)], peer);
    }

    /// forSwarm without a discovery source: the author alone.
    fn swarmWithoutKnown(self: *Holders, author: NodeID, out: *[fetcher.max_holders]NodeID) []NodeID {
        if (author.eql(self.self_id)) return out[0..0];
        out[0] = author;
        return out[0..1];
    }

    /// Appends `group` to `out` (deduplicated against what is listed
    /// already), in four ranks, each in the group's order: connected and
    /// not metered, not connected and not metered, connected and metered,
    /// the rest. `live` lists the connected peers. Each peer's roles are
    /// looked up once.
    fn appendGroup(self: *Holders, out: *[fetcher.max_holders]NodeID, n: *usize, group: []const NodeID, live: []const NodeID) void {
        std.debug.assert(group.len <= max_known);
        const peers = self.peers.?;
        var ranks: [max_known]u2 = undefined;
        for (group, ranks[0..group.len]) |peer, *r| {
            const roles = peers.rolesFn(peers.ctx, peer);
            const metered = roles != null and roles.? & rpc.Roles.metered != 0;
            r.* = @as(u2, if (metered) 2 else 0) + @as(u2, if (contains(live, peer)) 0 else 1);
        }
        for (0..4) |rank| {
            for (group, ranks[0..group.len]) |peer, r| {
                if (n.* >= out.len) return;
                if (r != rank) continue;
                if (peer.eql(self.self_id)) continue;
                if (contains(out[0..n.*], peer)) continue;
                out[n.*] = peer;
                n.* += 1;
            }
        }
    }

    fn contains(list: []const NodeID, id: NodeID) bool {
        for (list) |x| {
            if (x.eql(id)) return true;
        }
        return false;
    }

    fn oldestLocked(self: *Holders) usize {
        var victim: usize = 0;
        for (self.keeps[0..self.keep_count], 0..) |e, i| {
            if (e.last_seen < self.keeps[victim].last_seen) victim = i;
        }
        return victim;
    }
};

const Keep = struct {
    /// Keeps copies of `origin`'s folders.
    holder: NodeID,
    origin: NodeID,
    last_seen: i64,
};

// ---- Tests ----

const testing = std.testing;

fn idOf(b: u32) NodeID {
    var bytes = [_]u8{0} ** 32;
    bytes[0] = @truncate(b);
    bytes[1] = @truncate(b >> 8);
    return .{ .bytes = bytes };
}

const Self = [_]u8{0xEE} ** 32;

fn table(self_id: NodeID) Holders {
    return .{ .self_id = self_id };
}

/// A peering source whose known peers and roles the test controls; roles
/// looked up by the peer's first byte.
var stub_known: [8]NodeID = [_]NodeID{idOf(0)} ** 8;
var stub_roles: [8]u8 = [_]u8{0} ** 8;

fn stubRoles(ctx: *anyopaque, peer: NodeID) ?u8 {
    _ = ctx;
    for (stub_known, stub_roles) |k, r| if (k.eql(peer)) return r;
    return null;
}

fn stubKnown(ctx: *anyopaque, out: []NodeID) usize {
    _ = ctx;
    const n = @min(out.len, stub_known.len);
    @memcpy(out[0..n], stub_known[0..n]);
    return n;
}

fn stubPeers() Holders.Peers {
    return .{ .ctx = undefined, .rolesFn = stubRoles, .knownFn = stubKnown };
}

var fake_ms: i64 = 0;
/// Extra ms every fakeClock call adds; set high to simulate entries
/// ageing between notes, 0 to keep queries at a frozen instant.
var fake_step_ms: i64 = 0;
fn fakeClock() i64 {
    fake_ms += fake_step_ms;
    return fake_ms;
}

test "holders: forOrigin lists the origin, then the noted keepers, bounded" {
    var t = table(.{ .bytes = Self });
    var out: [fetcher.max_holders]NodeID = [_]NodeID{idOf(0xFF)} ** fetcher.max_holders;
    // With nothing noted, the sharing device alone is the holder.
    try testing.expectEqualSlices(NodeID, &.{idOf(1)}, t.forOrigin(idOf(1), &out));
    t.noteKeeps(idOf(2), idOf(1));
    t.noteKeeps(idOf(3), idOf(1));
    const holders_list = t.forOrigin(idOf(1), &out);
    try testing.expectEqual(@as(usize, 3), holders_list.len);
    try testing.expect(idOf(1).eql(holders_list[0]));
    try testing.expect(idOf(2).eql(holders_list[1]));
    try testing.expect(idOf(3).eql(holders_list[2]));

    // Other origins' keepers don't leak into this list.
    t.noteKeeps(idOf(4), idOf(5));
    try testing.expectEqual(@as(usize, 3), t.forOrigin(idOf(1), &out).len);
    // And the origin's own note (it keeps itself) is not a duplicate.
    t.noteKeeps(idOf(1), idOf(1));
    try testing.expectEqual(@as(usize, 3), t.forOrigin(idOf(1), &out).len);

    // One list for too many keepers: the origin plus the seven oldest
    // still fit; an eighth keeper is left out.
    var i: u8 = 6;
    while (i < 8 + 6) : (i += 1) t.noteKeeps(idOf(i), idOf(1));
    const bounded = t.forOrigin(idOf(1), &out);
    try testing.expectEqual(@as(usize, fetcher.max_holders), bounded.len);
    for (bounded[1..]) |_| {}
}

test "holders: re-noting refreshes, stale entries are skipped, and forgetting removes both directions" {
    fake_step_ms = 0;
    fake_ms = 0;
    var t = table(.{ .bytes = Self });
    t.clock = fakeClock;

    t.noteKeeps(idOf(2), idOf(1));
    // Far enough later that the first note is stale beyond the ttl, and
    // a note made now (3) is fresh.
    fake_ms += keep_ttl_ms + 1;
    t.noteKeeps(idOf(3), idOf(1));
    var out: [fetcher.max_holders]NodeID = undefined;
    try testing.expectEqualSlices(NodeID, &.{ idOf(1), idOf(3) }, t.forOrigin(idOf(1), &out));

    // forget drops the peer as holder and as origin.
    t.noteKeeps(idOf(5), idOf(3));
    t.forget(idOf(3));
    try testing.expectEqualSlices(NodeID, &.{idOf(1)}, t.forOrigin(idOf(1), &out));
    try testing.expectEqualSlices(NodeID, &.{idOf(3)}, t.forOrigin(idOf(3), &out));
}

test "holders: the keep table is bounded by replacement, not growth" {
    var t = table(.{ .bytes = Self });
    t.clock = fakeClock;
    fake_step_ms = 1;
    var n: u32 = 0;
    while (n < max_keeps + 4) : (n += 1) {
        t.noteKeeps(idOf(@intCast(n)), idOf(200));
    }
    fake_step_ms = 0;
    t.mutex.lock();
    defer t.mutex.unlock();
    try testing.expectEqual(@as(usize, max_keeps), t.keep_count);
    // The freshest notes survived; the four oldest were pushed out.
    try testing.expect(!keptHolder(&t, idOf(0)));
    try testing.expect(keptHolder(&t, idOf(@intCast(max_keeps))));
}

fn keptHolder(self: *Holders, holder: NodeID) bool {
    for (self.keeps[0..self.keep_count]) |e| if (e.holder.eql(holder)) return true;
    return false;
}

test "holders: forSwarm orders author, swarm backup peers, then the rest, metered last, without itself" {
    stub_known = .{ idOf(1), idOf(2), idOf(3), idOf(4), idOf(0), idOf(0), idOf(0), idOf(0) };
    stub_roles = .{
        rpc.Roles.metered, // 1: a phone
        rpc.Roles.swarm_backup, // 2: home server
        rpc.Roles.swarm_backup | rpc.Roles.metered, // 3: phone backing up
        0, // 4: plain
        0,
        0,
        0,
        0,
    };
    var t = table(idOf(0)); // only another node counts
    t.peers = stubPeers();

    var out: [fetcher.max_holders]NodeID = undefined;
    const swarm_list = t.forSwarm(idOf(9), &out);
    try testing.expectEqualSlices(NodeID, &.{ idOf(9), idOf(2), idOf(3), idOf(4), idOf(1) }, swarm_list);
    // The author is never listed twice, nor is this node ever listed.
    const self_list = t.forSwarm(idOf(0), &out);
    try testing.expectEqualSlices(NodeID, &.{ idOf(2), idOf(3), idOf(4), idOf(1) }, self_list);

    // Without a discovery source only the author remains.
    var t2 = table(idOf(0));
    const lone = t2.forSwarm(idOf(9), &out);
    try testing.expectEqualSlices(NodeID, &.{idOf(9)}, lone);
    try testing.expectEqual(@as(usize, 0), t2.forSwarm(idOf(0), &out).len);
}

/// A source with a full routing table of stale peers (ids 100..163, no
/// roles), and connected peers the test sets.
const FullTable = struct {
    var connected: [4]NodeID = undefined;
    var connected_count: usize = 0;
    var backup: NodeID = undefined;

    fn roles(_: *anyopaque, peer: NodeID) ?u8 {
        return if (peer.eql(backup)) rpc.Roles.swarm_backup else null;
    }
    fn known(_: *anyopaque, out: []NodeID) usize {
        const n = @min(out.len, max_known);
        for (out[0..n], 0..) |*o, i| o.* = idOf(@intCast(100 + i));
        return n;
    }
    fn live(_: *anyopaque, out: []NodeID) usize {
        const n = @min(out.len, connected_count);
        @memcpy(out[0..n], connected[0..n]);
        return n;
    }
    fn source() Holders.Peers {
        return .{ .ctx = undefined, .rolesFn = roles, .knownFn = known, .connectedFn = live };
    }
};

test "holders: forSwarm lists a peer reached only through a relay, even with a full routing table" {
    var t = table(idOf(0));
    t.peers = FullTable.source();
    var out: [fetcher.max_holders]NodeID = undefined;

    // Not connected and not in the table: not listed; stale peers fill the cap.
    FullTable.connected_count = 0;
    FullTable.backup = idOf(7);
    const before = t.forSwarm(idOf(9), &out);
    try testing.expectEqual(@as(usize, fetcher.max_holders), before.len);
    for (before) |p| try testing.expect(!p.eql(idOf(7)));

    // Connected through a relay (so in no table): listed right after the
    // author, ahead of the 64 stale peers, as a swarm backup.
    FullTable.connected = .{ idOf(7), idOf(0), idOf(0), idOf(0) };
    FullTable.connected_count = 1;
    const after = t.forSwarm(idOf(9), &out);
    try testing.expectEqual(idOf(9), after[0]);
    try testing.expectEqual(idOf(7), after[1]);

    // A connected peer without roles leads the rest, ahead of stale ones.
    FullTable.backup = idOf(250);
    FullTable.connected = .{ idOf(7), idOf(120), idOf(0), idOf(0) };
    FullTable.connected_count = 2;
    const ranked = t.forSwarm(idOf(9), &out);
    try testing.expectEqualSlices(NodeID, &.{ idOf(9), idOf(7), idOf(120), idOf(100), idOf(101), idOf(102), idOf(103), idOf(104) }, ranked);
}

test "holders: announced relay backup stays listed while disconnected" {
    const Roles = struct {
        fn copy(_: *anyopaque, bit: u8, out: []NodeID) usize {
            if (out.len == 0 or bit != rpc.Roles.swarm_backup) return 0;
            out[0] = idOf(7);
            return 1;
        }
    };
    FullTable.connected_count = 0;
    FullTable.backup = idOf(7);
    var t = table(idOf(0));
    var peers = FullTable.source();
    peers.withRoleFn = Roles.copy;
    t.peers = peers;
    var out: [fetcher.max_holders]NodeID = undefined;
    const split = t.forSwarmSplit(idOf(9), &out);
    try testing.expectEqualSlices(NodeID, &.{ idOf(9), idOf(7) }, split.ids[0..split.backups_end]);
    try testing.expectEqual(@as(usize, fetcher.max_holders), split.ids.len);
    try testing.expect(!t.knowsPeer(idOf(7)));
    // Remembered in the routing table but not connected: not "known".
    try testing.expect(!t.knowsPeer(idOf(100)));
    FullTable.connected = .{ idOf(100), idOf(0), idOf(0), idOf(0) };
    FullTable.connected_count = 1;
    try testing.expect(t.knowsPeer(idOf(100)));
    FullTable.connected_count = 0;
}
