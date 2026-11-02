//! Makes this device hold what it should: the files `fs/` says it keeps
//! (a swarm backup device: every swarm file; a replica holder: the files
//! placement gives it; a folder backup device: members' marked folders).
//! `fs/` decides *what* through providers; the keeper copies *how*: the
//! whole DAG through the fetcher, several blocks at once so a copy spreads
//! across holders, each kept (pinned) against the quota, skipping blocks
//! already held without reading them, stopping promptly when told to.
//!
//! One thread runs rounds: every `interval_ns`, or sooner after `wake()`.
//! A round asks each provider for its wants (bounded) and copies the ones
//! not held yet; the provider hears each outcome and keeps its own
//! bookkeeping (what it already holds), so rounds stay cheap.

const std = @import("std");
const sync = @import("../sync.zig");
const NodeID = @import("../net/id.zig").NodeID;
const storage = @import("../storage/mod.zig");
const fetcher_mod = @import("fetcher.zig");

const codec = storage.dag.codec;
const walk = storage.dag.walk;
pub const Cid = fetcher_mod.Cid;

/// A file to hold, and the devices likely to have it (best first).
pub const Want = struct {
    root: Cid,
    hints: [fetcher_mod.max_holders]NodeID = undefined,
    hint_count: u8 = 0,
    /// The device that wrote the file, if the provider knows it (it is
    /// normally among the hints). Needed for `Outcome.lost`.
    author: ?NodeID = null,

    pub fn holders(self: *const Want) []const NodeID {
        return self.hints[0..self.hint_count];
    }

    pub fn init(root: Cid, hints: []const NodeID) Want {
        var w: Want = .{ .root = root };
        const n = @min(hints.len, fetcher_mod.max_holders);
        @memcpy(w.hints[0..n], hints[0..n]);
        w.hint_count = @intCast(n);
        return w;
    }
};

/// How copying one wanted file ended.
pub const Outcome = enum {
    /// Held in full.
    kept,
    /// Couldn't be copied this round (a holder unreachable, cancelled, ...).
    failed,
    /// A block was answered "not found" by EVERY holder asked, none failing
    /// or unreachable, and the file's author was among them: the data is on
    /// no device that could be asked. `fs/` decides what that means.
    lost,
};

/// The outcome of a copy that failed with `err` for `want`.
pub fn failure(err: anyerror, want: *const Want) Outcome {
    if (err != error.LostEverywhere) return .failed;
    const author = want.author orelse return .failed;
    for (want.holders()) |h| if (h.eql(author)) return .lost;
    return .failed;
}

/// What `fs/` wants held. Both functions run on the keeper's thread.
pub const Provider = struct {
    ctx: *anyopaque,
    /// Appends the files this device should hold and doesn't yet (as far as
    /// the provider knows), at most `max` of them.
    wantsFn: *const fn (ctx: *anyopaque, allocator: std.mem.Allocator, out: *std.ArrayList(Want), max: usize) anyerror!void,
    /// How the copy of `root` ended this round.
    doneFn: *const fn (ctx: *anyopaque, root: Cid, outcome: Outcome) void,
};

pub const Copied = struct { blocks: usize, bytes: u64 };

/// Blocks fetched at once during one copy.
pub const copy_workers = 4;
/// Most blocks one DAG may have: a valid DAG from a peer can still be enormous.
pub const max_blocks = 1 << 20;
const max_providers = 4;
/// Most files copied per provider per round.
const wants_per_round = 64;

