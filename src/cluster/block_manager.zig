const std = @import("std");
const network = @import("../net/transport/mod.zig");
const dht = @import("../net/discovery/mod.zig");
const NodeID = @import("../net/id.zig").NodeID;
const storage = @import("../storage/mod.zig");
const quorum = @import("quorum.zig");
const keeper_mod = @import("keeper.zig");
const fetcher_mod = @import("fetcher.zig");
const holders_mod = @import("holders.zig");
const walk = storage.dag.walk;

/// Owns the fetcher and the holder registry, and dials holders for them.
/// Also the mobile C API's file-level path: `put` stores a file locally and
/// announces this node as provider of its root CID; `get` copies the
/// missing blocks with the keeper's copy (several blocks at once, from every
/// holder) using the provider records and the peers closest to the CID as
/// holders. Nothing is pushed at put: devices that keep files pull them
/// (cluster/keeper.zig). Records expire after providers.default_ttl_s.
pub const BlockManager = struct {
    allocator: std.mem.Allocator,
    net: *network.manager.ConnectionManager,
    dht_node: *dht.Node,
    store: ?*storage.engine.StorageEngine, // Nullable for mobile
    quorum: quorum.QuorumConfig,
    layout: storage.dag.Layout = .Balanced,
    /// Where each block of a read comes from (fetcher.zig); null without a
    /// store.
    fetcher: ?fetcher_mod.Fetcher = null,
    /// Who probably holds what (holders.zig); null without a store, since
    /// only reads need it.
    holders: ?holders_mod.Holders = null,

    pub const Config = struct {
        network: *network.manager.ConnectionManager,
        dht: *dht.Node,
        storage: ?*storage.engine.StorageEngine,
        /// W = number of peers that must acknowledge a provider record.
        /// W = 0 keeps `put` local-only.
        quorum: quorum.QuorumConfig = .{},
    };

    pub fn init(allocator: std.mem.Allocator, config: Config) !*BlockManager {
        const self = try allocator.create(BlockManager);
        self.* = .{
            .allocator = allocator,
            .net = config.network,
            .dht_node = config.dht,
            .store = config.storage,
            .quorum = config.quorum,
        };
        if (config.storage) |s| {
            self.fetcher = fetcher_mod.Fetcher.init(s, .{ .ctx = self, .getFn = getBlockFrom, .connectedFn = isConnected });
            self.holders = .{
                .self_id = config.dht.manager.node_id,
                .peers = .{ .ctx = self, .rolesFn = rolesOfPeered, .knownFn = knownIDsOf, .connectedFn = connectedIDsOf, .withRoleFn = roleIDsOf, .knowsFn = knowsID },
            };
        }
        return self;
    }

    pub fn deinit(self: *BlockManager) void {
        self.allocator.destroy(self);
    }

    /// Stores the file read from `reader` (anything with read([]u8) !usize)
    /// and announces this node as its provider. Returns the root CID
    /// (caller-owned). On error.QuorumNotReached the blocks are still stored
    /// locally; calling put again is idempotent and retries the announcement.
    pub fn put(self: *BlockManager, reader: anytype) ![]const u8 {
        const store = self.store orelse return error.StorageDisabled;

        var builder = storage.dag.DagBuilder{
            .allocator = self.allocator,
            .store = store,
            .layout = self.layout,
        };
        const root = try builder.build(reader);
        errdefer self.allocator.free(root);

        try self.announce(root);
        return root;
    }

    /// Publishes this node as provider of `root` to the closest DHT peers.
    pub fn announce(self: *BlockManager, root: []const u8) !void {
        const key = NodeID{ .bytes = try walk.cidFromSlice(root) };
        if (self.quorum.W == 0) return;

        const acks = try self.dht_node.addProvider(key);
        const acks_u8: u8 = @intCast(@min(acks, std.math.maxInt(u8)));
        if (acks_u8 == 0) {
            // A lone node with no peers cannot announce a provider record
            // and must not stall: storefronts like the Desktop GUI surface
            // the w quorum after the first peer appears.
            return if (self.quorum.W > 0) error.QuorumNotReached else void{};
        }
        if (!quorum.isWriteSatisfied(self.quorum, acks_u8)) return error.QuorumNotReached;
    }

    /// Writes the file rooted at `root` to `writer` (anything with writeAll)
    /// and returns its size. Missing blocks are fetched from the provider
    /// first. Read failures (including error.DagTooLarge when the visit
    /// budget is exhausted) propagate and may leave partial output in `writer`.
    pub fn get(self: *BlockManager, root: []const u8, writer: anytype, options: walk.ReadOptions) !u64 {
        const store = self.store orelse return error.StorageDisabled;
        if (!try walk.isComplete(self.allocator, store, root)) {
            try self.fetch(root);
        }
        return walk.readFile(self.allocator, store, root, writer, options);
    }

    /// Copies every block of `root` that is missing locally, through the
    /// keeper's copy, from the holders `fetchHolders` lists; the fetcher
    /// picks among them per block.
    pub fn fetch(self: *BlockManager, root: []const u8) !void {
        const store = self.store orelse return error.StorageDisabled;
        const fetcher = &(self.fetcher orelse return error.StorageDisabled);
        const cid = try walk.cidFromSlice(root);
        const self_id = self.dht_node.manager.node_id;
        const registry: ?*holders_mod.Holders = if (self.holders) |*h| h else null;
        var go: std.atomic.Value(bool) = .init(true);

        // The backups and the connected peers first, on their own: they
        // answer without a lookup, and a phone on mobile data shouldn't
        // wait for two DHT lookups to ask the backup it is connected to.
        var near_buf: [fetcher_mod.max_holders]NodeID = undefined;
        const near = fetchHolders(self_id, registry, &.{}, &.{}, &near_buf);
        var near_err: ?anyerror = null;
        if (near.len > 0) {
            if (keeper_mod.copy(self.allocator, fetcher, store, cid, near, null, &go)) |_| return else |err| near_err = err;
        }

        // Then the DHT: the nodes named by provider records and the peers
        // closest to the CID. A failed lookup (no DHT peer answering) is
        // reported only when nobody at all was left to ask.
        const key = NodeID{ .bytes = cid };
        var lookup_err: ?anyerror = null;
        const providers: ?[]NodeID = self.dht_node.findProviders(key) catch |err| blk: {
            lookup_err = err;
            break :blk null;
        };
        defer if (providers) |p| self.allocator.free(p);
        const closest: ?[]dht.kbucket.PeerInfo = self.dht_node.closestFor(key) catch |err| blk: {
            lookup_err = err;
            break :blk null;
        };
        defer if (closest) |c| self.allocator.free(c);
        var closest_ids: [fetcher_mod.max_holders]NodeID = undefined;
        var closest_count: usize = 0;
        if (closest) |peers| {
            for (peers[0..@min(peers.len, closest_ids.len)]) |peer| {
                closest_ids[closest_count] = peer.id;
                closest_count += 1;
            }
        }
        const provider_ids: []const NodeID = if (providers) |p| p else &.{};
        // Every candidate in one copy, so each block may use any of them (a
        // file split between a near peer and a provider) and the fetcher
        // weighs every answer (a near peer's real error isn't hidden by a
        // provider's "not found"): the near peers again (skipped per block
        // by the fetcher's miss memory where they said no), the new
        // providers, then the new closest peers (only near the CID in the
        // DHT, often stale), up to fetcher.max_candidates: none is dropped
        // to fit a holder list's eight slots.
        var fresh_providers: [fetcher_mod.max_candidates]NodeID = undefined;
        var fresh_closest: [fetcher_mod.max_candidates]NodeID = undefined;
        const new_providers = dhtHolders(self_id, near, provider_ids, &.{}, &fresh_providers);
        const new_closest = dhtHolders(self_id, near, &.{}, closest_ids[0..closest_count], &fresh_closest);
        // Nobody new: the near peers' answer stands.
        if (new_providers.len + new_closest.len == 0) {
            if (near_err) |err| return err;
            if (lookup_err) |err| return err;
            return error.NoProvider;
        }
        var out: [fetcher_mod.max_candidates]NodeID = undefined;
        const n = phaseTwoHolders(self_id, near, new_providers, new_closest, &out).len;
        _ = try keeper_mod.copy(self.allocator, fetcher, store, cid, out[0..n], null, &go);
    }

    /// The whole-file get's holders, by the same policy as a swarm read
    /// (fs/swarm.zig holderHints): the registry's swarm backups and the
    /// peers connected right now first, since they answer without a dial
    /// or keep every file; then the nodes named by provider records and
    /// the peers the DHT holds closest to the CID. There is no author to
    /// put first. Deduplicated, without this node, capped at
    /// `fetcher.max_holders`, in `out`.
    fn fetchHolders(self_id: NodeID, registry: ?*holders_mod.Holders, providers: []const NodeID, closest: []const NodeID, out: *[fetcher_mod.max_holders]NodeID) []NodeID {
        var n: usize = 0;
        if (registry) |holds| {
            var buf: [fetcher_mod.max_holders]NodeID = undefined;
            // Self as the author: none is listed.
            const split = holds.forSwarmSplit(holds.self_id, &buf);
            for (split.ids[0..split.backups_end]) |h| addHolder(out, &n, h, self_id);
            // Then the connected peers, from all of them (not from the
            // swarm list, already cut to size). Disconnected ones are
            // routing-table entries, which the closest peers cover better.
            var live_buf: [fetcher_mod.max_holders]NodeID = undefined;
            for (holds.connectedPeers(&live_buf)) |h| addHolder(out, &n, h, self_id);
        }
        for (providers) |p| addHolder(out, &n, p, self_id);
        for (closest) |p| addHolder(out, &n, p, self_id);
        return out[0..n];
    }

    /// Phase two's candidates: the near peers, the new providers, then the
    /// new closest peers; deduplicated, without this node, up to
    /// fetcher.max_candidates (past that, the closest go first).
    fn phaseTwoHolders(self_id: NodeID, near: []const NodeID, providers: []const NodeID, closest: []const NodeID, out: *[fetcher_mod.max_candidates]NodeID) []NodeID {
        var n: usize = 0;
        for ([_][]const NodeID{ near, providers, closest }) |group| {
            for (group) |h| addCandidate(out, &n, h, self_id);
        }
        return out[0..n];
    }

    fn containsId(list: []const NodeID, id: NodeID) bool {
        for (list) |x| if (x.eql(id)) return true;
        return false;
    }

    fn addCandidate(out: *[fetcher_mod.max_candidates]NodeID, n: *usize, id: NodeID, self_id: NodeID) void {
        if (n.* >= out.len) return;
        if (id.eql(self_id)) return;
        for (out[0..n.*]) |x| if (x.eql(id)) return;
        out[n.*] = id;
        n.* += 1;
    }

    /// The DHT's holders (providers, then the closest peers) not in
    /// `asked`, without this node, deduplicated, capped at
    /// `fetcher.max_candidates`, in `out`.
    fn dhtHolders(self_id: NodeID, asked: []const NodeID, providers: []const NodeID, closest: []const NodeID, out: *[fetcher_mod.max_candidates]NodeID) []NodeID {
        var n: usize = 0;
        for ([_][]const NodeID{ providers, closest }) |group| {
            for (group) |p| {
                for (asked) |a| {
                    if (a.eql(p)) break;
                } else addCandidate(out, &n, p, self_id);
            }
        }
        return out[0..n];
    }

    fn addHolder(out: *[fetcher_mod.max_holders]NodeID, n: *usize, id: NodeID, self_id: NodeID) void {
        if (n.* >= out.len) return;
        if (id.eql(self_id)) return;
        for (out[0..n.*]) |x| if (x.eql(id)) return;
        out[n.*] = id;
        n.* += 1;
    }

    /// A connection to `peer_id`, located through the routing table or a
    /// DHT lookup. Pooled by the connection manager: deinit it after use.
    pub fn connectTo(self: *BlockManager, peer_id: NodeID) !network.Connection {
        if (self.net.existingConnection(peer_id)) |conn| return conn;
        const peer = self.findPeer(peer_id) catch |err| {
            // A device reached through a relay has no address of its own in
            // the routing table, nor do other devices list one that answers
            // from here: the connection manager's relay is the way to it.
            return self.net.connectToPeerMulti(&.{}, self.dht_node.swarm_key, peer_id) catch return err;
        };
        return self.net.connectToPeerMulti(peer.addresses[0..peer.addrs_count], self.dht_node.swarm_key, peer_id);
    }

    // ---- What the folder layer (fs) asks of the network ----

    /// Every peer the routing table knows, and every device this one has a
    /// connection to: one reached through a relay is never in the table
    /// (its only address there would be the relay's). Caller frees.
    pub fn knownPeers(self: *BlockManager, allocator: std.mem.Allocator) ![]NodeID {
        var ids: std.ArrayList(NodeID) = .empty;
        errdefer ids.deinit(allocator);
        {
            const node = self.dht_node;
            node.mutex.lock();
            defer node.mutex.unlock();
            const peers = try node.routing_table.getAllPeers();
            defer node.routing_table.allocator.free(peers);
            try ids.ensureTotalCapacity(allocator, peers.len);
            for (peers) |p| ids.appendAssumeCapacity(p.id);
        }
        const conns = try self.net.liveConnections(allocator);
        defer {
            for (conns) |c| c.deinit();
            allocator.free(conns);
        }
        for (conns) |c| {
            const peer = c.getRemoteNodeID();
            if (peer.eql(self.net.node_id)) continue;
            for (ids.items) |known| {
                if (known.eql(peer)) break;
            } else try ids.append(allocator, peer);
        }
        return ids.toOwnedSlice(allocator);
    }

    // @atlas allow: the wire answer (listing bytes); fs.remote.Shares decodes it
    pub const SharesReply = struct {
        nickname: []u8,
        /// Encoded dir block.
        listing: []u8,
        /// The device's authenticated identity, when it presented one.
        device_id: ?NodeID,
    };

    /// Asks `peer` which folders it shares (GET_SHARES). Slices allocated
    /// in `allocator`.
    pub fn shares(self: *BlockManager, allocator: std.mem.Allocator, peer: NodeID) !SharesReply {
        const conn = try self.connectTo(peer);
        defer conn.deinit();
        const reply = try self.dht_node.fetchShares(conn);
        defer self.dht_node.allocator.free(reply.listing);
        defer self.dht_node.allocator.free(reply.nickname);
        const nickname = try allocator.dupe(u8, reply.nickname);
        errdefer allocator.free(nickname);
        const listing = try allocator.dupe(u8, reply.listing);
        if (self.fetcher) |*f| f.markUp(peer);
        return .{ .nickname = nickname, .listing = listing, .device_id = conn.getRemoteDeviceID() };
    }

    /// `conn`'s device's swarm folder manifest unless it matches the digest `have`
    /// (GET_SWARM; empty then). Allocated in `allocator`.
    pub fn swarmManifest(self: *BlockManager, allocator: std.mem.Allocator, conn: network.Connection, have: [32]u8) ![]u8 {
        const bytes = try self.dht_node.fetchSwarm(conn, have);
        defer self.dht_node.allocator.free(bytes);
        return allocator.dupe(u8, bytes);
    }

    /// The swarm manifest digest `peer` last announced in a ping, or null.
    pub fn peerSwarmDigest(self: *BlockManager, peer: NodeID) ?[32]u8 {
        return self.dht_node.peerSwarmDigest(peer);
    }

    /// The trust store the handshakes check, if any.
    pub fn trustStore(self: *BlockManager) ?*@import("../device/trust.zig").Store {
        return self.dht_node.trust_store;
    }

    /// A connection to a device already in the routing table, without a DHT
    /// lookup: reads must not wait on the network to find a holder.
    pub fn connectKnown(self: *BlockManager, peer_id: NodeID) !network.Connection {
        if (self.net.existingConnection(peer_id)) |conn| return conn;
        const peer = self.knownPeer(peer_id) orelse return error.ProviderUnreachable;
        return self.net.connectToPeerMulti(peer.addresses[0..peer.addrs_count], self.dht_node.swarm_key, peer_id);
    }

    /// The fetcher's network side: GET_BLOCK to `peer`, retrying a failed
    /// pooled session once. A holder not in
    /// the routing table yet (a node just started, the author not met) is
    /// looked up through the DHT, but not while the connection manager
    /// backs it off: a failed lookup ends in a failed dial, which starts
    /// that backoff, so a device that can't be found costs one lookup per
    /// backoff, even when the fetcher asks it anyway (a probe).
    fn getBlockFrom(ctx: *anyopaque, peer: NodeID, cid: *const fetcher_mod.Cid, allocator: std.mem.Allocator) anyerror!?[]u8 {
        const self: *BlockManager = @ptrCast(@alignCast(ctx));
        const pooled = self.net.existingConnection(peer);
        const conn = pooled orelse try self.connectBlockPeer(peer);
        defer conn.deinit();
        const data = (self.dht_node.fetchBlock(conn, cid.*) catch |err| retry: {
            // Only a session that is gone (closed by its keepalive or the
            // far end) is replaced. One request ending early (a timeout, a
            // stream the server closed) says nothing about the session,
            // which other requests may be using: report it.
            if (pooled == null or !sessionGone(conn, err)) return err;
            // Gone: closing it can't hurt anyone, and drops it from the
            // pool so the retry dials a fresh one.
            conn.close();
            const fresh = try self.connectBlockPeer(peer);
            defer fresh.deinit();
            break :retry (try self.dht_node.fetchBlock(fresh, cid.*));
        }) orelse return null;
        defer self.dht_node.allocator.free(data);
        return try allocator.dupe(u8, data);
    }

    /// A new connection to `peer`. A timeout here is the dial's (the
    /// handshake, through a relay too): reported as ConnectionTimedOut, so
    /// the fetcher doesn't take it for a live link failing under a request.
    fn connectBlockPeer(self: *BlockManager, peer: NodeID) !network.Connection {
        const conn = self.connectKnown(peer) catch |err| switch (err) {
            error.ProviderUnreachable => if (self.net.dialBackedOff(peer)) error.PeerUnreachable else self.connectTo(peer),
            else => err,
        };
        return conn catch |err| dialFailure(err);
    }

    /// A dial's error as the fetcher should see it: a timeout while
    /// connecting is the connection's, not a request's.
    fn dialFailure(err: anyerror) anyerror {
        return if (err == error.Timeout) error.ConnectionTimedOut else err;
    }

    /// The pooled session itself is gone, so a fresh one may work.
    fn sessionGone(conn: network.Connection, err: anyerror) bool {
        return conn.isClosed() or err == error.SessionClosed;
    }

    // ---- The holder registry's view of discovery ----

    /// A peer's announced roles (PING/PONG), or null when unknown.
    fn rolesOfPeered(ctx: *anyopaque, peer: NodeID) ?u8 {
        const self: *BlockManager = @ptrCast(@alignCast(ctx));
        return self.dht_node.peerRoles(peer);
    }

    /// Connected right now: the one sign a peer still exists that stale
    /// state can't fake (other peers' lookup replies can put an ID from
    /// before a re-join back into the routing table).
    fn knowsID(ctx: *anyopaque, peer: NodeID) bool {
        const self: *BlockManager = @ptrCast(@alignCast(ctx));
        return self.net.isConnected(peer);
    }

    /// Peers that announced `bit` lately, kept only if connected or a
    /// current member (a revoked device's announcement lingers for
    /// role_fresh_ms; the same rule as a file's author).
    fn roleIDsOf(ctx: *anyopaque, bit: u8, out: []NodeID) usize {
        const self: *BlockManager = @ptrCast(@alignCast(ctx));
        const n = self.dht_node.copyPeersWithRole(bit, out);
        const trust = self.trustStore() orelse return n;
        var kept: usize = 0;
        for (out[0..n]) |peer| {
            if (!self.net.isConnected(peer) and !trust.isMemberNode(peer)) continue;
            out[kept] = peer;
            kept += 1;
        }
        return kept;
    }

    /// Copies the routing table's peer IDs.
    fn knownIDsOf(ctx: *anyopaque, out: []NodeID) usize {
        const self: *BlockManager = @ptrCast(@alignCast(ctx));
        return self.dht_node.copyPeerIDs(out);
    }

    /// Copies the IDs of the devices connected right now, relayed ones
    /// included (they are in no routing table).
    fn connectedIDsOf(ctx: *anyopaque, out: []NodeID) usize {
        const self: *BlockManager = @ptrCast(@alignCast(ctx));
        return self.net.copyConnectedIDs(out);
    }

    /// The fetcher's view of the connections: a device connected right now
    /// is asked even while its fetch backoff runs.
    fn isConnected(ctx: *anyopaque, peer: NodeID) bool {
        const self: *BlockManager = @ptrCast(@alignCast(ctx));
        return self.net.isConnected(peer);
    }

    fn findPeer(self: *BlockManager, peer_id: NodeID) !dht.kbucket.PeerInfo {
        if (self.knownPeer(peer_id)) |peer| return peer;
        try self.dht_node.lookup(peer_id);
        return self.knownPeer(peer_id) orelse error.ProviderUnreachable;
    }

    fn knownPeer(self: *BlockManager, peer_id: NodeID) ?dht.kbucket.PeerInfo {
        self.dht_node.mutex.lock();
        defer self.dht_node.mutex.unlock();
        const peer = self.dht_node.routing_table.getPeer(peer_id) orelse return null;
        if (peer.addrs_count == 0) return null;
        return peer;
    }
};

