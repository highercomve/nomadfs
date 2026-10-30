//! This device's membership in its swarm, as one service: the pairing
//! ticket it shows, the invites it hosts, the devices it trusts and the
//! ones it revokes. The command line, the app and the mobile API all call
//! this; they only read input and show results.
//!
//! A running node owns one (`Node.membership`) over its live trust store, so
//! what any front end does takes effect in the node at once, and the node's
//! membership push tells the swarm. A front end without a running node opens
//! one from the configuration (`open`); a node running elsewhere merges
//! what it wrote (trust.Store.syncFromDisk).

const std = @import("std");
const sync = @import("../sync.zig");
const NodeID = @import("../net/id.zig").NodeID;
const identity_mod = @import("identity.zig");
const pairing = @import("pairing.zig");
const trust_mod = @import("trust.zig");
const invite = @import("invite.zig");
const local_addrs = @import("../net/local_addrs.zig");
const paths_mod = @import("paths.zig");
const config_mod = @import("../config.zig");
const ConnectionManager = @import("../net/transport/manager.zig").ConnectionManager;

const Identity = identity_mod.Identity;
const Ticket = pairing.Ticket;

/// How long a pairing ticket is valid.
pub const ticket_lifetime_s: u64 = 24 * 60 * 60;

pub const Membership = struct {
    allocator: std.mem.Allocator,
    identity: Identity,
    /// The X25519 transport public key tickets pin.
    transport_key: [32]u8,
    /// Borrowed; the caller keeps it alive.
    nickname: []const u8,
    node_port: u16,
    swarm_key: [32]u8,
    /// The trust store changes go to: the running node's, or one `open`ed.
    trust: *trust_mod.Store,
    /// Told after a device was trusted or revoked (the node closes a revoked
    /// device's connections and forgets it as a holder).
    hooks: ?Hooks = null,

    /// Guards the invite.
    mutex: sync.Mutex = .{},
    host: ?*invite.Host = null,
    code_buf: [160]u8 = undefined,
    code_len: usize = 0,
    /// The joiner was trusted already (status is polled).
    joined_handled: bool = false,

    /// What `open` allocated (null when the store belongs to a node).
    owned: ?*Owned = null,

    const Owned = struct { store: trust_mod.Store, nickname: []u8 };

    pub const Hooks = struct {
        ctx: *anyopaque,
        trustedFn: *const fn (ctx: *anyopaque, ticket: *const Ticket) void,
        revokedFn: *const fn (ctx: *anyopaque, device: NodeID, transport_key: ?[32]u8) void,
    };

    /// The service for a front end that runs no node: identity, transport
    /// key and trust store loaded from the configuration's paths. `close`
    /// frees them.
    pub fn open(allocator: std.mem.Allocator, config: config_mod.Config) !Membership {
        var paths = try paths_mod.Paths.resolve(allocator, config.node.key_path);
        defer paths.deinit(allocator);
        const identity = try Identity.loadOrCreate(paths.identity);
        const transport = try ConnectionManager.loadOrCreateKey(allocator, config.node.key_path);
        const owned = try allocator.create(Owned);
        errdefer allocator.destroy(owned);
        owned.store = try trust_mod.Store.load(allocator, paths.trust, identity.seed());
        errdefer owned.store.deinit();
        owned.nickname = try allocator.dupe(u8, config.node.nickname);
        return .{
            .allocator = allocator,
            .identity = identity,
            .transport_key = transport.public_key,
            .nickname = owned.nickname,
            .node_port = config.network.port,
            .swarm_key = swarmKey(config.node.swarm_key),
            .trust = &owned.store,
            .owned = owned,
        };
    }

    pub fn swarmKey(text: []const u8) [32]u8 {
        var key = [_]u8{0} ** 32;
        @memcpy(key[0..@min(32, text.len)], text[0..@min(32, text.len)]);
        return key;
    }

    pub fn close(self: *Membership) void {
        self.cancelInvite();
        if (self.owned) |o| {
            o.store.deinit();
            self.allocator.free(o.nickname);
            self.allocator.destroy(o);
            self.owned = null;
        }
    }

    // ---- Tickets ----

    /// Every address this device is reachable at on `port`, comma separated:
    /// the LAN one first, then the others (Tailscale and other VPNs), so a
    /// device that pairs or joins can reach this one away from home too.
    /// Localhost when there is none. Addresses that don't fit are left out.
    pub fn advertised(buf: []u8, port: u16) []const u8 {
        var len: usize = 0;
        var ip_buf: [16]u8 = undefined;
        if (invite.lanAddress(&ip_buf)) |ip| len = appendAddr(buf, len, ip, port);
        var addrs: [8]@import("../net/compat.zig").Address = undefined;
        const n = local_addrs.list(&addrs, port);
        for (addrs[0..n]) |a| {
            var text_buf: [64]u8 = undefined;
            const text = std.fmt.bufPrint(&text_buf, "{f}", .{a}) catch continue;
            if (std.mem.indexOf(u8, buf[0..len], text) != null) continue;
            const sep: usize = if (len > 0) 1 else 0;
            if (len + sep + text.len > buf.len) break;
            if (sep == 1) buf[len] = ',';
            @memcpy(buf[len + sep ..][0..text.len], text);
            len += sep + text.len;
        }
        if (len == 0) len = appendAddr(buf, 0, "127.0.0.1", port);
        return buf[0..len];
    }

    fn appendAddr(buf: []u8, len: usize, ip: []const u8, port: u16) usize {
        const text = std.fmt.bufPrint(buf[len..], "{s}:{d}", .{ ip, port }) catch return len;
        return len + text.len;
    }

    /// This device's pairing ticket, valid for a day, listing `addresses`
    /// ("ip:port,ip:port"; empty: every address it has, see advertised).
    pub fn ticket(self: *Membership, addresses: []const u8, now: u64) !Ticket {
        var buf: [pairing.max_addresses_len]u8 = undefined;
        const addrs = if (addresses.len > 0) addresses else advertised(&buf, self.node_port);
        return Ticket.init(self.identity, self.transport_key, self.nickname, addrs, now + ticket_lifetime_s);
    }

    // ---- Trusting and revoking ----

    /// The devices trusted here, a copy (the store changes under
    /// revocations from peers). Caller frees.
    pub fn devices(self: *Membership, allocator: std.mem.Allocator) ![]trust_mod.Entry {
        return self.trust.copyEntries(allocator);
    }

    pub const Trusted = struct { ticket: Ticket, added: bool };

    /// Trusts the device a ticket URI names (it signed the ticket). Fails
    /// with error.StaleTicket when a newer ticket of it is already trusted.
    pub fn trustUri(self: *Membership, uri: []const u8, now: u64) !Trusted {
        const t = try Ticket.parseAt(uri, now);
        return .{ .ticket = t, .added = try self.trustTicket(&t, now) };
    }

    fn trustTicket(self: *Membership, t: *const Ticket, now: u64) !bool {
        const added = try self.trust.trustTicket(t.*, now);
        try self.trust.save();
        if (self.hooks) |h| h.trustedFn(h.ctx, t);
        return added;
    }

    pub const Joined = struct {
        /// The inviting device, now trusted here.
        inviter: Ticket,
        swarm_key: [32]u8,
        /// Where the inviter's node listens: `tcp://ip:port`.
        peer_buf: [64]u8 = undefined,
        peer_len: u8 = 0,

        pub fn peer(self: *const Joined) []const u8 {
            return self.peer_buf[0..self.peer_len];
        }
    };

    /// Joins the swarm of the device that showed invite `code`: presents this
    /// device's ticket (listing `addresses`), receives the swarm key over the
    /// one-time exchange, and trusts the inviter. The caller saves the key
    /// and the peer (settings.joinSwarm) and restarts the node on them.
    pub fn join(self: *Membership, code: []const u8, addresses: []const u8, now: u64) !Joined {
        const mine = try self.ticket(addresses, now);
        var uri_buf: [pairing.max_uri_len]u8 = undefined;
        var joined = try invite.join(self.allocator, code, try mine.toUri(&uri_buf), self.identity);
        defer joined.deinit(self.allocator);

        var out: Joined = .{ .inviter = undefined, .swarm_key = joined.swarm_key };
        errdefer std.crypto.secureZero(u8, &out.swarm_key);
        const peer = try std.fmt.bufPrint(&out.peer_buf, "tcp://{s}:{d}", .{ joined.host_ip, joined.node_port });
        out.peer_len = @intCast(peer.len);
        out.inviter = (self.trustUri(joined.ticket_uri, now) catch |err| switch (err) {
            // Trusted already, with a newer ticket: nothing to add.
            error.StaleTicket => Trusted{ .ticket = try Ticket.parseAt(joined.ticket_uri, now), .added = false },
            else => return err,
        }).ticket;
        return out;
    }

    pub const Revoked = struct { device: NodeID, removed: bool };

    /// Revokes the device `query` names (a device ID or fingerprint, as the
    /// device list shows it), signed by this device, so it spreads.
    pub fn revoke(self: *Membership, query: []const u8, now: u64) !Revoked {
        const device = try self.trust.resolve(query) orelse return error.DeviceNotFound;
        const transport_key: ?[32]u8 = if (self.trust.lookup(device)) |e| e.transport_key else null;
        const removed = try self.trust.revokeDevice(device, self.identity.deviceId(), now);
        try self.trust.save();
        if (self.hooks) |h| h.revokedFn(h.ctx, device, transport_key);
        return .{ .device = device, .removed = removed };
    }

    // ---- Invites ----

    pub const InviteState = struct {
        /// `none`: no invite was opened (or it was cancelled).
        state: enum { none, waiting, joined, expired },
        /// While waiting; points into the service (valid until the next call).
        code: []const u8 = "",
        expires_in: u64 = 0,
        /// Once joined: the device that joined, now trusted.
        joined: ?Ticket = null,
    };

    /// Opens a one-time invite on the node port + 1 for one join within
    /// ten minutes, replacing any open one. `ip` is the address the code
    /// names; `addresses` go in this device's ticket the joiner receives.
    pub fn startInvite(self: *Membership, ip: []const u8, addresses: []const u8, now: u64) !InviteState {
        const t = try self.ticket(addresses, now);
        var uri_buf: [pairing.max_uri_len]u8 = undefined;
        const uri = try t.toUri(&uri_buf);
        self.mutex.lock();
        defer self.mutex.unlock();
        self.cancelLocked();
        const host = try invite.Host.start(std.heap.page_allocator, .{
            .identity = self.identity,
            .swarm_key = self.swarm_key,
            .node_port = self.node_port,
            .ticket_uri = uri,
        }, try std.math.add(u16, self.node_port, 1), invite.default_lifetime_s, now);
        errdefer host.destroy();
        const code = try host.code(ip, &self.code_buf);
        self.code_len = code.len;
        self.host = host;
        self.joined_handled = false;
        return self.statusLocked(now);
    }

    /// Where the invite is. The first time it reports a join, the joiner is
    /// trusted here (it proved it holds its ticket's identity), whoever
    /// asks: the app polling, the command line waiting.
    pub fn inviteStatus(self: *Membership, now: u64) InviteState {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.statusLocked(now);
    }

    fn statusLocked(self: *Membership, now: u64) InviteState {
        const host = self.host orelse return .{ .state = .none };
        const state = host.status(now);
        var out: InviteState = .{ .state = switch (state) {
            .waiting => .waiting,
            .joined => .joined,
            .expired => .expired,
        }, .expires_in = if (host.expires_at > now) host.expires_at - now else 0 };
        switch (state) {
            .waiting => out.code = self.code_buf[0..self.code_len],
            .expired => {},
            .joined => {
                const uri = (host.joinedTicket(self.allocator) catch null) orelse return out;
                defer self.allocator.free(uri);
                const t = Ticket.parseAt(uri, now) catch return out;
                out.joined = t;
                if (!self.joined_handled) {
                    self.joined_handled = true;
                    // A newer ticket of it already trusted wins; still joined.
                    _ = self.trustTicket(&t, now) catch |err| if (err != error.StaleTicket)
                        std.debug.print("membership: trusting {s} failed: {any}\n", .{ t.nicknameSlice(), err });
                }
            },
        }
        return out;
    }

    pub fn cancelInvite(self: *Membership) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.cancelLocked();
    }

    fn cancelLocked(self: *Membership) void {
        if (self.host) |h| h.destroy();
        self.host = null;
        self.code_len = 0;
    }
};

