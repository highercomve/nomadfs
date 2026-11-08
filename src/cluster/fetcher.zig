//! Where each block comes from. A read hands the fetcher the block it needs,
//! the file's root and the devices that may hold it (hints from fs/, later
//! the holder registry); the fetcher picks the holder expected to answer
//! first: least `(requests in flight + 1) / measured rate`. Callers that
//! fetch several blocks at once (read-ahead's workers) so spread across
//! holders by speed, with no message the read didn't need anyway.
//!
//! What it remembers, bounded:
//! - per device: its rate (leaf blocks only, EWMA), requests in flight, and
//!   when it may be tried again after failing to connect (backoff);
//! - misses: a device that answered "not found" for a block is skipped for
//!   that block for 30 s, and for the whole file after 3 misses in a row on
//!   it, for 60 s, so a device without the file costs a few round trips,
//!   not one per block.
//!
//! Devices in the routing table are dialed directly; one not met yet is
//! looked up through the DHT once, and backs off if it can't be reached.

const std = @import("std");
const sync = @import("../sync.zig");
const NodeID = @import("../net/id.zig").NodeID;
const storage = @import("../storage/mod.zig");

pub const Cid = [32]u8;
/// Most holders one read considers.
pub const max_holders = 8;
/// First byte of a leaf block (storage/dag/codec.zig Tag.leaf).
const leaf_tag: u8 = @intFromEnum(storage.dag.codec.Tag.leaf);

/// Dials a holder and fetches one block: the network side, supplied by the
/// BlockManager (and by tests). Returns null when the holder doesn't have it.
pub const Transport = struct {
    ctx: *anyopaque,
    /// Caller-owned bytes from `allocator`, or null for "not found".
    getFn: *const fn (ctx: *anyopaque, peer: NodeID, cid: *const Cid, allocator: std.mem.Allocator) anyerror!?[]u8,
    /// Whether a live connection to `peer` exists right now (direct or
    /// relayed). A connected device is asked even while backing off: the
    /// failure that started the backoff is over. Null: never assumed.
    /// Called with the fetcher's mutex held; it must not call back.
    connectedFn: ?*const fn (ctx: *anyopaque, peer: NodeID) bool = null,
};

