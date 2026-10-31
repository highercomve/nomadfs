//! This device's own IPv4 addresses: the home LAN, Tailscale and other VPNs.
//! A device tells others all of them (PING/PONG), so a phone that learned
//! the desktop's LAN address at home can still reach it over Tailscale when
//! it's away. Linux and Android read them straight from the kernel
//! (SIOCGIFCONF, no libc needed), macOS from getifaddrs, Windows from
//! GetAdaptersAddresses; elsewhere the list is empty.

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
    return switch (builtin.os.tag) {
        .linux => listNetsLinux(out),
        .macos => listNetsDarwin(out),
        .windows => if (@sizeOf(usize) == 8) listNetsWindows(out) else 0,
        else => 0,
    };
}

/// Adds `addr`/`mask` unless it's loopback, link-local, unset or already there.
fn addNet(out: []Net, n: *usize, addr: [4]u8, mask: [4]u8) void {
    if (n.* == out.len) return;
    if (addr[0] == 127 or addr[0] == 0) return;
    if (addr[0] == 169 and addr[1] == 254) return;
    for (out[0..n.*]) |seen| if (std.mem.eql(u8, &seen.addr, &addr)) return;
    out[n.*] = .{ .addr = addr, .mask = mask };
    n.* += 1;
}

/// The netmask of a prefix length (`/24` → 255.255.255.0).
fn maskOf(prefix: u8) [4]u8 {
    const bits: u32 = if (prefix == 0) 0 else ~@as(u32, 0) << @intCast(32 - @min(prefix, 32));
    return @bitCast(std.mem.nativeToBig(u32, bits));
}

test maskOf {
    try std.testing.expectEqual([4]u8{ 255, 255, 255, 0 }, maskOf(24));
    try std.testing.expectEqual([4]u8{ 255, 192, 0, 0 }, maskOf(10));
    try std.testing.expectEqual([4]u8{ 255, 255, 255, 255 }, maskOf(32));
    try std.testing.expectEqual([4]u8{ 0, 0, 0, 0 }, maskOf(0));
}

// macOS: struct ifaddrs and BSD sockaddrs (a length byte, then the family).
const Darwin = struct {
    const Ifaddrs = extern struct {
        next: ?*Ifaddrs,
        name: [*:0]const u8,
        flags: c_uint,
        addr: ?*const SockaddrIn,
        netmask: ?*const SockaddrIn,
        dstaddr: ?*anyopaque,
        data: ?*anyopaque,
    };
    const SockaddrIn = extern struct { len: u8, family: u8, port: u16, addr: [4]u8, zero: [8]u8 };
    const af_inet = 2;
    const iff_up = 0x1;
    const iff_loopback = 0x8;
    extern "c" fn getifaddrs(out: *?*Ifaddrs) c_int;
    extern "c" fn freeifaddrs(list: *Ifaddrs) void;
};

/// macOS: Tailscale and other VPNs are `utunN`, which stay in the list.
fn listNetsDarwin(out: []Net) usize {
    var head: ?*Darwin.Ifaddrs = null;
    if (Darwin.getifaddrs(&head) != 0) return 0;
    const first = head orelse return 0;
    defer Darwin.freeifaddrs(first);
    var n: usize = 0;
    var it: ?*Darwin.Ifaddrs = first;
    while (it) |ifa| : (it = ifa.next) {
        if (ifa.flags & Darwin.iff_up == 0 or ifa.flags & Darwin.iff_loopback != 0) continue;
        const addr = ifa.addr orelse continue;
        if (addr.family != Darwin.af_inet) continue;
        if (skipped(std.mem.span(ifa.name))) continue;
        const mask = if (ifa.netmask) |m| m.addr else maskOf(32);
        addNet(out, &n, addr.addr, mask);
    }
    return n;
}

// Windows (64-bit): the leading fields of IP_ADAPTER_ADDRESSES_LH and
// IP_ADAPTER_UNICAST_ADDRESS_LH, as iphlpapi lays them out.
const Win = struct {
    const SockaddrIn = extern struct { family: u16, port: u16, addr: [4]u8, zero: [8]u8 };
    const Unicast = extern struct {
        length: u32,
        flags: u32,
        next: ?*Unicast,
        sockaddr: ?*const SockaddrIn,
        sockaddr_len: i32,
        prefix_origin: i32,
        suffix_origin: i32,
        dad_state: i32,
        valid_lifetime: u32,
        preferred_lifetime: u32,
        lease_lifetime: u32,
        on_link_prefix_length: u8,
    };
    const Adapter = extern struct {
        length: u32,
        if_index: u32,
        next: ?*Adapter,
        adapter_name: ?[*:0]const u8,
        first_unicast: ?*Unicast,
        first_anycast: ?*anyopaque,
        first_multicast: ?*anyopaque,
        first_dns: ?*anyopaque,
        dns_suffix: ?*anyopaque,
        description: ?*anyopaque,
        friendly_name: ?*anyopaque,
        physical_address: [8]u8,
        physical_address_length: u32,
        flags: u32,
        mtu: u32,
        if_type: u32,
        oper_status: i32,
    };
    const af_inet = 2;
    const skip_anycast_multicast_dns = 0x2 | 0x4 | 0x8;
    const if_type_loopback = 24;
    const oper_up = 1;
    const buffer_overflow = 111;
    extern "iphlpapi" fn GetAdaptersAddresses(family: u32, flags: u32, reserved: ?*anyopaque, addresses: ?*Adapter, size: *u32) callconv(.winapi) u32;
};

fn listNetsWindows(out: []Net) usize {
    // Usually ~15 KB; grow once if Windows asks for more.
    var stack: [32 * 1024]u8 align(8) = undefined;
    var size: u32 = stack.len;
    var buf: []align(8) u8 = &stack;
    var heap_buf: ?[]align(8) u8 = null;
    defer if (heap_buf) |h| std.heap.page_allocator.free(h);
    var rc = Win.GetAdaptersAddresses(Win.af_inet, Win.skip_anycast_multicast_dns, null, @ptrCast(buf.ptr), &size);
    if (rc == Win.buffer_overflow) {
        heap_buf = std.heap.page_allocator.alignedAlloc(u8, .@"8", size) catch return 0;
        buf = heap_buf.?;
        rc = Win.GetAdaptersAddresses(Win.af_inet, Win.skip_anycast_multicast_dns, null, @ptrCast(buf.ptr), &size);
    }
    if (rc != 0) return 0;
    var n: usize = 0;
    var adapter: ?*Win.Adapter = @ptrCast(buf.ptr);
    while (adapter) |a| : (adapter = a.next) {
        if (a.if_type == Win.if_type_loopback or a.oper_status != Win.oper_up) continue;
        var uni = a.first_unicast;
        while (uni) |u| : (uni = u.next) {
            const sa = u.sockaddr orelse continue;
            if (sa.family != Win.af_inet) continue;
            addNet(out, &n, sa.addr, maskOf(u.on_link_prefix_length));
        }
    }
    return n;
}

fn listNetsLinux(out: []Net) usize {
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
        var mask_req = req;
        if (linux.errno(linux.ioctl(fd, 0x891b, @intFromPtr(&mask_req))) != .SUCCESS) continue;
        addNet(out, &n, bytes, @bitCast(mask_req.addr.addr));
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
/// interface, not only mobile data or the phone's own hotspot; elsewhere
/// always. Backups use it to
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
        // The phone's own hotspot (sharing mobile data) is a wlan too, and
        // its address is the gateway's, x.x.x.1: a Wi-Fi client never is.
        const octets: [4]u8 = @bitCast(req.addr.addr);
        if (octets[3] == 1) continue;
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
