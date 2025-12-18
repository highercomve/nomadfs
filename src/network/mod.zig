const std = @import("std");

pub const tcp = @import("tcp.zig");
pub const noise = @import("noise.zig");
pub const manager = @import("manager.zig");
pub const yamux = @import("yamux.zig");

/// The generic Stream interface.
/// Represents a bidirectional binary channel (e.g., a Yamux stream or a QUIC stream).
pub const Stream = struct {
    ptr: *anyopaque, // Pointer to the specific implementation state
    vtable: *const StreamVTable,

    pub const StreamVTable = struct {
        read: *const fn (ctx: *anyopaque, buffer: []u8) anyerror!usize,
        write: *const fn (ctx: *anyopaque, buffer: []const u8) anyerror!usize,
        close: *const fn (ctx: *anyopaque) void,
    };

    // Generic wrappers for easy calling
    pub fn read(self: Stream, buffer: []u8) !usize {
        return self.vtable.read(self.ptr, buffer);
    }

    pub fn write(self: Stream, buffer: []const u8) !usize {
        return self.vtable.write(self.ptr, buffer);
    }

    pub fn close(self: Stream) void {
        self.vtable.close(self.ptr);
    }

    // Helper to integrate with Zig's standard library IO (Reader/Writer)
    pub fn reader(self: Stream) std.io.Reader(Stream, anyerror, read) {
        return .{ .context = self };
    }

    pub fn writer(self: Stream) std.io.Writer(Stream, anyerror, write) {
        return .{ .context = self };
    }
};

/// The generic Connection interface.
/// Represents a secure, multiplexed connection to a specific Peer.
pub const Connection = struct {
    ptr: *anyopaque, // Pointer to the implementation (e.g., *TcpSession or *QuicConnection)
    vtable: *const ConnectionVTable,

    pub const ConnectionVTable = struct {
        /// Open a new outbound stream to the peer
        openStream: *const fn (ctx: *anyopaque) anyerror!Stream,
        /// Accept a new inbound stream from the peer
        acceptStream: *const fn (ctx: *anyopaque) anyerror!Stream,
        /// Close the entire connection
        close: *const fn (ctx: *anyopaque) void,
    };

    pub fn openStream(self: Connection) !Stream {
        return self.vtable.openStream(self.ptr);
    }

    pub fn acceptStream(self: Connection) !Stream {
        return self.vtable.acceptStream(self.ptr);
    }

    pub fn close(self: Connection) void {
        self.vtable.close(self.ptr);
    }
};