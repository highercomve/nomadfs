//! This device's own IPv4 addresses: the home LAN, Tailscale and other VPNs.
//! A device tells others all of them (PING/PONG), so a phone that learned
//! the desktop's LAN address at home can still reach it over Tailscale when
//! it's away. Read straight from the kernel (SIOCGIFCONF), no libc needed;
//! Linux and Android only, elsewhere the list is empty.

const std = @import("std");
const builtin = @import("builtin");
const Address = @import("compat.zig").Address;

/// Interfaces that never reach another of the user's devices: loopback,
/// container and VM bridges.
const skipped_prefixes = [_][]const u8{ "lo", "docker", "br-", "veth", "virbr", "cni", "flannel", "podman", "kube", "lxc", "vmnet" };

/// Fills `out` with this device's addresses, each with `port`; returns how
/// many. Loopback and link-local addresses are left out.
pub const Net = struct {
    addr: [4]u8,
    mask: [4]u8,

    pub fn contains(self: Net, ip: [4]u8) bool {
        for (ip, self.addr, self.mask) |a, b, mask| {
            if (a & mask != b & mask) return false;
        }
        return true;
    }
};

pub fn list(out: []Address, port: u16) usize {
    var nets: [32]Net = undefined;
    const n = @min(out.len, listNets(&nets));
    for (out[0..n], nets[0..n]) |*addr, net| addr.* = Address.initIp4(net.addr, port);
    return n;
}

/// IPv4 interface addresses and their actual kernel netmasks. Empty when unavailable.
pub fn listNets(out: []Net) usize {
    if (builtin.os.tag != .linux) return 0;
    const linux = std.os.linux;

    const fd_rc = linux.socket(linux.AF.INET, linux.SOCK.DGRAM | linux.SOCK.CLOEXEC, 0);
    if (linux.errno(fd_rc) != .SUCCESS) return 0;
    const fd: i32 = @intCast(fd_rc);
    defer _ = linux.close(fd);

    // struct ifreq: the name, then a union whose largest member is 24 bytes
    // on 64-bit targets (16 on 32-bit); the address is at its start.
    const Ifreq = extern struct {
        name: [16]u8,
        addr: linux.sockaddr.in,
        pad: [if (@sizeOf(usize) == 8) 8 else 0]u8,
    };
    const Ifconf = extern struct { len: c_int, buf: [*]Ifreq };
    var reqs: [32]Ifreq = undefined;
    var conf = Ifconf{ .len = @sizeOf(@TypeOf(reqs)), .buf = &reqs };
    const SIOCGIFCONF = 0x8912;
    if (linux.errno(linux.ioctl(fd, SIOCGIFCONF, @intFromPtr(&conf))) != .SUCCESS) return 0;

    const count = @min(@as(usize, @intCast(@max(conf.len, 0))) / @sizeOf(Ifreq), reqs.len);
    var n: usize = 0;
    for (reqs[0..count]) |req| {
        if (n == out.len) break;
        if (req.addr.family != linux.AF.INET) continue;
        const name = std.mem.sliceTo(&req.name, 0);
        if (skipped(name)) continue;
        const bytes: [4]u8 = @bitCast(req.addr.addr);
        if (bytes[0] == 127 or bytes[0] == 0) continue;
        if (bytes[0] == 169 and bytes[1] == 254) continue;
        var mask_req = req;
        if (linux.errno(linux.ioctl(fd, 0x891b, @intFromPtr(&mask_req))) != .SUCCESS) continue;
        const mask: [4]u8 = @bitCast(mask_req.addr.addr);
        var dup = false;
        for (out[0..n]) |seen| dup = dup or std.mem.eql(u8, &seen.addr, &bytes);
        if (dup) continue;
        out[n] = .{ .addr = bytes, .mask = mask };
        n += 1;
    }
    return n;
}

/// Private IPv6 has no interface enumeration here; preserve the portable fallback.
pub fn onLink(addr: Address) bool {
    var nets: [32]Net = undefined;
    const n = listNets(&nets);
    if (n == 0) return true;
    return switch (addr.ip) {
        .ip4 => |ip| onLinkNets(ip.bytes, nets[0..n]),
        .ip6 => false,
    };
}

pub fn onLinkNets(ip: [4]u8, nets: []const Net) bool {
    for (nets) |net| if (net.contains(ip)) return true;
    return false;
}

pub fn haveCgnat() bool {
    var nets: [32]Net = undefined;
    for (nets[0..listNets(&nets)]) |net| {
        if (isCgnat(Address.initIp4(net.addr, 1))) return true;
    }
    return false;
}

/// Whether this device is on a network where large transfers are fine: on
/// Android, an IPv4 address on a Wi-Fi (`wlan*`) or wired (`eth*`)
/// interface, not only mobile data; elsewhere always. Backups use it to
/// wait for Wi-Fi.
pub fn onUnmeteredNetwork() bool {
    if (builtin.os.tag != .linux or !builtin.abi.isAndroid()) return true;
    const linux = std.os.linux;
    const fd_rc = linux.socket(linux.AF.INET, linux.SOCK.DGRAM | linux.SOCK.CLOEXEC, 0);
    if (linux.errno(fd_rc) != .SUCCESS) return false;
    const fd: i32 = @intCast(fd_rc);
    defer _ = linux.close(fd);
    const Ifreq = extern struct {
        name: [16]u8,
        addr: linux.sockaddr.in,
        pad: [if (@sizeOf(usize) == 8) 8 else 0]u8,
    };
    const Ifconf = extern struct { len: c_int, buf: [*]Ifreq };
    var reqs: [32]Ifreq = undefined;
    var conf = Ifconf{ .len = @sizeOf(@TypeOf(reqs)), .buf = &reqs };
    if (linux.errno(linux.ioctl(fd, 0x8912, @intFromPtr(&conf))) != .SUCCESS) return false;
    const count = @min(@as(usize, @intCast(@max(conf.len, 0))) / @sizeOf(Ifreq), reqs.len);
    for (reqs[0..count]) |req| {
        if (req.addr.family != linux.AF.INET) continue;
        const name = std.mem.sliceTo(&req.name, 0);
        if (std.mem.startsWith(u8, name, "wlan") or std.mem.startsWith(u8, name, "eth")) return true;
    }
    return false;
}

