const sync = @import("../../sync.zig");
const network = @import("../transport/mod.zig");
const Address = network.Address;
const std = @import("std");
const id = @import("../id.zig");
const kbucket = @import("kbucket.zig");
const providers_mod = @import("providers.zig");
const pairing = @import("../../device/pairing.zig");
const policy_mod = @import("../../device/policy.zig");
const codec = @import("../../storage/dag/codec.zig");

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
    // 14 was PUT_BLOCK (push replication, removed: holders pull).
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
    /// Reply to GET_SWARM: the encoded manifest (fs/manifest.zig), or nothing
/// when the asker's digest (`have`) says it has the same content.
    SWARM = 19,
    /// A new swarm key from a trusted device (device/rotation.zig).
    /// Answered with STORE_ACK.
    ROTATE_KEY = 20,
    /// Ask a device to pipe this stream to `target` (transport/relay.zig).
    /// Answered with RELAY_ACK; if ok, the stream then carries the
    /// connection to `target`.
    RELAY_CONNECT = 21,
    /// From a relay: `from` is connecting through this stream. Answered
    /// with RELAY_ACK; then the stream carries that connection.
    RELAY_INCOMING = 22,
    RELAY_ACK = 23,
    /// A member vouches that a device belongs to the swarm, signed by the
    /// member's Ed25519 identity (device/trust.zig applyAdmission). Answered
    /// with STORE_ACK.
    ADMIT = 24,
    /// Ask a trusted device about itself (node_info.zig). Answered with
    /// NODE_INFO; empty when the asker isn't trusted.
    GET_NODE_INFO = 25,
    NODE_INFO = 26,
    /// A signed swarm setting (device/policy.zig). Answered with STORE_ACK,
    /// `stored` also for one not newer than the receiver's.
    POLICY = 27,
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

/// What a device says about itself in every PING and PONG (one trailing
/// byte both sides can read). Readers of the holder registry use bit 0
/// (it keeps swarm backups) and bit 2 (its network is metered).
pub const Roles = struct {
    /// The device keeps the swarm folder's files as they appear.
    pub const swarm_backup: u8 = 1 << 0;
    /// The device accepts copies of files it did not touch (stage 3).
    pub const accepts_copies: u8 = 1 << 1;
    /// Transfers to it should wait or stay small (mobile data).
    pub const metered: u8 = 1 << 2;
};

pub const MessagePayload = union(MessageType) {
    /// `swarm`: the sender's swarm folder manifest digest (zeros: none), so
    /// peers fetch its manifest only when it differs from theirs.
    PING: struct { port: u16, announced: Announced = .{}, roles: u8 = 0, swarm: [32]u8 = no_swarm },
    /// `port`: where the responder listens. A PING can travel over a
    /// connection the responder opened, whose source port is not that.
    /// Sent last, so 0.3.2 and older read the rest and ignore it; null
    /// from them.
    PONG: struct { announced: Announced = .{}, port: ?u16 = null, roles: u8 = 0, swarm: [32]u8 = no_swarm },
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
    /// `have`: the digest of the asker's manifest (Manifest.digest).
    GET_SWARM: struct { have: [32]u8 },
    SWARM: struct { manifest: []const u8 },
    ROTATE_KEY: struct { epoch: u64, new_key: [32]u8, signer_key: [32]u8, signature: [64]u8 },
    RELAY_CONNECT: struct { target: id.NodeID },
    RELAY_INCOMING: struct { from: id.NodeID },
    RELAY_ACK: struct { ok: bool },
    ADMIT: Admit,
    GET_NODE_INFO: void,
    NODE_INFO: struct { info: []const u8 },
    POLICY: struct { record: [policy_mod.Record.encoded_len]u8 },
};

/// A member's signed vouch for another device (ADMIT). The label is a fixed
/// buffer, so the message needs no allocation.
pub const Admit = struct {
    public_key: [32]u8,
    transport_key: [32]u8,
    label: [max_admit_label]u8 = [_]u8{0} ** max_admit_label,
    label_len: u8 = 0,
    /// When the device was admitted (signed).
    at: u64,
    signer_key: [32]u8,
    signature: [64]u8,

    pub fn labelSlice(self: *const Admit) []const u8 {
        return self.label[0..self.label_len];
    }
};

