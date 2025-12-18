const std = @import("std");
const nomadfs = @import("nomadfs");

/// A helper struct to represent a running node in a test environment.
/// It wraps the configuration, allocator, and connection manager.
pub const TestPeer = struct {
    allocator: std.mem.Allocator,
    config: nomadfs.config.Config,
    manager: nomadfs.network.manager.ConnectionManager,
    server_thread: ?std.Thread = null,
    running: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    listen_addr: std.net.Address,

    pub fn init(allocator: std.mem.Allocator, port: u16) !*TestPeer {
        const peer = try allocator.create(TestPeer);
        
        // Setup minimal config
        var cfg = nomadfs.config.Config{
            .node = .{ .nickname = "TestNode", .swarm_key = "test_key" },
            .storage = .{ .enabled = true, .storage_path = "./test_data" }, // TODO: Use tmp dir
            .network = .{ .port = port, .bootstrap_peers = undefined, .transport = .tcp },
        };
        // Dummy lists to avoid leaks or complex init for now
        cfg.network.bootstrap_peers = &.{};
        
        const addr = try std.net.Address.parseIp("127.0.0.1", port);

        peer.* = .{ 
            .allocator = allocator,
            .config = cfg,
            .manager = nomadfs.network.manager.ConnectionManager.init(allocator, .tcp),
            .listen_addr = addr,
        };
        return peer;
    }

    pub fn deinit(self: *TestPeer) void {
        self.stop();
        self.manager.deinit();
        self.allocator.destroy(self);
    }

    pub fn start(self: *TestPeer) !void {
        if (self.running.load(.acquire)) return;
        self.running.store(true, .release);

        self.server_thread = try std.Thread.spawn(.{}, serverLoop, .{self});
    }

    pub fn stop(self: *TestPeer) void {
        if (!self.running.load(.acquire)) return;
        self.running.store(false, .release);
        
        // Connect to self to unblock accept()
        if (std.net.tcpConnectToAddress(self.listen_addr)) |s| {
            s.close();
        } else |_| {}

        if (self.server_thread) |t| {
            t.join();
            self.server_thread = null;
        }
    }

    fn serverLoop(self: *TestPeer) void {
        // We call the actual listener from tcp.zig
        nomadfs.network.tcp.listen(self.allocator, self.config.network.port, &self.running, &self.manager) catch |err| {
            if (self.running.load(.acquire)) {
                std.debug.print("TestPeer server error: {}\n", .{err});
            }
        };
    }

    pub fn connect(self: *TestPeer, other: *TestPeer) !nomadfs.network.Stream {
        const conn = try self.manager.connectToPeer(other.listen_addr);
        // We have a connection, now open a stream
        return conn.openStream();
    }
};
