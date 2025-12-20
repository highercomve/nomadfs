const std = @import("std");
const nomadfs = @import("nomadfs");
const TestPeer = @import("test_helpers").TestPeer;

test "dht: X-node discovery" {
    std.debug.print("\n=== Running Test: dht: 10-node discovery ===\n", .{});
    const allocator = std.testing.allocator;

    const NUM_NODES = 5;
    var peers = try allocator.alloc(*TestPeer, NUM_NODES);
    defer allocator.free(peers);

    var dht_nodes = try allocator.alloc(nomadfs.dht.Node, NUM_NODES);
    defer allocator.free(dht_nodes);

    // 1. Initialize all peers and DHT nodes
    for (0..NUM_NODES) |i| {
        peers[i] = try TestPeer.init(allocator, @as(u16, 11000 + @as(u16, @intCast(i))));
        dht_nodes[i] = nomadfs.dht.Node.init(allocator, &peers[i].manager, peers[i].config.node.swarm_key);
        peers[i].manager.setConnectionHandler(&dht_nodes[i], nomadfs.dht.Node.serve);
        try peers[i].start();
        std.debug.print("Node {d} ID: {x}\n", .{ i, peers[i].manager.node_id.bytes });
    }

    defer {
        for (0..NUM_NODES) |i| {
            dht_nodes[i].deinit();
            peers[i].deinit();
        }
    }

    // Wait for all to start listening
    std.Thread.sleep(200 * std.time.ns_per_ms);

    // 2. Bootstrap: Node 0 knows everyone else (correct ports)
    // In a real system, they would connect to Node 0.
    for (1..NUM_NODES) |i| {
        try dht_nodes[0].routing_table.addPeer(.{
            .id = peers[i].manager.node_id,
            .address = peers[i].listen_addr,
            .last_seen = std.time.timestamp(),
        });
    }

    std.debug.print("Bootstrapping complete. Node 0 knows all nodes with correct listen ports.\n", .{});

    const last_node_idx = NUM_NODES - 1;
    // 3. Last node knows Node 0
    try dht_nodes[last_node_idx].routing_table.addPeer(.{
        .id = peers[0].manager.node_id,
        .address = peers[0].listen_addr,
        .last_seen = std.time.timestamp(),
    });

    // 4. Last node tries to find Node 5 (or 2 if NUM_NODES=5)
    // Node 0 knows Node 5 (with correct port).

    const target_idx = NUM_NODES / 2;
    const target_id = peers[target_idx].manager.node_id;
    std.debug.print("Last node searching for Node {d} (ID: {x})\n", .{ target_idx, target_id.bytes });

    // Check Node 0's routing table first
    {
        const closest_to_target = try dht_nodes[0].routing_table.getClosestPeers(target_id, 1);
        defer allocator.free(closest_to_target);
        if (closest_to_target.len > 0) {
            std.debug.print("Node 0 thinks closest to target is: {f} at {any}\n", .{ closest_to_target[0].id, closest_to_target[0].address });
        }
    }

    try dht_nodes[last_node_idx].lookup(target_id);

    // 5. Verify discovery
    const closest = try dht_nodes[last_node_idx].routing_table.getClosestPeers(target_id, 1);
    defer allocator.free(closest);

    if (closest.len == 0 or !closest[0].id.eql(target_id)) {
        std.debug.print("FAILED: Discovery failed!\n", .{});
        if (closest.len > 0) {
            std.debug.print("Found ID: {x}\n", .{closest[0].id.bytes});
        }
        return error.DiscoveryFailed;
    }

    std.debug.print("Discovery successful! Last node found Node {d}.\n", .{target_idx});

    // 6. Clean teardown
    for (0..NUM_NODES) |i| {
        peers[i].stop();
    }
    std.Thread.sleep(200 * std.time.ns_per_ms);
}
