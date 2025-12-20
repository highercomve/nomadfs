const std = @import("std");
const NodeID = @import("id.zig").NodeID;

pub const K = 20;

pub const PeerInfo = struct {
    id: NodeID,
    address: std.net.Address,
    last_seen: i64,
};

const Bucket = struct {
    peers: std.ArrayListUnmanaged(PeerInfo),
    replacements: std.ArrayListUnmanaged(PeerInfo),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) Bucket {
        return Bucket{
            .peers = std.ArrayListUnmanaged(PeerInfo){},
            .replacements = std.ArrayListUnmanaged(PeerInfo){},
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Bucket) void {
        self.peers.deinit(self.allocator);
        self.replacements.deinit(self.allocator);
    }

    // Returns true if added/updated, false if bucket full and peer added to replacement cache
    pub fn add(self: *Bucket, peer: PeerInfo) !bool {
        // Check if exists in peers (Main Bucket), update
        for (self.peers.items, 0..) |*p, i| {
            if (p.id.eql(peer.id)) {
                // Move to tail (most recently seen)
                p.last_seen = peer.last_seen;
                p.address = peer.address;

                const removed = self.peers.orderedRemove(i);
                try self.peers.append(self.allocator, removed);
                return true;
            }
        }

        // Check if exists in replacements, update
        for (self.replacements.items, 0..) |*p, i| {
            if (p.id.eql(peer.id)) {
                p.last_seen = peer.last_seen;
                p.address = peer.address;
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

    pub fn addPeer(self: *RoutingTable, peer: PeerInfo) !void {
        std.debug.assert(!peer.id.eql(self.local_id));
        const cpl = self.local_id.commonPrefixLen(peer.id);

        const index = @min(cpl, 255);
        std.debug.print("RoutingTable: Adding peer {x} to bucket {d} (CPL: {d})\n", .{peer.id.bytes[0..4], index, cpl});
        _ = try self.buckets[index].add(peer);
    }

    pub fn markDisconnected(self: *RoutingTable, peer_id: NodeID) void {
        const cpl = self.local_id.commonPrefixLen(peer_id);
        const index = @min(cpl, 255);
        const bucket = &self.buckets[index];
        _ = bucket.remove(peer_id);
    }

    pub fn getClosestPeers(self: *RoutingTable, target: NodeID, count: usize) ![]PeerInfo {
        std.debug.assert(count > 0);
        var all_peers = std.ArrayListUnmanaged(PeerInfo){};
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
        var all_peers = std.ArrayListUnmanaged(PeerInfo){};
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
                    std.debug.print("  - Peer: {x} at {f}\n", .{ p.id.bytes, p.address });
                }
                total_peers += b.peers.items.len;
            }
        }
        std.debug.print("Total Peers: {d}\n", .{total_peers});
        std.debug.print("--------------------------\n", .{});
    }
};
