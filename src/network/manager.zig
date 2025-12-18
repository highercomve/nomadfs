const std = @import("std");
const network = @import("mod.zig");
const config = @import("../config.zig");
const tcp = @import("tcp.zig");

pub const ConnectionManager = struct {
    allocator: std.mem.Allocator,
    connections: std.ArrayListUnmanaged(network.Connection),
    transport_type: config.Config.TransportType,

    pub fn init(allocator: std.mem.Allocator, transport_type: config.Config.TransportType) ConnectionManager {
        return .{
            .allocator = allocator,
            .connections = std.ArrayListUnmanaged(network.Connection){},
            .transport_type = transport_type,
        };
    }

    pub fn deinit(self: *ConnectionManager) void {
        for (self.connections.items) |conn| {
            conn.close();
        }
        self.connections.deinit(self.allocator);
    }

    pub fn addConnection(self: *ConnectionManager, conn: network.Connection) !void {
        try self.connections.append(self.allocator, conn);
    }

    pub fn connectToPeer(self: *ConnectionManager, address: std.net.Address) !network.Connection {
        switch (self.transport_type) {
            .tcp => {
                // For MVP, we assume tcp.connect returns a fully negotiated Connection
                const conn = try tcp.connect(self.allocator, address);
                try self.addConnection(conn);
                return conn;
            },
            .quic => {
                return error.QuicNotImplemented;
            },
        }
    }
};