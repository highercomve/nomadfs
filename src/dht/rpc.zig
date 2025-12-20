const std = @import("std");
const id = @import("id.zig");
const kbucket = @import("kbucket.zig");

pub const MessageType = enum(u8) {
    PING = 0,
    PONG = 1,
    FIND_NODE = 2,
    FIND_NODE_RESPONSE = 3,
    FIND_VALUE = 4,
    FIND_VALUE_RESPONSE = 5,
    STORE = 6,
};

pub const FindValueResult = union(enum) {
    value: []const u8,
    closer_peers: []kbucket.PeerInfo,
};

pub const MessagePayload = union(MessageType) {
    PING: struct { port: u16 },
    PONG: void,
    FIND_NODE: struct { target: id.NodeID },
    FIND_NODE_RESPONSE: struct { closer_peers: []kbucket.PeerInfo },
    FIND_VALUE: struct { key: id.NodeID },
    FIND_VALUE_RESPONSE: FindValueResult,
    STORE: struct { key: id.NodeID, value: []const u8 },
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
            .PING => |p| {
                try writer.writeInt(u16, p.port, .big);
            },
            .PONG => {},
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
            .FIND_VALUE => |p| {
                try writer.writeAll(&p.key.bytes);
            },
            .FIND_VALUE_RESPONSE => |p| {
                switch (p) {
                    .value => |val| {
                        try writer.writeByte(1); // 1 indicates found value
                        try writer.writeInt(u32, @intCast(val.len), .big);
                        try writer.writeAll(val);
                    },
                    .closer_peers => |peers| {
                        try writer.writeByte(0); // 0 indicates closer peers
                        if (peers.len > 255) return error.TooManyPeers;
                        try writer.writeByte(@intCast(peers.len));
                        for (peers) |peer| {
                            try writer.writeAll(&peer.id.bytes);
                            try serializeAddress(peer.address, writer);
                        }
                    },
                }
            },
            .STORE => |p| {
                try writer.writeAll(&p.key.bytes);
                try writer.writeInt(u32, @intCast(p.value.len), .big);
                try writer.writeAll(p.value);
            },
        }
    }

    pub fn deserialize(allocator: std.mem.Allocator, reader: anytype) !Message {
        const type_byte = try reader.readByte();
        const msg_type = std.meta.intToEnum(MessageType, type_byte) catch return error.InvalidMessageType;

        var sender_id: id.NodeID = undefined;
        try reader.readNoEof(&sender_id.bytes);

        const payload = switch (msg_type) {
            .PING => blk: {
                const port = try reader.readInt(u16, .big);
                break :blk MessagePayload{ .PING = .{ .port = port } };
            },
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
            .FIND_VALUE => blk: {
                var key: id.NodeID = undefined;
                try reader.readNoEof(&key.bytes);
                break :blk MessagePayload{ .FIND_VALUE = .{ .key = key } };
            },
            .FIND_VALUE_RESPONSE => blk: {
                const found_byte = try reader.readByte();
                if (found_byte == 1) {
                    const len = try reader.readInt(u32, .big);
                    // Sanity check for max value size (e.g., 10MB)
                    if (len > 10 * 1024 * 1024) return error.ValueTooLarge;

                    const val = try allocator.alloc(u8, len);
                    errdefer allocator.free(val);
                    try reader.readNoEof(val);

                    break :blk MessagePayload{ .FIND_VALUE_RESPONSE = .{ .value = val } };
                } else {
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
                    break :blk MessagePayload{ .FIND_VALUE_RESPONSE = .{ .closer_peers = peers } };
                }
            },
            .STORE => blk: {
                var key: id.NodeID = undefined;
                try reader.readNoEof(&key.bytes);
                const len = try reader.readInt(u32, .big);
                // Sanity check for max value size
                if (len > 10 * 1024 * 1024) return error.ValueTooLarge;

                const val = try allocator.alloc(u8, len);
                errdefer allocator.free(val);
                try reader.readNoEof(val);

                break :blk MessagePayload{ .STORE = .{ .key = key, .value = val } };
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
            .FIND_VALUE_RESPONSE => |p| {
                switch (p) {
                    .value => |v| allocator.free(v),
                    .closer_peers => |peers| allocator.free(peers),
                }
            },
            .STORE => |p| allocator.free(p.value),
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
