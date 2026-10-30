const std = @import("std");
const builtin = @import("builtin");
const network = @import("mod.zig");
const config = @import("../../config.zig");
const tcp = @import("tcp.zig");
const noise = @import("noise.zig");
const nat = @import("nat.zig");
const id = @import("../id.zig");
const sync = @import("../../sync.zig");
const env_mod = @import("../../env.zig");
const device_auth = @import("../../device/auth.zig");

pub const TrafficCounters = struct {
    sent: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    received: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
};

pub const ConnectionManager = struct {
    const ManagedConnection = struct {
        conn: network.Connection,
        last_active: i64,
        handler_thread: ?std.Thread = null,
    };

    pub const max_connections = 256;

    allocator: std.mem.Allocator,
    connections: std.ArrayListUnmanaged(ManagedConnection),
    transport_type: config.Config.TransportType,
    identity_key: noise.KeyPair,
    node_id: id.NodeID,
    bound_port: u16 = 0,
    mutex: sync.Mutex = .{},
    stop_mutex: sync.Mutex = .{},
    on_connection_ctx: ?*anyopaque = null,
    on_connection_fn: ?*const fn (ctx: *anyopaque, conn: network.Connection) anyerror!void = null,
    on_discovery_ctx: ?*anyopaque = null,
    on_discovery_fn: ?*const fn (ctx: *anyopaque, peer_id: id.NodeID, addr: network.Address) void = null,
    reaper_thread: ?std.Thread = null,
    upnp_thread: ?std.Thread = null,
    accept_thread: ?std.Thread = null,
    running: std.atomic.Value(bool) = std.atomic.Value(bool).init(true),
    idle_timeout: i64 = 60 * 5,
    handshake_timeout_ms: u32 = tcp.default_handshake_timeout_ms,
    reap_interval_ms: u64 = 10000,
    upnp: nat.UPnP,
    mdns: ?network.mdns.MDNS = null,
    ref_count: std.atomic.Value(usize) = std.atomic.Value(usize).init(1),
    handshake_wg: sync.WaitGroup = .{},
    handshakes: tcp.Handshakes = .{},
    stopping: bool = false,
    tcp_server: ?network.Server = null,
    heap_allocated: bool = false,
    device_auth: ?device_auth.Authenticator = null,
    /// Reaches a device through another one when none of its addresses
    /// answers (discovery/node.zig sets it; transport/relay.zig).
    relay_dialer: ?RelayDialer = null,
    traffic: TrafficCounters = .{},
    /// Devices that just failed every address and the relay: dialing them
    /// again fails at once until `until_ms`, so a device that is gone (an
    /// old identity, a phone off) costs one round of timeouts, not one per
    /// caller. Guarded by `mutex`.
    dial_backoff: [max_dial_backoff]DialBackoff = @splat(.{}),

    pub const max_dial_backoff = 64;
    const backoff_first_ms: i64 = 30 * std.time.ms_per_s;
    const backoff_max_ms: i64 = 10 * std.time.ms_per_min;
    const DialBackoff = struct {
        peer: ?id.NodeID = null,
        until_ms: i64 = 0,
        failures: u8 = 0,
    };

    pub const RelayDialer = struct {
        ctx: *anyopaque,
        /// A connection reference the caller must deinit().
        dialFn: *const fn (ctx: *anyopaque, target: id.NodeID) anyerror!network.Connection,
    };

    pub fn init(allocator: std.mem.Allocator, transport_type: config.Config.TransportType, key_path: ?[]const u8) !ConnectionManager {
        const keypair = try loadOrGenerateKey(allocator, key_path);
        return initExplicit(allocator, transport_type, keypair);
    }

    pub fn create(allocator: std.mem.Allocator, transport_type: config.Config.TransportType, key_path: ?[]const u8) !*ConnectionManager {
        const keypair = try loadOrGenerateKey(allocator, key_path);
        return createExplicit(allocator, transport_type, keypair);
    }

    pub fn createExplicit(allocator: std.mem.Allocator, transport_type: config.Config.TransportType, keypair: noise.KeyPair) !*ConnectionManager {
        const self = try allocator.create(ConnectionManager);
        self.* = initExplicit(allocator, transport_type, keypair);
        self.heap_allocated = true;
        return self;
    }

    pub fn initExplicit(allocator: std.mem.Allocator, transport_type: config.Config.TransportType, keypair: noise.KeyPair) ConnectionManager {
        return .{
            .allocator = allocator,
            .connections = .empty,
            .transport_type = transport_type,
            .identity_key = keypair,
            .node_id = id.NodeID.fromPublicKey(keypair.public_key),
            .bound_port = 0,
            .mutex = .{},
            .stop_mutex = .{},
            .on_connection_ctx = null,
            .on_connection_fn = null,
            .reaper_thread = null,
            .upnp_thread = null,
            .accept_thread = null,
            .running = std.atomic.Value(bool).init(true),
            .upnp = nat.UPnP.init(allocator),
            .mdns = null,
            .ref_count = std.atomic.Value(usize).init(1),
            .stopping = false,
            .tcp_server = null,
            .heap_allocated = false,
        };
    }

    /// Enables device identity verification for every new connection.
    pub fn setDeviceAuthenticator(self: *ConnectionManager, auth: device_auth.Authenticator) void {
        self.device_auth = auth;
    }

    pub fn deviceAuthPtr(self: *ConnectionManager) ?*const device_auth.Authenticator {
        if (self.device_auth) |*auth| return auth;
        return null;
    }

    pub fn ref(self: *ConnectionManager) void {
        _ = self.ref_count.fetchAdd(1, .acquire);
    }

    pub fn deinit(self: *ConnectionManager) void {
        if (self.ref_count.fetchSub(1, .acq_rel) == 1) {
            // Ensure we have visibility of all modifications before destruction
            const allocator = self.allocator;
            const is_heap = self.heap_allocated;
            self.stop();
            if (self.mdns) |*m| {
                m.deinit();
            }
            self.connections.deinit(allocator);
            self.upnp.deinit();
            if (is_heap) {
                allocator.destroy(self);
            }
        }
    }

    pub fn start(self: *ConnectionManager) !void {
        self.stop_mutex.lock();
        defer self.stop_mutex.unlock();

        if (self.reaper_thread != null) return;
        self.mutex.lock();
        self.stopping = false;
        self.mutex.unlock();
        self.handshakes.restart();

        self.running.store(true, .release);
        self.reaper_thread = try std.Thread.spawn(.{}, ConnectionManager.runReaper, .{self});

        // Start mDNS
        if (self.mdns) |*m| {
            try m.start();
        }
    }

    /// Public wrapper for callers that need the node transport key without
    /// constructing a manager, such as device pairing.
    pub fn loadOrCreateKey(allocator: std.mem.Allocator, explicit_path: ?[]const u8) !noise.KeyPair {
        return loadOrGenerateKey(allocator, explicit_path);
    }

    /// Loads the node key, generating one only where none exists yet. An
    /// existing but unreadable or corrupt key is an error: replacing it
    /// would silently change the node's identity.
    fn loadOrGenerateKey(allocator: std.mem.Allocator, explicit_path: ?[]const u8) !noise.KeyPair {
        if (explicit_path) |path| return loadOrCreateKeyAt(path);

        const key_filename = "node.key";

        // 1. Try CWD
        if (noise.KeyPair.loadFromFile(key_filename)) |kp| {
            return kp;
        } else |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        }

        // 2. Try Home directory
        const home_env = if (builtin.os.tag == .windows) "USERPROFILE" else "HOME";
        if (env_mod.getEnv(allocator, home_env)) |home| {
            defer allocator.free(home);
            const dot_nomad = try std.fs.path.join(allocator, &.{ home, ".nomadfs" });
            defer allocator.free(dot_nomad);

            // Ensure directory exists
            const io = std.Io.Threaded.global_single_threaded.io();
            std.Io.Dir.cwd().createDirPath(io, dot_nomad) catch {};

            const key_path = try std.fs.path.join(allocator, &.{ dot_nomad, key_filename });
            defer allocator.free(key_path);
            return loadOrCreateKeyAt(key_path);
        }

        // 3. Fallback: Generate and save in CWD
        return loadOrCreateKeyAt(key_filename);
    }

    fn loadOrCreateKeyAt(path: []const u8) !noise.KeyPair {
        if (noise.KeyPair.loadFromFile(path)) |kp| {
            return kp;
        } else |err| switch (err) {
            error.FileNotFound => {},
            else => {
                std.debug.print("Refusing to replace unusable key file '{s}': {any}\n", .{ path, err });
                return err;
            },
        }
        const kp = noise.KeyPair.generate();
        try kp.saveToFile(path);
        return kp;
    }

    pub fn stop(self: *ConnectionManager) void {
        self.stop_mutex.lock();
        defer self.stop_mutex.unlock();

        self.mutex.lock();
        if (self.stopping) {
            self.mutex.unlock();
            return;
        }
        self.stopping = true;

        self.running.store(false, .release);
        self.mutex.unlock();
        self.handshakes.stop();
        if (self.mdns) |*m| {
            m.stop();
        }
        if (self.tcp_server) |*s| {
            s.deinit();
            self.tcp_server = null;
        }

        if (self.accept_thread) |t| {
            t.join();
            self.accept_thread = null;
        }

        // Wait for all handshake threads to finish without holding the lock
        // as they might need to acquire it to add themselves or clean up.
        self.handshake_wg.wait();
        self.handshakes.wg.wait();

        // Collect and cleanup connections and their handler threads
        self.mutex.lock();
        while (self.connections.items.len > 0) {
            const mc = self.connections.pop().?;
            self.mutex.unlock();

            retireConnection(mc);

            self.mutex.lock();
        }
        self.mutex.unlock();

        if (self.reaper_thread) |t| {
            t.join();
            self.reaper_thread = null;
        }

        if (self.upnp_thread) |t| {
            t.join();
            self.upnp_thread = null;
        }

        // Mappings use an infinite lease; remove ours so the router does not
        // keep forwarding the port after we exit. Bounded by UPnP timeouts.
        if (self.upnp.mapped_port) |port| {
            self.upnp.deletePortMap(port, "TCP") catch |err| {
                std.debug.print("UPnP: Failed to delete port mapping {d}: {any}\n", .{ port, err });
            };
        }
    }

    fn runReaper(self: *ConnectionManager) void {
        while (self.running.load(.acquire)) {
            // Sleep in small increments
            const sleep_interval = 100; // ms
            var total_slept: u64 = 0;
            while (total_slept < self.reap_interval_ms and self.running.load(.acquire)) : (total_slept += sleep_interval) {
                sync.sleep(sleep_interval * std.time.ns_per_ms);
            }
            if (!self.running.load(.acquire)) break;

            // Maintenance may send resets. Keep references, but never keep
            // the pool locked across transport writes or shutdown cannot run.
            var active: [max_connections]network.Connection = undefined;
            self.mutex.lock();
            var active_count: usize = 0;
            for (self.connections.items) |mc| {
                const vtable = mc.conn.vtable orelse continue;
                if (vtable.maintain == null) continue;
                mc.conn.retain();
                active[active_count] = mc.conn;
                active_count += 1;
            }
            self.mutex.unlock();
            for (active[0..active_count]) |conn| {
                conn.maintain();
                conn.deinit();
            }

            self.mutex.lock();
            var i: usize = 0;
            const now = sync.timestamp();
            while (i < self.connections.items.len) {
                const mc = &self.connections.items[i];
                // A connection someone is using is active by definition.
                if (mc.conn.isInUse()) mc.last_active = now;
                const is_idle = (now - mc.last_active) > self.idle_timeout;
                const is_closed = mc.conn.isClosed();

                if (is_closed or is_idle) {
                    const removed_mc = self.connections.orderedRemove(i);
                    self.mutex.unlock();
                    retireConnection(removed_mc);
                    self.mutex.lock();
                } else {
                    i += 1;
                }
            }
            self.mutex.unlock();
        }
    }

    /// Tears down a connection already removed from `connections`: signal
    /// shutdown, wait for its handler, then drop the manager's reference.
    /// Other holders keep the connection alive until they release it.
    fn retireConnection(mc: ManagedConnection) void {
        mc.conn.close();
        if (mc.handler_thread) |t| t.join();
        mc.conn.deinit();
    }

    /// Drops pooled sessions authenticated as this device or transport node.
    pub fn trafficTotals(self: *const ConnectionManager) struct { sent: u64, received: u64 } {
        return .{
            .sent = self.traffic.sent.load(.monotonic),
            .received = self.traffic.received.load(.monotonic),
        };
    }

    pub fn closePeer(self: *ConnectionManager, peer: id.NodeID) usize {
        var removed: [max_connections]ManagedConnection = undefined;
        var count: usize = 0;
        self.mutex.lock();
        var i: usize = 0;
        while (i < self.connections.items.len) {
            const conn = self.connections.items[i].conn;
            const device = conn.getRemoteDeviceID();
            if (conn.getRemoteNodeID().eql(peer) or (device != null and device.?.eql(peer))) {
                removed[count] = self.connections.orderedRemove(i);
                count += 1;
            } else i += 1;
        }
        self.mutex.unlock();
        for (removed[0..count]) |mc| mc.conn.close();
        for (removed[0..count]) |mc| retireConnection(mc);
        return count;
    }

    pub fn getConnectionsCount(self: *ConnectionManager) usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.connections.items.len;
    }

    /// Returns a new reference; the caller must deinit() it.
    pub fn getConnection(self: *ConnectionManager, index: usize) ?network.Connection {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (index >= self.connections.items.len) return null;
        const conn = self.connections.items[index].conn;
        conn.retain();
        return conn;
    }

    /// Finds a live connection and returns a new reference to it. With a
    /// node ID only the authenticated ID counts (another node may now sit at
    /// a known address); without one, any of `addresses` matches.
    /// Caller holds self.mutex.
    fn findConnectionLocked(self: *ConnectionManager, addresses: []const network.Address, remote_node_id: ?id.NodeID) ?network.Connection {
        for (self.connections.items) |*mc| {
            if (mc.conn.isClosed()) continue;
            const matches = if (remote_node_id) |target_id|
                mc.conn.getRemoteNodeID().eql(target_id)
            else for (addresses) |addr| {
                if (addressesMatch(mc.conn.getPeerAddress(), addr)) break true;
            } else false;
            if (matches) {
                mc.last_active = sync.timestamp();
                mc.conn.retain();
                return mc.conn;
            }
        }
        return null;
    }

    fn threadWrapper(cb: *const fn (*anyopaque, network.Connection) anyerror!void, ctx: *anyopaque, conn: network.Connection) void {
        cb(ctx, conn) catch |err| {
            if (err != error.SessionClosed and err != error.EndOfStream and err != error.ConnectionResetByPeer) {
                std.debug.print("Connection handler error: {any}\n", .{err});
            }
        };
    }

    /// Registers `conn` and starts its handler. On success the manager takes
    /// over the caller's reference; on error the caller still owns it and
    /// nothing was registered.
    pub fn addConnection(self: *ConnectionManager, conn: network.Connection) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.stopping) return error.ManagerStopping;
        if (self.connections.items.len >= max_connections) {
            conn.close();
            return error.TooManyConnections;
        }

        // Reserve first so that nothing can fail after the handler starts.
        try self.connections.ensureUnusedCapacity(self.allocator, 1);

        var handler_thread: ?std.Thread = null;
        if (self.on_connection_fn) |cb| {
            handler_thread = try std.Thread.spawn(.{}, threadWrapper, .{ cb, self.on_connection_ctx.?, conn });
        }

        self.connections.appendAssumeCapacity(.{
            .conn = conn,
            .last_active = sync.timestamp(),
            .handler_thread = handler_thread,
        });
        self.clearBackoffLocked(conn.getRemoteNodeID());
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

    pub fn setDiscoveryHandler(self: *ConnectionManager, ctx: anytype, comptime handler: fn (@TypeOf(ctx), id.NodeID, network.Address) void) void {
        const ContextType = @TypeOf(ctx);
        const Wrapper = struct {
            fn wrap(c: *anyopaque, peer_id: id.NodeID, addr: network.Address) void {
                const typed_ctx: ContextType = @ptrCast(@alignCast(c));
                handler(typed_ctx, peer_id, addr);
            }
        };
        self.on_discovery_ctx = ctx;
        self.on_discovery_fn = Wrapper.wrap;
    }

    fn onMdnsDiscovery(ctx: ?*anyopaque, peer_id: id.NodeID, addr: network.Address) void {
        if (ctx) |c| {
            const self: *ConnectionManager = @ptrCast(@alignCast(c));
            if (self.on_discovery_fn) |cb| {
                cb(self.on_discovery_ctx.?, peer_id, addr);
            }
        }
    }

    pub fn listen(self: *ConnectionManager, cfg: config.Config, running: ?*std.atomic.Value(bool)) !void {
        self.stop_mutex.lock();
        defer self.stop_mutex.unlock();
        _ = running;
        if (self.tcp_server != null) return;
        self.mutex.lock();
        self.stopping = false;
        self.mutex.unlock();
        self.running.store(true, .release);
        self.handshakes.restart();
        if (self.mdns) |*m| m.deinit();
        self.mdns = null;
        // Unwind every partially started service before a retry.
        errdefer {
            if (self.mdns) |*m| m.deinit();
            self.mdns = null;
            if (self.tcp_server) |*server| server.deinit();
            self.tcp_server = null;
            if (self.upnp_thread) |t| t.join();
            self.upnp_thread = null;
        }
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
                    .handshake_timeout_ms = self.handshake_timeout_ms,
                    .swarm_key = cfg.node.swarm_key,
                    .static_key = self.identity_key,
                    .running = &self.running,
                    .manager = self,
                    .device_auth = self.deviceAuthPtr(),
                });

                self.accept_thread = try std.Thread.spawn(.{}, tcp.runAcceptLoop, .{
                    self.allocator,
                    self.tcp_server.?,
                    tcp.ListenConfig{
                        .port = cfg.network.port,
                        .handshake_timeout_ms = self.handshake_timeout_ms,
                        .swarm_key = cfg.node.swarm_key,
                        .static_key = self.identity_key,
                        .running = &self.running,
                        .manager = self,
                        .device_auth = self.deviceAuthPtr(),
                    },
                });
            },
            .quic => {
                return error.QuicNotImplemented;
            },
        }
    }

    /// Returns a connection reference the caller must deinit(). When no
    /// address answers and the device is known by ID, tries to reach it
    /// through another device (relay_dialer).
    pub fn connectToPeerMulti(self: *ConnectionManager, addresses: []const network.Address, swarm_key: []const u8, remote_node_id: ?id.NodeID) !network.Connection {
        if (remote_node_id) |target| {
            if (self.existingConnection(target)) |conn| return conn;
            if (self.dialBackedOff(target)) return error.PeerUnreachable;
        }
        const conn = self.dialAny(addresses, swarm_key, remote_node_id) catch |err| {
            if (remote_node_id) |target| self.noteDialFailed(target);
            return err;
        };
        return conn;
    }

    fn dialAny(self: *ConnectionManager, addresses: []const network.Address, swarm_key: []const u8, remote_node_id: ?id.NodeID) !network.Connection {
        const direct_err = if (self.connectDirect(addresses, swarm_key, remote_node_id)) |conn| return conn else |err| err;
        const target = remote_node_id orelse return direct_err;
        const dialer = self.relay_dialer orelse return direct_err;
        if (target.eql(self.node_id)) return direct_err;
        return dialer.dialFn(dialer.ctx, target) catch |err| {
            std.debug.print("ConnectionManager: no relay reaches {x}: {any}\n", .{ target.bytes[0..4], err });
            return direct_err;
        };
    }

    /// Whether `peer` failed every address recently. Caller doesn't hold `mutex`.
    fn dialBackedOff(self: *ConnectionManager, peer: id.NodeID) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        const now = sync.monotonicMillis();
        for (&self.dial_backoff) |*b| if (b.peer) |p| if (p.eql(peer)) return now < b.until_ms;
        return false;
    }

    fn noteDialFailed(self: *ConnectionManager, peer: id.NodeID) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        const now = sync.monotonicMillis();
        // Its slot, else a free one, else the one that ends soonest.
        var slot = &self.dial_backoff[0];
        for (&self.dial_backoff) |*b| {
            if (b.peer) |p| if (p.eql(peer)) {
                slot = b;
                break;
            };
            if (b.peer == null and slot.peer != null) slot = b;
            if (b.peer != null and slot.peer != null and b.until_ms < slot.until_ms) slot = b;
        }
        const failures: u8 = if (slot.peer != null and slot.peer.?.eql(peer)) slot.failures +| 1 else 1;
        const shift: u6 = @intCast(@min(failures - 1, 5));
        slot.* = .{ .peer = peer, .failures = failures, .until_ms = now + @min(backoff_first_ms << shift, backoff_max_ms) };
    }

    /// A connection to `peer` exists (dialed or accepted): it's reachable.
    /// Caller holds `mutex`.
    fn clearBackoffLocked(self: *ConnectionManager, peer: id.NodeID) void {
        for (&self.dial_backoff) |*b| if (b.peer) |p| if (p.eql(peer)) {
            b.* = .{};
        };
    }

    /// The live connection to `node_id`, or null; a reference the caller
    /// must deinit().
    pub fn existingConnection(self: *ConnectionManager, node_id: id.NodeID) ?network.Connection {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.findConnectionLocked(&.{}, node_id);
    }

    /// References to every live connection; deinit each, then free the
    /// slice.
    pub fn liveConnections(self: *ConnectionManager, allocator: std.mem.Allocator) ![]network.Connection {
        self.mutex.lock();
        defer self.mutex.unlock();
        var out: std.ArrayList(network.Connection) = .empty;
        errdefer {
            for (out.items) |c| c.deinit();
            out.deinit(allocator);
        }
        for (self.connections.items) |mc| {
            if (mc.conn.isClosed()) continue;
            try out.ensureUnusedCapacity(allocator, 1);
            mc.conn.retain();
            out.appendAssumeCapacity(mc.conn);
        }
        return out.toOwnedSlice(allocator);
    }

    /// connectToPeerMulti without the relay: only the addresses given (a
    /// relay dialing on another device's behalf, so relays never chain).
    pub fn connectDirect(self: *ConnectionManager, addresses: []const network.Address, swarm_key: []const u8, remote_node_id: ?id.NodeID) !network.Connection {
        // 1. Check existing connections first
        {
            self.mutex.lock();
            defer self.mutex.unlock();
            if (self.stopping) return error.ManagerStopping;
            if (self.findConnectionLocked(addresses, remote_node_id)) |c| return c;
        }

        // 2. Try dialing each address (Sorted by Priority)
        // Make a mutable copy to sort
        const sorted_addrs = try self.allocator.dupe(network.Address, addresses);
        defer self.allocator.free(sorted_addrs);

        const SortCtx = struct {
            pub fn lessThan(_: @This(), a: network.Address, b: network.Address) bool {
                return network.addressPriority(a) < network.addressPriority(b);
            }
        };
        std.mem.sort(network.Address, sorted_addrs, SortCtx{}, SortCtx.lessThan);

        for (sorted_addrs) |addr| {
            // Port 0, multicast, link-local and the like can't be a peer.
            if (@import("../local_addrs.zig").classify(addr) == .invalid) continue;
            if (self.connectToPeer(addr, swarm_key, remote_node_id)) |conn| {
                return conn;
            } else |err| {
                std.debug.print("ConnectionManager: Failed to dial {f}: {any}\n", .{ addr, err });
                continue;
            }
        }

        return error.AllAddressesFailed;
    }

    /// Returns a connection reference the caller must deinit().
    pub fn connectToPeer(self: *ConnectionManager, address: network.Address, swarm_key: []const u8, remote_node_id: ?id.NodeID) !network.Connection {
        {
            self.mutex.lock();
            defer self.mutex.unlock();
            if (self.stopping) return error.ManagerStopping;
            if (self.findConnectionLocked(&.{address}, remote_node_id)) |c| return c;
        }

        switch (self.transport_type) {
            .tcp => {
                const conn = try tcp.connectTracked(self.allocator, address, swarm_key, self.identity_key, self.handshake_timeout_ms, self.deviceAuthPtr(), &self.handshakes, &self.traffic);
                errdefer conn.deinit();

                // The Noise handshake authenticated the remote key; make sure
                // it belongs to the node we meant to reach.
                if (remote_node_id) |expected| {
                    if (!conn.getRemoteNodeID().eql(expected)) return error.PeerIdMismatch;
                }

                // One reference for the manager, one for the caller.
                conn.retain();
                self.addConnection(conn) catch |err| {
                    conn.deinit();
                    return err;
                };
                return conn;
            },
            .quic => {
                return error.QuicNotImplemented;
            },
        }
    }
};

