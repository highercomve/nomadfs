//! Thin wrappers over the raw socket calls the UDP users (mDNS, NAT
//! discovery) need. Each retries on EINTR and turns errno into an error.

const std = @import("std");

const posix = std.posix;
const system = posix.system;

pub fn createSocket(domain: u32, sock_type: u32, protocol: u32) !posix.socket_t {
    while (true) {
        const rc = system.socket(domain, sock_type, protocol);
        if (posix.errno(rc) == .INTR) continue;
        return switch (posix.errno(rc)) {
            .SUCCESS => @intCast(rc),
            else => |err| posix.unexpectedErrno(err),
        };
    }
}

pub fn closeSocket(s: posix.socket_t) void {
    _ = system.close(@intCast(s));
}

pub fn shutdownSocket(s: posix.socket_t, how: i32) void {
    _ = system.shutdown(@intCast(s), how);
}

pub fn bindSocket(s: posix.socket_t, addr: *const posix.sockaddr, len: posix.socklen_t) !void {
    while (true) {
        const rc = system.bind(@intCast(s), addr, len);
        if (posix.errno(rc) == .INTR) continue;
        return switch (posix.errno(rc)) {
            .SUCCESS => {},
            else => |err| posix.unexpectedErrno(err),
        };
    }
}

pub fn sendtoSocket(s: posix.socket_t, buf: []const u8, flags: u32, addr: ?*const posix.sockaddr, alen: posix.socklen_t) !usize {
    while (true) {
        const rc = system.sendto(@intCast(s), buf.ptr, buf.len, flags, addr, alen);
        if (posix.errno(rc) == .INTR) continue;
        return switch (posix.errno(rc)) {
            .SUCCESS => @intCast(rc),
            else => |err| posix.unexpectedErrno(err),
        };
    }
}

/// Returns error.WouldBlock when a receive timeout expires.
pub fn recvfromSocket(s: posix.socket_t, buf: []u8, flags: u32, addr: ?*posix.sockaddr, alen: ?*posix.socklen_t) !usize {
    while (true) {
        const rc = system.recvfrom(@intCast(s), buf.ptr, buf.len, flags, addr, alen);
        if (posix.errno(rc) == .INTR) continue;
        return switch (posix.errno(rc)) {
            .SUCCESS => @intCast(rc),
            .AGAIN => error.WouldBlock,
            else => |err| posix.unexpectedErrno(err),
        };
    }
}
