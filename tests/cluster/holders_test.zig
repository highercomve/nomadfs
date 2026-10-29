//! Stage 2 of the distribution layer: the holder registry (cluster/holders.zig).
//! A shares a folder, C learns that B keeps copies of A's folders
//! (noteKeeps, as a SHARES reply would say), B reads the file once so it
//! holds the blocks, A (the sharing device) is stopped, and C still reads
//! the file: through `forOrigin(A)`, from B.

const std = @import("std");
const nomadfs = @import("nomadfs");
const TestPeer = @import("test_helpers").TestPeer;
const DhtNode = nomadfs.net.discovery.Node;
const StorageEngine = nomadfs.storage.engine.StorageEngine;
const BlockManager = nomadfs.cluster.BlockManager;
const fs = nomadfs.fs;

test "holders: C reads a shared file from B while A, the sharing device, is down" {
    std.debug.print("\n=== Running Test: holders: read through the registry ===\n", .{});
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const cwd = std.Io.Dir.cwd();

    const dirs = [_][]const u8{ "test_holders_a", "test_holders_b", "test_holders_c", "test_holders_folder" };
    for (dirs) |d| cwd.deleteTree(io, d) catch {};
    defer for (dirs) |d| cwd.deleteTree(io, d) catch {};

    // One file, a few blocks between the three devices.
    const content = try allocator.alloc(u8, 900_000);
    defer allocator.free(content);
    var prng = std.Random.DefaultPrng.init(0x0304);
    prng.random().bytes(content);
    for (content, 0..) |*b, i| b.* ^= @truncate(i);
    try cwd.createDirPath(io, "test_holders_folder");
    try cwd.writeFile(io, .{ .sub_path = "test_holders_folder/video.bin", .data = content });

    var store_a = try StorageEngine.init(allocator, "test_holders_a");
    defer store_a.deinit();
    var store_b = try StorageEngine.init(allocator, "test_holders_b");
    defer store_b.deinit();
    var store_c = try StorageEngine.init(allocator, "test_holders_c");
    defer store_c.deinit();

    var peer_a = try TestPeer.init(allocator, 13210); // the sharing device
    defer peer_a.deinit();
    var peer_b = try TestPeer.init(allocator, 13211); // keeps a copy
    defer peer_b.deinit();
    var peer_c = try TestPeer.init(allocator, 13212); // reads
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

    const index = try fs.ShareIndex.create(allocator, io, &store_a);
    defer index.destroy();
    try index.add("Camera", "test_holders_folder");
    dht_a.share_source = index.source();

    for (
        [_]*DhtNode{ &dht_a, &dht_b, &dht_c },
        [_]*TestPeer{ &peer_a, &peer_b, &peer_c },
    ) |dht, peer| {
        peer.manager.setConnectionHandler(dht, DhtNode.serve);
    }
    defer peer_a.stop();
    defer peer_b.stop();
    defer peer_c.stop();
    try peer_a.start();
    try peer_b.start();
    try peer_c.start();
    nomadfs.sync.sleep(100 * std.time.ns_per_ms);

    // C meets both A and B; the registry only serves peers it can dial.
    {
        const conn = try peer_c.manager.connectToPeer(peer_a.listen_addr, peer_c.config.node.swarm_key, peer_a.manager.node_id);
        defer conn.deinit();
        try dht_c.ping(conn);
        const conn_b = try peer_c.manager.connectToPeer(peer_b.listen_addr, peer_c.config.node.swarm_key, peer_b.manager.node_id);
        defer conn_b.deinit();
        try dht_c.ping(conn_b);
    }
    nomadfs.sync.sleep(200 * std.time.ns_per_ms);

    const bm_c = try BlockManager.init(allocator, .{ .network = peer_c.manager, .dht = &dht_c, .storage = &store_c });
    defer bm_c.deinit();
    const bm_b = try BlockManager.init(allocator, .{ .network = peer_b.manager, .dht = &dht_b, .storage = &store_b });
    defer bm_b.deinit();

    // C browses A's share (listing and dir blocks only) and finds the file.
    const a_id = peer_a.manager.node_id;
    const b_id = peer_b.manager.node_id;
    var remote_a = fs.Remote{ .block_manager = bm_c, .peer = a_id };
    const shares = try remote_a.shares(allocator);
    defer shares.deinit(allocator);
    const share = shares.listing.entries[0];
    try std.testing.expectEqualStrings("Camera", share.name);
    const loader = remote_a.loader();
    const img = try fs.tree.resolve(allocator, loader, share.cid, "video.bin");

    // B meets A, then reads the file once: it holds the blocks now.
    // (B's fetcher caches them in its store, so it answers GET_BLOCK.)
    {
        const conn = try peer_b.manager.connectToPeer(peer_a.listen_addr, peer_b.config.node.swarm_key, peer_a.manager.node_id);
        defer conn.deinit();
        try dht_b.ping(conn);
    }
    nomadfs.sync.sleep(200 * std.time.ns_per_ms);
    var remote_b = fs.Remote{ .block_manager = bm_b, .peer = a_id };
    {
        const b_loader = remote_b.loader();
        const whole = try fs.tree.readAt(allocator, b_loader, img.cid, 0, content);
        try std.testing.expectEqual(content.len, whole);
    }
    try std.testing.expect(store_b.has(&img.cid));

    // A told C's registry, through noteKeeps as a SHARES reply would, that
    // B keeps copies of A's folders.
    const holders = &bm_c.holders.?;
    holders.noteKeeps(b_id, a_id);
    var out: [8]nomadfs.net.id.NodeID = undefined;
    const likely = holders.forOrigin(a_id, &out);
    try std.testing.expectEqual(@as(usize, 2), likely.len);
    try std.testing.expect(likely[1].eql(b_id));

    peer_a.stop();
    nomadfs.sync.sleep(100 * std.time.ns_per_ms);
    const read: []u8 = try allocator.alloc(u8, content.len);
    defer allocator.free(read);
    try std.testing.expect(!try nomadfs.storage.dag.walk.isComplete(allocator, &store_c, &img.cid));
    const n = try fs.remote.readShareAt(allocator, bm_c, null, a_id, img.cid, 0, read);
    try std.testing.expectEqual(content.len, n);
    try std.testing.expectEqualSlices(u8, content, read);
    // B serves every block; C fetched the whole file through the registry.
    try std.testing.expect(nomadfs.storage.dag.walk.isComplete(allocator, &store_c, &img.cid) catch false);
}
