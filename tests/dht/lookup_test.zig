const std = @import("std");
const id = @import("nomadfs").dht.id;
const kbucket = @import("nomadfs").dht.kbucket;
const lookup = @import("nomadfs").dht.lookup;

test "dht: iterative lookup state management" {
    const allocator = std.testing.allocator;

    const target = id.NodeID{ .bytes = [_]u8{0xff} ** 32 };
    
    // Create some initial peers
    const p1 = kbucket.PeerInfo{
        .id = id.NodeID{ .bytes = [_]u8{0x10} ** 32 },
        .address = try std.net.Address.parseIp("127.0.0.1", 9001),
        .last_seen = 0,
    };
    const p2 = kbucket.PeerInfo{
        .id = id.NodeID{ .bytes = [_]u8{0x80} ** 32 },
        .address = try std.net.Address.parseIp("127.0.0.1", 9002),
        .last_seen = 0,
    };

    var state = try lookup.LookupState.init(allocator, target, &.{ p1, p2 });
    defer state.deinit();

    // 1. Initial state
    try std.testing.expect(!state.isFinished());
    
    // 2. Get next peers to query (should be p2 then p1 based on XOR distance to 0xff...)
    const to_query = try state.nextPeersToQuery();
    defer allocator.free(to_query);
    
    try std.testing.expectEqual(@as(usize, 2), to_query.len);
    try std.testing.expect(to_query[0].id.eql(p2.id)); // 0x80 is closer to 0xff than 0x10

    // 3. Report a reply with even closer peers
    const p3 = kbucket.PeerInfo{
        .id = id.NodeID{ .bytes = [_]u8{0xf0} ** 32 },
        .address = try std.net.Address.parseIp("127.0.0.1", 9003),
        .last_seen = 0,
    };
    
    try state.reportReply(p2.id, &.{ p3 });
    
    // p3 should now be at the top
    try std.testing.expect(state.best_peers.items[0].info.id.eql(p3.id));
    try std.testing.expect(state.best_peers.items[0].queried == false);

    // 4. Query p3
    const to_query2 = try state.nextPeersToQuery();
    defer allocator.free(to_query2);
    try std.testing.expectEqual(@as(usize, 1), to_query2.len);
    try std.testing.expect(to_query2[0].id.eql(p3.id));

    // 5. Finish
    try state.reportReply(p3.id, &.{});
    try state.reportReply(p1.id, &.{});
    
    try std.testing.expect(state.isFinished());
}