pub const Fetcher = struct {
    store: *storage.engine.StorageEngine,
    transport: Transport,

    mutex: sync.Mutex = .{},
    peers: [max_peers]PeerState = undefined,
    peer_count: usize = 0,
    block_misses: [max_block_misses]Miss = undefined,
    block_miss_next: usize = 0,
    block_miss_count: usize = 0,
    root_misses: [max_root_misses]RootMiss = undefined,
    root_miss_count: usize = 0,
    /// Totals since start, for measuring.
    stats: Stats = .{},

    const max_peers = 64;
    const max_block_misses = 512;
    const max_root_misses = 128;
    pub const block_miss_ms: i64 = 30 * std.time.ms_per_s;
    pub const root_miss_ms: i64 = 60 * std.time.ms_per_s;
    /// Misses in a row on one file before the device is skipped for it.
    pub const root_miss_after: u8 = 3;
    /// Bytes per ms assumed for a device never measured: about 4 MB/s, so
    /// new holders get tried.
    const default_rate: u32 = 4096;
    const backoff_first_ms: i64 = 5 * std.time.ms_per_s;
    const backoff_max_ms: i64 = 60 * std.time.ms_per_s;

    pub const PeerState = struct {
        id: NodeID,
        /// EWMA of bytes per ms on leaf blocks; 0 = not measured yet.
        rate: u32 = 0,
        in_flight: u16 = 0,
        fails: u8 = 0,
        down_until: i64 = 0,
        last_used: i64 = 0,
        /// Blocks and bytes it served (for measuring).
        blocks: u64 = 0,
        bytes: u64 = 0,
    };

    const Miss = struct { peer: NodeID, cid: Cid, until: i64 };
    const RootMiss = struct { peer: NodeID, root: Cid, count: u8, until: i64 };

    pub const Stats = struct {
        local: u64 = 0,
        fetched: u64 = 0,
        fetched_bytes: u64 = 0,
        not_found: u64 = 0,
        failed: u64 = 0,
    };

    pub fn init(store: *storage.engine.StorageEngine, transport: Transport) Fetcher {
        return .{ .store = store, .transport = transport };
    }

    /// The bytes of `cid` (caller-owned), from the local store or the best
    /// of `holders`; a fetched block is verified and kept in the read
    /// cache. `root` is the file it belongs to (misses are remembered per
    /// file). Rates are measured on leaf blocks (file data) only.
    pub fn fetch(self: *Fetcher, root: *const Cid, cid: *const Cid, holders: []const NodeID, allocator: std.mem.Allocator) ![]u8 {
        return self.fetchVerdict(root, cid, holders, allocator, null, null);
    }

    /// Like `fetch`; when it fails, `lost` (if given) tells whether the block
    /// is on none of the devices that can be asked now: `author` answered
    /// "not found" (now, or a moment ago), and every other holder did too or
    /// can't be reached (offline, refusing, backing off). Unreachable devices
    /// don't count, so one that is away for days doesn't hold the verdict
    /// back; a reachable one that answers anything but "not found" does.
    pub fn fetchVerdict(self: *Fetcher, root: *const Cid, cid: *const Cid, holders: []const NodeID, allocator: std.mem.Allocator, author: ?NodeID, lost: ?*bool) ![]u8 {
        if (lost) |l| l.* = false;
        if (try self.store.get(cid, allocator)) |block| {
            self.count(.local, 0);
            return @constCast(block.data);
        }
        const list = holders[0..@min(holders.len, max_holders)];
        if (list.len == 0) return error.NoHolders;
        var tried = [_]bool{false} ** max_holders;
        var last: anyerror = error.BlockNotFound;
        var tally: Tally = .{};
        var not_found = [_]bool{false} ** max_holders;
        while (self.pick(root, cid, list, &tried, if (tally.only_refused) .may_probe else .no_probe)) |picked| {
            const i = picked.index;
            tried[i] = true;
            const peer = list[i];
            const started = sync.monotonicMillis();
            const result = self.transport.getFn(self.transport.ctx, peer, cid, allocator);
            const elapsed = sync.monotonicMillis() - started;
            const maybe = result catch |err| {
                self.done(peer, root, cid, .{ .failed = err });
                last = err;
                tally.note(.{ .failed = err }, picked.probe);
                continue;
            };
            const bytes = maybe orelse {
                self.done(peer, root, cid, .not_found);
                last = error.BlockNotFound;
                not_found[i] = true;
                tally.note(.not_found, picked.probe);
                continue;
            };
            // put() checks the bytes hash to `cid` before keeping them.
            self.store.putCached(.{ .cid = cid.*, .data = bytes }) catch |err| {
                allocator.free(bytes);
                self.done(peer, root, cid, .{ .failed = err });
                last = err;
                tally.note(.bad_answer, picked.probe);
                continue;
            };
            self.done(peer, root, cid, .{ .served = .{ .len = bytes.len, .ms = elapsed, .leaf = bytes.len > 0 and bytes[0] == leaf_tag } });
            return bytes;
        }
        if (lost) |l| l.* = !tally.any_failed and author != null and self.authorMissed(root, cid, list, &tried, &not_found, author.?);
        // Nobody asked: every holder said "not found" a moment ago (`last`
        // is BlockNotFound). Every one asked out of reach: say so, whatever
        // the transport called it.
        if (tally.failed_attempts > 0 and tally.all_unreachable) return error.HoldersUnreachable;
        return last;
    }

    /// One failed attempt of a fetch.
    const Attempt = union(enum) {
        /// The transport failed (could not connect, or the holder answered
        /// with an error).
        failed: anyerror,
        /// The holder answered "not found".
        not_found,
        /// The holder answered with bytes that couldn't be kept (they don't
        /// hash to the CID, or the store failed).
        bad_answer,
    };

    /// What the failed attempts of one fetch add up to; every attempt goes
    /// through `note`, so the three flags can't drift apart.
    const Tally = struct {
        /// Attempts that failed (a fetch that succeeds returns before
        /// the tally is read).
        failed_attempts: usize = 0,
        /// A reachable holder answered something other than "not found":
        /// holds the lost verdict back.
        any_failed: bool = false,
        /// Every holder asked failed to be reached (none answered at all).
        all_unreachable: bool = true,
        /// Every holder asked was refused at once by the connection
        /// manager's backoff (error.PeerUnreachable: no traffic, no wait),
        /// so probing the next one costs nothing either.
        only_refused: bool = true,

        fn note(self: *Tally, attempt: Attempt, probe: bool) void {
            self.failed_attempts += 1;
            switch (attempt) {
                .failed => |err| {
                    // A holder asked only because every one was backing
                    // off (a probe) would have been skipped before: its
                    // failure, whatever the transport calls it, leaves the
                    // verdict as it was.
                    if (!unreachable_error(err) and !probe) self.any_failed = true;
                    if (!cant_reach(err)) self.all_unreachable = false;
                    if (err != error.PeerUnreachable) self.only_refused = false;
                },
                .not_found => {
                    self.all_unreachable = false;
                    self.only_refused = false;
                },
                .bad_answer => {
                    self.any_failed = true;
                    self.all_unreachable = false;
                    self.only_refused = false;
                },
            }
        }
    };

    /// The author is among `holders` and said "not found": in this fetch, or
    /// a moment ago (skipped for it now).
    fn authorMissed(self: *Fetcher, root: *const Cid, cid: *const Cid, holders: []const NodeID, tried: *const [max_holders]bool, not_found: *const [max_holders]bool, author: NodeID) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        const now = sync.monotonicMillis();
        for (holders, 0..) |peer, i| {
            if (!peer.eql(author)) continue;
            if (tried[i]) return not_found[i];
            return self.missedLocked(peer, root, cid, now);
        }
        return false;
    }

    /// Errors that mean the device couldn't be reached at all, as opposed
    /// to one that answered with a failure.
    fn unreachable_error(err: anyerror) bool {
        return switch (err) {
            error.ConnectionRefused, error.ConnectionTimedOut, error.NoRelay, error.PeerIdMismatch, error.NetworkUnreachable, error.HostUnreachable, error.PeerDown, error.ConnectionResetByPeer, error.BrokenPipe, error.Timeout => true,
            else => false,
        };
    }

    /// Errors that say no connection to the device could be had: what
    /// unreachable_error counts, plus the connection manager's "every
    /// address failed" and "backing off". Only names the error a read
    /// reports (HoldersUnreachable); the lost verdict keeps the narrower
    /// set, so a holder that fails that way still holds it back.
    fn cant_reach(err: anyerror) bool {
        return unreachable_error(err) or switch (err) {
            error.AllAddressesFailed, error.PeerUnreachable, error.ProviderUnreachable => true,
            else => false,
        };
    }

    const Outcome = union(enum) {
        served: struct { len: usize, ms: i64, leaf: bool },
        not_found,
        failed: anyerror,
    };

    /// Whether pick may fall back to a holder backing off: only while
    /// nobody was asked yet in this fetch, or every one asked was refused
    /// at once by the connection manager's backoff (a dead holder ranked
    /// first must not use up the only chance of a reachable one after it).
    const ProbePolicy = enum { may_probe, no_probe };

    /// The holder to ask next, or null when none is left; counts the
    /// request in flight. Holders backing off are skipped, unless connected
    /// again, or unless `policy` is may_probe and they are all that is
    /// left: then the first of them in the caller's order (the author, the
    /// backups, connected peers first) is asked anyway, so a read never
    /// fails without asking anyone. (The connection manager's own backoff
    /// keeps that from redialing a dead device for every block, and
    /// BlockManager skips the DHT lookup while it lasts.)
    fn pick(self: *Fetcher, root: *const Cid, cid: *const Cid, holders: []const NodeID, tried: *[max_holders]bool, policy: ProbePolicy) ?Picked {
        self.mutex.lock();
        defer self.mutex.unlock();
        const now = sync.monotonicMillis();
        const fallback = self.bestRateLocked();
        var best: ?usize = null;
        var best_cost: u64 = std.math.maxInt(u64);
        // The first holder backing off, in the caller's order.
        var probe: ?usize = null;
        for (holders, 0..) |peer, i| {
            if (tried[i]) continue;
            if (self.missedLocked(peer, root, cid, now)) continue;
            const st = self.findLocked(peer);
            if (st) |s| if (now < s.down_until and !self.connectedLocked(peer)) {
                if (probe == null) probe = i;
                continue;
            };
            const rate: u64 = if (st) |s| (if (s.rate > 0) s.rate else fallback) else fallback;
            const in_flight: u64 = if (st) |s| s.in_flight else 0;
            // Expected wait for one more block, scaled to stay an integer.
            const c = (in_flight + 1) * 1_000_000 / @max(rate, 1);
            if (c < best_cost) { // ties keep the caller's order
                best = i;
                best_cost = c;
            }
        }
        const is_probe = best == null;
        const i = best orelse (if (policy == .may_probe) probe else null) orelse return null;
        const st = self.getOrAddLocked(holders[i], now);
        st.in_flight +|= 1;
        st.last_used = now;
        return .{ .index = i, .probe = is_probe };
    }

    /// What pick chose: the holder's index, and whether it is backing off
    /// and asked only because nothing else was left (a probe).
    const Picked = struct { index: usize, probe: bool };

    fn done(self: *Fetcher, peer: NodeID, root: *const Cid, cid: *const Cid, outcome: Outcome) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        const now = sync.monotonicMillis();
        const st = self.getOrAddLocked(peer, now);
        st.in_flight -|= 1;
        switch (outcome) {
            .served => |s| {
                st.fails = 0;
                st.down_until = 0;
                st.blocks += 1;
                st.bytes += s.len;
                self.stats.fetched += 1;
                self.stats.fetched_bytes += s.len;
                // Small index blocks measure latency, not throughput.
                if (s.leaf and s.len >= 16 * 1024) {
                    const sample: u32 = @intCast(@min(s.len / @as(usize, @intCast(@max(s.ms, 1))), std.math.maxInt(u32)));
                    st.rate = if (st.rate == 0) sample else @intCast((@as(u64, st.rate) * 3 + sample) / 4);
                }
                self.clearRootMissLocked(peer, root);
            },
            .not_found => {
                self.stats.not_found += 1;
                self.addBlockMissLocked(peer, cid, now);
                self.addRootMissLocked(peer, root, now);
            },
            .failed => {
                self.stats.failed += 1;
                st.fails +|= 1;
                const shift: u6 = @intCast(@min(st.fails - 1, 4));
                st.down_until = now + @min(backoff_first_ms << shift, backoff_max_ms);
            },
        }
    }

    fn count(self: *Fetcher, comptime what: enum { local }, _: usize) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        switch (what) {
            .local => self.stats.local += 1,
        }
    }

    /// Whether `peer` is down: failed to connect recently.
    pub fn isDown(self: *Fetcher, peer: NodeID) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        const st = self.findLocked(peer) orelse return false;
        return sync.monotonicMillis() < st.down_until;
    }

    /// Marks `peer` down (e.g. the mount saw it fail), with backoff.
    pub fn markDown(self: *Fetcher, peer: NodeID) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        const now = sync.monotonicMillis();
        const st = self.getOrAddLocked(peer, now);
        st.fails +|= 1;
        const shift: u6 = @intCast(@min(st.fails - 1, 4));
        st.down_until = now + @min(backoff_first_ms << shift, backoff_max_ms);
    }

    pub fn markUp(self: *Fetcher, peer: NodeID) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        const st = self.findLocked(peer) orelse return;
        st.fails = 0;
        st.down_until = 0;
    }

    /// Forgets every device's backoff: this node was cut off, so the
    /// failures were its own, not the devices' (Node clears the connection
    /// manager's backoff at the same moment).
    pub fn clearAllBackoff(self: *Fetcher) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        for (self.peers[0..self.peer_count]) |*s| {
            s.fails = 0;
            s.down_until = 0;
        }
    }

    /// Whether the transport has a live connection to `peer`. Caller holds
    /// `mutex`.
    fn connectedLocked(self: *Fetcher, peer: NodeID) bool {
        const f = self.transport.connectedFn orelse return false;
        return f(self.transport.ctx, peer);
    }

    /// A copy of what is known about each device, for measuring.
    pub fn snapshot(self: *Fetcher, out: []PeerState) []PeerState {
        self.mutex.lock();
        defer self.mutex.unlock();
        const n = @min(out.len, self.peer_count);
        @memcpy(out[0..n], self.peers[0..n]);
        return out[0..n];
    }

    pub fn totals(self: *Fetcher) Stats {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.stats;
    }

    // ---- State (caller holds mutex) ----

    fn findLocked(self: *Fetcher, peer: NodeID) ?*PeerState {
        for (self.peers[0..self.peer_count]) |*s| if (s.id.eql(peer)) return s;
        return null;
    }

    /// Full: the device used longest ago (and not busy) makes room.
    fn getOrAddLocked(self: *Fetcher, peer: NodeID, now: i64) *PeerState {
        if (self.findLocked(peer)) |s| return s;
        if (self.peer_count < max_peers) {
            self.peers[self.peer_count] = .{ .id = peer, .last_used = now };
            self.peer_count += 1;
            return &self.peers[self.peer_count - 1];
        }
        var victim: usize = 0;
        for (self.peers[0..self.peer_count], 0..) |s, i| {
            const v = self.peers[victim];
            if ((s.in_flight == 0 and v.in_flight > 0) or (s.in_flight == v.in_flight and s.last_used < v.last_used)) victim = i;
        }
        self.peers[victim] = .{ .id = peer, .last_used = now };
        return &self.peers[victim];
    }

    fn bestRateLocked(self: *Fetcher) u32 {
        var best: u32 = 0;
        for (self.peers[0..self.peer_count]) |s| best = @max(best, s.rate);
        return if (best > 0) best else default_rate;
    }

    fn missedLocked(self: *Fetcher, peer: NodeID, root: *const Cid, cid: *const Cid, now: i64) bool {
        for (self.block_misses[0..self.block_miss_count]) |m| {
            if (now < m.until and m.peer.eql(peer) and std.mem.eql(u8, &m.cid, cid)) return true;
        }
        for (self.root_misses[0..self.root_miss_count]) |m| {
            if (m.count >= root_miss_after and now < m.until and m.peer.eql(peer) and std.mem.eql(u8, &m.root, root)) return true;
        }
        return false;
    }

    /// A ring: the oldest miss makes room.
    fn addBlockMissLocked(self: *Fetcher, peer: NodeID, cid: *const Cid, now: i64) void {
        self.block_misses[self.block_miss_next] = .{ .peer = peer, .cid = cid.*, .until = now + block_miss_ms };
        self.block_miss_next = (self.block_miss_next + 1) % max_block_misses;
        self.block_miss_count = @min(self.block_miss_count + 1, max_block_misses);
    }

    fn addRootMissLocked(self: *Fetcher, peer: NodeID, root: *const Cid, now: i64) void {
        for (self.root_misses[0..self.root_miss_count]) |*m| {
            if (m.peer.eql(peer) and std.mem.eql(u8, &m.root, root)) {
                if (now >= m.until) m.count = 0;
                m.count +|= 1;
                m.until = now + root_miss_ms;
                return;
            }
        }
        const entry: RootMiss = .{ .peer = peer, .root = root.*, .count = 1, .until = now + root_miss_ms };
        if (self.root_miss_count < max_root_misses) {
            self.root_misses[self.root_miss_count] = entry;
            self.root_miss_count += 1;
            return;
        }
        // Full: replace the one expiring first.
        var victim: usize = 0;
        for (self.root_misses, 0..) |m, i| if (m.until < self.root_misses[victim].until) {
            victim = i;
        };
        self.root_misses[victim] = entry;
    }

    /// A block served: the device has (part of) the file after all.
    fn clearRootMissLocked(self: *Fetcher, peer: NodeID, root: *const Cid) void {
        for (self.root_misses[0..self.root_miss_count]) |*m| {
            if (m.peer.eql(peer) and std.mem.eql(u8, &m.root, root)) m.count = 0;
        }
    }
};