/// Longest device label an ADMIT carries: the pairing nickname limit.
pub const max_admit_label = pairing.max_nickname_len;

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
                try writer.writeByte(p.roles);
                try writer.writeAll(&p.swarm);
            },
            .PONG => |p| {
                try writeAnnounced(p.announced, writer);
                if (p.port) |port| try writer.writeInt(u16, port, .big);
                try writer.writeByte(p.roles);
                try writer.writeAll(&p.swarm);
            },
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
                        try writer.writeInt(u32, try valueLen(val.len), .big);
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
                try writer.writeInt(u32, try valueLen(p.value.len), .big);
                try writer.writeAll(p.value);
            },
            .DIAL_BACK => |p| {
                try writer.writeInt(u16, p.port, .big);
            },
            .STORE_ACK => |p| try writer.writeByte(@intFromBool(p.stored)),
            .RELAY_CONNECT => |p| try writer.writeAll(&p.target.bytes),
            .RELAY_INCOMING => |p| try writer.writeAll(&p.from.bytes),
            .RELAY_ACK => |p| try writer.writeByte(@intFromBool(p.ok)),
            .ADMIT => |p| {
                try writer.writeAll(&p.public_key);
                try writer.writeAll(&p.transport_key);
                if (p.label_len > max_admit_label) return error.InvalidNickname;
                try writer.writeByte(p.label_len);
                try writer.writeAll(p.label[0..p.label_len]);
                try writer.writeInt(u64, p.at, .big);
                try writer.writeAll(&p.signer_key);
                try writer.writeAll(&p.signature);
            },
            .GET_BLOCK => |p| try writer.writeAll(&p.cid),
            .ADD_PROVIDER => |p| try writer.writeAll(&p.key.bytes),
            .GET_PROVIDERS => |p| try writer.writeAll(&p.key.bytes),
            .PROVIDERS => |p| {
                if (p.providers.len > providers_mod.max_per_key) return error.TooManyProviders;
                try writer.writeByte(std.math.cast(u8, p.providers.len) orelse return error.TooManyProviders);
                for (p.providers) |provider| try writer.writeAll(&provider.bytes);
            },
            .BLOCK => |p| {
                const data = p.data orelse return writer.writeByte(0);
                try writer.writeByte(1);
                try writer.writeInt(u32, try valueLen(data.len), .big);
                try writer.writeAll(data);
            },
            .REVOKE => |p| {
                try writer.writeAll(&p.device_id.bytes);
                try writer.writeAll(&p.signer_key);
                try writer.writeInt(u64, p.at, .big);
                try writer.writeAll(&p.signature);
            },
            .GET_SHARES => {},
            .SHARES => |p| {
                try writeNickname(p.nickname, writer);
                try writer.writeInt(u32, try valueLen(p.listing.len), .big);
                try writer.writeAll(p.listing);
            },
            .GET_SWARM => |p| try writer.writeAll(&p.have),
            .ROTATE_KEY => |p| {
                try writer.writeInt(u64, p.epoch, .big);
                try writer.writeAll(&p.new_key);
                try writer.writeAll(&p.signer_key);
                try writer.writeAll(&p.signature);
            },
            .SWARM => |p| {
                try writer.writeInt(u32, try valueLenMax(p.manifest.len, max_swarm_len), .big);
                try writer.writeAll(p.manifest);
            },
            .GET_NODE_INFO => {},
            .POLICY => |p| try writer.writeAll(&p.record),
            .NODE_INFO => |p| {
                try writer.writeInt(u32, try valueLen(p.info.len), .big);
                try writer.writeAll(p.info);
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
                const announced = try readAnnounced(reader);
                // Before 0.3.3 the message ends here; roles arrive last.
                const roles: u8 = reader.readByte() catch 0;
                var swarm: [32]u8 = no_swarm;
                reader.readNoEof(&swarm) catch {
                    swarm = no_swarm;
                };
                break :blk MessagePayload{ .PING = .{ .port = port, .announced = announced, .roles = roles, .swarm = swarm } };
            },
            .PONG => blk: {
                const announced = try readAnnounced(reader);
                // Older nodes end the reply here and close the stream.
                const port: ?u16 = reader.readInt(u16, .big) catch null;
                const roles: u8 = reader.readByte() catch 0;
                var swarm: [32]u8 = no_swarm;
                reader.readNoEof(&swarm) catch {
                    swarm = no_swarm;
                };
                break :blk MessagePayload{ .PONG = .{ .announced = announced, .port = port, .roles = roles, .swarm = swarm } };
            },
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
                // Only the two tags the serializer writes; anything else is
                // not a peer list and must not be read as one.
                switch (try reader.readByte()) {
                    1 => break :blk MessagePayload{ .FIND_VALUE_RESPONSE = .{ .value = try readValueMax(allocator, reader, max_stored_value_len) } },
                    0 => break :blk MessagePayload{ .FIND_VALUE_RESPONSE = .{ .closer_peers = try readPeers(allocator, reader) } },
                    else => return error.InvalidMessage,
                }
            },
            .STORE => blk: {
                var key: id.NodeID = undefined;
                try reader.readNoEof(&key.bytes);
                break :blk MessagePayload{ .STORE = .{ .key = key, .value = try readValueMax(allocator, reader, max_stored_value_len) } };
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
                .data = if (try readBool(reader)) try readValueMax(allocator, reader, max_block_len) else null,
            } },
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
                if (nick_len > max_nickname_len) return error.InvalidNickname;
                const nickname = try allocator.alloc(u8, nick_len);
                errdefer allocator.free(nickname);
                try reader.readNoEof(nickname);
                if (!isValidNickname(nickname)) return error.InvalidNickname;
                const listing = try readValueMax(allocator, reader, max_block_len);
                errdefer allocator.free(listing);
                break :blk MessagePayload{ .SHARES = .{ .nickname = nickname, .listing = listing } };
            },
            .GET_SWARM => blk: {
                var have: [32]u8 = undefined;
                try reader.readNoEof(&have);
                break :blk MessagePayload{ .GET_SWARM = .{ .have = have } };
            },
            .GET_NODE_INFO => MessagePayload{ .GET_NODE_INFO = {} },
            .POLICY => blk: {
                var record: [policy_mod.Record.encoded_len]u8 = undefined;
                try reader.readNoEof(&record);
                break :blk MessagePayload{ .POLICY = .{ .record = record } };
            },
            .NODE_INFO => MessagePayload{ .NODE_INFO = .{ .info = try readValueMax(allocator, reader, max_node_info_len) } },
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
            .SWARM => MessagePayload{ .SWARM = .{ .manifest = try readValueMax(allocator, reader, max_swarm_len) } },
            .RELAY_CONNECT => blk: {
                var target: id.NodeID = undefined;
                try reader.readNoEof(&target.bytes);
                break :blk MessagePayload{ .RELAY_CONNECT = .{ .target = target } };
            },
            .RELAY_INCOMING => blk: {
                var from: id.NodeID = undefined;
                try reader.readNoEof(&from.bytes);
                break :blk MessagePayload{ .RELAY_INCOMING = .{ .from = from } };
            },
            .RELAY_ACK => MessagePayload{ .RELAY_ACK = .{ .ok = try readBool(reader) } },
            .ADMIT => blk: {
                var a: Admit = .{ .public_key = undefined, .transport_key = undefined, .at = 0, .signer_key = undefined, .signature = undefined };
                try reader.readNoEof(&a.public_key);
                try reader.readNoEof(&a.transport_key);
                a.label_len = try reader.readByte();
                if (a.label_len > max_admit_label) return error.InvalidNickname;
                try reader.readNoEof(a.label[0..a.label_len]);
                a.at = try reader.readInt(u64, .big);
                try reader.readNoEof(&a.signer_key);
                try reader.readNoEof(&a.signature);
                break :blk MessagePayload{ .ADMIT = a };
            },
        };

        return Message{
            .sender_id = sender_id,
            .payload = payload,
        };
    }

    /// Longest device nickname a SHARES reply carries; longer ones are cut.
    /// The same limit pairing applies to a device's name.
    pub const max_nickname_len = pairing.max_nickname_len;

    /// Upper bound on a value carried by STORE / FIND_VALUE_RESPONSE.
    pub const max_value_len = 10 * 1024 * 1024;

    fn writePeers(peers: []const kbucket.PeerInfo, writer: anytype) !void {
        try writer.writeByte(std.math.cast(u8, peers.len) orelse return error.TooManyPeers);
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
                const addr = try deserializeAddress(reader);
                if (@import("../local_addrs.zig").classify(addr) != .invalid)
                    _ = peer.addAddressFrom(addr, .hearsay, peer.last_seen);
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

    /// Reads a length-prefixed value; the returned slice is caller-owned. The
    /// buffer grows as bytes arrive, so a peer that declares a large length and
    /// then stalls costs only the bytes it actually sent.
    fn readValue(allocator: std.mem.Allocator, reader: anytype) ![]u8 {
        return readValueMax(allocator, reader, max_value_len);
    }

    fn readValueMax(allocator: std.mem.Allocator, reader: anytype, max: usize) ![]u8 {
        const len = try reader.readInt(u32, .big);
        if (len > max) return error.ValueTooLarge;

        var val: std.ArrayList(u8) = .empty;
        errdefer val.deinit(allocator);
        var remaining: usize = len;
        while (remaining > 0) {
            const n = @min(remaining, read_chunk_len);
            const start = val.items.len;
            try val.resize(allocator, start + n);
            try reader.readNoEof(val.items[start..]);
            remaining -= n;
        }
        return val.toOwnedSlice(allocator);
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
            .PROVIDERS => |p| allocator.free(p.providers),
            .SHARES => |p| {
                allocator.free(p.nickname);
                allocator.free(p.listing);
            },
            .SWARM => |p| allocator.free(p.manifest),
            .NODE_INFO => |p| allocator.free(p.info),
            else => {},
        }
    }
};

