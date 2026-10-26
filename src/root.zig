//! By convention, root.zig is the root source file when making a library.
const std = @import("std");

pub const config = @import("config.zig");
pub const net = @import("net/mod.zig");
pub const storage = @import("storage/mod.zig");
pub const device = @import("device/mod.zig");

/// C ABI bindings for mobile hosts; the shared library target points here.
pub const mobile_api = @import("mobile/api.zig");

// Force the C ABI surface into every artifact of this module, so the shared
// library keeps its exports even though nothing below references it.
comptime {
    _ = mobile_api;
}
pub const cluster = @import("cluster/mod.zig");
pub const sync = @import("sync.zig");
pub const env = @import("env.zig");

const ConnectionManager = net.transport.manager.ConnectionManager;
const DiscoveryNode = net.discovery.Node;
const HashRight = cluster.ring.HashRing;

pub const Node = struct {
    allocator: std.mem.Allocator,
    connection_manager: *ConnectionManager,
    store: ?*storage.engine.StorageEngine,
    discovery_node: *DiscoveryNode,
    block_manager: *cluster.BlockManager,
    ring: *HashRight,
    device_paths: device.paths.Paths,
    device_identity: device.identity.Identity,
    trust_store: *device.trust.Store,
    bootstrap_thread: ?std.Thread = null,
    bootstrap_running: *std.atomic.Value(bool),

    pub fn init(allocator: std.mem.Allocator, cfg: config.Config) !Node {
        const connection_manager = try allocator.create(ConnectionManager);
        errdefer allocator.destroy(connection_manager);
        connection_manager.* = try ConnectionManager.init(allocator, cfg.network.transport, cfg.node.key_path);
        errdefer connection_manager.deinit();
        try connection_manager.start();

        var store: ?*storage.engine.StorageEngine = null;
        if (cfg.storage.enabled) {
            const s = try allocator.create(storage.engine.StorageEngine);
            errdefer allocator.destroy(s);
            s.* = try storage.engine.StorageEngine.init(allocator, cfg.storage.storage_path);
            store = s;
        }
        errdefer if (store) |s| {
            s.deinit();
            allocator.destroy(s);
        };

        const discovery_node = try allocator.create(DiscoveryNode);
        discovery_node.* = DiscoveryNode.init(
            allocator,
            connection_manager,
            cfg.node.swarm_key,
        );
        errdefer {
            discovery_node.deinit();
            allocator.destroy(discovery_node);
        }

        // Serve our blocks to peers repairing from us.
        discovery_node.block_store = store;

        // Register DHT serve loop for new connections
        connection_manager.setConnectionHandler(discovery_node, DiscoveryNode.serve);
        connection_manager.setDiscoveryHandler(discovery_node, DiscoveryNode.onDiscovery);

        const block_manager = try cluster.BlockManager.init(allocator, .{
            .network = connection_manager,
            .dht = discovery_node,
            .storage = store,
            .replication = cfg.storage.replicas,
        });
        errdefer block_manager.deinit();

        const ring = try allocator.create(HashRight);
        ring.* = HashRight.init(allocator);
        errdefer {
            ring.deinit();
            allocator.destroy(ring);
        }

        // If storage is enabled, add ourselves to the ring
        if (cfg.storage.enabled) {
            try ring.addNode(connection_manager.node_id, 10);
        }

        var device_paths = try device.paths.Paths.resolve(allocator, cfg.node.key_path);
        errdefer device_paths.deinit(allocator);
        const device_identity = try device.identity.Identity.loadOrCreate(device_paths.identity);
        // Heap allocated so the authenticator's pointer stays valid after the
        // Node value is copied out of init().
        const trust_store = try allocator.create(device.trust.Store);
        errdefer allocator.destroy(trust_store);
        trust_store.* = try device.trust.Store.load(allocator, device_paths.trust, device_identity.seed());
        errdefer trust_store.deinit();

        // Revocations are signed with the device identity and recorded in
        // the same trust store the handshake policy reads.
        discovery_node.trust_store = trust_store;
        discovery_node.device_identity = device_identity;

        connection_manager.setDeviceAuthenticator(.{
            .identity = device_identity,
            .trust = trust_store,
            .require_trusted = cfg.security.require_trusted_devices,
        });

        const bootstrap_running = try allocator.create(std.atomic.Value(bool));
        bootstrap_running.* = std.atomic.Value(bool).init(true);

        return Node{
            .allocator = allocator,
            .connection_manager = connection_manager,
            .store = store,
            .discovery_node = discovery_node,
            .block_manager = block_manager,
            .ring = ring,
            .device_paths = device_paths,
            .device_identity = device_identity,
            .trust_store = trust_store,
            .bootstrap_running = bootstrap_running,
            .bootstrap_thread = null,
        };
    }

    pub fn deinit(self: *Node) void {
        self.bootstrap_running.store(false, .release);
        if (self.bootstrap_thread) |t| {
            t.join();
        }
        self.allocator.destroy(self.bootstrap_running);

        // Stop network traffic and callbacks BEFORE destroying handlers
        self.connection_manager.stop();

        self.trust_store.deinit();
        self.allocator.destroy(self.trust_store);
        self.device_paths.deinit(self.allocator);

        self.ring.deinit();
        self.allocator.destroy(self.ring);
        self.block_manager.deinit();
        self.discovery_node.deinit();
        self.allocator.destroy(self.discovery_node);
        if (self.store) |s| {
            s.deinit();
            self.allocator.destroy(s);
        }
        self.connection_manager.deinit();
        self.allocator.destroy(self.connection_manager);
    }

    pub fn run(self: *Node, running: *std.atomic.Value(bool), cfg: config.Config) !void {
        try self.connection_manager.listen(cfg, running);
        while (running.load(.acquire)) {
            sync.sleep(100 * std.time.ns_per_ms);
        }
        // Signal bootstrap thread to stop if main loop stops
        self.bootstrap_running.store(false, .release);
    }

    pub fn bootstrap(self: *Node, peer_urls: [][]const u8, swarm_key: []const u8) !void {
        if (self.bootstrap_thread) |t| {
            // Signal stop
            self.bootstrap_running.store(false, .release);
            t.join();
            self.bootstrap_thread = null;
            // Reset flag for new thread
            self.bootstrap_running.store(true, .release);
        }

        self.bootstrap_thread = try std.Thread.spawn(.{}, runBootstrap, .{ self, peer_urls, swarm_key });
    }

    fn runBootstrap(self: *Node, peer_urls: [][]const u8, swarm_key: []const u8) void {
        for (peer_urls) |peer_url| {
            if (!self.bootstrap_running.load(.acquire)) return;
            self.connectBootstrapPeer(peer_url, swarm_key);
        }

        std.debug.print("Bootstrap connections complete. Starting periodic peer discovery and maintenance...\n", .{});
        const discovery_node = self.discovery_node;

        // 1. Initial Self-Lookup (Once)
        if (self.bootstrap_running.load(.acquire)) {
            std.debug.print("Starting initial self-lookup...\n", .{});
            discovery_node.lookup(self.connection_manager.node_id) catch |err| {
                std.debug.print("Error during self-lookup: {any}\n", .{err});
            };
            std.debug.print("Initial self-lookup complete. Routing table dump:\n", .{});
            discovery_node.routing_table.dump();
        }

        // 2. Periodic Bucket Refresh (Standard Kademlia Maintenance)
        while (self.sleepWhileBootstrapping(60 * std.time.ns_per_s)) {
            discovery_node.refreshBuckets() catch |err| {
                std.debug.print("Bucket refresh error: {any}\n", .{err});
            };
        }
    }

    /// Sleeps up to `total_ns`, waking early when bootstrapping is cancelled.
    /// Returns whether bootstrapping is still running.
    fn sleepWhileBootstrapping(self: *Node, total_ns: u64) bool {
        const sleep_chunk = 100 * std.time.ns_per_ms;
        var elapsed: u64 = 0;
        while (elapsed < total_ns) : (elapsed += sleep_chunk) {
            if (!self.bootstrap_running.load(.acquire)) return false;
            sync.sleep(sleep_chunk);
        }
        return self.bootstrap_running.load(.acquire);
    }

    fn connectBootstrapPeer(self: *Node, peer_url: []const u8, swarm_key: []const u8) void {
        const address = parseBootstrapUrl(peer_url) orelse return;
        std.debug.print("Bootstrapping: Connecting to {s}...\n", .{peer_url});

        const max_attempts = 5;
        var attempts: usize = 0;
        while (attempts < max_attempts) : (attempts += 1) {
            if (!self.bootstrap_running.load(.acquire)) return;

            const conn = self.connection_manager.connectToPeer(address, swarm_key, null) catch |err| {
                if (attempts == max_attempts - 1) {
                    std.debug.print("Failed to connect to bootstrap peer {s} after {d} attempts: {any}\n", .{ peer_url, max_attempts, err });
                    return;
                }
                std.debug.print("Retry {d}/{d} for {s}: {any}\n", .{ attempts + 1, max_attempts, peer_url, err });
                if (!self.sleepWhileBootstrapping(1 * std.time.ns_per_s)) return;
                continue;
            };
            defer conn.deinit();

            std.debug.print("Successfully connected to bootstrap peer: {s}\n", .{peer_url});
            self.discovery_node.ping(conn) catch {};

            // Request AutoNAT dial-back
            self.discovery_node.checkReachability(conn) catch |err| {
                std.debug.print("AutoNAT request failed: {any}\n", .{err});
            };
            return;
        }
    }

    /// Parses "tcp://host:port" or "host:port"; logs and returns null if invalid.
    fn parseBootstrapUrl(peer_url: []const u8) ?net.compat.Address {
        var addr_part = peer_url;
        if (std.mem.startsWith(u8, addr_part, "tcp://")) {
            addr_part = addr_part[6..];
        }

        const colon_idx = std.mem.lastIndexOfScalar(u8, addr_part, ':') orelse {
            std.debug.print("Invalid bootstrap peer URL: {s}\n", .{peer_url});
            return null;
        };
        const host = addr_part[0..colon_idx];
        const port = std.fmt.parseInt(u16, addr_part[colon_idx + 1 ..], 10) catch {
            std.debug.print("Invalid port in bootstrap peer URL: {s}\n", .{peer_url});
            return null;
        };

        return net.compat.Address.parseIp(host, port) catch {
            std.debug.print("Failed to parse IP for bootstrap peer: {s}\n", .{peer_url});
            return null;
        };
    }
};