// ---- Tests: scheduling against a fake network ----

const testing = std.testing;

pub const FakeNet = struct {
    /// Per peer: has the blocks, delay in ms, fails to connect, answers
    /// with an error (reachable but failing).
    /// `connected`: the transport reports a live connection to it.
    /// `offline`: fails like the real connection manager does for a device
    /// none of whose addresses answers (error.AllAddressesFailed, which
    /// unreachable_error doesn't count). `refused`: refused at once by the
    /// manager's dial backoff (error.PeerUnreachable).
    pub const Peer = struct { id: NodeID, has: bool = true, delay_ms: u64 = 0, down: bool = false, offline: bool = false, refused: bool = false, broken: bool = false, connected: bool = false, served: std.atomic.Value(u32) = .init(0) };
    peers: []Peer,
    blocks: std.AutoHashMapUnmanaged(Cid, []const u8) = .empty,

    pub fn transport(self: *FakeNet) Transport {
        return .{ .ctx = self, .getFn = get, .connectedFn = connected };
    }

    fn connected(ctx: *anyopaque, peer: NodeID) bool {
        const self: *FakeNet = @ptrCast(@alignCast(ctx));
        for (self.peers) |p| if (p.id.eql(peer)) return p.connected;
        return false;
    }

    fn get(ctx: *anyopaque, peer: NodeID, cid: *const Cid, allocator: std.mem.Allocator) anyerror!?[]u8 {
        const self: *FakeNet = @ptrCast(@alignCast(ctx));
        for (self.peers) |*p| if (p.id.eql(peer)) {
            if (p.down) return error.ConnectionRefused;
            if (p.offline) return error.AllAddressesFailed;
            if (p.refused) return error.PeerUnreachable;
            if (p.broken) return error.InvalidResponse;
            if (p.delay_ms > 0) sync.sleep(p.delay_ms * std.time.ns_per_ms);
            if (!p.has) return null;
            const data = self.blocks.get(cid.*) orelse return null;
            _ = p.served.fetchAdd(1, .monotonic);
            return try allocator.dupe(u8, data);
        };
        return error.UnknownPeer;
    }
};