const TestConnection = struct {
    node: NodeID,
    device: ?NodeID = null,
    closed: bool = false,
    released: usize = 0,
    failure: anyerror = error.SessionClosed,
    reply: ?network.Stream = null,
    opens: usize = 0,
    fn stream(ctx: *anyopaque) anyerror!network.Stream {
        const self: *@This() = @ptrCast(@alignCast(ctx));
        self.opens += 1;
        if (self.reply) |reply| return reply;
        return self.failure;
    }
    fn address(_: *anyopaque) network.Address {
        return network.Address.initIp4(.{ 0, 0, 0, 0 }, 0);
    }
    fn nodeId(ctx: *anyopaque) NodeID {
        const self: *@This() = @ptrCast(@alignCast(ctx));
        return self.node;
    }
    fn deviceId(ctx: *anyopaque) ?NodeID {
        const self: *@This() = @ptrCast(@alignCast(ctx));
        return self.device;
    }
    fn close(ctx: *anyopaque) void {
        const self: *@This() = @ptrCast(@alignCast(ctx));
        self.closed = true;
    }
    fn retain(_: *anyopaque) void {}
    fn deinit(ctx: *anyopaque) void {
        const self: *@This() = @ptrCast(@alignCast(ctx));
        self.released += 1;
    }
    fn isClosed(ctx: *anyopaque) bool {
        const self: *@This() = @ptrCast(@alignCast(ctx));
        return self.closed;
    }
    fn isInUse(_: *anyopaque) bool {
        return false;
    }
    fn connection(self: *@This()) network.Connection {
        return network.Connection.init(self, &vtable);
    }
    const vtable: network.Connection.ConnectionVTable = .{
        .openStream = stream,
        .acceptStream = stream,
        .getPeerAddress = address,
        .getRemoteNodeID = nodeId,
        .getRemoteDeviceID = deviceId,
        .close = close,
        .retain = retain,
        .deinit = deinit,
        .isClosed = isClosed,
        .isInUse = isInUse,
    };
};

