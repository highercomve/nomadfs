const std = @import("std");
const nomadfs = @import("nomadfs");
const TestPeer = @import("test_helpers").TestPeer;
const DhtNode = nomadfs.net.discovery.Node;
const StorageEngine = nomadfs.storage.engine.StorageEngine;
const BlockManager = nomadfs.cluster.BlockManager;
const SwarmFolder = nomadfs.fs.SwarmFolder;

test "swarm folder: two devices add, read, rename and delete in one folder" {
    std.debug.print("\n=== Running Test: swarm folder ===\n", .{});
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const cwd = std.Io.Dir.cwd();
    const dirs = [_][]const u8{ "test_swarm_a", "test_swarm_b", "test_swarm_src" };
    for (dirs) |d| cwd.deleteTree(io, d) catch {};
    defer for (dirs) |d| cwd.deleteTree(io, d) catch {};
    try cwd.createDirPath(io, "test_swarm_src");

    const report = try allocator.alloc(u8, 1_500_000);
    defer allocator.free(report);
    var prng = std.Random.DefaultPrng.init(42);
    prng.random().bytes(report);
    try cwd.writeFile(io, .{ .sub_path = "test_swarm_src/report.pdf", .data = report });
    try cwd.writeFile(io, .{ .sub_path = "test_swarm_src/todo.txt", .data = "buy dates" });

    var store_a = try StorageEngine.init(allocator, "test_swarm_a");
    defer store_a.deinit();
    var store_b = try StorageEngine.init(allocator, "test_swarm_b");
    defer store_b.deinit();

    var peer_a = try TestPeer.init(allocator, 13150);
    defer peer_a.deinit();
    var peer_b = try TestPeer.init(allocator, 13151);
    defer peer_b.deinit();
    var dht_a = DhtNode.init(allocator, peer_a.manager, peer_a.config.node.swarm_key);
    defer dht_a.deinit();
    var dht_b = DhtNode.init(allocator, peer_b.manager, peer_b.config.node.swarm_key);
    defer dht_b.deinit();
    dht_a.block_store = &store_a;
    dht_b.block_store = &store_b;

    const swarm_a = try SwarmFolder.create(allocator, io, &store_a, peer_a.manager.node_id, "Desk", "test_swarm_a/manifest.json");
    defer swarm_a.destroy();
    const swarm_b = try SwarmFolder.create(allocator, io, &store_b, peer_b.manager.node_id, "Phone", "test_swarm_b/manifest.json");
    defer swarm_b.destroy();
    dht_a.swarm_source = swarm_a.source();
    dht_b.swarm_source = swarm_b.source();

    peer_a.manager.setConnectionHandler(&dht_a, DhtNode.serve);
    peer_b.manager.setConnectionHandler(&dht_b, DhtNode.serve);
    defer peer_a.stop();
    defer peer_b.stop();
    try peer_a.start();
    try peer_b.start();
    nomadfs.sync.sleep(100 * std.time.ns_per_ms);
    {
        const conn = try peer_b.manager.connectToPeer(peer_a.listen_addr, peer_b.config.node.swarm_key, peer_a.manager.node_id);
        defer conn.deinit();
        try dht_b.ping(conn);
    }
    nomadfs.sync.sleep(200 * std.time.ns_per_ms);

    const bm_a = try BlockManager.init(allocator, .{ .network = peer_a.manager, .dht = &dht_a, .storage = &store_a });
    defer bm_a.deinit();
    const bm_b = try BlockManager.init(allocator, .{ .network = peer_b.manager, .dht = &dht_b, .storage = &store_b });
    defer bm_b.deinit();
    swarm_a.block_manager = bm_a;
    swarm_b.block_manager = bm_b;

    // A adds a file under a folder; B sees it after one sync.
    try swarm_a.addFile("work", "report.pdf", "test_swarm_src/report.pdf");
    try std.testing.expect(try swarm_b.syncNow() > 0);
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const top = try swarm_b.list(arena, "");
    try std.testing.expectEqual(@as(usize, 1), top.len);
    try std.testing.expectEqualStrings("work", top[0].name);
    try std.testing.expect(top[0].dir);
    const work = try swarm_b.list(arena, "work");
    try std.testing.expectEqualStrings("report.pdf", work[0].name);
    try std.testing.expectEqualStrings("Desk", work[0].author);

    // B reads a range from A on demand: nothing of it was copied before.
    try std.testing.expect(!store_b.has(&work[0].cid.?));
    var buf: [4096]u8 = undefined;
    const n = try swarm_b.readAt(allocator, work[0].cid.?, work[0].author_id.?, 1_000_000, &buf);
    try std.testing.expectEqualSlices(u8, report[1_000_000..][0..n], buf[0..n]);

    // B renames it and adds its own file; A picks both up.
    try swarm_b.rename("work/report.pdf", "Q3 report.pdf");
    try swarm_b.addFile("", "todo.txt", "test_swarm_src/todo.txt");
    try std.testing.expect(try swarm_a.syncNow() > 0);
    const a_work = try swarm_a.list(arena, "work");
    try std.testing.expectEqual(@as(usize, 1), a_work.len);
    try std.testing.expectEqualStrings("Q3 report.pdf", a_work[0].name);
    const a_top = try swarm_a.list(arena, "");
    try std.testing.expectEqual(@as(usize, 2), a_top.len);

    // A deletes the folder; the delete reaches B.
    try swarm_a.remove("work");
    _ = try swarm_b.syncNow();
    const b_top = try swarm_b.list(arena, "");
    try std.testing.expectEqual(@as(usize, 1), b_top.len);
    try std.testing.expectEqualStrings("todo.txt", b_top[0].name);

    // The manifest survives a restart.
    const reloaded = try SwarmFolder.create(allocator, io, &store_b, peer_b.manager.node_id, "Phone", "test_swarm_b/manifest.json");
    defer reloaded.destroy();
    const again = try reloaded.list(arena, "");
    try std.testing.expectEqual(@as(usize, 1), again.len);
}
