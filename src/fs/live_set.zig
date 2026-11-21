//! The live set: which roots this device must keep, and whether that
//! answer is still current when the collection comes to delete.

const std = @import("std");
const storage = @import("../storage/mod.zig");
const swarm_mod = @import("swarm.zig");
const shares_mod = @import("shares.zig");

const SwarmFolder = swarm_mod.SwarmFolder;
const ShareIndex = shares_mod.ShareIndex;
const CidSet = storage.dag.walk.CidSet;

/// The one place that answers "which roots must this device keep": the
/// swarm folder's live files (and deletes still inside the undo grace)
/// and every share's root. A new kind of root (e.g. CID-only puts, W1)
/// is added here, so the collection never deletes what it doesn't list.
pub const LiveSet = struct {
    pub const Reason = enum {
        /// The swarm folder hasn't pulled yet: it may be missing files.
        waiting_for_sync,
        /// A share has no root yet: its blocks are reachable from nothing.
        share_without_root,
        /// A share is being indexed: its root is about to change.
        share_indexing,
    };

    pub const Taken = union(enum) {
        not_ready: Reason,
        ready: Snapshot,
    };

    pub const Snapshot = struct {
        allocator: std.mem.Allocator,
        /// Every live swarm file's root, and files deleted here a moment ago.
        swarm_roots: [][32]u8,
        /// Every share's root.
        share_roots: [][32]u8,
        /// The swarm roots as a set: the files whose thumbnails stay.
        file_roots: CidSet,
        /// A delete still inside the undo grace was spared: collect again soon.
        sparing_recent: bool,
        /// The swarm folder's changeGeneration the roots came from.
        swarm_generation: u64,
        /// The share tokens collectionCutoff checks; null without a share index.
        share_snapshot: ?ShareIndex.Snapshot,
        /// Blocks newer than this at the take are spared.
        cutoff_s: i64,
        /// What the roots were taken from, checked again by sweepCutoff.
        swarm: *SwarmFolder,
        shares: ?*ShareIndex,

        pub fn deinit(self: *Snapshot) void {
            self.allocator.free(self.swarm_roots);
            self.allocator.free(self.share_roots);
            self.file_roots.deinit(self.allocator);
            if (self.share_snapshot) |snap| ShareIndex.freeSnapshot(self.allocator, snap.shares);
            self.* = undefined;
        }

        /// After claiming the sweep: null when the swarm folder or the
        /// share set moved since the take (the roots may be stale, skip).
        /// Otherwise the sweep cutoff, pinned back to any running scan's
        /// start (see ShareIndex.collectionCutoff).
        pub fn sweepCutoff(self: *const Snapshot) ?i64 {
            if (self.swarm.changeGeneration() != self.swarm_generation) return null;
            const snap = self.share_snapshot orelse return self.cutoff_s;
            return self.shares.?.collectionCutoff(snap, self.cutoff_s); // a share snapshot implies the index
        }
    };

    /// The roots to keep, or why they can't be told yet. A share without
    /// a root wins over one indexing, and both over the swarm folder
    /// waiting for a sync (the order the collection reports them in).
    /// The share snapshot is taken first: it starts the epoch the sweep
    /// cutoff is measured from. Free a ready snapshot with deinit.
    pub fn take(allocator: std.mem.Allocator, swarm: *SwarmFolder, shares: ?*ShareIndex, cutoff_s: i64) !Taken {
        var share_snap: ?ShareIndex.Snapshot = if (shares) |index| try index.collectionSnapshot(allocator) else null;
        errdefer if (share_snap) |snap| ShareIndex.freeSnapshot(allocator, snap.shares);
        const share_list: []shares_mod.Share = if (share_snap) |snap| snap.shares else &.{};
        var missing = false;
        var indexing = false;
        for (share_list) |sh| {
            missing = missing or sh.root == null;
            indexing = indexing or sh.indexing;
        }
        const reason: ?Reason = if (missing) .share_without_root else if (indexing) .share_indexing else null;
        if (reason) |r| {
            if (share_snap) |snap| ShareIndex.freeSnapshot(allocator, snap.shares);
            share_snap = null;
            return .{ .not_ready = r };
        }
        const live = (try swarm.liveRoots(allocator)) orelse {
            if (share_snap) |snap| ShareIndex.freeSnapshot(allocator, snap.shares);
            share_snap = null;
            return .{ .not_ready = .waiting_for_sync };
        };
        errdefer allocator.free(live.roots);

        const share_roots = try allocator.alloc([32]u8, share_list.len);
        errdefer allocator.free(share_roots);
        for (share_list, share_roots) |sh, *r| r.* = sh.root.?;

        var file_roots: CidSet = .empty;
        errdefer file_roots.deinit(allocator);
        for (live.roots) |r| try file_roots.put(allocator, r, {});

        return .{ .ready = .{
            .allocator = allocator,
            .swarm_roots = live.roots,
            .share_roots = share_roots,
            .file_roots = file_roots,
            .sparing_recent = live.sparing_recent,
            .swarm_generation = live.generation,
            .share_snapshot = share_snap,
            .cutoff_s = cutoff_s,
            .swarm = swarm,
            .shares = shares,
        } };
    }
};

const testing = std.testing;

