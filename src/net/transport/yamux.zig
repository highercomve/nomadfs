const sync = @import("../../sync.zig");
const std = @import("std");
const network = @import("mod.zig");

pub const Version = 0;

pub const Type = enum(u8) {
    DATA = 0,
    WINDOW_UPDATE = 1,
    PING = 2,
    GO_AWAY = 3,
};

pub const Flags = struct {
    pub const SYN: u16 = 1;
    pub const ACK: u16 = 2;
    pub const FIN: u16 = 4;
    pub const RST: u16 = 8;
};

pub const Header = struct {
    version: u8 = Version,
    type: Type,
    flags: u16,
    stream_id: u32,
    length: u32,

    pub fn encode(self: Header, buffer: *[12]u8) void {
        buffer[0] = self.version;
        buffer[1] = @intFromEnum(self.type);
        std.mem.writeInt(u16, buffer[2..4], self.flags, .big);
        std.mem.writeInt(u32, buffer[4..8], self.stream_id, .big);
        std.mem.writeInt(u32, buffer[8..12], self.length, .big);
    }

    /// Decodes a peer-supplied header. Unknown versions and frame types are
    /// rejected instead of being cast into the `Type` enum.
    pub fn decode(buffer: [12]u8) error{InvalidFrame}!Header {
        if (buffer[0] != Version) return error.InvalidFrame;
        if (buffer[1] > @intFromEnum(Type.GO_AWAY)) return error.InvalidFrame;
        return .{
            .version = buffer[0],
            .type = @enumFromInt(buffer[1]),
            .flags = std.mem.readInt(u16, buffer[2..4], .big),
            .stream_id = std.mem.readInt(u32, buffer[4..8], .big),
            .length = std.mem.readInt(u32, buffer[8..12], .big),
        };
    }
};

fn readExactly(stream: network.Stream, buffer: []u8) !void {
    var total_read: usize = 0;
    while (total_read < buffer.len) {
        const n = try stream.read(buffer[total_read..]);
        if (n == 0) return error.EndOfStream;
        total_read += n;
    }
}

fn writeExactly(stream: network.Stream, buffer: []const u8) !void {
    var total_written: usize = 0;
    while (total_written < buffer.len) {
        const n = try stream.write(buffer[total_written..]);
        if (n == 0) return error.WriteZero;
        total_written += n;
    }
}

/// 1 MiB: the largest block (FastCDC's maximum chunk) fits in one window,
/// so a block reply never stalls waiting for a window update.
pub const InitialWindowSize: u32 = 1024 * 1024;

/// Upper bound on live streams per session, in both directions. Together with
/// the receive window this caps buffered receive data per session at
/// MaxStreams * InitialWindowSize (64 MiB).
pub const MaxStreams: u32 = 64;

/// A single logical stream within a Yamux session.
///
/// Ownership: the session owns the allocation. The user that obtained the
/// stream (newStream/acceptStream) must call streamClose exactly once and must
/// not touch the stream afterwards. The session frees the stream once both the
/// local side has closed it and the peer has sent FIN/RST, or on deinit.
pub const YamuxStream = struct {
    id: u32,
    session: *Session,
    incoming_data: std.ArrayListUnmanaged(u8),
    read_index: usize = 0,
    remote_window: u32, // How much we can send to peer
    local_window: u32, // How much peer can send to us
    /// Read but not yet returned to the peer as window: updates go out in
    /// batches of half a window instead of one per read.
    unacked: u32 = 0,
    mutex: sync.Mutex = .{},
    cond: sync.Condition = .{},
    write_cond: sync.Condition = .{},
    /// The local user called streamClose and no longer references the stream.
    local_closed: bool = false,
    /// The peer sent FIN or RST; no more data will arrive.
    remote_closed: bool = false,
    /// The peer sent RST or the session shut down; writes fail.
    reset: bool = false,
    /// Bound on each blocking read/write in milliseconds; 0 = unbounded.
    timeout_ms: u32 = 0,

    /// Waits on `cond` until woken or the deadline passes. Caller holds
    /// `mutex` and re-checks its predicate.
    fn waitUntil(self: *YamuxStream, cond: *sync.Condition, deadline_ms: ?i64) error{Timeout}!void {
        const until = deadline_ms orelse return cond.wait(&self.mutex);
        const now = sync.monotonicMillis();
        if (now >= until) return error.Timeout;
        cond.timedWait(&self.mutex, @as(u64, @intCast(until - now)) * std.time.ns_per_ms);
    }

    fn deadlineFromNow(self: *const YamuxStream) ?i64 {
        if (self.timeout_ms == 0) return null;
        return sync.monotonicMillis() + self.timeout_ms;
    }

    pub fn init(allocator: std.mem.Allocator, id: u32, session: *Session) YamuxStream {
        _ = allocator;
        return .{
            .id = id,
            .session = session,
            .incoming_data = .empty,
            .read_index = 0,
            .remote_window = InitialWindowSize,
            .local_window = InitialWindowSize,
        };
    }

    pub fn deinit(self: *YamuxStream, allocator: std.mem.Allocator) void {
        self.incoming_data.deinit(allocator);
    }
};

