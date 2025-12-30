const std = @import("std");
const network = @import("mod.zig");
const noise = @import("noise.zig");
const YamuxSession = @import("yamux.zig").Session;

const id = @import("../id.zig");

/// Concrete implementation for TCP/Noise/Yamux
const TcpConnectionImpl = struct {
    tcp_stream: TcpStream,
    noise_stream: noise.NoiseStream,
    yamux: *YamuxSession,
    yamux_thread: std.Thread,
    allocator: std.mem.Allocator,
    peer_address: std.net.Address,
    closed: bool = false,

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

    pub fn getPeerAddress(ctx: *anyopaque) std.net.Address {
        const self: *TcpConnectionImpl = @ptrCast(@alignCast(ctx));
        return self.peer_address;
    }

    pub fn getRemoteNodeID(ctx: *anyopaque) id.NodeID {
        const self: *TcpConnectionImpl = @ptrCast(@alignCast(ctx));
        return id.NodeID.fromPublicKey(self.noise_stream.remote_static);
    }

    pub fn isClosed(ctx: *anyopaque) bool {
        const self: *TcpConnectionImpl = @ptrCast(@alignCast(ctx));
        return self.closed or self.yamux.closed;
    }

    pub fn close(ctx: *anyopaque) void {
        const self: *TcpConnectionImpl = @ptrCast(@alignCast(ctx));
        if (self.closed) return;
        self.closed = true;

        // 1. Close underlying noise stream (which closes TCP)
        // This will cause yamux_thread to exit
        var ns = self.noise_stream.stream();
        ns.close();

        // 2. Join thread and clean up yamux session
        self.yamux_thread.join();
        self.yamux.deinit();
    }

    pub fn deinit(ctx: *anyopaque) void {
        const self: *TcpConnectionImpl = @ptrCast(@alignCast(ctx));
        TcpConnectionImpl.close(ctx);
        self.allocator.destroy(self);
    }
};

const tcp_connection_vtable = network.Connection.ConnectionVTable{
    .openStream = TcpConnectionImpl.openStream,
    .acceptStream = TcpConnectionImpl.acceptStream,
    .getPeerAddress = TcpConnectionImpl.getPeerAddress,
    .getRemoteNodeID = TcpConnectionImpl.getRemoteNodeID,
    .close = TcpConnectionImpl.close,
    .deinit = TcpConnectionImpl.deinit,
    .isClosed = TcpConnectionImpl.isClosed,
};

const yamux_stream_vtable = network.Stream.StreamVTable{
    .read = YamuxSession.streamRead,
    .write = YamuxSession.streamWrite,
    .close = YamuxSession.streamClose,
};

pub const TcpStream = struct {
    net_stream: std.net.Stream,
    closed: bool = false,

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

    fn close(ptr: *anyopaque) void {
        const self: *TcpStream = @ptrCast(@alignCast(ptr));
        if (self.closed) return;
        std.posix.shutdown(self.net_stream.handle, .both) catch {};
        self.net_stream.close();
        self.closed = true;
    }
};

const tcp_stream_vtable = network.Stream.StreamVTable{
    .read = TcpStream.read,
    .write = TcpStream.write,
    .close = TcpStream.close,
};

pub const ListenConfig = struct {
    port: u16,
    swarm_key: []const u8,
    static_key: noise.KeyPair,
    running: ?*std.atomic.Value(bool) = null,
    manager: ?*network.manager.ConnectionManager = null,
};

pub fn listen(allocator: std.mem.Allocator, cfg: ListenConfig) !void {
    const address = try std.net.Address.parseIp("0.0.0.0", cfg.port);
    var server = try address.listen(.{ .reuse_address = true });
    defer server.deinit();

    std.debug.print("Listening for TCP connections on {f}...\n", .{address});

    while (cfg.running == null or cfg.running.?.load(.acquire)) {
        const conn = server.accept() catch |err| {
            if (cfg.running != null and !cfg.running.?.load(.acquire)) break;
            return err;
        };
        std.debug.print("Accepted connection from {f}\n", .{conn.address});

        if (cfg.manager) |m| {
            m.ref();
            m.handshake_wg.start();
        }

        const thread = try std.Thread.spawn(.{}, handleIncomingConnection, .{
            allocator,
            conn,
            cfg.swarm_key,
            cfg.static_key,
            cfg.manager,
        });
        thread.detach();
    }
}

fn handleIncomingConnection(
    allocator: std.mem.Allocator,
    conn: std.net.Server.Connection,
    swarm_key: []const u8,
    static_key: noise.KeyPair,
    manager: ?*network.manager.ConnectionManager,
) void {
    defer if (manager) |m| {
        m.handshake_wg.finish();
    };
    defer if (manager) |m| {
        m.deinit();
    };

    const do_work = struct {
        fn do(
            a: std.mem.Allocator,
            c: std.net.Server.Connection,
            sk: []const u8,
            stk: noise.KeyPair,
            m: ?*network.manager.ConnectionManager,
        ) !void {
            // Create the connection implementation
            const impl = try a.create(TcpConnectionImpl);
            errdefer a.destroy(impl);

            // Initialize raw TCP stream
            impl.tcp_stream = .{ .net_stream = c.stream };
            impl.peer_address = c.address;

            // Perform Noise Handshake (Responder)
            impl.noise_stream = try noise.NoiseStream.handshake(a, impl.tcp_stream.stream(), sk, stk, false);

            impl.yamux = try YamuxSession.init(a, impl.noise_stream.stream(), true);
            errdefer impl.yamux.deinit();

            impl.yamux_thread = try std.Thread.spawn(.{}, YamuxSession.run, .{impl.yamux});
            impl.allocator = a;
            impl.closed = false;

            const conn_obj = impl.connection();
            if (m) |mgr| {
                mgr.addConnection(conn_obj) catch |err| {
                    conn_obj.deinit();
                    return err;
                };
            } else {
                conn_obj.deinit();
            }
        }
    }.do;

    do_work(allocator, conn, swarm_key, static_key, manager) catch |err| {
        std.debug.print("Connection handler error for {f}: {}\n", .{ conn.address, err });
        conn.stream.close();
    };
}

pub fn connect(allocator: std.mem.Allocator, address: std.net.Address, swarm_key: []const u8, static_key: noise.KeyPair) !network.Connection {
    const stream = try std.net.tcpConnectToAddress(address);

    const impl = try allocator.create(TcpConnectionImpl);
    errdefer allocator.destroy(impl);
    impl.tcp_stream = .{ .net_stream = stream };
    impl.peer_address = address;

    // Perform Noise Handshake (Initiator)
    impl.noise_stream = try noise.NoiseStream.handshake(allocator, impl.tcp_stream.stream(), swarm_key, static_key, true);

    impl.yamux = try YamuxSession.init(allocator, impl.noise_stream.stream(), false);
    errdefer impl.yamux.deinit();

    impl.yamux_thread = try std.Thread.spawn(.{}, YamuxSession.run, .{impl.yamux});
    impl.allocator = allocator;
    impl.closed = false;

    return impl.connection();
}
