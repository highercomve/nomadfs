//! Browsing another device's shares. A Remote is a tree.Loader that serves
//! blocks from the local store and fetches missing ones from the device on
//! first use, verifying each against its CID before keeping it. The local
//! store is therefore the cache: a file read once reads offline afterwards.

const std = @import("std");
const cluster = @import("../cluster/mod.zig");
const fetcher_mod = @import("../cluster/fetcher.zig");
const NodeID = @import("../net/id.zig").NodeID;
const DhtNode = @import("../net/discovery/mod.zig").Node;
const storage = @import("../storage/mod.zig");
const sync = @import("../sync.zig");
const backup = @import("backup.zig");
const tree = @import("tree.zig");
const readahead_mod = @import("readahead.zig");

/// A tree.Loader over the cluster layer's fetcher (cluster/fetcher.zig):
/// the blocks of the file `root` from `holders`, best first. This module
/// says which file and who may hold it; the fetcher says where each block
/// comes from. Without a block manager (a mount device never connected)
/// every load fails at once with error.PeerDown.
pub const Source = struct {
    block_manager: ?*cluster.BlockManager,
    /// The file being read; misses are remembered per file. Null: each
    /// block counts as its own file.
    root: ?tree.Cid = null,
    holders: []const NodeID,

    pub fn loader(self: *Source) tree.Loader {
        return .{ .ctx = self, .loadFn = load };
    }

    fn load(ctx: *anyopaque, cid: *const tree.Cid, allocator: std.mem.Allocator) anyerror![]u8 {
        const self: *Source = @ptrCast(@alignCast(ctx));
        return fetchFrom(self.block_manager, self.root, cid, self.holders, allocator);
    }
};

fn fetchFrom(block_manager: ?*cluster.BlockManager, root: ?tree.Cid, cid: *const tree.Cid, holders: []const NodeID, allocator: std.mem.Allocator) ![]u8 {
    const bm = block_manager orelse return error.PeerDown;
    const fetcher = &(bm.fetcher orelse return error.StorageDisabled);
    return fetcher.fetch(&(root orelse cid.*), cid, holders, allocator);
}

/// Another device: its shares (GET_SHARES, meaning, so it is asked here),
/// and a loader for its blocks, through the fetcher.
pub const Remote = struct {
    block_manager: ?*cluster.BlockManager,
    peer: NodeID,
    /// The file being read, when known: the fetcher remembers misses per
    /// file.
    root: ?tree.Cid = null,

    pub fn loader(self: *Remote) tree.Loader {
        return .{ .ctx = self, .loadFn = load };
    }

    fn load(ctx: *anyopaque, cid: *const tree.Cid, allocator: std.mem.Allocator) anyerror![]u8 {
        const self: *Remote = @ptrCast(@alignCast(ctx));
        return fetchFrom(self.block_manager, self.root, cid, (&self.peer)[0..1], allocator);
    }

    pub const Shares = struct {
        nickname: []u8,
        listing: tree.Listing,
        device_id: ?NodeID = null,
        /// The SHARES `backup` field, undecoded (fs/backup.zig).
        backup: []u8 = &.{},

        pub fn deinit(self: Shares, allocator: std.mem.Allocator) void {
            allocator.free(self.nickname);
            self.listing.deinit();
            allocator.free(self.backup);
        }
    };

    /// The device's nickname and current shares (each entry's cid is that
    /// share's root dir).
    pub fn shares(self: *Remote, allocator: std.mem.Allocator) !Shares {
        const bm = self.block_manager orelse return error.PeerDown;
        const dht_node = bm.dht_node;
        const conn = try bm.connectTo(self.peer);
        defer conn.deinit();
        const reply = try dht_node.fetchShares(conn);
        defer dht_node.allocator.free(reply.listing);
        defer dht_node.allocator.free(reply.nickname);
        defer dht_node.allocator.free(reply.backup);

        const nickname = try allocator.dupe(u8, reply.nickname);
        errdefer allocator.free(nickname);
        const device_id = conn.getRemoteDeviceID();
        const reply_backup = try allocator.dupe(u8, reply.backup);
        errdefer allocator.free(reply_backup);
        const res = Shares{
            .nickname = nickname,
            .listing = try tree.decodeListing(allocator, reply.listing),
            .device_id = device_id,
            .backup = reply_backup,
        };
        if (bm.fetcher) |*f| f.markUp(self.peer);
        self.noteSaidKept(bm, reply_backup);
        return res;
    }

    /// What the reply's `backup` field said (fs/backup.zig): this peer
    /// keeps copies of those owners' folders. The holder registry records
    /// each one (cluster/holders.zig), so reads can go to the copy when
    /// its owner is offline. Best effort: errors are all ignored.
    fn noteSaidKept(self: *Remote, bm: *cluster.BlockManager, bytes: []const u8) void {
        const dht_node = bm.dht_node;
        const trust = dht_node.trust_store orelse return;
        const holders_ptr = if (bm.holders) |*h| h else return;
        var info = backup.decodeInfo(dht_node.allocator, bytes) catch return;
        defer info.deinit();
        for (info.held) |h| {
            const entry = trust.lookup(.{ .bytes = h.owner }) orelse continue;
            holders_ptr.noteKeeps(self.peer, NodeID.fromPublicKey(entry.transport_key));
        }
    }
};

/// A holder list the size of the fetcher's, ready to fill.
pub fn holdersBuffer() [fetcher_mod.max_holders]NodeID {
    return [_]NodeID{.{ .bytes = [_]u8{0} ** 32 }} ** fetcher_mod.max_holders;
}

/// The likely holders of a share's files (cluster/holders.zig): the
/// sharing device, then devices noted as keeping copies of its owner's
/// folders; never empty (the peer alone when there's nothing noted, when
/// the peer is not this node).
fn holderListFor(block_manager: *cluster.BlockManager, peer: NodeID, out: *[fetcher_mod.max_holders]NodeID) []const NodeID {
    if (block_manager.holders) |*holds| {
        const list = holds.forOrigin(peer, out);
        if (list.len > 0) return list;
    }
    out[0] = peer;
    return out[0..1];
}

/// Reads part of a share's file from its likely holders: the sharing
/// device, then the devices the holder registry says keep copies of its
/// owner's folders (cluster/holders.zig); through a read-ahead when one is
/// attached. Directory listings stay with the sharing device (Remote).
pub fn readShareAt(
    allocator: std.mem.Allocator,
    block_manager: *cluster.BlockManager,
    read_ahead: ?*readahead_mod.ReadAhead,
    peer: NodeID,
    root: tree.Cid,
    offset: u64,
    dest: []u8,
) !usize {
    var buffer = holdersBuffer();
    const holders = holderListFor(block_manager, peer, &buffer);
    if (read_ahead) |ra| return ra.readAt(allocator, holders, root, offset, dest);
    var source = Source{ .block_manager = block_manager, .root = root, .holders = holders };
    return tree.readAt(allocator, source.loader(), root, offset, dest);
}

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
