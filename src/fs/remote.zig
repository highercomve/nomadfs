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

    pub fn loader(self: *Remote) tree.Loader {
        return .{ .ctx = self, .loadFn = load };
    }

    fn load(ctx: *anyopaque, cid: *const tree.Cid, allocator: std.mem.Allocator) anyerror![]u8 {
        const self: *Remote = @ptrCast(@alignCast(ctx));
        if (try self.store.get(cid, allocator)) |block| return @constCast(block.data);

        if (health.isDown(self.peer)) return error.PeerDown;

        const dht_node = self.block_manager.dht_node;
        const conn = self.block_manager.connectTo(self.peer) catch |err| {
            health.markDown(self.peer);
            return err;
        };
        defer conn.deinit();
        const remote = dht_node.fetchBlock(conn, cid.*) catch |err| {
            if (err == error.Timeout) {
                health.markDown(self.peer);
            }
            return err;
        } orelse return error.BlockNotFound;
        defer dht_node.allocator.free(remote);

        // put() rejects bytes that do not hash to `cid`.
        try self.store.put(.{ .cid = cid.*, .data = remote });
        health.markUp(self.peer);
        return allocator.dupe(u8, remote);
    }

    pub const Shares = struct {
        nickname: []u8,
        listing: tree.Listing,
        device_id: ?NodeID = null,

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
        const device_id = conn.getRemoteDeviceID();
        const res = Shares{
            .nickname = nickname,
            .listing = try tree.decodeListing(allocator, reply.listing),
            .device_id = device_id,
        };
        health.markUp(self.peer);
        return res;
    }
};

/// A Loader over several devices: the local store first, then each peer
/// in order until one serves the block (the device that added a swarm
/// file, then anyone who may have cached it).
pub const MultiRemote = struct {
    block_manager: *cluster.BlockManager,
    store: *storage.engine.StorageEngine,
    peers: []const NodeID,

    pub fn loader(self: *MultiRemote) tree.Loader {
        return .{ .ctx = self, .loadFn = load };
    }

    fn load(ctx: *anyopaque, cid: *const tree.Cid, allocator: std.mem.Allocator) anyerror![]u8 {
        const self: *MultiRemote = @ptrCast(@alignCast(ctx));
        if (try self.store.get(cid, allocator)) |block| return @constCast(block.data);
        var last: anyerror = error.BlockNotFound;
        for (self.peers) |peer| {
            var one = Remote{ .block_manager = self.block_manager, .store = self.store, .peer = peer };
            return Remote.load(&one, cid, allocator) catch |err| {
                last = err;
                continue;
            };
        }
        return last;
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
