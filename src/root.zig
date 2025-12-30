//! By convention, root.zig is the root source file when making a library.
const std = @import("std");

pub const config = @import("config.zig");
pub const net = @import("net/mod.zig");
pub const storage = @import("storage/mod.zig");
pub const dist = @import("dist/mod.zig");

const ConnectionManager = net.transport.manager.ConnectionManager;
const DiscoveryNode = net.discovery.Node;
const HashRight = dist.ring.HashRing;

pub const Node = struct {
    allocator: std.mem.Allocator,
    connection_manager: *ConnectionManager,
    store: ?*storage.engine.StorageEngine,
    discovery_node: *DiscoveryNode,
    block_manager: *dist.BlockManager,
    ring: *HashRight,

    pub fn init(allocator: std.mem.Allocator, cfg: config.Config) !Node {
        const connection_manager = try allocator.create(ConnectionManager);
        connection_manager.* = try ConnectionManager.init(allocator, cfg.network.transport, cfg.node.key_path);
        try connection_manager.start();
        errdefer {
            connection_manager.deinit();
            allocator.destroy(connection_manager);
        }

        var store: ?*storage.engine.StorageEngine = null;
        if (cfg.storage.enabled) {
            store = try allocator.create(storage.engine.StorageEngine);
            store.?.* = try storage.engine.StorageEngine.init(allocator, cfg.storage.storage_path);
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

        // Register DHT serve loop for new connections
        connection_manager.setConnectionHandler(discovery_node, DiscoveryNode.serve);
        connection_manager.setDiscoveryHandler(discovery_node, DiscoveryNode.onDiscovery);

        const block_manager = try dist.BlockManager.init(allocator, .{
            .network = connection_manager,
            .dht = discovery_node,
            .storage = store,
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

        return Node{
            .allocator = allocator,
            .connection_manager = connection_manager,
            .store = store,
            .discovery_node = discovery_node,
            .block_manager = block_manager,
            .ring = ring,
        };
    }

    pub fn deinit(self: *Node) void {
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

    pub fn run(self: *Node, port: u16, swarm_key: []const u8, running: *std.atomic.Value(bool), enable_mdns: bool, upnp_enabled: bool) !void {
        try self.connection_manager.listen(.{
            .port = port,
            .swarm_key = swarm_key,
            .enable_mdns = enable_mdns,
            .upnp_enabled = upnp_enabled,
        }, running);
    }

    pub fn bootstrap(self: *Node, peer_urls: [][]const u8, swarm_key: []const u8) !void {
        const Ctx = struct {
            node: *Node,
            urls: [][]const u8,
            key: []const u8,

            fn run(ctx: @This()) void {
                for (ctx.urls) |peer_url| {
                    var addr_part = peer_url;
                    if (std.mem.startsWith(u8, addr_part, "tcp://")) {
                        addr_part = addr_part[6..];
                    }

                    const colon_idx = std.mem.indexOf(u8, addr_part, ":") orelse {
                        std.debug.print("Invalid bootstrap peer URL: {s}\n", .{peer_url});
                        continue;
                    };
                    const host = addr_part[0..colon_idx];
                    const port_str = addr_part[colon_idx + 1 ..];
                    const port = std.fmt.parseInt(u16, port_str, 10) catch {
                        std.debug.print("Invalid port in bootstrap peer URL: {s}\n", .{peer_url});
                        continue;
                    };

                    const address = std.net.Address.parseIp(host, port) catch {
                        std.debug.print("Failed to parse IP for bootstrap peer: {s}\n", .{peer_url});
                        continue;
                    };

                    std.debug.print("Bootstrapping: Connecting to {s}...\n", .{peer_url});

                    var attempts: usize = 0;
                    const max_attempts = 5;
                    while (attempts < max_attempts) : (attempts += 1) {
                        if (ctx.node.connection_manager.connectToPeer(address, ctx.key, null)) |conn| {
                            std.debug.print("Successfully connected to bootstrap peer: {s}\n", .{peer_url});
                            ctx.node.discovery_node.ping(conn) catch {};

                            // Request AutoNAT dial-back
                            ctx.node.discovery_node.checkReachability(conn) catch |err| {
                                std.debug.print("AutoNAT request failed: {any}\n", .{err});
                            };

                            break;
                        } else |err| {
                            if (attempts < max_attempts - 1) {
                                std.debug.print("Retry {d}/{d} for {s}: {any}\n", .{ attempts + 1, max_attempts, peer_url, err });
                                std.Thread.sleep(1 * std.time.ns_per_s);
                            } else {
                                std.debug.print("Failed to connect to bootstrap peer {s} after {d} attempts: {any}\n", .{ peer_url, max_attempts, err });
                            }
                        }
                    }
                }

                std.debug.print("Bootstrap connections complete. Starting periodic peer discovery and maintenance...\n", .{});
                const discovery_node_ptr = ctx.node.discovery_node;
                const net_node_id = ctx.node.connection_manager.node_id;

                // 1. Initial Self-Lookup (Once)
                std.debug.print("Starting initial self-lookup...\n", .{});
                discovery_node_ptr.lookup(net_node_id) catch |err| {
                    std.debug.print("Error during self-lookup: {any}\n", .{err});
                };
                std.debug.print("Initial self-lookup complete. Routing table dump:\n", .{});
                discovery_node_ptr.routing_table.dump();

                // 2. Periodic Bucket Refresh (Standard Kademlia Maintenance)
                while (true) {
                    std.Thread.sleep(60 * std.time.ns_per_s); // Check for stale buckets every minute
                    discovery_node_ptr.refreshBuckets() catch |err| {
                        std.debug.print("Bucket refresh error: {any}\n", .{err});
                    };
                }
            }
        };

        const thread = try std.Thread.spawn(.{}, Ctx.run, .{Ctx{
            .node = self,
            .urls = peer_urls,
            .key = swarm_key,
        }});
        thread.detach();
    }
};
