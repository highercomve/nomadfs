//! One-time invites: how a new device joins the swarm without anyone
//! copying the swarm key around.
//!
//! The inviting device opens a short-lived listener and shows a code:
//!
//!   nomadfs://invite?addr=192.168.1.20:14701&token=<32 hex>
//!
//! The token is 128 random bits, valid once and for a few minutes. Both
//! sides derive a pre-shared key from it and run the transport's usual
//! Noise_XXpsk3 handshake with throwaway static keys, so only a holder of
//! the token can complete it, and a code read off the screen afterwards is
//! useless. A short PIN would need a PAKE to resist offline guessing; a
//! 128-bit token does not.
//!
//! Inside the encrypted channel the devices swap signed pairing tickets
//! (identity, transport key, addresses) and the inviter sends the swarm key
//! and its node port:
//!
//!   joiner -> inviter: [u16 len][ticket uri]
//!   inviter -> joiner: [32 swarm key][u16 node port][u16 len][ticket uri]

const std = @import("std");
const sync = @import("../sync.zig");
const pairing = @import("pairing.zig");
const Identity = @import("identity.zig").Identity;
const net = @import("../net/mod.zig");
const ConnectionManager = net.transport.manager.ConnectionManager;
const KeyPair = net.transport.noise.KeyPair;

pub const token_len = 16;
pub const default_lifetime_s = 10 * 60;
/// Bound on a ticket URI on the wire (pairing.max_uri_len is smaller).
const max_ticket_len = 2048;
const io_timeout_ms = 15_000;
const scheme = "nomadfs://invite?";

pub const Error = error{TicketNotOwned};

/// The transport PSK both sides derive from the invite token.
pub fn derivePsk(token: [token_len]u8) [32]u8 {
    var out: [32]u8 = undefined;
    var h = std.crypto.hash.sha2.Sha256.init(.{});
    h.update("nomadfs-invite-v1:");
    h.update(&token);
    h.final(&out);
    return out;
}

pub const Code = struct {
    /// "ip:port" of the invite listener.
    addr: []const u8,
    token: [token_len]u8,

    /// Parses an invite code; `addr` points into `text`.
    pub fn parse(text: []const u8) !Code {
        const trimmed = std.mem.trim(u8, text, " \t\r\n");
        // Schemes are case-insensitive, and phone keyboards capitalize the
        // first letter of a typed code.
        if (!std.ascii.startsWithIgnoreCase(trimmed, scheme)) return error.InvalidInvite;
        var addr: ?[]const u8 = null;
        var token: ?[token_len]u8 = null;
        var params = std.mem.splitScalar(u8, trimmed[scheme.len..], '&');
        while (params.next()) |param| {
            if (std.mem.startsWith(u8, param, "addr=")) addr = param[5..];
            if (std.mem.startsWith(u8, param, "token=")) {
                const hex = param[6..];
                if (hex.len != token_len * 2) return error.InvalidInvite;
                var t: [token_len]u8 = undefined;
                _ = std.fmt.hexToBytes(&t, hex) catch return error.InvalidInvite;
                token = t;
            }
        }
        return .{ .addr = addr orelse return error.InvalidInvite, .token = token orelse return error.InvalidInvite };
    }

    pub fn format(self: Code, buf: []u8) ![]const u8 {
        const hex = std.fmt.bytesToHex(self.token, .lower);
        return std.fmt.bufPrint(buf, scheme ++ "addr={s}&token={s}", .{ self.addr, &hex });
    }

    fn address(self: Code) !net.compat.Address {
        const colon = std.mem.lastIndexOfScalar(u8, self.addr, ':') orelse return error.InvalidInvite;
        const port = std.fmt.parseInt(u16, self.addr[colon + 1 ..], 10) catch return error.InvalidInvite;
        return net.compat.Address.parseIp(self.addr[0..colon], port) catch error.InvalidInvite;
    }
};

/// What the inviter hands to whoever presents the token.
pub const Offer = struct {
    identity: Identity,
    swarm_key: [32]u8,
    node_port: u16,
    /// The inviter's own pairing ticket (nomadfs://pair?...).
    ticket_uri: []const u8,
};