/// Bytes read from the stream per step of readValue.
const read_chunk_len = 64 * 1024;

/// Length prefix of a value the receiver accepts (readValue). A value over
/// Message.max_value_len fails here instead of being sent and then rejected.
fn valueLen(len: usize) !u32 {
    return valueLenMax(len, Message.max_value_len);
}

fn valueLenMax(len: usize, max: usize) !u32 {
    if (len > max) return error.ValueTooLarge;
    return std.math.cast(u32, len) orelse error.ValueTooLarge;
}

/// The largest swarm folder manifest a SWARM reply carries: a whole photo
/// library's manifest is tens of MiB, more than other values. The folder
/// caps its manifest below this (checked in node.zig).
pub const max_swarm_len = 64 * 1024 * 1024;

/// PING/PONG `swarm` when the sender has no swarm folder.
pub const no_swarm = [_]u8{0} ** 32;

/// The largest NODE_INFO (node_info.zig encodes within it).
pub const max_node_info_len = 1024;

/// Each message's values are bounded before they're read, so a peer can't
/// make a handler buffer more than its type allows (256 handlers at the
/// general 10 MiB limit would be 2.5 GiB).
/// A DHT value (STORE, FIND_VALUE): node.zig's StoreLimits keeps no larger.
pub const max_stored_value_len = 64 * 1024;
/// A block (BLOCK) or a folder listing (SHARES): the largest block, a
/// directory block.
pub const max_block_len = codec.max_dir_block_len;

