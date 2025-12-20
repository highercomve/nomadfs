const std = @import("std");
const nomadfs = @import("nomadfs");
const TestPeer = @import("test_helpers").TestPeer;

test "dht: churn resilience" {
    std.debug.print("\n=== Running Test: dht: churn resilience ===\n", .{});
    const allocator = std.testing.allocator;

    const NUM_NODES = 5;
    var peers = try allocator.alloc(*TestPeer, NUM_NODES);
    defer allocator.free(peers);

    var dht_nodes = try allocator.alloc(nomadfs.dht.Node, NUM_NODES);
    defer allocator.free(dht_nodes);

    // 1. Initialize all peers and DHT nodes
    for (0..NUM_NODES) |i| {
        peers[i] = try TestPeer.init(allocator, @as(u16, 12000 + @as(u16, @intCast(i))));
        dht_nodes[i] = nomadfs.dht.Node.init(allocator, &peers[i].manager, peers[i].config.node.swarm_key);
        peers[i].manager.setConnectionHandler(&dht_nodes[i], nomadfs.dht.Node.serve);
        try peers[i].start();
    }

    defer {
        for (0..NUM_NODES) |i| {
            dht_nodes[i].deinit();
            peers[i].deinit();
        }
    }

    std.Thread.sleep(100 * std.time.ns_per_ms);

    // 2. Bootstrap: Node 0 knows everyone else (correct ports)
    for (1..NUM_NODES) |i| {
        try dht_nodes[0].routing_table.addPeer(.{
            .id = peers[i].manager.node_id,
            .address = peers[i].listen_addr,
            .last_seen = std.time.timestamp(),
        });
    }

    const last_node_idx = NUM_NODES - 1;
    // 3. Last node knows Node 0
    try dht_nodes[last_node_idx].routing_table.addPeer(.{
        .id = peers[0].manager.node_id,
        .address = peers[0].listen_addr,
        .last_seen = std.time.timestamp(),
    });

    // 4. Last node performs a general lookup to discover some peers
    const discovery_target = nomadfs.dht.id.NodeID{ .bytes = [_]u8{0xaa} ** 32 };
    try dht_nodes[last_node_idx].lookup(discovery_target);

    // 5. Select a target and find which node is closest to it (among 1..NUM_NODES-2)
    const target = nomadfs.dht.id.NodeID{ .bytes = [_]u8{0x55} ** 32 };

    var closest_idx: usize = 1;
    var min_dist = peers[1].manager.node_id.distance(target);

    for (2..last_node_idx) |i| {
        const dist = peers[i].manager.node_id.distance(target);
        for (0..32) |b| {
            if (dist.bytes[b] < min_dist.bytes[b]) {
                min_dist = dist;
                closest_idx = i;
                break;
            } else if (dist.bytes[b] > min_dist.bytes[b]) {
                break;
            }
        }
    }

    std.debug.print("Closest node to target is Node {d} (ID: {x})\n", .{ closest_idx, peers[closest_idx].manager.node_id.bytes });

    // 6. Stop the closest node to simulate churn
    std.debug.print("Stopping Node {d} to simulate churn...\n", .{closest_idx});
    peers[closest_idx].stop();
    std.Thread.sleep(1 * std.time.ns_per_s);

    // Verify Last Node HAS the stopped node in its routing table before lookup
    {
        dht_nodes[last_node_idx].routing_table.dump();
        const all_peers = try dht_nodes[last_node_idx].routing_table.getClosestPeers(target, 20);
        defer allocator.free(all_peers);
        var found = false;
        for (all_peers) |p| {
            if (p.id.eql(peers[closest_idx].manager.node_id)) {
                found = true;
                break;
            }
        }
        if (!found) {
            std.debug.print("FAILED: Stopped node NOT in Last Node routing table before lookup!\n", .{});
            return error.TestSetupFailed;
        }
    }

    // 7. Last Node tries to lookup the target
    // It should encounter the failure of the stopped node and find the NEXT best peer.
    std.debug.print("Last Node starting lookup for target...\n", .{});
    try dht_nodes[last_node_idx].lookup(target);

    // 8. Verify lookup results
    const results = try dht_nodes[last_node_idx].routing_table.getClosestPeers(target, 1);
    defer allocator.free(results);

    try std.testing.expect(results.len > 0);

    // Should NOT be the stopped node
    try std.testing.expect(!results[0].id.eql(peers[closest_idx].manager.node_id));

    std.debug.print("Churn resilience test passed! Node {d} found next best peer (ID: {x}).\n", .{ last_node_idx, results[0].id.bytes });

    // Cleanup
    for (0..NUM_NODES) |i| {
        peers[i].stop();
    }
    std.Thread.sleep(100 * std.time.ns_per_ms);
}
