const std = @import("std");
const id = @import("id.zig");
const kbucket = @import("kbucket.zig");
const rpc = @import("rpc.zig");
const network = @import("../network/mod.zig");
const lookup_mod = @import("lookup.zig");

pub const Node = struct {
    allocator: std.mem.Allocator,
    manager: *network.manager.ConnectionManager,
    routing_table: kbucket.RoutingTable,
    swarm_key: []const u8,
    storage: std.AutoHashMapUnmanaged(id.NodeID, []u8),

    pub fn init(allocator: std.mem.Allocator, manager: *network.manager.ConnectionManager, swarm_key: []const u8) Node {
        return .{
            .allocator = allocator,
            .manager = manager,
            .routing_table = kbucket.RoutingTable.init(allocator, manager.node_id),
            .swarm_key = swarm_key,
            .storage = .{},
        };
    }

    pub fn deinit(self: *Node) void {
        self.routing_table.deinit();
        var it = self.storage.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.value_ptr.*);
        }
        self.storage.deinit(self.allocator);
    }

    pub fn ping(self: *Node, conn: network.Connection) !void {
        const stream = try conn.openStream();
        defer stream.close();

        const msg = rpc.Message{
            .sender_id = self.manager.node_id,
            .payload = .{ .PING = {} },
        };

        try msg.serialize(stream.writer());

        // Wait for PONG
        const response = try rpc.Message.deserialize(self.allocator, stream.reader());
        defer response.deinit(self.allocator);

        if (response.payload == .PONG) {
            std.debug.print("Received PONG from {f}\n", .{response.sender_id});
            try self.routing_table.addPeer(.{
                .id = response.sender_id,
                .address = conn.getPeerAddress(),
                .last_seen = std.time.timestamp(),
            });
        }
    }

    pub fn store(self: *Node, key: id.NodeID, value: []const u8) !void {
        // Ensure we know about the closest nodes
        try self.lookup(key);

        const closest = try self.routing_table.getClosestPeers(key, kbucket.K);
        defer self.allocator.free(closest);

        var stored_count: usize = 0;
        for (closest) |peer| {
            if (peer.id.eql(self.manager.node_id)) {
                try self.localStore(key, value);
                stored_count += 1;
                continue;
            }
            self.sendStore(peer.address, key, value) catch |err| {
                std.debug.print("Failed to store at {f}: {any}\n", .{ peer.address, err });
                continue;
            };
            stored_count += 1;
        }
    }

    pub fn localStore(self: *Node, key: id.NodeID, value: []const u8) !void {
        const v_copy = try self.allocator.dupe(u8, value);
        const res = try self.storage.getOrPut(self.allocator, key);
        if (res.found_existing) {
            self.allocator.free(res.value_ptr.*);
        }
        res.value_ptr.* = v_copy;
    }

    pub fn lookupValue(self: *Node, target: id.NodeID) !?[]u8 {
        // Check local storage first
        if (self.storage.get(target)) |val| {
            return try self.allocator.dupe(u8, val);
        }

        const initial_peers = try self.routing_table.getClosestPeers(target, kbucket.K);
        defer self.allocator.free(initial_peers);

        var state = try lookup_mod.LookupState.init(self.allocator, target, initial_peers);
        defer state.deinit();

        while (!state.isFinished()) {
            const next_peers = try state.nextPeersToQuery();
            defer self.allocator.free(next_peers);

            if (next_peers.len == 0) break;

            for (next_peers) |peer| {
                if (peer.id.eql(self.manager.node_id)) continue;

                const result_or_err = self.sendFindValue(peer.address, target);
                if (result_or_err) |result| {
                    switch (result) {
                        .value => |v| {
                            // Found it!
                            // value is owned by the message inside sendFindValue, but we duped it there?
                            // No, sendFindValue returns FindValueResult which points to message memory?
                            // We need to handle memory carefully.
                            // Let's assume sendFindValue returns allocated copies.
                            return v;
                        },
                        .closer_peers => |closer| {
                            defer self.allocator.free(closer);
                            try state.reportReply(peer.id, closer);
                            for (closer) |p| {
                                if (p.id.eql(self.manager.node_id)) continue;
                                try self.routing_table.addPeer(p);
                            }
                        },
                    }
                } else |_| {
                    state.reportFailure(peer.id);
                }
            }
        }
        return null;
    }

    pub fn sendStore(self: *Node, address: std.net.Address, key: id.NodeID, value: []const u8) !void {
        var conn: network.Connection = undefined;
        var found = false;

        self.manager.mutex.lock();
        for (self.manager.connections.items) |c| {
            if (addressesMatch(c.getPeerAddress(), address)) {
                conn = c;
                found = true;
                break;
            }
        }
        self.manager.mutex.unlock();

        if (!found) {
            conn = try self.manager.connectToPeer(address, self.swarm_key);
        }

        const stream = try conn.openStream();
        defer stream.close();

        const msg = rpc.Message{
            .sender_id = self.manager.node_id,
            .payload = .{ .STORE = .{ .key = key, .value = value } },
        };
        try msg.serialize(stream.writer());
    }

    // Returns either the value (allocated) or closer peers (allocated)
    pub const FindValueResult = union(enum) {
        value: []u8,
        closer_peers: []kbucket.PeerInfo,
    };

    pub fn sendFindValue(self: *Node, address: std.net.Address, key: id.NodeID) !FindValueResult {
        var conn: network.Connection = undefined;
        var found = false;

        self.manager.mutex.lock();
        for (self.manager.connections.items) |c| {
            if (addressesMatch(c.getPeerAddress(), address)) {
                conn = c;
                found = true;
                break;
            }
        }
        self.manager.mutex.unlock();

        if (!found) {
            conn = try self.manager.connectToPeer(address, self.swarm_key);
        }

        const stream = try conn.openStream();
        defer stream.close();

        const msg = rpc.Message{
            .sender_id = self.manager.node_id,
            .payload = .{ .FIND_VALUE = .{ .key = key } },
        };
        try msg.serialize(stream.writer());

        const response = try rpc.Message.deserialize(self.allocator, stream.reader());
        defer response.deinit(self.allocator);

        switch (response.payload) {
            .FIND_VALUE_RESPONSE => |p| {
                switch (p) {
                    .value => |v| {
                        return FindValueResult{ .value = try self.allocator.dupe(u8, v) };
                    },
                    .closer_peers => |peers| {
                        const peers_copy = try self.allocator.alloc(kbucket.PeerInfo, peers.len);
                        @memcpy(peers_copy, peers);
                        return FindValueResult{ .closer_peers = peers_copy };
                    },
                }
            },
            else => return error.InvalidResponse,
        }
    }

    pub fn lookup(self: *Node, target: id.NodeID) !void {
        const initial_peers = try self.routing_table.getClosestPeers(target, kbucket.K);
        defer self.allocator.free(initial_peers);

        var state = try lookup_mod.LookupState.init(self.allocator, target, initial_peers);
        defer state.deinit();

        while (!state.isFinished()) {
            const next_peers = try state.nextPeersToQuery();
            defer self.allocator.free(next_peers);

            if (next_peers.len == 0) break;

            for (next_peers) |peer| {
                if (peer.id.eql(self.manager.node_id)) continue;

                if (self.sendFindNode(peer.address, target)) |closer_peers| {
                    defer self.allocator.free(closer_peers);
                    try state.reportReply(peer.id, closer_peers);

                    // Add discovered peers to routing table
                    for (closer_peers) |p| {
                        if (p.id.eql(self.manager.node_id)) continue;
                        try self.routing_table.addPeer(p);
                    }
                } else |_| {
                    // std.debug.print("Lookup query failed for {}: {any}\n", .{peer.address, err});
                    state.reportFailure(peer.id);
                }
            }
        }
    }

    pub fn sendFindNode(self: *Node, address: std.net.Address, target: id.NodeID) ![]kbucket.PeerInfo {
        var conn: network.Connection = undefined;
        var found = false;

        // Try to find existing connection
        self.manager.mutex.lock();
        for (self.manager.connections.items) |c| {
            if (addressesMatch(c.getPeerAddress(), address)) {
                conn = c;
                found = true;
                break;
            }
        }
        self.manager.mutex.unlock();

        if (!found) {
            conn = try self.manager.connectToPeer(address, self.swarm_key);
        }

        const stream = try conn.openStream();
        defer stream.close();

        const msg = rpc.Message{
            .sender_id = self.manager.node_id,
            .payload = .{ .FIND_NODE = .{ .target = target } },
        };
        try msg.serialize(stream.writer());

        const response = try rpc.Message.deserialize(self.allocator, stream.reader());
        defer response.deinit(self.allocator);

        switch (response.payload) {
            .FIND_NODE_RESPONSE => |p| {
                const peers = try self.allocator.alloc(kbucket.PeerInfo, p.closer_peers.len);
                @memcpy(peers, p.closer_peers);
                return peers;
            },
            else => return error.InvalidResponse,
        }
    }

    pub fn serve(self: *Node, conn: network.Connection) !void {
        const remote_id = conn.getRemoteNodeID();
        defer {
            std.debug.print("Peer disconnected: {f}\n", .{remote_id});
            self.routing_table.markDisconnected(remote_id);
            self.routing_table.dump();
        }

        while (true) {
            const stream = conn.acceptStream() catch |err| {
                // If the connection is closed, stop serving
                if (err == error.SessionClosed or err == error.EndOfStream or err == error.ConnectionResetByPeer) break;
                std.debug.print("Failed to accept stream: {any}\n", .{err});
                break;
            };

            // Handle stream in a new thread
            const handler = struct {
                fn run(n: *Node, s: network.Stream, c: network.Connection) void {
                    defer s.close();
                    n.handleRequest(s, c) catch |h_err| {
                        std.debug.print("Error handling DHT request: {any}\n", .{h_err});
                    };
                }
            };
            const thread = try std.Thread.spawn(.{}, handler.run, .{ self, stream, conn });
            thread.detach();
        }
    }

    fn handleRequest(self: *Node, stream: network.Stream, conn: network.Connection) !void {
        const msg = try rpc.Message.deserialize(self.allocator, stream.reader());
        defer msg.deinit(self.allocator);

        // Add sender to routing table
        self.routing_table.addPeer(.{
            .id = msg.sender_id,
            .address = conn.getPeerAddress(),
            .last_seen = std.time.timestamp(),
        }) catch |err| {
            std.debug.print("Failed to update routing table: {any}\n", .{err});
        };
        self.routing_table.dump();

        switch (msg.payload) {
            .PING => {
                const response = rpc.Message{
                    .sender_id = self.manager.node_id,
                    .payload = .{ .PONG = {} },
                };
                try response.serialize(stream.writer());
            },
            .FIND_NODE => |p| {
                const closer = try self.routing_table.getClosestPeers(p.target, kbucket.K);
                defer self.allocator.free(closer);

                const response = rpc.Message{
                    .sender_id = self.manager.node_id,
                    .payload = .{ .FIND_NODE_RESPONSE = .{ .closer_peers = closer } },
                };
                try response.serialize(stream.writer());
            },
            .FIND_VALUE => |p| {
                if (self.storage.get(p.key)) |val| {
                    // Return value
                    const response = rpc.Message{
                        .sender_id = self.manager.node_id,
                        .payload = .{ .FIND_VALUE_RESPONSE = .{ .value = val } },
                    };
                    try response.serialize(stream.writer());
                } else {
                    // Return closest peers
                    const closer = try self.routing_table.getClosestPeers(p.key, kbucket.K);
                    defer self.allocator.free(closer);

                    const response = rpc.Message{
                        .sender_id = self.manager.node_id,
                        .payload = .{ .FIND_VALUE_RESPONSE = .{ .closer_peers = closer } },
                    };
                    try response.serialize(stream.writer());
                }
            },
            .STORE => |p| {
                try self.localStore(p.key, p.value);
            },
            else => {
                std.debug.print("Received unhandled DHT message type: {any}\n", .{msg.payload});
            },
        }
    }
};

fn addressesMatch(a: std.net.Address, b: std.net.Address) bool {
    if (a.any.family != b.any.family) return false;
    switch (a.any.family) {
        std.posix.AF.INET => {
            return a.in.sa.port == b.in.sa.port and a.in.sa.addr == b.in.sa.addr;
        },
        std.posix.AF.INET6 => {
            return a.in6.sa.port == b.in6.sa.port and std.mem.eql(u8, &a.in6.sa.addr, &b.in6.sa.addr);
        },
        else => return false,
    }
}