pub const metrics = @import("metrics.zig");
pub const errors = @import("errors.zig");
pub const resilience = @import("net/resilience.zig");

test {
    // Compile every module and all of its declarations, including modules
    // nothing imports yet, so broken code and tests cannot hide.
    inline for (.{
        @import("cluster/block_manager.zig"),
        @import("mobile/api.zig"),
        @import("cluster/quorum.zig"),
        @import("cluster/repair.zig"),
        @import("cluster/ring.zig"),
        @import("cluster/vectors.zig"),
        @import("config.zig"),
        @import("device/auth.zig"),
        @import("device/identity.zig"),
        @import("device/pairing.zig"),
        @import("device/paths.zig"),
        @import("device/qr.zig"),
        @import("device/trust.zig"),
        @import("env.zig"),
        @import("errors.zig"),
        @import("metrics.zig"),
        @import("net/compat.zig"),
        @import("net/discovery/kbucket.zig"),
        @import("net/discovery/lookup.zig"),
        @import("net/discovery/node.zig"),
        @import("net/discovery/rpc.zig"),
        @import("net/id.zig"),
        @import("net/resilience.zig"),
        @import("net/transport/manager.zig"),
        @import("net/transport/mdns.zig"),
        @import("net/transport/nat.zig"),
        @import("net/transport/noise.zig"),
        @import("net/transport/tcp.zig"),
        @import("net/transport/yamux.zig"),
        @import("storage/block.zig"),
        @import("storage/chunker.zig"),
        @import("storage/dag/builder.zig"),
        @import("storage/dag/codec.zig"),
        @import("storage/dag/diff.zig"),
        @import("storage/dag/node.zig"),
        @import("storage/dag/walk.zig"),
        @import("storage/engine.zig"),
        @import("sync.zig"),
    }) |module| {
        std.testing.refAllDecls(module);
    }
}
