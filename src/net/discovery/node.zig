const sync = @import("../../sync.zig");
const std = @import("std");
const id = @import("../id.zig");
const kbucket = @import("kbucket.zig");
const rpc = @import("rpc.zig");
const network = @import("../transport/mod.zig");
const relay = network.relay;
const local_addrs = @import("../local_addrs.zig");
const lookup_mod = @import("lookup.zig");
const chunker = @import("../../storage/chunker.zig");
const codec = @import("../../storage/dag/codec.zig");
const StorageEngine = @import("../../storage/engine.zig").StorageEngine;
const providers_mod = @import("providers.zig");
const device_trust = @import("../../device/trust.zig");
const device_rotation = @import("../../device/rotation.zig");
const identity_mod = @import("../../device/identity.zig");

/// Bounds on values peers can STORE here. Without them any peer could fill
/// our memory with arbitrary values.
pub const StoreLimits = struct {
    max_value_len: usize = 64 * 1024,
    max_total_bytes: usize = 64 * 1024 * 1024,
    max_keys: usize = 100_000,
};

pub const Node = struct {
    allocator: std.mem.Allocator,
    manager: *network.manager.ConnectionManager,
    routing_table: kbucket.RoutingTable,
    swarm_key: []const u8,
    storage: std.AutoHashMapUnmanaged(id.NodeID, []u8),
    mutex: sync.Mutex = .{},
    /// Set by request threads when an inbound PING proves we are reachable.
    is_public: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    handlers_wg: sync.WaitGroup = .{},
    handlers_mutex: sync.Mutex = .{},
    stopping: std.atomic.Value(bool) = .init(false),
    active_handlers: usize = 0,
    /// Bound on every blocking step of a DHT RPC, in both directions, so a
    /// peer that accepts a stream and goes silent cannot stall a lookup or
    /// pin a request thread.
    rpc_timeout_ms: u32 = 10_000,
    /// Blocks served to peers via GET_BLOCK. Null on nodes without storage.
    block_store: ?*StorageEngine = null,
    /// Where revocations from peers are recorded. Without a store a node
    /// refuses revocation messages instead of ignoring them silently.
    trust_store: ?*device_trust.Store = null,
    /// Answers GET_SHARES. Null on nodes that share nothing: they reply
    /// with an empty listing.
    share_source: ?ShareSource = null,
    /// Answers GET_NODE_INFO; set by the node (root.zig).
    info_source: ?InfoSource = null,
    /// Answers GET_SWARM with the swarm folder's manifest. Null: an empty
    /// manifest.
    swarm_source: ?ShareSource = null,
    /// Told about an accepted swarm key rotation (key, epoch). Without one
    /// the node refuses rotations.
    rotation_sink: ?RotationSink = null,
    /// This device's current key epoch (config node.swarm_epoch).
    /// Runtime writers must use setSwarmEpoch; guarded by rotation_mutex.
    swarm_epoch: u64 = 0,
    rotation_mutex: sync.Mutex = .{},
    /// Human name sent with SHARES (config node.nickname).
    nickname: []const u8 = "",
    /// The roles this node announces in every PING and PONG (rpc.Roles):
    /// swarm backup, metered network. Root.zig keeps them current.
    local_roles: std.atomic.Value(u8) = std.atomic.Value(u8).init(0),
    /// Each peer's announced roles (the PING/PONG trailing byte), keyed by
    /// node ID; the peer least recently heard makes room. Guarded by
    /// `mutex`.
    peer_roles: PeerRoles = .{},
    /// Told about a revocation applied here (the revoked device's ID), so
    /// it leaves every registry that lists it (e.g. cluster/holders.zig).
    revocation_sink: ?RevocationSink = null,
    /// This node's Ed25519 identity, used to sign revocations it pushes.
    device_identity: ?identity_mod.Identity = null,
    store_limits: StoreLimits = .{},
    /// Sum of value lengths in `storage`. Guarded by `mutex`.
    stored_bytes: usize = 0,
    /// Who holds content for which key. Guarded by `mutex`.
    providers: providers_mod.ProviderStore = .{},
    /// Streams this node is piping between two other devices.
    active_relays: std.atomic.Value(u32) = .init(0),
    /// Devices no relay reached lately -> when to try again (ms). Guarded
    /// by `mutex`.
    relay_misses: std.AutoHashMapUnmanaged(id.NodeID, i64) = .empty,
    /// Per peer device: the member list last sent to it, so pings don't
    /// re-send an unchanged list. Guarded by `mutex`.
    admit_sent: std.AutoHashMapUnmanaged(id.NodeID, AdmitSent) = .empty,

    discovery_dials: std.AutoHashMapUnmanaged(id.NodeID, i64) = .empty,

    pub const max_handlers = 256;
    const max_recent_peers = 1024;

    /// Produces this node's share listing (an encoded dir block, owned by
    /// the caller) on demand. Type-erased so the DHT does not depend on the
    /// filesystem layer that implements it.
    pub const ShareSource = struct {
        ctx: *anyopaque,
        listFn: *const fn (ctx: *anyopaque, allocator: std.mem.Allocator) anyerror![]u8,
        /// The SHARES `backup` field (fs/backup.zig), caller-owned; null
        /// when the source has none.
        backupFn: ?*const fn (ctx: *anyopaque, allocator: std.mem.Allocator) anyerror![]u8 = null,
    };

    /// Answers GET_NODE_INFO (node_info.zig): the encoded info,
    /// caller-owned.
    pub const InfoSource = struct {
        ctx: *anyopaque,
        infoFn: *const fn (ctx: *anyopaque, allocator: std.mem.Allocator) anyerror![]u8,
    };

    pub const RotationSink = struct {
        ctx: *anyopaque,
        /// Persist and adopt the new key (restarting the node). Called
        /// from a request thread after the rotation was verified.
        applyFn: *const fn (ctx: *anyopaque, new_key: [32]u8, epoch: u64) void,
    };

    /// Told about an honored revocation (its device ID).
    pub const RevocationSink = struct {
        ctx: *anyopaque,
        revokedFn: *const fn (ctx: *anyopaque, device_id: id.NodeID) void,
    };

    /// Peers' announced roles, bounded: at most max_peer_roles devices,
    /// the least recently heard making room.
    pub const PeerRoles = struct {
        entries: [max_peer_roles]RoleEntry = undefined,
        count: usize = 0,

        pub const max_peer_roles = 256;
        const RoleEntry = struct { id: id.NodeID, roles: u8, heard_ms: i64 };
    };

    /// Turns one announced role bit (rpc.Roles) on or off. The next PING
    /// or PONG tells peers.
    pub fn setRole(self: *Node, bit: u8, on: bool) void {
        const old = self.local_roles.load(.acquire);
        self.local_roles.store(if (on) old | bit else old & ~bit, .release);
    }

    fn announcedRoles(self: *Node) u8 {
        return self.local_roles.load(.monotonic);
    }

    /// Records `roles` for an authenticated peer (PING or PONG heard).
    fn recordPeerRoles(self: *Node, peer: id.NodeID, roles: u8) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.recordPeerRolesLocked(peer, roles, sync.monotonicMillis());
    }

    fn recordPeerRolesLocked(self: *Node, peer: id.NodeID, roles: u8, now: i64) void {
        for (self.peer_roles.entries[0..self.peer_roles.count]) |*e| {
            if (e.id.eql(peer)) {
                e.roles = roles;
                e.heard_ms = now;
                return;
            }
        }
        if (self.peer_roles.count < PeerRoles.max_peer_roles) {
            self.peer_roles.entries[self.peer_roles.count] = .{ .id = peer, .roles = roles, .heard_ms = now };
            self.peer_roles.count += 1;
            return;
        }
        // Full: the peer least recently heard makes room.
        var victim: usize = 0;
        for (self.peer_roles.entries, 0..) |e, i| {
            if (e.heard_ms < self.peer_roles.entries[victim].heard_ms) victim = i;
        }
        self.peer_roles.entries[victim] = .{ .id = peer, .roles = roles, .heard_ms = now };
    }

    /// A peer's announced roles, or null when it hasn't been heard since
    /// this node started.
    pub fn peerRoles(self: *Node, peer: id.NodeID) ?u8 {
        self.mutex.lock();
        defer self.mutex.unlock();
        for (self.peer_roles.entries[0..self.peer_roles.count]) |e| {
            if (e.id.eql(peer)) return e.roles;
        }
        return null;
    }

    /// Copies up to `out.len` known peer IDs (the routing table).
    pub fn copyPeerIDs(self: *Node, out: []id.NodeID) usize {
        const peers = blk: {
            self.mutex.lock();
            defer self.mutex.unlock();
            break :blk self.routing_table.getAllPeers() catch return 0;
        };
        defer self.routing_table.allocator.free(peers);
        const n = @min(peers.len, out.len);
        for (peers[0..n], out[0..n]) |p, *o| o.* = p.id;
        return n;
    }

    pub fn init(allocator: std.mem.Allocator, manager: *network.manager.ConnectionManager, swarm_key: []const u8) Node {
        return .{
            .allocator = allocator,
            .manager = manager,
            .routing_table = kbucket.RoutingTable.init(allocator, manager.node_id),
            .swarm_key = swarm_key,
            .storage = .empty,
            .mutex = .{},
            .is_public = std.atomic.Value(bool).init(false),
            .handlers_wg = .{},
        };
    }

    /// mDNS announcements are unauthenticated, so a new peer is only added
    /// after we dial it (the handshake proves the ID) and it answers a PING.
    pub fn onDiscovery(self: *Node, peer_id: id.NodeID, addr: network.Address) void {
        if (peer_id.eql(self.manager.node_id)) return;
        if (local_addrs.classify(addr) == .invalid) return;
        if (!addr.isLoopback() and !local_addrs.onLink(addr)) return;
        if (self.stopping.load(.acquire)) return;
        if (self.manager.existingConnection(peer_id)) |conn| {
            conn.deinit();
            return;
        }
        {
            self.mutex.lock();
            defer self.mutex.unlock();
            if (self.routing_table.contains(peer_id)) return;
            const now = sync.monotonicMillis();
            pruneRecent(&self.discovery_dials, now);
            if (self.discovery_dials.contains(peer_id)) return;
            if (self.discovery_dials.count() >= max_recent_peers) return;
            self.discovery_dials.put(self.allocator, peer_id, now + 30_000) catch return;
        }

        const conn = self.manager.connectToPeer(addr, self.swarm_key, peer_id) catch return;
        defer conn.deinit();
        self.ping(conn) catch {};
    }

    fn pingLruAndEvict(self: *Node, lru: kbucket.PeerInfo) void {
        if (self.manager.connectToPeerMulti(lru.addresses[0..lru.addrs_count], self.swarm_key, lru.id)) |conn| {
            defer conn.deinit();
            self.ping(conn) catch {
                self.mutex.lock();
                self.routing_table.markDisconnected(lru.id);
                self.mutex.unlock();
            };
        } else |_| {
            self.mutex.lock();
            self.routing_table.markDisconnected(lru.id);
            self.mutex.unlock();
        }
    }

    pub fn checkReachability(self: *Node, conn: network.Connection) !void {
        const stream = try conn.openStream();
        defer stream.close();
        stream.setTimeout(self.rpc_timeout_ms);

        const msg = rpc.Message{
            .sender_id = self.manager.node_id,
            .payload = .{ .DIAL_BACK = .{ .port = self.manager.bound_port } },
        };
        try msg.send(self.allocator, stream);
        // We don't wait for a response on this stream.
        // We wait for an INCOMING connection on our listen port.
    }

    /// Stops admission before waiting, so repeated drains are safe.
    pub fn drainHandlers(self: *Node) void {
        self.handlers_mutex.lock();
        self.stopping.store(true, .release);
        self.handlers_mutex.unlock();
        self.handlers_wg.wait();
    }

    fn startHandler(self: *Node) bool {
        self.handlers_mutex.lock();
        defer self.handlers_mutex.unlock();
        if (self.stopping.load(.acquire) or self.active_handlers >= max_handlers) return false;
        self.active_handlers += 1;
        self.handlers_wg.start();
        return true;
    }

    fn finishHandler(self: *Node) void {
        self.handlers_mutex.lock();
        self.active_handlers -= 1;
        self.handlers_mutex.unlock();
        self.handlers_wg.finish();
    }

    pub fn deinit(self: *Node) void {
        self.drainHandlers();

        self.mutex.lock();
        defer self.mutex.unlock();
        self.routing_table.deinit();
        var it = self.storage.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.value_ptr.*);
        }
        self.storage.deinit(self.allocator);
        self.providers.deinit(self.allocator);
        self.relay_misses.deinit(self.allocator);
        self.admit_sent.deinit(self.allocator);
        self.discovery_dials.deinit(self.allocator);
    }

    /// This device's addresses on every network it's on, to announce.
    fn announced(self: *Node) rpc.Announced {
        var a: rpc.Announced = .{};
        if (self.manager.bound_port == 0) return a;
        a.count = std.math.cast(u8, local_addrs.list(&a.addrs, self.manager.bound_port)) orelse 0;
        return a;
    }

    pub fn ping(self: *Node, conn: network.Connection) !void {
        const stream = try conn.openStream();
        defer stream.close();
        stream.setTimeout(self.rpc_timeout_ms);

        const msg = rpc.Message{
            .sender_id = self.manager.node_id,
            .payload = .{ .PING = .{ .port = self.manager.bound_port, .announced = self.announced(), .roles = self.announcedRoles() } },
        };

        try msg.send(self.allocator, stream);

        // Wait for PONG
        const response = try rpc.Message.deserialize(self.allocator, stream.reader());
        defer response.deinit(self.allocator);
        if (response.payload != .PONG) return error.InvalidResponse;

        // Record the ID the handshake authenticated, not the claimed one.
        const peer_id = conn.getRemoteNodeID();
        if (!response.sender_id.eql(peer_id)) return error.PeerIdMismatch;
        self.recordPeerRoles(peer_id, response.payload.PONG.roles);

        var info = kbucket.PeerInfo{
            .id = peer_id,
            .last_seen = sync.timestamp(),
        };
        // The socket's IP with the port the peer listens on: when the peer
        // opened this connection, its source port is a random one.
        // Relayed: no address of the peer's own; it announces its own.
        var address = conn.getPeerAddress();
        if (response.payload.PONG.port) |port| if (port != 0) address.setPort(port);
        if (!conn.getPeerAddress().isUnspecified() and local_addrs.classify(address) != .invalid)
            _ = info.addAddressFrom(address, .observed, info.last_seen);
        for (response.payload.PONG.announced.slice()) |addr| {
            if (acceptAnnounced(addr, conn.getPeerAddress())) _ = info.addAddressFrom(addr, .announced, info.last_seen);
        }
        {
            self.mutex.lock();
            defer self.mutex.unlock();
            _ = try self.routing_table.addPeer(info);
        }

        // Outbound connections are the natural propagation point: every
        // PONG we just verified is an authenticated peer that can now hear
        // which devices we stopped trusting.
        if (self.trust_store) |trust| {
            if (trust.revocationCount() > 0) {
                _ = self.pushRevocations(conn) catch {};
            }
            // And which devices belong to the swarm: pairing with one member
            // makes a device a member everywhere.
            if (trust.count() > 0) _ = self.pushAdmissions(conn) catch {};
        }
    }

    /// Stores `value` at the K closest peers to `key`. Fails unless at least
    /// one peer acknowledged keeping it.
    pub fn store(self: *Node, key: id.NodeID, value: []const u8) !void {
        if (try self.storeReplicated(key, value) == 0) return error.StoreFailed;
    }

    /// Stores `value` at the K closest peers to `key` and returns how many
    /// acknowledged keeping it (sent but unacknowledged STOREs do not count).
    pub fn storeReplicated(self: *Node, key: id.NodeID, value: []const u8) !usize {
        // Ensure we know about the closest nodes
        try self.lookup(key);

        const closest = blk: {
            self.mutex.lock();
            defer self.mutex.unlock();
            break :blk try self.routing_table.getClosestPeers(key, kbucket.K);
        };
        defer self.allocator.free(closest);

        // Our own ID is never in the routing table, so every target is remote.
        var acked: usize = 0;
        for (closest) |peer| {
            self.sendStore(peer.addresses[0..peer.addrs_count], key, value, peer.id) catch |err| {
                std.debug.print("Failed to store at {x}: {any}\n", .{ peer.id.bytes[0..4], err });
                continue;
            };
            acked += 1;
        }
        return acked;
    }

    /// Stores a value locally, within `store_limits`.
    pub fn localStore(self: *Node, key: id.NodeID, value: []const u8) !void {
        const limits = self.store_limits;
        if (value.len > limits.max_value_len) return error.ValueTooLarge;

        self.mutex.lock();
        defer self.mutex.unlock();

        const existing = self.storage.get(key);
        if (existing == null and self.storage.count() >= limits.max_keys) return error.StorageFull;
        const old_len = if (existing) |old| old.len else 0;
        const new_total = self.stored_bytes - old_len + value.len;
        if (new_total > limits.max_total_bytes) return error.StorageFull;

        const v_copy = try self.allocator.dupe(u8, value);
        errdefer self.allocator.free(v_copy);
        const res = try self.storage.getOrPut(self.allocator, key);
        if (res.found_existing) {
            self.allocator.free(res.value_ptr.*);
        }
        res.value_ptr.* = v_copy;
        self.stored_bytes = new_total;
    }

    /// Registers this node as a provider of `key` with the K closest peers
    /// and returns how many acknowledged it.
    pub fn addProvider(self: *Node, key: id.NodeID) !usize {
        try self.lookup(key);
        const closest = try self.closestPeers(key);
        defer self.allocator.free(closest);

        var acked: usize = 0;
        for (closest) |peer| {
            self.sendAddProvider(peer, key) catch |err| {
                std.debug.print("Failed to announce provider to {x}: {any}\n", .{ peer.id.bytes[0..4], err });
                continue;
            };
            acked += 1;
        }
        return acked;
    }

    /// Refreshes the routing view for `key` and returns the K closest peers
    /// (caller-owned). Used both to replicate values and to choose holders.
    pub fn closestFor(self: *Node, key: id.NodeID) ![]kbucket.PeerInfo {
        try self.lookup(key);
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.routing_table.getClosestPeers(key, kbucket.K);
    }

    /// Returns up to providers.max_per_key other nodes holding content for
    /// `key` (caller-owned): known locally plus those the K closest peers
    /// report.
    pub fn findProviders(self: *Node, key: id.NodeID) ![]id.NodeID {
        var found: std.ArrayList(id.NodeID) = .empty;
        errdefer found.deinit(self.allocator);

        {
            var local: [providers_mod.max_per_key]id.NodeID = undefined;
            self.mutex.lock();
            defer self.mutex.unlock();
            for (self.providers.get(key, sync.timestamp(), &local)) |p| {
                try self.appendProvider(&found, p);
            }
        }

        try self.lookup(key);
        const closest = try self.closestPeers(key);
        defer self.allocator.free(closest);

        for (closest) |peer| {
            if (found.items.len >= providers_mod.max_per_key) break;
            const remote = self.queryProviders(peer, key) catch continue;
            defer self.allocator.free(remote);
            for (remote) |p| {
                if (found.items.len >= providers_mod.max_per_key) break;
                try self.appendProvider(&found, p);
            }
        }
        return found.toOwnedSlice(self.allocator);
    }

    fn appendProvider(self: *Node, list: *std.ArrayList(id.NodeID), provider: id.NodeID) !void {
        if (provider.eql(self.manager.node_id)) return;
        for (list.items) |p| {
            if (p.eql(provider)) return;
        }
        try list.append(self.allocator, provider);
    }

    fn closestPeers(self: *Node, key: id.NodeID) ![]kbucket.PeerInfo {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.routing_table.getClosestPeers(key, kbucket.K);
    }

    fn sendAddProvider(self: *Node, peer: kbucket.PeerInfo, key: id.NodeID) !void {
        const conn = try self.manager.connectToPeerMulti(peer.addresses[0..peer.addrs_count], self.swarm_key, peer.id);
        defer conn.deinit();
        const stream = try conn.openStream();
        defer stream.close();
        stream.setTimeout(self.rpc_timeout_ms);

        const msg = rpc.Message{ .sender_id = self.manager.node_id, .payload = .{ .ADD_PROVIDER = .{ .key = key } } };
        try msg.send(self.allocator, stream);

        const response = try rpc.Message.deserialize(self.allocator, stream.reader());
        defer response.deinit(self.allocator);
        switch (response.payload) {
            .STORE_ACK => |ack| if (!ack.stored) return error.StoreRejected,
            else => return error.InvalidResponse,
        }
    }

    /// Returns the providers `peer` knows for `key` (caller-owned).
    fn queryProviders(self: *Node, peer: kbucket.PeerInfo, key: id.NodeID) ![]const id.NodeID {
        const conn = try self.manager.connectToPeerMulti(peer.addresses[0..peer.addrs_count], self.swarm_key, peer.id);
        defer conn.deinit();
        const stream = try conn.openStream();
        defer stream.close();
        stream.setTimeout(self.rpc_timeout_ms);

        const msg = rpc.Message{ .sender_id = self.manager.node_id, .payload = .{ .GET_PROVIDERS = .{ .key = key } } };
        try msg.send(self.allocator, stream);

        const response = try rpc.Message.deserialize(self.allocator, stream.reader());
        switch (response.payload) {
            // Ownership of the list moves to the caller.
            .PROVIDERS => |p| return p.providers,
            else => {
                response.deinit(self.allocator);
                return error.InvalidResponse;
            },
        }
    }

    fn lookupValueWorker(node: *Node, state: *lookup_mod.LookupState, peer: kbucket.PeerInfo, target: id.NodeID, result_ptr: *?[]u8, result_mutex: *sync.Mutex) void {
        const candidate = node.lookupCandidate(peer);
        var via: ?network.Address = null;
        const result_or_err = node.sendFindValue(candidate.peer.addresses[0..candidate.peer.addrs_count], target, peer.id, &via);
        if (result_or_err) |result| {
            // Successful response, verify peer
            var p_updates = kbucket.PeerInfo{ .id = peer.id, .last_seen = sync.timestamp() };
            if (via) |addr| _ = p_updates.addAddressFrom(addr, .observed, p_updates.last_seen);
            node.addVerifiedPeer(p_updates);

            switch (result) {
                .value => |v| {
                    // Found it!
                    result_mutex.lock();
                    if (result_ptr.* == null) {
                        result_ptr.* = v;
                    } else {
                        node.allocator.free(v);
                    }
                    result_mutex.unlock();
                },
                .closer_peers => |closer| {
                    defer node.allocator.free(closer);
                    state.reportReply(peer.id, closer) catch {};
                    // NOTE: Hearsay peers not added to RT.
                },
            }
        } else |_| {
            state.reportFailure(peer.id);
            node.mutex.lock();
            defer node.mutex.unlock();
            if (candidate.tried_known) node.routing_table.markDisconnected(peer.id);
        }
    }

    pub fn lookupValue(self: *Node, target: id.NodeID) !?[]u8 {
        // Check local storage first
        const initial_peers = blk: {
            self.mutex.lock();
            defer self.mutex.unlock();
            if (self.storage.get(target)) |val| return try self.allocator.dupe(u8, val);
            break :blk try self.routing_table.getClosestPeers(target, kbucket.K);
        };
        defer self.allocator.free(initial_peers);

        var state = try lookup_mod.LookupState.init(self.allocator, target, initial_peers);
        defer state.deinit();

        // Workers write through pointers to these locals. runLookupRound joins
        // every worker it starts, so none can outlive this frame.
        var result: ?[]u8 = null;
        var result_mutex = sync.Mutex{};
        errdefer if (result) |v| self.allocator.free(v);

        while (!state.isFinished()) {
            // No worker is running between rounds.
            if (result) |v| return v;

            const next_peers = try state.nextPeersToQuery();
            defer self.allocator.free(next_peers);

            if (next_peers.len == 0) {
                if (state.in_flight.count() > 0) {
                    sync.sleep(10 * std.time.ns_per_ms);
                    continue;
                }
                break;
            }

            self.runLookupRound(&state, next_peers, lookupValueWorker, .{ target, &result, &result_mutex });
        }

        return result;
    }

    /// Queries `peers` in parallel and joins every worker it started before
    /// returning. A peer whose worker cannot be spawned counts as failed.
    fn runLookupRound(
        self: *Node,
        state: *lookup_mod.LookupState,
        peers: []const kbucket.PeerInfo,
        comptime worker: anytype,
        extra_args: anytype,
    ) void {
        std.debug.assert(peers.len <= lookup_mod.Alpha);

        var threads: [lookup_mod.Alpha]std.Thread = undefined;
        var started: usize = 0;
        defer for (threads[0..started]) |t| t.join();

        for (peers) |peer| {
            if (peer.id.eql(self.manager.node_id)) {
                state.reportFailure(peer.id);
                continue;
            }
            state.markInFlight(peer.id);
            threads[started] = std.Thread.spawn(.{}, worker, .{ self, state, peer } ++ extra_args) catch |err| {
                std.debug.print("Lookup: failed to spawn worker: {any}\n", .{err});
                state.reportFailure(peer.id);
                continue;
            };
            started += 1;
        }
    }

    /// Sends STORE and waits for the peer's STORE_ACK.
    pub fn sendStore(self: *Node, addresses: []const network.Address, key: id.NodeID, value: []const u8, peer_id: ?id.NodeID) !void {
        const conn = try self.manager.connectToPeerMulti(addresses, self.swarm_key, peer_id);
        defer conn.deinit();

        const stream = try conn.openStream();
        defer stream.close();
        stream.setTimeout(self.rpc_timeout_ms);

        const msg = rpc.Message{
            .sender_id = self.manager.node_id,
            .payload = .{ .STORE = .{ .key = key, .value = value } },
        };
        try msg.send(self.allocator, stream);

        const response = try rpc.Message.deserialize(self.allocator, stream.reader());
        defer response.deinit(self.allocator);
        switch (response.payload) {
            .STORE_ACK => |ack| if (!ack.stored) return error.StoreRejected,
            else => return error.InvalidResponse,
        }
    }

    /// Asks `conn`'s peer for a block. Returns the caller-owned block bytes,
    /// or null if the peer does not hold it. The bytes are NOT verified here;
    /// StorageEngine.put checks them against the CID.
    pub fn fetchBlock(self: *Node, conn: network.Connection, cid: [32]u8) !?[]u8 {
        const stream = try conn.openStream();
        defer stream.close();
        stream.setTimeout(self.rpc_timeout_ms);

        const msg = rpc.Message{
            .sender_id = self.manager.node_id,
            .payload = .{ .GET_BLOCK = .{ .cid = cid } },
        };
        try msg.send(self.allocator, stream);

        const response = try rpc.Message.deserialize(self.allocator, stream.reader());
        switch (response.payload) {
            // Ownership of the data moves to the caller; nothing else to free.
            .BLOCK => |b| return @constCast(b.data),
            else => {
                response.deinit(self.allocator);
                return error.InvalidResponse;
            },
        }
    }

    pub const SharesReply = struct {
        nickname: []u8,
        /// Encoded dir block; validate with codec.decode.
        listing: []u8,
        /// The `backup` field (fs/backup.zig decodes it); may be empty.
        backup: []u8,
    };

    /// Asks `conn`'s peer which folders it shares. Both slices of the reply
    /// are owned by the caller (allocated with the node's allocator).
    pub fn fetchShares(self: *Node, conn: network.Connection) !SharesReply {
        const stream = try conn.openStream();
        defer stream.close();
        stream.setTimeout(self.rpc_timeout_ms);

        const msg = rpc.Message{
            .sender_id = self.manager.node_id,
            .payload = .{ .GET_SHARES = {} },
        };
        try msg.send(self.allocator, stream);

        const response = try rpc.Message.deserialize(self.allocator, stream.reader());
        switch (response.payload) {
            .SHARES => |p| return .{ .nickname = @constCast(p.nickname), .listing = @constCast(p.listing), .backup = @constCast(p.backup) },
            else => {
                response.deinit(self.allocator);
                return error.InvalidResponse;
            },
        }
    }

    /// Hands `new_key` (epoch) to `conn`'s peer, signed with this device's
    /// identity. Returns whether the peer adopted it. Only call this for a
    /// connection whose device is trusted: the key travels to whoever it is.
    pub fn sendRotation(self: *Node, conn: network.Connection, new_key: [32]u8, epoch: u64) !bool {
        const identity = self.device_identity orelse return error.NoDeviceIdentity;
        const signature = try identity.sign(&device_rotation.message(epoch, new_key));
        const stream = try conn.openStream();
        defer stream.close();
        stream.setTimeout(self.rpc_timeout_ms);
        const msg = rpc.Message{ .sender_id = self.manager.node_id, .payload = .{ .ROTATE_KEY = .{
            .epoch = epoch,
            .new_key = new_key,
            .signer_key = identity.publicKey(),
            .signature = signature,
        } } };
        try msg.send(self.allocator, stream);
        const response = try rpc.Message.deserialize(self.allocator, stream.reader());
        defer response.deinit(self.allocator);
        return switch (response.payload) {
            .STORE_ACK => |ack| ack.stored,
            else => error.InvalidResponse,
        };
    }

    /// Asks `conn`'s peer for its swarm folder manifest (caller-owned,
    /// allocated with the node's allocator; validate by merging it).
    pub fn fetchSwarm(self: *Node, conn: network.Connection) ![]u8 {
        const stream = try conn.openStream();
        defer stream.close();
        stream.setTimeout(self.rpc_timeout_ms);
        const msg = rpc.Message{ .sender_id = self.manager.node_id, .payload = .{ .GET_SWARM = {} } };
        try msg.send(self.allocator, stream);
        const response = try rpc.Message.deserialize(self.allocator, stream.reader());
        switch (response.payload) {
            .SWARM => |p| return @constCast(p.manifest),
            else => {
                response.deinit(self.allocator);
                return error.InvalidResponse;
            },
        }
    }

    /// Pushes a block to `conn`'s peer. The receiver verifies the bytes
    /// against the CID before storing; returns whether it kept the block.
    pub fn putBlock(self: *Node, conn: network.Connection, cid: [32]u8, data: []const u8) !bool {
        const stream = try conn.openStream();
        defer stream.close();
        stream.setTimeout(self.rpc_timeout_ms);

        const msg = rpc.Message{
            .sender_id = self.manager.node_id,
            .payload = .{ .PUT_BLOCK = .{ .cid = cid, .data = data } },
        };
        try msg.send(self.allocator, stream);

        const response = try rpc.Message.deserialize(self.allocator, stream.reader());
        defer response.deinit(self.allocator);
        switch (response.payload) {
            .STORE_ACK => |ack| return ack.stored,
            else => return error.InvalidResponse,
        }
    }

    /// Signs and pushes `device`'s revocation to `conn`'s peer. Fails when
    /// this node has no device identity to sign with.
    pub fn sendRevoke(self: *Node, conn: network.Connection, device_id: id.NodeID) !bool {
        if (self.trust_store) |trust| {
            const tombstones = try trust.copyRevocations(self.allocator);
            defer self.allocator.free(tombstones);
            for (tombstones) |r| {
                if (r.device_id.eql(device_id)) return self.sendRevokeAt(conn, device_id, r.at);
            }
        }
        const now = std.math.cast(u64, sync.timestamp()) orelse return error.InvalidTimestamp;
        return self.sendRevokeAt(conn, device_id, now);
    }

    fn sendRevokeAt(self: *Node, conn: network.Connection, device_id: id.NodeID, at: u64) !bool {
        const identity = self.device_identity orelse return error.NoDeviceIdentity;
        const signed = device_trust.revocationMessage(device_id, identity.deviceId(), at);
        const stream = try conn.openStream();
        defer stream.close();
        stream.setTimeout(self.rpc_timeout_ms);

        const signature = try identity.sign(&signed);

        const msg = rpc.Message{
            .sender_id = self.manager.node_id,
            .payload = .{ .REVOKE = .{ .device_id = device_id, .signer_key = identity.publicKey(), .at = at, .signature = signature } },
        };
        try msg.send(self.allocator, stream);

        const response = try rpc.Message.deserialize(self.allocator, stream.reader());
        defer response.deinit(self.allocator);
        switch (response.payload) {
            .STORE_ACK => |ack| return ack.stored,
            else => return error.InvalidResponse,
        }
    }

    /// Sends every tombstone this node holds to `conn`'s peer, so a newly
    /// connected peer learns which devices were removed elsewhere. Returns
    /// how many peers honored them. No-op without tombstones or an identity.
    pub fn pushRevocations(self: *Node, conn: network.Connection) !usize {
        const trust = self.trust_store orelse return 0;
        if (self.device_identity == null) return 0;
        const tombstones = try trust.copyRevocations(self.allocator);
        defer self.allocator.free(tombstones);

        var honored: usize = 0;
        for (tombstones) |r| {
            const ok = self.sendRevokeAt(conn, r.device_id, r.at) catch |err| {
                std.debug.print("Failed to push revocation of {x}: {any}\n", .{ r.device_id.bytes[0..4], err });
                continue;
            };
            if (ok) honored += 1;
        }
        return honored;
    }

    pub const AdmitSent = struct {
        digest: u64,
        at: i64,
        /// The peer took every vouch.
        complete: bool,

        /// Seconds before the same list is sent again: rarely once taken (a
        /// peer may have lost its store), sooner when some were refused.
        fn retryAfter(self: AdmitSent) i64 {
            return if (self.complete) 6 * 60 * 60 else 10 * 60;
        }
    };

    /// Signs and sends this node's vouch for `entry` (ADMIT): `entry` is a
    /// member here, admitted at `entry.added_at`.
    fn sendAdmit(self: *Node, conn: network.Connection, entry: device_trust.Entry) !bool {
        const identity = self.device_identity orelse return error.NoDeviceIdentity;
        const label = entry.labelSlice();
        const signed = device_trust.admissionMessage(entry.public_key, entry.transport_key, label, entry.added_at, identity.deviceId());
        var admit: rpc.Admit = .{
            .public_key = entry.public_key,
            .transport_key = entry.transport_key,
            .at = entry.added_at,
            .signer_key = identity.publicKey(),
            .signature = try identity.sign(&signed),
        };
        @memcpy(admit.label[0..label.len], label);
        admit.label_len = @intCast(label.len);

        const stream = try conn.openStream();
        defer stream.close();
        stream.setTimeout(self.rpc_timeout_ms);
        const msg = rpc.Message{ .sender_id = self.manager.node_id, .payload = .{ .ADMIT = admit } };
        try msg.send(self.allocator, stream);
        const response = try rpc.Message.deserialize(self.allocator, stream.reader());
        defer response.deinit(self.allocator);
        switch (response.payload) {
            .STORE_ACK => |ack| return ack.stored,
            else => return error.InvalidResponse,
        }
    }

    /// Vouches for every member this node trusts to `conn`'s peer. A peer
    /// that trusts this node adds the ones it doesn't know. Returns how many
    /// it took. Entries without a pinned transport key are not sent.
    pub fn pushAdmissions(self: *Node, conn: network.Connection) !usize {
        const trust = self.trust_store orelse return 0;
        if (self.device_identity == null) return 0;
        const entries = try trust.copyEntries(self.allocator);
        defer self.allocator.free(entries);
        const peer = conn.getRemoteDeviceID();
        var hasher = std.hash.Wyhash.init(0);
        for (entries) |e| {
            hasher.update(&e.device_id.bytes);
            hasher.update(std.mem.asBytes(&e.added_at));
        }
        const digest = hasher.final();
        const now = sync.timestamp();
        if (peer) |p| {
            self.mutex.lock();
            const fresh = if (self.admit_sent.get(p)) |last| last.digest == digest and now -| last.at < last.retryAfter() else false;
            self.mutex.unlock();
            if (fresh) return 0;
        }

        var taken: usize = 0;
        var sent: usize = 0;
        for (entries) |e| {
            if (std.mem.eql(u8, &e.transport_key, &device_trust.no_transport_key)) continue;
            // The peer itself needs no vouch for itself.
            if (peer) |p| if (p.eql(e.device_id)) continue;
            sent += 1;
            const ok = self.sendAdmit(conn, e) catch |err| {
                std.debug.print("Failed to vouch for {x}: {any}\n", .{ e.device_id.bytes[0..4], err });
                continue;
            };
            if (ok) taken += 1;
        }
        // Remembered either way: a peer that refused some vouches (it
        // doesn't trust this node yet, or its store is full) hears the list
        // again after a while, not on every ping.
        if (peer) |p| {
            self.mutex.lock();
            defer self.mutex.unlock();
            if (self.admit_sent.count() >= 256) self.admit_sent.clearRetainingCapacity();
            self.admit_sent.put(self.allocator, p, .{ .digest = digest, .at = now, .complete = taken == sent }) catch {};
        }
        return taken;
    }

    /// Anti-entropy for membership: vouches for every member to a sample of
    /// known peers, so a device that joined through another member learns
    /// the rest of the swarm even when nobody dials it.
    pub fn sweepAdmissions(self: *Node, sample: usize) !usize {
        const trust = self.trust_store orelse return 0;
        if (trust.count() == 0 or self.device_identity == null) return 0;
        self.mutex.lock();
        const maybe_peers = self.routing_table.getClosestPeers(self.manager.node_id, sample) catch |err| {
            self.mutex.unlock();
            return err;
        };
        self.mutex.unlock();
        const peers = maybe_peers;
        defer self.allocator.free(peers);
        var reached: usize = 0;
        for (peers) |peer| {
            const conn = self.manager.connectToPeerMulti(peer.addresses[0..peer.addrs_count], self.swarm_key, peer.id) catch continue;
            defer conn.deinit();
            if ((self.pushAdmissions(conn) catch 0) > 0) reached += 1;
        }
        return reached;
    }

    /// Anti-entropy for revocations: connects to a sample of known peers
    /// and replays every tombstone we hold, so peers that never dialed us
    /// still learn which devices were removed. Returns how many peers
    /// accepted at least one revocation.
    pub fn sweepRevocations(self: *Node, sample: usize) !usize {
        const trust = self.trust_store orelse return 0;
        const tombstones = try trust.copyRevocations(self.allocator);
        defer self.allocator.free(tombstones);
        if (tombstones.len == 0 or self.device_identity == null) return 0;

        self.mutex.lock();
        const maybe_peers = self.routing_table.getClosestPeers(self.manager.node_id, sample) catch |err| {
            self.mutex.unlock();
            return err;
        };
        self.mutex.unlock();
        const peers = maybe_peers;
        defer self.allocator.free(peers);

        var accepted: usize = 0;
        for (peers) |peer| {
            const conn = self.manager.connectToPeerMulti(
                peer.addresses[0..peer.addrs_count],
                self.swarm_key,
                peer.id,
            ) catch |err| {
                std.debug.print("Revocation sweep: {x} unreachable: {any}\n", .{ peer.id.bytes[0..4], err });
                continue;
            };
            defer conn.deinit();

            var any_honored = false;
            for (tombstones) |r| {
                const ok = self.sendRevokeAt(conn, r.device_id, r.at) catch |err| {
                    std.debug.print("Revocation sweep: push to {x} failed: {any}\n", .{ peer.id.bytes[0..4], err });
                    continue;
                };
                if (ok) any_honored = true;
            }
            if (any_honored) accepted += 1;
        }
        return accepted;
    }

    // Returns either the value (allocated) or closer peers (allocated)
    pub const FindValueResult = union(enum) {
        value: []u8,
        closer_peers: []kbucket.PeerInfo,
    };

    pub fn sendFindValue(self: *Node, addresses: []const network.Address, key: id.NodeID, peer_id: ?id.NodeID, via: *?network.Address) !FindValueResult {
        via.* = null;
        const conn = try self.manager.connectToPeerMulti(addresses, self.swarm_key, peer_id);
        defer conn.deinit();
        via.* = matchingAddress(conn.getPeerAddress(), addresses);

        const stream = try conn.openStream();
        defer stream.close();
        stream.setTimeout(self.rpc_timeout_ms);

        const msg = rpc.Message{
            .sender_id = self.manager.node_id,
            .payload = .{ .FIND_VALUE = .{ .key = key } },
        };
        try msg.send(self.allocator, stream);

        const response = try rpc.Message.deserialize(self.allocator, stream.reader());
        defer response.deinit(self.allocator);

        switch (response.payload) {
            .FIND_VALUE_RESPONSE => |p| {
                switch (p) {
                    .value => |v| {
                        return FindValueResult{ .value = try self.allocator.dupe(u8, v) };
                    },
                    .closer_peers => |peers| {
                        const peers_copy = try self.allocator.alloc(kbucket.PeerInfo, peers.len);
                        @memcpy(peers_copy, peers);
                        return FindValueResult{ .closer_peers = peers_copy };
                    },
                }
            },
            else => return error.InvalidResponse,
        }
    }

    const LookupCandidate = struct { peer: kbucket.PeerInfo, tried_known: bool };

    fn lookupCandidate(self: *Node, hearsay: kbucket.PeerInfo) LookupCandidate {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.routing_table.getPeer(hearsay.id)) |known| {
            var merged = known;
            // Do not replace known addresses while constructing the dial list.
            for (hearsay.addresses[0..hearsay.addrs_count]) |addr| {
                if (merged.addrs_count == kbucket.MAX_PEER_ADDRESSES) break;
                _ = merged.addAddressFrom(addr, .hearsay, hearsay.last_seen);
            }
            return .{ .peer = merged, .tried_known = known.addrs_count > 0 };
        }
        return .{ .peer = hearsay, .tried_known = false };
    }

    fn addVerifiedPeer(self: *Node, peer: kbucket.PeerInfo) void {
        if (peer.addrs_count == 0) return;
        var lru_to_ping: ?kbucket.PeerInfo = null;
        {
            self.mutex.lock();
            defer self.mutex.unlock();

            if (self.routing_table.addPeer(peer)) |added| {
                if (!added) {
                    lru_to_ping = self.routing_table.getLRU(peer.id);
                }
            } else |err| {
                std.debug.print("Failed to add verified peer to routing table: {any}\n", .{err});
            }
        }

        if (lru_to_ping) |lru| {
            self.pingLruAndEvict(lru);
        }
    }

    fn lookupNodeWorker(node: *Node, state: *lookup_mod.LookupState, peer: kbucket.PeerInfo, target: id.NodeID) void {
        // std.debug.print("Lookup: [{x}] Querying peer {x}\n", .{ target.bytes[0..4], peer.id.bytes[0..4] });

        const candidate = node.lookupCandidate(peer);
        var via: ?network.Address = null;
        if (node.sendFindNode(candidate.peer.addresses[0..candidate.peer.addrs_count], target, peer.id, &via)) |closer_peers| {
            // std.debug.print("Lookup: [{x}] Peer {x} replied with {d} peers\n", .{ target.bytes[0..4], peer.id.bytes[0..4], closer_peers.len });
            defer node.allocator.free(closer_peers);
            state.reportReply(peer.id, closer_peers) catch {};

            // We successfully contacted 'peer'. Update it in our routing table.
            var p_updates = kbucket.PeerInfo{ .id = peer.id, .last_seen = sync.timestamp() };
            if (via) |addr| _ = p_updates.addAddressFrom(addr, .observed, p_updates.last_seen);
            node.addVerifiedPeer(p_updates);

            // NOTE: We do NOT add closer_peers to the routing table anymore (Hearsay).
            // They will be added only if we query them and they reply.
        } else |_| {
            // std.debug.print("Lookup: [{x}] Failed to contact {x}: {any}. Removing from table.\n", .{ target.bytes[0..4], peer.id.bytes[0..4], err });
            state.reportFailure(peer.id);
            node.mutex.lock();
            defer node.mutex.unlock();
            if (candidate.tried_known) node.routing_table.markDisconnected(peer.id);
        }
    }

    pub fn lookup(self: *Node, target: id.NodeID) !void {
        const initial_peers = blk: {
            self.mutex.lock();
            defer self.mutex.unlock();
            break :blk try self.routing_table.getClosestPeers(target, kbucket.K);
        };
        defer self.allocator.free(initial_peers);

        var state = try lookup_mod.LookupState.init(self.allocator, target, initial_peers);
        defer state.deinit();

        while (!state.isFinished()) {
            const next_peers = try state.nextPeersToQuery();
            defer self.allocator.free(next_peers);

            if (next_peers.len == 0) {
                // Nothing to query right now.
                if (state.in_flight.count() > 0) {
                    sync.sleep(10 * std.time.ns_per_ms);
                    continue;
                }
                break;
            }

            self.runLookupRound(&state, next_peers, lookupNodeWorker, .{target});
        }
    }

    pub fn sendFindNode(self: *Node, addresses: []const network.Address, target: id.NodeID, peer_id: ?id.NodeID, via: *?network.Address) ![]kbucket.PeerInfo {
        via.* = null;
        const conn = try self.manager.connectToPeerMulti(addresses, self.swarm_key, peer_id);
        defer conn.deinit();
        via.* = matchingAddress(conn.getPeerAddress(), addresses);

        const stream = try conn.openStream();
        defer stream.close();
        stream.setTimeout(self.rpc_timeout_ms);

        const msg = rpc.Message{
            .sender_id = self.manager.node_id,
            .payload = .{ .FIND_NODE = .{ .target = target } },
        };
        try msg.send(self.allocator, stream);

        const response = try rpc.Message.deserialize(self.allocator, stream.reader());
        defer response.deinit(self.allocator);

        switch (response.payload) {
            .FIND_NODE_RESPONSE => |p| {
                const peers = try self.allocator.alloc(kbucket.PeerInfo, p.closer_peers.len);
                @memcpy(peers, p.closer_peers);
                return peers;
            },
            else => return error.InvalidResponse,
        }
    }

    pub fn refreshBuckets(self: *Node) !void {
        const now = sync.timestamp();
        var i: usize = 0;
        while (i < 256) : (i += 1) {
            if (self.stopping.load(.acquire) or !self.manager.running.load(.acquire)) return;
            var needs_refresh = false;
            {
                self.mutex.lock();
                const bucket = &self.routing_table.buckets[i];
                if (now - bucket.last_updated > 3600) {
                    needs_refresh = true;
                }
                self.mutex.unlock();
            }

            if (needs_refresh) {
                // std.debug.print("Refreshing bucket {d}...\n", .{i});
                const target = self.manager.node_id.randomIdInBucket(i);
                self.lookup(target) catch |err| {
                    std.debug.print("Error refreshing bucket {d}: {any}\n", .{ i, err });
                };
            }
        }
    }

    pub fn serve(self: *Node, conn: network.Connection) !void {
        _ = conn.getRemoteNodeID();

        while (true) {
            const stream = conn.acceptStream() catch |err| {
                // If the connection is closed, stop serving
                if (err == error.SessionClosed or err == error.EndOfStream or err == error.ConnectionResetByPeer) break;
                std.debug.print("Failed to accept stream: {any}\n", .{err});
                break;
            };

            // Handle stream in a new thread. The thread holds its own
            // connection reference so the stream outlives connection reaping.
            const handler = struct {
                fn run(n: *Node, s: network.Stream, c: network.Connection) void {
                    defer n.finishHandler();
                    defer c.deinit();
                    s.setTimeout(n.rpc_timeout_ms);
                    // A relay request takes the stream over.
                    const taken = n.handleRequest(s, c) catch |h_err| blk: {
                        std.debug.print("Error handling DHT request: {any}\n", .{h_err});
                        break :blk false;
                    };
                    if (!taken) s.close();
                }
            };
            if (!self.startHandler()) {
                stream.close();
                continue;
            }
            conn.retain();
            const thread = std.Thread.spawn(.{}, handler.run, .{ self, stream, conn }) catch |err| {
                std.debug.print("Failed to spawn DHT request handler: {any}\n", .{err});
                self.finishHandler();
                conn.deinit();
                stream.close();
                continue;
            };
            thread.detach();
        }
        std.debug.print("DHT Serve loop exiting. (Public: {any})\n", .{self.is_public.load(.acquire)});
    }

    /// Answers one request. Returns whether the stream was taken over (a
    /// relay request); otherwise the caller closes it.
    fn handleRequest(self: *Node, stream: network.Stream, conn: network.Connection) !bool {
        const msg = try rpc.Message.deserialize(self.allocator, stream.reader());
        defer msg.deinit(self.allocator);

        // NOTE: We do NOT add the peer here anymore. We wait for PING to get the correct port.

        switch (msg.payload) {
            .PING => |p| try self.handlePing(stream, conn, msg.sender_id, p.port, p.roles, p.announced.slice()),
            .FIND_NODE => |p| try self.respondCloserPeers(stream, p.target, .find_node),
            .FIND_VALUE => |p| try self.handleFindValue(stream, p.key),
            .STORE => |p| try self.handleStore(stream, p.key, p.value),
            .GET_BLOCK => |p| try self.handleGetBlock(stream, p.cid),
            .GET_SHARES => try self.handleGetShares(stream),
            .GET_SWARM => try self.handleGetSwarm(stream),
            .GET_NODE_INFO => try self.handleGetNodeInfo(stream, conn),
            .ROTATE_KEY => |p| try self.handleRotateKey(stream, conn, p.epoch, p.new_key, p.signer_key, p.signature),
            .PUT_BLOCK => |p| try self.handlePutBlock(stream, conn, p.cid, p.data),
            .REVOKE => |p| try self.handleRevoke(stream, p.device_id, p.signer_key, p.at, p.signature),
            .ADMIT => |p| try self.handleAdmit(stream, p),
            .ADD_PROVIDER => |p| try self.handleAddProvider(stream, conn, p.key),
            .GET_PROVIDERS => |p| try self.handleGetProviders(stream, p.key),
            .DIAL_BACK => |p| try self.handleDialBack(conn, p.port),
            .RELAY_CONNECT => |p| {
                self.handleRelayConnect(stream, conn, p.target);
                return true;
            },
            .RELAY_INCOMING => |p| return self.handleRelayIncoming(stream, conn, p.from),
            else => {
                std.debug.print("Received unhandled DHT message type: {any}\n", .{msg.payload});
            },
        }
        return false;
    }

    // ---- Relaying (transport/relay.zig) ----

    /// Streams one node pipes at once.
    pub const max_relays = 32;
    /// After no relay reached a device (usually: it's off), dials to it
    /// don't ask relays again for this long.
    const relay_retry_ms: i64 = 60_000;
    /// Bound on a relay setting a connection up (it may dial the target).
    const relay_setup_timeout_ms: u32 = 15_000;

    /// Lets the connection manager reach devices through others when none
    /// of their addresses answers. Call once the node has its final address.
    pub fn enableRelay(self: *Node) void {
        self.manager.relay_dialer = .{ .ctx = self, .dialFn = dialThroughRelayErased };
    }

    fn dialThroughRelayErased(ctx: *anyopaque, target: id.NodeID) anyerror!network.Connection {
        const self: *Node = @ptrCast(@alignCast(ctx));
        return self.dialThroughRelay(target);
    }

    /// Asks each device this one is connected to to pipe a stream to
    /// `target`, and runs the connection over the first that does.
    /// Returns a reference the caller must deinit().
    pub fn dialThroughRelay(self: *Node, target: id.NodeID) !network.Connection {
        {
            self.mutex.lock();
            defer self.mutex.unlock();
            pruneRecent(&self.relay_misses, sync.monotonicMillis());
            if (self.relay_misses.get(target)) |until| {
                if (sync.monotonicMillis() < until) return error.NoRelay;
            }
        }
        const conn = self.dialThroughRelayOnce(target) catch |err| {
            self.mutex.lock();
            defer self.mutex.unlock();
            const now = sync.monotonicMillis();
            pruneRecent(&self.relay_misses, now);
            if (self.relay_misses.count() < max_recent_peers) {
                self.relay_misses.put(self.allocator, target, now + relay_retry_ms) catch {};
            }
            return err;
        };
        self.mutex.lock();
        defer self.mutex.unlock();
        _ = self.relay_misses.remove(target);
        return conn;
    }

    fn dialThroughRelayOnce(self: *Node, target: id.NodeID) !network.Connection {
        const conns = try self.manager.liveConnections(self.allocator);
        defer {
            for (conns) |c| c.deinit();
            self.allocator.free(conns);
        }
        for (conns) |via| {
            if (via.getRemoteNodeID().eql(target)) continue;
            if (via.getPeerAddress().isUnspecified()) continue; // relays don't chain
            const stream = via.openStream() catch continue;
            if (!self.requestRelay(stream, target)) {
                stream.close();
                continue;
            }
            via.retain();
            const conn = relay.establish(self.allocator, stream, via, self.swarm_key, self.manager.identity_key, true, self.manager.handshake_timeout_ms, self.manager.deviceAuthPtr()) catch |err| {
                std.debug.print("relay: handshake with {x} through {x} failed: {any}\n", .{ target.bytes[0..4], via.getRemoteNodeID().bytes[0..4], err });
                continue;
            };
            if (!conn.getRemoteNodeID().eql(target)) {
                conn.deinit();
                continue;
            }
            std.debug.print("relay: reached {x} through {x}\n", .{ target.bytes[0..4], via.getRemoteNodeID().bytes[0..4] });
            // One reference for the manager, one for the caller.
            conn.retain();
            self.manager.addConnection(conn) catch conn.deinit();
            return conn;
        }
        return error.NoRelay;
    }

    /// RELAY_CONNECT on `stream`; true when the relay answered ok.
    fn requestRelay(self: *Node, stream: network.Stream, target: id.NodeID) bool {
        stream.setTimeout(relay_setup_timeout_ms);
        const msg = rpc.Message{ .sender_id = self.manager.node_id, .payload = .{ .RELAY_CONNECT = .{ .target = target } } };
        msg.send(self.allocator, stream) catch return false;
        // Older nodes don't know RELAY_CONNECT: they close the stream.
        const reply = rpc.Message.deserialize(self.allocator, stream.reader()) catch return false;
        defer reply.deinit(self.allocator);
        return reply.payload == .RELAY_ACK and reply.payload.RELAY_ACK.ok;
    }

    fn sendRelayAck(self: *Node, stream: network.Stream, ok: bool) !void {
        const msg = rpc.Message{ .sender_id = self.manager.node_id, .payload = .{ .RELAY_ACK = .{ .ok = ok } } };
        try msg.send(self.allocator, stream);
    }

    /// RELAY_CONNECT from `conn`'s device: pipes `stream` to `target` until
    /// either end closes. Takes ownership of `stream`. Only devices of the
    /// swarm can ask (the connection is authenticated), and the target is
    /// reached directly, never through another relay.
    fn handleRelayConnect(self: *Node, stream: network.Stream, conn: network.Connection, target: id.NodeID) void {
        const from = conn.getRemoteNodeID();
        const out = self.openRelayStream(from, target) orelse {
            self.sendRelayAck(stream, false) catch {};
            stream.close();
            return;
        };
        defer _ = self.active_relays.fetchSub(1, .acq_rel);
        defer out.via.deinit();
        self.sendRelayAck(stream, true) catch {
            stream.close();
            out.stream.close();
            return;
        };
        std.debug.print("relay: piping {x} to {x}\n", .{ from.bytes[0..4], target.bytes[0..4] });
        relay.splice(stream, out.stream);
        std.debug.print("relay: {x} to {x} closed\n", .{ from.bytes[0..4], target.bytes[0..4] });
    }

    const RelayOut = struct { stream: network.Stream, via: network.Connection };

    /// A stream to `target` that it accepted for `from` (RELAY_INCOMING),
    /// counted in active_relays; null if it can't be had.
    fn openRelayStream(self: *Node, from: id.NodeID, target: id.NodeID) ?RelayOut {
        if (target.eql(self.manager.node_id) or target.eql(from)) return null;
        if (self.active_relays.fetchAdd(1, .acq_rel) >= max_relays) {
            _ = self.active_relays.fetchSub(1, .acq_rel);
            return null;
        }
        var counted = true;
        defer if (counted) {
            _ = self.active_relays.fetchSub(1, .acq_rel);
        };

        const via = self.manager.existingConnection(target) orelse blk: {
            const peer = peer: {
                self.mutex.lock();
                defer self.mutex.unlock();
                break :peer self.routing_table.getPeer(target);
            } orelse return null;
            break :blk self.manager.connectDirect(peer.addresses[0..peer.addrs_count], self.swarm_key, target) catch return null;
        };
        if (via.getPeerAddress().isUnspecified()) {
            via.deinit(); // relayed itself: relays don't chain
            return null;
        }
        const stream = via.openStream() catch {
            via.deinit();
            return null;
        };
        stream.setTimeout(relay_setup_timeout_ms);
        const ok = blk: {
            const msg = rpc.Message{ .sender_id = self.manager.node_id, .payload = .{ .RELAY_INCOMING = .{ .from = from } } };
            msg.send(self.allocator, stream) catch break :blk false;
            const reply = rpc.Message.deserialize(self.allocator, stream.reader()) catch break :blk false;
            defer reply.deinit(self.allocator);
            break :blk reply.payload == .RELAY_ACK and reply.payload.RELAY_ACK.ok;
        };
        if (!ok) {
            stream.close();
            via.deinit();
            return null;
        }
        counted = false;
        return .{ .stream = stream, .via = via };
    }

    /// RELAY_INCOMING: `from` connects to this node through `conn`'s
    /// device over `stream`. Returns whether the stream was taken.
    fn handleRelayIncoming(self: *Node, stream: network.Stream, conn: network.Connection, from: id.NodeID) bool {
        self.sendRelayAck(stream, true) catch return false;
        conn.retain();
        const relayed = relay.establish(self.allocator, stream, conn, self.swarm_key, self.manager.identity_key, false, self.manager.handshake_timeout_ms, self.manager.deviceAuthPtr()) catch |err| {
            std.debug.print("relay: handshake with {x} failed: {any}\n", .{ from.bytes[0..4], err });
            return true;
        };
        if (!relayed.getRemoteNodeID().eql(from)) {
            relayed.deinit();
            return true;
        }
        std.debug.print("relay: {x} connected through {x}\n", .{ from.bytes[0..4], conn.getRemoteNodeID().bytes[0..4] });
        self.manager.addConnection(relayed) catch relayed.deinit();
        return true;
    }

    fn handlePing(self: *Node, stream: network.Stream, conn: network.Connection, claimed_id: id.NodeID, port: u16, roles: u8, announced_addrs: []const network.Address) !void {
        // The handshake authenticated the connection; a PING may not claim
        // another node's identity (or ours) to plant it in the routing table.
        const sender_id = conn.getRemoteNodeID();
        if (!claimed_id.eql(sender_id)) return error.PeerIdMismatch;
        self.recordPeerRoles(sender_id, roles);

        // If we receive an INCOMING ping, it means we are reachable!
        self.is_public.store(true, .release);

        // Construct correct address from socket IP + Payload Port
        var address = conn.getPeerAddress();
        const relayed = address.isUnspecified();
        std.debug.print("Received PING from {x}. Address from sock: {f}, Port from payload: {d}\n", .{ sender_id.bytes[0..4], address, port });
        if (port != 0) address.setPort(port);

        // Add to routing table with CORRECT port
        var info = kbucket.PeerInfo{
            .id = sender_id,
            .last_seen = sync.timestamp(),
        };
        // Through a relay the socket says nothing about the sender.
        if (!relayed and local_addrs.classify(address) != .invalid) _ = info.addAddressFrom(address, .observed, info.last_seen);
        // And every other way it says it can be reached (Tailscale, ...).
        for (announced_addrs) |addr| {
            if (acceptAnnounced(addr, conn.getPeerAddress())) _ = info.addAddressFrom(addr, .announced, info.last_seen);
        }
        self.addVerifiedPeer(info);
        std.debug.print("Added peer {f} ({d} addresses) to routing table.\n", .{ address, info.addrs_count });

        const response = rpc.Message{
            .sender_id = self.manager.node_id,
            .payload = .{ .PONG = .{ .port = self.manager.bound_port, .announced = self.announced(), .roles = self.announcedRoles() } },
        };
        try response.send(self.allocator, stream);
    }

    /// Replies with the K closest known peers to `target`.
    fn respondCloserPeers(self: *Node, stream: network.Stream, target: id.NodeID, kind: enum { find_node, find_value }) !void {
        const closer = blk: {
            self.mutex.lock();
            defer self.mutex.unlock();
            break :blk try self.routing_table.getClosestPeers(target, kbucket.K);
        };
        defer self.allocator.free(closer);

        const response = rpc.Message{
            .sender_id = self.manager.node_id,
            .payload = switch (kind) {
                .find_node => .{ .FIND_NODE_RESPONSE = .{ .closer_peers = closer } },
                .find_value => .{ .FIND_VALUE_RESPONSE = .{ .closer_peers = closer } },
            },
        };
        try response.send(self.allocator, stream);
    }

    fn handleStore(self: *Node, stream: network.Stream, key: id.NodeID, value: []const u8) !void {
        var stored = true;
        self.localStore(key, value) catch |err| {
            std.debug.print("STORE rejected: {any}\n", .{err});
            stored = false;
        };
        const response = rpc.Message{
            .sender_id = self.manager.node_id,
            .payload = .{ .STORE_ACK = .{ .stored = stored } },
        };
        try response.send(self.allocator, stream);
    }

    fn handleAddProvider(self: *Node, stream: network.Stream, conn: network.Connection, key: id.NodeID) !void {
        const provider = conn.getRemoteNodeID();
        var stored = true;
        {
            self.mutex.lock();
            defer self.mutex.unlock();
            self.providers.add(self.allocator, key, provider, sync.timestamp()) catch |err| {
                std.debug.print("ADD_PROVIDER rejected: {any}\n", .{err});
                stored = false;
            };
        }
        const response = rpc.Message{
            .sender_id = self.manager.node_id,
            .payload = .{ .STORE_ACK = .{ .stored = stored } },
        };
        try response.send(self.allocator, stream);
    }

    fn handleGetProviders(self: *Node, stream: network.Stream, key: id.NodeID) !void {
        var buf: [providers_mod.max_per_key]id.NodeID = undefined;
        const list = blk: {
            self.mutex.lock();
            defer self.mutex.unlock();
            break :blk self.providers.get(key, sync.timestamp(), &buf);
        };
        const response = rpc.Message{
            .sender_id = self.manager.node_id,
            .payload = .{ .PROVIDERS = .{ .providers = list } },
        };
        try response.send(self.allocator, stream);
    }

    fn handleGetBlock(self: *Node, stream: network.Stream, cid: [32]u8) !void {
        var data: ?[]const u8 = null;
        defer if (data) |d| self.allocator.free(d);
        if (self.block_store) |block_store| {
            if (try block_store.get(&cid, self.allocator)) |block| data = block.data;
        }
        const response = rpc.Message{
            .sender_id = self.manager.node_id,
            .payload = .{ .BLOCK = .{ .data = data } },
        };
        try response.send(self.allocator, stream);
    }

    /// GET_NODE_INFO: only devices this one trusts learn about it; others
    /// get an empty reply.
    fn handleGetNodeInfo(self: *Node, stream: network.Stream, conn: network.Connection) !void {
        const trusted = blk: {
            const trust = self.trust_store orelse break :blk false;
            const device = conn.getRemoteDeviceID() orelse break :blk false;
            break :blk trust.isTrusted(device);
        };
        const info: []u8 = if (trusted) (if (self.info_source) |source| source.infoFn(source.ctx, self.allocator) catch |err| blk: {
            std.debug.print("NODE_INFO: unavailable: {any}\n", .{err});
            break :blk &.{};
        } else &.{}) else &.{};
        defer self.allocator.free(info);
        const response = rpc.Message{ .sender_id = self.manager.node_id, .payload = .{ .NODE_INFO = .{ .info = info } } };
        try response.send(self.allocator, stream);
    }

    /// Asks `conn`'s device about itself; caller-owned encoded info
    /// (node_info.decode). error.NotTrusted when it doesn't trust this one.
    pub fn fetchNodeInfo(self: *Node, conn: network.Connection, allocator: std.mem.Allocator) ![]u8 {
        const stream = try conn.openStream();
        defer stream.close();
        stream.setTimeout(self.rpc_timeout_ms);
        const msg = rpc.Message{ .sender_id = self.manager.node_id, .payload = .{ .GET_NODE_INFO = {} } };
        try msg.send(self.allocator, stream);
        const response = try rpc.Message.deserialize(self.allocator, stream.reader());
        defer response.deinit(self.allocator);
        switch (response.payload) {
            .NODE_INFO => |p| {
                if (p.info.len == 0) return error.NotTrusted;
                return allocator.dupe(u8, p.info);
            },
            else => return error.InvalidResponse,
        }
    }

    fn handleGetShares(self: *Node, stream: network.Stream) !void {
        const empty_listing = [_]u8{ 2, 0, 0 }; // dir block, zero entries
        const listing: []u8 = if (self.share_source) |source|
            try source.listFn(source.ctx, self.allocator)
        else
            try self.allocator.dupe(u8, &empty_listing);
        defer self.allocator.free(listing);
        // The backup field is extra: failing to build it must not hide the shares.
        const backup: []u8 = if (self.share_source) |source| (if (source.backupFn) |f| f(source.ctx, self.allocator) catch |err| blk: {
            std.debug.print("SHARES: backup info unavailable: {any}\n", .{err});
            break :blk &.{};
        } else &.{}) else &.{};
        defer self.allocator.free(backup);
        const response = rpc.Message{
            .sender_id = self.manager.node_id,
            .payload = .{ .SHARES = .{ .nickname = self.nickname, .listing = listing, .backup = backup } },
        };
        try response.send(self.allocator, stream);
    }

    pub fn setSwarmEpoch(self: *Node, epoch: u64) void {
        self.rotation_mutex.lock();
        defer self.rotation_mutex.unlock();
        self.swarm_epoch = epoch;
    }

    fn handleRotateKey(self: *Node, stream: network.Stream, conn: network.Connection, epoch: u64, new_key: [32]u8, signer_key: [32]u8, signature: [64]u8) !void {
        const accepted = self.applyRotation(conn.getRemoteDeviceID(), epoch, new_key, signer_key, signature);
        const response = rpc.Message{ .sender_id = self.manager.node_id, .payload = .{ .STORE_ACK = .{ .stored = accepted } } };
        try response.send(self.allocator, stream);
    }

    fn applyRotation(self: *Node, peer_device: ?id.NodeID, epoch: u64, new_key: [32]u8, signer_key: [32]u8, signature: [64]u8) bool {
        self.rotation_mutex.lock();
        defer self.rotation_mutex.unlock();
        if (epoch == std.math.maxInt(u64)) return false;
        const trust = self.trust_store orelse return false;
        const sink = self.rotation_sink orelse return false;
        device_rotation.verify(trust, peer_device, signer_key, signature, epoch, new_key, self.swarm_epoch) catch |err| {
            std.debug.print("Refused a swarm key rotation: {any}\n", .{err});
            return false;
        };
        self.swarm_epoch = epoch;
        sink.applyFn(sink.ctx, new_key, epoch);
        return true;
    }

    fn handleGetSwarm(self: *Node, stream: network.Stream) !void {
        const manifest: []u8 = if (self.swarm_source) |source|
            try source.listFn(source.ctx, self.allocator)
        else
            try self.allocator.dupe(u8, "[]");
        defer self.allocator.free(manifest);
        const response = rpc.Message{ .sender_id = self.manager.node_id, .payload = .{ .SWARM = .{ .manifest = manifest } } };
        try response.send(self.allocator, stream);
    }

    /// PUT_BLOCK: verify the bytes against their CID, then keep the block.
    /// A node with no block storage acknowledges nothing, so the sender does
    /// not count it as a replica.
    fn handlePutBlock(self: *Node, stream: network.Stream, conn: network.Connection, cid: [32]u8, data: []const u8) !void {
        var stored = false;
        _ = conn;
        if (canPutBlock(data.len)) if (self.block_store) |block_store| {
            // put() rejects bytes that do not hash to `cid`.
            if (block_store.put(.{ .cid = cid, .data = data })) {
                stored = true;
            } else |err| {
                std.debug.print("PUT_BLOCK rejected: {any}\n", .{err});
            }
        };
        const response = rpc.Message{
            .sender_id = self.manager.node_id,
            .payload = .{ .STORE_ACK = .{ .stored = stored } },
        };
        try response.send(self.allocator, stream);
    }

    /// Admission to the swarm is the write authorization: under the default
    /// policy any swarm-key holder may push replicas (learning/security/model.md),
    /// and under `require_trusted_devices` the handshake already refused untrusted
    /// devices. What is bounded here is the size: no valid encoded block (a leaf
    /// is a chunk plus its tag byte, a dir block is capped by the codec) is larger.
    /// The CID check, the handler cap and the storage quota bound the rest.
    fn canPutBlock(len: usize) bool {
        return len <= max_put_block_len;
    }

    const max_put_block_len = @max((chunker.Params{}).max_size + 1, codec.max_dir_block_len);

    /// REVOKE: only honored when the signature verifies, the signer is not
    /// the revoked device, and the signer's Ed25519 identity is in this
    /// node's own trust store. Everything else is refused, never applied.
    fn handleRevoke(
        self: *Node,
        stream: network.Stream,
        device_id: id.NodeID,
        signer_key: [32]u8,
        at: u64,
        signature: [64]u8,
    ) !void {
        var honored = false;
        if (self.trust_store) |trust| {
            const now = std.math.cast(u64, sync.timestamp()) orelse return error.InvalidTimestamp;
            const outcome = device_trust.applyRevocation(trust, device_id, signer_key, at, signature, now) catch .rejected;
            honored = outcome != .rejected;
            if (outcome == .applied) {
                _ = self.manager.closePeer(device_id);
                // It stops being a holder too (cluster/holders.zig).
                if (self.revocation_sink) |sink| sink.revokedFn(sink.ctx, device_id);
            }
            // Accepted tombstones must survive a restart, or every re-dial
            // replays the whole revocation.
            if (outcome == .applied) trust.save() catch |err| {
                std.debug.print("Failed to persist accepted revocation: {any}\n", .{err});
            };
        }
        const response = rpc.Message{
            .sender_id = self.manager.node_id,
            .payload = .{ .STORE_ACK = .{ .stored = honored } },
        };
        try response.send(self.allocator, stream);
    }

    /// ADMIT: a member vouches for a device. Added when this node trusts
    /// the signer and doesn't know the device (device_trust.applyAdmission).
    fn handleAdmit(self: *Node, stream: network.Stream, admit: rpc.Admit) !void {
        var taken = false;
        if (self.trust_store) |trust| {
            const self_id = if (self.device_identity) |identity| identity.deviceId() else id.NodeID{ .bytes = [_]u8{0} ** 32 };
            const now = std.math.cast(u64, sync.timestamp()) orelse return error.InvalidTimestamp;
            const outcome = device_trust.applyAdmission(trust, admit.public_key, admit.transport_key, admit.labelSlice(), admit.at, admit.signer_key, admit.signature, self_id, now) catch .rejected;
            taken = outcome != .rejected;
            if (outcome == .applied) trust.save() catch |err| {
                std.debug.print("Failed to persist a new swarm member: {any}\n", .{err});
            };
        }
        const response = rpc.Message{ .sender_id = self.manager.node_id, .payload = .{ .STORE_ACK = .{ .stored = taken } } };
        try response.send(self.allocator, stream);
    }

    fn handleFindValue(self: *Node, stream: network.Stream, key: id.NodeID) !void {
        // Copy under the lock: the stored slice may be replaced concurrently.
        const val_opt: ?[]u8 = blk: {
            self.mutex.lock();
            defer self.mutex.unlock();
            const val = self.storage.get(key) orelse break :blk null;
            break :blk try self.allocator.dupe(u8, val);
        };

        const val = val_opt orelse return self.respondCloserPeers(stream, key, .find_value);
        defer self.allocator.free(val);

        const response = rpc.Message{
            .sender_id = self.manager.node_id,
            .payload = .{ .FIND_VALUE_RESPONSE = .{ .value = val } },
        };
        try response.send(self.allocator, stream);
    }

    fn handleDialBack(self: *Node, conn: network.Connection, port: u16) !void {
        // Dial back the authenticated peer, never an ID taken from the payload.
        const sender_id = conn.getRemoteNodeID();
        var address = conn.getPeerAddress();
        if (address.isUnspecified()) return; // relayed: nothing to dial
        address.setPort(port);
        std.debug.print("AutoNAT: Attempting dial-back to {f}\n", .{address});

        // Attempt to dial back. If it succeeds, the other peer knows they are public.
        const dial_back_conn = self.manager.connectToPeer(address, self.swarm_key, sender_id) catch |err| {
            std.debug.print("AutoNAT: Dial-back to {f} failed: {any}\n", .{ address, err });
            return;
        };
        defer dial_back_conn.deinit();

        std.debug.print("AutoNAT: Dial-back to {f} successful!\n", .{address});
        // Send PING over the NEW connection to confirm
        try self.ping(dial_back_conn);
    }
};