const Fixture = struct {
    tmp: testing.TmpDir,
    store: storage.engine.StorageEngine,
    swarm: *SwarmFolder,
    shares: *ShareIndex,
    docs: []u8,

    fn open(self: *Fixture) !void {
        const allocator = testing.allocator;
        const io = testing.io;
        self.tmp = testing.tmpDir(.{});
        errdefer self.tmp.cleanup();
        try self.tmp.dir.createDirPath(io, "docs");
        try self.tmp.dir.createDirPath(io, "blocks");
        try self.tmp.dir.writeFile(io, .{ .sub_path = "docs/a.txt", .data = "alpha" });
        var path_buf: [std.fs.max_path_bytes]u8 = undefined;
        const base = path_buf[0..try self.tmp.dir.realPath(io, &path_buf)];
        const blocks = try std.fs.path.join(allocator, &.{ base, "blocks" });
        defer allocator.free(blocks);
        const manifest_path = try std.fs.path.join(allocator, &.{ base, "manifest.json" });
        defer allocator.free(manifest_path);
        self.docs = try std.fs.path.join(allocator, &.{ base, "docs" });
        errdefer allocator.free(self.docs);
        self.store = try storage.engine.StorageEngine.init(allocator, blocks);
        errdefer self.store.deinit();
        self.swarm = try SwarmFolder.create(allocator, io, &self.store, .{ .bytes = @splat(1) }, "Test", manifest_path);
        errdefer self.swarm.destroy();
        self.shares = try ShareIndex.create(allocator, io, &self.store);
    }

    fn close(self: *Fixture) void {
        self.shares.destroy();
        self.swarm.destroy();
        self.store.deinit();
        testing.allocator.free(self.docs);
        self.tmp.cleanup();
    }

    fn take(self: *Fixture, cutoff_s: i64) !LiveSet.Taken {
        return LiveSet.take(testing.allocator, self.swarm, self.shares, cutoff_s);
    }
};

test "LiveSet: not ready while waiting for sync, a share has no root, or one is indexing" {
    var f: Fixture = undefined;
    try f.open();
    defer f.close();

    // The folder hasn't pulled yet.
    try testing.expectEqual(LiveSet.Taken{ .not_ready = .waiting_for_sync }, try f.take(0));

    // Registered but never scanned: no root. That wins over waiting.
    try f.shares.register("docs", f.docs);
    try testing.expectEqual(LiveSet.Taken{ .not_ready = .share_without_root }, try f.take(0));
    f.swarm.reclaim_ready = true;
    try testing.expect(f.shares.remove("docs"));

    // Scanned, then a rescan running: indexing.
    try f.shares.add("docs", f.docs);
    {
        f.shares.mutex.lock();
        defer f.shares.mutex.unlock();
        f.shares.shares.items[0].indexing = true;
    }
    try testing.expectEqual(LiveSet.Taken{ .not_ready = .share_indexing }, try f.take(0));
}

test "LiveSet: a ready snapshot has the swarm, share and file roots" {
    var f: Fixture = undefined;
    try f.open();
    defer f.close();
    f.swarm.reclaim_ready = true;
    try f.shares.add("docs", f.docs);
    const kept = (try f.swarm.putBytes("keep.txt", "keep", null)).cid;
    const recent = (try f.swarm.putBytes("undo.txt", "undo", null)).cid;
    try f.swarm.remove("undo.txt");

    var taken = try f.take(500);
    try testing.expect(taken == .ready);
    var snap = &taken.ready;
    defer snap.deinit();
    try testing.expectEqual(@as(usize, 2), snap.swarm_roots.len);
    try testing.expect(snap.file_roots.contains(kept));
    // A delete inside the undo grace is still kept, and says so.
    try testing.expect(snap.file_roots.contains(recent));
    try testing.expect(snap.sparing_recent);
    const listed = try f.shares.snapshot(testing.allocator);
    defer ShareIndex.freeSnapshot(testing.allocator, listed);
    try testing.expectEqual(@as(usize, 1), snap.share_roots.len);
    try testing.expectEqualSlices(u8, &listed[0].root.?, &snap.share_roots[0]);
    try testing.expectEqual(@as(?i64, 500 - ShareIndex.cutoff_slack_s), snap.sweepCutoff());
}

test "LiveSet: sweepCutoff is null after a swarm edit or a share added" {
    var f: Fixture = undefined;
    try f.open();
    defer f.close();
    f.swarm.reclaim_ready = true;
    try f.shares.add("docs", f.docs);
    {
        var taken = try f.take(500);
        defer taken.ready.deinit();
        _ = try f.swarm.putBytes("new.txt", "new", null);
        try testing.expectEqual(null, taken.ready.sweepCutoff());
    }
    {
        var taken = try f.take(500);
        defer taken.ready.deinit();
        try f.shares.register("more", f.docs);
        try testing.expectEqual(null, taken.ready.sweepCutoff());
    }
}

test "LiveSet: a scan's start pins the cutoff; no share index keeps it" {
    var f: Fixture = undefined;
    try f.open();
    defer f.close();
    f.swarm.reclaim_ready = true;
    try f.shares.add("docs", f.docs);
    var taken = try f.take(100_000);
    defer taken.ready.deinit();
    {
        f.shares.mutex.lock();
        defer f.shares.mutex.unlock();
        f.shares.scan_started_s = 1000;
    }
    try testing.expectEqual(@as(?i64, 1000 - ShareIndex.cutoff_slack_s), taken.ready.sweepCutoff());
    f.shares.scan_started_s = null;

    var alone = try LiveSet.take(testing.allocator, f.swarm, null, 100_000);
    defer alone.ready.deinit();
    try testing.expectEqual(@as(?i64, 100_000), alone.ready.sweepCutoff());
}
