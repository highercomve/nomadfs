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
        _ = try keeper_mod.copy(self.allocator, fetcher, store, cid, holders[0..n], null, &go);
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
        return conn catch |err| if (err == error.Timeout) error.ConnectionTimedOut else err;
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

const rpc_roles = @import("../net/discovery/rpc.zig").Roles;
const rpc_no_swarm = @import("../net/discovery/rpc.zig").no_swarm;
