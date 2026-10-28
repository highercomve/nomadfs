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
pub fn list(out: []Address, port: u16) usize {
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
        const addr = Address.initIp4(bytes, port);
        var dup = false;
        for (out[0..n]) |seen| dup = dup or seen.eql(addr);
        if (dup) continue;
        out[n] = addr;
        n += 1;
    }
    return n;
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