/// Copies the whole DAG `root` into `store`, kept (pinned), through
/// `fetcher` from `hints`. Stops with error.Cancelled when `keep_going`
/// turns false; with error.LostEverywhere when a block is on none of the
/// hints (all answered "not found"; see `failure`).
pub fn copy(allocator: std.mem.Allocator, fetcher: *fetcher_mod.Fetcher, store: *storage.engine.StorageEngine, root: Cid, hints: []const NodeID, author: ?NodeID, keep_going: *const std.atomic.Value(bool)) !Copied {
    var job: CopyJob = .{ .allocator = allocator, .fetcher = fetcher, .store = store, .root = root, .hints = hints, .author = author, .keep_going = keep_going };
    defer {
        job.stack.deinit(allocator);
        job.visited.deinit(allocator);
    }
    try job.stack.append(allocator, root);
    try job.visited.put(allocator, root, {});
    var threads: [copy_workers - 1]?std.Thread = .{null} ** (copy_workers - 1);
    for (&threads) |*t| t.* = std.Thread.spawn(.{}, CopyJob.work, .{&job}) catch null;
    job.work();
    for (threads) |t| if (t) |th| th.join();
    if (job.failure) |err| return err;
    return .{ .blocks = job.fetched, .bytes = job.bytes };
}

const CopyJob = struct {
    allocator: std.mem.Allocator,
    fetcher: *fetcher_mod.Fetcher,
    store: *storage.engine.StorageEngine,
    root: Cid,
    hints: []const NodeID,
    /// Whose "not found" makes a miss final (see Fetcher.fetchVerdict).
    author: ?NodeID,
    keep_going: *const std.atomic.Value(bool),

    mutex: sync.Mutex = .{},
    more: sync.Condition = .{},
    stack: std.ArrayList(Cid) = .empty,
    visited: walk.CidSet = .empty,
    /// Workers holding a block they're processing (it may add children).
    active: usize = 0,
    failure: ?anyerror = null,
    fetched: usize = 0,
    bytes: u64 = 0,

    fn work(self: *CopyJob) void {
        while (true) {
            const cid = blk: {
                self.mutex.lock();
                defer self.mutex.unlock();
                while (self.stack.items.len == 0 and self.active > 0 and self.failure == null) self.more.wait(&self.mutex);
                if (self.failure != null) return;
                const cid = self.stack.pop() orelse return; // empty and nobody busy: done
                self.active += 1;
                break :blk cid;
            };
            self.one(&cid) catch |err| {
                self.mutex.lock();
                defer self.mutex.unlock();
                if (self.failure == null) self.failure = err;
                self.active -= 1;
                self.more.broadcast();
                return;
            };
            self.mutex.lock();
            self.active -= 1;
            self.more.broadcast();
            self.mutex.unlock();
        }
    }

    fn one(self: *CopyJob, cid: *const Cid) !void {
        if (!self.keep_going.load(.acquire)) return error.Cancelled;
        // File data already here: keep it, no read needed.
        if (self.store.heldLeaf(cid)) return self.store.pin(cid);
        const was_here = self.store.has(cid);
        var lost = false;
        const data = self.fetcher.fetchVerdict(&self.root, cid, self.hints, self.allocator, self.author, &lost) catch |err| return if (lost) error.LostEverywhere else err;
        defer self.allocator.free(data);
        try self.store.pin(cid);
        if (!was_here) {
            self.mutex.lock();
            self.fetched += 1;
            self.bytes += data.len;
            self.mutex.unlock();
        }
        switch (try codec.decode(data)) {
            .leaf => {},
            inline .parent, .dir => |links| {
                self.mutex.lock();
                defer self.mutex.unlock();
                var it = links;
                while (it.next()) |link| {
                    const child = link.cid.*;
                    const seen = try self.visited.getOrPut(self.allocator, child);
                    if (seen.found_existing) continue;
                    if (self.visited.count() > max_blocks) return error.DagTooLarge;
                    try self.stack.append(self.allocator, child);
                }
                self.more.broadcast();
            },
        }
    }
};