// Remove expired entries without allocating or invalidating a live iterator.
fn pruneRecent(map: *std.AutoHashMapUnmanaged(id.NodeID, i64), now: i64) void {
    var stale: [Node.max_recent_peers]id.NodeID = undefined;
    var count: usize = 0;
    var it = map.iterator();
    while (it.next()) |entry| {
        if (entry.value_ptr.* <= now) {
            stale[count] = entry.key_ptr.*;
            count += 1;
        }
    }
    for (stale[0..count]) |key| _ = map.remove(key);
}

test "localStore enforces value, byte and key limits" {
    const allocator = std.testing.allocator;
    var manager = network.manager.ConnectionManager.initExplicit(allocator, .tcp, network.noise.KeyPair.generate());
    defer manager.deinit();
    var node = Node.init(allocator, &manager, "k" ** 32);
    defer node.deinit();
    node.store_limits = .{ .max_value_len = 8, .max_total_bytes = 12, .max_keys = 2 };

    const k1 = id.NodeID{ .bytes = [_]u8{1} ** 32 };
    const k2 = id.NodeID{ .bytes = [_]u8{2} ** 32 };
    const k3 = id.NodeID{ .bytes = [_]u8{3} ** 32 };

    try std.testing.expectError(error.ValueTooLarge, node.localStore(k1, "123456789"));
    try node.localStore(k1, "12345678");
    try std.testing.expectError(error.StorageFull, node.localStore(k2, "12345"));
    try node.localStore(k2, "1234");
    // Replacing a value counts only the difference.
    try node.localStore(k1, "1234");
    try std.testing.expectEqual(@as(usize, 8), node.stored_bytes);
    try std.testing.expectError(error.StorageFull, node.localStore(k3, "1"));
}