test "block manager: a pooled session that is gone is dropped and redialed once" {
    var manager = network.manager.ConnectionManager.initExplicit(std.testing.allocator, .tcp, network.noise.KeyPair.generate());
    var mock = TestConnection{ .node = .{ .bytes = [_]u8{7} ** 32 } };
    defer manager.deinit();
    var node = dht.Node.init(std.testing.allocator, &manager, "k" ** 32);
    defer node.deinit();
    var bm: BlockManager = .{ .allocator = std.testing.allocator, .net = &manager, .dht_node = &node, .store = null, .quorum = .{} };
    try manager.addConnection(mock.connection());
    // No route or relay exists: the fresh attempt reports its own error.
    try std.testing.expectError(error.ProviderUnreachable, BlockManager.getBlockFrom(&bm, mock.node, &([_]u8{1} ** 32), std.testing.allocator));
    try std.testing.expect(mock.closed);
    try std.testing.expectEqual(@as(usize, 1), mock.opens);
    try std.testing.expectEqual(@as(usize, 1), mock.released);
}

test "block manager: one request's timeout leaves the pooled connection open" {
    var manager = network.manager.ConnectionManager.initExplicit(std.testing.allocator, .tcp, network.noise.KeyPair.generate());
    var mock = TestConnection{ .node = .{ .bytes = [_]u8{7} ** 32 }, .failure = error.Timeout };
    defer manager.deinit();
    var node = dht.Node.init(std.testing.allocator, &manager, "k" ** 32);
    defer node.deinit();
    var bm: BlockManager = .{ .allocator = std.testing.allocator, .net = &manager, .dht_node = &node, .store = null, .quorum = .{} };
    try manager.addConnection(mock.connection());
    // Other requests (read-ahead workers) may be using the session: the
    // timeout is reported, the connection kept, no redial.
    try std.testing.expectError(error.Timeout, BlockManager.getBlockFrom(&bm, mock.node, &([_]u8{1} ** 32), std.testing.allocator));
    try std.testing.expect(!mock.closed);
    try std.testing.expectEqual(@as(usize, 1), mock.opens);
}

