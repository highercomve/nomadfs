const std = @import("std");
const nomadfs = @import("nomadfs");
const TestPeer = @import("test_helpers").TestPeer;
const rpc = nomadfs.net.discovery.rpc;
const Node = nomadfs.net.discovery.Node;

test "dht: spoofed PING sender is rejected without crashing" {
    std.debug.print("\n=== Running Test: dht: spoofed PING sender is rejected ===\n", .{});
    const allocator = std.testing.allocator;

    var peer1 = try TestPeer.init(allocator, 13000);
    defer peer1.deinit();
    var peer2 = try TestPeer.init(allocator, 13001);
    defer peer2.deinit();

    var dht1 = Node.init(allocator, peer1.manager, peer1.config.node.swarm_key);
    defer dht1.deinit();
    peer1.manager.setConnectionHandler(&dht1, Node.serve);
    defer peer1.stop();

    try peer1.start();
    nomadfs.sync.sleep(100 * std.time.ns_per_ms);

    const conn = try peer2.manager.connectToPeer(peer1.listen_addr, peer2.config.node.swarm_key, peer1.manager.node_id);
    defer conn.deinit();

    // Claim to be peer1 itself: this used to hit an assert in addPeer.
    {
        const stream = try conn.openStream();
        defer stream.close();
        stream.setTimeout(2000);
        const msg = rpc.Message{ .sender_id = peer1.manager.node_id, .payload = .{ .PING = .{ .port = 13001 } } };
        try msg.serialize(stream.writer());
        // No PONG: the handler rejects the request and closes the stream.
        var buf: [1]u8 = undefined;
        const n = stream.read(&buf) catch 0;
        try std.testing.expectEqual(@as(usize, 0), n);
    }

    dht1.mutex.lock();
    const peers = try dht1.routing_table.getAllPeers();
    dht1.mutex.unlock();
    defer allocator.free(peers);
    try std.testing.expectEqual(@as(usize, 0), peers.len);

    // An honest PING over the same connection still works.
    var dht2 = Node.init(allocator, peer2.manager, peer2.config.node.swarm_key);
    defer dht2.deinit();
    try dht2.ping(conn);
}

test "dht: dialing with the wrong expected node ID fails" {
    std.debug.print("\n=== Running Test: dht: dialing with the wrong expected node ID fails ===\n", .{});
    const allocator = std.testing.allocator;

    var peer1 = try TestPeer.init(allocator, 13002);
    defer peer1.deinit();
    var peer2 = try TestPeer.init(allocator, 13003);
    defer peer2.deinit();
    try peer1.start();
    nomadfs.sync.sleep(100 * std.time.ns_per_ms);

    const wrong_id = nomadfs.net.id.NodeID{ .bytes = [_]u8{0xAB} ** 32 };
    try std.testing.expectError(
        error.PeerIdMismatch,
        peer2.manager.connectToPeer(peer1.listen_addr, peer2.config.node.swarm_key, wrong_id),
    );
    try std.testing.expectEqual(@as(usize, 0), peer2.manager.getConnectionsCount());
}

/// Accepts streams and reads them, but never answers.
fn silentHandler(_: *u8, conn: nomadfs.net.transport.Connection) anyerror!void {
    while (true) {
        const stream = conn.acceptStream() catch return;
        defer stream.close();
        var buf: [64]u8 = undefined;
        while ((stream.read(&buf) catch 0) > 0) {}
    }
}

test "dht: RPC to a silent peer times out" {
    std.debug.print("\n=== Running Test: dht: RPC to a silent peer times out ===\n", .{});
    const allocator = std.testing.allocator;

    var peer1 = try TestPeer.init(allocator, 13004);
    defer peer1.deinit();
    var peer2 = try TestPeer.init(allocator, 13005);
    defer peer2.deinit();

    var dummy: u8 = 0;
    peer1.manager.setConnectionHandler(&dummy, silentHandler);
    try peer1.start();
    nomadfs.sync.sleep(100 * std.time.ns_per_ms);

    var dht2 = Node.init(allocator, peer2.manager, peer2.config.node.swarm_key);
    defer dht2.deinit();
    dht2.rpc_timeout_ms = 200;

    const conn = try peer2.manager.connectToPeer(peer1.listen_addr, peer2.config.node.swarm_key, peer1.manager.node_id);
    defer conn.deinit();

    const started = nomadfs.sync.monotonicMillis();
    try std.testing.expectError(error.Timeout, dht2.ping(conn));
    try std.testing.expect(nomadfs.sync.monotonicMillis() - started < 3000);
}

test "network: connect to an unreachable address is bounded" {
    // 10.255.255.1 is unrouted on typical hosts: the SYN is never answered.
    const addr = try nomadfs.net.compat.Address.parseIp("10.255.255.1", 9);
    const started = nomadfs.sync.monotonicMillis();
    const result = nomadfs.net.compat.tcpConnectToAddressTimeout(addr, 300);
    if (result) |s| {
        s.close();
        return error.SkipZigTest; // Something answered; nothing to assert.
    } else |_| {}
    try std.testing.expect(nomadfs.sync.monotonicMillis() - started < 3000);
}
