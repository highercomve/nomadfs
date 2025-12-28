const std = @import("std");
const network = @import("mod.zig");
const id = @import("../dht/id.zig");

pub const MDNS_MULTICAST_ADDR = "239.255.255.250";
pub const MDNS_PORT = 5353; // Standard mDNS port, though NomadFS might use a custom one if needed. 
// Using 5353 might conflict with system mDNS (Avahi/Bonjour) if we don't bind carefully or use a different port.
// The plan mentioned "239.255.255.250:5353 (or custom port)".
// Let's use a custom port for NomadFS discovery to avoid parsing standard DNS packets for now, 
// and keep the protocol simple (JSON/Binary).
// Let's stick to the plan's IP but maybe port 9001 (default nomad) + 1? Or just a fixed discovery port like 9090.
// Let's use 5353 for now but with a specific protocol identifier payload.

pub const Announcement = struct {
    peer_id: id.NodeID,
    tcp_port: u16,
};

pub const ip_mreq = extern struct {
    imr_multiaddr: u32,
    imr_interface: u32,
};

pub const MDNS = struct {
    allocator: std.mem.Allocator,
    thread: ?std.Thread = null,
    running: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    socket: ?std.posix.socket_t = null,
    local_peer_id: id.NodeID,
    local_tcp_port: u16,
    found_peers_callback: *const fn (ctx: ?*anyopaque, peer_id: id.NodeID, addr: std.net.Address) void,
    callback_ctx: ?*anyopaque,

    pub fn init(
        allocator: std.mem.Allocator, 
        peer_id: id.NodeID, 
        tcp_port: u16,
        callback: *const fn (?*anyopaque, id.NodeID, std.net.Address) void,
        ctx: ?*anyopaque
    ) MDNS {
        return .{
            .allocator = allocator,
            .local_peer_id = peer_id,
            .local_tcp_port = tcp_port,
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
        if (self.socket) |s| {
            std.posix.shutdown(s, .both) catch {};
            std.posix.close(s);
            self.socket = null;
        }
        if (self.thread) |t| {
            t.join();
            self.thread = null;
        }
    }

    fn runLoop(self: *MDNS) void {
        const socket = std.posix.socket(std.posix.AF.INET, std.posix.SOCK.DGRAM, 0) catch |err| {
            std.debug.print("mDNS: Failed to create socket: {any}\n", .{err});
            return;
        };
        self.socket = socket;

        // Allow reusing the address so multiple nodes can run on the same machine (dev/testing)
        const enable: i32 = 1;
        std.posix.setsockopt(socket, std.posix.SOL.SOCKET, std.posix.SO.REUSEADDR, std.mem.asBytes(&enable)) catch {};
        
        // Bind to wildcard
        const addr = std.net.Address.parseIp("0.0.0.0", MDNS_PORT) catch unreachable;
        std.posix.bind(socket, &addr.any, addr.getOsSockLen()) catch |err| {
            std.debug.print("mDNS: Failed to bind socket: {any}\n", .{err});
            return;
        };

        // Join Multicast Group
        const mreq = ip_mreq{
            .imr_multiaddr = (std.net.Address.parseIp(MDNS_MULTICAST_ADDR, 0) catch unreachable).in.sa.addr,
            .imr_interface = (std.net.Address.parseIp("0.0.0.0", 0) catch unreachable).in.sa.addr,
        };
        // 35 is IP_ADD_MEMBERSHIP on Linux
        std.posix.setsockopt(socket, std.posix.IPPROTO.IP, 35, std.mem.asBytes(&mreq)) catch |err| {
            std.debug.print("mDNS: Failed to join multicast group: {any}\n", .{err});
            // Continue anyway, maybe we can still broadcast?
        };

        // Set timeout for recv
        const timeout = std.posix.timeval{ .sec = 1, .usec = 0 };
        std.posix.setsockopt(socket, std.posix.SOL.SOCKET, std.posix.SO.RCVTIMEO, std.mem.asBytes(&timeout)) catch {};

        var last_announce: i64 = 0;
        const announce_interval = 30; // seconds

        var buf: [1024]u8 = undefined;

        while (self.running.load(.acquire)) {
            const now = std.time.timestamp();
            if (now - last_announce >= announce_interval) {
                self.broadcastAnnouncement(socket) catch |err| {
                    std.debug.print("mDNS: Failed to broadcast: {any}\n", .{err});
                };
                last_announce = now;
            }

            var src_addr: std.net.Address = undefined;
            var len: std.posix.socklen_t = @sizeOf(std.net.Address);
            
            const bytes_read = std.posix.recvfrom(socket, &buf, 0, &src_addr.any, &len) catch |err| {
                if (err == error.WouldBlock or err == error.Again) continue;
                std.debug.print("mDNS: recv error: {any}\n", .{err});
                continue;
            };

            if (bytes_read > 0) {
                self.handlePacket(buf[0..bytes_read], src_addr) catch |err| {
                    std.debug.print("mDNS: Invalid packet: {any}\n", .{err});
                };
            }
        }
    }

    fn broadcastAnnouncement(self: *MDNS, socket: std.posix.socket_t) !void {
        // Simple JSON-like format: {"id":"hex...", "port":1234}
        var msg_buf: [256]u8 = undefined;
        const msg = try std.fmt.bufPrint(&msg_buf, "{{\"id\":\"{x}\",\"port\":{d}}}", .{self.local_peer_id.bytes, self.local_tcp_port});
        
        const dest = try std.net.Address.parseIp(MDNS_MULTICAST_ADDR, MDNS_PORT);
        _ = try std.posix.sendto(socket, msg, 0, &dest.any, dest.getOsSockLen());
    }

    fn handlePacket(self: *MDNS, data: []const u8, src: std.net.Address) !void {
        // Very manual parsing to avoid dependency on JSON parser for now (or use std.json)
        // Expected: {"id":"...", "port":...}
        
        // 1. Extract ID
        const id_key = "\"id\":\"";
        const id_start = std.mem.indexOf(u8, data, id_key);
        if (id_start == null) return error.InvalidFormat;
        const id_val_start = id_start.? + id_key.len;
        const id_end = std.mem.indexOf(u8, data[id_val_start..], "\"");
        if (id_end == null) return error.InvalidFormat;
        const id_hex = data[id_val_start .. id_val_start + id_end.?];
        
        // 2. Extract Port
        const port_key = "\"port\":";
        const port_start = std.mem.indexOf(u8, data, port_key);
        if (port_start == null) return error.InvalidFormat;
        const port_val_start = port_start.? + port_key.len;
        const port_end = std.mem.indexOfAny(u8, data[port_val_start..], ",}");
        if (port_end == null) return error.InvalidFormat;
        const port_str = data[port_val_start .. port_val_start + port_end.?];
        
        const port = try std.fmt.parseInt(u16, port_str, 10);
        
        var peer_id_bytes: [32]u8 = undefined;
        _ = try std.fmt.hexToBytes(&peer_id_bytes, id_hex);
        const peer_id = id.NodeID{ .bytes = peer_id_bytes };

        // Don't discover self
        if (peer_id.eql(self.local_peer_id)) return;

        // Construct the full address (TCP) using the Source IP + Announced Port
        var tcp_addr = src;
        switch (tcp_addr.any.family) {
            std.posix.AF.INET => tcp_addr.in.sa.port = std.mem.nativeToBig(u16, port),
            std.posix.AF.INET6 => tcp_addr.in6.sa.port = std.mem.nativeToBig(u16, port),
            else => return,
        }

        self.found_peers_callback(self.callback_ctx, peer_id, tcp_addr);
    }
};
