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

    pub fn decode(buffer: [12]u8) Header {
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

pub const InitialWindowSize: u32 = 256 * 1024;

/// A single logical stream within a Yamux session.
pub const YamuxStream = struct {
    id: u32,
    session: *Session,
    incoming_data: std.ArrayListUnmanaged(u8),
    remote_window: u32, // How much we can send to peer
    local_window: u32, // How much peer can send to us
    mutex: std.Thread.Mutex = .{},
    cond: std.Thread.Condition = .{},
    write_cond: std.Thread.Condition = .{},
    closed: bool = false,

    pub fn init(allocator: std.mem.Allocator, id: u32, session: *Session) YamuxStream {
        _ = allocator;
        return .{
            .id = id,
            .session = session,
            .incoming_data = .{},
            .remote_window = InitialWindowSize,
            .local_window = InitialWindowSize,
        };
    }

    pub fn deinit(self: *YamuxStream, allocator: std.mem.Allocator) void {
        self.incoming_data.deinit(allocator);
    }
};

pub const Session = struct {
    allocator: std.mem.Allocator,
    next_stream_id: u32,
    transport: network.Stream,
    streams: std.AutoHashMapUnmanaged(u32, *YamuxStream),
    accept_queue: std.ArrayListUnmanaged(*YamuxStream),
    mutex: std.Thread.Mutex = .{},
    accept_cond: std.Thread.Condition = .{},
    is_server: bool,
    closed: bool = false,

    pub fn init(allocator: std.mem.Allocator, transport: network.Stream, is_server: bool) !*Session {
        const self = try allocator.create(Session);
        self.* = .{
            .allocator = allocator,
            .next_stream_id = if (is_server) 2 else 1,
            .transport = transport,
            .streams = .{},
            .accept_queue = .{},
            .is_server = is_server,
            .closed = false,
        };
        return self;
    }

    pub fn deinit(self: *Session) void {
        var it = self.streams.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.*.deinit(self.allocator);
            self.allocator.destroy(entry.value_ptr.*);
        }
        self.streams.deinit(self.allocator);
        self.accept_queue.deinit(self.allocator);
        self.allocator.destroy(self);
    }

    pub fn newStream(self: *Session) !*YamuxStream {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.closed) return error.SessionClosed;

        const id = self.next_stream_id;
        self.next_stream_id += 2;

        const stream_ptr = try self.allocator.create(YamuxStream);
        stream_ptr.* = YamuxStream.init(self.allocator, id, self);

        try self.streams.put(self.allocator, id, stream_ptr);

        // Send SYN frame
        var header = Header{
            .type = .DATA,
            .flags = Flags.SYN,
            .stream_id = id,
            .length = 0,
        };
        var buf: [12]u8 = undefined;
        header.encode(&buf);
        _ = try self.transport.write(&buf);

        return stream_ptr;
    }

    pub fn acceptStream(self: *Session) !*YamuxStream {
        self.mutex.lock();
        defer self.mutex.unlock();

        while (self.accept_queue.items.len == 0) {
            if (self.closed) return error.SessionClosed;
            self.accept_cond.wait(&self.mutex);
        }
        return self.accept_queue.orderedRemove(0);
    }

    /// Read loop - must be called from a dedicated thread.
    pub fn run(self: *Session) !void {
        defer {
            self.mutex.lock();
            self.closed = true;
            var it = self.streams.iterator();
            while (it.next()) |entry| {
                const stream = entry.value_ptr.*;
                stream.mutex.lock();
                stream.closed = true;
                stream.cond.signal();
                stream.write_cond.signal();
                stream.mutex.unlock();
            }
            self.accept_cond.broadcast();
            self.mutex.unlock();
        }

        var header_buf: [12]u8 = undefined;
        while (true) {
            readExactly(self.transport, &header_buf) catch |err| {
                if (err == error.EndOfStream or err == error.NotOpenForReading or err == error.ConnectionResetByPeer or err == error.BrokenPipe) break;
                return err;
            };

            const header = Header.decode(header_buf);

            switch (header.type) {
                .DATA => {
                    self.mutex.lock();
                    var stream_ptr = self.streams.get(header.stream_id);

                    if (stream_ptr == null) {
                        const is_incoming = if (self.is_server) (header.stream_id % 2 != 0) else (header.stream_id % 2 == 0);
                        if (is_incoming) {
                            const new_s = try self.allocator.create(YamuxStream);
                            new_s.* = YamuxStream.init(self.allocator, header.stream_id, self);
                            try self.streams.put(self.allocator, header.stream_id, new_s);
                            try self.accept_queue.append(self.allocator, new_s);
                            self.accept_cond.signal();
                            stream_ptr = new_s;
                        }
                    }
                    self.mutex.unlock();

                    if (header.length > 0) {
                        const payload_buf = try self.allocator.alloc(u8, header.length);
                        errdefer self.allocator.free(payload_buf);

                        try readExactly(self.transport, payload_buf);

                        if (stream_ptr) |stream| {
                            stream.mutex.lock();
                            try stream.incoming_data.appendSlice(self.allocator, payload_buf);
                            if (stream.local_window >= header.length) {
                                stream.local_window -= header.length;
                            } else {
                                stream.local_window = 0;
                            }
                            if (header.flags & Flags.FIN != 0) {
                                stream.closed = true;
                            }
                            stream.cond.signal();
                            stream.mutex.unlock();
                            self.allocator.free(payload_buf);
                        } else {
                            self.allocator.free(payload_buf);
                        }
                    } else if (header.flags & Flags.FIN != 0) {
                        if (stream_ptr) |stream| {
                            stream.mutex.lock();
                            stream.closed = true;
                            stream.cond.signal();
                            stream.mutex.unlock();
                        }
                    }
                },
                .WINDOW_UPDATE => {
                    self.mutex.lock();
                    const stream_ptr = self.streams.get(header.stream_id);
                    self.mutex.unlock();

                    if (stream_ptr) |stream| {
                        stream.mutex.lock();
                        stream.remote_window += header.length;
                        stream.write_cond.signal();
                        stream.mutex.unlock();
                    }
                },
                else => {
                    if (header.length > 0) try self.discardBytes(header.length);
                },
            }
        }
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
        stream.mutex.lock();
        defer stream.mutex.unlock();

        while (stream.incoming_data.items.len == 0 and !stream.closed) {
            stream.cond.wait(&stream.mutex);
        }

        if (stream.incoming_data.items.len == 0 and stream.closed) return 0;

        const to_read = @min(buffer.len, stream.incoming_data.items.len);
        @memcpy(buffer[0..to_read], stream.incoming_data.items[0..to_read]);

        // Remove read bytes from the front (inefficient but OK for MVP)
        for (0..to_read) |_| {
            _ = stream.incoming_data.orderedRemove(0);
        }

        // Increment local window and send update
        stream.local_window += @intCast(to_read);

        if (to_read > 0) {
            var header = Header{
                .type = .WINDOW_UPDATE,
                .flags = 0,
                .stream_id = stream.id,
                .length = @intCast(to_read),
            };
            var h_buf: [12]u8 = undefined;
            header.encode(&h_buf);

            session.mutex.lock();
            _ = try session.transport.write(&h_buf);
            session.mutex.unlock();
        }

        return to_read;
    }

    pub fn streamWrite(ctx: *anyopaque, buffer: []const u8) anyerror!usize {
        const stream: *YamuxStream = @ptrCast(@alignCast(ctx));
        const session = stream.session;

        var total_sent: usize = 0;
        while (total_sent < buffer.len) {
            stream.mutex.lock();
            while (stream.remote_window == 0 and !stream.closed) {
                stream.write_cond.wait(&stream.mutex);
            }
            if (stream.closed) {
                stream.mutex.unlock();
                return error.StreamClosed;
            }

            const can_send = @min(buffer.len - total_sent, @as(usize, @intCast(stream.remote_window)));
            const to_send = buffer[total_sent .. total_sent + can_send];
            stream.remote_window -= @intCast(can_send);
            stream.mutex.unlock();

            // Wrap in a DATA frame
            var header = Header{
                .type = .DATA,
                .flags = 0,
                .stream_id = stream.id,
                .length = @intCast(can_send),
            };

            session.mutex.lock();
            var h_buf: [12]u8 = undefined;
            header.encode(&h_buf);
            _ = try session.transport.write(&h_buf);
            _ = try session.transport.write(to_send);
            session.mutex.unlock();

            total_sent += can_send;
        }

        return total_sent;
    }

    pub fn streamClose(ctx: *anyopaque) void {
        const stream: *YamuxStream = @ptrCast(@alignCast(ctx));
        const session = stream.session;
        stream.mutex.lock();
        if (stream.closed) {
            stream.mutex.unlock();
            return;
        }
        stream.closed = true;
        stream.cond.signal();
        stream.write_cond.signal();
        const id = stream.id;
        stream.mutex.unlock();

        // Send FIN frame
        var header = Header{
            .type = .DATA,
            .flags = Flags.FIN,
            .stream_id = id,
            .length = 0,
        };
        var h_buf: [12]u8 = undefined;
        header.encode(&h_buf);

        session.mutex.lock();
        _ = session.transport.write(&h_buf) catch {};
        session.mutex.unlock();
    }
};