pub const Keeper = struct {
    allocator: std.mem.Allocator,
    fetcher: *fetcher_mod.Fetcher,
    store: *storage.engine.StorageEngine,
    providers: [max_providers]?Provider = .{null} ** max_providers,
    interval_ns: u64 = 60 * std.time.ns_per_s,
    /// The background thread (sync.Worker); its loop watches worker.running.
    worker: sync.Worker = .{},
    woken: std.atomic.Value(bool) = .init(false),
    /// Serializes rounds (the thread, runNow from tests and the app).
    round_mutex: sync.Mutex = .{},

    pub fn init(allocator: std.mem.Allocator, fetcher: *fetcher_mod.Fetcher, store: *storage.engine.StorageEngine) Keeper {
        return .{ .allocator = allocator, .fetcher = fetcher, .store = store };
    }

    /// Registers a provider; call before start().
    pub fn register(self: *Keeper, provider: Provider) !void {
        for (&self.providers) |*slot| if (slot.* == null) {
            slot.* = provider;
            return;
        };
        return error.TooManyProviders;
    }

    pub fn start(self: *Keeper) !void {
        try self.worker.start(loop, .{self});
    }

    /// Stops the thread; a copy in progress stops at its next block.
    pub fn stop(self: *Keeper) void {
        self.worker.stop();
    }

    /// Run a round soon (something changed: a file was added, membership).
    pub fn wake(self: *Keeper) void {
        self.woken.store(true, .release);
    }

    fn loop(self: *Keeper) void {
        const step = 200 * std.time.ns_per_ms;
        var waited: u64 = self.interval_ns - 5 * std.time.ns_per_s; // first round soon
        while (self.worker.isRunning()) {
            sync.sleep(step);
            waited += step;
            if (waited < self.interval_ns and !self.woken.swap(false, .acq_rel)) continue;
            waited = 0;
            _ = self.round() catch |err| std.debug.print("keeper: round failed: {any}\n", .{err});
        }
    }

    /// One round over every provider; returns how many files are now held.
    pub fn round(self: *Keeper) !usize {
        self.round_mutex.lock();
        defer self.round_mutex.unlock();
        var held: usize = 0;
        var wants: std.ArrayList(Want) = .empty;
        defer wants.deinit(self.allocator);
        for (self.providers) |maybe| {
            const p = maybe orelse continue;
            wants.clearRetainingCapacity();
            try p.wantsFn(p.ctx, self.allocator, &wants, wants_per_round);
            for (wants.items) |*w| {
                if (!self.worker.isRunning()) return held;
                const outcome: Outcome = if (copy(self.allocator, self.fetcher, self.store, w.root, w.holders(), w.author, &self.worker.running)) |c| blk: {
                    if (c.blocks > 0) std.debug.print("keeper: kept {x} ({d} blocks, {d} KiB fetched)\n", .{ w.root[0..4], c.blocks, c.bytes >> 10 });
                    break :blk .kept;
                } else |err| blk: {
                    if (err != error.Cancelled) std.debug.print("keeper: {x} not kept: {any}\n", .{ w.root[0..4], err });
                    break :blk failure(err, w);
                };
                if (outcome == .kept) held += 1;
                p.doneFn(p.ctx, w.root, outcome);
            }
        }
        return held;
    }
};

// ---- Tests ----

const testing = std.testing;

/// The fetcher's network: blocks served from another store.
const StoreNet = struct {
    from: *storage.engine.StorageEngine,
    peer: NodeID,
    served: std.atomic.Value(u32) = .init(0),

    fn transport(self: *StoreNet) fetcher_mod.Transport {
        return .{ .ctx = self, .getFn = get };
    }

    fn get(ctx: *anyopaque, peer: NodeID, cid: *const Cid, allocator: std.mem.Allocator) anyerror!?[]u8 {
        const self: *StoreNet = @ptrCast(@alignCast(ctx));
        if (!peer.eql(self.peer)) return error.ConnectionRefused;
        const block = (try self.from.get(cid, allocator)) orelse return null;
        _ = self.served.fetchAdd(1, .monotonic);
        return @constCast(block.data);
    }
};

