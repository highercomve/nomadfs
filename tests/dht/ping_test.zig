const std = @import("std");
const nomadfs = @import("nomadfs");
const TestPeer = @import("test_helpers").TestPeer;

test "dht: ping/pong integration" {
    std.debug.print("\n=== Running Test: dht: ping/pong integration ===\n", .{});
    const allocator = std.testing.allocator;

    // 1. Create two peers
    var peer1 = try TestPeer.init(allocator, 10001);
    defer peer1.deinit();

    var peer2 = try TestPeer.init(allocator, 10002);
    defer peer2.deinit();

    // 2. Initialize DHT Nodes for both
    var dht1 = nomadfs.dht.Node.init(allocator, &peer1.manager, peer1.config.node.swarm_key);
    defer dht1.deinit();

    var dht2 = nomadfs.dht.Node.init(allocator, &peer2.manager, peer2.config.node.swarm_key);
    defer dht2.deinit();

    // 3. Register DHT serve loop for both
    peer1.manager.setConnectionHandler(&dht1, nomadfs.dht.Node.serve);
    peer2.manager.setConnectionHandler(&dht2, nomadfs.dht.Node.serve);

    // 4. Start peer1 (the "server")
    try peer1.start();
    std.Thread.sleep(100 * std.time.ns_per_ms);

    // 5. Peer2 connects to Peer1
    const conn = try peer2.manager.connectToPeer(peer1.listen_addr, peer2.config.node.swarm_key);

    // 6. Peer2 pings Peer1
    // We expect this to not time out and succeed
    try dht2.ping(conn);

    std.debug.print("Ping test passed!\n", .{});

    // 7. Close connection and wait for disconnection logic to run
    conn.close();
    std.Thread.sleep(100 * std.time.ns_per_ms);
}