fn idOf(b: u8) NodeID {
    return .{ .bytes = [_]u8{b} ** 32 };
}

/// A fresh store at `path` for a test (keeper.zig's tests use it too).
pub fn testStore(path: []const u8) !storage.engine.StorageEngine {
    const io = std.Io.Threaded.global_single_threaded.io();
    std.Io.Dir.cwd().deleteTree(io, path) catch {};
    return storage.engine.StorageEngine.init(testing.allocator, path);
}

/// `n` leaf blocks of `size` bytes in `net`; their CIDs in `out`.
fn addBlocks(net: *FakeNet, arena: std.mem.Allocator, n: usize, size: usize, out: []Cid) !void {
    for (out[0..n], 0..) |*cid, i| {
        const data = try arena.alloc(u8, size);
        @memset(data, @intCast(i % 251));
        data[0] = 0; // a leaf
        std.mem.writeInt(u32, data[1..5], @intCast(i), .little);
        std.crypto.hash.sha2.Sha256.hash(data, cid, .{});
        try net.blocks.put(arena, cid.*, data);
    }
}

test "fetcher: skips a device without the file after a few misses, then uses one that has it" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const path = "test_fetcher_miss";
    var store = try testStore(path);
    defer {
        store.deinit();
        std.Io.Dir.cwd().deleteTree(std.Io.Threaded.global_single_threaded.io(), path) catch {};
    }
    var peers = [_]FakeNet.Peer{ .{ .id = idOf(1), .has = false }, .{ .id = idOf(2) } };
    var net: FakeNet = .{ .peers = &peers };
    var cids: [10]Cid = undefined;
    try addBlocks(&net, arena.allocator(), cids.len, 1024, &cids);
    var f = Fetcher.init(&store, net.transport());
    const root = [_]u8{9} ** 32;
    const holders = [_]NodeID{ idOf(1), idOf(2) };
    for (&cids) |*cid| testing.allocator.free(try f.fetch(&root, cid, &holders, testing.allocator));
    // The device without the file is asked until it has missed 3 times in a
    // row on this file, then skipped.
    try testing.expectEqual(@as(u64, Fetcher.root_miss_after), f.totals().not_found);
    try testing.expectEqual(@as(u32, 10), peers[1].served.load(.monotonic));
    // Read again: local now.
    for (&cids) |*cid| testing.allocator.free(try f.fetch(&root, cid, &holders, testing.allocator));
    try testing.expectEqual(@as(u64, 10), f.totals().local);
}