test "block manager: a request ending early leaves a healthy pooled session open" {
    var manager = network.manager.ConnectionManager.initExplicit(std.testing.allocator, .tcp, network.noise.KeyPair.generate());
    var mock = TestConnection{ .node = .{ .bytes = [_]u8{7} ** 32 }, .failure = error.EndOfStream };
    defer manager.deinit();
    var node = dht.Node.init(std.testing.allocator, &manager, "k" ** 32);
    defer node.deinit();
    var bm: BlockManager = .{ .allocator = std.testing.allocator, .net = &manager, .dht_node = &node, .store = null, .quorum = .{} };
    try manager.addConnection(mock.connection());
    // The server closed that one stream; the session (and other requests
    // on it) is fine: reported, not closed, no redial.
    try std.testing.expectError(error.EndOfStream, BlockManager.getBlockFrom(&bm, mock.node, &([_]u8{1} ** 32), std.testing.allocator));
    try std.testing.expect(!mock.closed);
    try std.testing.expectEqual(@as(usize, 1), mock.opens);
}

test "block manager: local allocation failure leaves the pooled connection open" {
    var manager = network.manager.ConnectionManager.initExplicit(std.testing.allocator, .tcp, network.noise.KeyPair.generate());
    var mock = TestConnection{ .node = .{ .bytes = [_]u8{7} ** 32 }, .failure = error.OutOfMemory };
    defer manager.deinit();
    var node = dht.Node.init(std.testing.allocator, &manager, "k" ** 32);
    defer node.deinit();
    var bm: BlockManager = .{ .allocator = std.testing.allocator, .net = &manager, .dht_node = &node, .store = null, .quorum = .{} };
    try manager.addConnection(mock.connection());
    try std.testing.expectError(error.OutOfMemory, BlockManager.getBlockFrom(&bm, mock.node, &([_]u8{1} ** 32), std.testing.allocator));
    try std.testing.expect(!mock.closed);
    try std.testing.expectEqual(@as(usize, 1), mock.opens);
}

test "block manager: a pooled block miss does not close or retry the connection" {
    const Reply = struct {
        bytes: [128]u8 = undefined,
        len: usize = 0,
        pos: usize = 0,
        saving: bool = true,
        fn read(ctx: *anyopaque, out: []u8) anyerror!usize {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            const n = @min(out.len, self.len - self.pos);
            @memcpy(out[0..n], self.bytes[self.pos..][0..n]);
            self.pos += n;
            return n;
        }
        fn write(ctx: *anyopaque, bytes: []const u8) anyerror!usize {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            if (self.saving) {
                if (bytes.len > self.bytes.len - self.len) return error.NoSpaceLeft;
                @memcpy(self.bytes[self.len..][0..bytes.len], bytes);
                self.len += bytes.len;
            }
            return bytes.len;
        }
        fn close(_: *anyopaque) void {}
        const vtable: network.Stream.StreamVTable = .{ .read = read, .write = write, .close = close };
    };
    var reply: Reply = .{};
    const stream = network.Stream.init(&reply, &Reply.vtable);
    const message = dht.rpc.Message{ .sender_id = .{ .bytes = [_]u8{7} ** 32 }, .payload = .{ .BLOCK = .{ .data = null } } };
    try message.send(std.testing.allocator, stream);
    reply.saving = false;
    var manager = network.manager.ConnectionManager.initExplicit(std.testing.allocator, .tcp, network.noise.KeyPair.generate());
    var mock = TestConnection{ .node = message.sender_id, .reply = stream };
    defer manager.deinit();
    var node = dht.Node.init(std.testing.allocator, &manager, "k" ** 32);
    defer node.deinit();
    var bm: BlockManager = .{ .allocator = std.testing.allocator, .net = &manager, .dht_node = &node, .store = null, .quorum = .{} };
    try manager.addConnection(mock.connection());
    try std.testing.expectEqual(@as(?[]u8, null), try BlockManager.getBlockFrom(&bm, mock.node, &([_]u8{1} ** 32), std.testing.allocator));
    try std.testing.expect(!mock.closed);
    try std.testing.expectEqual(@as(usize, 1), mock.opens);
}

test "block manager: announced backups are kept only if connected or current members" {
    var manager = network.manager.ConnectionManager.initExplicit(std.testing.allocator, .tcp, network.noise.KeyPair.generate());
    defer manager.deinit();
    var node = dht.Node.init(std.testing.allocator, &manager, "k" ** 32);
    defer node.deinit();
    const io = std.Io.Threaded.global_single_threaded.io();
    const path = "test_bm_role_trust.store";
    std.Io.Dir.cwd().deleteFile(io, path) catch {};
    defer std.Io.Dir.cwd().deleteFile(io, path) catch {};
    var trust = try @import("../device/trust.zig").Store.load(std.testing.allocator, path, null);
    defer trust.deinit();
    const member_key = [_]u8{41} ** 32;
    _ = try trust.upsert([_]u8{40} ** 32, member_key, "backup", 1);
    node.trust_store = &trust;
    var bm: BlockManager = .{ .allocator = std.testing.allocator, .net = &manager, .dht_node = &node, .store = null, .quorum = .{} };
    const member = NodeID.fromPublicKey(member_key);
    const revoked = NodeID{ .bytes = [_]u8{42} ** 32 };
    node.recordPeerRoles(member, rpc_roles.swarm_backup, rpc_no_swarm);
    node.recordPeerRoles(revoked, rpc_roles.swarm_backup, rpc_no_swarm);
    var out: [4]NodeID = undefined;
    // The member is kept; the other (a revoked device, say) isn't.
    try std.testing.expectEqualSlices(NodeID, &.{member}, out[0..BlockManager.roleIDsOf(&bm, rpc_roles.swarm_backup, &out)]);
}

