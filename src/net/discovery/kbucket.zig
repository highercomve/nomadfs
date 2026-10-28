const std = @import("std");
const sync = @import("../../sync.zig");
const NodeID = @import("../id.zig").NodeID;
const network = @import("../transport/mod.zig");

pub const K = 20;
pub const MAX_PEER_ADDRESSES = 8;

pub const AddrSource = enum(u8) { hearsay, announced, observed };

pub const PeerInfo = struct {
    id: NodeID,
    addresses: [MAX_PEER_ADDRESSES]network.Address = undefined,
    sources: [MAX_PEER_ADDRESSES]AddrSource = [_]AddrSource{.observed} ** MAX_PEER_ADDRESSES,
    learned: [MAX_PEER_ADDRESSES]i64 = [_]i64{0} ** MAX_PEER_ADDRESSES,
    addrs_count: u8 = 0,
    last_seen: i64,

    pub fn addAddress(self: *PeerInfo, addr: network.Address) bool {
        return self.addAddressFrom(addr, .observed, self.last_seen);
    }

    pub fn addAddressFrom(self: *PeerInfo, addr: network.Address, source: AddrSource, now: i64) bool {
        for (0..self.addrs_count) |i| {
            if (!addressesMatch(self.addresses[i], addr)) continue;
            const raised = @intFromEnum(source) > @intFromEnum(self.sources[i]);
            if (raised) self.sources[i] = source;
            self.learned[i] = @max(self.learned[i], now);
            return raised;
        }
        var slot: usize = self.addrs_count;
        if (slot == MAX_PEER_ADDRESSES) {
            slot = 0;
            for (1..MAX_PEER_ADDRESSES) |i| {
                if (@intFromEnum(self.sources[i]) < @intFromEnum(self.sources[slot]) or
                    (self.sources[i] == self.sources[slot] and self.learned[i] < self.learned[slot])) slot = i;
            }
            if (@intFromEnum(source) < @intFromEnum(self.sources[slot]) or
                (source == .hearsay and source == self.sources[slot])) return false;
        } else self.addrs_count += 1;
        self.addresses[slot] = addr;
        self.sources[slot] = source;
        self.learned[slot] = now;
        return true;
    }

    pub fn mergeAddresses(self: *PeerInfo, other: PeerInfo) void {
        for (0..other.addrs_count) |i| {
            _ = self.addAddressFrom(other.addresses[i], other.sources[i], other.learned[i]);
        }
    }

    pub fn getBestAddress(self: PeerInfo) network.Address {
        if (self.addrs_count == 0) return network.Address.initIp4(.{ 0, 0, 0, 0 }, 0);

        var best_addr = self.addresses[0];
        var best_prio = @import("../local_addrs.zig").addressPriority(best_addr);

        for (1..self.addrs_count) |i| {
            const addr = self.addresses[i];
            const prio = @import("../local_addrs.zig").addressPriority(addr);
            if (prio < best_prio) {
                best_addr = addr;
                best_prio = prio;
            }
        }
        return best_addr;
    }
};

fn addressesMatch(a: network.Address, b: network.Address) bool {
    return a.eql(b);
}

