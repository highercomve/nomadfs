//! Whose process a loopback connection comes from. The WebDAV server
//! listens on 127.0.0.1, which every account on the machine can reach, and
//! its URL (token included) is public on macOS: the mount table and the
//! webdavfs_agent command line show it to every account. So a connection
//! is served only when it comes from a process of this user.
//!
//! Linux reads the socket's owner from /proc/net/tcp. macOS has no such
//! table, but lets a process read only its own user's file descriptors:
//! the client socket is looked for among them, so another account's is
//! never found. Windows mounts through the WebClient service (another
//! account) and its mappings are private to each user: the token is the
//! check there.

const std = @import("std");
const builtin = @import("builtin");

/// Where a connection's owner can be told.
pub const supported = (builtin.os.tag == .linux and !builtin.abi.isAndroid()) or builtin.os.tag == .macos;

/// The connection from 127.0.0.1:`client_port` to 127.0.0.1:`server_port`
/// belongs to a process of this user. False when it can't be told.
pub fn sameUser(gpa: std.mem.Allocator, server_port: u16, client_port: u16) bool {
    // On 127.0.0.1 no client can hold the listener's own port: a "client"
    // claiming it came from another address, and would otherwise match
    // the server's own accepted socket below.
    if (client_port == server_port) return false;
    return switch (builtin.os.tag) {
        .linux => linuxSameUser(gpa, server_port, client_port),
        .macos => darwinSameUser(gpa, server_port, client_port),
        else => true,
    };
}

// ---- Linux ----

/// /proc/net/tcp past this is not read (a line is about 150 bytes).
const max_tcp_table = 16 * 1024 * 1024;

fn linuxSameUser(gpa: std.mem.Allocator, server_port: u16, client_port: u16) bool {
    const uid = std.os.linux.getuid();
    // A client on a dual-stack socket shows up in tcp6, as ::ffff:127.0.0.1.
    for ([_][]const u8{ "/proc/net/tcp", "/proc/net/tcp6" }) |path| {
        const table = readTable(gpa, path) orelse continue;
        defer gpa.free(table);
        if (tableOwner(table, server_port, client_port)) |owner| return owner == uid;
    }
    return false;
}

fn readTable(gpa: std.mem.Allocator, path: []const u8) ?[]u8 {
    const io = std.Io.Threaded.global_single_threaded.io();
    var file = std.Io.Dir.cwd().openFile(io, path, .{}) catch return null;
    defer file.close(io);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var buf: [64 * 1024]u8 = undefined;
    while (out.items.len < max_tcp_table) {
        // /proc files have no size: read until a short read.
        const n = file.readPositionalAll(io, &buf, out.items.len) catch {
            out.deinit(gpa);
            return null;
        };
        out.appendSlice(gpa, buf[0..n]) catch {
            out.deinit(gpa);
            return null;
        };
        if (n < buf.len) break;
    }
    return out.toOwnedSlice(gpa) catch {
        out.deinit(gpa);
        return null;
    };
}

/// 127.0.0.1 as /proc/net/tcp shows it (host order), and as tcp6 shows
/// ::ffff:127.0.0.1 (a client on a dual-stack socket).
const loopback4 = "0100007F";
const loopback6 = "0000000000000000FFFF00000100007F";

/// `address` (`ADDR:PORT`) is exactly 127.0.0.1.
fn isLoopback(address: []const u8) bool {
    const colon = std.mem.indexOfScalar(u8, address, ':') orelse return false;
    const host = address[0..colon];
    return std.ascii.eqlIgnoreCase(host, loopback4) or std.ascii.eqlIgnoreCase(host, loopback6);
}

/// The uid owning the established socket from loopback port
/// `client_port` to loopback port `server_port`, in a /proc/net/tcp table.
fn tableOwner(table: []const u8, server_port: u16, client_port: u16) ?u32 {
    var lines = std.mem.splitScalar(u8, table, '\n');
    _ = lines.next(); // the header
    while (lines.next()) |line| {
        // sl local_address rem_address st tx:rx tr:when retrnsmt uid ...
        var fields: [8][]const u8 = undefined;
        var it = std.mem.tokenizeScalar(u8, line, ' ');
        var n: usize = 0;
        while (n < fields.len) : (n += 1) fields[n] = it.next() orelse break;
        if (n < fields.len) continue;
        const local = fields[1];
        const remote = fields[2];
        const state = fields[3];
        const uid_text = fields[7];
        if (portOf(local) != client_port or portOf(remote) != server_port) continue;
        // Both ends 127.0.0.1, and connected (01: TCP_ESTABLISHED), not a
        // listener or a socket on another address that shares the ports.
        if (!std.mem.eql(u8, state, "01") or !isLoopback(local) or !isLoopback(remote)) continue;
        return std.fmt.parseInt(u32, uid_text, 10) catch continue;
    }
    return null;
}

