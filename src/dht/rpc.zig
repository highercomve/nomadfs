const std = @import("std");
const id = @import("id.zig");
const kbucket = @import("kbucket.zig");

pub const MessageType = enum(u8) {
    PING = 0,
    PONG = 1,
    FIND_NODE = 2,
    FIND_NODE_RESPONSE = 3,
};

pub const MessagePayload = union(MessageType) {
    PING: void,
    PONG: void,
    FIND_NODE: struct { target: id.NodeID },
    FIND_NODE_RESPONSE: struct { closer_peers: []kbucket.PeerInfo },
};

pub const Message = struct {
    sender_id: id.NodeID,
    payload: MessagePayload,

    pub fn serialize(self: Message, writer: anytype) !void {
        // 1. Write Message Type
        try writer.writeByte(@intFromEnum(self.payload));

        // 2. Write Sender ID
        try writer.writeAll(&self.sender_id.bytes);

        // 3. Write Payload
        switch (self.payload) {
            .PING, .PONG => {},
            .FIND_NODE => |p| {
                try writer.writeAll(&p.target.bytes);
            },
            .FIND_NODE_RESPONSE => |p| {
                if (p.closer_peers.len > 255) return error.TooManyPeers;
                try writer.writeByte(@intCast(p.closer_peers.len));
                for (p.closer_peers) |peer| {
                    try writer.writeAll(&peer.id.bytes);
                    try serializeAddress(peer.address, writer);
                }
            },
        }
    }

    pub fn deserialize(allocator: std.mem.Allocator, reader: anytype) !Message {
        const type_byte = try reader.readByte();
        const msg_type = std.meta.intToEnum(MessageType, type_byte) catch return error.InvalidMessageType;

        var sender_id: id.NodeID = undefined;
        try reader.readNoEof(&sender_id.bytes);

        const payload = switch (msg_type) {
            .PING => MessagePayload{ .PING = {} },
            .PONG => MessagePayload{ .PONG = {} },
            .FIND_NODE => blk: {
                var target: id.NodeID = undefined;
                try reader.readNoEof(&target.bytes);
                break :blk MessagePayload{ .FIND_NODE = .{ .target = target } };
            },
            .FIND_NODE_RESPONSE => blk: {
                const count = try reader.readByte();
                if (count > kbucket.K) return error.TooManyPeers;

                const peers = try allocator.alloc(kbucket.PeerInfo, count);
                errdefer allocator.free(peers);

                for (0..count) |i| {
                    var peer_id: id.NodeID = undefined;
                    try reader.readNoEof(&peer_id.bytes);
                    const address = try deserializeAddress(reader);
                    peers[i] = .{
                        .id = peer_id,
                        .address = address,
                        .last_seen = std.time.timestamp(),
                    };
                }
                break :blk MessagePayload{ .FIND_NODE_RESPONSE = .{ .closer_peers = peers } };
            },
        };

        return Message{
            .sender_id = sender_id,
            .payload = payload,
        };
    }

    pub fn deinit(self: Message, allocator: std.mem.Allocator) void {
        switch (self.payload) {
            .FIND_NODE_RESPONSE => |p| allocator.free(p.closer_peers),
            else => {},
        }
    }
};

fn serializeAddress(addr: std.net.Address, writer: anytype) !void {
    switch (addr.any.family) {
        std.posix.AF.INET => {
            try writer.writeByte(4);
            try writer.writeAll(std.mem.asBytes(&addr.in.sa.addr));
            // addr.in.sa.port is already big-endian
            try writer.writeAll(std.mem.asBytes(&addr.in.sa.port));
        },
        std.posix.AF.INET6 => {
            try writer.writeByte(6);
            try writer.writeAll(&addr.in6.sa.addr);
            // addr.in6.sa.port is already big-endian
            try writer.writeAll(std.mem.asBytes(&addr.in6.sa.port));
        },
        else => return error.UnsupportedAddressFamily,
    }
}

fn deserializeAddress(reader: anytype) !std.net.Address {
    const family = try reader.readByte();
    switch (family) {
        4 => {
            var ipv4: [4]u8 = undefined;
            try reader.readNoEof(&ipv4);
            var port_be: u16 = undefined;
            try reader.readNoEof(std.mem.asBytes(&port_be));
            // initIp4 expects host-endian port
            const port = std.mem.bigToNative(u16, port_be);
            return std.net.Address.initIp4(ipv4, port);
        },
        6 => {
            var ipv6: [16]u8 = undefined;
            try reader.readNoEof(&ipv6);
            var port_be: u16 = undefined;
            try reader.readNoEof(std.mem.asBytes(&port_be));
            // initIp6 expects host-endian port
            const port = std.mem.bigToNative(u16, port_be);
            return std.net.Address.initIp6(ipv6, port, 0, 0);
        },
        else => return error.InvalidAddressFamily,
    }
}