const SliceReader = struct {
    data: []const u8,
    pos: usize = 0,
    pub fn read(self: *SliceReader, buf: []u8) !usize {
        const n = @min(buf.len, self.data.len - self.pos);
        @memcpy(buf[0..n], self.data[self.pos..][0..n]);
        self.pos += n;
        return n;
    }
};

const freshStore = fetcher_mod.testStore;

fn cleanup(path: []const u8) void {
    std.Io.Dir.cwd().deleteTree(std.Io.Threaded.global_single_threaded.io(), path) catch {};
}

test "keeper: copies a whole file, kept, and a second copy fetches nothing" {
    const a_path = "test_keeper_a";
    const b_path = "test_keeper_b";
    var a = try freshStore(a_path);
    defer {
        a.deinit();
        cleanup(a_path);
    }
    var b = try freshStore(b_path);
    defer {
        b.deinit();
        cleanup(b_path);
    }
    // A 3 MiB file of varied bytes in A: several leaves under parents.
    const data = try testing.allocator.alloc(u8, 3 << 20);
    defer testing.allocator.free(data);
    var prng = std.Random.DefaultPrng.init(7);
    prng.random().bytes(data);
    var reader = SliceReader{ .data = data };
    var builder = storage.dag.DagBuilder{ .allocator = testing.allocator, .store = &a, .layout = .Balanced };
    const root_slice = try builder.build(&reader);
    defer testing.allocator.free(root_slice);
    const root: Cid = root_slice[0..32].*;

    const peer: NodeID = .{ .bytes = [_]u8{4} ** 32 };
    var net: StoreNet = .{ .from = &a, .peer = peer };
    var f = fetcher_mod.Fetcher.init(&b, net.transport());
    var go: std.atomic.Value(bool) = .init(true);
    const c = try copy(testing.allocator, &f, &b, root, &.{peer}, null, &go);
    try testing.expect(c.blocks > 3);
    try testing.expect(try walk.isComplete(testing.allocator, &b, &root));
    try testing.expectEqual(storage.engine.StorageEngine.Where.kept, b.locate(&root));

    // Held already: nothing fetched.
    const before = net.served.load(.monotonic);
    const again = try copy(testing.allocator, &f, &b, root, &.{peer}, null, &go);
    try testing.expectEqual(@as(usize, 0), again.blocks);
    try testing.expectEqual(before, net.served.load(.monotonic));

    // Cancelled: stops with an error, nothing hangs.
    var c_path_store = try freshStore("test_keeper_c");
    defer {
        c_path_store.deinit();
        cleanup("test_keeper_c");
    }
    var f2 = fetcher_mod.Fetcher.init(&c_path_store, net.transport());
    var stop: std.atomic.Value(bool) = .init(false);
    try testing.expectError(error.Cancelled, copy(testing.allocator, &f2, &c_path_store, root, &.{peer}, null, &stop));
}