test "block manager: a connected non-member announcing swarm backup is kept" {
    var manager = network.manager.ConnectionManager.initExplicit(std.testing.allocator, .tcp, network.noise.KeyPair.generate());
    defer manager.deinit();
    var node = dht.Node.init(std.testing.allocator, &manager, "k" ** 32);
    defer node.deinit();
    const io = std.Io.Threaded.global_single_threaded.io();
    const path = "test_bm_role_connected.store";
    std.Io.Dir.cwd().deleteFile(io, path) catch {};
    defer std.Io.Dir.cwd().deleteFile(io, path) catch {};
    // An empty trust store: nobody is a member, so only the connection
    // can keep the backup.
    var trust = try @import("../device/trust.zig").Store.load(std.testing.allocator, path, null);
    defer trust.deinit();
    node.trust_store = &trust;
    var bm: BlockManager = .{ .allocator = std.testing.allocator, .net = &manager, .dht_node = &node, .store = null, .quorum = .{} };
    var mock = TestConnection{ .node = .{ .bytes = [_]u8{43} ** 32 } };
    try manager.addConnection(mock.connection());
    const gone = NodeID{ .bytes = [_]u8{44} ** 32 };
    node.recordPeerRoles(mock.node, rpc_roles.swarm_backup, rpc_no_swarm);
    node.recordPeerRoles(gone, rpc_roles.swarm_backup, rpc_no_swarm);
    var out: [4]NodeID = undefined;
    try std.testing.expectEqualSlices(NodeID, &.{mock.node}, out[0..BlockManager.roleIDsOf(&bm, rpc_roles.swarm_backup, &out)]);
}

test "block manager: a dial's timeout is reported as the connection's" {
    // connectBlockPeer maps through this; a real dial timeout needs a network.
    try std.testing.expectEqual(@as(anyerror, error.ConnectionTimedOut), BlockManager.dialFailure(error.Timeout));
    try std.testing.expectEqual(@as(anyerror, error.ConnectionRefused), BlockManager.dialFailure(error.ConnectionRefused));
    try std.testing.expectEqual(@as(anyerror, error.PeerUnreachable), BlockManager.dialFailure(error.PeerUnreachable));
}

test "block manager: a whole-file get asks backups and connected peers before providers" {
    const Fake = struct {
        backups: []const NodeID,
        connected: []const NodeID,
        routing: []const NodeID,
        fn has(list: []const NodeID, id: NodeID) bool {
            for (list) |x| if (x.eql(id)) return true;
            return false;
        }
        fn copy(list: []const NodeID, out: []NodeID) usize {
            const n = @min(list.len, out.len);
            @memcpy(out[0..n], list[0..n]);
            return n;
        }
        fn roles(ctx: *anyopaque, peer: NodeID) ?u8 {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            return if (has(self.backups, peer)) rpc_roles.swarm_backup else 0;
        }
        fn known(ctx: *anyopaque, out: []NodeID) usize {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            return copy(self.routing, out);
        }
        fn live(ctx: *anyopaque, out: []NodeID) usize {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            return copy(self.connected, out);
        }
        fn knows(ctx: *anyopaque, peer: NodeID) bool {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            return has(self.connected, peer);
        }
    };
    const id = struct {
        fn of(b: u8) NodeID {
            return .{ .bytes = [_]u8{b} ** 32 };
        }
    }.of;
    const self_id = id(1);
    // 2: connected backup, 3: backup in the table only, 4: connected,
    // 5: in the table only.
    var fake: Fake = .{ .backups = &.{ id(2), id(3) }, .connected = &.{ id(2), id(4) }, .routing = &.{ id(3), id(5) } };
    var registry: holders_mod.Holders = .{
        .self_id = self_id,
        .peers = .{ .ctx = &fake, .rolesFn = Fake.roles, .knownFn = Fake.known, .connectedFn = Fake.live, .knowsFn = Fake.knows },
    };
    const providers = [_]NodeID{ id(4), id(6), self_id };
    const closest = [_]NodeID{ id(7), id(5), id(8), id(9), id(10), id(11) };
    var out: [fetcher_mod.max_holders]NodeID = undefined;

    // Backups (the connected one first), the connected peer, then the
    // providers and the closest peers: each once, never this node, and
    // the table-only peer 5 only where the DHT names it.
    const got = BlockManager.fetchHolders(self_id, &registry, &providers, &closest, &out);
    try std.testing.expectEqualSlices(NodeID, &.{ id(2), id(3), id(4), id(6), id(7), id(5), id(8), id(9) }, got);

    // Without a registry (no store): the DHT's answers alone.
    const bare = BlockManager.fetchHolders(self_id, null, &providers, closest[0..2], &out);
    try std.testing.expectEqualSlices(NodeID, &.{ id(4), id(6), id(7), id(5) }, bare);
}

const rpc_roles = @import("../net/discovery/rpc.zig").Roles;
const rpc_no_swarm = @import("../net/discovery/rpc.zig").no_swarm;

test "block manager: a connected metered peer isn't lost to a full table of disconnected ones" {
    const Fake = struct {
        metered: NodeID,
        connected: []const NodeID,
        routing: []const NodeID,
        fn copy(list: []const NodeID, out: []NodeID) usize {
            const n = @min(list.len, out.len);
            @memcpy(out[0..n], list[0..n]);
            return n;
        }
        fn roles(ctx: *anyopaque, peer: NodeID) ?u8 {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            return if (peer.eql(self.metered)) rpc_roles.metered else 0;
        }
        fn known(ctx: *anyopaque, out: []NodeID) usize {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            return copy(self.routing, out);
        }
        fn live(ctx: *anyopaque, out: []NodeID) usize {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            return copy(self.connected, out);
        }
    };
    const id = struct {
        fn of(b: u8) NodeID {
            return .{ .bytes = [_]u8{b} ** 32 };
        }
    }.of;
    // 20: connected (through a relay, on mobile data), in no table; eight
    // disconnected table entries that would rank before it.
    const phone = id(20);
    var fake: Fake = .{ .metered = phone, .connected = &.{phone}, .routing = &.{ id(30), id(31), id(32), id(33), id(34), id(35), id(36), id(37) } };
    var registry: holders_mod.Holders = .{
        .self_id = id(1),
        .peers = .{ .ctx = &fake, .rolesFn = Fake.roles, .knownFn = Fake.known, .connectedFn = Fake.live },
    };
    var out: [fetcher_mod.max_holders]NodeID = undefined;
    try std.testing.expectEqualSlices(NodeID, &.{phone}, BlockManager.fetchHolders(id(1), &registry, &.{}, &.{}, &out));
}

