const compat = @import("../compat.zig");
const Address = compat.Address;
const std = @import("std");
const builtin = @import("builtin");
const network = @import("mod.zig");
const id = @import("../id.zig");
const sync = @import("../../sync.zig");

pub const MDNS_MULTICAST_ADDR = "224.0.0.251";
pub const MDNS_PORT = 5354;
pub const MAGIC_PREFIX = "NMFS";

pub const Announcement = struct {
    peer_id: id.NodeID,
    tcp_port: u16,
};

pub const ip_mreq = extern struct {
    imr_multiaddr: u32,
    imr_interface: u32,
};

const posix = std.posix;
const system = posix.system;

fn createSocket(domain: u32, sock_type: u32, protocol: u32) !posix.socket_t {
    const rc = system.socket(domain, sock_type, protocol);
    return switch (posix.errno(rc)) {
        .SUCCESS => @intCast(rc),
        else => |err| posix.unexpectedErrno(err),
    };
}

fn closeSocket(s: posix.socket_t) void {
    _ = system.close(@intCast(s));
}

fn shutdownSocket(s: posix.socket_t, how: i32) void {
    _ = system.shutdown(@intCast(s), how);
}

fn bindSocket(s: posix.socket_t, addr: *const posix.sockaddr, len: posix.socklen_t) !void {
    const rc = system.bind(@intCast(s), addr, len);
    return switch (posix.errno(rc)) {
        .SUCCESS => {},
        else => |err| posix.unexpectedErrno(err),
    };
}

fn sendtoSocket(s: posix.socket_t, buf: []const u8, flags: u32, addr: ?*const posix.sockaddr, alen: posix.socklen_t) !usize {
    const rc = system.sendto(@intCast(s), buf.ptr, buf.len, flags, addr, alen);
    return switch (posix.errno(rc)) {
        .SUCCESS => rc,
        else => |err| posix.unexpectedErrno(err),
    };
}

fn recvfromSocket(s: posix.socket_t, buf: []u8, flags: u32, addr: ?*posix.sockaddr, alen: ?*posix.socklen_t) !usize {
    const rc = system.recvfrom(@intCast(s), buf.ptr, buf.len, flags, addr, alen);
    return switch (posix.errno(rc)) {
        .SUCCESS => rc,
        .AGAIN => error.WouldBlock,
        else => |err| posix.unexpectedErrno(err),
    };
}

