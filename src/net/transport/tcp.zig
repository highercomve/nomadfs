const std = @import("std");
const network = @import("mod.zig");
const noise = @import("noise.zig");
const device_auth = @import("../../device/auth.zig");
const YamuxSession = @import("yamux.zig").Session;

const sync = @import("../../sync.zig");

const id = @import("../id.zig");

/// Concrete implementation for TCP/Noise/Yamux.
///
/// Reference counted (see network.Connection). close() shuts the socket down
/// and wakes every waiter; the final deinit() joins the Yamux reader, then
/// frees the session, its streams, the Noise buffers and the descriptor.
const TcpConnectionImpl = struct {
    tcp_stream: TcpStream,
    noise_stream: noise.NoiseStream,
    yamux: *YamuxSession,
    yamux_thread: std.Thread,
    allocator: std.mem.Allocator,
    peer_address: network.Address,
    closed: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    refs: std.atomic.Value(u32) = std.atomic.Value(u32).init(1),

    pub fn connection(self: *TcpConnectionImpl) network.Connection {
        return network.Connection.init(self, &tcp_connection_vtable);
    }

    /// Implements network.Connection.openStream
    pub fn openStream(ctx: *anyopaque) anyerror!network.Stream {
        const self: *TcpConnectionImpl = @ptrCast(@alignCast(ctx));

        // Ask Yamux to allocate a new stream ID and structure
        const yamux_stream = try self.yamux.newStream();

        // Return the abstract interface pointing to our concrete Yamux stream
        return network.Stream.init(yamux_stream, &yamux_stream_vtable);
    }

    pub fn acceptStream(ctx: *anyopaque) anyerror!network.Stream {
        const self: *TcpConnectionImpl = @ptrCast(@alignCast(ctx));
        const yamux_stream = try self.yamux.acceptStream();

        return network.Stream.init(yamux_stream, &yamux_stream_vtable);
    }

    pub fn getPeerAddress(ctx: *anyopaque) network.Address {
        const self: *TcpConnectionImpl = @ptrCast(@alignCast(ctx));
        return self.peer_address;
    }

    pub fn getRemoteNodeID(ctx: *anyopaque) id.NodeID {
        const self: *TcpConnectionImpl = @ptrCast(@alignCast(ctx));
        return id.NodeID.fromPublicKey(self.noise_stream.remote_static);
    }

    pub fn getRemoteDeviceID(ctx: *anyopaque) ?id.NodeID {
        const self: *TcpConnectionImpl = @ptrCast(@alignCast(ctx));
        return self.noise_stream.remote_device_id;
    }

    pub fn isClosed(ctx: *anyopaque) bool {
        const self: *TcpConnectionImpl = @ptrCast(@alignCast(ctx));
        return self.closed.load(.acquire) or self.yamux.isClosed();
    }

    /// The manager holds one reference; any other reference or a live stream
    /// means the connection is in use.
    fn maintain(ctx: *anyopaque) void {
        const self: *TcpConnectionImpl = @ptrCast(@alignCast(ctx));
        self.yamux.reapClosed(@import("../../sync.zig").monotonicMillis());
    }

    pub fn isInUse(ctx: *anyopaque) bool {
        const self: *TcpConnectionImpl = @ptrCast(@alignCast(ctx));
        const streams = self.yamux.streamCount();
        return self.refs.load(.acquire) > 1 or streams > 0;
    }

    /// Signals shutdown. Safe while other threads still use the connection.
    pub fn close(ctx: *anyopaque) void {
        const self: *TcpConnectionImpl = @ptrCast(@alignCast(ctx));
        if (self.closed.swap(true, .acq_rel)) return;

        // Shutdown (not close) the socket: the Yamux reader may be blocked in
        // read() on this descriptor, so it must stay allocated until joined.
        self.tcp_stream.shutdown();
        self.yamux.close();
    }

    pub fn retain(ctx: *anyopaque) void {
        const self: *TcpConnectionImpl = @ptrCast(@alignCast(ctx));
        const prev = self.refs.fetchAdd(1, .monotonic);
        std.debug.assert(prev > 0);
    }

    /// Drops one reference; the last one tears the connection down.
    pub fn deinit(ctx: *anyopaque) void {
        const self: *TcpConnectionImpl = @ptrCast(@alignCast(ctx));
        const prev = self.refs.fetchSub(1, .acq_rel);
        std.debug.assert(prev > 0);
        if (prev != 1) return;

        TcpConnectionImpl.close(ctx);
        self.yamux_thread.join();
        self.yamux.deinit();
        self.noise_stream.deinit(); // Releases the descriptor.
        self.allocator.destroy(self);
    }
};

