const sync = @import("../../sync.zig");
const network = @import("../transport/mod.zig");
const Address = network.Address;
const std = @import("std");
const id = @import("../id.zig");
const kbucket = @import("kbucket.zig");
const providers_mod = @import("providers.zig");

/// In-memory target for Message.serialize (Message.send).
const MessageBuffer = struct {
    allocator: std.mem.Allocator,
    list: std.ArrayList(u8) = .empty,

    fn append(self: *MessageBuffer, bytes: []const u8) error{OutOfMemory}!usize {
        try self.list.appendSlice(self.allocator, bytes);
        return bytes.len;
    }

    fn writer(self: *MessageBuffer) network.Stream.GenericWriter(*MessageBuffer, error{OutOfMemory}, append) {
        return .{ .context = self };
    }
};

pub const MessageType = enum(u8) {
    PING = 0,
    PONG = 1,
    FIND_NODE = 2,
    FIND_NODE_RESPONSE = 3,
    FIND_VALUE = 4,
    FIND_VALUE_RESPONSE = 5,
    STORE = 6,
    DIAL_BACK = 7,
    /// Reply to STORE: whether the receiver kept the value.
    STORE_ACK = 8,
    /// Request a content-addressed block by CID.
    GET_BLOCK = 9,
    /// Reply to GET_BLOCK; data is null if the block is not held.
    BLOCK = 10,
    /// Register the (authenticated) sender as a provider of `key`.
    /// Answered with STORE_ACK.
    ADD_PROVIDER = 11,
    GET_PROVIDERS = 12,
    /// Reply to GET_PROVIDERS.
    PROVIDERS = 13,
    /// Push a content-addressed block; the receiver verifies it against the
    /// CID before storing. Answered with STORE_ACK.
    PUT_BLOCK = 14,
    /// Tell a peer that a device was revoked, signed by the revoking
    /// device's Ed25519 identity. Answered with STORE_ACK.
    REVOKE = 15,
    /// Ask a device which folders it shares. Answered with SHARES.
    GET_SHARES = 16,
    /// Reply to GET_SHARES: a dir block (storage/dag/codec.zig) whose
    /// entries map each share name to its current root CID.
    SHARES = 17,
    /// Ask a device for its swarm folder manifest. Answered with SWARM.
    GET_SWARM = 18,
    /// Reply to GET_SWARM: the encoded manifest (fs/manifest.zig).
    SWARM = 19,
    /// A new swarm key from a trusted device (device/rotation.zig).
    /// Answered with STORE_ACK.
    ROTATE_KEY = 20,
};

pub const FindValueResult = union(enum) {
    value: []const u8,
    closer_peers: []kbucket.PeerInfo,
};

/// Addresses a device announces about itself (local_addrs.zig).
pub const max_announced = 6;

/// A device's own addresses, sent with PING and PONG so the other side can
/// reach it on every network it is on, not only the one it saw.
pub const Announced = struct {
    addrs: [max_announced]Address = undefined,
    count: u8 = 0,

    pub fn slice(self: *const Announced) []const Address {
        return self.addrs[0..self.count];
    }
};

pub const MessagePayload = union(MessageType) {
    PING: struct { port: u16, announced: Announced = .{} },
    PONG: struct { announced: Announced = .{} },
    FIND_NODE: struct { target: id.NodeID },
    FIND_NODE_RESPONSE: struct { closer_peers: []kbucket.PeerInfo },
    FIND_VALUE: struct { key: id.NodeID },
    FIND_VALUE_RESPONSE: FindValueResult,
    STORE: struct { key: id.NodeID, value: []const u8 },
    DIAL_BACK: struct { port: u16 },
    STORE_ACK: struct { stored: bool },
    GET_BLOCK: struct { cid: [32]u8 },
    BLOCK: struct { data: ?[]const u8 },
    // No provider field: the receiver uses the connection's authenticated
    // node ID, so a peer cannot register anyone but itself.
    ADD_PROVIDER: struct { key: id.NodeID },
    GET_PROVIDERS: struct { key: id.NodeID },
    PROVIDERS: struct { providers: []const id.NodeID },
    PUT_BLOCK: struct { cid: [32]u8, data: []const u8 },
    REVOKE: struct {
        /// The revoked device's NodeID (hash of its Ed25519 public key).
        device_id: id.NodeID,
        /// The revoking device's public key; the receiver checks that it is
        /// locally trusted before honoring anything.
        signer_key: [32]u8,
        signature: [64]u8,
        /// Informational timestamp; not part of the signature.
        at: u64,
    },
    GET_SHARES: void,
    SHARES: struct { nickname: []const u8, listing: []const u8 },
    GET_SWARM: void,
    SWARM: struct { manifest: []const u8 },
    ROTATE_KEY: struct { epoch: u64, new_key: [32]u8, signer_key: [32]u8, signature: [64]u8 },
};