pub const MDNS = struct {
    allocator: std.mem.Allocator,
    thread: ?std.Thread = null,
    running: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    send_socket: ?posix.socket_t = null,
    recv_socket: ?posix.socket_t = null,
    local_peer_id: id.NodeID,
    local_tcp_port: u16,
    mdns_port: u16,
    found_peers_callback: *const fn (ctx: ?*anyopaque, peer_id: id.NodeID, addr: Address) void,
    callback_ctx: ?*anyopaque,

    pub fn init(allocator: std.mem.Allocator, peer_id: id.NodeID, tcp_port: u16, mdns_port: u16, callback: *const fn (?*anyopaque, id.NodeID, Address) void, ctx: ?*anyopaque) MDNS {
        return .{
            .allocator = allocator,
            .local_peer_id = peer_id,
            .local_tcp_port = tcp_port,
            .mdns_port = mdns_port,
            .found_peers_callback = callback,
            .callback_ctx = ctx,
        };
    }

    pub fn deinit(self: *MDNS) void {
        self.stop();
    }

    pub fn start(self: *MDNS) !void {
        if (self.running.load(.acquire)) return;

        self.running.store(true, .release);
        self.thread = try std.Thread.spawn(.{}, runLoop, .{self});
    }

    pub fn stop(self: *MDNS) void {
        self.running.store(false, .release);
        if (self.send_socket) |s| {
            shutdownSocket(s, posix.SHUT.RDWR);
            closeSocket(s);
            self.send_socket = null;
        }
        if (self.recv_socket) |s| {
            shutdownSocket(s, posix.SHUT.RDWR);
            closeSocket(s);
            self.recv_socket = null;
        }
        if (self.thread) |t| {
            t.join();
            self.thread = null;
        }
    }

    fn runLoop(self: *MDNS) void {
        const recv_socket = createSocket(posix.AF.INET, posix.SOCK.DGRAM, 0) catch |err| {
            std.debug.print("mDNS: Failed to create recv socket: {any}\n", .{err});
            return;
        };
        self.recv_socket = recv_socket;

        const send_socket = createSocket(posix.AF.INET, posix.SOCK.DGRAM, 0) catch |err| {
            std.debug.print("mDNS: Failed to create send socket: {any}\n", .{err});
            return;
        };
        self.send_socket = send_socket;

        // --- Configure Recv Socket ---
        const enable: i32 = 1;
        posix.setsockopt(recv_socket, posix.SOL.SOCKET, posix.SO.REUSEADDR, std.mem.asBytes(&enable)) catch {};
        if (builtin.os.tag != .windows) {
            posix.setsockopt(recv_socket, posix.SOL.SOCKET, posix.SO.REUSEPORT, std.mem.asBytes(&enable)) catch {};
        }

        const addr = Address.parseIp("0.0.0.0", self.mdns_port) catch unreachable;
        const sa = addr.toPosix();
        bindSocket(recv_socket, @ptrCast(&sa), @sizeOf(@TypeOf(sa))) catch |err| {
            std.debug.print("mDNS: Failed to bind recv socket: {any}\n", .{err});
            return;
        };

        const mcast_sa = (Address.parseIp(MDNS_MULTICAST_ADDR, 0) catch unreachable).toPosix();
        const mreq = ip_mreq{
            .imr_multiaddr = mcast_sa.addr,
            .imr_interface = 0,
        };
        const add_membership = if (@hasDecl(posix, "IP_ADD_MEMBERSHIP")) posix.IP_ADD_MEMBERSHIP else 35;
        posix.setsockopt(recv_socket, posix.IPPROTO.IP, add_membership, std.mem.asBytes(&mreq)) catch |err| {
            std.debug.print("mDNS: Failed to join multicast group: {any}\n", .{err});
        };

        // --- Configure Send Socket ---
        const multicast_loop = if (@hasDecl(posix, "IP_MULTICAST_LOOP")) posix.IP_MULTICAST_LOOP else 34;
        posix.setsockopt(send_socket, posix.IPPROTO.IP, multicast_loop, std.mem.asBytes(&enable)) catch {};

        // Set timeout for recv
        const timeout = posix.timeval{ .sec = 1, .usec = 0 };
        posix.setsockopt(recv_socket, posix.SOL.SOCKET, posix.SO.RCVTIMEO, std.mem.asBytes(&timeout)) catch {};

        var last_announce: i64 = 0;
        const announce_interval = 2; // seconds
        var buf: [1024]u8 = undefined;

        while (self.running.load(.acquire)) {
            const now = sync.timestamp();
            if (now - last_announce >= announce_interval) {
                self.broadcastAnnouncement(send_socket) catch |err| {
                    std.debug.print("mDNS: Failed to broadcast: {any}\n", .{err});
                };
                last_announce = now;
            }

            var src_sa: posix.sockaddr.in = undefined;
            var len: posix.socklen_t = @sizeOf(posix.sockaddr.in);

            const bytes_read = recvfromSocket(recv_socket, &buf, 0, @ptrCast(&src_sa), &len) catch |err| {
                if (err == error.WouldBlock) continue;
                std.debug.print("mDNS: recv error: {any}\n", .{err});
                continue;
            };

            if (bytes_read > 0) {
                const src_addr = Address.fromPosix(src_sa);
                self.handlePacket(buf[0..bytes_read], src_addr) catch |err| {
                    if (err != error.InvalidFormat) {
                        std.debug.print("mDNS: Packet handling error: {any}\n", .{err});
                    }
                };
            }
        }
    }

    fn broadcastAnnouncement(self: *MDNS, socket: posix.socket_t) !void {
        // Simple JSON-like format with magic prefix: NMFS{"id":"hex...", "port":1234}
        var msg_buf: [256]u8 = undefined;
        const msg = try std.fmt.bufPrint(&msg_buf, "{s}{{\"id\":\"{x}\",\"port\":{d}}}", .{ MAGIC_PREFIX, self.local_peer_id.bytes, self.local_tcp_port });

        const dest = (try Address.parseIp(MDNS_MULTICAST_ADDR, self.mdns_port)).toPosix();
        _ = try sendtoSocket(socket, msg, 0, @ptrCast(&dest), @sizeOf(@TypeOf(dest)));
    }

    fn handlePacket(self: *MDNS, data: []const u8, src: Address) !void {
        // 0. Check for Magic Prefix
        if (!std.mem.startsWith(u8, data, MAGIC_PREFIX)) {
            // Silently ignore non-NomadFS traffic (very common on port 5353)
            return;
        }
        const payload = data[MAGIC_PREFIX.len..];

        // 1. Extract ID
        const id_key = "\"id\":\"";
        const id_start = std.mem.indexOf(u8, payload, id_key);
        if (id_start == null) return error.InvalidFormat;
        const id_val_start = id_start.? + id_key.len;
        const id_end = std.mem.indexOf(u8, payload[id_val_start..], "\"");
        if (id_end == null) return error.InvalidFormat;
        const id_hex = payload[id_val_start .. id_val_start + id_end.?];

        // 2. Extract Port
        const port_key = "\"port\":";
        const port_start = std.mem.indexOf(u8, payload, port_key);
        if (port_start == null) return error.InvalidFormat;
        const port_val_start = port_start.? + port_key.len;
        const port_end = std.mem.indexOfAny(u8, payload[port_val_start..], ",}");
        if (port_end == null) return error.InvalidFormat;
        const port_str = payload[port_val_start .. port_val_start + port_end.?];

        const port = try std.fmt.parseInt(u16, port_str, 10);

        var peer_id_bytes: [32]u8 = undefined;
        _ = try std.fmt.hexToBytes(&peer_id_bytes, id_hex);
        const peer_id = id.NodeID{ .bytes = peer_id_bytes };

        // Don't discover self
        if (peer_id.eql(self.local_peer_id)) return;

        // Construct the full address (TCP) using the Source IP + Announced Port
        var tcp_addr = src;
        tcp_addr.setPort(port);

        self.found_peers_callback(self.callback_ctx, peer_id, tcp_addr);
    }
};
