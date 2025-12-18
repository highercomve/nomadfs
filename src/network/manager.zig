const std = @import("std");
const builtin = @import("builtin");
const network = @import("mod.zig");
const config = @import("../config.zig");
const tcp = @import("tcp.zig");
const noise = @import("noise.zig");
const id = @import("../dht/id.zig");

pub const ConnectionManager = struct {
    allocator: std.mem.Allocator,
    connections: std.ArrayListUnmanaged(network.Connection),
    transport_type: config.Config.TransportType,
    identity_key: noise.KeyPair,
    node_id: id.NodeID,
    mutex: std.Thread.Mutex = .{},
    on_connection_ctx: ?*anyopaque = null,
    on_connection_fn: ?*const fn (ctx: *anyopaque, conn: network.Connection) anyerror!void = null,

    pub fn init(allocator: std.mem.Allocator, transport_type: config.Config.TransportType) !ConnectionManager {
        const keypair = try loadOrGenerateKey(allocator);
        return initExplicit(allocator, transport_type, keypair);
    }

    pub fn initExplicit(allocator: std.mem.Allocator, transport_type: config.Config.TransportType, keypair: noise.KeyPair) ConnectionManager {
        return .{
            .allocator = allocator,
            .connections = std.ArrayListUnmanaged(network.Connection){},
            .transport_type = transport_type,
            .identity_key = keypair,
            .node_id = id.NodeID.fromPublicKey(keypair.public_key),
            .on_connection_ctx = null,
            .on_connection_fn = null,
        };
    }

    fn loadOrGenerateKey(allocator: std.mem.Allocator) !noise.KeyPair {
        const key_filename = "node.key";

        // 1. Try CWD
        if (noise.KeyPair.loadFromFile(key_filename)) |kp| {
            std.debug.print("Loaded identity key from ./{s}\n", .{key_filename});
            return kp;
        } else |_| {}

        // 2. Try Home directory
        const home_env = if (builtin.os.tag == .windows) "USERPROFILE" else "HOME";
        if (std.process.getEnvVarOwned(allocator, home_env)) |home| {
            defer allocator.free(home);
            const dot_nomad = try std.fs.path.join(allocator, &.{ home, ".nomadfs" });
            defer allocator.free(dot_nomad);

            // Ensure directory exists
            std.fs.cwd().makePath(dot_nomad) catch {};

            const key_path = try std.fs.path.join(allocator, &.{ dot_nomad, key_filename });
            defer allocator.free(key_path);

            if (noise.KeyPair.loadFromFile(key_path)) |kp| {
                std.debug.print("Loaded identity key from {s}\n", .{key_path});
                return kp;
            } else |_| {
                // If it doesn't exist in home, but home is accessible, we'll create it here
                const kp = noise.KeyPair.generate();
                try kp.saveToFile(key_path);
                std.debug.print("Generated new identity key at {s}\n", .{key_path});
                return kp;
            }
        } else |_| {}

        // 3. Fallback: Generate and save in CWD
        const kp = noise.KeyPair.generate();
        try kp.saveToFile(key_filename);
        std.debug.print("Generated new identity key at ./{s}\n", .{key_filename});
        return kp;
    }

    pub fn deinit(self: *ConnectionManager) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        for (self.connections.items) |conn| {
            conn.close();
        }
        self.connections.deinit(self.allocator);
    }

    pub fn addConnection(self: *ConnectionManager, conn: network.Connection) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        try self.connections.append(self.allocator, conn);
        if (self.on_connection_fn) |cb| {
            try cb(self.on_connection_ctx.?, conn);
        }
    }

    pub fn listen(self: *ConnectionManager, port: u16, swarm_key: []const u8, running: ?*std.atomic.Value(bool)) !void {
        switch (self.transport_type) {
            .tcp => {
                // For MVP, we assume tcp.connect returns a fully negotiated Connection
                try tcp.listen(self.allocator, port, swarm_key, self.identity_key, running, self);
            },
            .quic => {
                return error.QuicNotImplemented;
            },
        }
    }

    pub fn connectToPeer(self: *ConnectionManager, address: std.net.Address, swarm_key: []const u8) !network.Connection {
        switch (self.transport_type) {
            .tcp => {
                // For MVP, we assume tcp.connect returns a fully negotiated Connection
                const conn = try tcp.connect(self.allocator, address, swarm_key, self.identity_key);
                try self.addConnection(conn);
                return conn;
            },
            .quic => {
                return error.QuicNotImplemented;
            },
        }
    }
};
