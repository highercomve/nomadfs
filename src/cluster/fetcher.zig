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
        if (try self.store.get(cid, allocator)) |block| {
            self.count(.local, 0);
            return @constCast(block.data);
        }
        const list = holders[0..@min(holders.len, max_holders)];
        var tried = [_]bool{false} ** max_holders;
        var last: anyerror = error.NoHolder;
        while (self.pick(root, cid, list, &tried)) |i| {
            tried[i] = true;
            const peer = list[i];
            const started = sync.monotonicMillis();
            const result = self.transport.getFn(self.transport.ctx, peer, cid, allocator);
            const elapsed = sync.monotonicMillis() - started;
            const maybe = result catch |err| {
                self.done(peer, root, cid, .{ .failed = err });
                last = err;
                continue;
            };
            const bytes = maybe orelse {
                self.done(peer, root, cid, .not_found);
                last = error.BlockNotFound;
                continue;
            };
            // put() checks the bytes hash to `cid` before keeping them.
            self.store.putCached(.{ .cid = cid.*, .data = bytes }) catch |err| {
                allocator.free(bytes);
                self.done(peer, root, cid, .{ .failed = err });
                last = err;
                continue;
            };
            self.done(peer, root, cid, .{ .served = .{ .len = bytes.len, .ms = elapsed, .leaf = bytes.len > 0 and bytes[0] == leaf_tag } });
            return bytes;
        }
        return last;
    }

    const Outcome = union(enum) {
        served: struct { len: usize, ms: i64, leaf: bool },
        not_found,
        failed: anyerror,
    };

    /// The holder to ask next, or null when none is left; counts the
    /// request in flight.
    fn pick(self: *Fetcher, root: *const Cid, cid: *const Cid, holders: []const NodeID, tried: *[max_holders]bool) ?usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        const now = sync.monotonicMillis();
        const fallback = self.bestRateLocked();
        var best: ?usize = null;
        var best_cost: u64 = std.math.maxInt(u64);
        for (holders, 0..) |peer, i| {
            if (tried[i]) continue;
            if (self.missedLocked(peer, root, cid, now)) continue;
            const st = self.findLocked(peer);
            if (st) |s| if (now < s.down_until) continue;
            const rate: u64 = if (st) |s| (if (s.rate > 0) s.rate else fallback) else fallback;
            const in_flight: u64 = if (st) |s| s.in_flight else 0;
            // Expected wait for one more block, scaled to stay an integer.
            const c = (in_flight + 1) * 1_000_000 / @max(rate, 1);
            if (c < best_cost) { // ties keep the caller's order
                best = i;
                best_cost = c;
            }
        }
        const i = best orelse return null;
        const st = self.getOrAddLocked(holders[i], now);
        st.in_flight +|= 1;
        st.last_used = now;
        return i;
    }

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

const FakeNet = struct {
    /// Per peer: has the blocks, delay in ms, fails to connect.
    const Peer = struct { id: NodeID, has: bool = true, delay_ms: u64 = 0, down: bool = false, served: std.atomic.Value(u32) = .init(0) };
    peers: []Peer,
    blocks: std.AutoHashMapUnmanaged(Cid, []const u8) = .empty,

    fn transport(self: *FakeNet) Transport {
        return .{ .ctx = self, .getFn = get };
    }

    fn get(ctx: *anyopaque, peer: NodeID, cid: *const Cid, allocator: std.mem.Allocator) anyerror!?[]u8 {
        const self: *FakeNet = @ptrCast(@alignCast(ctx));
        for (self.peers) |*p| if (p.id.eql(peer)) {
            if (p.down) return error.ConnectionRefused;
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
