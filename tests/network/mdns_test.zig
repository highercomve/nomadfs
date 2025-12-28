const std = @import("std");
const network = @import("nomadfs").network;
const id = @import("nomadfs").dht.id;

fn onDiscovery(ctx: ?*anyopaque, peer_id: id.NodeID, addr: std.net.Address) void {
    const discovered_ptr: *bool = @ptrCast(@alignCast(ctx.?));
    discovered_ptr.* = true;
    _ = peer_id;
    _ = addr;
}

test "network: mDNS local discovery" {
    const allocator = std.testing.allocator;

    const peer1_id = id.NodeID.generate();
    const peer2_id = id.NodeID.generate();

    var discovered1: bool = false;
    var discovered2: bool = false;

    var mdns1 = network.mdns.MDNS.init(allocator, peer1_id, 9001, onDiscovery, &discovered1);
    defer mdns1.deinit();

    var mdns2 = network.mdns.MDNS.init(allocator, peer2_id, 9002, onDiscovery, &discovered2);
    defer mdns2.deinit();

    try mdns1.start();
    try mdns2.start();

    var i: usize = 0;
    while (i < 50) : (i += 1) { // Wait up to 5s
        if (discovered1 and discovered2) break;
        std.Thread.sleep(100 * std.time.ns_per_ms);
    }

    try std.testing.expect(discovered1);
    try std.testing.expect(discovered2);
}