fn isPrintableAscii(byte: u8) bool {
    return byte >= 0x20 and byte <= 0x7e;
}

/// A SHARES nickname: printable ASCII within the pairing limit. Empty is fine
/// (a device without a name).
fn isValidNickname(nickname: []const u8) bool {
    if (nickname.len > Message.max_nickname_len) return false;
    for (nickname) |byte| {
        if (!isPrintableAscii(byte)) return false;
    }
    return true;
}

/// Writes the nickname as the receiver will accept it. A name this device
/// cannot send as printable ASCII keeps its length, with each other byte
/// replaced by '?', so peers still get the listing.
fn writeNickname(nickname: []const u8, writer: anytype) !void {
    const n = @min(nickname.len, Message.max_nickname_len);
    var buf: [Message.max_nickname_len]u8 = undefined;
    for (nickname[0..n], buf[0..n]) |byte, *out| {
        out.* = if (isPrintableAscii(byte)) byte else '?';
    }
    try writer.writeByte(std.math.cast(u8, n) orelse return error.InvalidNickname);
    try writer.writeAll(buf[0..n]);
}

fn writeAnnounced(a: Announced, writer: anytype) !void {
    try writer.writeByte(a.count);
    for (a.slice()) |addr| try serializeAddress(addr, writer);
}