/// The inviting side: a listener that answers one join, then stops.
pub const Host = struct {
    allocator: std.mem.Allocator,
    manager: *ConnectionManager,
    running: std.atomic.Value(bool) = .init(true),
    port: u16,
    token: [token_len]u8,
    /// Transport PSK derived from the token. The listener reads it for
    /// every handshake, so it lives as long as the Host.
    psk: [32]u8,
    swarm_key: [32]u8,
    node_port: u16,
    ticket_uri: []u8,
    expires_at: u64,
    mutex: sync.Mutex = .{},
    state: State = .waiting,
    /// The joiner's pairing ticket once it joined. Guarded by `mutex`.
    joined_ticket: ?[]u8 = null,
    stopped: bool = false,

    pub const State = enum { waiting, joined, expired };

    /// Starts listening on `port` for one join within `lifetime_s` seconds.
    pub fn start(allocator: std.mem.Allocator, offer: Offer, port: u16, lifetime_s: u64, now: u64) !*Host {
        const io = std.Io.Threaded.global_single_threaded.io();
        var token: [token_len]u8 = undefined;
        try io.randomSecure(&token);

        const manager = try ConnectionManager.createExplicit(allocator, .tcp, KeyPair.generate());
        errdefer manager.deinit();
        manager.setDeviceAuthenticator(.{ .identity = offer.identity });
        try manager.start();

        const self = try allocator.create(Host);
        errdefer allocator.destroy(self);
        self.* = .{
            .allocator = allocator,
            .manager = manager,
            .port = port,
            .token = token,
            .psk = derivePsk(token),
            .swarm_key = offer.swarm_key,
            .node_port = offer.node_port,
            .ticket_uri = try allocator.dupe(u8, offer.ticket_uri),
            .expires_at = now + lifetime_s,
        };
        errdefer allocator.free(self.ticket_uri);

        manager.setConnectionHandler(self, onConnection);
        try manager.listen(.{
            .node = .{ .nickname = "invite", .swarm_key = &self.psk },
            .storage = .{ .enabled = false, .storage_path = "" },
            .network = .{
                .port = port,
                .bootstrap_peers = &.{},
                .transport = .tcp,
                .upnp_enabled = false,
                .enable_mdns = false,
            },
        }, &self.running);
        return self;
    }

    /// The code to show, for the listener reachable at `ip`.
    pub fn code(self: *Host, ip: []const u8, buf: []u8) ![]const u8 {
        var addr_buf: [64]u8 = undefined;
        const addr = try std.fmt.bufPrint(&addr_buf, "{s}:{d}", .{ ip, self.port });
        return (Code{ .addr = addr, .token = self.token }).format(buf);
    }

    /// Current state; an invite past its lifetime stops listening.
    pub fn status(self: *Host, now: u64) State {
        self.mutex.lock();
        const expired = self.state == .waiting and now >= self.expires_at;
        if (expired) self.state = .expired;
        const state = self.state;
        self.mutex.unlock();
        if (state != .waiting) self.stopListening();
        return state;
    }

    /// The joiner's ticket (caller-owned copy), once joined.
    pub fn joinedTicket(self: *Host, allocator: std.mem.Allocator) !?[]u8 {
        self.mutex.lock();
        defer self.mutex.unlock();
        const t = self.joined_ticket orelse return null;
        return try allocator.dupe(u8, t);
    }

    fn stopListening(self: *Host) void {
        self.mutex.lock();
        if (self.stopped) {
            self.mutex.unlock();
            return;
        }
        self.stopped = true;
        self.mutex.unlock();
        self.running.store(false, .release);
        // Wake the accept loop so it sees the flag.
        if (net.compat.Address.parseIp("127.0.0.1", self.port)) |addr| {
            if (net.compat.tcpConnectToAddress(addr)) |s| s.close() else |_| {}
        } else |_| {}
        self.manager.stop();
    }

    pub fn destroy(self: *Host) void {
        self.stopListening();
        self.manager.deinit();
        std.crypto.secureZero(u8, &self.token);
        std.crypto.secureZero(u8, &self.psk);
        std.crypto.secureZero(u8, &self.swarm_key);
        self.allocator.free(self.ticket_uri);
        if (self.joined_ticket) |t| self.allocator.free(t);
        self.allocator.destroy(self);
    }

    fn onConnection(self: *Host, conn: net.transport.Connection) anyerror!void {
        // The Noise handshake already proved the peer holds the token.
        const stream = try conn.acceptStream();
        defer stream.close();
        stream.setTimeout(io_timeout_ms);

        const peer_ticket = try readBlob(self.allocator, stream.reader());
        var stored = false;
        errdefer if (!stored) self.allocator.free(peer_ticket);
        const now = nowSeconds();
        const ticket = try pairing.Ticket.parseAt(peer_ticket, now);
        const remote = conn.getRemoteDeviceID() orelse return Error.TicketNotOwned;
        if (!ticket.deviceId().eql(remote)) return Error.TicketNotOwned;

        self.mutex.lock();
        if (self.state == .waiting and now >= self.expires_at) self.state = .expired;
        const usable = self.state == .waiting and !self.stopped;
        if (usable) {
            self.state = .joined; // one join per invite
            self.joined_ticket = peer_ticket;
            stored = true;
        }
        self.mutex.unlock();
        if (!usable) {
            return error.InviteUsed;
        }

        const w = stream.writer();
        try w.writeAll(&self.swarm_key);
        try w.writeInt(u16, self.node_port, .big);
        try writeBlob(w, self.ticket_uri);
    }
};