// ---- Tests ----

const testing = std.testing;

test "membership: trust a ticket, refuse an older one, revoke by fingerprint" {
    const io = std.Io.Threaded.global_single_threaded.io();
    const path = "test_membership_service.store";
    std.Io.Dir.cwd().deleteFile(io, path) catch {};
    defer std.Io.Dir.cwd().deleteFile(io, path) catch {};
    const me = try Identity.fromSeed([_]u8{0x71} ** identity_mod.seed_len);
    const phone = try Identity.fromSeed([_]u8{0x72} ** identity_mod.seed_len);
    var store = try trust_mod.Store.load(testing.allocator, path, me.seed());
    defer store.deinit();

    const Seen = struct {
        trusted: usize = 0,
        revoked: usize = 0,
        fn onTrusted(ctx: *anyopaque, _: *const Ticket) void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.trusted += 1;
        }
        fn onRevoked(ctx: *anyopaque, _: NodeID, _: ?[32]u8) void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.revoked += 1;
        }
    };
    var seen: Seen = .{};
    var m: Membership = .{
        .allocator = testing.allocator,
        .identity = me,
        .transport_key = [_]u8{1} ** 32,
        .nickname = "Desk",
        .node_port = 14700,
        .swarm_key = [_]u8{2} ** 32,
        .trust = &store,
        .hooks = .{ .ctx = &seen, .trustedFn = Seen.onTrusted, .revokedFn = Seen.onRevoked },
    };
    defer m.close();

    // This device's own ticket, as another device would trust it.
    const mine = try m.ticket("", 1000);
    try testing.expectEqualStrings("Desk", mine.nicknameSlice());
    // Without explicit addresses, every one this machine has, on the node port.
    try testing.expect(mine.addressesSlice().len > 0);
    try testing.expect(std.mem.endsWith(u8, mine.addressesSlice(), ":14700"));

    // The phone's ticket: trusted, saved, hook told.
    var uri_buf: [pairing.max_uri_len]u8 = undefined;
    const newer = try Ticket.init(phone, [_]u8{3} ** 32, "Phone", "10.0.0.2:14700", 5000);
    const t = try m.trustUri(try newer.toUri(&uri_buf), 1000);
    try testing.expect(t.added);
    try testing.expectEqual(@as(usize, 1), seen.trusted);
    var reloaded = try trust_mod.Store.load(testing.allocator, path, me.seed());
    defer reloaded.deinit();
    try testing.expect(reloaded.isTrusted(phone.deviceId()));

    // An older ticket of it is refused.
    const older = try Ticket.init(phone, [_]u8{3} ** 32, "Phone", "10.0.0.2:14700", 4000);
    try testing.expectError(error.StaleTicket, m.trustUri(try older.toUri(&uri_buf), 1000));

    // Revoked by the fingerprint the device list shows.
    var fp_buf: [19]u8 = undefined;
    const fp = Identity.formatFingerprint(phone.fingerprint(), &fp_buf);
    const r = try m.revoke(fp, 2000);
    try testing.expect(r.removed and r.device.eql(phone.deviceId()));
    try testing.expect(!store.isTrusted(phone.deviceId()));
    try testing.expectEqual(@as(usize, 1), seen.revoked);
    try testing.expectError(error.DeviceNotFound, m.revoke("ffffffff", 2001));

    // No invite open.
    try testing.expect(m.inviteStatus(2000).state == .none);
}