pub const Message = struct {
    sender_id: id.NodeID,
    payload: MessagePayload,

    /// Serializes the whole message in memory and hands it to `stream` in
    /// one write: one Yamux frame instead of one per field.
    pub fn send(self: Message, allocator: std.mem.Allocator, stream: network.Stream) !void {
        var buf: MessageBuffer = .{ .allocator = allocator };
        defer buf.list.deinit(allocator);
        try self.serialize(buf.writer());
        try stream.writer().writeAll(buf.list.items);
    }

    pub fn serialize(self: Message, writer: anytype) !void {
        // 1. Write Message Type
        try writer.writeByte(@intFromEnum(self.payload));

        // 2. Write Sender ID
        try writer.writeAll(&self.sender_id.bytes);

        // 3. Write Payload
        switch (self.payload) {
            .PING => |p| {
                try writer.writeInt(u16, p.port, .big);
                try writeAnnounced(p.announced, writer);
            },
            .PONG => |p| try writeAnnounced(p.announced, writer),
            .FIND_NODE => |p| {
                try writer.writeAll(&p.target.bytes);
            },
            .FIND_NODE_RESPONSE => |p| try writePeers(p.closer_peers, writer),
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
                        try writePeers(peers, writer);
                    },
                }
            },
            .STORE => |p| {
                try writer.writeAll(&p.key.bytes);
                try writer.writeInt(u32, @intCast(p.value.len), .big);
                try writer.writeAll(p.value);
            },
            .DIAL_BACK => |p| {
                try writer.writeInt(u16, p.port, .big);
            },
            .STORE_ACK => |p| try writer.writeByte(@intFromBool(p.stored)),
            .GET_BLOCK => |p| try writer.writeAll(&p.cid),
            .ADD_PROVIDER => |p| try writer.writeAll(&p.key.bytes),
            .GET_PROVIDERS => |p| try writer.writeAll(&p.key.bytes),
            .PROVIDERS => |p| {
                if (p.providers.len > providers_mod.max_per_key) return error.TooManyProviders;
                try writer.writeByte(@intCast(p.providers.len));
                for (p.providers) |provider| try writer.writeAll(&provider.bytes);
            },
            .BLOCK => |p| {
                const data = p.data orelse return writer.writeByte(0);
                try writer.writeByte(1);
                try writer.writeInt(u32, @intCast(data.len), .big);
                try writer.writeAll(data);
            },
            .PUT_BLOCK => |p| {
                try writer.writeAll(&p.cid);
                try writer.writeInt(u32, @intCast(p.data.len), .big);
                try writer.writeAll(p.data);
            },
            .REVOKE => |p| {
                try writer.writeAll(&p.device_id.bytes);
                try writer.writeAll(&p.signer_key);
                try writer.writeInt(u64, p.at, .big);
                try writer.writeAll(&p.signature);
            },
            .GET_SHARES => {},
            .SHARES => |p| {
                const nick = p.nickname[0..@min(p.nickname.len, max_nickname_len)];
                try writer.writeByte(@intCast(nick.len));
                try writer.writeAll(nick);
                try writer.writeInt(u32, @intCast(p.listing.len), .big);
                try writer.writeAll(p.listing);
            },
            .GET_SWARM => {},
            .ROTATE_KEY => |p| {
                try writer.writeInt(u64, p.epoch, .big);
                try writer.writeAll(&p.new_key);
                try writer.writeAll(&p.signer_key);
                try writer.writeAll(&p.signature);
            },
            .SWARM => |p| {
                try writer.writeInt(u32, @intCast(p.manifest.len), .big);
                try writer.writeAll(p.manifest);
            },
        }
    }

    pub fn deserialize(allocator: std.mem.Allocator, reader: anytype) !Message {
        const type_byte = try reader.readByte();
        const msg_type = std.enums.fromInt(MessageType, type_byte) orelse return error.InvalidMessageType;

        var sender_id: id.NodeID = undefined;
        try reader.readNoEof(&sender_id.bytes);

        const payload = switch (msg_type) {
            .PING => blk: {
                const port = try reader.readInt(u16, .big);
                break :blk MessagePayload{ .PING = .{ .port = port, .announced = try readAnnounced(reader) } };
            },
            .PONG => MessagePayload{ .PONG = .{ .announced = try readAnnounced(reader) } },
            .FIND_NODE => blk: {
                var target: id.NodeID = undefined;
                try reader.readNoEof(&target.bytes);
                break :blk MessagePayload{ .FIND_NODE = .{ .target = target } };
            },
            .FIND_NODE_RESPONSE => MessagePayload{
                .FIND_NODE_RESPONSE = .{ .closer_peers = try readPeers(allocator, reader) },
            },
            .FIND_VALUE => blk: {
                var key: id.NodeID = undefined;
                try reader.readNoEof(&key.bytes);
                break :blk MessagePayload{ .FIND_VALUE = .{ .key = key } };
            },
            .FIND_VALUE_RESPONSE => blk: {
                const found_byte = try reader.readByte();
                if (found_byte == 1) {
                    break :blk MessagePayload{ .FIND_VALUE_RESPONSE = .{ .value = try readValue(allocator, reader) } };
                }
                break :blk MessagePayload{ .FIND_VALUE_RESPONSE = .{ .closer_peers = try readPeers(allocator, reader) } };
            },
            .STORE => blk: {
                var key: id.NodeID = undefined;
                try reader.readNoEof(&key.bytes);
                break :blk MessagePayload{ .STORE = .{ .key = key, .value = try readValue(allocator, reader) } };
            },
            .DIAL_BACK => blk: {
                const port = try reader.readInt(u16, .big);
                break :blk MessagePayload{ .DIAL_BACK = .{ .port = port } };
            },
            .STORE_ACK => MessagePayload{ .STORE_ACK = .{ .stored = try readBool(reader) } },
            .GET_BLOCK => blk: {
                var cid: [32]u8 = undefined;
                try reader.readNoEof(&cid);
                break :blk MessagePayload{ .GET_BLOCK = .{ .cid = cid } };
            },
            .ADD_PROVIDER => blk: {
                var key: id.NodeID = undefined;
                try reader.readNoEof(&key.bytes);
                break :blk MessagePayload{ .ADD_PROVIDER = .{ .key = key } };
            },
            .GET_PROVIDERS => blk: {
                var key: id.NodeID = undefined;
                try reader.readNoEof(&key.bytes);
                break :blk MessagePayload{ .GET_PROVIDERS = .{ .key = key } };
            },
            .PROVIDERS => MessagePayload{ .PROVIDERS = .{ .providers = try readProviders(allocator, reader) } },
            .BLOCK => MessagePayload{ .BLOCK = .{
                .data = if (try readBool(reader)) try readValue(allocator, reader) else null,
            } },
            .PUT_BLOCK => blk: {
                var cid: [32]u8 = undefined;
                try reader.readNoEof(&cid);
                break :blk MessagePayload{ .PUT_BLOCK = .{ .cid = cid, .data = try readValue(allocator, reader) } };
            },
            .REVOKE => blk: {
                var device: id.NodeID = undefined;
                try reader.readNoEof(&device.bytes);
                var signer_key: [32]u8 = undefined;
                try reader.readNoEof(&signer_key);
                const at = try reader.readInt(u64, .big);
                var signature: [64]u8 = undefined;
                try reader.readNoEof(&signature);
                break :blk MessagePayload{ .REVOKE = .{ .device_id = device, .signer_key = signer_key, .at = at, .signature = signature } };
            },
            .GET_SHARES => MessagePayload{ .GET_SHARES = {} },
            .SHARES => blk: {
                const nick_len = try reader.readByte();
                const nickname = try allocator.alloc(u8, nick_len);
                errdefer allocator.free(nickname);
                try reader.readNoEof(nickname);
                break :blk MessagePayload{ .SHARES = .{ .nickname = nickname, .listing = try readValue(allocator, reader) } };
            },
            .GET_SWARM => MessagePayload{ .GET_SWARM = {} },
            .ROTATE_KEY => blk: {
                const epoch = try reader.readInt(u64, .big);
                var new_key: [32]u8 = undefined;
                try reader.readNoEof(&new_key);
                var signer_key: [32]u8 = undefined;
                try reader.readNoEof(&signer_key);
                var signature: [64]u8 = undefined;
                try reader.readNoEof(&signature);
                break :blk MessagePayload{ .ROTATE_KEY = .{ .epoch = epoch, .new_key = new_key, .signer_key = signer_key, .signature = signature } };
            },
            .SWARM => MessagePayload{ .SWARM = .{ .manifest = try readValue(allocator, reader) } },
        };

        return Message{
            .sender_id = sender_id,
            .payload = payload,
        };
    }

    /// Longest device nickname a SHARES reply carries; longer ones are cut.
    pub const max_nickname_len = 64;

    /// Upper bound on a value carried by STORE / FIND_VALUE_RESPONSE.
    pub const max_value_len = 10 * 1024 * 1024;

    fn writePeers(peers: []const kbucket.PeerInfo, writer: anytype) !void {
        if (peers.len > 255) return error.TooManyPeers;
        try writer.writeByte(@intCast(peers.len));
        for (peers) |peer| {
            try writer.writeAll(&peer.id.bytes);
            try writer.writeByte(peer.addrs_count);
            for (0..peer.addrs_count) |i| {
                try serializeAddress(peer.addresses[i], writer);
            }
        }
    }

    /// Reads a peer list; the returned slice is caller-owned.
    fn readPeers(allocator: std.mem.Allocator, reader: anytype) ![]kbucket.PeerInfo {
        const count = try reader.readByte();
        if (count > kbucket.K) return error.TooManyPeers;

        const peers = try allocator.alloc(kbucket.PeerInfo, count);
        errdefer allocator.free(peers);

        for (peers) |*peer| {
            var peer_id: id.NodeID = undefined;
            try reader.readNoEof(&peer_id.bytes);
            peer.* = .{ .id = peer_id, .last_seen = sync.timestamp() };

            const addrs_count = try reader.readByte();
            if (addrs_count > kbucket.MAX_PEER_ADDRESSES) return error.TooManyAddresses;

            for (0..addrs_count) |_| {
                _ = peer.addAddress(try deserializeAddress(reader));
            }
        }
        return peers;
    }

    fn readProviders(allocator: std.mem.Allocator, reader: anytype) ![]id.NodeID {
        const count = try reader.readByte();
        if (count > providers_mod.max_per_key) return error.TooManyProviders;
        const list = try allocator.alloc(id.NodeID, count);
        errdefer allocator.free(list);
        for (list) |*provider| try reader.readNoEof(&provider.bytes);
        return list;
    }

    fn readBool(reader: anytype) !bool {
        return switch (try reader.readByte()) {
            0 => false,
            1 => true,
            else => error.InvalidMessage,
        };
    }

    /// Reads a length-prefixed value; the returned slice is caller-owned.
    fn readValue(allocator: std.mem.Allocator, reader: anytype) ![]u8 {
        const len = try reader.readInt(u32, .big);
        if (len > max_value_len) return error.ValueTooLarge;

        const val = try allocator.alloc(u8, len);
        errdefer allocator.free(val);
        try reader.readNoEof(val);
        return val;
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
            .BLOCK => |p| if (p.data) |d| allocator.free(d),
            .PUT_BLOCK => |p| allocator.free(p.data),
            .PROVIDERS => |p| allocator.free(p.providers),
            .SHARES => |p| {
                allocator.free(p.nickname);
                allocator.free(p.listing);
            },
            .SWARM => |p| allocator.free(p.manifest),
            else => {},
        }
    }
};

