const std = @import("std");
const nomadfs = @import("nomadfs");
const TestPeer = @import("test_helpers").TestPeer;

test "network: tcp loopback" {
    const allocator = std.testing.allocator;

    // 1. Create two peers
    var peer1 = try TestPeer.init(allocator, 9001);
    defer peer1.deinit();

    var peer2 = try TestPeer.init(allocator, 9002);
    defer peer2.deinit();

    // 2. Start peer1 listener
    try peer1.start();
    
    // Give it a moment to bind
    std.Thread.sleep(100 * std.time.ns_per_ms);

    // 3. Peer2 connects to Peer1
    const conn = try peer2.manager.connectToPeer(peer1.listen_addr, peer2.config.node.swarm_key);
    const stream = try conn.openStream();
    defer stream.close();

    std.debug.print("Successfully opened stream between peers\n", .{});
}
