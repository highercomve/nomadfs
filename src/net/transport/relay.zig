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
const network = @import("interface.zig");
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
    /// Maintenance writes are under way (on their own thread: see maintain).
    maintaining: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    /// The last maintenance worker, joined before the next one starts and
    /// in deinit (after close wakes it), so none outlives the session.
    worker: ?std.Thread = null,
    refs: network.RefCount = .{},

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

    /// Like a TCP connection's: a session silent past the keepalive is
    /// closed. A relayed one needs it more: the relay can keep the stream
    /// open while the far leg is dead, and nothing else would notice.
    /// Every write maintenance needs (resets for expired streams, the
    /// keepalive ping) goes out on this session's own worker thread, one at
    /// a time: written through the relay's stream, a write can wait on that
    /// stream's window if the relay stops reading, and the caller here is
    /// the connection manager's one maintenance thread. Here only the
    /// state is checked, which writes nothing; a session silent past the
    /// limit is closed, which writes nothing either and wakes a stuck
    /// worker.
    fn maintain(ctx: *anyopaque) void {
        const self: *RelayedConnectionImpl = @ptrCast(@alignCast(ctx));
        const now = @import("../../sync.zig").monotonicMillis();
        const state = self.yamux.keepAliveState(now);
        if (state == .dead) {
            std.debug.print("relayed connection to {x}: no answer for {d} s, closing\n", .{ getRemoteNodeID(ctx).bytes[0..4], @divTrunc(@import("yamux.zig").keepalive_dead_ms, 1000) });
            close(ctx);
            return;
        }
        self.maintainAsync(now, state == .ping);
    }

    /// Only ever called from maintain (the manager's one maintenance
    /// thread), which holds a reference meanwhile: deinit can't run.
    fn maintainAsync(self: *RelayedConnectionImpl, now: i64, ping: bool) void {
        if (self.maintaining.swap(true, .acq_rel)) return; // one still writing
        // The previous one has finished (maintaining was false): instant.
        if (self.worker) |t| t.join();
        self.worker = std.Thread.spawn(.{ .stack_size = 64 * 1024 }, maintainWorker, .{ self, now, ping }) catch {
            self.worker = null;
            self.maintaining.store(false, .release);
            return;
        };
    }

    fn maintainWorker(self: *RelayedConnectionImpl, now: i64, ping: bool) void {
        self.yamux.reapClosed(now);
        if (ping) self.yamux.sendPing(now);
        self.maintaining.store(false, .release);
    }

    fn isInUse(ctx: *anyopaque) bool {
        const self: *RelayedConnectionImpl = @ptrCast(@alignCast(ctx));
        return self.refs.shared() or self.yamux.streamCount() > 0;
    }

    /// Signals shutdown: ends the stream through the relay, which wakes
    /// the Yamux reader. Safe while other threads use the connection.
    /// Writes nothing: the stream's FIN is queued for the relay
    /// connection's next flush, since this runs on the connection manager's
    /// one maintenance thread when the session is dead, and the relay link
    /// may be stalled even with its writer free.
    fn close(ctx: *anyopaque) void {
        const self: *RelayedConnectionImpl = @ptrCast(@alignCast(ctx));
        if (self.closed.swap(true, .acq_rel)) return;
        // `base` is a Yamux stream of `via` (see `establish`).
        if (self.base.ptr) |stream| YamuxSession.streamShutdownQueued(stream);
        self.yamux.close();
    }

    fn retain(ctx: *anyopaque) void {
        const self: *RelayedConnectionImpl = @ptrCast(@alignCast(ctx));
        self.refs.retain();
    }

    fn deinit(ctx: *anyopaque) void {
        const self: *RelayedConnectionImpl = @ptrCast(@alignCast(ctx));
        if (!self.refs.release()) return;

        close(ctx);
        // close woke a worker stuck on the relay's window; it ends now.
        if (self.worker) |t| t.join();
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

test "relay: maintenance never blocks on a stalled relay (ping and expired-stream resets go to the worker)" {
    const sync = @import("../../sync.zig");
    const yamux = @import("yamux.zig");
    const Sink = struct {
        fn read(_: *anyopaque, _: []u8) anyerror!usize {
            return 0;
        }
        fn write(_: *anyopaque, bytes: []const u8) anyerror!usize {
            return bytes.len;
        }
        fn close(_: *anyopaque) void {}
        const vt: network.Stream.StreamVTable = .{ .read = read, .write = write, .close = close };
    };
    const Call = struct {
        impl: *RelayedConnectionImpl,
        finished: std.atomic.Value(bool) = .init(false),
        fn run(self: *@This()) void {
            RelayedConnectionImpl.maintain(self.impl);
            self.finished.store(true, .release);
        }
    };
    // A relayed session: an inner Yamux session over Noise over a stream
    // of the session to the relay (`outer`).
    var sink: Sink = .{};
    const outer = try YamuxSession.init(std.testing.allocator, network.Stream.init(&sink, &Sink.vt), false);
    defer outer.deinit();
    const base = try outer.newStream();
    var packet: [65537]u8 = undefined;
    var encrypted: noise.NoiseStream = undefined;
    encrypted.inner = network.Stream.init(base, &stream_vtable);
    encrypted.send_cipher = noise.CipherState.init();
    encrypted.send_cipher.initializeKey([_]u8{1} ** 32);
    encrypted.write_buffer = &packet;
    const inner = try YamuxSession.init(std.testing.allocator, encrypted.stream(), false);
    defer inner.deinit();
    // A request stream released here whose peer never sent FIN.
    const tombstone = try inner.newStream();
    YamuxSession.streamClose(tombstone);
    // The relay stops reading: no window left on its stream.
    base.remote_window = 0;
    inner.last_rx_ms.store(sync.monotonicMillis() - yamux.keepalive_idle_ms - 1, .monotonic);
    var impl: RelayedConnectionImpl = undefined;
    impl.yamux = inner;
    impl.maintaining = .init(false);
    impl.worker = null;
    impl.refs = .{};
    // First round: a ping is due; the worker writes it and gets stuck.
    RelayedConnectionImpl.maintain(&impl);
    var worker_stuck = false;
    for (0..1000) |_| {
        if (!inner.write_mutex.tryLock()) {
            worker_stuck = true;
            break;
        }
        inner.write_mutex.unlock();
        sync.sleep(std.time.ns_per_ms);
    }
    // The tombstone expires; the next round must still return at once.
    tombstone.mutex.lock();
    tombstone.closed_at_ms = sync.monotonicMillis() - 60_000;
    tombstone.mutex.unlock();
    var call: Call = .{ .impl = &impl };
    const thread = try std.Thread.spawn(.{}, Call.run, .{&call});
    sync.sleep(100 * std.time.ns_per_ms);
    const returned = call.finished.load(.acquire);
    // Release the window and wait for everyone before freeing state.
    base.mutex.lock();
    base.remote_window = 4096;
    base.write_cond.broadcast();
    base.mutex.unlock();
    thread.join();
    while (impl.maintaining.load(.acquire)) sync.sleep(std.time.ns_per_ms);
    if (impl.worker) |t| t.join();
    try std.testing.expect(worker_stuck);
    try std.testing.expect(returned);
}
