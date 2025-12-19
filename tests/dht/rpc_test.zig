const std = @import("std");
const nomadfs = @import("nomadfs");
const id = nomadfs.dht.id;
const rpc = nomadfs.dht.rpc;
const kbucket = nomadfs.dht.kbucket;

test "dht: rpc serialization and deserialization" {
    std.debug.print("\n=== Running Test: dht: rpc serialization and deserialization ===\n", .{});
    const allocator = std.testing.allocator;

    const sender_id = id.NodeID{ .bytes = [_]u8{0x01} ** 32 };

    const peers = try allocator.alloc(kbucket.PeerInfo, 2);
    defer allocator.free(peers);

    peers[0] = .{
        .id = id.NodeID{ .bytes = [_]u8{0x03} ** 32 },
        .address = try std.net.Address.parseIp("1.2.3.4", 1234),
        .last_seen = 0,
    };
    peers[1] = .{
        .id = id.NodeID{ .bytes = [_]u8{0x04} ** 32 },
        .address = try std.net.Address.parseIp("::1", 5678),
        .last_seen = 0,
    };

    const original_msg = rpc.Message{
        .sender_id = sender_id,
        .payload = .{
            .FIND_NODE_RESPONSE = .{ .closer_peers = peers },
        },
    };

    var buffer = std.ArrayListUnmanaged(u8){};
    defer buffer.deinit(allocator);

    try original_msg.serialize(buffer.writer(allocator));

    var stream = std.io.fixedBufferStream(buffer.items);
    const decoded_msg = try rpc.Message.deserialize(allocator, stream.reader());
    defer decoded_msg.deinit(allocator);

    try std.testing.expect(decoded_msg.sender_id.eql(sender_id));

    switch (decoded_msg.payload) {
        .FIND_NODE_RESPONSE => |p| {
            try std.testing.expectEqual(@as(usize, 2), p.closer_peers.len);
            try std.testing.expect(p.closer_peers[0].id.eql(peers[0].id));
            try std.testing.expectEqual(@as(u16, 1234), p.closer_peers[0].address.getPort());
            try std.testing.expect(p.closer_peers[1].id.eql(peers[1].id));
            try std.testing.expectEqual(@as(u16, 5678), p.closer_peers[1].address.getPort());
        },
        else => unreachable,
    }
}
