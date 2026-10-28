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
        return .{ .ip = .{ .ip6 = .{ .bytes = bytes, .port = port, .flow = flow_info, .interface = .{ .index = scope_id } } } };
    }

    pub fn getPort(self: Address) u16 {
        return self.ip.getPort();
    }

    pub fn setPort(self: *Address, port: u16) void {
        self.ip.setPort(port);
    }

    pub fn eql(self: Address, other: Address) bool {
        if (self.ip == .ip6 and other.ip == .ip6 and
            self.ip.ip6.interface.index != other.ip.ip6.interface.index) return false;
        return self.ip.eql(&other.ip);
    }

    /// 0.0.0.0:0 / [::]:0: no address (a relayed connection's peer).
    pub fn isUnspecified(self: Address) bool {
        if (self.getPort() != 0) return false;
        return switch (self.ip) {
            .ip4 => |ip4| std.mem.allEqual(u8, &ip4.bytes, 0),
            .ip6 => |ip6| std.mem.allEqual(u8, &ip6.bytes, 0),
        };
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
            .ip6 => |ip6| return ip6.bytes[0] & 0xfe == 0xfc or
                (ip6.bytes[0] == 0xfe and ip6.bytes[1] & 0xc0 == 0x80),
        }
    }

    pub fn priority(self: Address) u8 {
        if (self.isPrivate()) return 10;
        return 1;
    }

    pub const PosixAddress = extern union {
        ip4: std.posix.sockaddr.in,
        ip6: std.posix.sockaddr.in6,

        pub fn len(self: *const PosixAddress) std.posix.socklen_t {
            return if (self.ip4.family == std.posix.AF.INET6)
                @sizeOf(std.posix.sockaddr.in6)
            else
                @sizeOf(std.posix.sockaddr.in);
        }
    };

    pub fn toPosix(self: Address) PosixAddress {
        return switch (self.ip) {
            .ip4 => |ip4| .{ .ip4 = .{
                .family = std.posix.AF.INET,
                .port = std.mem.nativeToBig(u16, ip4.port),
                .addr = @bitCast(ip4.bytes),
            } },
            .ip6 => |ip6| .{ .ip6 = .{
                .family = std.posix.AF.INET6,
                .port = std.mem.nativeToBig(u16, ip6.port),
                .addr = ip6.bytes,
                .flowinfo = std.mem.nativeToBig(u32, ip6.flow),
                .scope_id = ip6.interface.index,
            } },
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

    /// Sends small writes at once instead of holding them for the peer's
    /// ACK (Nagle). Without it a request or a frame header can wait out
    /// the peer's delayed ACK, tens of milliseconds per round trip.
    pub fn setNoDelay(self: Stream) void {
        if (builtin.os.tag == .windows) return;
        const one: c_int = 1;
        std.posix.setsockopt(self.inner.socket.handle, std.posix.IPPROTO.TCP, std.posix.TCP.NODELAY, std.mem.asBytes(&one)) catch {};
    }

    pub fn read(self: Stream, buffer: []u8) !usize {
        if (builtin.os.tag == .linux) {
            while (true) {
                const rc = std.posix.system.read(@intCast(self.inner.socket.handle), buffer.ptr, buffer.len);
                if (std.posix.errno(rc) == .INTR) continue;
                return switch (std.posix.errno(rc)) {
                    .SUCCESS => @intCast(rc),
                    .BADF => error.FileDescriptorClosed,
                    .AGAIN => error.WouldBlock,
                    .CONNRESET => error.ConnectionResetByPeer,
                    .PIPE => error.BrokenPipe,
                    else => |err| std.posix.unexpectedErrno(err),
                };
            }
        } else {
            const io = std.Io.Threaded.global_single_threaded.io();
            var bufs: [1][]u8 = .{buffer};
            return io.vtable.netRead(io.userdata, self.inner.socket.handle, &bufs);
        }
    }

    pub fn write(self: Stream, buffer: []const u8) !usize {
        if (builtin.os.tag == .linux) {
            while (true) {
                const rc = std.os.linux.sendto(@intCast(self.inner.socket.handle), buffer.ptr, buffer.len, std.os.linux.MSG.NOSIGNAL, null, 0);
                if (std.posix.errno(rc) == .INTR) continue;
                return switch (std.posix.errno(rc)) {
                    .SUCCESS => @intCast(rc),
                    .BADF, .PIPE => error.BrokenPipe,
                    .AGAIN => error.WouldBlock,
                    .CONNRESET => error.ConnectionResetByPeer,
                    else => |err| std.posix.unexpectedErrno(err),
                };
            }
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

    /// Bounds each blocking read and write to `timeout_ms`; 0 removes the
    /// bound. Expiry surfaces as error.WouldBlock. Not wired up on Windows yet.
    pub fn setTimeout(self: Stream, timeout_ms: u32) !void {
        if (builtin.os.tag == .windows) return;
        const tv = std.posix.timeval{
            .sec = @intCast(timeout_ms / std.time.ms_per_s),
            .usec = @intCast((timeout_ms % std.time.ms_per_s) * std.time.us_per_ms),
        };
        const fd = self.inner.socket.handle;
        try std.posix.setsockopt(fd, std.posix.SOL.SOCKET, std.posix.SO.RCVTIMEO, std.mem.asBytes(&tv));
        try std.posix.setsockopt(fd, std.posix.SOL.SOCKET, std.posix.SO.SNDTIMEO, std.mem.asBytes(&tv));
    }

    /// Unblocks pending reads and writes without releasing the descriptor.
    /// Safe to call while another thread is blocked on this stream.
    pub fn shutdown(self: Stream) void {
        const io = std.Io.Threaded.global_single_threaded.io();
        self.inner.shutdown(io, .both) catch {};
    }

    /// Releases the descriptor. No other thread may be using the stream.
    pub fn close(self: Stream) void {
        const io = std.Io.Threaded.global_single_threaded.io();
        self.shutdown();
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
        const client_stream = if (builtin.os.tag == .linux) blk: {
            var sa: std.os.linux.sockaddr.storage = undefined;
            var len: std.os.linux.socklen_t = @sizeOf(@TypeOf(sa));
            const rc = while (true) {
                const result = std.os.linux.accept4(self.inner.socket.handle, @ptrCast(&sa), &len, std.os.linux.SOCK.CLOEXEC);
                switch (std.posix.errno(result)) {
                    .SUCCESS => break result,
                    .INTR => continue,
                    .BADF, .INVAL, .NOTSOCK => return error.FileDescriptorClosed,
                    .MFILE, .NFILE => return error.SystemResources,
                    .CONNABORTED => return error.ConnectionAborted,
                    else => |err| return std.posix.unexpectedErrno(err),
                }
            };
            const addr: Address = if (sa.family == std.posix.AF.INET6) addr6: {
                const ip6: *const std.os.linux.sockaddr.in6 = @ptrCast(&sa);
                break :addr6 Address.initIp6(ip6.addr, std.mem.bigToNative(u16, ip6.port), @intCast(std.mem.bigToNative(u32, ip6.flowinfo)), ip6.scope_id);
            } else Address.fromPosix(@as(*const std.posix.sockaddr.in, @ptrCast(&sa)).*);
            break :blk std.Io.net.Stream{ .socket = .{ .handle = @intCast(rc), .address = addr.ip } };
        } else try self.inner.accept(io);
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

/// Like tcpConnectToAddress, but gives up after `timeout_ms` instead of
/// waiting out the kernel's SYN retries (minutes on Linux). std.Io's connect
/// timeout is not implemented in Zig 0.16, so Linux uses a non-blocking
/// connect + poll; other targets fall back to the blocking connect.
pub fn tcpConnectToAddressTimeout(address: Address, timeout_ms: u32) !Stream {
    std.debug.assert(timeout_ms > 0);
    if (builtin.os.tag != .linux) return tcpConnectToAddress(address);

    const linux = std.os.linux;
    const family: u32 = switch (address.ip) {
        .ip4 => linux.AF.INET,
        .ip6 => linux.AF.INET6,
    };
    const sock_rc = linux.socket(family, linux.SOCK.STREAM | linux.SOCK.CLOEXEC | linux.SOCK.NONBLOCK, 0);
    switch (linux.errno(sock_rc)) {
        .SUCCESS => {},
        .MFILE, .NFILE => return error.SystemResources,
        else => |err| return std.posix.unexpectedErrno(err),
    }
    const fd: i32 = @intCast(sock_rc);
    errdefer _ = linux.close(fd);

    var sa4: linux.sockaddr.in = undefined;
    var sa6: linux.sockaddr.in6 = undefined;
    const sa_ptr: *const linux.sockaddr, const sa_len: linux.socklen_t = switch (address.ip) {
        .ip4 => |ip4| blk: {
            sa4 = .{ .port = std.mem.nativeToBig(u16, ip4.port), .addr = @bitCast(ip4.bytes) };
            break :blk .{ @ptrCast(&sa4), @sizeOf(linux.sockaddr.in) };
        },
        .ip6 => |ip6| blk: {
            sa6 = .{ .port = std.mem.nativeToBig(u16, ip6.port), .flowinfo = std.mem.nativeToBig(u32, ip6.flow), .addr = ip6.bytes, .scope_id = ip6.interface.index };
            break :blk .{ @ptrCast(&sa6), @sizeOf(linux.sockaddr.in6) };
        },
    };

    switch (linux.errno(linux.connect(fd, sa_ptr, sa_len))) {
        .SUCCESS => {},
        .INPROGRESS => try awaitConnect(fd, timeout_ms),
        else => |err| return connectErrno(err),
    }

    // Back to blocking mode: the rest of the stack uses blocking I/O.
    const flags = linux.fcntl(fd, linux.F.GETFL, 0);
    const nonblock: usize = @as(u32, @bitCast(linux.O{ .NONBLOCK = true }));
    _ = linux.fcntl(fd, linux.F.SETFL, flags & ~nonblock);

    return .{ .inner = .{ .socket = .{ .handle = fd, .address = address.ip } } };
}

fn awaitConnect(fd: i32, timeout_ms: u32) !void {
    const linux = std.os.linux;
    var fds = [_]linux.pollfd{.{ .fd = fd, .events = linux.POLL.OUT, .revents = 0 }};
    // Android's seccomp profile forbids the raw `poll` syscall (bionic only
    // uses ppoll), so wait on ppoll even on desktop Linux.
    const timeout: linux.timespec = .{
        .sec = @intCast(timeout_ms / std.time.ms_per_s),
        .nsec = @intCast((timeout_ms % std.time.ms_per_s) * std.time.ns_per_ms),
    };
    const ready = linux.ppoll(&fds, 1, @constCast(&timeout), null);
    switch (linux.errno(ready)) {
        .SUCCESS => {},
        .INTR => return error.ConnectionTimedOut,
        else => |err| return std.posix.unexpectedErrno(err),
    }
    if (ready == 0) return error.ConnectionTimedOut;

    var so_error: i32 = 0;
    var len: linux.socklen_t = @sizeOf(i32);
    switch (linux.errno(linux.getsockopt(fd, linux.SOL.SOCKET, linux.SO.ERROR, @ptrCast(&so_error), &len))) {
        .SUCCESS => {},
        else => |err| return std.posix.unexpectedErrno(err),
    }
    if (so_error != 0) return connectErrno(@enumFromInt(so_error));
}

fn connectErrno(err: std.os.linux.E) anyerror {
    return switch (err) {
        .CONNREFUSED => error.ConnectionRefused,
        .NETUNREACH => error.NetworkUnreachable,
        .HOSTUNREACH => error.HostUnreachable,
        .TIMEDOUT => error.ConnectionTimedOut,
        .ADDRNOTAVAIL => error.AddressUnavailable,
        else => std.posix.unexpectedErrno(err),
    };
}

test "IPv6 POSIX conversion preserves scope and private ranges" {
    const address = Address.initIp6(.{ 0xfe, 0x80 } ++ .{0} ** 14, 1234, 42, 7);
    try std.testing.expect(address.isPrivate());
    try std.testing.expect((try Address.parseIp("fc00::1", 1)).isPrivate());
    try std.testing.expect((try Address.parseIp("fd00::1", 1)).isPrivate());
    try std.testing.expect(!(try Address.parseIp("2001:db8::1", 1)).isPrivate());
    const sa = address.toPosix();
    try std.testing.expectEqual(@as(u32, 7), sa.ip6.scope_id);
    try std.testing.expectEqual(@as(u32, 42), std.mem.bigToNative(u32, sa.ip6.flowinfo));
    try std.testing.expectEqual(@as(u16, 1234), std.mem.bigToNative(u16, sa.ip6.port));
    try std.testing.expectEqual(@as(std.posix.socklen_t, @sizeOf(std.posix.sockaddr.in6)), sa.len());
}

test "bad socket descriptor is an error rather than EOF" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const stream = Stream{ .inner = .{ .socket = .{ .handle = -1, .address = Address.initIp4(.{ 0, 0, 0, 0 }, 0).ip } } };
    var byte: [1]u8 = undefined;
    try std.testing.expectError(error.FileDescriptorClosed, stream.read(&byte));
}
