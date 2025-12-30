const std = @import("std");
const builtin = @import("builtin");
const network = @import("mod.zig");
const config = @import("../../config.zig");
const tcp = @import("tcp.zig");
const noise = @import("noise.zig");
const nat = @import("nat.zig");
const id = @import("../id.zig");

pub const ConnectionManager = struct {
    const ManagedConnection = struct {
        conn: network.Connection,
        last_active: i64,
    };

    allocator: std.mem.Allocator,
    connections: std.ArrayListUnmanaged(ManagedConnection),
    transport_type: config.Config.TransportType,
    identity_key: noise.KeyPair,
    node_id: id.NodeID,
    bound_port: u16 = 0,
    mutex: std.Thread.Mutex = .{},
    on_connection_ctx: ?*anyopaque = null,
    on_connection_fn: ?*const fn (ctx: *anyopaque, conn: network.Connection) anyerror!void = null,
    on_discovery_ctx: ?*anyopaque = null,
    on_discovery_fn: ?*const fn (ctx: *anyopaque, peer_id: id.NodeID, addr: std.net.Address) void = null,
    reaper_thread: ?std.Thread = null,
    upnp_thread: ?std.Thread = null,
    running: std.atomic.Value(bool) = std.atomic.Value(bool).init(true),
    idle_timeout: i64 = 60 * 5,
    reap_interval_ms: u64 = 10000,
    upnp: nat.UPnP,
    mdns: ?network.mdns.MDNS = null,
    ref_count: std.atomic.Value(usize) = std.atomic.Value(usize).init(1),
    handshake_wg: std.Thread.WaitGroup = .{},
    stopping: bool = false,
    tcp_server: ?std.net.Server = null,

    pub fn init(allocator: std.mem.Allocator, transport_type: config.Config.TransportType, key_path: ?[]const u8) !ConnectionManager {
        const keypair = try loadOrGenerateKey(allocator, key_path);
        return initExplicit(allocator, transport_type, keypair);
    }

    pub fn initExplicit(allocator: std.mem.Allocator, transport_type: config.Config.TransportType, keypair: noise.KeyPair) ConnectionManager {
        return .{
            .allocator = allocator,
            .connections = std.ArrayListUnmanaged(ManagedConnection){},
            .transport_type = transport_type,
            .identity_key = keypair,
            .node_id = id.NodeID.fromPublicKey(keypair.public_key),
            .bound_port = 0,
            .on_connection_ctx = null,
            .on_connection_fn = null,
            .reaper_thread = null,
            .upnp_thread = null,
            .running = std.atomic.Value(bool).init(true),
            .upnp = nat.UPnP.init(allocator),
            .mdns = null,
            .ref_count = std.atomic.Value(usize).init(1),
            .stopping = false,
            .tcp_server = null,
        };
    }

    pub fn ref(self: *ConnectionManager) void {
        _ = self.ref_count.fetchAdd(1, .monotonic);
    }

    pub fn deinit(self: *ConnectionManager) void {
        if (self.ref_count.fetchSub(1, .release) == 1) {
            // Ensure we have visibility of all modifications before destruction
            _ = self.ref_count.load(.acquire);
            self.stop();
            if (self.mdns) |*m| {
                m.deinit();
            }
            self.connections.deinit(self.allocator);
            self.upnp.deinit();
        }
    }

    pub fn start(self: *ConnectionManager) !void {
        if (self.reaper_thread != null) return;
        self.running.store(true, .release);
        self.reaper_thread = try std.Thread.spawn(.{}, ConnectionManager.runReaper, .{self});

        // Start mDNS
        if (self.mdns) |*m| {
            try m.start();
        }
    }

    fn loadOrGenerateKey(allocator: std.mem.Allocator, explicit_path: ?[]const u8) !noise.KeyPair {
        if (explicit_path) |path| {
            if (noise.KeyPair.loadFromFile(path)) |kp| {
                return kp;
            } else |_| {
                const kp = noise.KeyPair.generate();
                try kp.saveToFile(path);
                return kp;
            }
        }

        const key_filename = "node.key";

        // 1. Try CWD
        if (noise.KeyPair.loadFromFile(key_filename)) |kp| {
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
                return kp;
            } else |_| {
                const kp = noise.KeyPair.generate();
                try kp.saveToFile(key_path);
                return kp;
            }
        } else |_| {}

        // 3. Fallback: Generate and save in CWD
        const kp = noise.KeyPair.generate();
        try kp.saveToFile(key_filename);
        return kp;
    }

    pub fn stop(self: *ConnectionManager) void {
        self.mutex.lock();
        if (self.stopping) {
            self.mutex.unlock();
            return;
        }
        self.stopping = true;

        self.running.store(false, .release);
        if (self.mdns) |*m| {
            m.stop();
        }
        if (self.tcp_server) |*s| {
            s.deinit();
            self.tcp_server = null;
        }
        self.mutex.unlock();

        // Wait for all handshake threads to finish without holding the lock
        // as they might need to acquire it to add themselves or clean up.
        self.handshake_wg.wait();

        if (self.reaper_thread) |t| {
            t.join();
            self.reaper_thread = null;
        }

        if (self.upnp_thread) |t| {
            t.join();
            self.upnp_thread = null;
        }

        self.mutex.lock();
        defer self.mutex.unlock();
        for (self.connections.items) |mc| {
            mc.conn.deinit();
        }
        self.connections.clearRetainingCapacity();
    }

    fn runReaper(self: *ConnectionManager) void {
        while (self.running.load(.acquire)) {
            // Sleep in small increments
            const sleep_interval = 100; // ms
            var total_slept: u64 = 0;
            while (total_slept < self.reap_interval_ms and self.running.load(.acquire)) : (total_slept += sleep_interval) {
                std.Thread.sleep(sleep_interval * std.time.ns_per_ms);
            }
            if (!self.running.load(.acquire)) break;

            self.mutex.lock();
            var i: usize = 0;
            const now = std.time.timestamp();
            while (i < self.connections.items.len) {
                const mc = self.connections.items[i];
                const is_idle = (now - mc.last_active) > self.idle_timeout;
                const is_closed = mc.conn.isClosed();

                if (is_closed or is_idle) {
                    _ = self.connections.orderedRemove(i);
                    mc.conn.deinit();
                } else {
                    i += 1;
                }
            }
            self.mutex.unlock();
        }
    }

    pub fn getConnectionsCount(self: *ConnectionManager) usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.connections.items.len;
    }

    pub fn getConnection(self: *ConnectionManager, index: usize) ?network.Connection {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (index >= self.connections.items.len) return null;
        return self.connections.items[index].conn;
    }

    fn threadWrapper(cb: *const fn (*anyopaque, network.Connection) anyerror!void, ctx: *anyopaque, conn: network.Connection) void {
        cb(ctx, conn) catch |err| {
            std.debug.print("Connection handler error: {any}\n", .{err});
        };
    }

    pub fn addConnection(self: *ConnectionManager, conn: network.Connection) !void {
        var cb_opt: ?*const fn (*anyopaque, network.Connection) anyerror!void = null;
        var ctx_opt: ?*anyopaque = null;

        {
            self.mutex.lock();
            defer self.mutex.unlock();
            try self.connections.append(self.allocator, .{
                .conn = conn,
                .last_active = std.time.timestamp(),
            });
            cb_opt = self.on_connection_fn;
            ctx_opt = self.on_connection_ctx;
        }

        if (cb_opt) |cb| {
            const thread = try std.Thread.spawn(.{}, threadWrapper, .{ cb, ctx_opt.?, conn });
            thread.detach();
        }
    }

    pub fn setConnectionHandler(self: *ConnectionManager, ctx: anytype, comptime handler: fn (@TypeOf(ctx), network.Connection) anyerror!void) void {
        const ContextType = @TypeOf(ctx);
        const Wrapper = struct {
            fn wrap(c: *anyopaque, conn: network.Connection) anyerror!void {
                const typed_ctx: ContextType = @ptrCast(@alignCast(c));
                return handler(typed_ctx, conn);
            }
        };
        self.on_connection_ctx = ctx;
        self.on_connection_fn = Wrapper.wrap;
    }

    pub fn setDiscoveryHandler(self: *ConnectionManager, ctx: anytype, comptime handler: fn (@TypeOf(ctx), id.NodeID, std.net.Address) void) void {
        const ContextType = @TypeOf(ctx);
        const Wrapper = struct {
            fn wrap(c: *anyopaque, peer_id: id.NodeID, addr: std.net.Address) void {
                const typed_ctx: ContextType = @ptrCast(@alignCast(c));
                handler(typed_ctx, peer_id, addr);
            }
        };
        self.on_discovery_ctx = ctx;
        self.on_discovery_fn = Wrapper.wrap;
    }

    fn onMdnsDiscovery(ctx: ?*anyopaque, peer_id: id.NodeID, addr: std.net.Address) void {
        std.debug.print("mDNS: Discovered peer {x} at {f}\n", .{ peer_id.bytes[0..4], addr });

        if (ctx) |c| {
            const self: *ConnectionManager = @ptrCast(@alignCast(c));
            if (self.on_discovery_fn) |cb| {
                cb(self.on_discovery_ctx.?, peer_id, addr);
            }
        }
    }

    pub fn listen(self: *ConnectionManager, cfg: config.Config, running: ?*std.atomic.Value(bool)) !void {
        self.bound_port = cfg.network.port;

        // Initialize mDNS

        if (cfg.network.enable_mdns) {
            self.mdns = network.mdns.MDNS.init(
                self.allocator,
                self.node_id,
                cfg.network.port,
                network.mdns.MDNS_PORT,
                onMdnsDiscovery,
                self,
            );

            try self.mdns.?.start();
        }

        // Attempt UPnP in background
        if (cfg.network.upnp_enabled) {
            self.upnp_thread = try std.Thread.spawn(.{}, struct {
                fn run(cm: *ConnectionManager, p: u16) void {
                    cm.upnp.discoverGateway() catch |err| {
                        std.debug.print("UPnP Discovery failed: {any}\n", .{err});
                        return;
                    };

                    const local_ip = cm.upnp.getLocalIP() catch |err| {
                        std.debug.print("UPnP failed to determine local IP: {any}\n", .{err});
                        return;
                    };
                    defer cm.allocator.free(local_ip);

                    cm.upnp.mapPort(p, "TCP", local_ip) catch |err| {
                        std.debug.print("UPnP Port Mapping failed: {any}\n", .{err});
                        return;
                    };
                }
            }.run, .{ self, cfg.network.port });
        }

        switch (self.transport_type) {
            .tcp => {
                self.tcp_server = try tcp.listen(self.allocator, .{
                    .port = cfg.network.port,
                    .swarm_key = cfg.node.swarm_key,
                    .static_key = self.identity_key,
                    .running = running,
                    .manager = self,
                });
            },
            .quic => {
                return error.QuicNotImplemented;
            },
        }
    }

    pub fn connectToPeerMulti(self: *ConnectionManager, addresses: []const std.net.Address, swarm_key: []const u8, remote_node_id: ?id.NodeID) !network.Connection {
        // 1. Check existing connections first
        self.mutex.lock();
        for (self.connections.items) |*mc| {
            if (remote_node_id) |target_id| {
                if (mc.conn.getRemoteNodeID().eql(target_id)) {
                    mc.last_active = std.time.timestamp();
                    const c = mc.conn;
                    self.mutex.unlock();
                    return c;
                }
            }
            // Check if any of the target addresses match existing connection
            for (addresses) |addr| {
                if (addressesMatch(mc.conn.getPeerAddress(), addr)) {
                    mc.last_active = std.time.timestamp();
                    const c = mc.conn;
                    self.mutex.unlock();
                    return c;
                }
            }
        }
        self.mutex.unlock();

        // 2. Try dialing each address (Sorted by Priority)
        // Make a mutable copy to sort
        const sorted_addrs = try self.allocator.dupe(std.net.Address, addresses);
        defer self.allocator.free(sorted_addrs);

        const SortCtx = struct {
            pub fn lessThan(_: @This(), a: std.net.Address, b: std.net.Address) bool {
                return network.addressPriority(a) < network.addressPriority(b);
            }
        };
        std.mem.sort(std.net.Address, sorted_addrs, SortCtx{}, SortCtx.lessThan);

        for (sorted_addrs) |addr| {
            std.debug.print("ConnectionManager: Dialing {f}...\n", .{addr});
            if (self.connectToPeer(addr, swarm_key, remote_node_id)) |conn| {
                return conn;
            } else |err| {
                std.debug.print("ConnectionManager: Failed to dial {f}: {any}\n", .{ addr, err });
                continue;
            }
        }

        return error.AllAddressesFailed;
    }

    pub fn connectToPeer(self: *ConnectionManager, address: std.net.Address, swarm_key: []const u8, remote_node_id: ?id.NodeID) !network.Connection {
        self.mutex.lock();
        for (self.connections.items) |*mc| {
            // Check for NodeID match (preferred)
            if (remote_node_id) |target_id| {
                if (mc.conn.getRemoteNodeID().eql(target_id)) {
                    mc.last_active = std.time.timestamp();
                    const c = mc.conn;
                    self.mutex.unlock();
                    return c;
                }
            }

            // Check for Address match (fallback)
            if (addressesMatch(mc.conn.getPeerAddress(), address)) {
                mc.last_active = std.time.timestamp();
                const c = mc.conn;
                self.mutex.unlock();
                return c;
            }
        }
        self.mutex.unlock();

        std.debug.print("ConnectionManager: Connecting to {f} (New)\n", .{address});
        switch (self.transport_type) {
            .tcp => {
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
