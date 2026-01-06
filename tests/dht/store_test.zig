const std = @import("std");
const nomadfs = @import("nomadfs");
const TestPeer = @import("test_helpers").TestPeer;
const id = nomadfs.net.id;

test "dht: store and find_value (with timeout)" {
    std.debug.print("\n=== Running Test: dht: store and find_value (with timeout) ===\n", .{});
    const allocator = std.testing.allocator;

    const TEST_TIMEOUT_MS = 10_000; // 10 seconds timeout
    const POLL_INTERVAL_MS: u64 = 500; // 500ms poll interval

    var result: ?[]const u8 = null;
    var elapsed_ms: u64 = 0;
    var poll_count: usize = 0;

    // 1. Create two peers
    var peer1 = try TestPeer.init(allocator, 11001);
    defer peer1.deinit();

    var peer2 = try TestPeer.init(allocator, 11002);
    defer peer2.deinit();

    // 2. Initialize DHT Nodes
    var dht1 = nomadfs.net.discovery.Node.init(allocator, peer1.manager, peer1.config.node.swarm_key);
    defer dht1.deinit();

    var dht2 = nomadfs.net.discovery.Node.init(allocator, peer2.manager, peer2.config.node.swarm_key);
    defer dht2.deinit();

    // 3. Register DHT serve loop
    peer1.manager.setConnectionHandler(&dht1, nomadfs.net.discovery.Node.serve);
    peer2.manager.setConnectionHandler(&dht2, nomadfs.net.discovery.Node.serve);

    // 4. Start peers
    try peer1.start();
    try peer2.start();
    std.Thread.sleep(100 * std.time.ns_per_ms);

    // 5. Store data from Peer2 to Peer1
    const key = id.NodeID.fromData("my_secret_data");
    const value = "hello world";

    try dht2.store(key, value);
    std.Thread.sleep(50 * std.time.ns_per_ms);

    // 6. Verify Peer1 has it locally
    if (dht1.storage.get(key)) |stored_val| {
        try std.testing.expectEqualStrings(value, stored_val);
    } else {
        return error.DataNotStoredOnPeer1;
    }

    // 7. Retrieve data using findValue from Peer2 with timeout
    // Remove from Peer1 storage to force network lookup
    _ = dht2.storage.remove(key);

    // Simple polling loop with timeout
    while (elapsed_ms < TEST_TIMEOUT_MS and result == null) : (elapsed_ms += POLL_INTERVAL_MS) {
        poll_count += 1;

        // Check if peer has value in storage (lookup succeeded)
        const lookup_val = dht1.storage.get(key);
        if (lookup_val) |val| {
            result = val;
            std.debug.print("Poll {} at {}ms: result=found\n", .{ poll_count, elapsed_ms });
            break;
        }
    }

    // Verify lookup completed
    if (result) |val| {
        defer allocator.free(val);
        try std.testing.expectEqualStrings(value, val);
    } else {
        std.debug.print("=== Test FAILED: Lookup timed out after {}ms ===\n", .{elapsed_ms});
        return error.TestTimeout;
    }

    // Cleanup
    const conn = try peer2.manager.connectToPeer(peer1.listen_addr, peer2.config.node.swarm_key, peer1.manager.node_id);
    conn.close();
    std.Thread.sleep(100 * std.time.ns_per_ms);
}