test "fetcher: a device that fails to connect is skipped until its backoff ends" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const path = "test_fetcher_down";
    var store = try testStore(path);
    defer {
        store.deinit();
        std.Io.Dir.cwd().deleteTree(std.Io.Threaded.global_single_threaded.io(), path) catch {};
    }
    var peers = [_]FakeNet.Peer{ .{ .id = idOf(1), .down = true }, .{ .id = idOf(2) } };
    var net: FakeNet = .{ .peers = &peers };
    var cids: [5]Cid = undefined;
    try addBlocks(&net, arena.allocator(), cids.len, 1024, &cids);
    var f = Fetcher.init(&store, net.transport());
    const root = [_]u8{9} ** 32;
    const holders = [_]NodeID{ idOf(1), idOf(2) };
    for (&cids) |*cid| testing.allocator.free(try f.fetch(&root, cid, &holders, testing.allocator));
    try testing.expectEqual(@as(u64, 1), f.totals().failed);
    try testing.expect(f.isDown(idOf(1)));
    // Nothing is left in flight after failures.
    var buf: [8]Fetcher.PeerState = undefined;
    for (f.snapshot(&buf)) |s| try testing.expectEqual(@as(u16, 0), s.in_flight);
    // No holder at all has it: the last error comes back.
    const missing = [_]u8{7} ** 32;
    try testing.expectError(error.BlockNotFound, f.fetch(&root, &missing, &holders, testing.allocator));
}

