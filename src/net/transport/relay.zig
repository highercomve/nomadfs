//! A connection to a device through another one. When no address of a
//! device answers (it is on a network nobody else can reach, like a home
//! server off Tailscale seen from a phone on mobile data), a device both
//! can reach pipes a stream between them (discovery/node.zig, RELAY_*).
//! Over that stream the two ends run the same Noise handshake and Yamux
//! session as over TCP: the relay only ever sees ciphertext, and the
//! connection is used like any other.
//!
//! The relayed connection holds a reference to the connection the stream
//! travels on, so it stays up as long as the relayed one is in use.

const std = @import("std");
const network = @import("mod.zig");
const noise = @import("noise.zig");
const device_auth = @import("../../device/auth.zig");
const YamuxSession = @import("yamux.zig").Session;
const id = @import("../id.zig");

const RelayedConnectionImpl = struct {
    /// The stream through the relay (a Yamux stream of `via`).
    base: network.Stream,
    /// The connection to the relay; one reference held.
    via: network.Connection,
    noise_stream: noise.NoiseStream,
    yamux: *YamuxSession,
    yamux_thread: std.Thread,
    allocator: std.mem.Allocator,
    closed: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    refs: std.atomic.Value(u32) = std.atomic.Value(u32).init(1),

    fn connection(self: *RelayedConnectionImpl) network.Connection {
        return network.Connection.init(self, &vtable);
    }

    fn openStream(ctx: *anyopaque) anyerror!network.Stream {
        const self: *RelayedConnectionImpl = @ptrCast(@alignCast(ctx));
        return network.Stream.init(try self.yamux.newStream(), &stream_vtable);
    }

    fn acceptStream(ctx: *anyopaque) anyerror!network.Stream {
        const self: *RelayedConnectionImpl = @ptrCast(@alignCast(ctx));
        return network.Stream.init(try self.yamux.acceptStream(), &stream_vtable);
    }

    /// No address of the device itself: the bytes come from the relay.
    /// Unspecified, so nothing records it as a way to reach the device.
    fn getPeerAddress(_: *anyopaque) network.Address {
        return network.Address.initIp4(.{ 0, 0, 0, 0 }, 0);
    }

    fn getRemoteNodeID(ctx: *anyopaque) id.NodeID {
        const self: *RelayedConnectionImpl = @ptrCast(@alignCast(ctx));
        return id.NodeID.fromPublicKey(self.noise_stream.remote_static);
    }

    fn getRemoteDeviceID(ctx: *anyopaque) ?id.NodeID {
        const self: *RelayedConnectionImpl = @ptrCast(@alignCast(ctx));
        return self.noise_stream.remote_device_id;
    }

    fn isClosed(ctx: *anyopaque) bool {
        const self: *RelayedConnectionImpl = @ptrCast(@alignCast(ctx));
        return self.closed.load(.acquire) or self.yamux.isClosed() or self.via.isClosed();
    }

    fn maintain(ctx: *anyopaque) void {
        const self: *RelayedConnectionImpl = @ptrCast(@alignCast(ctx));
        self.yamux.reapClosed(@import("../../sync.zig").monotonicMillis());
    }

    fn isInUse(ctx: *anyopaque) bool {
        const self: *RelayedConnectionImpl = @ptrCast(@alignCast(ctx));
        const streams = self.yamux.streamCount();
        return self.refs.load(.acquire) > 1 or streams > 0;
    }

    /// Signals shutdown: ends the stream through the relay, which wakes
    /// the Yamux reader. Safe while other threads use the connection.
    fn close(ctx: *anyopaque) void {
        const self: *RelayedConnectionImpl = @ptrCast(@alignCast(ctx));
        if (self.closed.swap(true, .acq_rel)) return;
        self.base.shutdown();
        self.yamux.close();
    }

    fn retain(ctx: *anyopaque) void {
        const self: *RelayedConnectionImpl = @ptrCast(@alignCast(ctx));
        const prev = self.refs.fetchAdd(1, .monotonic);
        std.debug.assert(prev > 0);
    }

    fn deinit(ctx: *anyopaque) void {
        const self: *RelayedConnectionImpl = @ptrCast(@alignCast(ctx));
        const prev = self.refs.fetchSub(1, .acq_rel);
        std.debug.assert(prev > 0);
        if (prev != 1) return;

        close(ctx);
        self.yamux_thread.join();
        self.yamux.deinit();
        self.noise_stream.deinit(); // Closes `base`.
        self.via.deinit();
        self.allocator.destroy(self);
    }
};

