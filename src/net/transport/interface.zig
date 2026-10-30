//! The interfaces every transport implements (Stream, Connection) and the
//! socket types they are built on. Transport files import this rather than
//! mod.zig, so the package hub stays out of their imports.

const std = @import("std");
pub const compat = @import("../compat.zig");
pub const Address = compat.Address;
pub const Server = compat.Server;
pub const TcpStream = compat.Stream;

const id = @import("../id.zig");

/// Checks what an interface's init() expects: `obj` points to one struct
/// (the implementation) and `pargs` to one `VTable`.
fn assertImpl(comptime VTable: type, obj: anytype, pargs: anytype) void {
    const PtrInfo = @typeInfo(@TypeOf(obj));
    std.debug.assert(PtrInfo == .pointer); // Must be a pointer
    std.debug.assert(PtrInfo.pointer.size == .one); // Must be a single-item pointer
    std.debug.assert(@typeInfo(PtrInfo.pointer.child) == .@"struct"); // Must point to a struct

    const ArgsPtrInfo = @typeInfo(@TypeOf(pargs));
    std.debug.assert(ArgsPtrInfo == .pointer); // Must be a pointer
    std.debug.assert(ArgsPtrInfo.pointer.size == .one); // Must be a single-item pointer
    std.debug.assert(ArgsPtrInfo.pointer.child == VTable); // Must be the interface's vtable
}

/// The generic Stream interface.
/// Represents a bidirectional binary channel (e.g., a Yamux stream or a QUIC stream).
pub const Stream = struct {
    ptr: ?*anyopaque, // Pointer to the specific implementation state
    vtable: ?*const StreamVTable,

    pub fn init(obj: anytype, pargs: anytype) Stream {
        assertImpl(StreamVTable, obj, pargs);
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
        /// Optional: wakes blocked reads and writes (reads then end, writes
        /// fail) without releasing the stream; close() is still needed.
        /// For tearing down a stream another thread is reading.
        shutdown: ?*const fn (ctx: *anyopaque) void = null,
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

    /// Wakes blocked reads and writes; see StreamVTable.shutdown. A no-op
    /// for streams without it.
    pub fn shutdown(self: Stream) void {
        const p = self.ptr orelse return;
        const v = self.vtable orelse return;
        if (v.shutdown) |f| f(p);
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
        assertImpl(ConnectionVTable, obj, pargs);
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

        /// The device identity the peer proved in the handshake (hash of
        /// its Ed25519 key), when the transport authenticates devices.
        getRemoteDeviceID: ?*const fn (ctx: *anyopaque) ?id.NodeID = null,

        /// Signal shutdown of the entire connection. Frees nothing.
        close: *const fn (ctx: *anyopaque) void,

        /// Take an additional reference.
        retain: *const fn (ctx: *anyopaque) void,

        /// Drop one reference; the last one frees the connection.
        deinit: *const fn (ctx: *anyopaque) void,

        /// Check if the connection is closed
        isClosed: *const fn (ctx: *anyopaque) bool,

        /// Periodic cleanup; may perform I/O, so callers must hold no pool lock.
        maintain: ?*const fn (ctx: *anyopaque) void = null,

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

    /// The peer's verified device identity, or null when the transport
    /// did not authenticate one.
    pub fn getRemoteDeviceID(self: Connection) ?id.NodeID {
        const p = self.ptr orelse return null;
        const v = self.vtable orelse return null;
        const f = v.getRemoteDeviceID orelse return null;
        return f(p);
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

    pub fn maintain(self: Connection) void {
        const p = self.ptr orelse return;
        const v = self.vtable orelse return;
        if (v.maintain) |f| f(p);
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

/// The reference count of a Connection implementation. Starts at one, the
/// creator's reference.
pub const RefCount = struct {
    count: std.atomic.Value(u32) = std.atomic.Value(u32).init(1),

    pub fn retain(self: *RefCount) void {
        const prev = self.count.fetchAdd(1, .monotonic);
        std.debug.assert(prev > 0);
    }

    /// Drops one reference; true when it was the last.
    pub fn release(self: *RefCount) bool {
        const prev = self.count.fetchSub(1, .acq_rel);
        std.debug.assert(prev > 0);
        return prev == 1;
    }

    /// Whether anyone besides the one holder (the manager) has a reference.
    pub fn shared(self: *const RefCount) bool {
        return self.count.load(.acquire) > 1;
    }
};
