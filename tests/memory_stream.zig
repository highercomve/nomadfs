const std = @import("std");
const network = @import("nomadfs").network;

pub const MemoryStream = struct {
    buffer: std.ArrayListUnmanaged(u8),
    read_pos: usize = 0,
    allocator: std.mem.Allocator,

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
        if (self.read_pos >= self.buffer.items.len) return 0;
        
        const available = self.buffer.items.len - self.read_pos;
        const to_read = @min(available, buffer.len);
        
        @memcpy(buffer[0..to_read], self.buffer.items[self.read_pos..self.read_pos+to_read]);
        self.read_pos += to_read;
        return to_read;
    }

    fn write(ptr: *anyopaque, buffer: []const u8) anyerror!usize {
        const self: *MemoryStream = @ptrCast(@alignCast(ptr));
        try self.buffer.appendSlice(self.allocator, buffer);
        return buffer.len;
    }

    fn close(ptr: *anyopaque) void {
        _ = ptr;
    }
};