fn writeAnnounced(a: Announced, writer: anytype) !void {
    try writer.writeByte(a.count);
    for (a.slice()) |addr| try serializeAddress(addr, writer);
}

fn readAnnounced(reader: anytype) !Announced {
    var a: Announced = .{};
    const count = try reader.readByte();
    if (count > max_announced) return error.TooManyAddresses;
    for (0..count) |i| a.addrs[i] = try deserializeAddress(reader);
    a.count = count;
    return a;
}

fn serializeAddress(addr: Address, writer: anytype) !void {
    switch (addr.ip) {
        .ip4 => |ip4| {
            try writer.writeByte(4);
            try writer.writeAll(&ip4.bytes);
            const port_be = std.mem.nativeToBig(u16, ip4.port);
            try writer.writeAll(std.mem.asBytes(&port_be));
        },
        .ip6 => |ip6| {
            try writer.writeByte(6);
            try writer.writeAll(&ip6.bytes);
            const port_be = std.mem.nativeToBig(u16, ip6.port);
            try writer.writeAll(std.mem.asBytes(&port_be));
        },
    }
}

fn deserializeAddress(reader: anytype) !Address {
    const family = try reader.readByte();
    switch (family) {
        4 => {
            var ipv4: [4]u8 = undefined;
            try reader.readNoEof(&ipv4);
            var port_be: u16 = undefined;
            try reader.readNoEof(std.mem.asBytes(&port_be));
            const port = std.mem.bigToNative(u16, port_be);
            return Address.initIp4(ipv4, port);
        },
        6 => {
            var ipv6: [16]u8 = undefined;
            try reader.readNoEof(&ipv6);
            var port_be: u16 = undefined;
            try reader.readNoEof(std.mem.asBytes(&port_be));
            const port = std.mem.bigToNative(u16, port_be);
            return Address.initIp6(ipv6, port, 0, 0);
        },
        else => return error.InvalidAddressFamily,
    }
}

