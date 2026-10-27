//! Browsing another device's shares. A Remote is a tree.Loader that serves
//! blocks from the local store and fetches missing ones from the device on
//! first use, verifying each against its CID before keeping it. The local
//! store is therefore the cache: a file read once reads offline afterwards.

const std = @import("std");
const cluster = @import("../cluster/mod.zig");
const NodeID = @import("../net/id.zig").NodeID;
const storage = @import("../storage/mod.zig");
const tree = @import("tree.zig");

pub const Remote = struct {
    block_manager: *cluster.BlockManager,
    store: *storage.engine.StorageEngine,
    peer: NodeID,

    pub fn loader(self: *Remote) tree.Loader {
        return .{ .ctx = self, .loadFn = load };
    }

    fn load(ctx: *anyopaque, cid: *const tree.Cid, allocator: std.mem.Allocator) anyerror![]u8 {
        const self: *Remote = @ptrCast(@alignCast(ctx));
        if (try self.store.get(cid, allocator)) |block| return @constCast(block.data);

        const dht_node = self.block_manager.dht_node;
        const conn = try self.block_manager.connectTo(self.peer);
        defer conn.deinit();
        const remote = (try dht_node.fetchBlock(conn, cid.*)) orelse return error.BlockNotFound;
        defer dht_node.allocator.free(remote);

        // put() rejects bytes that do not hash to `cid`.
        try self.store.put(.{ .cid = cid.*, .data = remote });
        return allocator.dupe(u8, remote);
    }

    pub const Shares = struct {
        nickname: []u8,
        listing: tree.Listing,

        pub fn deinit(self: Shares, allocator: std.mem.Allocator) void {
            allocator.free(self.nickname);
            self.listing.deinit();
        }
    };

    /// The device's nickname and current shares (each entry's cid is that
    /// share's root dir).
    pub fn shares(self: *Remote, allocator: std.mem.Allocator) !Shares {
        const dht_node = self.block_manager.dht_node;
        const conn = try self.block_manager.connectTo(self.peer);
        defer conn.deinit();
        const reply = try dht_node.fetchShares(conn);
        defer dht_node.allocator.free(reply.listing);
        defer dht_node.allocator.free(reply.nickname);

        const nickname = try allocator.dupe(u8, reply.nickname);
        errdefer allocator.free(nickname);
        return .{ .nickname = nickname, .listing = try tree.decodeListing(allocator, reply.listing) };
    }
};

/// Every peer the routing table knows (caller frees).
pub fn knownPeers(block_manager: *cluster.BlockManager, allocator: std.mem.Allocator) ![]NodeID {
    const dht_node = block_manager.dht_node;
    dht_node.mutex.lock();
    defer dht_node.mutex.unlock();
    const peers = try dht_node.routing_table.getAllPeers();
    defer dht_node.routing_table.allocator.free(peers);
    const ids = try allocator.alloc(NodeID, peers.len);
    for (peers, ids) |p, *out| out.* = p.id;
    return ids;
}
