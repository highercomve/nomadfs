//! A photo deleted on the phone before any backup device copied it: real
//! nodes (loopback TCP) with a phone that imports its Camera share into the
//! swarm folder, a backup device whose keeper copies it, and a plain member.
//! The backup device removes an entry whose data is on no device (src/fs/
//! swarm.zig `lostRoot`), and only then. The pieces are unit-tested with a
//! fake network; this runs them over the wire.

const std = @import("std");
const nomadfs = @import("nomadfs");
const TestPeer = @import("test_helpers").TestPeer;
const DhtNode = nomadfs.net.discovery.Node;
const StorageEngine = nomadfs.storage.engine.StorageEngine;
const BlockManager = nomadfs.cluster.BlockManager;
const Keeper = nomadfs.cluster.keeper.Keeper;
const SwarmFolder = nomadfs.fs.SwarmFolder;
const ShareIndex = nomadfs.fs.ShareIndex;
const BackupImport = nomadfs.fs.BackupImport;

const testing = std.testing;
const photo_path = "Pixel/Camera/a.jpg";

fn alwaysAllowed() bool {
    return true;
}

/// One real node: store, listener, discovery, swarm folder, block manager.
const Node = struct {
    allocator: std.mem.Allocator,
    dir: []u8,
    store: StorageEngine,
    peer: TestPeer,
    dht: DhtNode,
    swarm: *SwarmFolder,
    bm: *BlockManager,
    /// Phone only: the shares and the import of the backup-marked one.
    shares: ?*ShareIndex = null,
    imp: ?*BackupImport = null,

    fn create(allocator: std.mem.Allocator, dir: []const u8, device: []const u8, port: u16) !*Node {
        const io = std.Io.Threaded.global_single_threaded.io();
        const self = try allocator.create(Node);
        errdefer allocator.destroy(self);
        self.allocator = allocator;
        self.shares = null;
        self.imp = null;
        self.dir = try allocator.dupe(u8, dir);
        errdefer allocator.free(self.dir);
        std.Io.Dir.cwd().deleteTree(io, dir) catch {};
        self.store = try StorageEngine.init(allocator, dir);
        errdefer self.store.deinit();
        self.peer = try TestPeer.init(allocator, port);
        errdefer self.peer.deinit();
        self.dht = DhtNode.init(allocator, self.peer.manager, self.peer.config.node.swarm_key);
        errdefer self.dht.deinit();
        self.dht.block_store = &self.store;
        const manifest = try std.fmt.allocPrint(allocator, "{s}/manifest.json", .{dir});
        defer allocator.free(manifest);
        self.swarm = try SwarmFolder.create(allocator, io, &self.store, self.peer.manager.node_id, device, manifest);
        errdefer self.swarm.destroy();
        self.dht.swarm_source = self.swarm.source();
        self.peer.manager.setConnectionHandler(&self.dht, DhtNode.serve);
        try self.peer.start();
        self.bm = try BlockManager.init(allocator, .{ .network = self.peer.manager, .dht = &self.dht, .storage = &self.store });
        self.swarm.block_manager = self.bm;
        return self;
    }

    fn destroy(self: *Node) void {
        self.peer.stop();
        if (self.imp) |i| i.destroy();
        if (self.shares) |s| s.destroy();
        self.bm.deinit();
        self.swarm.destroy();
        self.dht.deinit();
        self.peer.deinit();
        self.store.deinit();
        std.Io.Dir.cwd().deleteTree(std.Io.Threaded.global_single_threaded.io(), self.dir) catch {};
        self.allocator.free(self.dir);
        self.allocator.destroy(self);
    }

    fn id(self: *const Node) nomadfs.net.id.NodeID {
        return self.peer.manager.node_id;
    }

    /// Phone: shares `share_dir` as Camera and marks it for backup.
    fn makePhone(self: *Node, share_dir: []const u8) !void {
        const io = std.Io.Threaded.global_single_threaded.io();
        std.Io.Dir.cwd().deleteTree(io, share_dir) catch {};
        try std.Io.Dir.cwd().createDirPath(io, share_dir);
        const imported = try std.fmt.allocPrint(self.allocator, "{s}/imported", .{self.dir});
        defer self.allocator.free(imported);
        const index = try ShareIndex.create(self.allocator, io, &self.store);
        self.shares = index;
        try index.add("Camera", share_dir);
        try index.setBackup("Camera", true);
        self.imp = try BackupImport.create(self.allocator, io, self.swarm, index, &self.store, "Pixel", imported, alwaysAllowed);
    }

    /// The share is rescanned and what is new goes into the swarm folder;
    /// returns how many files that added.
    fn rescanImport(self: *Node) !usize {
        self.shares.?.rescanAll();
        return self.imp.?.run();
    }
};

