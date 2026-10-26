pub const compat = @import("../compat.zig");
pub const Address = compat.Address;
pub const Server = compat.Server;
pub const TcpStream = compat.Stream;
const std = @import("std");

pub const tcp = @import("tcp.zig");
pub const noise = @import("noise.zig");
pub const manager = @import("manager.zig");
pub const yamux = @import("yamux.zig");
pub const mdns = @import("mdns.zig");

const id = @import("../id.zig");

/// The generic Stream interface.
/// Represents a bidirectional binary channel (e.g., a Yamux stream or a QUIC stream).
pub const Stream = struct {
    ptr: ?*anyopaque, // Pointer to the specific implementation state
    vtable: ?*const StreamVTable,

    pub fn init(obj: anytype, pargs: anytype) Stream {
        const Ptr = @TypeOf(obj);
        const PtrInfo = @typeInfo(Ptr);
        std.debug.assert(PtrInfo == .pointer); // Must be a pointer
        std.debug.assert(PtrInfo.pointer.size == .one); // Must be a single-item pointer
        std.debug.assert(@typeInfo(PtrInfo.pointer.child) == .@"struct"); // Must point to a struct

        const ArgsPtr = @TypeOf(pargs);
        const ArgsPtrInfo = @typeInfo(ArgsPtr);
        std.debug.assert(ArgsPtrInfo == .pointer); // Must be a pointer
        std.debug.assert(ArgsPtrInfo.pointer.size == .one); // Must be a single-item pointer
        std.debug.assert(ArgsPtrInfo.pointer.child == StreamVTable); // Must be StreamVTable

        return .{
            .ptr = obj,
            .vtable = pargs,
        };
    }

    pub fn GenericReader(
        comptime Context: type,
        comptime ReadError: type,
        comptime readFn: fn (context: Context, buffer: []u8) ReadError!usize,
    ) type {
        return struct {
            context: Context,

            pub const Error = ReadError;

            pub fn read(self: @This(), buffer: []u8) Error!usize {
                return readFn(self.context, buffer);
            }

            pub fn readAll(self: @This(), buffer: []u8) Error!usize {
                var index: usize = 0;
                while (index < buffer.len) {
                    const amt = try self.read(buffer[index..]);
                    if (amt == 0) break;
                    index += amt;
                }
                return index;
            }

            pub fn readNoEof(self: @This(), buffer: []u8) (Error || error{EndOfStream})!void {
                const amt = try self.readAll(buffer);
                if (amt < buffer.len) return error.EndOfStream;
            }

            pub fn readByte(self: @This()) (Error || error{EndOfStream})!u8 {
                var b: [1]u8 = undefined;
                try self.readNoEof(&b);
                return b[0];
            }

            pub fn readInt(self: @This(), comptime T: type, endian: std.builtin.Endian) (Error || error{EndOfStream})!T {
                var bytes: [@sizeOf(T)]u8 = undefined;
                try self.readNoEof(&bytes);
                return std.mem.readInt(T, &bytes, endian);
            }
        };
    }

    pub fn GenericWriter(
        comptime Context: type,
        comptime WriteError: type,
        comptime writeFn: fn (context: Context, bytes: []const u8) WriteError!usize,
    ) type {
        return struct {
            context: Context,

            pub const Error = WriteError;

            pub fn write(self: @This(), bytes: []const u8) Error!usize {
                return writeFn(self.context, bytes);
            }

            pub fn writeAll(self: @This(), bytes: []const u8) Error!void {
                var index: usize = 0;
                while (index < bytes.len) {
                    index += try self.write(bytes[index..]);
                }
            }

            pub fn writeByte(self: @This(), byte: u8) Error!void {
                const b = [1]u8{byte};
                return self.writeAll(&b);
            }

            pub fn writeInt(self: @This(), comptime T: type, value: T, endian: std.builtin.Endian) Error!void {
                var bytes: [@sizeOf(T)]u8 = undefined;
                std.mem.writeInt(T, &bytes, value, endian);
                return self.writeAll(&bytes);
            }
        };
    }

    pub const StreamVTable = struct {
        read: *const fn (ctx: *anyopaque, buffer: []u8) anyerror!usize,
        write: *const fn (ctx: *anyopaque, buffer: []const u8) anyerror!usize,
        close: *const fn (ctx: *anyopaque) void,
        /// Optional: bound each blocking read/write; 0 removes the bound.
        setTimeout: ?*const fn (ctx: *anyopaque, timeout_ms: u32) void = null,
    };

    // Generic wrappers for easy calling
    pub fn read(self: Stream, buffer: []u8) !usize {
        const p = self.ptr orelse {
            @panic("Stream.read: ptr is null");
        };
        const v = self.vtable orelse {
            @panic("Stream.read: vtable is null");
        };
        return v.read(p, buffer);
    }

    pub fn write(self: Stream, buffer: []const u8) !usize {
        const p = self.ptr orelse {
            @panic("Stream.write: ptr is null");
        };
        const v = self.vtable orelse {
            @panic("Stream.write: vtable is null");
        };
        return v.write(p, buffer);
    }

    pub fn close(self: Stream) void {
        const p = self.ptr orelse return;
        const v = self.vtable orelse return;
        v.close(p);
    }

    /// Bounds each blocking read/write; expiry returns error.Timeout.
    /// A no-op for streams that do not support deadlines.
    pub fn setTimeout(self: Stream, timeout_ms: u32) void {
        const p = self.ptr orelse return;
        const v = self.vtable orelse return;
        if (v.setTimeout) |f| f(p, timeout_ms);
    }

    // Helper to integrate with Reader/Writer
    pub fn reader(self: Stream) GenericReader(Stream, anyerror, read) {
        return .{ .context = self };
    }

    pub fn writer(self: Stream) GenericWriter(Stream, anyerror, write) {
        return .{ .context = self };
    }
};