const tcp_connection_vtable = network.Connection.ConnectionVTable{
    .openStream = TcpConnectionImpl.openStream,
    .acceptStream = TcpConnectionImpl.acceptStream,
    .getPeerAddress = TcpConnectionImpl.getPeerAddress,
    .getRemoteNodeID = TcpConnectionImpl.getRemoteNodeID,
    .getRemoteDeviceID = TcpConnectionImpl.getRemoteDeviceID,
    .close = TcpConnectionImpl.close,
    .retain = TcpConnectionImpl.retain,
    .deinit = TcpConnectionImpl.deinit,
    .isClosed = TcpConnectionImpl.isClosed,
    .isInUse = TcpConnectionImpl.isInUse,
    .maintain = TcpConnectionImpl.maintain,
};

const yamux_stream_vtable = network.Stream.StreamVTable{
    .read = YamuxSession.streamRead,
    .write = YamuxSession.streamWrite,
    .close = YamuxSession.streamClose,
    .setTimeout = YamuxSession.streamSetTimeout,
    .shutdown = YamuxSession.streamShutdown,
};

/// Fixed pre-authentication budget; descriptors stay registered until their
/// owner removes them before close, so stop never shuts down a reused fd.
pub const Handshakes = struct {
    pub const limit = 64;
    mutex: sync.Mutex = .{},
    sockets: [limit]?network.TcpStream = .{null} ** limit,
    stopping: bool = false,
    wg: sync.WaitGroup = .{},

    fn add(self: *Handshakes, socket: network.TcpStream) ?usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.stopping) return null;
        for (&self.sockets, 0..) |*entry, i| {
            if (entry.* == null) {
                entry.* = socket;
                self.wg.start();
                return i;
            }
        }
        return null;
    }

    fn remove(self: *Handshakes, slot: usize) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.sockets[slot] = null;
    }

    pub fn restart(self: *Handshakes) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.stopping = false;
    }

    pub fn stop(self: *Handshakes) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.stopping = true;
        for (self.sockets) |socket| if (socket) |stream| stream.shutdown();
    }
};

pub const TcpStream = struct {
    net_stream: network.TcpStream,
    deadline_ms: ?i64 = null,
    handshakes: ?*Handshakes = null,
    handshake_slot: usize = 0,
    closed: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    pub fn stream(self: *TcpStream) network.Stream {
        return network.Stream.init(self, &tcp_stream_vtable);
    }

    fn read(ptr: *anyopaque, buffer: []u8) anyerror!usize {
        const self: *TcpStream = @ptrCast(@alignCast(ptr));
        try self.boundOperation();
        return self.net_stream.read(buffer);
    }

    fn write(ptr: *anyopaque, buffer: []const u8) anyerror!usize {
        const self: *TcpStream = @ptrCast(@alignCast(ptr));
        try self.boundOperation();
        return self.net_stream.write(buffer);
    }

    fn boundOperation(self: *TcpStream) !void {
        const deadline = self.deadline_ms orelse return;
        const remaining = deadline - sync.monotonicMillis();
        if (remaining <= 0) return error.HandshakeTimedOut;
        try self.net_stream.setTimeout(@intCast(remaining));
    }

    fn untrack(self: *TcpStream) void {
        if (self.handshakes) |h| h.remove(self.handshake_slot);
        self.handshakes = null;
    }

    /// Unblocks readers and writers; the descriptor stays valid.
    fn shutdown(self: *TcpStream) void {
        if (self.closed.load(.acquire)) return;
        self.net_stream.shutdown();
    }

    fn close(ptr: *anyopaque) void {
        const self: *TcpStream = @ptrCast(@alignCast(ptr));
        if (self.closed.swap(true, .acq_rel)) return;
        self.untrack();
        self.net_stream.close();
    }
};

