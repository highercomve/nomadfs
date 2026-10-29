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
    /// existed. Within each group, peers on a metered network come last.
    /// The result excludes this node, is bounded to `fetcher.max_holders`,
    /// and lives in the caller's buffer.
    pub fn forSwarm(self: *Holders, author: NodeID, out: *[fetcher.max_holders]NodeID) []NodeID {
        self.mutex.lock();
        defer self.mutex.unlock();
        const peers = self.peers orelse return self.swarmWithoutKnown(author, out);

        var known: [max_known]NodeID = undefined;
        const count = peers.knownFn(peers.ctx, &known);

        var n: usize = 0;
        if (!author.eql(self.self_id)) {
            out[0] = author;
            n = 1;
        }
        // Swarm backup devices: they keep every file.
        backuppeers: {
            var backup: [max_known]NodeID = undefined;
            var m: usize = 0;
            for (known[0..count]) |p| {
                const roles = peers.rolesFn(peers.ctx, p) orelse continue;
                if (roles & rpc.Roles.swarm_backup != 0) {
                    backup[m] = p;
                    m += 1;
                }
            }
            self.appendGroup(out, &n, backup[0..m]);
            break :backuppeers;
        }
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
        self.appendGroup(out, &n, rest[0..m]);
        return out[0..n];
    }

    /// forSwarm without a discovery source: the author alone.
    fn swarmWithoutKnown(self: *Holders, author: NodeID, out: *[fetcher.max_holders]NodeID) []NodeID {
        if (author.eql(self.self_id)) return out[0..0];
        out[0] = author;
        return out[0..1];
    }

    /// Appends `group` to `out` (deduplicated against what is listed
    /// already), the peers not on a metered network first.
    fn appendGroup(self: *Holders, out: *[fetcher.max_holders]NodeID, n: *usize, group: []NodeID) void {
        const peers = self.peers.?;
        // Partition in place: non-metered first, metered behind.
        var head: usize = 0;
        var tail: usize = group.len;
        while (head < tail) {
            const roles = peers.rolesFn(peers.ctx, group[head]);
            const metered = roles != null and roles.? & rpc.Roles.metered != 0;
            if (metered) {
                tail -= 1;
                std.mem.swap(NodeID, &group[head], &group[tail]);
            } else {
                head += 1;
            }
        }
        for (0..2) |round| {
            const part = if (round == 0) group[0..head] else group[head..];
            for (part) |peer| {
                if (n.* >= out.len) return;
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
