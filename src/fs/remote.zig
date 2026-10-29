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

pub const HealthGate = struct {
    const Entry = struct {
        peer: NodeID,
        down_until_ms: i64 = 0,
        fails: u32 = 0,
    };
    mutex: sync.Mutex = .{},
    entries: [64]Entry = [_]Entry{.{ .peer = .{ .bytes = [_]u8{0} ** 32 } }} ** 64,
    count: usize = 0,

    pub fn isDown(self: *HealthGate, peer: NodeID) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        const now = sync.monotonicMillis();
        for (self.entries[0..self.count]) |e| {
            if (e.peer.eql(peer)) {
                return now < e.down_until_ms;
            }
        }
        return false;
    }

    pub fn markDown(self: *HealthGate, peer: NodeID) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        const now = sync.monotonicMillis();
        for (self.entries[0..self.count]) |*e| {
            if (e.peer.eql(peer)) {
                e.fails +|= 1;
                const shift: u6 = @intCast(@min(e.fails - 1, 10));
                const backoff = @min(@as(i64, 5000) * (@as(i64, 1) << shift), 60000);
                e.down_until_ms = now + backoff;
                return;
            }
        }
        const backoff: i64 = 5000;
        const entry = Entry{
            .peer = peer,
            .down_until_ms = now + backoff,
            .fails = 1,
        };
        if (self.count < self.entries.len) {
            self.entries[self.count] = entry;
            self.count += 1;
        } else {
            var evict_idx: usize = 0;
            for (self.entries, 0..) |e, i| {
                if (now >= e.down_until_ms) {
                    evict_idx = i;
                    break;
                }
            }
            self.entries[evict_idx] = entry;
        }
    }

    pub fn markUp(self: *HealthGate, peer: NodeID) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        for (self.entries[0..self.count], 0..) |*e, i| {
            if (e.peer.eql(peer)) {
                self.count -= 1;
                self.entries[i] = self.entries[self.count];
                return;
            }
        }
    }

    pub fn reset(self: *HealthGate) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.count = 0;
    }
};

pub var health: HealthGate = .{};

pub const Remote = struct {
    block_manager: *cluster.BlockManager,
    store: *storage.engine.StorageEngine,
    peer: NodeID,
    /// The file being read, when known: the fetcher remembers misses per
    /// file.
    root: ?tree.Cid = null,

    pub fn loader(self: *Remote) tree.Loader {
        return .{ .ctx = self, .loadFn = load };
    }

    /// Blocks come through the fetcher (cluster/fetcher.zig), from this
    /// one device.
    fn load(ctx: *anyopaque, cid: *const tree.Cid, allocator: std.mem.Allocator) anyerror![]u8 {
        const self: *Remote = @ptrCast(@alignCast(ctx));
        if (try self.store.get(cid, allocator)) |block| return @constCast(block.data);
        if (health.isDown(self.peer)) return error.PeerDown;
        const fetcher = &(self.block_manager.fetcher orelse return error.StorageDisabled);
        const bytes = fetcher.fetch(&(self.root orelse cid.*), cid, &.{self.peer}, allocator) catch |err| {
            if (err != error.BlockNotFound) health.markDown(self.peer);
            return err;
        };
        health.markUp(self.peer);
        return bytes;
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
        const dht_node = self.block_manager.dht_node;
        const conn = try self.block_manager.connectTo(self.peer);
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
        health.markUp(self.peer);
        self.noteSaidKept(dht_node, reply_backup);
        return res;
    }

    /// What the reply's `backup` field said (fs/backup.zig): this peer
    /// keeps copies of those owners' folders. The holder registry records
    /// each one (cluster/holders.zig), so reads can go to the copy when
    /// its owner is offline. Best effort: errors are all ignored.
    fn noteSaidKept(self: *Remote, dht_node: *DhtNode, bytes: []const u8) void {
        const trust = dht_node.trust_store orelse return;
        const holders_ptr = if (self.block_manager.holders) |*h| h else return;
        var info = backup.decodeInfo(dht_node.allocator, bytes) catch return;
        defer info.deinit();
        for (info.held) |h| {
            const entry = trust.lookup(.{ .bytes = h.owner }) orelse continue;
            holders_ptr.noteKeeps(self.peer, NodeID.fromPublicKey(entry.transport_key));
        }
    }
};