test "handler admission is capped and drain permanently stops admission" {
    const allocator = std.testing.allocator;
    var manager = network.manager.ConnectionManager.initExplicit(allocator, .tcp, network.noise.KeyPair.generate());
    defer manager.deinit();
    var node = Node.init(allocator, &manager, "k" ** 32);
    defer node.deinit();
    for (0..Node.max_handlers) |_| try std.testing.expect(node.startHandler());
    try std.testing.expect(!node.startHandler());
    node.finishHandler();
    try std.testing.expect(node.startHandler());
    for (0..Node.max_handlers) |_| node.finishHandler();
    node.drainHandlers();
    node.drainHandlers();
    try std.testing.expect(!node.startHandler());
}

test "PUT_BLOCK accepts any valid encoded block size and nothing larger" {
    try std.testing.expect(Node.canPutBlock(1));
    try std.testing.expect(Node.canPutBlock((chunker.Params{}).max_size + 1));
    try std.testing.expect(Node.canPutBlock(codec.max_dir_block_len));
    try std.testing.expect(!Node.canPutBlock(Node.max_put_block_len + 1));
}

test "recent peer maps prune expired deadlines" {
    var map: std.AutoHashMapUnmanaged(id.NodeID, i64) = .empty;
    defer map.deinit(std.testing.allocator);
    const old = id.NodeID{ .bytes = [_]u8{1} ** 32 };
    const live = id.NodeID{ .bytes = [_]u8{2} ** 32 };
    try map.put(std.testing.allocator, old, 30);
    try map.put(std.testing.allocator, live, 31);
    pruneRecent(&map, 30);
    try std.testing.expect(!map.contains(old));
    try std.testing.expect(map.contains(live));
}