fn addressesMatch(a: network.Address, b: network.Address) bool {
    return a.eql(b);
}

const TestConnection = struct {
    node: id.NodeID,
    device: ?id.NodeID = null,
    closed: bool = false,
    released: usize = 0,
    fn stream(_: *anyopaque) anyerror!network.Stream {
        return error.SessionClosed;
    }
    fn address(_: *anyopaque) network.Address {
        return network.Address.initIp4(.{ 0, 0, 0, 0 }, 0);
    }
    fn nodeId(ctx: *anyopaque) id.NodeID {
        const self: *@This() = @ptrCast(@alignCast(ctx));
        return self.node;
    }
    fn deviceId(ctx: *anyopaque) ?id.NodeID {
        const self: *@This() = @ptrCast(@alignCast(ctx));
        return self.device;
    }
    fn close(ctx: *anyopaque) void {
        const self: *@This() = @ptrCast(@alignCast(ctx));
        self.closed = true;
    }
    fn retain(_: *anyopaque) void {}
    fn deinit(ctx: *anyopaque) void {
        const self: *@This() = @ptrCast(@alignCast(ctx));
        self.released += 1;
    }
    fn isClosed(ctx: *anyopaque) bool {
        const self: *@This() = @ptrCast(@alignCast(ctx));
        return self.closed;
    }
    fn isInUse(_: *anyopaque) bool {
        return false;
    }
    fn connection(self: *@This()) network.Connection {
        return network.Connection.init(self, &vtable);
    }
    const vtable: network.Connection.ConnectionVTable = .{
        .openStream = stream,
        .acceptStream = stream,
        .getPeerAddress = address,
        .getRemoteNodeID = nodeId,
        .getRemoteDeviceID = deviceId,
        .close = close,
        .retain = retain,
        .deinit = deinit,
        .isClosed = isClosed,
        .isInUse = isInUse,
    };
};