test "block manager: the DHT phase asks the holders the near phase didn't, even with eight near" {
    const id = struct {
        fn of(b: u8) NodeID {
            return .{ .bytes = [_]u8{b} ** 32 };
        }
    }.of;
    // Eight connected peers were asked first (and failed); the only holder
    // is a provider none of them is.
    const near = [_]NodeID{ id(10), id(11), id(12), id(13), id(14), id(15), id(16), id(17) };
    const providers = [_]NodeID{ id(11), id(40), id(1) };
    const closest = [_]NodeID{ id(12), id(41), id(40) };
    var out: [fetcher_mod.max_candidates]NodeID = undefined;
    // New ones only: the provider first, then a closest peer; not this
    // node (1), no repeats.
    try std.testing.expectEqualSlices(NodeID, &.{ id(40), id(41) }, BlockManager.dhtHolders(id(1), &near, &providers, &closest, &out));
    // Nothing new: empty, so phase one's answer stands.
    try std.testing.expectEqual(@as(usize, 0), BlockManager.dhtHolders(id(1), &near, &.{id(10)}, &.{id(11)}, &out).len);
}

/// A whole-file get across both phases: `a` is connected (asked first),
/// `b` a provider found through the DHT.
const TwoPhaseCase = struct {
    const Case = enum { split_dag, error_precedence };
    a: NodeID = .{ .bytes = [_]u8{61} ** 32 },
    b: NodeID = .{ .bytes = [_]u8{62} ** 32 },
    case: Case,
    root: fetcher_mod.Cid,
    middle: fetcher_mod.Cid,
    leaf: fetcher_mod.Cid,
    root_data: []const u8,
    middle_data: []const u8,
    leaf_data: []const u8,
    a_leaf_asked: bool = false,
    b_middle_asked: bool = false,
    fn roles(_: *anyopaque, _: NodeID) ?u8 {
        return 0;
    }
    fn known(_: *anyopaque, _: []NodeID) usize {
        return 0;
    }
    fn live(ctx: *anyopaque, out: []NodeID) usize {
        const self: *@This() = @ptrCast(@alignCast(ctx));
        if (out.len == 0) return 0;
        out[0] = self.a;
        return 1;
    }
    fn connected(ctx: *anyopaque, peer: NodeID) bool {
        const self: *@This() = @ptrCast(@alignCast(ctx));
        return peer.eql(self.a);
    }
    fn get(ctx: *anyopaque, peer: NodeID, cid: *const fetcher_mod.Cid, allocator: std.mem.Allocator) anyerror!?[]u8 {
        const self: *@This() = @ptrCast(@alignCast(ctx));
        if (self.case == .error_precedence) return if (peer.eql(self.a)) error.InvalidResponse else null;
        if (peer.eql(self.a)) {
            if (std.mem.eql(u8, cid, &self.root)) return try allocator.dupe(u8, self.root_data);
            if (std.mem.eql(u8, cid, &self.leaf)) {
                self.a_leaf_asked = true;
                return try allocator.dupe(u8, self.leaf_data);
            }
        } else if (std.mem.eql(u8, cid, &self.middle)) {
            self.b_middle_asked = true;
            return try allocator.dupe(u8, self.middle_data);
        }
        return null;
    }
    fn run(case: Case) !void {
        const allocator = std.testing.allocator;
        const codec = storage.dag.codec;
        const leaf_data = "\x00held by near";
        var leaf: fetcher_mod.Cid = undefined;
        std.crypto.hash.sha2.Sha256.hash(leaf_data, &leaf, .{});
        const middle_data = try codec.encodeParent(allocator, &.{.{ .name = "leaf", .cid = &leaf, .size = leaf_data.len - 1 }});
        defer allocator.free(middle_data);
        var middle: fetcher_mod.Cid = undefined;
        std.crypto.hash.sha2.Sha256.hash(middle_data, &middle, .{});
        const root_data = try codec.encodeParent(allocator, &.{.{ .name = "middle", .cid = &middle, .size = leaf_data.len - 1 }});
        defer allocator.free(root_data);
        var root: fetcher_mod.Cid = undefined;
        std.crypto.hash.sha2.Sha256.hash(root_data, &root, .{});
        var store = try fetcher_mod.testStore("test_two_phase_get");
        defer {
            store.deinit();
            std.Io.Dir.cwd().deleteTree(std.Io.Threaded.global_single_threaded.io(), "test_two_phase_get") catch {};
        }
        var manager = network.manager.ConnectionManager.initExplicit(allocator, .tcp, network.noise.KeyPair.generate());
        defer manager.deinit();
        var node = dht.Node.init(allocator, &manager, "k" ** 32);
        defer node.deinit();
        const bm = try BlockManager.init(allocator, .{ .network = &manager, .dht = &node, .storage = &store });
        defer bm.deinit();
        var fake: @This() = .{ .case = case, .root = root, .middle = middle, .leaf = leaf, .root_data = root_data, .middle_data = middle_data, .leaf_data = leaf_data };
        try node.providers.add(allocator, .{ .bytes = root }, fake.b, @import("../sync.zig").timestamp());
        bm.fetcher = fetcher_mod.Fetcher.init(&store, .{ .ctx = &fake, .getFn = get, .connectedFn = connected });
        bm.holders = .{ .self_id = manager.node_id, .peers = .{ .ctx = &fake, .rolesFn = roles, .knownFn = known, .connectedFn = live } };
        if (case == .error_precedence) {
            try std.testing.expectError(error.InvalidResponse, bm.fetch(&root));
        } else {
            try bm.fetch(&root);
            try std.testing.expect(fake.b_middle_asked);
            try std.testing.expect(fake.a_leaf_asked);
            try std.testing.expect(try walk.isComplete(allocator, &store, &root));
        }
    }
};

test "block manager: a file split between a near peer and a provider is fetched whole" {
    try TwoPhaseCase.run(.split_dag);
}

test "block manager: a provider's not found doesn't hide a near peer's real error" {
    try TwoPhaseCase.run(.error_precedence);
}