test "drain waits for an admitted handler and refuses concurrent admission" {
    const allocator = std.testing.allocator;
    var manager = network.manager.ConnectionManager.initExplicit(allocator, .tcp, network.noise.KeyPair.generate());
    defer manager.deinit();
    var node = Node.init(allocator, &manager, "k" ** 32);
    defer node.deinit();
    try std.testing.expect(node.startHandler());
    var finished: std.atomic.Value(bool) = .init(false);
    const Waiter = struct {
        fn run(n: *Node, done: *std.atomic.Value(bool)) void {
            n.drainHandlers();
            done.store(true, .release);
        }
    };
    const thread = try std.Thread.spawn(.{}, Waiter.run, .{ &node, &finished });
    while (!node.stopping.load(.acquire)) sync.sleep(std.time.ns_per_ms);
    const stopped_admission = !node.startHandler();
    const waited = !finished.load(.acquire);
    node.finishHandler();
    thread.join();
    try std.testing.expect(stopped_admission);
    try std.testing.expect(waited);
    try std.testing.expect(finished.load(.acquire));
}

test "concurrent rotations apply an epoch once and reject the maximum epoch" {
    const allocator = std.testing.allocator;
    var manager = network.manager.ConnectionManager.initExplicit(allocator, .tcp, network.noise.KeyPair.generate());
    defer manager.deinit();
    var node = Node.init(allocator, &manager, "k" ** 32);
    defer node.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const base = path_buf[0..try tmp.dir.realPath(std.testing.io, &path_buf)];
    const path = try std.fs.path.join(allocator, &.{ base, "trust" });
    defer allocator.free(path);
    const identity = try identity_mod.Identity.fromSeed([_]u8{3} ** 32);
    const peer = try identity_mod.Identity.fromSeed([_]u8{4} ** 32);
    var trust = try device_trust.Store.load(allocator, path, identity.seed());
    defer trust.deinit();
    _ = try trust.upsert(peer.publicKey(), [_]u8{9} ** 32, "peer", 1);
    node.trust_store = &trust;
    const Sink = struct {
        count: usize = 0,
        fn apply(ctx: *anyopaque, _: [32]u8, _: u64) void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.count += 1;
        }
        fn run(n: *Node, signer: identity_mod.Identity, sig: [64]u8) void {
            _ = n.applyRotation(signer.deviceId(), 5, [_]u8{7} ** 32, signer.publicKey(), sig);
        }
    };
    var sink = Sink{};
    node.rotation_sink = .{ .ctx = &sink, .applyFn = Sink.apply };
    const key = [_]u8{7} ** 32;
    const signature = try peer.sign(&device_rotation.message(5, key));
    const t1 = try std.Thread.spawn(.{}, Sink.run, .{ &node, peer, signature });
    const t2 = std.Thread.spawn(.{}, Sink.run, .{ &node, peer, signature }) catch |err| {
        t1.join();
        return err;
    };
    t1.join();
    t2.join();
    const count = sink.count;
    try std.testing.expectEqual(@as(usize, 1), count);
    const max_sig = try peer.sign(&device_rotation.message(std.math.maxInt(u64), key));
    try std.testing.expect(!node.applyRotation(peer.deviceId(), std.math.maxInt(u64), key, peer.publicKey(), max_sig));
}

