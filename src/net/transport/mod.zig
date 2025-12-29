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

    pub const StreamVTable = struct {
        read: *const fn (ctx: *anyopaque, buffer: []u8) anyerror!usize,
        write: *const fn (ctx: *anyopaque, buffer: []const u8) anyerror!usize,
        close: *const fn (ctx: *anyopaque) void,
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

    // Helper to integrate with Zig's standard library IO (Reader/Writer)
    pub fn reader(self: Stream) std.io.GenericReader(Stream, anyerror, read) {
        return .{ .context = self };
    }

    pub fn writer(self: Stream) std.io.GenericWriter(Stream, anyerror, write) {
        return .{ .context = self };
    }
};

/// The generic Connection interface.
/// Represents a secure, multiplexed connection to a specific Peer.
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
        getPeerAddress: *const fn (ctx: *anyopaque) std.net.Address,

        /// Get the NodeID of the remote peer (derived from handshake)
        getRemoteNodeID: *const fn (ctx: *anyopaque) id.NodeID,

        /// Close the entire connection (shutdown)
        close: *const fn (ctx: *anyopaque) void,

        /// Deinitialize the connection and free memory
        deinit: *const fn (ctx: *anyopaque) void,

        /// Check if the connection is closed
        isClosed: *const fn (ctx: *anyopaque) bool,
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

    pub fn getPeerAddress(self: Connection) std.net.Address {
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

    pub fn deinit(self: Connection) void {
        const p = self.ptr orelse return;
        const v = self.vtable orelse return;
        v.deinit(p);
    }

    pub fn isClosed(self: Connection) bool {
        const p = self.ptr orelse return true;
        const v = self.vtable orelse return true;
        return v.isClosed(p);
    }
};

pub fn isLoopback(addr: std.net.Address) bool {
    switch (addr.any.family) {
        std.posix.AF.INET => {
            return (addr.in.sa.addr & 0xFF) == 127;
        },
        std.posix.AF.INET6 => {
            const loopback_bytes = [_]u8{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1 };
            return std.mem.eql(u8, &addr.in6.sa.addr, &loopback_bytes);
        },
        else => return false,
    }
}

pub fn isPrivate(addr: std.net.Address) bool {
    if (isLoopback(addr)) return true;
    switch (addr.any.family) {
        std.posix.AF.INET => {
            const ip = std.mem.nativeToBig(u32, addr.in.sa.addr);
            // 10.0.0.0/8
            if ((ip & 0xFF000000) == 0x0A000000) return true;
            // 172.16.0.0/12
            if ((ip & 0xFFF00000) == 0xAC100000) return true;
            // 192.168.0.0/16
            if ((ip & 0xFFFF0000) == 0xC0A80000) return true;
            return false;
        },
        std.posix.AF.INET6 => {
            // Unique Local Address (fc00::/7)
            return (addr.in6.sa.addr[0] & 0xFE) == 0xFC;
        },
        else => return false,
    }
}

/// Returns a priority score: 0 (Best/Loopback) -> 1 (Private LAN) -> 2 (Public WAN)
pub fn addressPriority(addr: std.net.Address) u8 {
    if (isLoopback(addr)) return 0;
    if (isPrivate(addr)) return 1;
    return 2;
}

