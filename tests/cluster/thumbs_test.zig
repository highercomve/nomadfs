//! Thumbnails across devices (fs/thumbs.zig over GET_DERIVED): a device
//! that does not have a photo gets its thumbnail from one that does,
//! without fetching a block of the photo.

const std = @import("std");
const nomadfs = @import("nomadfs");
const TestPeer = @import("test_helpers").TestPeer;
const DhtNode = nomadfs.net.discovery.Node;
const NodeID = nomadfs.net.id.NodeID;
const StorageEngine = nomadfs.storage.engine.StorageEngine;
const BlockManager = nomadfs.cluster.BlockManager;
const SwarmFolder = nomadfs.fs.SwarmFolder;
const Thumbs = nomadfs.fs.Thumbs;
const thumbs_mod = nomadfs.fs.thumbs;
const tree = nomadfs.fs.tree;
const image = nomadfs.codec.image;

/// Blocks in a store, kept and cached.
fn blockCount(store: *StorageEngine) !u64 {
    return (try store.keptUsage()).blocks + store.cacheStats().blocks;
}

test "thumbs: a device without a photo gets its thumbnail from a holder, and none of its blocks" {
    std.debug.print("\n=== Running Test: thumbs across devices ===\n", .{});
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const cwd = std.Io.Dir.cwd();
    const dirs = [_][]const u8{ "test_thumbs_a", "test_thumbs_b", "test_thumbs_c", "test_thumbs_src" };
    for (dirs) |d| cwd.deleteTree(io, d) catch {};
    defer for (dirs) |d| cwd.deleteTree(io, d) catch {};
    try cwd.createDirPath(io, "test_thumbs_src");

    // A photo of several chunks: a JPEG, then bytes decoders ignore.
    const jpeg = try image.testing.gradientJpeg(allocator, 1600, 1200, 3);
    defer allocator.free(jpeg);
    const photo = try allocator.alloc(u8, jpeg.len + 2_500_000);
    defer allocator.free(photo);
    @memcpy(photo[0..jpeg.len], jpeg);
    var prng = std.Random.DefaultPrng.init(11);
    prng.random().bytes(photo[jpeg.len..]);
    try cwd.writeFile(io, .{ .sub_path = "test_thumbs_src/beach.jpg", .data = photo });
    const own = try image.testing.gradientJpeg(allocator, 800, 600, 9);
    defer allocator.free(own);
    try cwd.writeFile(io, .{ .sub_path = "test_thumbs_src/desk.jpg", .data = own });

    var store_a = try StorageEngine.init(allocator, "test_thumbs_a");
    defer store_a.deinit();
    var store_b = try StorageEngine.init(allocator, "test_thumbs_b");
    defer store_b.deinit();
    var store_c = try StorageEngine.init(allocator, "test_thumbs_c");
    defer store_c.deinit();

    // A adds the photo (a phone), B is the backup (a home server), C looks
    // at the photos page (a laptop).
    var peer_a = try TestPeer.init(allocator, 13184);
    defer peer_a.deinit();
    var peer_b = try TestPeer.init(allocator, 13185);
    defer peer_b.deinit();
    var peer_c = try TestPeer.init(allocator, 13186);
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

    const swarm_a = try SwarmFolder.create(allocator, io, &store_a, peer_a.manager.node_id, "Phone", "test_thumbs_a/manifest.json");
    defer swarm_a.destroy();
    const swarm_b = try SwarmFolder.create(allocator, io, &store_b, peer_b.manager.node_id, "Server", "test_thumbs_b/manifest.json");
    defer swarm_b.destroy();
    const swarm_c = try SwarmFolder.create(allocator, io, &store_c, peer_c.manager.node_id, "Laptop", "test_thumbs_c/manifest.json");
    defer swarm_c.destroy();
    dht_a.swarm_source = swarm_a.source();
    dht_b.swarm_source = swarm_b.source();
    dht_c.swarm_source = swarm_c.source();

    // B and C answer for thumbnails. A does not (`derived_source` stays
    // null): it says it does not hold the file, as a device would that
    // has no thumbnails folder.
    const thumbs_b = try Thumbs.create(allocator, io, &store_b, swarm_b, "test_thumbs_b/thumbs", .{});
    defer thumbs_b.destroy();
    // C asks before it decodes, as a phone does.
    const thumbs_c = try Thumbs.create(allocator, io, &store_c, swarm_c, "test_thumbs_c/thumbs", .{ .prefer_local = false });
    defer thumbs_c.destroy();
    thumbs_b.remote = thumbs_b.clusterRemote();
    thumbs_c.remote = thumbs_c.clusterRemote();
    dht_b.derived_source = thumbs_b.source();
    dht_c.derived_source = thumbs_c.source();
    // The handlers that answer from the thumbnails end before those are
    // freed (the node drains them the same way).
    defer dht_b.drainHandlers();
    defer dht_c.drainHandlers();

    peer_a.manager.setConnectionHandler(&dht_a, DhtNode.serve);
    peer_b.manager.setConnectionHandler(&dht_b, DhtNode.serve);
    peer_c.manager.setConnectionHandler(&dht_c, DhtNode.serve);
    defer peer_a.stop();
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
    for ([_]*TestPeer{ &peer_a, &peer_b }) |other| {
        const conn = try peer_c.manager.connectToPeer(other.listen_addr, peer_c.config.node.swarm_key, other.manager.node_id);
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

    // A adds the photo, B copies it, C learns of it.
    try swarm_a.addFile("", "beach.jpg", "test_thumbs_src/beach.jpg");
    try std.testing.expect(try swarm_b.syncNow() > 0);
    swarm_b.backup_enabled.store(true, .release);
    try swarm_b.backupRound();
    try std.testing.expectEqual(@as(usize, 1), swarm_b.backupStatus().backed_up);
    try std.testing.expect(try swarm_c.syncNow() > 0);
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const items = try swarm_c.list(arena_state.allocator(), "");
    try std.testing.expectEqual(@as(usize, 1), items.len);
    const cid = items[0].cid.?;
    const author = items[0].author_id.?;
    try std.testing.expect(std.mem.eql(u8, &author, &peer_a.manager.node_id.bytes));

    var leaves: std.ArrayList([32]u8) = .empty;
    defer leaves.deinit(allocator);
    try tree.leavesIn(allocator, tree.Loader.local(&store_a), cid, 0, 0, photo.len, &leaves, 64);
    try std.testing.expect(leaves.items.len >= 3);
    const blocks_before = try blockCount(&store_c);

    // The author is the first C asks, the backup the next: both connected.
    var hint_buf: [nomadfs.cluster.fetcher.max_holders]NodeID = undefined;
    const hints = swarm_c.holdersOf(allocator, &cid, .{ .bytes = author }, &hint_buf);
    try std.testing.expect(hints.len >= 2);
    try std.testing.expect(hints[0].eql(peer_a.manager.node_id));
    try std.testing.expect(hints[1].eql(peer_b.manager.node_id));
    {
        // What each says over the wire: A has no source, B knows one kind.
        const conn_a = try bm_c.connectKnown(peer_a.manager.node_id);
        defer conn_a.deinit();
        try std.testing.expect(try dht_c.fetchDerived(conn_a, cid, thumbs_mod.kind_jpeg_320, allocator) == .not_held);
        const conn_b = try bm_c.connectKnown(peer_b.manager.node_id);
        defer conn_b.deinit();
        try std.testing.expect(try dht_c.fetchDerived(conn_b, cid, 200, allocator) == .unknown_kind);
        try std.testing.expect(try dht_c.fetchDerived(conn_b, @splat(0xEE), thumbs_mod.kind_jpeg_320, allocator) == .not_held);
    }

    // (3) A says it does not hold it and C goes on to B. B has the file
    // and no thumbnail yet, and these test peers present no trusted
    // device: B decodes nothing for C, queues nothing (a peer outside the
    // swarm never costs B a decode), and C is told to come back.
    try std.testing.expectEqual(thumbs_mod.Result.pending, try thumbs_c.get(allocator, cid, author, .photo, 4_000));
    try std.testing.expectEqual(@as(u64, 0), thumbs_b.generated.load(.monotonic));
    try std.testing.expectEqual(@as(usize, 0), thumbs_b.wanted.len);

    // B makes it on its own (what its pregeneration worker does).
    try std.testing.expect(try thumbs_b.generateLocal(allocator, &cid, .other) == .jpeg_len);

    // (1) C gets the thumbnail, (5) for a small part of the photo's bytes.
    const traffic_before = peer_c.manager.trafficTotals();
    const got = try thumbs_c.get(allocator, cid, author, .photo, 4_000);
    const traffic = peer_c.manager.trafficTotals();
    const thumb = try thumbs_c.readAll(allocator, cid, got.jpeg_len);
    defer allocator.free(thumb);
    const dims = try image.info(thumb);
    try std.testing.expectEqual(@as(u32, 320), dims.width);
    try std.testing.expectEqual(@as(u32, 240), dims.height);
    const wire = (traffic.sent - traffic_before.sent) + (traffic.received - traffic_before.received);
    std.debug.print("thumbs: {d} bytes on the wire for a {d} byte thumbnail of a {d} byte photo\n", .{ wire, thumb.len, photo.len });
    try std.testing.expect(wire >= thumb.len);
    try std.testing.expect(wire < thumb.len + 16 * 1024);
    try std.testing.expect(wire < photo.len / 20);
    // Not one block of the photo came with it.
    try std.testing.expectEqual(blocks_before, try blockCount(&store_c));
    try std.testing.expectEqual(StorageEngine.Where.missing, store_c.locate(&cid));
    for (leaves.items) |*leaf| try std.testing.expectEqual(StorageEngine.Where.missing, store_c.locate(leaf));
    try std.testing.expect(!thumbs_c.isAllLocal(&cid));
    // It is B's thumbnail, byte for byte.
    const made = try thumbs_b.readAll(allocator, cid, got.jpeg_len);
    defer allocator.free(made);
    try std.testing.expectEqualSlices(u8, made, thumb);
    try std.testing.expectEqual(@as(u64, 0), thumbs_c.generated.load(.monotonic));

    // (2) With A and B gone, C still has it.
    peer_a.stop();
    peer_b.stop();
    nomadfs.sync.sleep(100 * std.time.ns_per_ms);
    try std.testing.expectEqual(got.jpeg_len, (try thumbs_c.get(allocator, cid, author, .photo, 4_000)).jpeg_len);
    var part: [32]u8 = undefined;
    try std.testing.expectEqual(part.len, try thumbs_c.read(cid, 0, &part));
    try std.testing.expectEqualSlices(u8, thumb[0..part.len], &part);

    // (4) A photo C has, with nobody to ask: C makes the thumbnail itself.
    try swarm_c.addFile("", "desk.jpg", "test_thumbs_src/desk.jpg");
    const mine = swarm_c.fileInfo("desk.jpg").?;
    const local = try thumbs_c.get(allocator, mine.cid, mine.author, .photo, 4_000);
    try std.testing.expect(local == .jpeg_len);
    try std.testing.expectEqual(@as(u64, 1), thumbs_c.generated.load(.monotonic));
    // A photo that is nowhere to be had stays without one.
    try std.testing.expectEqual(thumbs_mod.Result.unavailable, try thumbs_c.get(allocator, @splat(0xE7), author, .photo, 4_000));
}
