const std = @import("std");
const nomadfs = @import("nomadfs");

/// A helper struct to represent a running node in a test environment.
/// It wraps the configuration, allocator, and connection manager.
pub const TestPeer = struct {
    allocator: std.mem.Allocator,
    config: nomadfs.config.Config,
    manager: *nomadfs.net.transport.manager.ConnectionManager,
    running: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    listen_addr: nomadfs.net.compat.Address,

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

        const addr = try nomadfs.net.compat.Address.parseIp("127.0.0.1", port);

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
        // Handshake threads are detached and drop the manager's reference in
        // their last statement. Wait (bounded) until only our own reference
        // remains, so the test allocator's leak detection cannot race a
        // thread that is one instruction away from destroying the manager.
        var waited: usize = 0;
        while (self.manager.ref_count.load(.acquire) != 1) {
            if (waited >= 200) {
                std.debug.print("TestPeer: manager reference did not drain in time\n", .{});
                break;
            }
            nomadfs.sync.sleep(5 * std.time.ns_per_ms);
            waited += 1;
        }
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
        if (nomadfs.net.compat.tcpConnectToAddress(self.listen_addr)) |s| {
            s.close();
        } else |_| {}

        // Close all existing connections and wait for handlers
        self.manager.stop();
    }

    pub fn connect(self: *TestPeer, other: *TestPeer) !nomadfs.net.transport.Stream {
        const conn = try self.manager.connectToPeer(other.listen_addr, self.config.node.swarm_key, other.manager.node_id);
        // The manager's own reference keeps the connection (and so the
        // stream) alive until this peer is stopped.
        defer conn.deinit();
        return conn.openStream();
    }
};
