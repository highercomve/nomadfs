pub const compat = @import("../compat.zig");
pub const Address = compat.Address;
pub const Server = compat.Server;
pub const TcpStream = compat.Stream;

pub const tcp = @import("tcp.zig");
pub const noise = @import("noise.zig");
pub const manager = @import("manager.zig");
pub const yamux = @import("yamux.zig");
pub const mdns = @import("mdns.zig");
pub const relay = @import("relay.zig");
pub const interface = @import("interface.zig");

pub const Stream = interface.Stream;
pub const Connection = interface.Connection;

pub fn isLoopback(addr: Address) bool {
    return addr.isLoopback();
}

pub fn isPrivate(addr: Address) bool {
    return addr.isPrivate();
}

/// Dial order, lowest first: loopback, the LAN, Tailscale and other CGNAT
/// VPN ranges (they work away from home), then public addresses. Addresses
/// that can't be dialed (port 0, multicast, link-local...) sort last.
pub fn addressPriority(addr: Address) u8 {
    return @import("../local_addrs.zig").addressPriority(addr);
}
