const std = @import("std");
const nomadfs = @import("nomadfs");
const TestPeer = @import("test_helpers").TestPeer;
const id = nomadfs.dht.id;

test "dht: store and find_value" {
    std.debug.print("\n=== Running Test: dht: store and find_value ===\n", .{});
    const allocator = std.testing.allocator;

    // 1. Create two peers
    var peer1 = try TestPeer.init(allocator, 11001);
    defer peer1.deinit();

    var peer2 = try TestPeer.init(allocator, 11002);
    defer peer2.deinit();

    // 2. Initialize DHT Nodes
    var dht1 = nomadfs.dht.Node.init(allocator, &peer1.manager, peer1.config.node.swarm_key);
    defer dht1.deinit();

    var dht2 = nomadfs.dht.Node.init(allocator, &peer2.manager, peer2.config.node.swarm_key);
    defer dht2.deinit();

    // 3. Register DHT serve loop
    peer1.manager.setConnectionHandler(&dht1, nomadfs.dht.Node.serve);
    peer2.manager.setConnectionHandler(&dht2, nomadfs.dht.Node.serve);

    try peer1.start();
    try peer2.start(); // Start peer2 as well to accept connections if needed (though peer2 is client here)
    std.Thread.sleep(100 * std.time.ns_per_ms);

    // 4. Connect Peer2 to Peer1
    const conn = try peer2.manager.connectToPeer(peer1.listen_addr, peer2.config.node.swarm_key);
    // Ping to ensure they know each other and update routing tables
    try dht2.ping(conn);
    std.Thread.sleep(50 * std.time.ns_per_ms);

    // 5. Store data from Peer2 to Peer1
    const key = id.NodeID.fromData("my_secret_data");
    const value = "hello world";

    // Peer2 stores
    try dht2.store(key, value);
    std.Thread.sleep(50 * std.time.ns_per_ms);

    // 6. Verify Peer1 has it locally
    if (dht1.storage.get(key)) |stored_val| {
        try std.testing.expectEqualStrings(value, stored_val);
    } else {
        return error.DataNotStoredOnPeer1;
    }

    // 7. Retrieve data using findValue from Peer2
    // Even though Peer2 stored it, we want to see if it can fetch it back from the network (Peer1)
    // First, clear Peer2's local storage to be sure (though store() might have put it there if it considers itself close)
    // store() calls localStore if it's one of the closest.
    // Let's check if Peer2 has it.
    // If Peer2 has it, findValue returns it immediately.
    // We want to force a network fetch.
    _ = dht2.storage.remove(key);

    const result = try dht2.lookupValue(key);
    try std.testing.expect(result != null);
    if (result) |val| {
        defer allocator.free(val);
        try std.testing.expectEqualStrings(value, val);
    }

    // Cleanup
    conn.close();
    std.Thread.sleep(100 * std.time.ns_per_ms);
}
