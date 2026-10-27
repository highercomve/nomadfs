const sync = @import("../../sync.zig");
const std = @import("std");
const id = @import("../id.zig");
const kbucket = @import("kbucket.zig");
const rpc = @import("rpc.zig");
const network = @import("../transport/mod.zig");
const lookup_mod = @import("lookup.zig");
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
    /// Answers GET_SWARM with the swarm folder's manifest. Null: an empty
    /// manifest.
    swarm_source: ?ShareSource = null,
    /// Told about an accepted swarm key rotation (key, epoch). Without one
    /// the node refuses rotations.
    rotation_sink: ?RotationSink = null,
    /// This device's current key epoch (config node.swarm_epoch).
    swarm_epoch: u64 = 0,
    /// Human name sent with SHARES (config node.nickname).
    nickname: []const u8 = "",
    /// This node's Ed25519 identity, used to sign revocations it pushes.
    device_identity: ?identity_mod.Identity = null,
    store_limits: StoreLimits = .{},
    /// Sum of value lengths in `storage`. Guarded by `mutex`.
    stored_bytes: usize = 0,
    /// Who holds content for which key. Guarded by `mutex`.
    providers: providers_mod.ProviderStore = .{},

    /// Produces this node's share listing (an encoded dir block, owned by
    /// the caller) on demand. Type-erased so the DHT does not depend on the
    /// filesystem layer that implements it.
    pub const ShareSource = struct {
        ctx: *anyopaque,
        listFn: *const fn (ctx: *anyopaque, allocator: std.mem.Allocator) anyerror![]u8,
    };

    pub const RotationSink = struct {
        ctx: *anyopaque,
        /// Persist and adopt the new key (restarting the node). Called
        /// from a request thread after the rotation was verified.
        applyFn: *const fn (ctx: *anyopaque, new_key: [32]u8, epoch: u64) void,
    };

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
        const known = blk: {
            self.mutex.lock();
            defer self.mutex.unlock();
            break :blk self.routing_table.contains(peer_id);
        };
        if (known) return;

        const conn = self.manager.connectToPeer(addr, self.swarm_key, peer_id) catch return;
        defer conn.deinit();
        self.ping(conn) catch {};
    }

    fn pingLruAndEvict(self: *Node, lru: kbucket.PeerInfo) void {
        const addr = lru.getBestAddress();
        if (self.manager.connectToPeer(addr, self.swarm_key, lru.id)) |conn| {
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
        try msg.serialize(stream.writer());
        // We don't wait for a response on this stream.
        // We wait for an INCOMING connection on our listen port.
    }

    pub fn deinit(self: *Node) void {
        // Wait for all in-flight request handlers to finish.
        // They might be detached threads accessing 'self'.
        self.handlers_wg.wait();

        self.mutex.lock();
        defer self.mutex.unlock();
        self.routing_table.deinit();
        var it = self.storage.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.value_ptr.*);
        }
        self.storage.deinit(self.allocator);
        self.providers.deinit(self.allocator);
    }

    pub fn ping(self: *Node, conn: network.Connection) !void {
        const stream = try conn.openStream();
        defer stream.close();
        stream.setTimeout(self.rpc_timeout_ms);

        const msg = rpc.Message{
            .sender_id = self.manager.node_id,
            .payload = .{ .PING = .{ .port = self.manager.bound_port } },
        };

        try msg.serialize(stream.writer());

        // Wait for PONG
        const response = try rpc.Message.deserialize(self.allocator, stream.reader());
        defer response.deinit(self.allocator);
        if (response.payload != .PONG) return error.InvalidResponse;

        // Record the ID the handshake authenticated, not the claimed one.
        const peer_id = conn.getRemoteNodeID();
        if (!response.sender_id.eql(peer_id)) return error.PeerIdMismatch;

        self.mutex.lock();
        defer self.mutex.unlock();
        var info = kbucket.PeerInfo{
            .id = peer_id,
            .last_seen = sync.timestamp(),
        };
        _ = info.addAddress(conn.getPeerAddress());
        _ = try self.routing_table.addPeer(info);

        // Outbound connections are the natural propagation point: every
        // PONG we just verified is an authenticated peer that can now hear
        // which devices we stopped trusting.
        if (self.trust_store) |trust| {
            if (trust.revocationsSlice().len > 0) {
                _ = self.pushRevocations(conn) catch {};
            }
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
        try msg.serialize(stream.writer());

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
        try msg.serialize(stream.writer());

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
        const result_or_err = node.sendFindValue(peer.addresses[0..peer.addrs_count], target, peer.id);
        if (result_or_err) |result| {
            // Successful response, verify peer
            var p_updates = peer;
            p_updates.last_seen = sync.timestamp();
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
            node.routing_table.markDisconnected(peer.id);
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
        try msg.serialize(stream.writer());

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
        try msg.serialize(stream.writer());

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
        try msg.serialize(stream.writer());

        const response = try rpc.Message.deserialize(self.allocator, stream.reader());
        switch (response.payload) {
            .SHARES => |p| return .{ .nickname = @constCast(p.nickname), .listing = @constCast(p.listing) },
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
        try msg.serialize(stream.writer());
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
        try msg.serialize(stream.writer());
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
        try msg.serialize(stream.writer());

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
        const identity = self.device_identity orelse return error.NoDeviceIdentity;
        const signed = device_trust.revocationMessage(device_id, identity.deviceId());
        const stream = try conn.openStream();
        defer stream.close();
        stream.setTimeout(self.rpc_timeout_ms);

        const signature = try identity.sign(&signed);

        const msg = rpc.Message{
            .sender_id = self.manager.node_id,
            .payload = .{ .REVOKE = .{ .device_id = device_id, .signer_key = identity.publicKey(), .at = @intCast(sync.timestamp()), .signature = signature } },
        };
        try msg.serialize(stream.writer());

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
        const tombstones = trust.revocationsSlice();

        var honored: usize = 0;
        for (tombstones) |r| {
            const ok = self.sendRevoke(conn, r.device_id) catch |err| {
                std.debug.print("Failed to push revocation of {x}: {any}\n", .{ r.device_id.bytes[0..4], err });
                continue;
            };
            if (ok) honored += 1;
        }
        return honored;
    }

    /// Anti-entropy for revocations: connects to a sample of known peers
    /// and replays every tombstone we hold, so peers that never dialed us
    /// still learn which devices were removed. Returns how many peers
    /// accepted at least one revocation.
    pub fn sweepRevocations(self: *Node, sample: usize) !usize {
        const trust = self.trust_store orelse return 0;
        const ids = try trust.copyRevocationIds(self.allocator);
        defer self.allocator.free(ids);
        if (ids.len == 0 or self.device_identity == null) return 0;

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
            for (ids) |device_id| {
                const ok = self.sendRevoke(conn, device_id) catch |err| {
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

    pub fn sendFindValue(self: *Node, addresses: []const network.Address, key: id.NodeID, peer_id: ?id.NodeID) !FindValueResult {
        const conn = try self.manager.connectToPeerMulti(addresses, self.swarm_key, peer_id);
        defer conn.deinit();

        const stream = try conn.openStream();
        defer stream.close();
        stream.setTimeout(self.rpc_timeout_ms);

        const msg = rpc.Message{
            .sender_id = self.manager.node_id,
            .payload = .{ .FIND_VALUE = .{ .key = key } },
        };
        try msg.serialize(stream.writer());

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

    fn addVerifiedPeer(self: *Node, peer: kbucket.PeerInfo) void {
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

        if (node.sendFindNode(peer.addresses[0..peer.addrs_count], target, peer.id)) |closer_peers| {
            // std.debug.print("Lookup: [{x}] Peer {x} replied with {d} peers\n", .{ target.bytes[0..4], peer.id.bytes[0..4], closer_peers.len });
            defer node.allocator.free(closer_peers);
            state.reportReply(peer.id, closer_peers) catch {};

            // We successfully contacted 'peer'. Update it in our routing table.
            var p_updates = peer;
            p_updates.last_seen = sync.timestamp();
            node.addVerifiedPeer(p_updates);

            // NOTE: We do NOT add closer_peers to the routing table anymore (Hearsay).
            // They will be added only if we query them and they reply.
        } else |_| {
            // std.debug.print("Lookup: [{x}] Failed to contact {x}: {any}. Removing from table.\n", .{ target.bytes[0..4], peer.id.bytes[0..4], err });
            state.reportFailure(peer.id);
            node.mutex.lock();
            defer node.mutex.unlock();
            node.routing_table.markDisconnected(peer.id);
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

    pub fn sendFindNode(self: *Node, addresses: []const network.Address, target: id.NodeID, peer_id: ?id.NodeID) ![]kbucket.PeerInfo {
        const conn = try self.manager.connectToPeerMulti(addresses, self.swarm_key, peer_id);
        defer conn.deinit();

        const stream = try conn.openStream();
        defer stream.close();
        stream.setTimeout(self.rpc_timeout_ms);

        const msg = rpc.Message{
            .sender_id = self.manager.node_id,
            .payload = .{ .FIND_NODE = .{ .target = target } },
        };
        try msg.serialize(stream.writer());

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
                    defer n.handlers_wg.finish();
                    defer c.deinit();
                    defer s.close();
                    s.setTimeout(n.rpc_timeout_ms);
                    n.handleRequest(s, c) catch |h_err| {
                        std.debug.print("Error handling DHT request: {any}\n", .{h_err});
                    };
                }
            };
            conn.retain();
            self.handlers_wg.start();
            const thread = std.Thread.spawn(.{}, handler.run, .{ self, stream, conn }) catch |err| {
                std.debug.print("Failed to spawn DHT request handler: {any}\n", .{err});
                self.handlers_wg.finish();
                conn.deinit();
                stream.close();
                continue;
            };
            thread.detach();
        }
        std.debug.print("DHT Serve loop exiting. (Public: {any})\n", .{self.is_public.load(.acquire)});
    }

    fn handleRequest(self: *Node, stream: network.Stream, conn: network.Connection) !void {
        const msg = try rpc.Message.deserialize(self.allocator, stream.reader());
        defer msg.deinit(self.allocator);

        // NOTE: We do NOT add the peer here anymore. We wait for PING to get the correct port.

        switch (msg.payload) {
            .PING => |p| try self.handlePing(stream, conn, msg.sender_id, p.port),
            .FIND_NODE => |p| try self.respondCloserPeers(stream, p.target, .find_node),
            .FIND_VALUE => |p| try self.handleFindValue(stream, p.key),
            .STORE => |p| try self.handleStore(stream, p.key, p.value),
            .GET_BLOCK => |p| try self.handleGetBlock(stream, p.cid),
            .GET_SHARES => try self.handleGetShares(stream),
            .GET_SWARM => try self.handleGetSwarm(stream),
            .ROTATE_KEY => |p| try self.handleRotateKey(stream, conn, p.epoch, p.new_key, p.signer_key, p.signature),
            .PUT_BLOCK => |p| try self.handlePutBlock(stream, p.cid, p.data),
            .REVOKE => |p| try self.handleRevoke(stream, p.device_id, p.signer_key, p.signature),
            .ADD_PROVIDER => |p| try self.handleAddProvider(stream, conn, p.key),
            .GET_PROVIDERS => |p| try self.handleGetProviders(stream, p.key),
            .DIAL_BACK => |p| try self.handleDialBack(conn, p.port),
            else => {
                std.debug.print("Received unhandled DHT message type: {any}\n", .{msg.payload});
            },
        }
    }

    fn handlePing(self: *Node, stream: network.Stream, conn: network.Connection, claimed_id: id.NodeID, port: u16) !void {
        // The handshake authenticated the connection; a PING may not claim
        // another node's identity (or ours) to plant it in the routing table.
        const sender_id = conn.getRemoteNodeID();
        if (!claimed_id.eql(sender_id)) return error.PeerIdMismatch;

        // If we receive an INCOMING ping, it means we are reachable!
        self.is_public.store(true, .release);

        // Construct correct address from socket IP + Payload Port
        var address = conn.getPeerAddress();
        std.debug.print("Received PING from {x}. Address from sock: {f}, Port from payload: {d}\n", .{ sender_id.bytes[0..4], address, port });
        address.setPort(port);

        // Add to routing table with CORRECT port
        var info = kbucket.PeerInfo{
            .id = sender_id,
            .last_seen = sync.timestamp(),
        };
        _ = info.addAddress(address);
        self.addVerifiedPeer(info);
        std.debug.print("Added peer {f} to routing table.\n", .{address});

        const response = rpc.Message{
            .sender_id = self.manager.node_id,
            .payload = .{ .PONG = {} },
        };
        try response.serialize(stream.writer());
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
        try response.serialize(stream.writer());
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
        try response.serialize(stream.writer());
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
        try response.serialize(stream.writer());
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
        try response.serialize(stream.writer());
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
        try response.serialize(stream.writer());
    }

    fn handleGetShares(self: *Node, stream: network.Stream) !void {
        const empty_listing = [_]u8{ 2, 0, 0 }; // dir block, zero entries
        const listing: []u8 = if (self.share_source) |source|
            try source.listFn(source.ctx, self.allocator)
        else
            try self.allocator.dupe(u8, &empty_listing);
        defer self.allocator.free(listing);
        const response = rpc.Message{
            .sender_id = self.manager.node_id,
            .payload = .{ .SHARES = .{ .nickname = self.nickname, .listing = listing } },
        };
        try response.serialize(stream.writer());
    }

    fn handleRotateKey(self: *Node, stream: network.Stream, conn: network.Connection, epoch: u64, new_key: [32]u8, signer_key: [32]u8, signature: [64]u8) !void {
        var accepted = false;
        if (self.trust_store) |trust| if (self.rotation_sink) |sink| {
            if (device_rotation.verify(trust, conn.getRemoteDeviceID(), signer_key, signature, epoch, new_key, self.swarm_epoch)) {
                self.swarm_epoch = epoch;
                accepted = true;
                sink.applyFn(sink.ctx, new_key, epoch);
            } else |err| {
                std.debug.print("Refused a swarm key rotation: {any}\n", .{err});
            }
        };
        const response = rpc.Message{ .sender_id = self.manager.node_id, .payload = .{ .STORE_ACK = .{ .stored = accepted } } };
        try response.serialize(stream.writer());
    }

    fn handleGetSwarm(self: *Node, stream: network.Stream) !void {
        const manifest: []u8 = if (self.swarm_source) |source|
            try source.listFn(source.ctx, self.allocator)
        else
            try self.allocator.dupe(u8, "[]");
        defer self.allocator.free(manifest);
        const response = rpc.Message{ .sender_id = self.manager.node_id, .payload = .{ .SWARM = .{ .manifest = manifest } } };
        try response.serialize(stream.writer());
    }

    /// PUT_BLOCK: verify the bytes against their CID, then keep the block.
    /// A node with no block storage acknowledges nothing, so the sender does
    /// not count it as a replica.
    fn handlePutBlock(self: *Node, stream: network.Stream, cid: [32]u8, data: []const u8) !void {
        var stored = false;
        if (self.block_store) |block_store| {
            // put() rejects bytes that do not hash to `cid`.
            if (block_store.put(.{ .cid = cid, .data = data })) {
                stored = true;
            } else |err| {
                std.debug.print("PUT_BLOCK rejected: {any}\n", .{err});
            }
        }
        const response = rpc.Message{
            .sender_id = self.manager.node_id,
            .payload = .{ .STORE_ACK = .{ .stored = stored } },
        };
        try response.serialize(stream.writer());
    }

    /// REVOKE: only honored when the signature verifies, the signer is not
    /// the revoked device, and the signer's Ed25519 identity is in this
    /// node's own trust store. Everything else is refused, never applied.
    fn handleRevoke(
        self: *Node,
        stream: network.Stream,
        device_id: id.NodeID,
        signer_key: [32]u8,
        signature: [64]u8,
    ) !void {
        var honored = false;
        if (self.trust_store) |trust| {
            honored = device_trust.applyRevocation(trust, device_id, signer_key, signature, @intCast(sync.timestamp())) catch false;
            // Accepted tombstones must survive a restart, or every re-dial
            // replays the whole revocation.
            if (honored) trust.save() catch |err| {
                std.debug.print("Failed to persist accepted revocation: {any}\n", .{err});
            };
        }
        const response = rpc.Message{
            .sender_id = self.manager.node_id,
            .payload = .{ .STORE_ACK = .{ .stored = honored } },
        };
        try response.serialize(stream.writer());
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
        try response.serialize(stream.writer());
    }

    fn handleDialBack(self: *Node, conn: network.Connection, port: u16) !void {
        // Dial back the authenticated peer, never an ID taken from the payload.
        const sender_id = conn.getRemoteNodeID();
        var address = conn.getPeerAddress();
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

fn addressesMatch(a: network.Address, b: network.Address) bool {
    return a.eql(b);
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