const Bucket = struct {
    peers: std.ArrayList(PeerInfo),
    replacements: std.ArrayList(PeerInfo),
    allocator: std.mem.Allocator,
    last_updated: i64,

    pub fn init(allocator: std.mem.Allocator) Bucket {
        return Bucket{
            .peers = .empty,
            .replacements = .empty,
            .allocator = allocator,
            .last_updated = sync.timestamp(),
        };
    }

    pub fn deinit(self: *Bucket) void {
        self.peers.deinit(self.allocator);
        self.replacements.deinit(self.allocator);
    }

    // Returns true if added/updated, false if bucket full and peer added to replacement cache
    pub fn add(self: *Bucket, incoming: PeerInfo) !bool {
        // The routing table never stores third-party addresses, even if a caller forgets.
        var peer = PeerInfo{ .id = incoming.id, .last_seen = incoming.last_seen };
        for (0..incoming.addrs_count) |i| {
            if (incoming.sources[i] == .hearsay) continue;
            if (@import("../local_addrs.zig").classify(incoming.addresses[i]) == .invalid) continue;
            _ = peer.addAddressFrom(incoming.addresses[i], incoming.sources[i], incoming.learned[i]);
        }
        if (peer.addrs_count == 0) return true;
        self.last_updated = sync.timestamp();
        // Check if exists in peers (Main Bucket), update
        for (self.peers.items, 0..) |*p, i| {
            if (p.id.eql(peer.id)) {
                // Move to tail (most recently seen)
                p.last_seen = peer.last_seen;
                p.mergeAddresses(peer);

                const removed = self.peers.orderedRemove(i);
                try self.peers.append(self.allocator, removed);
                return true;
            }
        }

        // Check if exists in replacements, update
        for (self.replacements.items, 0..) |*p, i| {
            if (p.id.eql(peer.id)) {
                p.last_seen = peer.last_seen;
                p.mergeAddresses(peer);
                const removed = self.replacements.orderedRemove(i);
                try self.replacements.append(self.allocator, removed);
                return false;
            }
        }

        // If main bucket has space, add it
        if (self.peers.items.len < K) {
            try self.peers.append(self.allocator, peer);
            return true;
        }

        // Main bucket full. Add to replacement cache.
        if (self.replacements.items.len < K) {
            try self.replacements.append(self.allocator, peer);
        } else {
            // Replacement cache full.
            // MVP: Discard oldest replacement (head)
            std.log.warn("KBucket replacement cache full, evicting oldest peer", .{});
            _ = self.replacements.orderedRemove(0);
            try self.replacements.append(self.allocator, peer);
        }

        return false;
    }

    pub fn remove(self: *Bucket, peer_id: NodeID) bool {
        for (self.peers.items, 0..) |*p, i| {
            if (p.id.eql(peer_id)) {
                _ = self.peers.orderedRemove(i);

                // Promote from replacements if available
                if (self.replacements.items.len > 0) {
                    // Take the most recently seen replacement (tail)
                    if (self.replacements.pop()) |replacement| {
                        self.peers.append(self.allocator, replacement) catch {};
                    }
                }
                return true;
            }
        }

        // Also check replacements
        for (self.replacements.items, 0..) |*p, i| {
            if (p.id.eql(peer_id)) {
                _ = self.replacements.orderedRemove(i);
                return true;
            }
        }
        return false;
    }

    pub fn getLRU(self: *Bucket) ?PeerInfo {
        if (self.peers.items.len == 0) return null;
        return self.peers.items[0];
    }
};

pub const RoutingTable = struct {
    local_id: NodeID,
    buckets: [256]Bucket, // Bucket i stores peers with common prefix length i
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, local_id: NodeID) RoutingTable {
        var rt = RoutingTable{
            .local_id = local_id,
            .buckets = undefined,
            .allocator = allocator,
        };
        for (0..256) |i| {
            rt.buckets[i] = Bucket.init(allocator);
        }
        return rt;
    }

    pub fn deinit(self: *RoutingTable) void {
        for (&self.buckets) |*b| {
            b.deinit();
        }
    }

    /// Adds or refreshes a peer. Our own ID is never stored; peer IDs can
    /// come from the network, so this is a normal rejection, not an assert.
    pub fn addPeer(self: *RoutingTable, peer: PeerInfo) !bool {
        if (peer.id.eql(self.local_id)) return false;
        return try self.bucketFor(peer.id).add(peer);
    }

    pub fn getLRU(self: *RoutingTable, peer_id: NodeID) ?PeerInfo {
        return self.bucketFor(peer_id).getLRU();
    }

    pub fn markDisconnected(self: *RoutingTable, peer_id: NodeID) void {
        _ = self.bucketFor(peer_id).remove(peer_id);
    }

    /// Whether `peer_id` is in the main bucket (replacements do not count).
    pub fn contains(self: *RoutingTable, peer_id: NodeID) bool {
        for (self.bucketFor(peer_id).peers.items) |p| {
            if (p.id.eql(peer_id)) return true;
        }
        return false;
    }

    /// Returns a copy of `peer_id`'s entry in the main bucket, if present.
    pub fn getPeer(self: *RoutingTable, peer_id: NodeID) ?PeerInfo {
        for (self.bucketFor(peer_id).peers.items) |p| {
            if (p.id.eql(peer_id)) return p;
        }
        return null;
    }

    fn bucketFor(self: *RoutingTable, peer_id: NodeID) *Bucket {
        const cpl = self.local_id.commonPrefixLen(peer_id);
        return &self.buckets[@min(cpl, 255)];
    }

    pub fn getClosestPeers(self: *RoutingTable, target: NodeID, count: usize) ![]PeerInfo {
        std.debug.assert(count > 0);
        var all_peers: std.ArrayListUnmanaged(PeerInfo) = .empty;
        defer all_peers.deinit(self.allocator);

        for (&self.buckets) |*b| {
            try all_peers.appendSlice(self.allocator, b.peers.items);
        }

        // Sort by distance to target
        const Context = struct {
            target: NodeID,
            pub fn lessThan(ctx: @This(), a: PeerInfo, b: PeerInfo) bool {
                const dist_a = a.id.distance(ctx.target);
                const dist_b = b.id.distance(ctx.target);
                for (0..32) |i| {
                    if (dist_a.bytes[i] < dist_b.bytes[i]) return true;
                    if (dist_a.bytes[i] > dist_b.bytes[i]) return false;
                }
                return false;
            }
        };

        std.mem.sort(PeerInfo, all_peers.items, Context{ .target = target }, Context.lessThan);

        const result_len = @min(count, all_peers.items.len);
        return self.allocator.dupe(PeerInfo, all_peers.items[0..result_len]);
    }

    pub fn getAllPeers(self: *RoutingTable) ![]PeerInfo {
        var all_peers: std.ArrayListUnmanaged(PeerInfo) = .empty;
        defer all_peers.deinit(self.allocator);

        for (&self.buckets) |*b| {
            try all_peers.appendSlice(self.allocator, b.peers.items);
        }
        return self.allocator.dupe(PeerInfo, all_peers.items);
    }

    pub fn dump(self: *RoutingTable) void {
        std.debug.print("--- Routing Table Dump ---\n", .{});
        std.debug.print("Local ID: {x}\n", .{self.local_id.bytes});
        var total_peers: usize = 0;
        for (&self.buckets, 0..) |*b, i| {
            if (b.peers.items.len > 0) {
                std.debug.print("Bucket {d}: {d} peers (+{d} replacements)\n", .{ i, b.peers.items.len, b.replacements.items.len });
                for (b.peers.items) |p| {
                    std.debug.print("  - Peer: {x}\n", .{p.id.bytes});
                    for (0..p.addrs_count) |addr_idx| {
                        std.debug.print("    -> {f}\n", .{p.addresses[addr_idx]});
                    }
                }
                total_peers += b.peers.items.len;
            }
        }
        std.debug.print("Total Peers: {d}\n", .{total_peers});
        std.debug.print("--------------------------\n", .{});
    }
};

