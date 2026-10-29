const std = @import("std");
const nomadfs = @import("nomadfs");
const TestPeer = @import("test_helpers").TestPeer;
const DhtNode = nomadfs.net.discovery.Node;
const StorageEngine = nomadfs.storage.engine.StorageEngine;

test "cluster: wire byte counters track traffic across loopback block transfer" {
    std.debug.print("\n=== Running Test: cluster: wire byte traffic totals ===\n", .{});
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();

    const dir1 = "test_traffic_store_1";
    const dir2 = "test_traffic_store_2";
    std.Io.Dir.cwd().deleteTree(io, dir1) catch {};
    std.Io.Dir.cwd().deleteTree(io, dir2) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, dir1) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, dir2) catch {};
    var engine1 = try StorageEngine.init(allocator, dir1);
    defer engine1.deinit();
    var engine2 = try StorageEngine.init(allocator, dir2);
    defer engine2.deinit();

    var peer1 = try TestPeer.init(allocator, 13270);
    defer peer1.deinit();
    var peer2 = try TestPeer.init(allocator, 13271);
    defer peer2.deinit();

    var dht1 = DhtNode.init(allocator, peer1.manager, peer1.config.node.swarm_key);
    defer dht1.deinit();
    var dht2 = DhtNode.init(allocator, peer2.manager, peer2.config.node.swarm_key);
    defer dht2.deinit();
    dht1.block_store = &engine1;
    dht2.block_store = &engine2;
    peer1.manager.setConnectionHandler(&dht1, DhtNode.serve);
    peer2.manager.setConnectionHandler(&dht2, DhtNode.serve);
    defer peer1.stop();
    defer peer2.stop();

    try peer1.start();
    try peer2.start();
    nomadfs.sync.sleep(100 * std.time.ns_per_ms);

    const initial1 = peer1.manager.trafficTotals();
    const initial2 = peer2.manager.trafficTotals();
    try std.testing.expectEqual(@as(u64, 0), initial1.sent);
    try std.testing.expectEqual(@as(u64, 0), initial1.received);
    try std.testing.expectEqual(@as(u64, 0), initial2.sent);
    try std.testing.expectEqual(@as(u64, 0), initial2.received);

    const data = "traffic measurement payload block across loopback connection";
    var cid: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(data, &cid, .{});
    try engine1.put(.{ .cid = cid, .data = data });

    const conn = try peer2.manager.connectToPeer(peer1.listen_addr, peer2.config.node.swarm_key, peer1.manager.node_id);
    defer conn.deinit();

    const fetched = try dht2.fetchBlock(conn, cid);
    try std.testing.expect(fetched != null);
    defer dht2.allocator.free(fetched.?);
    try std.testing.expectEqualStrings(data, fetched.?);

    nomadfs.sync.sleep(50 * std.time.ns_per_ms);

    const t1 = peer1.manager.trafficTotals();
    const t2 = peer2.manager.trafficTotals();

    try std.testing.expect(t1.sent > 0);
    try std.testing.expect(t1.received > 0);
    try std.testing.expect(t2.sent > 0);
    try std.testing.expect(t2.received > 0);

    const slack: u64 = 64;
    const diff_1_to_2 = if (t1.sent >= t2.received) t1.sent - t2.received else t2.received - t1.sent;
    const diff_2_to_1 = if (t2.sent >= t1.received) t2.sent - t1.received else t1.received - t2.sent;

    try std.testing.expect(diff_1_to_2 <= slack);
    try std.testing.expect(diff_2_to_1 <= slack);
}