fn portOf(address: []const u8) ?u16 {
    const colon = std.mem.indexOfScalar(u8, address, ':') orelse return null;
    return std.fmt.parseInt(u16, address[colon + 1 ..], 16) catch null;
}

test tableOwner {
    const table =
        \\  sl  local_address rem_address   st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode
        \\   0: 0100007F:B8D4 0100007F:BB8E 01 00000000:00000000 00:00000000 00000000  1000        0 1 1 0000000000000000 20 4 30 10 -1
        \\   1: 0100007F:B8D5 0100007F:BB8E 01 00000000:00000000 00:00000000 00000000  1001        0 2 1 0000000000000000 20 4 30 10 -1
        \\   2: 0A00000F:B8D6 08080808:BB8E 01 00000000:00000000 00:00000000 00000000  1002        0 3 1 0000000000000000 20 4 30 10 -1
    ;
    try std.testing.expectEqual(@as(?u32, 1000), tableOwner(table, 0xBB8E, 0xB8D4));
    try std.testing.expectEqual(@as(?u32, 1001), tableOwner(table, 0xBB8E, 0xB8D5));
    // Not to loopback: not a client of the server.
    try std.testing.expectEqual(@as(?u32, null), tableOwner(table, 0xBB8E, 0xB8D6));
    try std.testing.expectEqual(@as(?u32, null), tableOwner(table, 0xBB8E, 0x1234));

    // From another local address, a listener, or an IPv6 address that only
    // ends like 127.0.0.1: none is a loopback client.
    const tricky =
        \\  sl  local_address rem_address   st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode
        \\   0: C0A80102:B8D7 0100007F:BB8E 01 00000000:00000000 00:00000000 00000000  1003        0 1 1 0000000000000000 20 4 30 10 -1
        \\   1: 0100007F:B8D8 0100007F:BB8E 0A 00000000:00000000 00:00000000 00000000  1004        0 2 1 0000000000000000 20 4 30 10 -1
        \\   2: 20010DB800000000000000000100007F:B8D9 20010DB800000000000000000100007F:BB8E 01 00000000:00000000 00:00000000 00000000  1005        0 3 1 0000000000000000 20 4 30 10 -1
        \\   3: 0000000000000000FFFF00000100007F:B8DA 0000000000000000FFFF00000100007F:BB8E 01 00000000:00000000 00:00000000 00000000  1006        0 4 1 0000000000000000 20 4 30 10 -1
    ;
    try std.testing.expectEqual(@as(?u32, null), tableOwner(tricky, 0xBB8E, 0xB8D7));
    try std.testing.expectEqual(@as(?u32, null), tableOwner(tricky, 0xBB8E, 0xB8D8));
    try std.testing.expectEqual(@as(?u32, null), tableOwner(tricky, 0xBB8E, 0xB8D9));
    try std.testing.expectEqual(@as(?u32, 1006), tableOwner(tricky, 0xBB8E, 0xB8DA));
}

test "a client claiming the server's own port is refused" {
    try std.testing.expect(!sameUser(std.testing.allocator, 0xBB8E, 0xBB8E));
}

// ---- macOS ----

/// Bounds on what one check reads: this user's processes, and the
/// descriptors of each.
const max_pids = 8192;
const max_fds = 4096;

const darwin = struct {
    // libproc (sys/proc_info.h).
    const PROC_UID_ONLY = 4;
    const PROC_PIDLISTFDS = 1;
    const PROC_PIDFDSOCKETINFO = 3;
    const PROX_FDTYPE_SOCKET = 2;
    const SOCKINFO_TCP = 2;
    /// struct proc_fdinfo: { int32 proc_fd; uint32 proc_fdtype; }.
    const FdInfo = extern struct { fd: i32, fdtype: u32 };
    /// struct socket_fdinfo, read by offset (the same on arm64 and x86_64,
    /// from Zig's macOS headers): its size, psi.soi_kind, and the TCP
    /// socket's psi.soi_proto.pri_tcp.tcpsi_ini (struct in_sockinfo):
    /// insi_fport / insi_lport (ints holding the port in network order),
    /// insi_vflag (INI_IPV4 1, INI_IPV6 2), and insi_faddr / insi_laddr
    /// (16 bytes each: an in6_addr, or an in4in6_addr whose IPv4 address
    /// is the last 4 bytes).
    const socket_fdinfo_size = 792;
    const kind_offset = 256;
    const fport_offset = 264;
    const lport_offset = 268;
    const vflag_offset = 288;
    const faddr_offset = 296;
    const laddr_offset = 312;
    const INI_IPV4 = 0x1;
    const INI_IPV6 = 0x2;

    extern "c" fn proc_listpids(kind: u32, typeinfo: u32, buffer: ?*anyopaque, buffersize: c_int) c_int;
    extern "c" fn proc_pidinfo(pid: c_int, flavor: c_int, arg: u64, buffer: ?*anyopaque, buffersize: c_int) c_int;
    extern "c" fn proc_pidfdinfo(pid: c_int, fd: c_int, flavor: c_int, buffer: ?*anyopaque, buffersize: c_int) c_int;
    extern "c" fn geteuid() u32;
};