const tcp_stream_vtable = network.Stream.StreamVTable{
    .read = TcpStream.read,
    .write = TcpStream.write,
    .close = TcpStream.close,
};

/// Upper bound on the Noise handshake. Without it a peer that connects and
/// stays silent pins a handshake thread and blocks manager shutdown.
pub const default_handshake_timeout_ms: u32 = 10_000;

pub const ListenConfig = struct {
    port: u16,
    handshake_timeout_ms: u32 = default_handshake_timeout_ms,
    swarm_key: []const u8,
    static_key: noise.KeyPair,
    running: ?*std.atomic.Value(bool) = null,
    manager: ?*network.manager.ConnectionManager = null,
    device_auth: ?*const device_auth.Authenticator = null,
};

pub fn listen(_: std.mem.Allocator, cfg: ListenConfig) !network.Server {
    std.debug.print("Listening for TCP connections on port {d}...\n", .{cfg.port});
    return network.compat.listen(cfg.port);
}

pub fn runAcceptLoop(allocator: std.mem.Allocator, mut_server: network.Server, cfg: ListenConfig) void {
    acceptLoop(allocator, mut_server, cfg);
}

fn acceptLoop(allocator: std.mem.Allocator, mut_server: network.Server, cfg: ListenConfig) void {
    // We work on a copy of the server struct, but it shares the underlying FD.
    var server = mut_server;
    var local_handshakes: Handshakes = .{};
    const handshakes = if (cfg.manager) |m| &m.handshakes else &local_handshakes;
    defer handshakes.wg.wait();

    while (cfg.running == null or cfg.running.?.load(.acquire)) {
        const conn = server.accept() catch |err| {
            // If the socket was closed (e.g. by stop()), we expect an error.
            if (cfg.running != null and !cfg.running.?.load(.acquire)) break;
            // Also check for specific errors that imply closure?
            // For now, if running is false, we break.
            // If running is true but accept failed, it might be a temporary error or the socket was closed externally.
            if (err == error.ProcessFdQuotaExceeded or err == error.SystemFdQuotaExceeded or err == error.SystemResources)
                sync.sleep(100 * std.time.ns_per_ms);
            if (err == error.SocketNotBound or err == error.FileDescriptorClosed or err == error.OperationAborted or err == error.ConnectionAborted) break;
            continue;
        };
        const slot = handshakes.add(conn.stream) orelse {
            conn.stream.close();
            continue;
        };

        if (cfg.manager) |m| {
            m.ref();
            m.handshake_wg.start();
        }

        const thread = std.Thread.spawn(.{}, handleIncomingConnection, .{
            allocator,
            conn,
            cfg.swarm_key,
            cfg.static_key,
            cfg.handshake_timeout_ms,
            cfg.manager,
            cfg.device_auth,
            handshakes,
            slot,
        }) catch {
            handshakes.remove(slot);
            handshakes.wg.finish();
            conn.stream.close();
            if (cfg.manager) |m| {
                m.handshake_wg.finish();
                m.deinit();
            }
            continue;
        };
        thread.detach();
    }
    std.debug.print("TCP Accept loop exiting.\n", .{});
}

