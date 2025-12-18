const std = @import("std");
const network = @import("nomadfs").network;

pub const MemoryStream = struct {
    buffer: std.ArrayListUnmanaged(u8),
    read_pos: usize = 0,
    allocator: std.mem.Allocator,
    mutex: std.Thread.Mutex = .{},

    pub fn init(allocator: std.mem.Allocator) MemoryStream {
        return .{
            .buffer = std.ArrayListUnmanaged(u8){},
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *MemoryStream) void {
        self.buffer.deinit(self.allocator);
    }

    pub fn stream(self: *MemoryStream) network.Stream {
        return .{
            .ptr = self,
            .vtable = &network.Stream.StreamVTable{
                .read = read,
                .write = write,
                .close = close,
            },
        };
    }

    fn read(ptr: *anyopaque, buffer: []u8) anyerror!usize {
        const self: *MemoryStream = @ptrCast(@alignCast(ptr));
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.read_pos >= self.buffer.items.len) return 0;
        
        const available = self.buffer.items.len - self.read_pos;
        const to_read = @min(available, buffer.len);
        
        @memcpy(buffer[0..to_read], self.buffer.items[self.read_pos..self.read_pos+to_read]);
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

pub const Pipe = struct {
    buffer_a_to_b: std.ArrayListUnmanaged(u8) = .{},
    buffer_b_to_a: std.ArrayListUnmanaged(u8) = .{},
    cursor_a_to_b: usize = 0,
    cursor_b_to_a: usize = 0,
    mutex: std.Thread.Mutex = .{},
    cond: std.Thread.Condition = .{},
    closed: bool = false,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) *Pipe {
        const self = allocator.create(Pipe) catch @panic("OOM");
        self.* = .{ .allocator = allocator };
        return self;
    }

    pub fn deinit(self: *Pipe) void {
        self.buffer_a_to_b.deinit(self.allocator);
        self.buffer_b_to_a.deinit(self.allocator);
        self.allocator.destroy(self);
    }

    pub fn client(self: *Pipe) network.Stream {
        return .{
            .ptr = self,
            .vtable = &network.Stream.StreamVTable{
                .read = readClient,
                .write = writeClient,
                .close = close,
            },
        };
    }

    pub fn server(self: *Pipe) network.Stream {
        return .{
            .ptr = self,
            .vtable = &network.Stream.StreamVTable{
                .read = readServer,
                .write = writeServer,
                .close = close,
            },
        };
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
        @memcpy(buffer[0..to_read], self.buffer_b_to_a.items[self.cursor_b_to_a..self.cursor_b_to_a+to_read]);
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
        @memcpy(buffer[0..to_read], self.buffer_a_to_b.items[self.cursor_a_to_b..self.cursor_a_to_b+to_read]);
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

    fn close(ptr: *anyopaque) void {
        const self: *Pipe = @ptrCast(@alignCast(ptr));
        self.mutex.lock();
        self.closed = true;
        self.cond.broadcast();
        self.mutex.unlock();
    }
};