fn darwinSameUser(gpa: std.mem.Allocator, server_port: u16, client_port: u16) bool {
    const pids = gpa.alloc(c_int, max_pids) catch return false;
    defer gpa.free(pids);
    const fds = gpa.alloc(darwin.FdInfo, max_fds) catch return false;
    defer gpa.free(fds);
    const got = darwin.proc_listpids(darwin.PROC_UID_ONLY, darwin.geteuid(), pids.ptr, @intCast(pids.len * @sizeOf(c_int)));
    if (got <= 0) return false;
    const pid_count = @min(pids.len, @as(usize, @intCast(got)) / @sizeOf(c_int));
    for (pids[0..pid_count]) |pid| {
        if (pid <= 0) continue;
        const bytes = darwin.proc_pidinfo(pid, darwin.PROC_PIDLISTFDS, 0, fds.ptr, @intCast(fds.len * @sizeOf(darwin.FdInfo)));
        if (bytes <= 0) continue;
        const fd_count = @min(fds.len, @as(usize, @intCast(bytes)) / @sizeOf(darwin.FdInfo));
        for (fds[0..fd_count]) |f| {
            if (f.fdtype != darwin.PROX_FDTYPE_SOCKET) continue;
            if (socketPorts(pid, f.fd)) |ports| {
                if (ports.local == client_port and ports.remote == server_port and ports.loopback) return true;
            }
        }
    }
    return false;
}

fn socketPorts(pid: c_int, fd: i32) ?struct { local: u16, remote: u16, loopback: bool } {
    var info: [darwin.socket_fdinfo_size]u8 align(8) = undefined;
    const n = darwin.proc_pidfdinfo(pid, fd, darwin.PROC_PIDFDSOCKETINFO, &info, info.len);
    if (n != info.len) return null;
    if (std.mem.readInt(i32, info[darwin.kind_offset..][0..4], .little) != darwin.SOCKINFO_TCP) return null;
    const vflag = info[darwin.vflag_offset];
    return .{
        .local = networkPort(std.mem.readInt(u32, info[darwin.lport_offset..][0..4], .little)),
        .remote = networkPort(std.mem.readInt(u32, info[darwin.fport_offset..][0..4], .little)),
        // Both ends 127.0.0.1: a socket of this user's between other
        // addresses that happens to use the same ports isn't the client.
        .loopback = isLoopbackIn(vflag, info[darwin.laddr_offset..][0..16]) and isLoopbackIn(vflag, info[darwin.faddr_offset..][0..16]),
    };
}

/// An in_sockinfo address is 127.0.0.1 (IPv4, or ::ffff:127.0.0.1).
fn isLoopbackIn(vflag: u8, addr: *const [16]u8) bool {
    const v4 = [4]u8{ 127, 0, 0, 1 };
    if (vflag & darwin.INI_IPV4 != 0) return std.mem.eql(u8, addr[12..16], &v4);
    if (vflag & darwin.INI_IPV6 != 0) {
        const mapped = [_]u8{0} ** 10 ++ [_]u8{ 0xff, 0xff } ++ v4;
        return std.mem.eql(u8, addr, &mapped);
    }
    return false;
}

test isLoopbackIn {
    var a: [16]u8 = @splat(0);
    a[12..16].* = .{ 127, 0, 0, 1 };
    try std.testing.expect(isLoopbackIn(darwin.INI_IPV4, &a));
    a[12] = 192;
    try std.testing.expect(!isLoopbackIn(darwin.INI_IPV4, &a));
    var m: [16]u8 = @splat(0);
    m[10..16].* = .{ 0xff, 0xff, 127, 0, 0, 1 };
    try std.testing.expect(isLoopbackIn(darwin.INI_IPV6, &m));
    try std.testing.expect(!isLoopbackIn(darwin.INI_IPV6, &a));
}

/// The kernel keeps the port as it is on the wire (big-endian) in the low
/// two bytes of the int.
fn networkPort(raw: u32) u16 {
    return std.mem.bigToNative(u16, @truncate(raw));
}
