//! By convention, root.zig is the root source file when making a library.
const std = @import("std");

pub const config = @import("config.zig");
pub const network = @import("network/mod.zig");
pub const storage = @import("storage/mod.zig");
pub const sync = @import("sync/mod.zig");
pub const dht = @import("dht/mod.zig");
pub const dist = @import("dist/mod.zig");

pub const Node = struct {
    allocator: std.mem.Allocator,
    net: *network.manager.ConnectionManager,
    store: ?*storage.engine.StorageEngine,
    dht_node: *dht.Node,
    block_manager: *dist.BlockManager,
    ring: *dist.ring.HashRing,

    pub fn init(allocator: std.mem.Allocator, cfg: config.Config) !*Node {
        const net = try allocator.create(network.manager.ConnectionManager);
        net.* = try network.manager.ConnectionManager.init(allocator, cfg.network.transport, cfg.node.key_path);
        try net.start();
        errdefer {
            net.deinit();
            allocator.destroy(net);
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

        const dht_node = try allocator.create(dht.Node);
        dht_node.* = dht.Node.init(allocator, net, cfg.node.swarm_key);
        errdefer {
            dht_node.deinit();
            allocator.destroy(dht_node);
        }

        // Register DHT serve loop for new connections
        net.setConnectionHandler(dht_node, dht.Node.serve);

        const block_manager = try dist.BlockManager.init(allocator, .{
            .network = net,
            .dht = dht_node,
            .storage = store,
        });
        errdefer block_manager.deinit();

        const ring = try allocator.create(dist.ring.HashRing);
        ring.* = dist.ring.HashRing.init(allocator);
        errdefer {
            ring.deinit();
            allocator.destroy(ring);
        }

        // If storage is enabled, add ourselves to the ring
        if (cfg.storage.enabled) {
            try ring.addNode(net.node_id, 10);
        }

        const self = try allocator.create(Node);
        self.* = .{
            .allocator = allocator,
            .net = net,
            .store = store,
            .dht_node = dht_node,
            .block_manager = block_manager,
            .ring = ring,
        };
        return self;
    }

    pub fn deinit(self: *Node) void {
        self.ring.deinit();
        self.allocator.destroy(self.ring);
        self.block_manager.deinit();
        self.dht_node.deinit();
        if (self.store) |s| {
            s.deinit();
            self.allocator.destroy(s);
        }
        self.net.deinit();
        self.allocator.destroy(self.net);
        self.allocator.destroy(self);
    }

    pub fn start(self: *Node, port: u16, swarm_key: []const u8, running: *std.atomic.Value(bool)) !void {
        const listen_thread = try std.Thread.spawn(.{}, struct {
            fn run(m: *network.manager.ConnectionManager, p: u16, key: []const u8, run_flag: *std.atomic.Value(bool)) void {
                m.listen(p, key, run_flag) catch |err| {
                    std.debug.print("Listener error: {any}\n", .{err});
                };
            }
        }.run, .{ self.net, port, swarm_key, running });
        listen_thread.detach();
    }

    pub fn bootstrap(self: *Node, peer_urls: [][]const u8, swarm_key: []const u8) !void {
        for (peer_urls) |peer_url| {
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
                if (self.net.connectToPeer(address, swarm_key)) |conn| {
                    std.debug.print("Successfully connected to bootstrap peer: {s}\n", .{peer_url});
                    try self.dht_node.ping(conn);
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
        const dht_node_ptr = self.dht_node;
        const net_node_id = self.net.node_id;

        const discovery_thread = try std.Thread.spawn(.{}, struct {
            fn run(node: *dht.Node, target_id: dht.id.NodeID) void {
                while (true) {
                    std.debug.print("Starting peer discovery...\n", .{});
                    node.lookup(target_id) catch |err| {
                        std.debug.print("Error during DHT lookup: {any}\n", .{err});
                    };
                    std.debug.print("Peer discovery complete. Routing table dump:\n", .{});
                    node.routing_table.dump();
                    std.Thread.sleep(10 * std.time.ns_per_s); // Run every 10 seconds
                }
            }
        }.run, .{ dht_node_ptr, net_node_id });
        discovery_thread.detach();

        const maintenance_thread = try std.Thread.spawn(.{}, struct {
            fn run(node: *dht.Node) void {
                while (true) {
                    std.Thread.sleep(60 * std.time.ns_per_s);
                    std.debug.print("Starting maintenance (ping all peers)...\n", .{});
                    node.maintain() catch |err| {
                        std.debug.print("Maintenance error: {any}\n", .{err});
                    };
                }
            }
        }.run, .{ dht_node_ptr });
        maintenance_thread.detach();
    }
};