/// Phone, backup device and a plain member, all knowing each other.
const Net = struct {
    allocator: std.mem.Allocator,
    phone: *Node,
    backup: *Node,
    reader: *Node,
    share_dir: []const u8,
    src_dir: []const u8,

    fn create(allocator: std.mem.Allocator, comptime tag: []const u8, port: u16) !*Net {
        const self = try allocator.create(Net);
        errdefer allocator.destroy(self);
        self.allocator = allocator;
        self.share_dir = "test_lost_" ++ tag ++ "_camera";
        self.src_dir = "test_lost_" ++ tag ++ "_src";
        self.phone = try Node.create(allocator, "test_lost_" ++ tag ++ "_phone", "Pixel", port);
        errdefer self.phone.destroy();
        self.backup = try Node.create(allocator, "test_lost_" ++ tag ++ "_backup", "Server", port + 1);
        errdefer self.backup.destroy();
        self.reader = try Node.create(allocator, "test_lost_" ++ tag ++ "_reader", "Laptop", port + 2);
        errdefer self.reader.destroy();
        try self.phone.makePhone(self.share_dir);

        // Everyone pings everyone: each learns the others' addresses and roles.
        const all = [_]*Node{ self.phone, self.backup, self.reader };
        for (all) |from| for (all) |to| {
            if (from == to) continue;
            const conn = try from.peer.manager.connectToPeer(to.peer.listen_addr, from.peer.config.node.swarm_key, to.id());
            defer conn.deinit();
            try from.dht.ping(conn);
        };
        nomadfs.sync.sleep(200 * std.time.ns_per_ms);

        try self.backup.swarm.setBackup(true);
        self.backup.swarm.lost_rounds = 3;
        self.backup.swarm.lost_span_ms = 0; // each test sets what it checks
        return self;
    }

    fn destroy(self: *Net) void {
        self.reader.destroy();
        self.backup.destroy();
        self.phone.destroy();
        std.Io.Dir.cwd().deleteTree(std.Io.Threaded.global_single_threaded.io(), self.share_dir) catch {};
        self.allocator.destroy(self);
    }

    /// Writes `len` random bytes (from `seed`) as `name` in the Camera folder.
    fn writePhoto(self: *Net, name: []const u8, seed: u64, len: usize) ![]u8 {
        const io = std.Io.Threaded.global_single_threaded.io();
        const data = try self.allocator.alloc(u8, len);
        errdefer self.allocator.free(data);
        var prng = std.Random.DefaultPrng.init(seed);
        prng.random().bytes(data);
        var buf: [128]u8 = undefined;
        const path = try std.fmt.bufPrint(&buf, "{s}/{s}", .{ self.share_dir, name });
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = data });
        return data;
    }

    fn deletePhoto(self: *Net, name: []const u8) !void {
        var buf: [128]u8 = undefined;
        const path = try std.fmt.bufPrint(&buf, "{s}/{s}", .{ self.share_dir, name });
        try std.Io.Dir.cwd().deleteFile(std.Io.Threaded.global_single_threaded.io(), path);
    }

    /// The photo is imported on the phone and the backup device and the
    /// reader learn of it.
    fn importPhoto(self: *Net) !void {
        try testing.expectEqual(@as(usize, 1), try self.phone.rescanImport());
        try testing.expect(self.phone.swarm.fileInfo(photo_path) != null);
        try self.sync(self.backup);
        try self.sync(self.reader);
        try testing.expect(self.backup.swarm.fileInfo(photo_path) != null);
        try testing.expect(self.reader.swarm.fileInfo(photo_path) != null);
    }

    fn sync(_: *Net, node: *Node) !void {
        _ = try node.swarm.syncNow();
    }

    /// Keeper rounds on the backup device, one after the other.
    fn rounds(self: *Net, n: usize) !void {
        for (0..n) |_| try self.backup.swarm.backupRound();
    }

    /// Time passing between two keeper rounds (a minute apart in the app):
    /// the fetcher's memory of recent misses and its backoffs have run out.
    fn timePasses(self: *Net) void {
        const f = &self.backup.bm.fetcher.?;
        f.mutex.lock();
        defer f.mutex.unlock();
        f.block_miss_count = 0;
        f.root_miss_count = 0;
        for (f.peers[0..f.peer_count]) |*p| p.down_until = 0;
    }

    /// The bytes of the photo, read from `node` (on demand when it has not got
    /// them: the author, then the backup devices, then anyone).
    fn readAll(self: *Net, node: *Node, want: []const u8) !void {
        const info = node.swarm.fileInfo(photo_path) orelse return error.FileNotFound;
        const got = try self.allocator.alloc(u8, want.len);
        defer self.allocator.free(got);
        const n = try node.swarm.readAt(self.allocator, info.cid, info.author, 0, got);
        try testing.expectEqual(want.len, n);
        try testing.expectEqualSlices(u8, want, got);
    }

    fn live(_: *Net, node: *Node) bool {
        return node.swarm.fileInfo(photo_path) != null;
    }

    /// The entry is a tombstone made by the backup device.
    fn removedByBackup(self: *Net, node: *Node) bool {
        node.swarm.mutex.lock();
        defer node.swarm.mutex.unlock();
        const e = node.swarm.manifest.get(photo_path) orelse return false;
        return e.deleted and std.mem.eql(u8, &e.version.device, &self.backup.id().bytes);
    }

    /// Replaces a block of `node`'s store with garbage: the node is reachable
    /// but answers a request for it with an error.
    fn corruptBlock(_: *Net, node: *Node, cid: [32]u8) !void {
        const io = std.Io.Threaded.global_single_threaded.io();
        const hex = std.fmt.bytesToHex(cid, .lower);
        var buf: [256]u8 = undefined;
        const path = try std.fmt.bufPrint(&buf, "{s}/{s}", .{ node.dir, &hex });
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = "garbage, not the block" });
    }

    fn repairBlock(_: *Net, node: *Node, cid: [32]u8) void {
        const io = std.Io.Threaded.global_single_threaded.io();
        const hex = std.fmt.bytesToHex(cid, .lower);
        var buf: [256]u8 = undefined;
        const path = std.fmt.bufPrint(&buf, "{s}/{s}", .{ node.dir, &hex }) catch return;
        std.Io.Dir.cwd().deleteFile(io, path) catch {};
    }
};