const vtable = network.Connection.ConnectionVTable{
    .openStream = RelayedConnectionImpl.openStream,
    .acceptStream = RelayedConnectionImpl.acceptStream,
    .getPeerAddress = RelayedConnectionImpl.getPeerAddress,
    .getRemoteNodeID = RelayedConnectionImpl.getRemoteNodeID,
    .getRemoteDeviceID = RelayedConnectionImpl.getRemoteDeviceID,
    .close = RelayedConnectionImpl.close,
    .retain = RelayedConnectionImpl.retain,
    .deinit = RelayedConnectionImpl.deinit,
    .isClosed = RelayedConnectionImpl.isClosed,
    .isInUse = RelayedConnectionImpl.isInUse,
    .maintain = RelayedConnectionImpl.maintain,
};

const stream_vtable = network.Stream.StreamVTable{
    .read = YamuxSession.streamRead,
    .write = YamuxSession.streamWrite,
    .close = YamuxSession.streamClose,
    .setTimeout = YamuxSession.streamSetTimeout,
    .shutdown = YamuxSession.streamShutdown,
};

/// Runs the Noise handshake and starts Yamux over `base`, a stream through
/// the relay `via`. Takes ownership of `base` and of one reference to
/// `via`, also on error. The result holds one reference.
pub fn establish(
    allocator: std.mem.Allocator,
    base: network.Stream,
    via: network.Connection,
    swarm_key: []const u8,
    static_key: noise.KeyPair,
    initiator: bool,
    handshake_timeout_ms: u32,
    device_auth_opt: ?*const device_auth.Authenticator,
) !network.Connection {
    errdefer via.deinit();
    var base_owned = true;
    errdefer if (base_owned) base.close();

    const impl = try allocator.create(RelayedConnectionImpl);
    errdefer allocator.destroy(impl);
    impl.* = .{
        .base = base,
        .via = via,
        .noise_stream = undefined,
        .yamux = undefined,
        .yamux_thread = undefined,
        .allocator = allocator,
    };

    base.setTimeout(handshake_timeout_ms);
    impl.noise_stream = try noise.NoiseStream.handshake(allocator, base, swarm_key, static_key, initiator, device_auth_opt);
    base_owned = false; // The Noise stream closes it from here on.
    errdefer impl.noise_stream.deinit();
    // An established connection idles legitimately.
    base.setTimeout(0);

    impl.yamux = try YamuxSession.init(allocator, impl.noise_stream.stream(), !initiator);
    errdefer impl.yamux.deinit();
    impl.yamux_thread = try std.Thread.spawn(.{}, YamuxSession.run, .{impl.yamux});
    return impl.connection();
}

/// Copies bytes both ways between `a` and `b` until either ends, then
/// closes both. Runs on the caller's thread plus one more.
pub fn splice(a: network.Stream, b: network.Stream) void {
    const Pump = struct {
        fn run(from: network.Stream, to: network.Stream) void {
            var buf: [64 * 1024]u8 = undefined;
            while (true) {
                const n = from.read(&buf) catch break;
                if (n == 0) break;
                to.writer().writeAll(buf[0..n]) catch break;
            }
            // Wake the other direction.
            from.shutdown();
            to.shutdown();
        }
    };
    a.setTimeout(0);
    b.setTimeout(0);
    const other = std.Thread.spawn(.{}, Pump.run, .{ b, a }) catch {
        a.close();
        b.close();
        return;
    };
    Pump.run(a, b);
    other.join();
    a.close();
    b.close();
}
