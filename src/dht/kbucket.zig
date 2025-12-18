const std = @import("std");
const NodeID = @import("id.zig").NodeID;

pub const K = 20;

pub const PeerInfo = struct {
    id: NodeID,
    address: std.net.Address,
    last_seen: i64,
    online: bool = true,
};

const Bucket = struct {
    peers: std.ArrayListUnmanaged(PeerInfo),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) Bucket {
        return Bucket{
            .peers = std.ArrayListUnmanaged(PeerInfo){},
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Bucket) void {
        self.peers.deinit(self.allocator);
    }

    // Returns true if added/updated, false if bucket full and peer discarded
    pub fn add(self: *Bucket, peer: PeerInfo) !bool {
        // Check if exists, update
        for (self.peers.items, 0..) |*p, i| {
            if (p.id.eql(peer.id)) {
                // Move to tail (most recently seen)
                // For simplicity in MVP, just update last_seen and keep order
                p.last_seen = peer.last_seen;
                p.address = peer.address;

                // Rotate to end
                const removed = self.peers.orderedRemove(i);
                try self.peers.append(self.allocator, removed);
                return true;
            }
        }

        if (self.peers.items.len < K) {
            try self.peers.append(self.allocator, peer);
            return true;
        }

        // Bucket full. In real Kademlia, we ping the LRU (head).
        // MVP: Just discard new peer.
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

        // cpl is 0..256. If cpl is 256, ids are identical (handled by assert above).
        // Index must be < 256.
        const index = @min(cpl, 255);
        _ = try self.buckets[index].add(peer);
    }

    pub fn markDisconnected(self: *RoutingTable, peer_id: NodeID) void {
        const cpl = self.local_id.commonPrefixLen(peer_id);

        const index = @min(cpl, 255);

        const bucket = &self.buckets[index];

        for (bucket.peers.items) |*p| {
            if (p.id.eql(peer_id)) {
                p.online = false;
                p.last_seen = std.time.timestamp();
                return;
            }
        }
    }
    pub fn getClosestPeers(self: *RoutingTable, target: NodeID, count: usize) ![]PeerInfo {
        std.debug.assert(count > 0);
        var result = std.ArrayListUnmanaged(PeerInfo){};
        defer result.deinit(self.allocator); // We will return a slice, so we shouldn't deinit the backing if we were just returning list, but here we copy.

        // Search starting from the specific bucket, spreading out
        // 1. Check bucket[cpl]
        // 2. Check bucket[cpl-1], bucket[cpl+1] etc.

        // Simplified approach: Iterate all buckets, collect, sort.
        // For MVP this is acceptable (K*256 is small).

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
                // Compare distance bytes
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

    pub fn dump(self: *RoutingTable) void {
        std.debug.print("--- Routing Table Dump ---\n", .{});
        std.debug.print("Local ID: {x}\n", .{self.local_id.bytes});
        var total_peers: usize = 0;
        for (&self.buckets, 0..) |*b, i| {
            if (b.peers.items.len > 0) {
                std.debug.print("Bucket {d}: {d} peers\n", .{ i, b.peers.items.len });
                for (b.peers.items) |p| {
                    const status = if (p.online) "ONLINE" else "OFFLINE";
                    std.debug.print("  - Peer: {x} at {f} [{s}]\n", .{ p.id.bytes, p.address, status });
                }
                total_peers += b.peers.items.len;
            }
        }
        std.debug.print("Total Peers: {d}\n", .{total_peers});
        std.debug.print("--------------------------\n", .{});
    }
};
