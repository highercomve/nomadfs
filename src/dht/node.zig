const std = @import("std");
const id = @import("id.zig");
const kbucket = @import("kbucket.zig");
const rpc = @import("rpc.zig");
const network = @import("../network/mod.zig");

pub const Node = struct {
    allocator: std.mem.Allocator,
    manager: *network.manager.ConnectionManager,
    routing_table: kbucket.RoutingTable,
    swarm_key: []const u8,

    pub fn init(allocator: std.mem.Allocator, manager: *network.manager.ConnectionManager, swarm_key: []const u8) Node {
        return .{
            .allocator = allocator,
            .manager = manager,
            .routing_table = kbucket.RoutingTable.init(allocator, manager.node_id),
            .swarm_key = swarm_key,
        };
    }

    pub fn deinit(self: *Node) void {
        self.routing_table.deinit();
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
            self.routing_table.dump();
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
            else => {
                std.debug.print("Received unhandled DHT message type: {any}\n", .{msg.payload});
            },
        }
    }
};
