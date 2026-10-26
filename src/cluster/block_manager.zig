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
/// Writes: `put` stores the file locally, announces this node as provider of
/// the root CID and, when `replication > 0`, pushes the whole DAG to that
/// many peers closest to the CID (PUT_BLOCK, content-verified by the
/// receiver). Reads: `get` collects holder records, finds their addresses
/// through the DHT and copies the missing blocks from the first one that can
/// serve them. Records expire after providers.default_ttl_s; call `announce`
/// periodically to keep them.
pub const BlockManager = struct {
    allocator: std.mem.Allocator,
    net: *network.manager.ConnectionManager,
    dht_node: *dht.Node,
    store: ?*storage.engine.StorageEngine, // Nullable for mobile
    quorum: quorum.QuorumConfig,
    layout: storage.dag.Layout = .Balanced,
    replication: u8,

    pub const Config = struct {
        network: *network.manager.ConnectionManager,
        dht: *dht.Node,
        storage: ?*storage.engine.StorageEngine,
        /// W = number of peers that must acknowledge a provider record.
        /// W = 0 keeps `put` local-only.
        quorum: quorum.QuorumConfig = .{},
        /// N = closest peers the DAG of a new file is pushed to. 0 keeps
        /// puts local (provider records only) -- the default, so a single
        /// node still stores without touching the network.
        replication: u8 = 0,
    };

    pub fn init(allocator: std.mem.Allocator, config: Config) !*BlockManager {
        const self = try allocator.create(BlockManager);
        self.* = .{
            .allocator = allocator,
            .net = config.network,
            .dht_node = config.dht,
            .store = config.storage,
            .quorum = config.quorum,
            .replication = config.replication,
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
        if (self.replication > 0) {
            const acked = self.replicate(root, self.replication) catch |err| blk: {
                // Content is durable locally and announced; replication is
                // best effort and never invalidates a put.
                std.debug.print("BlockManager: replication incomplete: {any}\n", .{err});
                break :blk @as(usize, 0);
            };
            if (acked == 0) {
                std.debug.print("BlockManager: no replica acknowledged the DAG\n", .{});
            }
        }
        return root;
    }

    /// Pushes every block of the DAG rooted at `root` to up to `fanout` of
    /// the peers closest to its CID, counting a peer as a replica once it has
    /// acknowledged the whole DAG. Returns how many peers now hold it. Local
    /// storage remains the source of truth: `put` never fails on replication
    /// problems, it only copies availability.
    pub fn replicate(self: *BlockManager, root: []const u8, fanout: usize) !usize {
        if (self.store == null) return error.StorageDisabled;

        const key = NodeID{ .bytes = try walk.cidFromSlice(root) };
        const closest = try self.dht_node.closestFor(key);
        defer self.allocator.free(closest);

        var acked: usize = 0;
        for (closest) |peer| {
            if (acked >= fanout) break;
            const conn = self.net.connectToPeerMulti(
                peer.addresses[0..peer.addrs_count],
                self.dht_node.swarm_key,
                peer.id,
            ) catch |err| {
                std.debug.print("BlockManager: replica target {x} unreachable: {any}\n", .{ peer.id.bytes[0..4], err });
                continue;
            };
            defer conn.deinit();

            _ = RepairManager.push(self.allocator, self.dht_node, self.store.?, conn, root) catch |err| {
                std.debug.print("BlockManager: replica {x} rejected the DAG: {any}\n", .{ peer.id.bytes[0..4], err });
                continue;
            };
            acked += 1;
        }
        return acked;
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
