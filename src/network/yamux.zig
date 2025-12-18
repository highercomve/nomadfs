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

/// A single logical stream within a Yamux session.
pub const YamuxStream = struct {
    id: u32,
    session: *Session,
    incoming_data: std.ArrayListUnmanaged(u8),
    mutex: std.Thread.Mutex = .{},
    cond: std.Thread.Condition = .{},
    closed: bool = false,

    pub fn init(allocator: std.mem.Allocator, id: u32, session: *Session) YamuxStream {
        _ = allocator;
        return .{
            .id = id,
            .session = session,
            .incoming_data = .{},
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
                stream.mutex.unlock();
            }
            self.accept_cond.broadcast();
            self.mutex.unlock();
        }

        var header_buf: [12]u8 = undefined;
        while (true) {
            const n = self.transport.read(&header_buf) catch |err| {
                // If the connection is closed or reset, stop the loop gracefully
                switch (err) {
                    error.NotOpenForReading, error.ConnectionResetByPeer, error.BrokenPipe, error.EndOfStream => break,
                    else => return err,
                }
            };
            if (n == 0) break; // Connection closed
            if (n < 12) return error.IncompleteHeader;

            const header = Header.decode(header_buf);
            
            switch (header.type) {
                .DATA => {
                    self.mutex.lock();
                    var stream_ptr = self.streams.get(header.stream_id);
                    
                    if (stream_ptr == null) {
                        // New stream?
                        // Server accepts odd IDs, Client accepts even IDs?
                        // If we are server (next_id=2), we accept 1, 3...
                        // If we are client (next_id=1), we accept 2, 4...
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
                        // Read payload
                        const payload_buf = try self.allocator.alloc(u8, header.length);
                        errdefer self.allocator.free(payload_buf);
                        
                        const read_n = try self.transport.read(payload_buf);
                        if (read_n != header.length) {
                            self.allocator.free(payload_buf);
                            return error.IncompletePayload;
                        }

                        if (stream_ptr) |stream| {
                            stream.mutex.lock();
                            try stream.incoming_data.appendSlice(self.allocator, payload_buf);
                            stream.cond.signal();
                            stream.mutex.unlock();
                            self.allocator.free(payload_buf);
                        } else {
                            self.allocator.free(payload_buf);
                        }
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
            const to_read = @min(remaining, buf.len);
            _ = try self.transport.read(buf[0..to_read]);
            remaining -= to_read;
        }
    }

    pub fn streamRead(ctx: *anyopaque, buffer: []u8) anyerror!usize {
        const stream: *YamuxStream = @ptrCast(@alignCast(ctx));
        stream.mutex.lock();
        defer stream.mutex.unlock();

        while (stream.incoming_data.items.len == 0 and !stream.closed) {
            stream.cond.wait(&stream.mutex);
        }

        const to_read = @min(buffer.len, stream.incoming_data.items.len);
        @memcpy(buffer[0..to_read], stream.incoming_data.items[0..to_read]);
        
        // Remove read bytes from the front (inefficient but OK for MVP)
        for (0..to_read) |_| {
            _ = stream.incoming_data.orderedRemove(0);
        }

        return to_read;
    }

    pub fn streamWrite(ctx: *anyopaque, buffer: []const u8) anyerror!usize {
        const stream: *YamuxStream = @ptrCast(@alignCast(ctx));
        const session = stream.session;

        // Wrap in a DATA frame
        var header = Header{
            .type = .DATA,
            .flags = 0,
            .stream_id = stream.id,
            .length = @intCast(buffer.len),
        };
        
        session.mutex.lock();
        defer session.mutex.unlock();

        var h_buf: [12]u8 = undefined;
        header.encode(&h_buf);
        _ = try session.transport.write(&h_buf);
        _ = try session.transport.write(buffer);

        return buffer.len;
    }

    pub fn streamClose(ctx: *anyopaque) void {
        const stream: *YamuxStream = @ptrCast(@alignCast(ctx));
        stream.mutex.lock();
        stream.closed = true;
        stream.cond.signal();
        stream.mutex.unlock();
        // TODO: Send FIN frame
    }
};