test "pool caps sessions and closes every matching device or node" {
    var manager = ConnectionManager.initExplicit(std.testing.allocator, .tcp, noise.KeyPair.generate());
    defer manager.deinit();
    const peer = id.NodeID{ .bytes = .{1} ** 32 };
    const other = id.NodeID{ .bytes = .{2} ** 32 };
    var mocks: [ConnectionManager.max_connections + 1]TestConnection = undefined;
    for (&mocks) |*mock| mock.* = .{ .node = other };
    mocks[0].node = peer;
    mocks[1].device = peer;
    for (mocks[0..ConnectionManager.max_connections]) |*mock| try manager.addConnection(mock.connection());
    try std.testing.expectError(error.TooManyConnections, manager.addConnection(mocks[ConnectionManager.max_connections].connection()));
    try std.testing.expect(mocks[ConnectionManager.max_connections].closed);
    try std.testing.expectEqual(@as(usize, 2), manager.closePeer(peer));
    try std.testing.expectEqual(@as(usize, 0), manager.closePeer(peer));
    try std.testing.expect(mocks[0].closed and mocks[1].closed);
    try std.testing.expectEqual(@as(usize, 1), mocks[0].released);
    try std.testing.expectEqual(@as(usize, ConnectionManager.max_connections - 2), manager.getConnectionsCount());
    manager.stop();
    for (mocks[0..ConnectionManager.max_connections]) |mock| try std.testing.expectEqual(@as(usize, 1), mock.released);
}