fn handleIncomingConnection(
    allocator: std.mem.Allocator,
    conn: network.Server.Connection,
    swarm_key: []const u8,
    static_key: noise.KeyPair,
    handshake_timeout_ms: u32,
    manager: ?*network.manager.ConnectionManager,
    device_auth_opt: ?*const device_auth.Authenticator,
    handshakes: *Handshakes,
    slot: usize,
) void {
    defer {
        handshakes.wg.finish();
        if (manager) |m| {
            m.handshake_wg.finish();
            m.deinit();
        }
    }

    const connection = establish(allocator, conn.stream, conn.address, swarm_key, static_key, false, handshake_timeout_ms, device_auth_opt, handshakes, slot) catch {
        return;
    };

    const m = manager orelse {
        connection.deinit();
        return;
    };
    // On success the manager owns our reference; on failure we still do.
    m.addConnection(connection) catch |err| {
        std.debug.print("Failed to register connection from {f}: {}\n", .{ conn.address, err });
        connection.deinit();
    };
}

/// Bound on a TCP connect; the Noise handshake keeps its own, longer one.
pub const connect_timeout_ms: u32 = 3000;

pub fn connect(
    allocator: std.mem.Allocator,
    address: network.Address,
    swarm_key: []const u8,
    static_key: noise.KeyPair,
    handshake_timeout_ms: u32,
    device_auth_opt: ?*const device_auth.Authenticator,
) !network.Connection {
    return connectTracked(allocator, address, swarm_key, static_key, handshake_timeout_ms, device_auth_opt, null);
}

pub fn connectTracked(
    allocator: std.mem.Allocator,
    address: network.Address,
    swarm_key: []const u8,
    static_key: noise.KeyPair,
    handshake_timeout_ms: u32,
    device_auth_opt: ?*const device_auth.Authenticator,
    handshakes: ?*Handshakes,
) !network.Connection {
    // A device has several addresses (LAN, Tailscale, ...) and the caller
    // tries them in turn: away from home the LAN one can hang until the
    // timeout, so the TCP connect gets a short bound of its own.
    const stream = try network.compat.tcpConnectToAddressTimeout(address, @min(handshake_timeout_ms, connect_timeout_ms));
    const slot = if (handshakes) |h| h.add(stream) orelse {
        stream.close();
        return error.TooManyHandshakes;
    } else 0;
    defer if (handshakes) |h| h.wg.finish();
    return establish(allocator, stream, address, swarm_key, static_key, true, handshake_timeout_ms, device_auth_opt, handshakes, slot);
}

/// Runs the Noise handshake and starts Yamux over `net_stream`, returning a
/// connection holding one reference. Takes ownership of the socket: on error
/// every partially initialized resource, including the socket, is released.
fn establish(
    allocator: std.mem.Allocator,
    net_stream: network.TcpStream,
    address: network.Address,
    swarm_key: []const u8,
    static_key: noise.KeyPair,
    initiator: bool,
    handshake_timeout_ms: u32,
    device_auth_opt: ?*const device_auth.Authenticator,
    handshakes: ?*Handshakes,
    slot: usize,
) !network.Connection {
    std.debug.assert(handshake_timeout_ms > 0);
    net_stream.setNoDelay();
    const impl = allocator.create(TcpConnectionImpl) catch |err| {
        if (handshakes) |h| h.remove(slot);
        net_stream.close();
        return err;
    };
    errdefer allocator.destroy(impl);

    impl.* = .{
        .tcp_stream = .{
            .net_stream = net_stream,
            .deadline_ms = sync.monotonicMillis() + handshake_timeout_ms,
            .handshakes = handshakes,
            .handshake_slot = slot,
        },
        .noise_stream = undefined,
        .yamux = undefined,
        .yamux_thread = undefined,
        .allocator = allocator,
        .peer_address = address,
    };
    // Guarded by TcpStream.closed, so the Noise cleanup below closing the
    // same socket first is harmless.
    errdefer TcpStream.close(&impl.tcp_stream);

    try net_stream.setTimeout(handshake_timeout_ms);
    impl.noise_stream = try noise.NoiseStream.handshake(allocator, impl.tcp_stream.stream(), swarm_key, static_key, initiator, device_auth_opt);
    errdefer impl.noise_stream.deinit();
    try impl.tcp_stream.boundOperation();
    impl.tcp_stream.untrack();
    impl.tcp_stream.deadline_ms = null;
    // Established connections idle legitimately; Yamux reads block forever.
    try net_stream.setTimeout(0);

    impl.yamux = try YamuxSession.init(allocator, impl.noise_stream.stream(), !initiator);
    errdefer impl.yamux.deinit();

    impl.yamux_thread = try std.Thread.spawn(.{}, YamuxSession.run, .{impl.yamux});
    return impl.connection();
}