test "lost file: a photo deleted on the phone before the backup copied it is removed everywhere" {
    std.debug.print("\n=== Running Test: lost file, removed (keeper thread) ===\n", .{});
    const allocator = testing.allocator;
    const net = try Net.create(allocator, "gone", 13600);
    defer net.destroy();
    const data = try net.writePhoto("a.jpg", 1, 1_200_000);
    defer allocator.free(data);
    try net.importPhoto();

    // The photo goes before the backup device's keeper has run at all.
    try net.deletePhoto("a.jpg");
    try testing.expectEqual(@as(usize, 0), try net.phone.rescanImport());
    try testing.expect(net.live(net.backup));

    // The backup device's keeper runs on its own thread (woken, not timed).
    const b = net.backup;
    b.swarm.lost_span_ms = 300;
    var keeper = Keeper.init(allocator, &b.bm.fetcher.?, &b.store);
    keeper.interval_ns = 3600 * std.time.ns_per_s;
    try keeper.register(b.swarm.keeperProvider());
    b.swarm.keeper = &keeper;
    try keeper.start();
    defer {
        keeper.stop();
        b.swarm.keeper = null;
    }
    var tries: usize = 0;
    while (!net.removedByBackup(b)) : (tries += 1) {
        if (tries >= 200) return error.TimedOut; // 10 s
        keeper.wake();
        nomadfs.sync.sleep(50 * std.time.ns_per_ms);
    }
    try testing.expect(!net.live(b));
    try testing.expectEqual(@as(usize, 0), b.swarm.backupStatus().backed_up);

    // The tombstone reaches the phone and the reader; nothing comes back.
    try net.sync(net.phone);
    try net.sync(net.reader);
    try testing.expect(!net.live(net.phone));
    try testing.expect(!net.live(net.reader));
    try testing.expect(net.removedByBackup(net.phone));
    try testing.expect(net.removedByBackup(net.reader));
    try testing.expectEqual(@as(usize, 0), try net.phone.rescanImport());
    try testing.expect(!net.live(net.phone));
}

