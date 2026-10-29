//! Browsing another device's shares. A Remote is a tree.Loader that serves
//! blocks from the local store and fetches missing ones from the device on
//! first use, verifying each against its CID before keeping it. The local
//! store is therefore the cache: a file read once reads offline afterwards.

const std = @import("std");
const cluster = @import("../cluster/mod.zig");
const NodeID = @import("../net/id.zig").NodeID;
const storage = @import("../storage/mod.zig");
const sync = @import("../sync.zig");
const tree = @import("tree.zig");

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
        const backup = try allocator.dupe(u8, reply.backup);
        errdefer allocator.free(backup);
        const res = Shares{
            .nickname = nickname,
            .listing = try tree.decodeListing(allocator, reply.listing),
            .device_id = device_id,
            .backup = backup,
        };
        health.markUp(self.peer);
        return res;
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