test "fetcher: concurrent fetches spread across holders, more to the faster one" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const path = "test_fetcher_spread";
    var store = try testStore(path);
    defer {
        store.deinit();
        std.Io.Dir.cwd().deleteTree(std.Io.Threaded.global_single_threaded.io(), path) catch {};
    }
    var peers = [_]FakeNet.Peer{ .{ .id = idOf(1), .delay_ms = 2 }, .{ .id = idOf(2), .delay_ms = 2 }, .{ .id = idOf(3), .delay_ms = 20 } };
    var net: FakeNet = .{ .peers = &peers };
    var cids: [120]Cid = undefined;
    try addBlocks(&net, arena.allocator(), cids.len, 64 * 1024, &cids);
    var f = Fetcher.init(&store, net.transport());
    const root = [_]u8{9} ** 32;
    const holders = [_]NodeID{ idOf(3), idOf(1), idOf(2) };

    // Six workers, like read-ahead.
    const Worker = struct {
        fn run(fetcher: *Fetcher, all: []Cid, next: *std.atomic.Value(usize), hs: []const NodeID, r: *const Cid) void {
            while (true) {
                const i = next.fetchAdd(1, .monotonic);
                if (i >= all.len) return;
                const bytes = fetcher.fetch(r, &all[i], hs, testing.allocator) catch return;
                testing.allocator.free(bytes);
            }
        }
    };
    var next: std.atomic.Value(usize) = .init(0);
    var threads: [6]std.Thread = undefined;
    for (&threads) |*t| t.* = try std.Thread.spawn(.{}, Worker.run, .{ &f, &cids, &next, &holders, &root });
    for (threads) |t| t.join();

    const slow = peers[2].served.load(.monotonic);
    const fast = peers[0].served.load(.monotonic) + peers[1].served.load(.monotonic);
    try testing.expectEqual(@as(u64, cids.len), f.totals().fetched);
    // Every holder served some; the fast ones most of it.
    try testing.expect(peers[0].served.load(.monotonic) > 0 and peers[1].served.load(.monotonic) > 0);
    try testing.expect(fast > slow * 3);
}

test "fetcher: lost when the author and every reachable holder said not found" {
    const path = "test_fetcher_lost";
    var store = try testStore(path);
    defer {
        store.deinit();
        std.Io.Dir.cwd().deleteTree(std.Io.Threaded.global_single_threaded.io(), path) catch {};
    }
    var peers = [_]FakeNet.Peer{
        .{ .id = idOf(1), .has = false }, // the author
        .{ .id = idOf(2), .has = false },
        .{ .id = idOf(3), .down = true }, // away: doesn't count
        .{ .id = idOf(4), .broken = true }, // reachable, answers an error
    };
    var net: FakeNet = .{ .peers = &peers };
    var f = Fetcher.init(&store, net.transport());
    const root = [_]u8{9} ** 32;
    const cid = [_]u8{7} ** 32;
    const author = idOf(1);
    var lost = false;
    try testing.expectError(error.BlockNotFound, f.fetchVerdict(&root, &cid, &.{ idOf(1), idOf(2) }, testing.allocator, author, &lost));
    try testing.expect(lost);
    // Asked again right away: both are skipped for their recent miss; still lost.
    _ = f.fetchVerdict(&root, &cid, &.{ idOf(1), idOf(2) }, testing.allocator, author, &lost) catch {};
    try testing.expect(lost);
    // A device that can't be reached doesn't hold the verdict back, now or
    // while it is backing off.
    _ = f.fetchVerdict(&root, &cid, &.{ idOf(1), idOf(2), idOf(3) }, testing.allocator, author, &lost) catch {};
    try testing.expect(lost);
    _ = f.fetchVerdict(&root, &cid, &.{ idOf(1), idOf(2), idOf(3) }, testing.allocator, author, &lost) catch {};
    try testing.expect(lost);
    // No author given, or the author not among the holders: never lost.
    _ = f.fetchVerdict(&root, &cid, &.{ idOf(1), idOf(2) }, testing.allocator, null, &lost) catch {};
    try testing.expect(!lost);
    _ = f.fetchVerdict(&root, &cid, &.{idOf(2)}, testing.allocator, author, &lost) catch {};
    try testing.expect(!lost);
    // No holder at all: not lost.
    try testing.expectError(error.NoHolders, f.fetchVerdict(&root, &cid, &.{}, testing.allocator, author, &lost));
    try testing.expect(!lost);
}

test "fetcher: a reachable holder that answers with an error keeps it from being lost" {
    const path = "test_fetcher_lost_broken";
    var store = try testStore(path);
    defer {
        store.deinit();
        std.Io.Dir.cwd().deleteTree(std.Io.Threaded.global_single_threaded.io(), path) catch {};
    }
    var peers = [_]FakeNet.Peer{ .{ .id = idOf(1), .has = false }, .{ .id = idOf(4), .broken = true } };
    var net: FakeNet = .{ .peers = &peers };
    var f = Fetcher.init(&store, net.transport());
    const root = [_]u8{9} ** 32;
    const cid = [_]u8{7} ** 32;
    var lost = true;
    _ = f.fetchVerdict(&root, &cid, &.{ idOf(1), idOf(4) }, testing.allocator, idOf(1), &lost) catch {};
    try testing.expect(!lost);
}

