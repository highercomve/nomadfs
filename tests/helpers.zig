const std = @import("std");
const nomadfs = @import("nomadfs");

/// A helper struct to represent a running node in a test environment.
/// It wraps the configuration, allocator, and connection manager.
pub const TestPeer = struct {
    allocator: std.mem.Allocator,
    config: nomadfs.config.Config,
    manager: *nomadfs.net.transport.manager.ConnectionManager,
    running: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    listen_addr: std.net.Address,

    pub fn init(allocator: std.mem.Allocator, port: u16) !TestPeer {
        // ... (minimal config setup)
        var cfg = nomadfs.config.Config{
            .node = .{
                .nickname = "TestNode",
                .swarm_key = "test_key_32_bytes_long_!!!!!!!!!",
            },
            .storage = .{
                .enabled = true,
                .storage_path = "./test_data",
            },
            .network = .{
                .port = port,
                .bootstrap_peers = undefined,
                .transport = .tcp,
                .upnp_enabled = false,
                .enable_mdns = false,
            },
        };
        // Dummy lists to avoid leaks or complex init for now
        cfg.network.bootstrap_peers = &.{};

        const addr = try std.net.Address.parseIp("127.0.0.1", port);

        const manager = try nomadfs.net.transport.manager.ConnectionManager.createExplicit(allocator, .tcp, nomadfs.net.transport.noise.KeyPair.generate());

        var peer = TestPeer{
            .allocator = allocator,
            .config = cfg,
            .manager = manager,
            .listen_addr = addr,
        };
        try peer.manager.start();
        return peer;
    }

    pub fn deinit(self: *TestPeer) void {
        self.stop();
        self.manager.deinit();
    }

    pub fn start(self: *TestPeer) !void {
        if (self.running.load(.acquire)) return;
        self.running.store(true, .release);

        try self.manager.listen(self.config, &self.running);
    }

    pub fn stop(self: *TestPeer) void {
        if (!self.running.load(.acquire)) return;
        self.running.store(false, .release);

        // Connect to self to unblock accept()
        if (std.net.tcpConnectToAddress(self.listen_addr)) |s| {
            s.close();
        } else |_| {}

        // Close all existing connections and wait for handlers
        self.manager.stop();
    }

    pub fn connect(self: *TestPeer, other: *TestPeer) !nomadfs.net.transport.Stream {
        const conn = try self.manager.connectToPeer(other.listen_addr, self.config.node.swarm_key, other.manager.node_id);
        // We have a connection, now open a stream
        return conn.openStream();
    }
};