test "stop joins mDNS callbacks without the pool mutex" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var manager = ConnectionManager.initExplicit(std.testing.allocator, .tcp, noise.KeyPair.generate());
    defer manager.deinit();
    manager.mdns = network.mdns.MDNS.init(std.testing.allocator, manager.node_id, 0, 0, ConnectionManager.onMdnsDiscovery, &manager);
    manager.mdns.?.running.store(true, .release);
    manager.mdns.?.thread = try std.Thread.spawn(.{}, struct {
        fn run(cm: *ConnectionManager) void {
            while (cm.mdns.?.running.load(.acquire)) sync.sleep(std.time.ns_per_ms);
            cm.mutex.lock();
            defer cm.mutex.unlock();
        }
    }.run, .{&manager});
    manager.stop();
    try std.testing.expect(manager.mdns.?.thread == null);
}

test "listen is idempotent and can restart after stop" {
    var manager = ConnectionManager.initExplicit(std.testing.allocator, .tcp, noise.KeyPair.generate());
    defer manager.deinit();
    const cfg = config.Config{
        .node = .{ .nickname = "test", .swarm_key = "x" ** 32 },
        .storage = .{ .enabled = false, .storage_path = "" },
        .network = .{ .port = 0, .bootstrap_peers = &.{}, .transport = .tcp, .upnp_enabled = false, .enable_mdns = false },
    };
    try manager.start();
    try manager.listen(cfg, null);
    const handle = manager.tcp_server.?.inner.socket.handle;
    try manager.listen(cfg, null);
    try std.testing.expectEqual(handle, manager.tcp_server.?.inner.socket.handle);
    manager.stop();
    try std.testing.expect(manager.accept_thread == null and manager.tcp_server == null);
    try manager.start();
    try manager.listen(cfg, null);
    try std.testing.expect(manager.accept_thread != null and manager.tcp_server != null);
    manager.stop();
}

test "manager: a device that failed every address is not dialed again until its backoff ends" {
    const manager = try ConnectionManager.createExplicit(std.testing.allocator, .tcp, noise.KeyPair.generate());
    defer manager.deinit();
    const peer = id.NodeID{ .bytes = [_]u8{0x42} ** 32 };
    try std.testing.expect(!manager.dialBackedOff(peer));
    manager.noteDialFailed(peer);
    try std.testing.expect(manager.dialBackedOff(peer));
    // Fails at once, without dialing (no address would answer anyway).
    try std.testing.expectError(error.PeerUnreachable, manager.connectToPeerMulti(&.{}, "", peer));
    manager.mutex.lock();
    manager.clearBackoffLocked(peer);
    manager.mutex.unlock();
    try std.testing.expect(!manager.dialBackedOff(peer));
}