pub const Joined = struct {
    swarm_key: [32]u8,
    node_port: u16,
    /// The inviter's pairing ticket (owned).
    ticket_uri: []u8,
    /// The inviter's IP as reached through the code (owned).
    host_ip: []u8,

    pub fn deinit(self: *Joined, allocator: std.mem.Allocator) void {
        std.crypto.secureZero(u8, &self.swarm_key);
        allocator.free(self.ticket_uri);
        allocator.free(self.host_ip);
    }
};

/// The joining side: presents `my_ticket_uri` to the inviter named by
/// `code_text` and receives the swarm key, its node port and its ticket.
pub fn join(allocator: std.mem.Allocator, code_text: []const u8, my_ticket_uri: []const u8, identity: Identity) !Joined {
    const ticket = pairing.Ticket.parseAt(my_ticket_uri, nowSeconds()) catch return error.InviteRejected;
    if (!ticket.deviceId().eql(identity.deviceId())) return error.InviteRejected;
    return joinExchange(allocator, code_text, my_ticket_uri, identity);
}

// Kept separate so tests can exercise a hostile peer presenting another device's ticket.
fn joinExchange(allocator: std.mem.Allocator, code_text: []const u8, my_ticket_uri: []const u8, identity: Identity) !Joined {
    const code = try Code.parse(code_text);
    const address = try code.address();
    var psk = derivePsk(code.token);
    defer std.crypto.secureZero(u8, &psk);

    const manager = try ConnectionManager.createExplicit(allocator, .tcp, KeyPair.generate());
    defer manager.deinit();
    manager.setDeviceAuthenticator(.{ .identity = identity });
    try manager.start();
    defer manager.stop();

    const conn = manager.connectToPeer(address, &psk, null) catch |err| {
        std.debug.print("invite: handshake with {s} failed: {any}\n", .{ code.addr, err });
        return error.InviteRejected; // wrong or used token, or unreachable
    };
    defer conn.deinit();
    const stream = conn.openStream() catch return error.InviteRejected;
    defer stream.close();
    stream.setTimeout(io_timeout_ms);

    try writeBlob(stream.writer(), my_ticket_uri);
    const r = stream.reader();
    var out: Joined = undefined;
    errdefer std.crypto.secureZero(u8, &out.swarm_key);
    r.readNoEof(&out.swarm_key) catch return error.InviteRejected;
    out.node_port = try r.readInt(u16, .big);
    out.ticket_uri = try readBlob(allocator, r);
    errdefer allocator.free(out.ticket_uri);
    const ticket = pairing.Ticket.parseAt(out.ticket_uri, nowSeconds()) catch return error.InviteRejected;
    const remote = conn.getRemoteDeviceID() orelse return error.InviteRejected;
    if (!ticket.deviceId().eql(remote)) return error.InviteRejected;
    const colon = std.mem.lastIndexOfScalar(u8, code.addr, ':').?;
    out.host_ip = try allocator.dupe(u8, code.addr[0..colon]);
    return out;
}

/// The address this device uses on the LAN: the source address the kernel
/// picks for an outbound UDP "connection" (nothing is sent). Null where
/// that can't be determined.
pub fn lanAddress(buf: *[16]u8) ?[]const u8 {
    if (@import("builtin").os.tag != .linux) return null;
    const linux = std.os.linux;
    const rc = linux.socket(linux.AF.INET, linux.SOCK.DGRAM | linux.SOCK.CLOEXEC, 0);
    if (linux.errno(rc) != .SUCCESS) return null;
    const fd: i32 = @intCast(rc);
    defer _ = linux.close(fd);
    var target = linux.sockaddr.in{ .port = std.mem.nativeToBig(u16, 9), .addr = std.mem.nativeToBig(u32, 0xC0000201) }; // 192.0.2.1 (TEST-NET-1)
    if (linux.errno(linux.connect(fd, @ptrCast(&target), @sizeOf(linux.sockaddr.in))) != .SUCCESS) return null;
    var local: linux.sockaddr.in = undefined;
    var len: linux.socklen_t = @sizeOf(linux.sockaddr.in);
    if (linux.errno(linux.getsockname(fd, @ptrCast(&local), &len)) != .SUCCESS) return null;
    const a: [4]u8 = @bitCast(local.addr);
    return std.fmt.bufPrint(buf, "{d}.{d}.{d}.{d}", .{ a[0], a[1], a[2], a[3] }) catch null;
}

