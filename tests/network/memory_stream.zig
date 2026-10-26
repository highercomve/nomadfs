const sync = @import("nomadfs").sync;
const std = @import("std");
const network = @import("nomadfs").net.transport;

pub const MemoryStream = struct {
    buffer: std.ArrayList(u8),
    read_pos: usize = 0,
    allocator: std.mem.Allocator,
    mutex: sync.Mutex = .{},

    pub fn init(allocator: std.mem.Allocator) MemoryStream {
        return .{
            .buffer = .empty,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *MemoryStream) void {
        self.buffer.deinit(self.allocator);
    }

    pub fn stream(self: *MemoryStream) network.Stream {
        return network.Stream.init(self, &memory_stream_vtable);
    }

    fn read(ptr: *anyopaque, buffer: []u8) anyerror!usize {
        const self: *MemoryStream = @ptrCast(@alignCast(ptr));
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.read_pos >= self.buffer.items.len) return 0;

        const available = self.buffer.items.len - self.read_pos;
        const to_read = @min(available, buffer.len);

        @memcpy(buffer[0..to_read], self.buffer.items[self.read_pos .. self.read_pos + to_read]);
        self.read_pos += to_read;
        return to_read;
    }

    fn write(ptr: *anyopaque, buffer: []const u8) anyerror!usize {
        const self: *MemoryStream = @ptrCast(@alignCast(ptr));
        self.mutex.lock();
        defer self.mutex.unlock();
        try self.buffer.appendSlice(self.allocator, buffer);
        return buffer.len;
    }

    fn close(ptr: *anyopaque) void {
        _ = ptr;
    }
};

const memory_stream_vtable = network.Stream.StreamVTable{
    .read = MemoryStream.read,
    .write = MemoryStream.write,
    .close = MemoryStream.close,
};

pub const Pipe = struct {
    buffer_a_to_b: std.ArrayListUnmanaged(u8) = .empty,
    buffer_b_to_a: std.ArrayListUnmanaged(u8) = .empty,
    cursor_a_to_b: usize = 0,
    cursor_b_to_a: usize = 0,
    mutex: sync.Mutex = .{},
    cond: sync.Condition = .{},
    closed: bool = false,
    /// Lets tests mark the connection as in use to exercise idle reaping.
    in_use: bool = false,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) Pipe {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Pipe) void {
        self.buffer_a_to_b.deinit(self.allocator);
        self.buffer_b_to_a.deinit(self.allocator);
    }

    pub fn client(self: *Pipe) network.Stream {
        return network.Stream.init(self, &pipe_client_stream_vtable);
    }

    pub fn server(self: *Pipe) network.Stream {
        return network.Stream.init(self, &pipe_server_stream_vtable);
    }

    fn readClient(ptr: *anyopaque, buffer: []u8) anyerror!usize {
        const self: *Pipe = @ptrCast(@alignCast(ptr));
        self.mutex.lock();
        defer self.mutex.unlock();

        while (self.cursor_b_to_a >= self.buffer_b_to_a.items.len) {
            if (self.closed) return 0;
            self.cond.wait(&self.mutex);
        }

        const available = self.buffer_b_to_a.items.len - self.cursor_b_to_a;
        const to_read = @min(available, buffer.len);
        @memcpy(buffer[0..to_read], self.buffer_b_to_a.items[self.cursor_b_to_a .. self.cursor_b_to_a + to_read]);
        self.cursor_b_to_a += to_read;
        return to_read;
    }

    fn writeClient(ptr: *anyopaque, buffer: []const u8) anyerror!usize {
        const self: *Pipe = @ptrCast(@alignCast(ptr));
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.closed) return error.BrokenPipe;
        try self.buffer_a_to_b.appendSlice(self.allocator, buffer);
        self.cond.broadcast();
        return buffer.len;
    }

    fn readServer(ptr: *anyopaque, buffer: []u8) anyerror!usize {
        const self: *Pipe = @ptrCast(@alignCast(ptr));
        self.mutex.lock();
        defer self.mutex.unlock();

        while (self.cursor_a_to_b >= self.buffer_a_to_b.items.len) {
            if (self.closed) return 0;
            self.cond.wait(&self.mutex);
        }

        const available = self.buffer_a_to_b.items.len - self.cursor_a_to_b;
        const to_read = @min(available, buffer.len);
        @memcpy(buffer[0..to_read], self.buffer_a_to_b.items[self.cursor_a_to_b .. self.cursor_a_to_b + to_read]);
        self.cursor_a_to_b += to_read;
        return to_read;
    }

    fn writeServer(ptr: *anyopaque, buffer: []const u8) anyerror!usize {
        const self: *Pipe = @ptrCast(@alignCast(ptr));
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.closed) return error.BrokenPipe;
        try self.buffer_b_to_a.appendSlice(self.allocator, buffer);
        self.cond.broadcast();
        return buffer.len;
    }

    pub fn connection(self: *Pipe) network.Connection {
        return network.Connection.init(self, &pipe_connection_vtable);
    }

    fn pipeDeinit(ctx: *anyopaque) void {
        const self: *Pipe = @ptrCast(@alignCast(ctx));
        self.deinit();
    }

    fn openStream(ctx: *anyopaque) anyerror!network.Stream {
        const self: *Pipe = @ptrCast(@alignCast(ctx));
        return self.client();
    }

    fn acceptStream(ctx: *anyopaque) anyerror!network.Stream {
        const self: *Pipe = @ptrCast(@alignCast(ctx));
        return self.server();
    }

    fn getPeerAddress(ctx: *anyopaque) network.Address {
        _ = ctx;
        return network.Address.parseIp("127.0.0.1", 0) catch unreachable;
    }

    fn getRemoteNodeID(ctx: *anyopaque) @import("nomadfs").net.id.NodeID {
        _ = ctx;
        var bytes: [32]u8 = undefined;
        @memset(&bytes, 0);
        return .{ .bytes = bytes };
    }

    fn isClosed(ctx: *anyopaque) bool {
        const self: *Pipe = @ptrCast(@alignCast(ctx));
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.closed;
    }

    fn isInUse(ctx: *anyopaque) bool {
        const self: *Pipe = @ptrCast(@alignCast(ctx));
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.in_use;
    }

    pub fn setInUse(self: *Pipe, in_use: bool) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.in_use = in_use;
    }

    pub fn stop(self: *Pipe) void {
        self.mutex.lock();
        self.closed = true;
        self.cond.broadcast();
        self.mutex.unlock();
    }

    fn close(ptr: *anyopaque) void {
        const self: *Pipe = @ptrCast(@alignCast(ptr));
        self.stop();
    }

    /// Pipes are single-owner in tests; the last holder calls deinit.
    fn retain(ctx: *anyopaque) void {
        _ = ctx;
    }
};

const pipe_connection_vtable = network.Connection.ConnectionVTable{
    .openStream = Pipe.openStream,
    .acceptStream = Pipe.acceptStream,
    .getPeerAddress = Pipe.getPeerAddress,
    .getRemoteNodeID = Pipe.getRemoteNodeID,
    .close = Pipe.close,
    .retain = Pipe.retain,
    .deinit = Pipe.pipeDeinit,
    .isClosed = Pipe.isClosed,
    .isInUse = Pipe.isInUse,
};

const pipe_client_stream_vtable = network.Stream.StreamVTable{
    .read = Pipe.readClient,
    .write = Pipe.writeClient,
    .close = Pipe.close,
};

const pipe_server_stream_vtable = network.Stream.StreamVTable{
    .read = Pipe.readServer,
    .write = Pipe.writeServer,
    .close = Pipe.close,
};