/// Lock order: Session.mutex before YamuxStream.mutex. Session.write_mutex is
/// only ever taken with no other lock held, so a blocked transport write never
/// stalls frame dispatch or stream bookkeeping.
pub const Session = struct {
    allocator: std.mem.Allocator,
    next_stream_id: u32,
    transport: network.Stream,
    streams: std.AutoHashMapUnmanaged(u32, *YamuxStream),
    accept_queue: std.ArrayListUnmanaged(*YamuxStream),
    mutex: sync.Mutex = .{},
    write_mutex: sync.Mutex = .{},
    /// A frame's header and payload, assembled for one transport write
    /// (guarded by write_mutex).
    write_buffer: std.ArrayListUnmanaged(u8) = .empty,
    accept_cond: sync.Condition = .{},
    accept_waiters: usize = 0,
    is_server: bool,
    closed: bool = false,
    /// The peer sent GO_AWAY: no new streams, existing streams keep working.
    go_away: bool = false,

    pub fn init(allocator: std.mem.Allocator, transport: network.Stream, is_server: bool) !*Session {
        const self = try allocator.create(Session);
        self.* = .{
            .allocator = allocator,
            .next_stream_id = if (is_server) 2 else 1,
            .transport = transport,
            .streams = .empty,
            .accept_queue = .empty,
            .accept_waiters = 0,
            .is_server = is_server,
            .closed = false,
        };
        return self;
    }

    /// Frees the session and every stream it still owns. The run() thread must
    /// have been joined and no user may still hold a stream.
    pub fn deinit(self: *Session) void {
        self.close();

        var it = self.streams.valueIterator();
        while (it.next()) |stream| {
            stream.*.deinit(self.allocator);
            self.allocator.destroy(stream.*);
        }
        self.streams.deinit(self.allocator);
        self.accept_queue.deinit(self.allocator);
        self.write_buffer.deinit(self.allocator);
        self.allocator.destroy(self);
    }

    /// Marks the session closed and wakes every waiter. Does not free memory.
    pub fn close(self: *Session) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.closed) return;
        self.closed = true;

        self.accept_cond.broadcast();

        var it = self.streams.valueIterator();
        while (it.next()) |entry| {
            const stream = entry.*;
            stream.mutex.lock();
            defer stream.mutex.unlock();
            stream.reset = true;
            stream.cond.broadcast();
            stream.write_cond.broadcast();
        }
    }

    /// Streams still tracked by the session, including ones awaiting accept.
    pub fn streamCount(self: *Session) usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.streams.count();
    }

    pub fn isClosed(self: *Session) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.closed or self.go_away;
    }

    pub fn newStream(self: *Session) !*YamuxStream {
        const stream_ptr = try self.allocator.create(YamuxStream);

        {
            self.mutex.lock();
            defer self.mutex.unlock();
            errdefer self.allocator.destroy(stream_ptr);

            if (self.closed or self.go_away) return error.SessionClosed;
            if (self.streams.count() >= MaxStreams) return error.TooManyStreams;
            if (self.next_stream_id > std.math.maxInt(u32) - 2) return error.StreamIdsExhausted;

            stream_ptr.* = YamuxStream.init(self.allocator, self.next_stream_id, self);
            try self.streams.put(self.allocator, stream_ptr.id, stream_ptr);
            self.next_stream_id += 2;
        }

        self.writeFrame(.{
            .type = .DATA,
            .flags = Flags.SYN,
            .stream_id = stream_ptr.id,
            .length = 0,
        }, &.{}) catch |err| {
            // The stream is already visible to the read loop, so release it
            // through the regular close path rather than freeing it here.
            streamClose(stream_ptr);
            return err;
        };

        return stream_ptr;
    }

    pub fn acceptStream(self: *Session) !*YamuxStream {
        self.mutex.lock();
        defer self.mutex.unlock();

        self.accept_waiters += 1;
        defer self.accept_waiters -= 1;

        while (self.accept_queue.items.len == 0) {
            if (self.closed) return error.SessionClosed;
            self.accept_cond.wait(&self.mutex);
        }
        return self.accept_queue.orderedRemove(0);
    }

    /// Read loop - must be called from a dedicated thread.
    pub fn run(self: *Session) void {
        defer self.close();

        var header_buf: [12]u8 = undefined;
        while (true) {
            readExactly(self.transport, &header_buf) catch |err| {
                if (err != error.EndOfStream and err != error.NotOpenForReading and err != error.ConnectionResetByPeer and err != error.BrokenPipe) {
                    std.debug.print("YamuxSession transport read error: {any}\n", .{err});
                }
                return;
            };

            self.handleFrame(&header_buf) catch |err| {
                std.debug.print("YamuxSession frame handling error: {any}\n", .{err});
                return;
            };
        }
    }

    fn handleFrame(self: *Session, header_buf: *const [12]u8) !void {
        const header = try Header.decode(header_buf.*);

        switch (header.type) {
            .DATA => try self.handleData(header),
            .WINDOW_UPDATE => {
                try self.handleWindowUpdate(header);
                if (header.flags & (Flags.FIN | Flags.RST) != 0) {
                    self.remoteClose(header.stream_id, header.flags & Flags.RST != 0);
                }
            },
            .PING => {
                // If it's a request (no ACK flag), send it back.
                // An ACK is ignored for now (no PING tracker).
                if (header.flags & Flags.ACK == 0) {
                    var resp = header;
                    resp.flags |= Flags.ACK;
                    try self.writeFrame(resp, &.{});
                }
            },
            .GO_AWAY => {
                self.mutex.lock();
                defer self.mutex.unlock();
                self.go_away = true;
                self.accept_cond.broadcast();
            },
        }
    }

    const DataTarget = union(enum) {
        stream: *YamuxStream,
        discard,
        refuse,
    };

    /// Resolves the stream a DATA frame belongs to, creating it for a valid
    /// incoming SYN. A returned stream has remote_closed == false; only this
    /// (run) thread sets remote_closed, so the stream cannot be freed until
    /// this thread calls remoteClose.
    fn dataTarget(self: *Session, header: Header) !DataTarget {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.streams.get(header.stream_id)) |stream| {
            stream.mutex.lock();
            defer stream.mutex.unlock();
            if (stream.remote_closed) return .discard;
            return .{ .stream = stream };
        }

        const is_incoming = if (self.is_server) (header.stream_id % 2 != 0) else (header.stream_id % 2 == 0);
        if (!is_incoming or header.flags & Flags.SYN == 0) return .discard;
        if (self.closed) return .discard;
        if (self.streams.count() >= MaxStreams) return .refuse;

        try self.streams.ensureUnusedCapacity(self.allocator, 1);
        try self.accept_queue.ensureUnusedCapacity(self.allocator, 1);
        const new_s = try self.allocator.create(YamuxStream);
        new_s.* = YamuxStream.init(self.allocator, header.stream_id, self);
        self.streams.putAssumeCapacity(header.stream_id, new_s);
        self.accept_queue.appendAssumeCapacity(new_s);
        self.accept_cond.signal();
        return .{ .stream = new_s };
    }

    fn handleData(self: *Session, header: Header) !void {
        const stream = switch (try self.dataTarget(header)) {
            .stream => |s| s,
            .discard => return self.discardBytes(header.length),
            .refuse => {
                try self.discardBytes(header.length);
                return self.writeFrame(.{
                    .type = .WINDOW_UPDATE,
                    .flags = Flags.RST,
                    .stream_id = header.stream_id,
                    .length = 0,
                }, &.{});
            },
        };

        // Enforce the receive window before reading any payload, so a peer
        // can never make us buffer more than InitialWindowSize per stream.
        var keep_data: bool = undefined;
        {
            stream.mutex.lock();
            defer stream.mutex.unlock();
            if (header.length > stream.local_window) return error.WindowExceeded;
            stream.local_window -= header.length;
            keep_data = !stream.local_closed;
        }

        var chunk: [64 * 1024]u8 = undefined;
        var remaining: u32 = header.length;
        while (remaining > 0) {
            const n: u32 = @min(remaining, @as(u32, chunk.len));
            try readExactly(self.transport, chunk[0..n]);
            remaining -= n;
            if (!keep_data) continue;

            stream.mutex.lock();
            defer stream.mutex.unlock();
            try stream.incoming_data.appendSlice(self.allocator, chunk[0..n]);
            stream.cond.broadcast();
        }

        if (header.flags & (Flags.FIN | Flags.RST) != 0) {
            self.remoteClose(header.stream_id, header.flags & Flags.RST != 0);
        }
    }

    fn handleWindowUpdate(self: *Session, header: Header) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        const stream = self.streams.get(header.stream_id) orelse return;
        stream.mutex.lock();
        defer stream.mutex.unlock();
        stream.remote_window = std.math.add(u32, stream.remote_window, header.length) catch
            return error.WindowOverflow;
        stream.write_cond.broadcast();
    }

    /// Records FIN/RST from the peer and frees the stream if the local side is
    /// already done with it.
    fn remoteClose(self: *Session, stream_id: u32, is_reset: bool) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        const stream = self.streams.get(stream_id) orelse return;
        var release = false;
        {
            stream.mutex.lock();
            defer stream.mutex.unlock();
            stream.remote_closed = true;
            if (is_reset) stream.reset = true;
            stream.cond.broadcast();
            stream.write_cond.broadcast();
            release = stream.local_closed;
        }
        if (release) self.destroyStreamLocked(stream);
    }

    /// Caller holds self.mutex and nobody else references the stream.
    fn destroyStreamLocked(self: *Session, stream: *YamuxStream) void {
        _ = self.streams.remove(stream.id);
        stream.deinit(self.allocator);
        self.allocator.destroy(stream);
    }

    fn writeFrame(self: *Session, header: Header, payload: []const u8) !void {
        std.debug.assert(payload.len == header.length or header.type != .DATA);
        var h_buf: [12]u8 = undefined;
        header.encode(&h_buf);

        self.write_mutex.lock();
        defer self.write_mutex.unlock();
        // One transport write per frame: the header doesn't travel alone.
        self.write_buffer.clearRetainingCapacity();
        try self.write_buffer.ensureTotalCapacity(self.allocator, h_buf.len + payload.len);
        self.write_buffer.appendSliceAssumeCapacity(&h_buf);
        self.write_buffer.appendSliceAssumeCapacity(payload);
        try writeExactly(self.transport, self.write_buffer.items);
    }

    fn discardBytes(self: *Session, len: u32) !void {
        var buf: [1024]u8 = undefined;
        var remaining = len;
        while (remaining > 0) {
            const to_read = @min(remaining, @as(u32, @intCast(buf.len)));
            try readExactly(self.transport, buf[0..to_read]);
            remaining -= to_read;
        }
    }

    pub fn streamRead(ctx: *anyopaque, buffer: []u8) anyerror!usize {
        const stream: *YamuxStream = @ptrCast(@alignCast(ctx));
        const session = stream.session;

        var to_read: usize = 0;
        var update: u32 = 0;
        {
            stream.mutex.lock();
            defer stream.mutex.unlock();

            const deadline = stream.deadlineFromNow();
            while (stream.incoming_data.items.len - stream.read_index == 0 and
                !stream.remote_closed and !stream.reset and !stream.local_closed)
            {
                try stream.waitUntil(&stream.cond, deadline);
            }

            const available = stream.incoming_data.items.len - stream.read_index;
            if (available == 0) return 0;

            to_read = @min(buffer.len, available);
            @memcpy(buffer[0..to_read], stream.incoming_data.items[stream.read_index .. stream.read_index + to_read]);
            stream.read_index += to_read;

            // Compact if we have too much wasted space
            if (stream.read_index > 4096 and stream.read_index > stream.incoming_data.items.len / 2) {
                const remaining = stream.incoming_data.items.len - stream.read_index;
                if (remaining > 0) {
                    std.mem.copyForwards(u8, stream.incoming_data.items[0..remaining], stream.incoming_data.items[stream.read_index..]);
                }
                stream.incoming_data.shrinkAndFree(session.allocator, remaining);
                stream.read_index = 0;
            }

            // Give the window back in halves: the peer still has at least
            // half a window to send into, and the update costs one frame.
            // to_read <= available <= InitialWindowSize, so this cannot overflow.
            stream.unacked += @intCast(to_read);
            if (stream.unacked >= InitialWindowSize / 2) {
                update = stream.unacked;
                stream.local_window += update;
                stream.unacked = 0;
                std.debug.assert(stream.local_window <= InitialWindowSize);
            }
        }

        if (update > 0) {
            try session.writeFrame(.{
                .type = .WINDOW_UPDATE,
                .flags = 0,
                .stream_id = stream.id,
                .length = update,
            }, &.{});
        }

        return to_read;
    }

    pub fn streamWrite(ctx: *anyopaque, buffer: []const u8) anyerror!usize {
        const stream: *YamuxStream = @ptrCast(@alignCast(ctx));
        const session = stream.session;

        var total_sent: usize = 0;
        while (total_sent < buffer.len) {
            var can_send: u32 = 0;
            {
                stream.mutex.lock();
                defer stream.mutex.unlock();
                const deadline = stream.deadlineFromNow();
                while (stream.remote_window == 0 and !stream.local_closed and !stream.reset) {
                    try stream.waitUntil(&stream.write_cond, deadline);
                }
                if (stream.local_closed or stream.reset) return error.StreamClosed;

                can_send = @intCast(@min(buffer.len - total_sent, stream.remote_window));
                stream.remote_window -= can_send;
            }

            try session.writeFrame(.{
                .type = .DATA,
                .flags = 0,
                .stream_id = stream.id,
                .length = can_send,
            }, buffer[total_sent .. total_sent + can_send]);

            total_sent += can_send;
        }

        return total_sent;
    }

    pub fn streamSetTimeout(ctx: *anyopaque, timeout_ms: u32) void {
        const stream: *YamuxStream = @ptrCast(@alignCast(ctx));
        stream.mutex.lock();
        defer stream.mutex.unlock();
        stream.timeout_ms = timeout_ms;
    }

    /// Ends the stream locally: blocked reads return what's left then end,
    /// writes fail, and the peer gets FIN (so it closes its side, which
    /// frees ours as usual). The stream stays allocated until streamClose,
    /// so other threads may still be inside read or write.
    pub fn streamShutdown(ctx: *anyopaque) void {
        const stream: *YamuxStream = @ptrCast(@alignCast(ctx));
        const session = stream.session;
        {
            stream.mutex.lock();
            defer stream.mutex.unlock();
            if (stream.reset or stream.local_closed) return;
            stream.reset = true;
            stream.cond.broadcast();
            stream.write_cond.broadcast();
        }
        session.writeFrame(.{
            .type = .DATA,
            .flags = Flags.FIN,
            .stream_id = stream.id,
            .length = 0,
        }, &.{}) catch {};
    }

    /// Half-closes the stream and releases the caller's hold on it. The stream
    /// must not be used after this returns.
    pub fn streamClose(ctx: *anyopaque) void {
        const stream: *YamuxStream = @ptrCast(@alignCast(ctx));
        const session = stream.session;
        const id = stream.id;

        var send_fin = false;
        {
            session.mutex.lock();
            defer session.mutex.unlock();

            var release = false;
            {
                stream.mutex.lock();
                defer stream.mutex.unlock();
                if (stream.local_closed) return;
                stream.local_closed = true;
                stream.cond.broadcast();
                stream.write_cond.broadcast();
                send_fin = !stream.reset;
                release = stream.remote_closed;
            }
            if (release) session.destroyStreamLocked(stream);
        }

        if (send_fin) {
            session.writeFrame(.{
                .type = .DATA,
                .flags = Flags.FIN,
                .stream_id = id,
                .length = 0,
            }, &.{}) catch {};
        }
    }
};