/// Only a socket equal to a dial candidate proves that candidate was used.
fn matchingAddress(sock: network.Address, candidates: []const network.Address) ?network.Address {
    if (local_addrs.classify(sock) == .invalid) return null;
    for (candidates) |addr| if (addr.eql(sock)) return sock;
    return null;
}

fn acceptAnnounced(addr: network.Address, sock: network.Address) bool {
    const scope = local_addrs.classify(addr);
    const socket_scope = local_addrs.classify(sock);
    return acceptAnnouncedScope(scope, socket_scope, if (scope == .private) local_addrs.onLink(addr) else false, if (scope == .cgnat) local_addrs.haveCgnat() else false);
}

fn acceptAnnouncedScope(scope: local_addrs.Scope, socket: local_addrs.Scope, on_link: bool, have_cgnat: bool) bool {
    return switch (scope) {
        .invalid => false,
        .loopback => socket == .loopback,
        .private => socket == .loopback or socket == .private or socket == .cgnat or on_link,
        .cgnat => socket == .cgnat or have_cgnat,
        .public => true,
    };
}

test "announced scopes respect the authenticated socket and local networks" {
    try std.testing.expect(!acceptAnnouncedScope(.private, .public, false, false));
    try std.testing.expect(acceptAnnouncedScope(.private, .public, true, false));
    try std.testing.expect(acceptAnnouncedScope(.private, .private, false, false));
    try std.testing.expect(acceptAnnouncedScope(.loopback, .loopback, false, false));
    try std.testing.expect(!acceptAnnouncedScope(.loopback, .public, false, false));
    try std.testing.expect(!acceptAnnouncedScope(.cgnat, .public, false, false));
    try std.testing.expect(acceptAnnouncedScope(.cgnat, .public, false, true));
    try std.testing.expect(!acceptAnnouncedScope(.invalid, .loopback, true, true));
}