const nowSeconds = @import("../sync.zig").nowSeconds;

fn writeBlob(w: anytype, bytes: []const u8) !void {
    if (bytes.len > max_ticket_len) return error.TicketTooLong;
    try w.writeInt(u16, @intCast(bytes.len), .big);
    try w.writeAll(bytes);
}

fn readBlob(allocator: std.mem.Allocator, r: anytype) ![]u8 {
    const len = try r.readInt(u16, .big);
    if (len == 0 or len > max_ticket_len) return error.InvalidInvite;
    const buf = try allocator.alloc(u8, len);
    errdefer allocator.free(buf);
    try r.readNoEof(buf);
    return buf;
}

test "invite: code round trip and rejection" {
    var buf: [128]u8 = undefined;
    const token = [_]u8{0xAB} ** token_len;
    const text = try (Code{ .addr = "192.168.1.20:14701", .token = token }).format(&buf);
    const parsed = try Code.parse(text);
    try std.testing.expectEqualStrings("192.168.1.20:14701", parsed.addr);
    try std.testing.expectEqualSlices(u8, &token, &parsed.token);
    // As a phone keyboard types it: first letter capitalized.
    var typed_buf: [128]u8 = undefined;
    const typed = try std.fmt.bufPrint(&typed_buf, "N{s}", .{text[1..]});
    try std.testing.expectEqualStrings("192.168.1.20:14701", (try Code.parse(typed)).addr);
    try std.testing.expectError(error.InvalidInvite, Code.parse("nomadfs://join?key=00"));
    try std.testing.expectError(error.InvalidInvite, Code.parse("nomadfs://invite?addr=1.2.3.4:5&token=abcd"));
    // Different tokens never share a PSK.
    try std.testing.expect(!std.mem.eql(u8, &derivePsk(token), &derivePsk([_]u8{0xAC} ** token_len)));
}

fn testTicket(identity: Identity, buf: []u8) ![]const u8 {
    const ticket = try pairing.Ticket.init(identity, [_]u8{2} ** 32, "device", "127.0.0.1:14700", nowSeconds() + 60);
    return ticket.toUri(buf);
}

test "invite: possession enforced before consuming token, then matching identities succeed" {
    const allocator = std.testing.allocator;
    const host_identity = Identity.generate();
    const joiner = Identity.generate();
    const stranger = Identity.generate();
    var host_buf: [pairing.max_uri_len]u8 = undefined;
    var joiner_buf: [pairing.max_uri_len]u8 = undefined;
    var stranger_buf: [pairing.max_uri_len]u8 = undefined;
    const host_uri = try testTicket(host_identity, &host_buf);
    const joiner_uri = try testTicket(joiner, &joiner_buf);
    const stranger_uri = try testTicket(stranger, &stranger_buf);
    const key = [_]u8{0x5A} ** 32;
    const host = try Host.start(allocator, .{ .identity = host_identity, .swarm_key = key, .node_port = 14700, .ticket_uri = host_uri }, 13141, 60, nowSeconds());
    defer host.destroy();
    var buf: [128]u8 = undefined;
    const code = try host.code("127.0.0.1", &buf);

    // A revoked third device's copied ticket cannot clear its tombstone.
    const trust = @import("trust.zig");
    const path = "test_invite_tombstone.store";
    const io = std.Io.Threaded.global_single_threaded.io();
    std.Io.Dir.cwd().deleteFile(io, path) catch {};
    defer std.Io.Dir.cwd().deleteFile(io, path) catch {};
    var store = try trust.Store.load(allocator, path, null);
    defer store.deinit();
    _ = try store.revokeDevice(stranger.deviceId(), host_identity.deviceId(), nowSeconds());
    try std.testing.expectError(error.InviteRejected, joinExchange(allocator, code, stranger_uri, joiner));
    try std.testing.expectEqual(Host.State.waiting, host.status(nowSeconds()));
    try std.testing.expect((try host.joinedTicket(allocator)) == null);
    try std.testing.expect(store.isRevoked(stranger.deviceId()));

    var wrong = try Code.parse(code);
    wrong.token[0] ^= 1;
    var wrong_buf: [128]u8 = undefined;
    try std.testing.expectError(error.InviteRejected, join(allocator, try wrong.format(&wrong_buf), joiner_uri, joiner));
    try std.testing.expectError(error.InviteRejected, joinExchange(allocator, code, "invalid", joiner));
    var joined = try join(allocator, code, joiner_uri, joiner);
    defer joined.deinit(allocator);
    try std.testing.expectEqualSlices(u8, &key, &joined.swarm_key);
    try std.testing.expectEqual(@as(u16, 14700), joined.node_port);
    try std.testing.expectEqualStrings(host_uri, joined.ticket_uri);
    try std.testing.expectEqualStrings("127.0.0.1", joined.host_ip);
    const seen = (try host.joinedTicket(allocator)).?;
    defer allocator.free(seen);
    try std.testing.expect((try pairing.Ticket.parse(seen)).deviceId().eql(joiner.deviceId()));
    try std.testing.expectError(error.InviteRejected, join(allocator, code, joiner_uri, joiner));
    try std.testing.expectEqual(Host.State.joined, host.status(nowSeconds()));
}

