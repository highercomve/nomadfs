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
            self.fetcher = fetcher_mod.Fetcher.init(s, .{ .ctx = self, .getFn = getBlockFrom });
            self.holders = .{
                .self_id = config.dht.manager.node_id,
                .peers = .{ .ctx = config.dht, .rolesFn = rolesOfPeered, .knownFn = knownIDsOf },
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
    /// keeper's copy: the holders are the nodes named by provider records,
    /// then the peers the DHT holds closest to the CID; the fetcher picks
    /// among them per block.
    pub fn fetch(self: *BlockManager, root: []const u8) !void {
        const store = self.store orelse return error.StorageDisabled;
        const fetcher = &(self.fetcher orelse return error.StorageDisabled);
        const cid = try walk.cidFromSlice(root);
        const key = NodeID{ .bytes = cid };

        var holders: [fetcher_mod.max_holders]NodeID = undefined;
        var n: usize = 0;
        const providers = try self.dht_node.findProviders(key);
        defer self.allocator.free(providers);
        for (providers) |p| addHolder(&holders, &n, p);
        const closest = try self.dht_node.closestFor(key);
        defer self.allocator.free(closest);
        for (closest) |peer| addHolder(&holders, &n, peer.id);
        if (n == 0) return error.NoProvider;

        var go: std.atomic.Value(bool) = .init(true);
        _ = try keeper_mod.copy(self.allocator, fetcher, store, cid, holders[0..n], &go);
    }

    fn addHolder(out: *[fetcher_mod.max_holders]NodeID, n: *usize, id: NodeID) void {
        if (n.* >= out.len) return;
        for (out[0..n.*]) |x| if (x.eql(id)) return;
        out[n.*] = id;
        n.* += 1;
    }

    /// A connection to `peer_id`, located through the routing table or a
    /// DHT lookup. Pooled by the connection manager: deinit it after use.
    pub fn connectTo(self: *BlockManager, peer_id: NodeID) !network.Connection {
        const peer = try self.findPeer(peer_id);
        return self.net.connectToPeerMulti(peer.addresses[0..peer.addrs_count], self.dht_node.swarm_key, peer_id);
    }

    // ---- What the folder layer (fs) asks of the network ----

    /// Every peer the routing table knows (caller frees).
    pub fn knownPeers(self: *BlockManager, allocator: std.mem.Allocator) ![]NodeID {
        const node = self.dht_node;
        node.mutex.lock();
        defer node.mutex.unlock();
        const peers = try node.routing_table.getAllPeers();
        defer node.routing_table.allocator.free(peers);
        const ids = try allocator.alloc(NodeID, peers.len);
        for (peers, ids) |p, *out| out.* = p.id;
        return ids;
    }

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

    /// The fetcher's network side: one GET_BLOCK to `peer`. A holder not in
    /// the routing table yet (a node just started, the author not met) is
    /// looked up once; if that fails, the fetcher's backoff keeps it from
    /// being tried again for a while.
    fn getBlockFrom(ctx: *anyopaque, peer: NodeID, cid: *const fetcher_mod.Cid, allocator: std.mem.Allocator) anyerror!?[]u8 {
        const self: *BlockManager = @ptrCast(@alignCast(ctx));
        const conn = self.connectKnown(peer) catch |err| switch (err) {
            error.ProviderUnreachable => try self.connectTo(peer),
            else => return err,
        };
        defer conn.deinit();
        const data = (try self.dht_node.fetchBlock(conn, cid.*)) orelse return null;
        defer self.dht_node.allocator.free(data);
        return try allocator.dupe(u8, data);
    }

    // ---- The holder registry's view of discovery ----

    /// A peer's announced roles (PING/PONG), or null when unknown.
    fn rolesOfPeered(ctx: *anyopaque, peer: NodeID) ?u8 {
        const node: *dht.Node = @ptrCast(@alignCast(ctx));
        return node.peerRoles(peer);
    }

    /// Copies the routing table's peer IDs.
    fn knownIDsOf(ctx: *anyopaque, out: []NodeID) usize {
        const node: *dht.Node = @ptrCast(@alignCast(ctx));
        return node.copyPeerIDs(out);
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
