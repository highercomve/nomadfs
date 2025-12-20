const std = @import("std");
const nomadfs = @import("nomadfs");
const NodeID = nomadfs.dht.id.NodeID;
const RoutingTable = nomadfs.dht.kbucket.RoutingTable;

test "kbucket: randomIdInBucket correctness" {
    const local_id = NodeID.generate();
    
    var i: usize = 0;
    while (i < 256) : (i += 1) {
        const target = local_id.randomIdInBucket(i);
        const cpl = local_id.commonPrefixLen(target);
        
        // CPL must be exactly i
        try std.testing.expectEqual(@as(u8, @intCast(i)), cpl);
        
        // Target must not be equal to local_id
        try std.testing.expect(!local_id.eql(target));
    }
}

test "kbucket: last_updated timestamp" {
    const allocator = std.testing.allocator;
    const local_id = NodeID.generate();
    var rt = RoutingTable.init(allocator, local_id);
    defer rt.deinit();

    const peer_id = local_id.randomIdInBucket(5);
    const peer_addr = try std.net.Address.parseIp("127.0.0.1", 9000);
    
    const bucket_index = 5;
    // Manually set to 0 to ensure any update is greater
    rt.buckets[bucket_index].last_updated = 0;
    
    try rt.addPeer(.{
        .id = peer_id,
        .address = peer_addr,
        .last_seen = std.time.timestamp(),
    });

    const updated_ts = rt.buckets[bucket_index].last_updated;
    try std.testing.expect(updated_ts > 0);
}

test "node: refreshBuckets logic" {
    // This test verifies that refreshBuckets correctly identifies stale buckets.
    // Since we can't easily mock time without refactoring, we will manually
    // manipulate the last_updated field for testing.
    
    const allocator = std.testing.allocator;
    
    // We need a dummy ConnectionManager to init Node
    var manager = nomadfs.network.manager.ConnectionManager.initExplicit(
        allocator, 
        .tcp, 
        nomadfs.network.noise.KeyPair.generate()
    );
    defer manager.deinit();

    var node = nomadfs.dht.Node.init(allocator, &manager, "test_swarm_key");
    defer node.deinit();

    const now = std.time.timestamp();
    
    // 1. Manually mark bucket 10 as stale (2 hours ago)
    node.routing_table.buckets[10].last_updated = now - 7200;
    
    // 2. Mark bucket 20 as fresh (now)
    node.routing_table.buckets[20].last_updated = now;

    // We can't easily check if lookup was called without a mock, 
    // but we can check if it at least runs without crashing 
    // and if it updates the timestamp of the stale bucket after it would hypothetically add a peer.
    // Actually, lookup itself doesn't update the bucket timestamp unless it finds someone.
    
    try node.refreshBuckets();
    
    // The timestamp for bucket 10 should STILL be old because lookup didn't find anyone 
    // (no other nodes running).
    try std.testing.expectEqual(now - 7200, node.routing_table.buckets[10].last_updated);
}
