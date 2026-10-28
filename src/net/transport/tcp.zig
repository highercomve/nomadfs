const std = @import("std");
const network = @import("mod.zig");
const noise = @import("noise.zig");
const device_auth = @import("../../device/auth.zig");
const YamuxSession = @import("yamux.zig").Session;

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
    pub fn isInUse(ctx: *anyopaque) bool {
        const self: *TcpConnectionImpl = @ptrCast(@alignCast(ctx));
        return self.refs.load(.acquire) > 1 or self.yamux.streamCount() > 0;
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
};

const yamux_stream_vtable = network.Stream.StreamVTable{
    .read = YamuxSession.streamRead,
    .write = YamuxSession.streamWrite,
    .close = YamuxSession.streamClose,
    .setTimeout = YamuxSession.streamSetTimeout,
};

pub const TcpStream = struct {
    net_stream: network.TcpStream,
    closed: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    pub fn stream(self: *TcpStream) network.Stream {
        return network.Stream.init(self, &tcp_stream_vtable);
    }

    fn read(ptr: *anyopaque, buffer: []u8) anyerror!usize {
        const self: *TcpStream = @ptrCast(@alignCast(ptr));
        return self.net_stream.read(buffer);
    }

    fn write(ptr: *anyopaque, buffer: []const u8) anyerror!usize {
        const self: *TcpStream = @ptrCast(@alignCast(ptr));
        return self.net_stream.write(buffer);
    }

    /// Unblocks readers and writers; the descriptor stays valid.
    fn shutdown(self: *TcpStream) void {
        if (self.closed.load(.acquire)) return;
        self.net_stream.shutdown();
    }

    fn close(ptr: *anyopaque) void {
        const self: *TcpStream = @ptrCast(@alignCast(ptr));
        if (self.closed.swap(true, .acq_rel)) return;
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

    while (cfg.running == null or cfg.running.?.load(.acquire)) {
        const conn = server.accept() catch |err| {
            // If the socket was closed (e.g. by stop()), we expect an error.
            if (cfg.running != null and !cfg.running.?.load(.acquire)) break;
            // Also check for specific errors that imply closure?
            // For now, if running is false, we break.
            // If running is true but accept failed, it might be a temporary error or the socket was closed externally.
            std.debug.print("Accept error: {any}\n", .{err});
            if (err == error.SocketNotBound or err == error.FileDescriptorClosed or err == error.OperationAborted or err == error.ConnectionAborted) break;
            continue;
        };
        std.debug.print("Accepted connection from {f}\n", .{conn.address});

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
        }) catch |err| {
            std.debug.print("Failed to spawn connection handler thread: {any}\n", .{err});
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
) void {
    defer if (manager) |m| {
        m.handshake_wg.finish();
        m.deinit();
    };

    const connection = establish(allocator, conn.stream, conn.address, swarm_key, static_key, false, handshake_timeout_ms, device_auth_opt) catch |err| {
        std.debug.print("Connection handler error for {f}: {}\n", .{ conn.address, err });
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

pub fn connect(
    allocator: std.mem.Allocator,
    address: network.Address,
    swarm_key: []const u8,
    static_key: noise.KeyPair,
    handshake_timeout_ms: u32,
    device_auth_opt: ?*const device_auth.Authenticator,
) !network.Connection {
    // The handshake bound doubles as the connect bound.
    const stream = try network.compat.tcpConnectToAddressTimeout(address, handshake_timeout_ms);
    return establish(allocator, stream, address, swarm_key, static_key, true, handshake_timeout_ms, device_auth_opt);
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
) !network.Connection {
    std.debug.assert(handshake_timeout_ms > 0);
    net_stream.setNoDelay();
    const impl = allocator.create(TcpConnectionImpl) catch |err| {
        net_stream.close();
        return err;
    };
    errdefer allocator.destroy(impl);

    impl.* = .{
        .tcp_stream = .{ .net_stream = net_stream },
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
    // Established connections idle legitimately; Yamux reads block forever.
    try net_stream.setTimeout(0);

    impl.yamux = try YamuxSession.init(allocator, impl.noise_stream.stream(), !initiator);
    errdefer impl.yamux.deinit();

    impl.yamux_thread = try std.Thread.spawn(.{}, YamuxSession.run, .{impl.yamux});
    return impl.connection();
}