/// A Loader over several devices that may hold the file `root` (the device
/// that added a swarm file first): the fetcher picks among them per block.
pub const MultiRemote = struct {
    block_manager: *cluster.BlockManager,
    store: *storage.engine.StorageEngine,
    peers: []const NodeID,
    root: tree.Cid,

    pub fn loader(self: *MultiRemote) tree.Loader {
        return .{ .ctx = self, .loadFn = load };
    }

    fn load(ctx: *anyopaque, cid: *const tree.Cid, allocator: std.mem.Allocator) anyerror![]u8 {
        const self: *MultiRemote = @ptrCast(@alignCast(ctx));
        const fetcher = &(self.block_manager.fetcher orelse return error.StorageDisabled);
        return fetcher.fetch(&self.root, cid, self.peers, allocator);
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

/// Reads part of a share's file: the local store first, then likely
/// holders — the sharing device, then the devices the holder registry
/// says keep copies of its owner's folders (cluster/holders.zig); through
/// a read-ahead when one is attached. SHARE directory listings stay with
/// the sharing device (loader(), shares()). The registry is consulted
/// only past the health gate, so gated reads never touch the network side.
pub fn readShareAt(
    allocator: std.mem.Allocator,
    block_manager: *cluster.BlockManager,
    store: *storage.engine.StorageEngine,
    read_ahead: ?*readahead_mod.ReadAhead,
    peer: NodeID,
    root: tree.Cid,
    offset: u64,
    dest: []u8,
) !usize {
    if (read_ahead) |ra| {
        var buffer = holdersBuffer();
        return ra.readAt(allocator, holderListFor(block_manager, peer, &buffer), root, offset, dest);
    }
    var share = ShareLoader{ .block_manager = block_manager, .store = store, .peer = peer, .root = root };
    return tree.readAt(allocator, share.loader(), root, offset, dest);
}

/// A Loader for a share file: lists the likely holders at the first
/// missing block (the registry may have learned new keepers meanwhile),
/// then lets the fetcher pick per block.
pub const ShareLoader = struct {
    block_manager: *cluster.BlockManager,
    store: *storage.engine.StorageEngine,
    peer: NodeID,
    root: tree.Cid,
    listed: bool = false,
    holders_buffer: [fetcher_mod.max_holders]NodeID = holdersBuffer(),
    peers: []const NodeID = &.{},

    pub fn loader(self: *ShareLoader) tree.Loader {
        return .{ .ctx = self, .loadFn = load };
    }

    fn load(ctx: *anyopaque, cid: *const tree.Cid, allocator: std.mem.Allocator) anyerror![]u8 {
        const self: *ShareLoader = @ptrCast(@alignCast(ctx));
        if (try self.store.get(cid, allocator)) |block| return @constCast(block.data);
        if (health.isDown(self.peer)) return error.PeerDown;
        if (!self.listed) {
            self.peers = holderListFor(self.block_manager, self.peer, &self.holders_buffer);
            self.listed = true;
        }
        const fetcher_ptr = &(self.block_manager.fetcher orelse return error.StorageDisabled);
        return fetcher_ptr.fetch(&self.root, cid, self.peers, allocator);
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

test "health gate: markDown backs off and markUp clears" {
    health.reset();
    const peer = NodeID{ .bytes = [_]u8{0x99} ** 32 };
    try std.testing.expect(!health.isDown(peer));
    health.markDown(peer);
    try std.testing.expect(health.isDown(peer));
    health.markUp(peer);
    try std.testing.expect(!health.isDown(peer));
}