test "lost file: exact rounds and time are needed, fewer or sooner leave it alone" {
    std.debug.print("\n=== Running Test: lost file, thresholds ===\n", .{});
    const allocator = testing.allocator;
    const net = try Net.create(allocator, "limits", 13610);
    defer net.destroy();
    const data = try net.writePhoto("a.jpg", 2, 300_000);
    defer allocator.free(data);
    try net.importPhoto();
    try net.deletePhoto("a.jpg");
    _ = try net.phone.rescanImport();

    // Time threshold: all the rounds are in, the span is not over.
    net.backup.swarm.lost_span_ms = 700;
    const started = nomadfs.sync.monotonicMillis();
    try net.rounds(5);
    if (nomadfs.sync.monotonicMillis() - started < 700) try testing.expect(net.live(net.backup));

    // The span runs out: the next round removes it.
    while (nomadfs.sync.monotonicMillis() - started < 700) nomadfs.sync.sleep(20 * std.time.ns_per_ms);
    try net.rounds(1);
    try testing.expect(net.removedByBackup(net.backup));

    // Round threshold (a second photo, span 0): two rounds leave it, the third removes it.
    try testing.expectEqual(@as(usize, 0), net.backup.swarm.backupStatus().backed_up);
    const second = try net.writePhoto("a.jpg", 3, 200_000);
    defer allocator.free(second);
    try testing.expectEqual(@as(usize, 1), try net.phone.rescanImport());
    try net.sync(net.backup);
    try testing.expect(net.live(net.backup));
    try net.deletePhoto("a.jpg");
    _ = try net.phone.rescanImport();
    net.backup.swarm.lost_span_ms = 0;
    try net.rounds(2);
    try testing.expect(net.live(net.backup));
    try net.rounds(1);
    try testing.expect(!net.live(net.backup));
}

