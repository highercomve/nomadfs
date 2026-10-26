const std = @import("std");
const network = @import("../net/transport/mod.zig");
const dht = @import("../net/discovery/mod.zig");
const NodeID = @import("../net/id.zig").NodeID;
const storage = @import("../storage/mod.zig");
const quorum = @import("quorum.zig");
const RepairManager = @import("repair.zig").RepairManager;
const walk = storage.dag.walk;

/// Stores files as Merkle DAGs and moves them between nodes.
///
/// Provider records: `put` registers this node, with the peers closest to the
/// root CID, as a holder of the blocks. `get` collects the holders, finds
/// their addresses through the DHT and copies the missing blocks from the
/// first one that can serve them. Records expire after
/// providers.default_ttl_s; call `announce` periodically to keep them.
pub const BlockManager = struct {
    allocator: std.mem.Allocator,
    net: *network.manager.ConnectionManager,
    dht_node: *dht.Node,
    store: ?*storage.engine.StorageEngine, // Nullable for mobile
    quorum: quorum.QuorumConfig,
    layout: storage.dag.Layout = .Balanced,

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
        if (!quorum.isWriteSatisfied(self.quorum, acks_u8)) return error.QuorumNotReached;
    }

    /// Writes the file rooted at `root` to `writer` (anything with writeAll)
    /// and returns its size. Missing blocks are fetched from the provider
    /// first, so a failure never leaves partial output in `writer`.
    pub fn get(self: *BlockManager, root: []const u8, writer: anytype, options: walk.ReadOptions) !u64 {
        const store = self.store orelse return error.StorageDisabled;
        if (!try walk.isComplete(self.allocator, store, root)) {
            try self.fetch(root);
        }
        return walk.readFile(self.allocator, store, root, writer, options);
    }

    /// Copies every block of `root` that is missing locally from the first
    /// provider able to serve them. Unreachable or incomplete providers are
    /// skipped; the last failure is returned if none succeeds.
    pub fn fetch(self: *BlockManager, root: []const u8) !void {
        const key = NodeID{ .bytes = try walk.cidFromSlice(root) };

        const providers = try self.dht_node.findProviders(key);
        defer self.allocator.free(providers);
        if (providers.len == 0) return error.NoProvider;

        var last_err: anyerror = error.NoProvider;
        for (providers) |provider| {
            self.fetchFrom(provider, root) catch |err| {
                std.debug.print("BlockManager: provider {x} failed: {any}\n", .{ provider.bytes[0..4], err });
                last_err = err;
                continue;
            };
            return;
        }
        return last_err;
    }

    fn fetchFrom(self: *BlockManager, provider: NodeID, root: []const u8) !void {
        const store = self.store orelse return error.StorageDisabled;
        const peer = try self.findPeer(provider);
        const conn = try self.net.connectToPeerMulti(peer.addresses[0..peer.addrs_count], self.dht_node.swarm_key, provider);
        defer conn.deinit();

        _ = try RepairManager.sync(self.allocator, self.dht_node, store, conn, root);
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