const TestBuffer = struct {
    list: std.ArrayList(u8) = .empty,
    pos: usize = 0,
    allocator: std.mem.Allocator,

    fn writer(self: *TestBuffer) network.Stream.GenericWriter(*TestBuffer, anyerror, write) {
        return .{ .context = self };
    }
    fn reader(self: *TestBuffer) network.Stream.GenericReader(*TestBuffer, anyerror, read) {
        return .{ .context = self };
    }
    fn write(self: *TestBuffer, bytes: []const u8) anyerror!usize {
        try self.list.appendSlice(self.allocator, bytes);
        return bytes.len;
    }
    fn read(self: *TestBuffer, dest: []u8) anyerror!usize {
        const n = @min(dest.len, self.list.items.len - self.pos);
        @memcpy(dest[0..n], self.list.items[self.pos..][0..n]);
        self.pos += n;
        return n;
    }
};

test "rpc: block exchange and store ack round trip" {
    const allocator = std.testing.allocator;
    const sender = id.NodeID{ .bytes = [_]u8{3} ** 32 };
    var buf = TestBuffer{ .allocator = allocator };
    defer buf.list.deinit(allocator);

    const messages = [_]Message{
        .{ .sender_id = sender, .payload = .{ .STORE_ACK = .{ .stored = true } } },
        .{ .sender_id = sender, .payload = .{ .GET_BLOCK = .{ .cid = [_]u8{9} ** 32 } } },
        .{ .sender_id = sender, .payload = .{ .BLOCK = .{ .data = "block bytes" } } },
        .{ .sender_id = sender, .payload = .{ .BLOCK = .{ .data = null } } },
        .{ .sender_id = sender, .payload = .{ .PUT_BLOCK = .{ .cid = [_]u8{7} ** 32, .data = "block bytes" } } },
        .{ .sender_id = sender, .payload = .{ .REVOKE = .{ .device_id = sender, .signer_key = [_]u8{8} ** 32, .signature = [_]u8{9} ** 64, .at = 42 } } },
        .{ .sender_id = sender, .payload = .{ .PROVIDERS = .{ .providers = &.{ sender, sender } } } },
    };
    for (messages) |m| try m.serialize(buf.writer());

    const ack = try Message.deserialize(allocator, buf.reader());
    defer ack.deinit(allocator);
    try std.testing.expect(ack.payload.STORE_ACK.stored);

    const get = try Message.deserialize(allocator, buf.reader());
    defer get.deinit(allocator);
    try std.testing.expectEqual([_]u8{9} ** 32, get.payload.GET_BLOCK.cid);

    const block = try Message.deserialize(allocator, buf.reader());
    defer block.deinit(allocator);
    try std.testing.expectEqualStrings("block bytes", block.payload.BLOCK.data.?);

    const missing = try Message.deserialize(allocator, buf.reader());
    defer missing.deinit(allocator);
    try std.testing.expect(missing.payload.BLOCK.data == null);

    const pushed = try Message.deserialize(allocator, buf.reader());
    defer pushed.deinit(allocator);
    try std.testing.expectEqual([_]u8{7} ** 32, pushed.payload.PUT_BLOCK.cid);
    try std.testing.expectEqualStrings("block bytes", pushed.payload.PUT_BLOCK.data);

    const revoke = try Message.deserialize(allocator, buf.reader());
    defer revoke.deinit(allocator);
    try std.testing.expect(revoke.payload.REVOKE.device_id.eql(sender));
    try std.testing.expectEqual([_]u8{8} ** 32, revoke.payload.REVOKE.signer_key);
    try std.testing.expectEqual(@as(u64, 42), revoke.payload.REVOKE.at);

    const providers = try Message.deserialize(allocator, buf.reader());
    defer providers.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 2), providers.payload.PROVIDERS.providers.len);
    try std.testing.expect(providers.payload.PROVIDERS.providers[1].eql(sender));
}

test "rpc: malformed bool is rejected" {
    var buf = TestBuffer{ .allocator = std.testing.allocator };
    defer buf.list.deinit(std.testing.allocator);
    try buf.list.append(std.testing.allocator, @intFromEnum(MessageType.STORE_ACK));
    try buf.list.appendSlice(std.testing.allocator, &([_]u8{0} ** 32));
    try buf.list.append(std.testing.allocator, 7);
    try std.testing.expectError(error.InvalidMessage, Message.deserialize(std.testing.allocator, buf.reader()));
}