test "fetcher: an author that can't be reached never makes it lost" {
    const path = "test_fetcher_lost_author_away";
    var store = try testStore(path);
    defer {
        store.deinit();
        std.Io.Dir.cwd().deleteTree(std.Io.Threaded.global_single_threaded.io(), path) catch {};
    }
    var peers = [_]FakeNet.Peer{ .{ .id = idOf(1), .down = true }, .{ .id = idOf(2), .has = false } };
    var net: FakeNet = .{ .peers = &peers };
    var f = Fetcher.init(&store, net.transport());
    const root = [_]u8{9} ** 32;
    const cid = [_]u8{7} ** 32;
    var lost = true;
    _ = f.fetchVerdict(&root, &cid, &.{ idOf(1), idOf(2) }, testing.allocator, idOf(1), &lost) catch {};
    try testing.expect(!lost);
}

test "fetcher: every holder backing off: the first in the caller's order is asked, never none" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const path = "test_fetcher_probe";
    var store = try testStore(path);
    defer {
        store.deinit();
        std.Io.Dir.cwd().deleteTree(std.Io.Threaded.global_single_threaded.io(), path) catch {};
    }
    var peers = [_]FakeNet.Peer{ .{ .id = idOf(1) }, .{ .id = idOf(2) } };
    var net: FakeNet = .{ .peers = &peers };
    var cids: [1]Cid = undefined;
    try addBlocks(&net, arena.allocator(), cids.len, 1024, &cids);
    var f = Fetcher.init(&store, net.transport());
    const root = [_]u8{9} ** 32;
    const holders = [_]NodeID{ idOf(1), idOf(2) };
    // Both down (say, the mount saw them fail); 1 twice, so 2 is due back
    // sooner, but 1 is listed first (the caller ranks the backup first).
    f.markDown(idOf(1));
    f.markDown(idOf(1));
    f.markDown(idOf(2));
    // Both are back: the read asks 1 instead of failing.
    testing.allocator.free(try f.fetch(&root, &cids[0], &holders, testing.allocator));
    try testing.expectEqual(@as(u32, 1), peers[0].served.load(.monotonic));
    try testing.expectEqual(@as(u32, 0), peers[1].served.load(.monotonic));
    try testing.expect(!f.isDown(idOf(1)));
}

test "fetcher: every holder out of reach reads as HoldersUnreachable; no holder as NoHolders" {
    const path = "test_fetcher_unreachable";
    var store = try testStore(path);
    defer {
        store.deinit();
        std.Io.Dir.cwd().deleteTree(std.Io.Threaded.global_single_threaded.io(), path) catch {};
    }
    var peers = [_]FakeNet.Peer{ .{ .id = idOf(1), .down = true }, .{ .id = idOf(2), .down = true } };
    var net: FakeNet = .{ .peers = &peers };
    var f = Fetcher.init(&store, net.transport());
    const root = [_]u8{9} ** 32;
    const cid = [_]u8{7} ** 32;
    const holders = [_]NodeID{ idOf(1), idOf(2) };
    try testing.expectError(error.HoldersUnreachable, f.fetch(&root, &cid, &holders, testing.allocator));
    // Both backing off now: one is still asked, and the answer is the same.
    try testing.expectError(error.HoldersUnreachable, f.fetch(&root, &cid, &holders, testing.allocator));
    try testing.expectEqual(@as(u64, 3), f.totals().failed);
    try testing.expectError(error.NoHolders, f.fetch(&root, &cid, &.{}, testing.allocator));
    // One reachable holder without the block: "not found" wins.
    peers[1].down = false;
    peers[1].has = false;
    f.clearAllBackoff();
    try testing.expectError(error.BlockNotFound, f.fetch(&root, &cid, &holders, testing.allocator));
}

test "fetcher: a holder backing off is asked once it is connected again" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const path = "test_fetcher_connected";
    var store = try testStore(path);
    defer {
        store.deinit();
        std.Io.Dir.cwd().deleteTree(std.Io.Threaded.global_single_threaded.io(), path) catch {};
    }
    var peers = [_]FakeNet.Peer{ .{ .id = idOf(1), .delay_ms = 20 }, .{ .id = idOf(2) } };
    var net: FakeNet = .{ .peers = &peers };
    var cids: [2]Cid = undefined;
    try addBlocks(&net, arena.allocator(), cids.len, 1024, &cids);
    var f = Fetcher.init(&store, net.transport());
    const root = [_]u8{9} ** 32;
    const holders = [_]NodeID{ idOf(2), idOf(1) };
    // 2 is backing off: 1 serves.
    f.markDown(idOf(2));
    testing.allocator.free(try f.fetch(&root, &cids[0], &holders, testing.allocator));
    try testing.expectEqual(@as(u32, 1), peers[0].served.load(.monotonic));
    // 2 is connected again (say, through a relay): asked despite its
    // backoff, first as listed first (both unmeasured: small blocks).
    peers[1].connected = true;
    testing.allocator.free(try f.fetch(&root, &cids[1], &holders, testing.allocator));
    try testing.expectEqual(@as(u32, 1), peers[1].served.load(.monotonic));
}