test "RoutingTable ignores our own ID instead of asserting" {
    const local_id = NodeID{ .bytes = [_]u8{7} ** 32 };
    var rt = RoutingTable.init(std.testing.allocator, local_id);
    defer rt.deinit();

    try std.testing.expect(!try rt.addPeer(.{ .id = local_id, .last_seen = 0 }));
    try std.testing.expect(!rt.contains(local_id));
    rt.markDisconnected(local_id);
    try std.testing.expect(rt.getLRU(local_id) == null);
}

test "address provenance replaces weakest oldest and never downgrades duplicates" {
    var peer = PeerInfo{ .id = .{ .bytes = [_]u8{1} ** 32 }, .last_seen = 1 };
    for (0..MAX_PEER_ADDRESSES) |i| {
        _ = peer.addAddressFrom(network.Address.initIp4(.{ 192, 0, 2, @intCast(i + 1) }, 9), .announced, @intCast(i));
    }
    const real = network.Address.initIp4(.{ 127, 0, 0, 1 }, 13500);
    try std.testing.expect(peer.addAddressFrom(real, .observed, 10));
    try std.testing.expect(peer.addresses[0].eql(real));
    try std.testing.expect(!peer.addAddressFrom(real, .hearsay, 11));
    try std.testing.expectEqual(AddrSource.observed, peer.sources[0]);
    var merged = PeerInfo{ .id = peer.id, .last_seen = 1 };
    merged.mergeAddresses(peer);
    try std.testing.expectEqualSlices(AddrSource, &peer.sources, &merged.sources);
    for (0..MAX_PEER_ADDRESSES) |i| peer.sources[i] = .observed;
    try std.testing.expect(!peer.addAddressFrom(network.Address.initIp4(.{ 198, 51, 100, 1 }, 9), .hearsay, 20));
    try std.testing.expect(peer.addAddressFrom(network.Address.initIp4(.{ 198, 51, 100, 2 }, 9), .observed, 21));
}

test "bucket strips hearsay on insertion and merge" {
    var bucket = Bucket.init(std.testing.allocator);
    defer bucket.deinit();
    var peer = PeerInfo{ .id = .{ .bytes = [_]u8{1} ** 32 }, .last_seen = 1 };
    _ = peer.addAddressFrom(network.Address.initIp4(.{ 192, 0, 2, 1 }, 9), .hearsay, 1);
    _ = try bucket.add(peer);
    try std.testing.expectEqual(@as(usize, 0), bucket.peers.items.len);
    _ = peer.addAddressFrom(network.Address.initIp4(.{ 127, 0, 0, 1 }, 13500), .observed, 2);
    _ = try bucket.add(peer);
    _ = try bucket.add(peer);
    try std.testing.expectEqual(@as(u8, 1), bucket.peers.items[0].addrs_count);
    try std.testing.expectEqual(AddrSource.observed, bucket.peers.items[0].sources[0]);
}
