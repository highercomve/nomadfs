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
    mutex: std.Thread.Mutex,

    pub fn init(allocator: std.mem.Allocator, manager: *network.manager.ConnectionManager, swarm_key: []const u8) Node {
        return .{
            .allocator = allocator,
            .manager = manager,
            .routing_table = kbucket.RoutingTable.init(allocator, manager.node_id),
            .swarm_key = swarm_key,
            .storage = .{},
            .mutex = .{},
        };
    }

    pub fn deinit(self: *Node) void {
        self.mutex.lock();
        defer self.mutex.unlock();
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
            .payload = .{ .PING = .{ .port = self.manager.bound_port } },
        };

        try msg.serialize(stream.writer());

        // Wait for PONG
        const response = try rpc.Message.deserialize(self.allocator, stream.reader());
        defer response.deinit(self.allocator);

        if (response.payload == .PONG) {
            self.mutex.lock();
            defer self.mutex.unlock();
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

        self.mutex.lock();
        const closest = try self.routing_table.getClosestPeers(key, kbucket.K);
        self.mutex.unlock();
        defer self.allocator.free(closest);

        var stored_count: usize = 0;
        for (closest) |peer| {
            if (peer.id.eql(self.manager.node_id)) {
                try self.localStore(key, value);
                stored_count += 1;
                continue;
            }
            self.sendStore(peer.address, key, value, peer.id) catch |err| {
                std.debug.print("Failed to store at {f}: {any}\n", .{ peer.address, err });
                continue;
            };
            stored_count += 1;
        }
    }

    pub fn localStore(self: *Node, key: id.NodeID, value: []const u8) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        const v_copy = try self.allocator.dupe(u8, value);
        const res = try self.storage.getOrPut(self.allocator, key);
        if (res.found_existing) {
            self.allocator.free(res.value_ptr.*);
        }
        res.value_ptr.* = v_copy;
    }

    pub fn lookupValue(self: *Node, target: id.NodeID) !?[]u8 {
        // Check local storage first
        self.mutex.lock();
        if (self.storage.get(target)) |val| {
            const v = try self.allocator.dupe(u8, val);
            self.mutex.unlock();
            return v;
        }
        const initial_peers = try self.routing_table.getClosestPeers(target, kbucket.K);
        self.mutex.unlock();
        defer self.allocator.free(initial_peers);

        var state = try lookup_mod.LookupState.init(self.allocator, target, initial_peers);
        defer state.deinit();

        while (!state.isFinished()) {
            const next_peers = try state.nextPeersToQuery();
            defer self.allocator.free(next_peers);

            if (next_peers.len == 0) break;

            for (next_peers) |peer| {
                if (peer.id.eql(self.manager.node_id)) continue;

                const result_or_err = self.sendFindValue(peer.address, target, peer.id);
                if (result_or_err) |result| {
                    switch (result) {
                        .value => |v| {
                            // Found it!
                            return v;
                        },
                        .closer_peers => |closer| {
                            defer self.allocator.free(closer);
                            try state.reportReply(peer.id, closer);
                            self.mutex.lock();
                            for (closer) |p| {
                                if (p.id.eql(self.manager.node_id)) continue;
                                if (state.failed.contains(p.id)) continue;
                                try self.routing_table.addPeer(p);
                            }
                            self.mutex.unlock();
                        },
                    }
                } else |_| {
                    state.reportFailure(peer.id);
                }
            }
        }
        return null;
    }

    pub fn sendStore(self: *Node, address: std.net.Address, key: id.NodeID, value: []const u8, peer_id: ?id.NodeID) !void {
        const conn = try self.manager.connectToPeer(address, self.swarm_key, peer_id);

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

    pub fn sendFindValue(self: *Node, address: std.net.Address, key: id.NodeID, peer_id: ?id.NodeID) !FindValueResult {
        const conn = try self.manager.connectToPeer(address, self.swarm_key, peer_id);

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
        self.mutex.lock();
        const initial_peers = try self.routing_table.getClosestPeers(target, kbucket.K);
        self.mutex.unlock();
        defer self.allocator.free(initial_peers);

        var state = try lookup_mod.LookupState.init(self.allocator, target, initial_peers);
        defer state.deinit();

        while (!state.isFinished()) {
            const next_peers = try state.nextPeersToQuery();
            defer self.allocator.free(next_peers);

            if (next_peers.len == 0) break;

            for (next_peers) |peer| {
                if (peer.id.eql(self.manager.node_id)) continue;

                if (self.sendFindNode(peer.address, target, peer.id)) |closer_peers| {
                    defer self.allocator.free(closer_peers);
                    try state.reportReply(peer.id, closer_peers);

                    // Add discovered peers to routing table
                    self.mutex.lock();
                    for (closer_peers) |p| {
                        if (p.id.eql(self.manager.node_id)) continue;
                        if (state.failed.contains(p.id)) continue;
                        try self.routing_table.addPeer(p);
                    }
                    self.mutex.unlock();
                } else |err| {
                    std.debug.print("Lookup: Failed to contact {f}: {any}. Removing from table.\n", .{ peer.address, err });
                    state.reportFailure(peer.id);
                    self.mutex.lock();
                    self.routing_table.markDisconnected(peer.id);
                    self.mutex.unlock();
                }
            }
        }
    }

    pub fn sendFindNode(self: *Node, address: std.net.Address, target: id.NodeID, peer_id: ?id.NodeID) ![]kbucket.PeerInfo {
        const conn = try self.manager.connectToPeer(address, self.swarm_key, peer_id);

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

    pub fn refreshBuckets(self: *Node) !void {
        const now = std.time.timestamp();
        var i: usize = 0;
        while (i < 256) : (i += 1) {
            var needs_refresh = false;
            {
                self.mutex.lock();
                const bucket = &self.routing_table.buckets[i];
                if (now - bucket.last_updated > 3600) {
                    needs_refresh = true;
                }
                self.mutex.unlock();
            }

            if (needs_refresh) {
                // std.debug.print("Refreshing bucket {d}...\n", .{i});
                const target = self.manager.node_id.randomIdInBucket(i);
                self.lookup(target) catch |err| {
                    std.debug.print("Error refreshing bucket {d}: {any}\n", .{ i, err });
                };
            }
        }
    }

    pub fn serve(self: *Node, conn: network.Connection) !void {
        _ = conn.getRemoteNodeID();

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

        // NOTE: We do NOT add the peer here anymore. We wait for PING to get the correct port.

        switch (msg.payload) {
            .PING => |p| {
                // Construct correct address from socket IP + Payload Port
                var address = conn.getPeerAddress();
                std.debug.print("Received PING from {x}. Address from sock: {f}, Port from payload: {d}\n", .{msg.sender_id.bytes[0..4], address, p.port});

                if (address.any.family == std.posix.AF.INET) {
                    address.in.sa.port = std.mem.nativeToBig(u16, p.port);
                } else if (address.any.family == std.posix.AF.INET6) {
                    address.in6.sa.port = std.mem.nativeToBig(u16, p.port);
                }
                std.debug.print("Address adjusted to: {f}\n", .{address});

                // Add to routing table with CORRECT port
                self.mutex.lock();
                defer self.mutex.unlock();
                self.routing_table.addPeer(.{
                    .id = msg.sender_id,
                    .address = address,
                    .last_seen = std.time.timestamp(),
                }) catch |err| {
                    std.debug.print("Failed to update routing table: {any}\n", .{err});
                };
                std.debug.print("Added peer to routing table.\n", .{});

                const response = rpc.Message{
                    .sender_id = self.manager.node_id,
                    .payload = .{ .PONG = {} },
                };
                try response.serialize(stream.writer());
            },
            .FIND_NODE => |p| {
                self.mutex.lock();
                const closer = try self.routing_table.getClosestPeers(p.target, kbucket.K);
                self.mutex.unlock();
                defer self.allocator.free(closer);

                const response = rpc.Message{
                    .sender_id = self.manager.node_id,
                    .payload = .{ .FIND_NODE_RESPONSE = .{ .closer_peers = closer } },
                };
                try response.serialize(stream.writer());
            },
            .FIND_VALUE => |p| {
                var val_opt: ?[]u8 = null;
                self.mutex.lock();
                if (self.storage.get(p.key)) |val| {
                    val_opt = try self.allocator.dupe(u8, val);
                }
                self.mutex.unlock();

                if (val_opt) |val| {
                    defer self.allocator.free(val);
                    // Return value
                    const response = rpc.Message{
                        .sender_id = self.manager.node_id,
                        .payload = .{ .FIND_VALUE_RESPONSE = .{ .value = val } },
                    };
                    try response.serialize(stream.writer());
                } else {
                    // Return closest peers
                    self.mutex.lock();
                    const closer = try self.routing_table.getClosestPeers(p.key, kbucket.K);
                    self.mutex.unlock();
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