/// The generic Connection interface.
/// Represents a secure, multiplexed connection to a specific Peer.
///
/// Connections are reference counted. Every holder (the manager, a handler
/// thread, a caller of connectToPeer) owns one reference and drops it with
/// deinit(). close() only signals shutdown: it wakes blocked users but frees
/// nothing, so it is safe to call while other threads still use the connection.
/// Streams opened on a connection are valid only while the opener holds a
/// reference.
pub const Connection = struct {
    ptr: ?*anyopaque, // Pointer to the implementation (e.g., *TcpSession or *QuicConnection)

    vtable: ?*const ConnectionVTable,

    pub fn init(obj: anytype, pargs: anytype) Connection {
        const Ptr = @TypeOf(obj);
        const PtrInfo = @typeInfo(Ptr);
        std.debug.assert(PtrInfo == .pointer); // Must be a pointer
        std.debug.assert(PtrInfo.pointer.size == .one); // Must be a single-item pointer
        std.debug.assert(@typeInfo(PtrInfo.pointer.child) == .@"struct"); // Must point to a struct

        const ArgsPtr = @TypeOf(pargs);
        const ArgsPtrInfo = @typeInfo(ArgsPtr);
        std.debug.assert(ArgsPtrInfo == .pointer); // Must be a pointer
        std.debug.assert(ArgsPtrInfo.pointer.size == .one); // Must be a single-item pointer
        std.debug.assert(ArgsPtrInfo.pointer.child == ConnectionVTable); // Must be ConnectionVTable

        return .{
            .ptr = obj,
            .vtable = pargs,
        };
    }

    pub const ConnectionVTable = struct {
        /// Open a new outbound stream to the peer
        openStream: *const fn (ctx: *anyopaque) anyerror!Stream,

        /// Accept a new inbound stream from the peer
        acceptStream: *const fn (ctx: *anyopaque) anyerror!Stream,

        /// Get the address of the remote peer
        getPeerAddress: *const fn (ctx: *anyopaque) Address,

        /// Get the NodeID of the remote peer (derived from handshake)
        getRemoteNodeID: *const fn (ctx: *anyopaque) id.NodeID,

        /// Signal shutdown of the entire connection. Frees nothing.
        close: *const fn (ctx: *anyopaque) void,

        /// Take an additional reference.
        retain: *const fn (ctx: *anyopaque) void,

        /// Drop one reference; the last one frees the connection.
        deinit: *const fn (ctx: *anyopaque) void,

        /// Check if the connection is closed
        isClosed: *const fn (ctx: *anyopaque) bool,

        /// Whether anyone besides the manager is using the connection
        /// (holding a reference or an open stream). Used by idle reaping.
        isInUse: *const fn (ctx: *anyopaque) bool,
    };

    pub fn openStream(self: Connection) !Stream {
        const p = self.ptr orelse {
            @panic("Connection.openStream: ptr is null");
        };

        const v = self.vtable orelse {
            @panic("Connection.openStream: vtable is null");
        };

        return v.openStream(p);
    }

    pub fn acceptStream(self: Connection) !Stream {
        const p = self.ptr orelse {
            @panic("Connection.acceptStream: ptr is null");
        };

        const v = self.vtable orelse {
            @panic("Connection.acceptStream: vtable is null");
        };

        return v.acceptStream(p);
    }

    pub fn getPeerAddress(self: Connection) Address {
        const p = self.ptr orelse {
            @panic("Connection.getPeerAddress: ptr is null");
        };

        const v = self.vtable orelse {
            @panic("Connection.getPeerAddress: vtable is null");
        };

        return v.getPeerAddress(p);
    }

    pub fn getRemoteNodeID(self: Connection) id.NodeID {
        const p = self.ptr orelse {
            @panic("Connection.getRemoteNodeID: ptr is null");
        };

        const v = self.vtable orelse {
            @panic("Connection.getRemoteNodeID: vtable is null");
        };

        return v.getRemoteNodeID(p);
    }

    pub fn close(self: Connection) void {
        const p = self.ptr orelse return;
        const v = self.vtable orelse return;
        v.close(p);
    }

    pub fn retain(self: Connection) void {
        const p = self.ptr orelse return;
        const v = self.vtable orelse return;
        v.retain(p);
    }

    pub fn deinit(self: Connection) void {
        const p = self.ptr orelse return;
        const v = self.vtable orelse return;
        v.deinit(p);
    }

    pub fn isInUse(self: Connection) bool {
        const p = self.ptr orelse return false;
        const v = self.vtable orelse return false;
        return v.isInUse(p);
    }

    pub fn isClosed(self: Connection) bool {
        const p = self.ptr orelse return true;
        const v = self.vtable orelse return true;
        return v.isClosed(p);
    }
};

pub fn isLoopback(addr: Address) bool {
    return addr.isLoopback();
}

pub fn isPrivate(addr: Address) bool {
    return addr.isPrivate();
}

/// Returns a priority score: 0 (Best/Loopback) -> 1 (Private LAN) -> 2 (Public WAN)
pub fn addressPriority(addr: Address) u8 {
    if (isLoopback(addr)) return 0;
    if (isPrivate(addr)) return 1;
    return 2;
}
