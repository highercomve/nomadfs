const std = @import("std");
const nomadfs = @import("nomadfs");
const TestPeer = @import("test_helpers").TestPeer;
const DhtNode = nomadfs.net.discovery.Node;
const StorageEngine = nomadfs.storage.engine.StorageEngine;
const BlockManager = nomadfs.cluster.BlockManager;
const SwarmFolder = nomadfs.fs.SwarmFolder;

test "swarm backup: a backup device serves files while their author is offline" {
    std.debug.print("\n=== Running Test: swarm backup ===\n", .{});
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const cwd = std.Io.Dir.cwd();
    const dirs = [_][]const u8{ "test_backup_a", "test_backup_b", "test_backup_c", "test_backup_src" };
    for (dirs) |d| cwd.deleteTree(io, d) catch {};
    defer for (dirs) |d| cwd.deleteTree(io, d) catch {};
    try cwd.createDirPath(io, "test_backup_src");

    // Several chunks, so the backup copies a whole DAG, not one block.
    const video = try allocator.alloc(u8, 2_500_000);
    defer allocator.free(video);
    var prng = std.Random.DefaultPrng.init(7);
    prng.random().bytes(video);
    try cwd.writeFile(io, .{ .sub_path = "test_backup_src/trip.mp4", .data = video });

    var store_a = try StorageEngine.init(allocator, "test_backup_a");
    defer store_a.deinit();
    var store_b = try StorageEngine.init(allocator, "test_backup_b");
    defer store_b.deinit();
    var store_c = try StorageEngine.init(allocator, "test_backup_c");
    defer store_c.deinit();

    // A adds the file (a phone), B is the backup (a home server), C reads
    // it later (a laptop) and only knows B.
    var peer_a = try TestPeer.init(allocator, 13170);
    defer peer_a.deinit();
    var peer_b = try TestPeer.init(allocator, 13171);
    defer peer_b.deinit();
    var peer_c = try TestPeer.init(allocator, 13172);
    defer peer_c.deinit();
    var dht_a = DhtNode.init(allocator, peer_a.manager, peer_a.config.node.swarm_key);
    defer dht_a.deinit();
    var dht_b = DhtNode.init(allocator, peer_b.manager, peer_b.config.node.swarm_key);
    defer dht_b.deinit();
    var dht_c = DhtNode.init(allocator, peer_c.manager, peer_c.config.node.swarm_key);
    defer dht_c.deinit();
    dht_a.block_store = &store_a;
    dht_b.block_store = &store_b;
    dht_c.block_store = &store_c;

    const swarm_a = try SwarmFolder.create(allocator, io, &store_a, peer_a.manager.node_id, "Phone", "test_backup_a/manifest.json");
    defer swarm_a.destroy();
    const swarm_b = try SwarmFolder.create(allocator, io, &store_b, peer_b.manager.node_id, "Server", "test_backup_b/manifest.json");
    defer swarm_b.destroy();
    const swarm_c = try SwarmFolder.create(allocator, io, &store_c, peer_c.manager.node_id, "Laptop", "test_backup_c/manifest.json");
    defer swarm_c.destroy();
    dht_a.swarm_source = swarm_a.source();
    dht_b.swarm_source = swarm_b.source();
    dht_c.swarm_source = swarm_c.source();

    peer_a.manager.setConnectionHandler(&dht_a, DhtNode.serve);
    peer_b.manager.setConnectionHandler(&dht_b, DhtNode.serve);
    peer_c.manager.setConnectionHandler(&dht_c, DhtNode.serve);
    defer peer_b.stop();
    defer peer_c.stop();
    try peer_a.start();
    try peer_b.start();
    try peer_c.start();
    nomadfs.sync.sleep(100 * std.time.ns_per_ms);
    {
        const conn = try peer_b.manager.connectToPeer(peer_a.listen_addr, peer_b.config.node.swarm_key, peer_a.manager.node_id);
        defer conn.deinit();
        try dht_b.ping(conn);
    }
    {
        const conn = try peer_c.manager.connectToPeer(peer_b.listen_addr, peer_c.config.node.swarm_key, peer_b.manager.node_id);
        defer conn.deinit();
        try dht_c.ping(conn);
    }
    nomadfs.sync.sleep(200 * std.time.ns_per_ms);

    const bm_a = try BlockManager.init(allocator, .{ .network = peer_a.manager, .dht = &dht_a, .storage = &store_a });
    defer bm_a.deinit();
    const bm_b = try BlockManager.init(allocator, .{ .network = peer_b.manager, .dht = &dht_b, .storage = &store_b });
    defer bm_b.deinit();
    const bm_c = try BlockManager.init(allocator, .{ .network = peer_c.manager, .dht = &dht_c, .storage = &store_c });
    defer bm_c.deinit();
    swarm_a.block_manager = bm_a;
    swarm_b.block_manager = bm_b;
    swarm_c.block_manager = bm_c;

    try swarm_a.addFile("", "trip.mp4", "test_backup_src/trip.mp4");
    try std.testing.expect(try swarm_b.syncNow() > 0);

    // One backup round (the thread runs these every sync interval).
    swarm_b.backup_enabled.store(true, .release);
    try swarm_b.backupRound();
    const status = swarm_b.backupStatus();
    try std.testing.expectEqual(@as(usize, 1), status.files);
    try std.testing.expectEqual(@as(usize, 1), status.backed_up);
    try std.testing.expectEqual(@as(u64, video.len), status.bytes);
    try std.testing.expectEqual(@as(usize, 0), status.unreachable_files);

    // A goes offline; C gets the listing and the bytes from B.
    peer_a.stop();
    try std.testing.expect(try swarm_c.syncNow() > 0);
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const items = try swarm_c.list(arena_state.allocator(), "");
    try std.testing.expectEqual(@as(usize, 1), items.len);
    try std.testing.expectEqualStrings("Phone", items[0].author);
    const got = try allocator.alloc(u8, video.len);
    defer allocator.free(got);
    const n = try swarm_c.readAt(allocator, items[0].cid.?, items[0].author_id.?, 0, got);
    try std.testing.expectEqual(video.len, n);
    try std.testing.expectEqualSlices(u8, video, got);

    // B remembers what it copied across a restart.
    const reloaded = try SwarmFolder.create(allocator, io, &store_b, peer_b.manager.node_id, "Server", "test_backup_b/manifest.json");
    defer reloaded.destroy();
    try reloaded.setBackup(true);
    try std.testing.expectEqual(@as(usize, 1), reloaded.backupStatus().backed_up);
}
