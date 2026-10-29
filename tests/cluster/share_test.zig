const std = @import("std");
const nomadfs = @import("nomadfs");
const TestPeer = @import("test_helpers").TestPeer;
const DhtNode = nomadfs.net.discovery.Node;
const StorageEngine = nomadfs.storage.engine.StorageEngine;
const BlockManager = nomadfs.cluster.BlockManager;
const fs = nomadfs.fs;

test "shares: browse a peer's folder and read a file range on demand" {
    std.debug.print("\n=== Running Test: shares: remote browse ===\n", .{});
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const cwd = std.Io.Dir.cwd();

    const owner_dir = "test_share_store_owner";
    const reader_dir = "test_share_store_reader";
    const folder = "test_share_folder";
    for ([_][]const u8{ owner_dir, reader_dir, folder }) |d| cwd.deleteTree(io, d) catch {};
    defer for ([_][]const u8{ owner_dir, reader_dir, folder }) |d| cwd.deleteTree(io, d) catch {};

    try cwd.createDirPath(io, folder ++ "/Camera");
    try cwd.writeFile(io, .{ .sub_path = folder ++ "/notes.txt", .data = "remember the milk" });
    const photo = try allocator.alloc(u8, 2 * 1024 * 1024 + 99);
    defer allocator.free(photo);
    var prng = std.Random.DefaultPrng.init(0x5eed);
    prng.random().bytes(photo);
    try cwd.writeFile(io, .{ .sub_path = folder ++ "/Camera/IMG_0001.jpg", .data = photo });

    var owner_store = try StorageEngine.init(allocator, owner_dir);
    defer owner_store.deinit();
    var reader_store = try StorageEngine.init(allocator, reader_dir);
    defer reader_store.deinit();

    var owner = try TestPeer.init(allocator, 13130);
    defer owner.deinit();
    var reader = try TestPeer.init(allocator, 13131);
    defer reader.deinit();

    var owner_dht = DhtNode.init(allocator, owner.manager, owner.config.node.swarm_key);
    defer owner_dht.deinit();
    var reader_dht = DhtNode.init(allocator, reader.manager, reader.config.node.swarm_key);
    defer reader_dht.deinit();
    owner_dht.block_store = &owner_store;
    owner_dht.nickname = "Poco X3";
    reader_dht.block_store = &reader_store;

    const index = try fs.ShareIndex.create(allocator, io, &owner_store);
    defer index.destroy();
    try index.add("Phone", folder);
    owner_dht.share_source = index.source();

    owner.manager.setConnectionHandler(&owner_dht, DhtNode.serve);
    reader.manager.setConnectionHandler(&reader_dht, DhtNode.serve);
    defer owner.stop();
    defer reader.stop();
    try owner.start();
    try reader.start();
    nomadfs.sync.sleep(100 * std.time.ns_per_ms);
    {
        const conn = try reader.manager.connectToPeer(owner.listen_addr, reader.config.node.swarm_key, owner.manager.node_id);
        defer conn.deinit();
        try reader_dht.ping(conn);
    }
    nomadfs.sync.sleep(200 * std.time.ns_per_ms);

    const bm = try BlockManager.init(allocator, .{ .network = reader.manager, .dht = &reader_dht, .storage = &reader_store });
    defer bm.deinit();

    const peers = try fs.remote.knownPeers(bm, allocator);
    defer allocator.free(peers);
    try std.testing.expectEqual(@as(usize, 1), peers.len);

    var remote = fs.Remote{ .block_manager = bm, .peer = peers[0] };
    const shares = try remote.shares(allocator);
    defer shares.deinit(allocator);
    try std.testing.expectEqualStrings("Poco X3", shares.nickname);
    try std.testing.expectEqual(@as(usize, 1), shares.listing.entries.len);
    const share = shares.listing.entries[0];
    try std.testing.expectEqualStrings("Phone", share.name);
    try std.testing.expectEqual(@as(u64, photo.len + 17), share.size);

    // Listing the share pulls only dir blocks: none of the photo yet.
    const loader = remote.loader();
    const img = try fs.tree.resolve(allocator, loader, share.cid, "Camera/IMG_0001.jpg");
    try std.testing.expectEqual(@as(u64, photo.len), img.size);
    try std.testing.expect(!reader_store.has(&img.cid));

    // A range from the middle fetches the root and the leaves covering it.
    var buf: [4096]u8 = undefined;
    const off: u64 = 1_500_000;
    const n = try fs.tree.readAt(allocator, loader, img.cid, off, &buf);
    try std.testing.expectEqual(buf.len, n);
    try std.testing.expectEqualSlices(u8, photo[off..][0..n], buf[0..n]);
    try std.testing.expect(reader_store.has(&img.cid));
    try std.testing.expect(!try nomadfs.storage.dag.walk.isComplete(allocator, &reader_store, &img.cid));

    // The same range is served from the local cache with the owner gone.
    owner.stop();
    var again: [4096]u8 = undefined;
    _ = try fs.tree.readAt(allocator, loader, img.cid, off, &again);
    try std.testing.expectEqualSlices(u8, &buf, &again);
}
