const std = @import("std");
const id = @import("id.zig");
const kbucket = @import("kbucket.zig");
const rpc = @import("rpc.zig");
const network = @import("../network/mod.zig");

pub const Alpha = 3;

/// State for an iterative lookup of a NodeID.
pub const LookupState = struct {
    allocator: std.mem.Allocator,
    target: id.NodeID,
    /// List of peers sorted by distance to target.
    best_peers: std.ArrayListUnmanaged(LookupPeer),
    /// Set of Peer IDs we've already successfully queried.
    queried: std.AutoHashMapUnmanaged(id.NodeID, void),
    /// Set of Peer IDs currently being queried.
    in_flight: std.AutoHashMapUnmanaged(id.NodeID, void),
    /// Set of Peer IDs that failed to respond.
    failed: std.AutoHashMapUnmanaged(id.NodeID, void),

    pub const LookupPeer = struct {
        info: kbucket.PeerInfo,
        queried: bool = false,
        replied: bool = false,
    };

    pub fn init(allocator: std.mem.Allocator, target: id.NodeID, initial_peers: []const kbucket.PeerInfo) !LookupState {
        var self = LookupState{
            .allocator = allocator,
            .target = target,
            .best_peers = try std.ArrayListUnmanaged(LookupPeer).initCapacity(allocator, initial_peers.len),
            .queried = .{},
            .in_flight = .{},
            .failed = .{},
        };

        for (initial_peers) |info| {
            try self.addPeer(info);
        }

        return self;
    }

    pub fn deinit(self: *LookupState) void {
        self.best_peers.deinit(self.allocator);
        self.queried.deinit(self.allocator);
        self.in_flight.deinit(self.allocator);
        self.failed.deinit(self.allocator);
    }

    pub fn addPeer(self: *LookupState, info: kbucket.PeerInfo) !void {
        if (self.queried.contains(info.id) or self.failed.contains(info.id)) return;

        // Don't add if already in best_peers
        for (self.best_peers.items) |p| {
            if (p.info.id.eql(info.id)) return;
        }

        try self.best_peers.append(self.allocator, .{ .info = info });
        self.sortPeers();
    }

    fn sortPeers(self: *LookupState) void {
        const Context = struct {
            target: id.NodeID,
            pub fn lessThan(ctx: @This(), a: LookupPeer, b: LookupPeer) bool {
                const dist_a = a.info.id.distance(ctx.target);
                const dist_b = b.info.id.distance(ctx.target);
                for (0..32) |i| {
                    if (dist_a.bytes[i] < dist_b.bytes[i]) return true;
                    if (dist_a.bytes[i] > dist_b.bytes[i]) return false;
                }
                return false;
            }
        };

        std.mem.sort(LookupPeer, self.best_peers.items, Context{ .target = self.target }, Context.lessThan);
    }

    /// Selects up to Alpha peers that haven't been queried yet.
    pub fn nextPeersToQuery(self: *LookupState) ![]kbucket.PeerInfo {
        var count: usize = 0;
        var result = std.ArrayListUnmanaged(kbucket.PeerInfo){};
        errdefer result.deinit(self.allocator);

        for (self.best_peers.items) |*p| {
            if (!p.queried and !self.in_flight.contains(p.info.id)) {
                try result.append(self.allocator, p.info);
                try self.in_flight.put(self.allocator, p.info.id, {});
                count += 1;
                if (count >= Alpha) break;
            }
        }
        return result.toOwnedSlice(self.allocator);
    }

    pub fn reportReply(self: *LookupState, sender_id: id.NodeID, closer_peers: []const kbucket.PeerInfo) !void {
        _ = self.in_flight.remove(sender_id);
        try self.queried.put(self.allocator, sender_id, {});

        for (self.best_peers.items) |*p| {
            if (p.info.id.eql(sender_id)) {
                p.queried = true;
                p.replied = true;
                break;
            }
        }

        for (closer_peers) |info| {
            try self.addPeer(info);
        }

        // Keep only top K results
        if (self.best_peers.items.len > kbucket.K) {
            self.best_peers.shrinkAndFree(self.allocator, kbucket.K);
        }
    }

    pub fn reportFailure(self: *LookupState, sender_id: id.NodeID) void {
        _ = self.in_flight.remove(sender_id);
        self.failed.put(self.allocator, sender_id, {}) catch {};

        // Remove from best_peers
        for (self.best_peers.items, 0..) |p, i| {
            if (p.info.id.eql(sender_id)) {
                _ = self.best_peers.orderedRemove(i);
                break;
            }
        }
    }

    pub fn isFinished(self: *LookupState) bool {
        // Finished if:
        // 1. We have nothing in flight.
        // AND
        // 2. Either we have no more unqueried peers.
        // 3. Or the K closest peers have all replied.

        if (self.in_flight.count() > 0) return false;

        var queried_count: usize = 0;
        var unqueried_found = false;
        for (self.best_peers.items) |p| {
            if (p.replied) {
                queried_count += 1;
            } else if (!p.queried) {
                unqueried_found = true;
            }
            if (queried_count >= kbucket.K) return true;
        }

        return !unqueried_found;
    }
};