/// TwoPhaseCase with phase two full: seven more (negative) provider
/// records besides the real one.
const SaturatedCase = struct {
    const Case = enum { split_dag, error_precedence };
    a: NodeID = .{ .bytes = [_]u8{61} ** 32 },
    b: NodeID = .{ .bytes = [_]u8{62} ** 32 },
    case: Case,
    root: fetcher_mod.Cid,
    middle: fetcher_mod.Cid,
    leaf: fetcher_mod.Cid,
    root_data: []const u8,
    middle_data: []const u8,
    leaf_data: []const u8,
    a_leaf_asked: bool = false,
    b_middle_asked: bool = false,
    fn roles(_: *anyopaque, _: NodeID) ?u8 {
        return 0;
    }
    fn known(_: *anyopaque, _: []NodeID) usize {
        return 0;
    }
    fn live(ctx: *anyopaque, out: []NodeID) usize {
        const self: *@This() = @ptrCast(@alignCast(ctx));
        if (out.len == 0) return 0;
        out[0] = self.a;
        return 1;
    }
    fn connected(ctx: *anyopaque, peer: NodeID) bool {
        const self: *@This() = @ptrCast(@alignCast(ctx));
        return peer.eql(self.a);
    }
    fn get(ctx: *anyopaque, peer: NodeID, cid: *const fetcher_mod.Cid, allocator: std.mem.Allocator) anyerror!?[]u8 {
        const self: *@This() = @ptrCast(@alignCast(ctx));
        if (self.case == .error_precedence) return if (peer.eql(self.a)) error.InvalidResponse else null;
        if (peer.eql(self.a)) {
            if (std.mem.eql(u8, cid, &self.root)) return try allocator.dupe(u8, self.root_data);
            if (std.mem.eql(u8, cid, &self.leaf)) {
                self.a_leaf_asked = true;
                return try allocator.dupe(u8, self.leaf_data);
            }
        } else if (peer.eql(self.b) and std.mem.eql(u8, cid, &self.middle)) {
            self.b_middle_asked = true;
            return try allocator.dupe(u8, self.middle_data);
        }
        return null;
    }
    fn run(case: Case) !void {
        const allocator = std.testing.allocator;
        const codec = storage.dag.codec;
        const leaf_data = "\x00held by near";
        var leaf: fetcher_mod.Cid = undefined;
        std.crypto.hash.sha2.Sha256.hash(leaf_data, &leaf, .{});
        const middle_data = try codec.encodeParent(allocator, &.{.{ .name = "leaf", .cid = &leaf, .size = leaf_data.len - 1 }});
        defer allocator.free(middle_data);
        var middle: fetcher_mod.Cid = undefined;
        std.crypto.hash.sha2.Sha256.hash(middle_data, &middle, .{});
        const root_data = try codec.encodeParent(allocator, &.{.{ .name = "middle", .cid = &middle, .size = leaf_data.len - 1 }});
        defer allocator.free(root_data);
        var root: fetcher_mod.Cid = undefined;
        std.crypto.hash.sha2.Sha256.hash(root_data, &root, .{});
        var store = try fetcher_mod.testStore("test_two_phase_full");
        defer {
            store.deinit();
            std.Io.Dir.cwd().deleteTree(std.Io.Threaded.global_single_threaded.io(), "test_two_phase_full") catch {};
        }
        var manager = network.manager.ConnectionManager.initExplicit(allocator, .tcp, network.noise.KeyPair.generate());
        defer manager.deinit();
        var node = dht.Node.init(allocator, &manager, "k" ** 32);
        defer node.deinit();
        const bm = try BlockManager.init(allocator, .{ .network = &manager, .dht = &node, .storage = &store });
        defer bm.deinit();
        var fake: @This() = .{ .case = case, .root = root, .middle = middle, .leaf = leaf, .root_data = root_data, .middle_data = middle_data, .leaf_data = leaf_data };
        try node.providers.add(allocator, .{ .bytes = root }, fake.b, @import("../sync.zig").timestamp());
        // One real provider and seven negative provider records fill phase two.
        for (70..77) |i| {
            const extra: NodeID = .{ .bytes = [_]u8{@intCast(i)} ** 32 };
            try node.providers.add(allocator, .{ .bytes = root }, extra, @import("../sync.zig").timestamp());
        }
        bm.fetcher = fetcher_mod.Fetcher.init(&store, .{ .ctx = &fake, .getFn = get, .connectedFn = connected });
        bm.holders = .{ .self_id = manager.node_id, .peers = .{ .ctx = &fake, .rolesFn = roles, .knownFn = known, .connectedFn = live } };
        if (case == .error_precedence) {
            try std.testing.expectError(error.InvalidResponse, bm.fetch(&root));
        } else {
            try bm.fetch(&root);
            try std.testing.expect(fake.b_middle_asked);
            try std.testing.expect(fake.a_leaf_asked);
            try std.testing.expect(try walk.isComplete(allocator, &store, &root));
        }
    }
};

test "block manager: a split file is fetched whole even with eight providers" {
    try SaturatedCase.run(.split_dag);
}

test "block manager: eight providers' not found don't hide a near peer's real error" {
    try SaturatedCase.run(.error_precedence);
}

test "block manager: phase two lists every candidate, none dropped to fit eight" {
    const id = struct {
        fn of(b: u8) NodeID {
            return .{ .bytes = [_]u8{b} ** 32 };
        }
    }.of;
    var out: [fetcher_mod.max_candidates]NodeID = undefined;
    // Eight near peers, eight providers, two closest: all eighteen, in
    // that order (this node and repeats left out).
    const near = [_]NodeID{ id(10), id(11), id(12), id(13), id(14), id(15), id(16), id(17) };
    const providers = [_]NodeID{ id(40), id(41), id(42), id(43), id(44), id(45), id(46), id(47) };
    const list = BlockManager.phaseTwoHolders(id(1), &near, &providers, &.{ id(60), id(10), id(1), id(61) }, &out);
    try std.testing.expectEqual(@as(usize, 18), list.len);
    try std.testing.expectEqualSlices(NodeID, &near, list[0..8]);
    try std.testing.expectEqualSlices(NodeID, &providers, list[8..16]);
    try std.testing.expectEqualSlices(NodeID, &.{ id(60), id(61) }, list[16..18]);
    // Past max_candidates, the closest are the ones left out.
    var many: [40]NodeID = undefined;
    for (&many, 0..) |*m, i| m.* = id(@intCast(100 + i));
    const capped = BlockManager.phaseTwoHolders(id(1), &near, many[0..30], &.{id(60)}, &out);
    try std.testing.expectEqual(@as(usize, fetcher_mod.max_candidates), capped.len);
    try std.testing.expect(!BlockManager.containsId(capped, id(60)));
}

/// A whole-file get with more near peers than half of eight: the one
/// holding a later block (or failing with a real error) is the fifth.
const NearTailCase = struct {
    const Case = enum { split_dag, error_precedence };
    a: NodeID = .{ .bytes = [_]u8{61} ** 32 },
    b: NodeID = .{ .bytes = [_]u8{62} ** 32 },
    case: Case,
    root: fetcher_mod.Cid,
    middle: fetcher_mod.Cid,
    leaf: fetcher_mod.Cid,
    root_data: []const u8,
    middle_data: []const u8,
    leaf_data: []const u8,
    a_leaf_asked: bool = false,
    b_middle_asked: bool = false,
    fn roles(_: *anyopaque, _: NodeID) ?u8 {
        return 0;
    }
    fn known(_: *anyopaque, _: []NodeID) usize {
        return 0;
    }
    fn live(ctx: *anyopaque, out: []NodeID) usize {
        const self: *@This() = @ptrCast(@alignCast(ctx));
        const ids = [_]NodeID{ .{ .bytes = [_]u8{80} ** 32 }, .{ .bytes = [_]u8{81} ** 32 }, .{ .bytes = [_]u8{82} ** 32 }, .{ .bytes = [_]u8{83} ** 32 }, self.a, .{ .bytes = [_]u8{84} ** 32 }, .{ .bytes = [_]u8{85} ** 32 }, .{ .bytes = [_]u8{86} ** 32 } };
        const n = @min(ids.len, out.len);
        @memcpy(out[0..n], ids[0..n]);
        return n;
    }
    fn connected(ctx: *anyopaque, peer: NodeID) bool {
        const self: *@This() = @ptrCast(@alignCast(ctx));
        return peer.eql(self.a) or (peer.bytes[0] >= 80 and peer.bytes[0] <= 86);
    }
    fn get(ctx: *anyopaque, peer: NodeID, cid: *const fetcher_mod.Cid, allocator: std.mem.Allocator) anyerror!?[]u8 {
        const self: *@This() = @ptrCast(@alignCast(ctx));
        if (self.case == .error_precedence) return if (peer.eql(self.a)) error.InvalidResponse else null;
        if (peer.eql(self.a)) {
            if (std.mem.eql(u8, cid, &self.root)) return try allocator.dupe(u8, self.root_data);
            if (std.mem.eql(u8, cid, &self.leaf)) {
                self.a_leaf_asked = true;
                return try allocator.dupe(u8, self.leaf_data);
            }
        } else if (peer.eql(self.b) and std.mem.eql(u8, cid, &self.middle)) {
            self.b_middle_asked = true;
            return try allocator.dupe(u8, self.middle_data);
        }
        return null;
    }
    fn run(case: Case) !void {
        const allocator = std.testing.allocator;
        const codec = storage.dag.codec;
        const leaf_data = "\x00held by near";
        var leaf: fetcher_mod.Cid = undefined;
        std.crypto.hash.sha2.Sha256.hash(leaf_data, &leaf, .{});
        const middle_data = try codec.encodeParent(allocator, &.{.{ .name = "leaf", .cid = &leaf, .size = leaf_data.len - 1 }});
        defer allocator.free(middle_data);
        var middle: fetcher_mod.Cid = undefined;
        std.crypto.hash.sha2.Sha256.hash(middle_data, &middle, .{});
        const root_data = try codec.encodeParent(allocator, &.{.{ .name = "middle", .cid = &middle, .size = leaf_data.len - 1 }});
        defer allocator.free(root_data);
        var root: fetcher_mod.Cid = undefined;
        std.crypto.hash.sha2.Sha256.hash(root_data, &root, .{});
        var store = try fetcher_mod.testStore("test_two_phase_near_tail");
        defer {
            store.deinit();
            std.Io.Dir.cwd().deleteTree(std.Io.Threaded.global_single_threaded.io(), "test_two_phase_near_tail") catch {};
        }
        var manager = network.manager.ConnectionManager.initExplicit(allocator, .tcp, network.noise.KeyPair.generate());
        defer manager.deinit();
        var node = dht.Node.init(allocator, &manager, "k" ** 32);
        defer node.deinit();
        const bm = try BlockManager.init(allocator, .{ .network = &manager, .dht = &node, .storage = &store });
        defer bm.deinit();
        var fake: @This() = .{ .case = case, .root = root, .middle = middle, .leaf = leaf, .root_data = root_data, .middle_data = middle_data, .leaf_data = leaf_data };
        try node.providers.add(allocator, .{ .bytes = root }, fake.b, @import("../sync.zig").timestamp());
        // One real provider and seven negative provider records fill phase two.
        for (70..77) |i| {
            const extra: NodeID = .{ .bytes = [_]u8{@intCast(i)} ** 32 };
            try node.providers.add(allocator, .{ .bytes = root }, extra, @import("../sync.zig").timestamp());
        }
        bm.fetcher = fetcher_mod.Fetcher.init(&store, .{ .ctx = &fake, .getFn = get, .connectedFn = connected });
        bm.holders = .{ .self_id = manager.node_id, .peers = .{ .ctx = &fake, .rolesFn = roles, .knownFn = known, .connectedFn = live } };
        if (case == .error_precedence) {
            try std.testing.expectError(error.InvalidResponse, bm.fetch(&root));
        } else {
            try bm.fetch(&root);
            try std.testing.expect(fake.b_middle_asked);
            try std.testing.expect(fake.a_leaf_asked);
            try std.testing.expect(try walk.isComplete(allocator, &store, &root));
        }
    }
};