test "fetcher: a probe of a device backing off never holds the lost verdict back" {
    const path = "test_fetcher_probe_lost";
    var store = try testStore(path);
    defer {
        store.deinit();
        std.Io.Dir.cwd().deleteTree(std.Io.Threaded.global_single_threaded.io(), path) catch {};
    }
    // 1, the author, said "not found"; 2 is away (the real manager's error).
    var peers = [_]FakeNet.Peer{ .{ .id = idOf(1), .has = false }, .{ .id = idOf(2), .offline = true } };
    var net: FakeNet = .{ .peers = &peers };
    var f = Fetcher.init(&store, net.transport());
    const root = [_]u8{9} ** 32;
    const cid = [_]u8{7} ** 32;
    const holders = [_]NodeID{ idOf(1), idOf(2) };
    var lost = true;
    // Asked normally, 2's failure holds the verdict back (as before).
    _ = f.fetchVerdict(&root, &cid, &holders, testing.allocator, idOf(1), &lost) catch {};
    try testing.expect(!lost);
    // Again at once: 1 is skipped for its miss, 2 is backing off and asked
    // only as a probe. Its failure leaves the verdict as skipping it did.
    try testing.expectError(error.HoldersUnreachable, f.fetchVerdict(&root, &cid, &holders, testing.allocator, idOf(1), &lost));
    try testing.expect(lost);
    try testing.expectEqual(@as(u64, 2), f.totals().failed);
}

test "fetcher: a dead holder the manager refuses at once doesn't use up the probe" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const path = "test_fetcher_probe_refused";
    var store = try testStore(path);
    defer {
        store.deinit();
        std.Io.Dir.cwd().deleteTree(std.Io.Threaded.global_single_threaded.io(), path) catch {};
    }
    // 1 (the author, listed first) is dead and backed off in the manager;
    // 2 (the backup) has the block. Both back off in the fetcher.
    var peers = [_]FakeNet.Peer{ .{ .id = idOf(1), .refused = true }, .{ .id = idOf(2) }, .{ .id = idOf(3), .offline = true } };
    var net: FakeNet = .{ .peers = &peers };
    var cids: [1]Cid = undefined;
    try addBlocks(&net, arena.allocator(), cids.len, 1024, &cids);
    var f = Fetcher.init(&store, net.transport());
    const root = [_]u8{9} ** 32;
    f.markDown(idOf(1));
    f.markDown(idOf(2));
    testing.allocator.free(try f.fetch(&root, &cids[0], &.{ idOf(1), idOf(2) }, testing.allocator));
    try testing.expectEqual(@as(u64, 1), f.totals().failed); // 1 was asked, and refused
    try testing.expectEqual(@as(u32, 1), peers[1].served.load(.monotonic));
    // A probe that cost a real dial attempt (3: every address failed) ends
    // the probing: the next holder backing off is not asked in that fetch.
    const missing = [_]u8{7} ** 32;
    f.markDown(idOf(3));
    f.markDown(idOf(2));
    peers[1].has = false;
    try testing.expectError(error.HoldersUnreachable, f.fetch(&root, &missing, &.{ idOf(3), idOf(2) }, testing.allocator));
    try testing.expectEqual(@as(u64, 0), f.totals().not_found); // 2 never asked
}

test "fetcher: Tally.note, one rule per kind of failed attempt" {
    const Case = struct { attempt: Fetcher.Attempt, probe: bool, any_failed: bool, all_unreachable: bool, only_refused: bool };
    const cases = [_]Case{
        // Refused at once by the manager's backoff: still out of reach, still free to probe.
        .{ .attempt = .{ .failed = error.PeerUnreachable }, .probe = true, .any_failed = false, .all_unreachable = true, .only_refused = true },
        // The same refusal asked normally holds the verdict back (the narrow set, as before).
        .{ .attempt = .{ .failed = error.PeerUnreachable }, .probe = false, .any_failed = true, .all_unreachable = true, .only_refused = true },
        // A dial that went out and failed: out of reach, but probing stops.
        .{ .attempt = .{ .failed = error.ConnectionRefused }, .probe = false, .any_failed = false, .all_unreachable = true, .only_refused = false },
        .{ .attempt = .{ .failed = error.AllAddressesFailed }, .probe = true, .any_failed = false, .all_unreachable = true, .only_refused = false },
        // A reachable holder answering with an error.
        .{ .attempt = .{ .failed = error.InvalidResponse }, .probe = false, .any_failed = true, .all_unreachable = false, .only_refused = false },
        .{ .attempt = .{ .failed = error.InvalidResponse }, .probe = true, .any_failed = false, .all_unreachable = false, .only_refused = false },
        .{ .attempt = .not_found, .probe = false, .any_failed = false, .all_unreachable = false, .only_refused = false },
        .{ .attempt = .bad_answer, .probe = true, .any_failed = true, .all_unreachable = false, .only_refused = false },
    };
    for (cases) |c| {
        var t: Fetcher.Tally = .{};
        t.note(c.attempt, c.probe);
        try testing.expectEqual(@as(usize, 1), t.failed_attempts);
        try testing.expectEqual(c.any_failed, t.any_failed);
        try testing.expectEqual(c.all_unreachable, t.all_unreachable);
        try testing.expectEqual(c.only_refused, t.only_refused);
    }
}
