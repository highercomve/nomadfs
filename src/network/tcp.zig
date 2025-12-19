const std = @import("std");
const network = @import("mod.zig");
const noise = @import("noise.zig");
const YamuxSession = @import("yamux.zig").Session;

const id = @import("../dht/id.zig");

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
        return network.Connection.init(self, &network.Connection.ConnectionVTable{
            .openStream = openStream,
            .acceptStream = acceptStream,
            .getPeerAddress = getPeerAddress,
            .getRemoteNodeID = getRemoteNodeID,
            .close = close,
            .isClosed = isClosed,
        });
    }

    /// Implements network.Connection.openStream
    pub fn openStream(ctx: *anyopaque) anyerror!network.Stream {
        const self: *TcpConnectionImpl = @ptrCast(@alignCast(ctx));

        // Ask Yamux to allocate a new stream ID and structure
        const yamux_stream = try self.yamux.newStream();

        // Return the abstract interface pointing to our concrete Yamux stream
        return network.Stream.init(yamux_stream, &network.Stream.StreamVTable{
            .read = YamuxSession.streamRead,
            .write = YamuxSession.streamWrite,
            .close = YamuxSession.streamClose,
        });
    }

    pub fn acceptStream(ctx: *anyopaque) anyerror!network.Stream {
        const self: *TcpConnectionImpl = @ptrCast(@alignCast(ctx));
        const yamux_stream = try self.yamux.acceptStream();

        return network.Stream.init(yamux_stream, &network.Stream.StreamVTable{
            .read = YamuxSession.streamRead,
            .write = YamuxSession.streamWrite,
            .close = YamuxSession.streamClose,
        });
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

        // 2. Join thread and clean up
        self.yamux_thread.join();
        self.yamux.deinit();
        self.allocator.destroy(self);
    }
};

pub const TcpStream = struct {
    net_stream: std.net.Stream,
    closed: bool = false,

    pub fn stream(self: *TcpStream) network.Stream {
        return network.Stream.init(self, &network.Stream.StreamVTable{
            .read = read,
            .write = write,
            .close = close,
        });
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

pub fn listen(allocator: std.mem.Allocator, port: u16, swarm_key: []const u8, static_key: noise.KeyPair, running: ?*std.atomic.Value(bool), manager: ?*network.manager.ConnectionManager) !void {
    const address = try std.net.Address.parseIp("0.0.0.0", port);
    var server = try address.listen(.{ .reuse_address = true });
    defer server.deinit();

    std.debug.print("Listening for TCP connections on {f}...\n", .{address});

    while (running == null or running.?.load(.acquire)) {
        const conn = server.accept() catch |err| {
            if (running != null and !running.?.load(.acquire)) break;
            return err;
        };
        std.debug.print("Accepted connection from {f}\n", .{conn.address});

        // Create the connection implementation
        const impl = try allocator.create(TcpConnectionImpl);
        errdefer allocator.destroy(impl);

        // Initialize raw TCP stream
        impl.tcp_stream = .{ .net_stream = conn.stream };
        impl.peer_address = conn.address;

        // Perform Noise Handshake (Responder)
        impl.noise_stream = noise.NoiseStream.handshake(impl.tcp_stream.stream(), swarm_key, static_key, false) catch |err| {
            std.debug.print("Handshake failed: {}\n", .{err});
            conn.stream.close();
            allocator.destroy(impl);
            continue;
        };

        impl.yamux = try YamuxSession.init(allocator, impl.noise_stream.stream(), true);
        errdefer impl.yamux.deinit();

        impl.yamux_thread = try std.Thread.spawn(.{}, YamuxSession.run, .{impl.yamux});
        impl.allocator = allocator;
        impl.closed = false;

        const conn_obj = impl.connection();
        if (manager) |m| {
            try m.addConnection(conn_obj);
        } else {
            conn_obj.close();
        }
    }
}

pub fn connect(allocator: std.mem.Allocator, address: std.net.Address, swarm_key: []const u8, static_key: noise.KeyPair) !network.Connection {
    const stream = try std.net.tcpConnectToAddress(address);

    const impl = try allocator.create(TcpConnectionImpl);
    errdefer allocator.destroy(impl);
    impl.tcp_stream = .{ .net_stream = stream };
    impl.peer_address = address;

    // Perform Noise Handshake (Initiator)
    impl.noise_stream = try noise.NoiseStream.handshake(impl.tcp_stream.stream(), swarm_key, static_key, true);

    impl.yamux = try YamuxSession.init(allocator, impl.noise_stream.stream(), false);
    errdefer impl.yamux.deinit();

    impl.yamux_thread = try std.Thread.spawn(.{}, YamuxSession.run, .{impl.yamux});
    impl.allocator = allocator;
    impl.closed = false;

    return impl.connection();
}
