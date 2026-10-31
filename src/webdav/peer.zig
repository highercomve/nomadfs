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

/// The uid owning the socket whose local port is `client_port` and whose
/// remote end is loopback port `server_port`, in a /proc/net/tcp table.
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
        const uid_text = fields[7];
        if (portOf(local) != client_port or portOf(remote) != server_port) continue;
        // The address before the colon: 127.0.0.1 in host order (and as
        // ::ffff:127.0.0.1 in tcp6).
        const colon = std.mem.indexOfScalar(u8, remote, ':') orelse continue;
        if (!std.mem.endsWith(u8, remote[0..colon], "0100007F")) continue;
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
    /// socket's psi.soi_proto.pri_tcp.tcpsi_ini.insi_fport / insi_lport
    /// (ints holding the port in network order).
    const socket_fdinfo_size = 792;
    const kind_offset = 256;
    const fport_offset = 264;
    const lport_offset = 268;

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
                if (ports.local == client_port and ports.remote == server_port) return true;
            }
        }
    }
    return false;
}

fn socketPorts(pid: c_int, fd: i32) ?struct { local: u16, remote: u16 } {
    var info: [darwin.socket_fdinfo_size]u8 align(8) = undefined;
    const n = darwin.proc_pidfdinfo(pid, fd, darwin.PROC_PIDFDSOCKETINFO, &info, info.len);
    if (n != info.len) return null;
    if (std.mem.readInt(i32, info[darwin.kind_offset..][0..4], .little) != darwin.SOCKINFO_TCP) return null;
    return .{
        .local = networkPort(std.mem.readInt(u32, info[darwin.lport_offset..][0..4], .little)),
        .remote = networkPort(std.mem.readInt(u32, info[darwin.fport_offset..][0..4], .little)),
    };
}

/// The kernel keeps the port as it is on the wire (big-endian) in the low
/// two bytes of the int.
fn networkPort(raw: u32) u16 {
    return std.mem.bigToNative(u16, @truncate(raw));
}