test "lost file: a photo the backup copied stays and is read from it after the phone deleted it" {
    std.debug.print("\n=== Running Test: lost file, already copied ===\n", .{});
    const allocator = testing.allocator;
    const net = try Net.create(allocator, "copied", 13620);
    defer net.destroy();
    const data = try net.writePhoto("a.jpg", 4, 1_500_000);
    defer allocator.free(data);
    try net.importPhoto();

    try net.rounds(1);
    try testing.expectEqual(@as(usize, 1), net.backup.swarm.backupStatus().backed_up);

    // Deleted on the phone afterwards: backup, not mirror.
    try net.deletePhoto("a.jpg");
    try testing.expectEqual(@as(usize, 0), try net.phone.rescanImport());
    try net.rounds(6);
    try testing.expect(net.live(net.backup));
    try testing.expectEqual(@as(usize, 1), net.backup.swarm.backupStatus().backed_up);

    // The phone is away; the reader (which holds nothing of it) gets it from the backup.
    net.phone.peer.stop();
    try net.sync(net.reader);
    try testing.expect(net.live(net.reader));
    try testing.expect(!net.reader.store.has(&net.reader.swarm.fileInfo(photo_path).?.cid));
    try net.readAll(net.reader, data);
}

test "lost file: an author that is away never makes it lost" {
    std.debug.print("\n=== Running Test: lost file, author away ===\n", .{});
    const allocator = testing.allocator;
    const net = try Net.create(allocator, "away", 13630);
    defer net.destroy();
    const data = try net.writePhoto("a.jpg", 5, 300_000);
    defer allocator.free(data);
    try net.importPhoto();
    try net.deletePhoto("a.jpg");
    _ = try net.phone.rescanImport();

    // The phone is switched off; the reader is up and has nothing.
    net.phone.peer.stop();
    try net.rounds(8);
    net.timePasses();
    try net.rounds(8);
    try testing.expect(net.live(net.backup));
    try testing.expectEqual(@as(usize, 0), net.backup.swarm.backupStatus().backed_up);
    try testing.expect(net.backup.swarm.backupStatus().unreachable_files > 0);
}

test "lost file: another member that is away doesn't hold the removal back" {
    std.debug.print("\n=== Running Test: lost file, member away ===\n", .{});
    const allocator = testing.allocator;
    const net = try Net.create(allocator, "member", 13640);
    defer net.destroy();
    const data = try net.writePhoto("a.jpg", 6, 300_000);
    defer allocator.free(data);
    try net.importPhoto();
    try net.deletePhoto("a.jpg");
    _ = try net.phone.rescanImport();

    net.reader.peer.stop();
    try net.rounds(2);
    try testing.expect(net.live(net.backup));
    try net.rounds(1);
    try testing.expect(net.removedByBackup(net.backup));
    try net.sync(net.phone);
    try testing.expect(!net.live(net.phone));
}

test "lost file: a reachable member that answers with an error blocks the removal" {
    std.debug.print("\n=== Running Test: lost file, member answers an error ===\n", .{});
    const allocator = testing.allocator;
    const net = try Net.create(allocator, "broken", 13650);
    defer net.destroy();
    // One block, so the file's CID is the only one anybody is asked for.
    const data = try net.writePhoto("a.jpg", 7, 30_000);
    defer allocator.free(data);
    try net.importPhoto();
    try net.deletePhoto("a.jpg");
    _ = try net.phone.rescanImport();

    // The reader holds a damaged copy of the block: reachable, but it fails.
    const cid = net.backup.swarm.fileInfo(photo_path).?.cid;
    try net.corruptBlock(net.reader, cid);
    for (0..6) |_| {
        net.timePasses(); // a minute apart: asked again each time
        try net.rounds(1);
        try testing.expect(net.live(net.backup));
    }
    try testing.expectEqual(@as(usize, 0), net.backup.swarm.backupStatus().backed_up);

    // Repaired (it says "not found" now), the removal goes ahead.
    net.repairBlock(net.reader, cid);
    net.timePasses();
    try net.rounds(2);
    try testing.expect(net.live(net.backup));
    try net.rounds(1);
    try testing.expect(net.removedByBackup(net.backup));
}