test "invite: inviter must own its ticket" {
    const identity = Identity.generate();
    const other = Identity.generate();
    var host_buf: [pairing.max_uri_len]u8 = undefined;
    var joiner_buf: [pairing.max_uri_len]u8 = undefined;
    const host = try Host.start(std.testing.allocator, .{ .identity = identity, .swarm_key = [_]u8{1} ** 32, .node_port = 1, .ticket_uri = try testTicket(other, &host_buf) }, 13142, 60, nowSeconds());
    defer host.destroy();
    var buf: [128]u8 = undefined;
    try std.testing.expectError(error.InviteRejected, join(std.testing.allocator, try host.code("127.0.0.1", &buf), try testTicket(other, &joiner_buf), other));
}

test "invite: connection rejects expiry without status polling" {
    const identity = Identity.generate();
    var ticket_buf: [pairing.max_uri_len]u8 = undefined;
    const uri = try testTicket(identity, &ticket_buf);
    const host = try Host.start(std.testing.allocator, .{ .identity = identity, .swarm_key = [_]u8{1} ** 32, .node_port = 1, .ticket_uri = uri }, 13143, 0, nowSeconds());
    defer host.destroy();
    var buf: [128]u8 = undefined;
    try std.testing.expectError(error.InviteRejected, join(std.testing.allocator, try host.code("127.0.0.1", &buf), uri, identity));
    try std.testing.expectEqual(Host.State.expired, host.status(nowSeconds()));
    try std.testing.expect((try host.joinedTicket(std.testing.allocator)) == null);
}

test "invite: a peer without the real device authenticator cannot consume an invite" {
    const allocator = std.testing.allocator;
    const identity = Identity.generate();
    var ticket_buf: [pairing.max_uri_len]u8 = undefined;
    const uri = try testTicket(identity, &ticket_buf);
    const host = try Host.start(allocator, .{ .identity = identity, .swarm_key = [_]u8{1} ** 32, .node_port = 1, .ticket_uri = uri }, 13243, 60, nowSeconds());
    defer host.destroy();
    const manager = try ConnectionManager.createExplicit(allocator, .tcp, KeyPair.generate());
    defer manager.deinit();
    try manager.start();
    defer manager.stop();
    const conn = try manager.connectToPeer(try net.compat.Address.parseIp("127.0.0.1", 13243), &host.psk, null);
    defer conn.deinit();
    const stream = try conn.openStream();
    defer stream.close();
    stream.setTimeout(io_timeout_ms);
    try writeBlob(stream.writer(), uri);
    var key: [32]u8 = undefined;
    if (stream.reader().readNoEof(&key)) |_| {
        return error.TestUnexpectedResult;
    } else |_| {}
    try std.testing.expectEqual(Host.State.waiting, host.status(nowSeconds()));
    try std.testing.expect((try host.joinedTicket(allocator)) == null);
}

test "invite: expires unused" {
    const identity = Identity.generate();
    var buf: [pairing.max_uri_len]u8 = undefined;
    const host = try Host.start(std.testing.allocator, .{ .identity = identity, .swarm_key = [_]u8{1} ** 32, .node_port = 1, .ticket_uri = try testTicket(identity, &buf) }, 13244, 60, 1000);
    defer host.destroy();
    try std.testing.expectEqual(Host.State.waiting, host.status(1059));
    try std.testing.expectEqual(Host.State.expired, host.status(1060));
}
