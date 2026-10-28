const std = @import("std");
const nomadfs = @import("nomadfs");
const TestPeer = @import("test_helpers").TestPeer;
const DhtNode = nomadfs.net.discovery.Node;
const StorageEngine = nomadfs.storage.engine.StorageEngine;
const BlockManager = nomadfs.cluster.BlockManager;
const SwarmFolder = nomadfs.fs.SwarmFolder;
const ReadAhead = nomadfs.fs.ReadAhead;

test "read-ahead: a sequential read fetches the next blocks before they're asked for" {
    std.debug.print("\n=== Running Test: read-ahead ===\n", .{});
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const cwd = std.Io.Dir.cwd();
    const dirs = [_][]const u8{ "test_ra_a", "test_ra_b", "test_ra_src" };
    for (dirs) |d| cwd.deleteTree(io, d) catch {};
    defer for (dirs) |d| cwd.deleteTree(io, d) catch {};
    try cwd.createDirPath(io, "test_ra_src");

    // Many chunks (FastCDC averages 256 KiB).
    const video = try allocator.alloc(u8, 6_000_000);
    defer allocator.free(video);
    var prng = std.Random.DefaultPrng.init(11);
    prng.random().bytes(video);
    try cwd.writeFile(io, .{ .sub_path = "test_ra_src/clip.mp4", .data = video });

    var store_a = try StorageEngine.init(allocator, "test_ra_a");
    defer store_a.deinit();
    var store_b = try StorageEngine.init(allocator, "test_ra_b");
    defer store_b.deinit();

    var peer_a = try TestPeer.init(allocator, 13180);
    defer peer_a.deinit();
    var peer_b = try TestPeer.init(allocator, 13181);
    defer peer_b.deinit();
    var dht_a = DhtNode.init(allocator, peer_a.manager, peer_a.config.node.swarm_key);
    defer dht_a.deinit();
    var dht_b = DhtNode.init(allocator, peer_b.manager, peer_b.config.node.swarm_key);
    defer dht_b.deinit();
    dht_a.block_store = &store_a;
    dht_b.block_store = &store_b;

    const swarm_a = try SwarmFolder.create(allocator, io, &store_a, peer_a.manager.node_id, "Phone", "test_ra_a/manifest.json");
    defer swarm_a.destroy();
    const swarm_b = try SwarmFolder.create(allocator, io, &store_b, peer_b.manager.node_id, "Laptop", "test_ra_b/manifest.json");
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
    const ra = try ReadAhead.create(allocator, bm_b, &store_b);
    defer ra.destroy();
    swarm_b.read_ahead = ra;

    try swarm_a.addFile("", "clip.mp4", "test_ra_src/clip.mp4");
    _ = try swarm_b.syncNow();
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const items = try swarm_b.list(arena_state.allocator(), "");
    const cid = items[0].cid.?;
    const author = items[0].author_id.?;

    // Two sequential reads, then wait: the blocks after them arrive without
    // being read.
    var buf: [128 * 1024]u8 = undefined;
    _ = try swarm_b.readAt(allocator, cid, author, 0, &buf);
    _ = try swarm_b.readAt(allocator, cid, author, buf.len, &buf);
    const ahead_start: u64 = 2 * buf.len + ReadAhead.min_window;
    var leaves: std.ArrayList([32]u8) = .empty;
    defer leaves.deinit(allocator);
    try nomadfs.fs.tree.leavesIn(allocator, nomadfs.fs.tree.Loader.local(&store_b), cid, 0, 2 * buf.len, ahead_start - 2 * buf.len, &leaves, 64);
    try std.testing.expect(leaves.items.len > 0);
    var waited: usize = 0;
    while (waited < 100) : (waited += 1) {
        var all = true;
        for (leaves.items) |leaf| all = all and store_b.has(&leaf);
        if (all) break;
        nomadfs.sync.sleep(50 * std.time.ns_per_ms);
    }
    for (leaves.items) |leaf| try std.testing.expect(store_b.has(&leaf));

    // Reading the whole file, in player-sized pieces, gives back its bytes.
    var offset: u64 = 0;
    while (offset < video.len) {
        const n = try swarm_b.readAt(allocator, cid, author, offset, &buf);
        try std.testing.expect(n > 0);
        try std.testing.expectEqualSlices(u8, video[@intCast(offset)..][0..n], buf[0..n]);
        offset += n;
    }
    try std.testing.expectEqual(@as(u64, video.len), offset);

    // A seek far ahead reads the right bytes too.
    const n = try swarm_b.readAt(allocator, cid, author, 5_000_000, &buf);
    try std.testing.expectEqualSlices(u8, video[5_000_000..][0..n], buf[0..n]);
}