test "lost file: a failed round in between starts the count over" {
    std.debug.print("\n=== Running Test: lost file, count restarts ===\n", .{});
    const allocator = testing.allocator;
    const net = try Net.create(allocator, "restart", 13660);
    defer net.destroy();
    const data = try net.writePhoto("a.jpg", 8, 30_000);
    defer allocator.free(data);
    try net.importPhoto();
    try net.deletePhoto("a.jpg");
    _ = try net.phone.rescanImport();
    const cid = net.backup.swarm.fileInfo(photo_path).?.cid;

    try net.rounds(2); // lost twice
    try testing.expect(net.live(net.backup));
    net.timePasses();
    try net.corruptBlock(net.reader, cid);
    try net.rounds(1); // a holder fails: not lost this time
    net.repairBlock(net.reader, cid);
    try testing.expect(net.live(net.backup));
    try net.rounds(2); // lost twice again: still short of three in a row
    try testing.expect(net.live(net.backup));
    try net.rounds(1);
    try testing.expect(net.removedByBackup(net.backup));
}

test "lost file: the reader's read cache has all of it, so the backup copies it from the reader" {
    std.debug.print("\n=== Running Test: lost file, copied from a cache ===\n", .{});
    const allocator = testing.allocator;
    const net = try Net.create(allocator, "cache", 13670);
    defer net.destroy();
    const data = try net.writePhoto("a.jpg", 9, 1_500_000);
    defer allocator.free(data);
    try net.importPhoto();

    // The reader reads the whole photo from the phone, then the phone deletes it.
    try net.readAll(net.reader, data);
    try net.deletePhoto("a.jpg");
    try testing.expectEqual(@as(usize, 0), try net.phone.rescanImport());
    try testing.expectEqual(@as(usize, 0), net.backup.swarm.backupStatus().backed_up);

    try net.rounds(1);
    try testing.expectEqual(@as(usize, 1), net.backup.swarm.backupStatus().backed_up);
    net.phone.peer.stop();
    net.reader.peer.stop();
    try net.rounds(5);
    try testing.expect(net.live(net.backup));

    // Readable from the backup device's own store alone.
    const info = net.backup.swarm.fileInfo(photo_path).?;
    const got = try allocator.alloc(u8, data.len);
    defer allocator.free(got);
    try testing.expectEqual(data.len, try net.backup.swarm.readLocal(allocator, info.cid, 0, got));
    try testing.expectEqualSlices(u8, data, got);
}

test "lost file: an edited photo's new version is imported and kept while the old one is lost" {
    std.debug.print("\n=== Running Test: lost file, edited photo ===\n", .{});
    const allocator = testing.allocator;
    const net = try Net.create(allocator, "edit", 13680);
    defer net.destroy();
    const first = try net.writePhoto("a.jpg", 10, 400_000);
    defer allocator.free(first);
    try net.importPhoto();
    const old_cid = net.backup.swarm.fileInfo(photo_path).?.cid;

    // Edited on the phone (a new size): the old content is gone from it.
    const second = try net.writePhoto("a.jpg", 11, 450_000);
    defer allocator.free(second);
    net.phone.shares.?.rescanAll();
    // The backup device hasn't heard of the edit: the old version is lost twice.
    try net.rounds(2);
    try testing.expect(net.live(net.backup));

    // The edit is imported and reaches the backup device; its keeper copies it.
    try testing.expectEqual(@as(usize, 1), try net.phone.imp.?.run());
    try net.sync(net.backup);
    const info = net.backup.swarm.fileInfo(photo_path) orelse return error.FileNotFound;
    try testing.expect(!std.mem.eql(u8, &info.cid, &old_cid));
    try net.rounds(5);
    try testing.expect(net.live(net.backup));
    try testing.expectEqual(@as(usize, 1), net.backup.swarm.backupStatus().backed_up);
    const got = try allocator.alloc(u8, second.len);
    defer allocator.free(got);
    try testing.expectEqual(second.len, try net.backup.swarm.readLocal(allocator, info.cid, 0, got));
    try testing.expectEqualSlices(u8, second, got);
}
