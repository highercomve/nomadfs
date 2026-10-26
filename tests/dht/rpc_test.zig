const compat = @import("nomadfs").net.compat;
const std = @import("std");
const nomadfs = @import("nomadfs");
const id = nomadfs.net.id;
const rpc = nomadfs.net.discovery.rpc;
const kbucket = nomadfs.net.discovery.kbucket;

const BufferWriter = struct {
    list: *std.ArrayList(u8),
    allocator: std.mem.Allocator,

    pub fn write(self: @This(), bytes: []const u8) !usize {
        try self.list.appendSlice(self.allocator, bytes);
        return bytes.len;
    }

    pub fn writeAll(self: @This(), bytes: []const u8) !void {
        try self.list.appendSlice(self.allocator, bytes);
    }

    pub fn writeByte(self: @This(), byte: u8) !void {
        try self.list.append(self.allocator, byte);
    }

    pub fn writeInt(self: @This(), comptime T: type, val: T, endian: std.builtin.Endian) !void {
        var bytes: [@sizeOf(T)]u8 = undefined;
        std.mem.writeInt(T, &bytes, val, endian);
        try self.list.appendSlice(self.allocator, &bytes);
    }
};

const BufferReader = struct {
    buffer: []const u8,
    pos: usize = 0,

    pub fn read(self: *@This(), dest: []u8) !usize {
        if (self.pos >= self.buffer.len) return 0;
        const n = @min(dest.len, self.buffer.len - self.pos);
        @memcpy(dest[0..n], self.buffer[self.pos .. self.pos + n]);
        self.pos += n;
        return n;
    }

    pub fn readNoEof(self: *@This(), dest: []u8) !void {
        const n = try self.read(dest);
        if (n < dest.len) return error.EndOfStream;
    }

    pub fn readByte(self: *@This()) !u8 {
        var b: [1]u8 = undefined;
        try self.readNoEof(&b);
        return b[0];
    }

    pub fn readInt(self: *@This(), comptime T: type, endian: std.builtin.Endian) !T {
        var bytes: [@sizeOf(T)]u8 = undefined;
        try self.readNoEof(&bytes);
        return std.mem.readInt(T, &bytes, endian);
    }
};

test "dht: rpc serialization and deserialization" {
    std.debug.print("\n=== Running Test: dht: rpc serialization and deserialization ===\n", .{});
    const allocator = std.testing.allocator;

    const sender_id = id.NodeID{ .bytes = [_]u8{0x01} ** 32 };

    const peers = try allocator.alloc(kbucket.PeerInfo, 2);
    defer allocator.free(peers);

    peers[0] = .{
        .id = id.NodeID{ .bytes = [_]u8{0x03} ** 32 },
        .addresses = .{try compat.Address.parseIp("1.2.3.4", 1234)} ++ .{undefined} ** (kbucket.MAX_PEER_ADDRESSES - 1),
        .addrs_count = 1,
        .last_seen = 0,
    };
    peers[1] = .{
        .id = id.NodeID{ .bytes = [_]u8{0x04} ** 32 },
        .addresses = .{try compat.Address.parseIp("::1", 5678)} ++ .{undefined} ** (kbucket.MAX_PEER_ADDRESSES - 1),
        .addrs_count = 1,
        .last_seen = 0,
    };

    const original_msg = rpc.Message{
        .sender_id = sender_id,
        .payload = .{
            .FIND_NODE_RESPONSE = .{ .closer_peers = peers },
        },
    };

    var buffer: std.ArrayList(u8) = .empty;
    defer buffer.deinit(allocator);

    const bw = BufferWriter{ .list = &buffer, .allocator = allocator };
    try original_msg.serialize(bw);

    var br = BufferReader{ .buffer = buffer.items };
    const decoded_msg = try rpc.Message.deserialize(allocator, &br);
    defer decoded_msg.deinit(allocator);

    try std.testing.expect(decoded_msg.sender_id.eql(sender_id));

    switch (decoded_msg.payload) {
        .FIND_NODE_RESPONSE => |p| {
            try std.testing.expectEqual(@as(usize, 2), p.closer_peers.len);
            try std.testing.expect(p.closer_peers[0].id.eql(peers[0].id));
            try std.testing.expectEqual(@as(u16, 1234), p.closer_peers[0].addresses[0].getPort());
            try std.testing.expect(p.closer_peers[1].id.eql(peers[1].id));
            try std.testing.expectEqual(@as(u16, 5678), p.closer_peers[1].addresses[0].getPort());
        },
        else => unreachable,
    }
}