/// A whole-file get whose real provider is the eighth provider record.
const ProviderTailCase = struct {
    const Case = enum { split_dag, error_precedence };
    a: NodeID = .{ .bytes = [_]u8{61} ** 32 },
    b: NodeID = .{ .bytes = [_]u8{62} ** 32 },
    case: Case,
    root: fetcher_mod.Cid,
    middle: fetcher_mod.Cid,
    leaf: fetcher_mod.Cid,
    root_data: []const u8,
    middle_data: []const u8,
    leaf_data: []const u8,
    a_leaf_asked: bool = false,
    b_middle_asked: bool = false,
    fn roles(_: *anyopaque, _: NodeID) ?u8 {
        return 0;
    }
    fn known(_: *anyopaque, _: []NodeID) usize {
        return 0;
    }
    fn live(ctx: *anyopaque, out: []NodeID) usize {
        const self: *@This() = @ptrCast(@alignCast(ctx));
        if (out.len == 0) return 0;
        out[0] = self.a;
        return 1;
    }
    fn connected(ctx: *anyopaque, peer: NodeID) bool {
        const self: *@This() = @ptrCast(@alignCast(ctx));
        return peer.eql(self.a);
    }
    fn get(ctx: *anyopaque, peer: NodeID, cid: *const fetcher_mod.Cid, allocator: std.mem.Allocator) anyerror!?[]u8 {
        const self: *@This() = @ptrCast(@alignCast(ctx));
        if (self.case == .error_precedence) return if (peer.eql(self.a)) error.InvalidResponse else null;
        if (peer.eql(self.a)) {
            if (std.mem.eql(u8, cid, &self.root)) return try allocator.dupe(u8, self.root_data);
            if (std.mem.eql(u8, cid, &self.leaf)) {
                self.a_leaf_asked = true;
                return try allocator.dupe(u8, self.leaf_data);
            }
        } else if (peer.eql(self.b)) {
            if (std.mem.eql(u8, cid, &self.middle)) {
                self.b_middle_asked = true;
                return try allocator.dupe(u8, self.middle_data);
            }
            if (std.mem.eql(u8, cid, &self.leaf)) return try allocator.dupe(u8, self.leaf_data);
        }
        return null;
    }
    fn run(case: Case) !void {
        const allocator = std.testing.allocator;
        const codec = storage.dag.codec;
        const leaf_data = "\x00held by near";
        var leaf: fetcher_mod.Cid = undefined;
        std.crypto.hash.sha2.Sha256.hash(leaf_data, &leaf, .{});
        const middle_data = try codec.encodeParent(allocator, &.{.{ .name = "leaf", .cid = &leaf, .size = leaf_data.len - 1 }});
        defer allocator.free(middle_data);
        var middle: fetcher_mod.Cid = undefined;
        std.crypto.hash.sha2.Sha256.hash(middle_data, &middle, .{});
        const root_data = try codec.encodeParent(allocator, &.{.{ .name = "middle", .cid = &middle, .size = leaf_data.len - 1 }});
        defer allocator.free(root_data);
        var root: fetcher_mod.Cid = undefined;
        std.crypto.hash.sha2.Sha256.hash(root_data, &root, .{});
        var store = try fetcher_mod.testStore("test_two_phase_provider_tail");
        defer {
            store.deinit();
            std.Io.Dir.cwd().deleteTree(std.Io.Threaded.global_single_threaded.io(), "test_two_phase_provider_tail") catch {};
        }
        var manager = network.manager.ConnectionManager.initExplicit(allocator, .tcp, network.noise.KeyPair.generate());
        defer manager.deinit();
        var node = dht.Node.init(allocator, &manager, "k" ** 32);
        defer node.deinit();
        const bm = try BlockManager.init(allocator, .{ .network = &manager, .dht = &node, .storage = &store });
        defer bm.deinit();
        var fake: @This() = .{ .case = case, .root = root, .middle = middle, .leaf = leaf, .root_data = root_data, .middle_data = middle_data, .leaf_data = leaf_data };
        // One real provider and seven negative provider records fill phase two.
        for (70..77) |i| {
            const extra: NodeID = .{ .bytes = [_]u8{@intCast(i)} ** 32 };
            try node.providers.add(allocator, .{ .bytes = root }, extra, @import("../sync.zig").timestamp());
        }
        try node.providers.add(allocator, .{ .bytes = root }, fake.b, @import("../sync.zig").timestamp());
        bm.fetcher = fetcher_mod.Fetcher.init(&store, .{ .ctx = &fake, .getFn = get, .connectedFn = connected });
        bm.holders = .{ .self_id = manager.node_id, .peers = .{ .ctx = &fake, .rolesFn = roles, .knownFn = known, .connectedFn = live } };
        if (case == .error_precedence) {
            try std.testing.expectError(error.InvalidResponse, bm.fetch(&root));
        } else {
            try bm.fetch(&root);
            try std.testing.expect(fake.b_middle_asked);
            try std.testing.expect(try walk.isComplete(allocator, &store, &root));
        }
    }
};

test "block manager: a near peer past half the slots still serves a later block" {
    try NearTailCase.run(.split_dag);
}
test "block manager: a near peer past half the slots still has its real error reported" {
    try NearTailCase.run(.error_precedence);
}
test "block manager: the eighth provider is still asked for a missing block" {
    try ProviderTailCase.run(.split_dag);
}