test "lookup candidate socket matching rejects inbound pooled and relay addresses" {
    const addr = network.Address.initIp4(.{ 127, 0, 0, 1 }, 13500);
    try std.testing.expect(matchingAddress(addr, &.{addr}) != null);
    try std.testing.expect(matchingAddress(network.Address.initIp4(.{ 127, 0, 0, 1 }, 55555), &.{addr}) == null);
    try std.testing.expect(matchingAddress(network.Address.initIp4(.{ 0, 0, 0, 0 }, 0), &.{addr}) == null);
}

test "lookup prioritizes known addresses and confines hearsay-only failure" {
    const allocator = std.testing.allocator;
    var manager = network.manager.ConnectionManager.initExplicit(allocator, .tcp, network.noise.KeyPair.generate());
    defer manager.deinit();
    var node = Node.init(allocator, &manager, "k" ** 32);
    defer node.deinit();
    var peer = kbucket.PeerInfo{ .id = .{ .bytes = [_]u8{9} ** 32 }, .last_seen = 1 };
    const real = network.Address.initIp4(.{ 127, 0, 0, 1 }, 13505);
    _ = peer.addAddress(real);
    _ = try node.routing_table.addPeer(peer);
    var hearsay = kbucket.PeerInfo{ .id = peer.id, .last_seen = 2 };
    _ = hearsay.addAddressFrom(network.Address.initIp4(.{ 192, 0, 2, 1 }, 9), .hearsay, 2);
    const candidate = node.lookupCandidate(hearsay);
    try std.testing.expect(candidate.tried_known);
    try std.testing.expect(candidate.peer.addresses[0].eql(real));
    hearsay.id = .{ .bytes = [_]u8{10} ** 32 };
    const hearsay_only = node.lookupCandidate(hearsay);
    try std.testing.expect(!hearsay_only.tried_known);
    try std.testing.expectEqual(@as(u8, 1), hearsay_only.peer.addrs_count);
    var state = try lookup_mod.LookupState.init(allocator, hearsay.id, &.{hearsay});
    defer state.deinit();
    node.rpc_timeout_ms = 20;
    // Empty addresses fail immediately; the actual worker must preserve known peers.
    hearsay.addrs_count = 0;
    Node.lookupNodeWorker(&node, &state, hearsay, hearsay.id);
    try std.testing.expect(node.routing_table.contains(peer.id));
}