test "pre-auth budget caps sockets and stop interrupts silent peers" {
    if (@import("builtin").os.tag != .linux) return error.SkipZigTest;
    const linux = std.os.linux;
    var fds: [2]i32 = undefined;
    try std.testing.expect(linux.errno(linux.socketpair(linux.AF.UNIX, linux.SOCK.STREAM, 0, &fds)) == .SUCCESS);
    const address = network.Address.initIp4(.{ 0, 0, 0, 0 }, 0).ip;
    const socket = network.TcpStream{ .inner = .{ .socket = .{ .handle = fds[0], .address = address } } };
    const peer = network.TcpStream{ .inner = .{ .socket = .{ .handle = fds[1], .address = address } } };
    defer socket.close();
    defer peer.close();
    var h: Handshakes = .{};
    for (0..Handshakes.limit) |i| try std.testing.expectEqual(i, h.add(socket).?);
    try std.testing.expect(h.add(socket) == null);
    h.stop();
    var byte: [1]u8 = undefined;
    try peer.setTimeout(100);
    try std.testing.expectEqual(@as(usize, 0), try peer.read(&byte));
    try std.testing.expect(h.add(socket) == null);
    for (0..Handshakes.limit) |i| {
        h.remove(i);
        h.wg.finish();
    }
    h.wg.wait();
    h.restart();
    const slot = h.add(socket).?;
    h.remove(slot);
    h.wg.finish();
}

test "TCP handshake deadline survives a drip-fed byte stream" {
    if (@import("builtin").os.tag != .linux) return error.SkipZigTest;
    const linux = std.os.linux;
    var fds: [2]i32 = undefined;
    try std.testing.expect(linux.errno(linux.socketpair(linux.AF.UNIX, linux.SOCK.STREAM, 0, &fds)) == .SUCCESS);
    const address = network.Address.initIp4(.{ 0, 0, 0, 0 }, 0).ip;
    var socket = TcpStream{ .net_stream = .{ .inner = .{ .socket = .{ .handle = fds[0], .address = address } } }, .deadline_ms = sync.monotonicMillis() + 80 };
    const peer = network.TcpStream{ .inner = .{ .socket = .{ .handle = fds[1], .address = address } } };
    defer peer.close();
    defer TcpStream.close(&socket);
    const writer = try std.Thread.spawn(.{}, struct {
        fn run(stream: network.TcpStream) void {
            for (0..20) |_| {
                _ = stream.write("x") catch return;
                sync.sleep(10 * std.time.ns_per_ms);
            }
        }
    }.run, .{peer});
    defer writer.join();
    const started = sync.monotonicMillis();
    var byte: [1]u8 = undefined;
    var expired = false;
    for (0..40) |_| {
        _ = TcpStream.read(&socket, &byte) catch |err| {
            try std.testing.expect(err == error.HandshakeTimedOut or err == error.WouldBlock);
            expired = true;
            break;
        };
    }
    try std.testing.expect(expired);
    try std.testing.expect(sync.monotonicMillis() - started < 500);
}