fn readAnnounced(reader: anytype) !Announced {
    var a: Announced = .{};
    const count = try reader.readByte();
    if (count > max_announced) return error.TooManyAddresses;
    for (0..count) |_| {
        const addr = try deserializeAddress(reader);
        if (@import("../local_addrs.zig").classify(addr) == .invalid) continue;
        a.addrs[a.count] = addr;
        a.count += 1;
    }
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

test "rpc: PONG carries the listening port, and reads without it from older nodes" {
    const allocator = std.testing.allocator;
    const sender = id.NodeID{ .bytes = [_]u8{4} ** 32 };
    var announced: Announced = .{};
    announced.addrs[0] = Address.initIp4(.{ 100, 123, 189, 53 }, 7865);
    announced.count = 1;

    var buf = TestBuffer{ .allocator = allocator };
    defer buf.list.deinit(allocator);
    try (Message{ .sender_id = sender, .payload = .{ .PONG = .{ .announced = announced, .port = 7865, .roles = Roles.swarm_backup | Roles.metered, .swarm = [_]u8{9} ** 32 } } }).serialize(buf.writer());
    const pong = try Message.deserialize(allocator, buf.reader());
    defer pong.deinit(allocator);
    try std.testing.expectEqual(@as(?u16, 7865), pong.payload.PONG.port);
    try std.testing.expectEqual(@as(u8, 1), pong.payload.PONG.announced.count);
    try std.testing.expectEqual(Roles.swarm_backup | Roles.metered, pong.payload.PONG.roles);
    try std.testing.expectEqual([_]u8{9} ** 32, pong.payload.PONG.swarm);

    // 0.3.2 and older: the addresses, then the stream ends.
    var old = TestBuffer{ .allocator = allocator };
    defer old.list.deinit(allocator);
    try (Message{ .sender_id = sender, .payload = .{ .PONG = .{ .announced = announced } } }).serialize(old.writer());
    // The roles byte and the swarm digest trail: an old peer's message ends before them.
    old.list.items.len -= 1 + 32; // roles and swarm digest
    const old_pong = try Message.deserialize(allocator, old.reader());
    defer old_pong.deinit(allocator);
    try std.testing.expectEqual(@as(?u16, null), old_pong.payload.PONG.port);
    try std.testing.expectEqual(@as(u8, 1), old_pong.payload.PONG.announced.count);
    try std.testing.expectEqual(@as(u8, 0), old_pong.payload.PONG.roles);

    // Same for PING: a full round trip, then the pre-roles short form.
    var ping_buf = TestBuffer{ .allocator = allocator };
    defer ping_buf.list.deinit(allocator);
    try (Message{ .sender_id = sender, .payload = .{ .PING = .{ .port = 7865, .announced = announced, .roles = Roles.metered } } }).serialize(ping_buf.writer());
    const ping = try Message.deserialize(allocator, ping_buf.reader());
    defer ping.deinit(allocator);
    try std.testing.expectEqual(@as(u16, 7865), ping.payload.PING.port);
    try std.testing.expectEqual(Roles.metered, ping.payload.PING.roles);

    try (Message{ .sender_id = sender, .payload = .{ .PING = .{ .port = 7865, .announced = announced } } }).serialize(old.writer());
    old.list.items.len -= 1 + 32; // roles and swarm digest
    const old_ping = try Message.deserialize(allocator, old.reader());
    defer old_ping.deinit(allocator);
    try std.testing.expectEqual(@as(u16, 7865), old_ping.payload.PING.port);
    try std.testing.expectEqual(@as(u8, 0), old_ping.payload.PING.roles);
}

test "rpc: readValue bounds allocation before payload arrival" {
    var input = TestBuffer{ .allocator = std.testing.allocator };
    defer input.list.deinit(std.testing.allocator);
    try input.writer().writeInt(u32, Message.max_value_len, .big);
    var memory: [128 * 1024]u8 = undefined;
    var fixed = std.heap.FixedBufferAllocator.init(&memory);
    try std.testing.expectError(error.EndOfStream, Message.readValue(fixed.allocator(), input.reader()));
    input.pos = 0;
    input.list.clearRetainingCapacity();
    try input.writer().writeInt(u32, Message.max_value_len + 1, .big);
    try std.testing.expectError(error.ValueTooLarge, Message.readValue(std.testing.allocator, input.reader()));
}

test "rpc: readValue grows across chunks and cleans up truncated payloads" {
    const allocator = std.testing.allocator;
    var input = TestBuffer{ .allocator = allocator };
    defer input.list.deinit(allocator);
    const data = try allocator.alloc(u8, read_chunk_len + 7);
    defer allocator.free(data);
    @memset(data, 42);
    try input.writer().writeInt(u32, @intCast(data.len), .big);
    try input.writer().writeAll(data);
    const value = try Message.readValue(allocator, input.reader());
    defer allocator.free(value);
    try std.testing.expectEqualSlices(u8, data, value);
    input.pos = 0;
    input.list.items.len -= 1;
    try std.testing.expectError(error.EndOfStream, Message.readValue(allocator, input.reader()));
}

test "rpc: unknown find-value response tags and invalid nicknames are rejected" {
    const allocator = std.testing.allocator;
    const sender = id.NodeID{ .bytes = [_]u8{3} ** 32 };
    var input = TestBuffer{ .allocator = allocator };
    defer input.list.deinit(allocator);
    const msg = Message{ .sender_id = sender, .payload = .{ .FIND_VALUE_RESPONSE = .{ .closer_peers = &.{} } } };
    try msg.serialize(input.writer());
    input.list.items[33] = 2;
    try std.testing.expectError(error.InvalidMessage, Message.deserialize(allocator, input.reader()));
    input.list.clearRetainingCapacity();
    input.pos = 0;
    try (Message{ .sender_id = sender, .payload = .{ .SHARES = .{ .nickname = "ok", .listing = "" } } }).serialize(input.writer());
    input.list.items[34] = 0x1b;
    try std.testing.expectError(error.InvalidNickname, Message.deserialize(allocator, input.reader()));
    input.pos = 0;
    input.list.items[33] = Message.max_nickname_len + 1;
    try std.testing.expectError(error.InvalidNickname, Message.deserialize(allocator, input.reader()));
    try std.testing.expectError(error.ValueTooLarge, valueLen(Message.max_value_len + 1));
}

test "rpc peer lists and announcements skip invalid addresses without changing framing" {
    const allocator = std.testing.allocator;
    var peer = kbucket.PeerInfo{ .id = .{ .bytes = [_]u8{3} ** 32 }, .last_seen = 1 };
    const addresses = [_]Address{
        Address.initIp4(.{ 0, 0, 0, 0 }, 0),
        Address.initIp4(.{ 224, 0, 0, 1 }, 1),
        Address.initIp4(.{ 10, 0, 0, 1 }, 0),
        Address.initIp4(.{ 192, 0, 2, 7 }, 14700),
    };
    for (addresses) |a| _ = peer.addAddress(a);
    var buf = TestBuffer{ .allocator = allocator };
    defer buf.list.deinit(allocator);
    try Message.writePeers(&.{peer}, buf.writer());
    const peers = try Message.readPeers(allocator, buf.reader());
    defer allocator.free(peers);
    try std.testing.expectEqual(@as(u8, 1), peers[0].addrs_count);
    try std.testing.expect(peers[0].addresses[0].eql(addresses[3]));
    try std.testing.expectEqual(kbucket.AddrSource.hearsay, peers[0].sources[0]);
    buf.pos = 0;
    buf.list.clearRetainingCapacity();
    var announced_addrs: Announced = .{};
    @memcpy(announced_addrs.addrs[0..addresses.len], &addresses);
    announced_addrs.count = addresses.len;
    try writeAnnounced(announced_addrs, buf.writer());
    const parsed = try readAnnounced(buf.reader());
    try std.testing.expectEqual(@as(u8, 1), parsed.count);
    try std.testing.expectEqual(buf.list.items.len, buf.pos);
}

test "rpc bounded random inputs do not panic" {
    var bytes: [128]u8 = undefined;
    var seed: u64 = 12345;
    const allocator = std.testing.allocator;
    for (0..256) |iteration| {
        for (&bytes) |*byte| {
            seed = seed *% 6364136223846793005 +% 1;
            byte.* = @truncate(seed >> 32);
        }
        var buf = TestBuffer{ .allocator = allocator };
        defer buf.list.deinit(allocator);
        try buf.list.appendSlice(allocator, bytes[0 .. iteration % bytes.len]);
        const msg = Message.deserialize(allocator, buf.reader()) catch continue;
        msg.deinit(allocator);
    }
}

test "rpc: ADMIT round trip keeps every field" {
    const allocator = std.testing.allocator;
    var buf = TestBuffer{ .allocator = allocator };
    defer buf.list.deinit(allocator);
    var admit: Admit = .{ .public_key = [_]u8{1} ** 32, .transport_key = [_]u8{2} ** 32, .at = 77, .signer_key = [_]u8{3} ** 32, .signature = [_]u8{4} ** 64 };
    @memcpy(admit.label[0..5], "Phone");
    admit.label_len = 5;
    const msg = Message{ .sender_id = id.NodeID{ .bytes = [_]u8{5} ** 32 }, .payload = .{ .ADMIT = admit } };
    try msg.serialize(buf.writer());
    const got = try Message.deserialize(allocator, buf.reader());
    defer got.deinit(allocator);
    try std.testing.expectEqualStrings("Phone", got.payload.ADMIT.labelSlice());
    try std.testing.expectEqual(@as(u64, 77), got.payload.ADMIT.at);
    try std.testing.expectEqual(admit.transport_key, got.payload.ADMIT.transport_key);
    try std.testing.expectEqual(admit.signature, got.payload.ADMIT.signature);
}