test "keeper: a round copies each provider's wants and reports them" {
    const a_path = "test_keeper_round_a";
    const b_path = "test_keeper_round_b";
    var a = try freshStore(a_path);
    defer {
        a.deinit();
        cleanup(a_path);
    }
    var b = try freshStore(b_path);
    defer {
        b.deinit();
        cleanup(b_path);
    }
    var reader = SliceReader{ .data = "a small file kept by the keeper" };
    var builder = storage.dag.DagBuilder{ .allocator = testing.allocator, .store = &a, .layout = .Balanced };
    const root_slice = try builder.build(&reader);
    defer testing.allocator.free(root_slice);
    const root: Cid = root_slice[0..32].*;
    const missing: Cid = [_]u8{9} ** 32;
    const peer: NodeID = .{ .bytes = [_]u8{4} ** 32 };
    var net: StoreNet = .{ .from = &a, .peer = peer };
    var f = fetcher_mod.Fetcher.init(&b, net.transport());

    const Wants = struct {
        roots: [2]Cid,
        peer: NodeID,
        ok: usize = 0,
        failed: usize = 0,
        lost: usize = 0,
        fn wants(ctx: *anyopaque, allocator: std.mem.Allocator, out: *std.ArrayList(Want), max: usize) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            for (self.roots[0..@min(max, 2)]) |r| try out.append(allocator, Want.init(r, &.{self.peer}));
        }
        fn done(ctx: *anyopaque, _: Cid, outcome: Outcome) void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            switch (outcome) {
                .kept => self.ok += 1,
                .failed => self.failed += 1,
                .lost => self.lost += 1,
            }
        }
    };
    var w: Wants = .{ .roots = .{ root, missing }, .peer = peer };
    var k = Keeper.init(testing.allocator, &f, &b);
    try k.register(.{ .ctx = &w, .wantsFn = Wants.wants, .doneFn = Wants.done });
    k.worker.running.store(true, .release); // a round without the thread
    try testing.expectEqual(@as(usize, 1), try k.round());
    try testing.expectEqual(@as(usize, 1), w.ok);
    try testing.expectEqual(@as(usize, 1), w.failed);
    try testing.expectEqual(storage.engine.StorageEngine.Where.kept, b.locate(&root));
}

/// Runs one keeper round for `want` over a fake network where `peers`
/// answer: returns the outcome the provider heard.
fn lostRound(path: []const u8, net: *fetcher_mod.FakeNet, hints: []const NodeID, author: ?NodeID) !Outcome {
    var b = try freshStore(path);
    defer {
        b.deinit();
        cleanup(path);
    }
    const missing: Cid = [_]u8{9} ** 32;
    const Wants = struct {
        want: Want,
        got: ?Outcome = null,
        fn wants(ctx: *anyopaque, allocator: std.mem.Allocator, out: *std.ArrayList(Want), _: usize) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            try out.append(allocator, self.want);
        }
        fn done(ctx: *anyopaque, _: Cid, outcome: Outcome) void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.got = outcome;
        }
    };
    var w: Wants = .{ .want = Want.init(missing, hints) };
    w.want.author = author;
    var f = fetcher_mod.Fetcher.init(&b, net.transport());
    var k = Keeper.init(testing.allocator, &f, &b);
    try k.register(.{ .ctx = &w, .wantsFn = Wants.wants, .doneFn = Wants.done });
    k.worker.running.store(true, .release);
    _ = try k.round();
    return w.got.?;
}

test "keeper: lost when the author and every reachable holder say not found" {
    const FakeNet = fetcher_mod.FakeNet;
    const author = NodeID{ .bytes = [_]u8{1} ** 32 };
    const other = NodeID{ .bytes = [_]u8{2} ** 32 };
    const down = NodeID{ .bytes = [_]u8{3} ** 32 };
    var peers = [_]FakeNet.Peer{ .{ .id = author, .has = false }, .{ .id = other, .has = false }, .{ .id = down, .down = true } };
    var net: FakeNet = .{ .peers = &peers };

    try testing.expectEqual(Outcome.lost, try lostRound("test_keeper_lost_a", &net, &.{ author, other }, author));
    // A holder that can't be reached doesn't count: still lost.
    try testing.expectEqual(Outcome.lost, try lostRound("test_keeper_lost_b", &net, &.{ author, other, down }, author));
    // The author can't be reached: never lost.
    var away = [_]FakeNet.Peer{ .{ .id = author, .down = true }, .{ .id = other, .has = false } };
    var net_away: FakeNet = .{ .peers = &away };
    try testing.expectEqual(Outcome.failed, try lostRound("test_keeper_lost_e", &net_away, &.{ author, other }, author));
    // The author isn't among the holders asked: failed.
    try testing.expectEqual(Outcome.failed, try lostRound("test_keeper_lost_c", &net, &.{other}, author));
    try testing.expectEqual(Outcome.failed, try lostRound("test_keeper_lost_d", &net, &.{ author, other }, null));
}