fn skipped(name: []const u8) bool {
    for (skipped_prefixes) |p| if (std.mem.startsWith(u8, name, p)) return true;
    return false;
}

/// Tailscale and other carrier-grade NAT ranges (100.64.0.0/10): reachable
/// from anywhere the VPN is up, so worth trying after the LAN.
pub fn isCgnat(addr: Address) bool {
    return switch (addr.ip) {
        .ip4 => |ip4| ip4.bytes[0] == 100 and ip4.bytes[1] & 0xC0 == 64,
        .ip6 => false,
    };
}

test "local addresses: lists this machine's, never loopback" {
    var out: [8]Address = undefined;
    const n = list(&out, 9000);
    for (out[0..n]) |a| {
        try std.testing.expect(!a.isLoopback());
        try std.testing.expectEqual(@as(u16, 9000), a.getPort());
    }
}

test "local addresses: Tailscale's range is CGNAT" {
    try std.testing.expect(isCgnat(Address.initIp4(.{ 100, 114, 119, 39 }, 1)));
    try std.testing.expect(!isCgnat(Address.initIp4(.{ 100, 128, 0, 1 }, 1)));
    try std.testing.expect(!isCgnat(Address.initIp4(.{ 192, 168, 68, 128 }, 1)));
}

pub const Scope = enum { invalid, loopback, private, cgnat, public };

/// Scope validation shared by discovery and subnet-aware callers.
pub fn classify(addr: Address) Scope {
    if (addr.getPort() == 0) return .invalid;
    switch (addr.ip) {
        .ip4 => |ip| {
            const b = ip.bytes;
            if (b[0] == 0 or b[0] >= 224 or (b[0] == 169 and b[1] == 254)) return .invalid;
            if (b[0] == 127) return .loopback;
            if (b[0] == 10 or (b[0] == 172 and b[1] & 0xf0 == 16) or
                (b[0] == 192 and b[1] == 168)) return .private;
            if (isCgnat(addr)) return .cgnat;
        },
        .ip6 => |ip| {
            const b = ip.bytes;
            if (std.mem.allEqual(u8, b[0..10], 0) and b[10] == 255 and b[11] == 255)
                return classify(Address.initIp4(b[12..16].*, addr.getPort()));
            if (std.mem.allEqual(u8, &b, 0) or b[0] == 255 or
                (b[0] == 0xfe and b[1] & 0xc0 == 0x80)) return .invalid;
            if (addr.isLoopback()) return .loopback;
            if (b[0] & 0xfe == 0xfc) return .private;
        },
    }
    return .public;
}

pub fn addressPriority(addr: Address) u8 {
    return switch (classify(addr)) {
        .invalid => 255,
        .loopback => 0,
        .private => 1,
        .cgnat => 2,
        .public => 3,
    };
}

test "address classification includes mapped IPv4 and IPv6 scopes" {
    const Case = struct { ip: []const u8, port: u16 = 9, scope: Scope };
    const cases = [_]Case{
        .{ .ip = "0.0.0.0", .scope = .invalid },
        .{ .ip = "10.0.0.1", .port = 0, .scope = .invalid },
        .{ .ip = "224.0.0.251", .scope = .invalid },
        .{ .ip = "255.255.255.255", .scope = .invalid },
        .{ .ip = "169.254.1.1", .scope = .invalid },
        .{ .ip = "240.0.0.1", .scope = .invalid },
        .{ .ip = "127.0.0.1", .scope = .loopback },
        .{ .ip = "10.1.2.3", .scope = .private },
        .{ .ip = "172.16.0.1", .scope = .private },
        .{ .ip = "192.168.1.1", .scope = .private },
        .{ .ip = "100.64.0.1", .scope = .cgnat },
        .{ .ip = "100.128.0.1", .scope = .public },
        .{ .ip = "8.8.8.8", .scope = .public },
        .{ .ip = "::", .scope = .invalid },
        .{ .ip = "::1", .scope = .loopback },
        .{ .ip = "ff02::1", .scope = .invalid },
        .{ .ip = "fe80::1", .scope = .invalid },
        .{ .ip = "::ffff:127.0.0.1", .scope = .loopback },
        .{ .ip = "::ffff:10.0.0.1", .scope = .private },
        .{ .ip = "fd00::1", .scope = .private },
        .{ .ip = "2001:db8::1", .scope = .public },
    };
    for (cases) |case| try std.testing.expectEqual(case.scope, classify(try Address.parseIp(case.ip, case.port)));
}

test "subnets use interface netmasks rather than private address class" {
    const nets = [_]Net{.{ .addr = .{ 192, 168, 4, 25 }, .mask = .{ 255, 255, 255, 0 } }};
    try std.testing.expect(onLinkNets(.{ 192, 168, 4, 1 }, &nets));
    try std.testing.expect(!onLinkNets(.{ 192, 168, 5, 1 }, &nets));
}
