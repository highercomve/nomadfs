const builtin = @import("builtin");
const std = @import("std");

/// Network Address abstraction compatible with Zig 0.16.
pub const Address = struct {
    ip: std.Io.net.IpAddress,

    pub fn parseIp(s: []const u8, port: u16) !Address {
        const ip = try std.Io.net.IpAddress.parse(s, port);
        return .{ .ip = ip };
    }

    pub fn initIp4(bytes: [4]u8, port: u16) Address {
        return .{ .ip = .{ .ip4 = .{ .bytes = bytes, .port = port } } };
    }

    pub fn initIp6(bytes: [16]u8, port: u16, flow_info: u20, scope_id: u32) Address {
        _ = flow_info;
        _ = scope_id;
        return .{ .ip = .{ .ip6 = .{ .bytes = bytes, .port = port } } };
    }

    pub fn getPort(self: Address) u16 {
        return self.ip.getPort();
    }

    pub fn setPort(self: *Address, port: u16) void {
        self.ip.setPort(port);
    }

    pub fn eql(self: Address, other: Address) bool {
        return self.ip.eql(&other.ip);
    }

    pub fn isLoopback(self: Address) bool {
        switch (self.ip) {
            .ip4 => |ip4| return ip4.bytes[0] == 127,
            .ip6 => |ip6| {
                const loopback_bytes = [_]u8{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1 };
                return std.mem.eql(u8, &ip6.bytes, &loopback_bytes);
            },
        }
    }

    pub fn isPrivate(self: Address) bool {
        if (self.isLoopback()) return true;
        switch (self.ip) {
            .ip4 => |ip4| {
                const b = ip4.bytes;
                if (b[0] == 10) return true;
                if (b[0] == 172 and b[1] >= 16 and b[1] <= 31) return true;
                if (b[0] == 192 and b[1] == 168) return true;
                return false;
            },
            .ip6 => return false,
        }
    }

    pub fn priority(self: Address) u8 {
        if (self.isPrivate()) return 10;
        return 1;
    }

    pub fn toPosix(self: Address) std.posix.sockaddr.in {
        const port_be = std.mem.nativeToBig(u16, self.getPort());
        const addr_bytes = switch (self.ip) {
            .ip4 => |ip4| ip4.bytes,
            .ip6 => [4]u8{ 0, 0, 0, 0 },
        };
        const addr_u32 = @as(u32, @bitCast(addr_bytes));
        return .{
            .family = std.posix.AF.INET,
            .port = port_be,
            .addr = addr_u32,
        };
    }

    pub fn fromPosix(sa: std.posix.sockaddr.in) Address {
        const port = std.mem.bigToNative(u16, sa.port);
        const bytes = @as([4]u8, @bitCast(sa.addr));
        return initIp4(bytes, port);
    }

    pub fn format(self: Address, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        return self.ip.format(writer);
    }
};

/// TCP / Network Stream abstraction compatible with Zig 0.16.
pub const Stream = struct {
    inner: std.Io.net.Stream,

    pub fn read(self: Stream, buffer: []u8) !usize {
        if (builtin.os.tag == .linux) {
            const rc = std.posix.system.read(@intCast(self.inner.socket.handle), buffer.ptr, buffer.len);
            return switch (std.posix.errno(rc)) {
                .SUCCESS => rc,
                .BADF => 0,
                .AGAIN => error.WouldBlock,
                .CONNRESET => error.ConnectionResetByPeer,
                .PIPE => error.BrokenPipe,
                else => |err| std.posix.unexpectedErrno(err),
            };
        } else {
            const io = std.Io.Threaded.global_single_threaded.io();
            var bufs: [1][]u8 = .{buffer};
            return io.vtable.netRead(io.userdata, self.inner.socket.handle, &bufs);
        }
    }

    pub fn write(self: Stream, buffer: []const u8) !usize {
        if (builtin.os.tag == .linux) {
            const rc = std.posix.system.write(@intCast(self.inner.socket.handle), buffer.ptr, buffer.len);
            return switch (std.posix.errno(rc)) {
                .SUCCESS => rc,
                .BADF, .PIPE => error.BrokenPipe,
                .AGAIN => error.WouldBlock,
                .CONNRESET => error.ConnectionResetByPeer,
                else => |err| std.posix.unexpectedErrno(err),
            };
        } else {
            const io = std.Io.Threaded.global_single_threaded.io();
            var bufs: [1][]const u8 = .{buffer};
            return io.vtable.netWrite(io.userdata, self.inner.socket.handle, "", &bufs, 1);
        }
    }

    pub fn writeAll(self: Stream, buffer: []const u8) !void {
        var written: usize = 0;
        while (written < buffer.len) {
            const n = try self.write(buffer[written..]);
            if (n == 0) return error.WriteZero;
            written += n;
        }
    }

    pub fn close(self: Stream) void {
        const io = std.Io.Threaded.global_single_threaded.io();
        if (builtin.os.tag != .windows) {
            _ = std.posix.system.shutdown(@intCast(self.inner.socket.handle), std.posix.SHUT.RDWR);
        }
        self.inner.close(io);
    }
};

/// TCP Server abstraction compatible with Zig 0.16.
pub const Server = struct {
    inner: std.Io.net.Server,

    pub const Connection = struct {
        stream: Stream,
        address: Address,
    };

    pub fn accept(self: *Server) !Connection {
        const io = std.Io.Threaded.global_single_threaded.io();
        const client_stream = try self.inner.accept(io);
        return .{
            .stream = .{ .inner = client_stream },
            .address = .{ .ip = client_stream.socket.address },
        };
    }

    pub fn deinit(self: *Server) void {
        const io = std.Io.Threaded.global_single_threaded.io();
        if (builtin.os.tag != .windows) {
            _ = std.posix.system.shutdown(@intCast(self.inner.socket.handle), std.posix.SHUT.RDWR);
        }
        self.inner.deinit(io);
    }
};

pub fn listen(port: u16) !Server {
    const io = std.Io.Threaded.global_single_threaded.io();
    const addr = try std.Io.net.IpAddress.parse("0.0.0.0", port);
    const s = try addr.listen(io, .{ .reuse_address = true });
    return .{ .inner = s };
}

pub fn tcpConnectToAddress(address: Address) !Stream {
    const io = std.Io.Threaded.global_single_threaded.io();
    const s = try address.ip.connect(io, .{ .mode = .stream });
    return .{ .inner = s };
}