test "YamuxStream ring buffer" {
    const allocator = std.testing.allocator;
    // Mock session
    const session = try allocator.create(Session);
    session.* = undefined;
    session.allocator = allocator;
    defer allocator.destroy(session);

    var stream = YamuxStream.init(allocator, 1, session);
    defer stream.deinit(allocator);

    // Test Write
    const data1 = "Hello";
    try stream.incoming_data.appendSlice(allocator, data1);
    try std.testing.expectEqual(data1.len, stream.incoming_data.items.len);
    try std.testing.expectEqual(@as(usize, 0), stream.read_index);

    // Test Read Partial
    var buf: [3]u8 = undefined;
    {
        const available = stream.incoming_data.items.len - stream.read_index;
        const to_read = @min(buf.len, available);
        @memcpy(buf[0..to_read], stream.incoming_data.items[stream.read_index .. stream.read_index + to_read]);
        stream.read_index += to_read;
    }
    try std.testing.expectEqualStrings("Hel", &buf);
    try std.testing.expectEqual(@as(usize, 3), stream.read_index);

    // Test Append more
    const data2 = " World";
    try stream.incoming_data.appendSlice(allocator, data2);
    // "Hello World"
    // index at 3. "lo World" remaining.

    // Test Read Rest
    var buf2: [8]u8 = undefined;
    {
        const available = stream.incoming_data.items.len - stream.read_index;
        const to_read = @min(buf2.len, available);
        @memcpy(buf2[0..to_read], stream.incoming_data.items[stream.read_index .. stream.read_index + to_read]);
        stream.read_index += to_read;
    }
    try std.testing.expectEqualStrings("lo World", &buf2);
    try std.testing.expectEqual(stream.incoming_data.items.len, stream.read_index);

    // Test Compaction logic
    // Force read_index high to trigger compaction (simulate)
    stream.read_index = 5;
    try stream.incoming_data.resize(allocator, 10);
    @memcpy(stream.incoming_data.items[5..10], "ABCDE");

    if (stream.read_index > 0) {
        const remaining = stream.incoming_data.items.len - stream.read_index;
        if (remaining > 0) {
            std.mem.copyForwards(u8, stream.incoming_data.items[0..remaining], stream.incoming_data.items[stream.read_index..]);
        }
        stream.incoming_data.shrinkAndFree(allocator, remaining);
        stream.read_index = 0;
    }

    try std.testing.expectEqualStrings("ABCDE", stream.incoming_data.items);
    try std.testing.expectEqual(@as(usize, 0), stream.read_index);
}
