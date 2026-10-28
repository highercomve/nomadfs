const std = @import("std");
const nomadfs = @import("nomadfs");
const TestPeer = @import("test_helpers").TestPeer;
const Node = nomadfs.net.discovery.Node;

fn setUp(peer: *TestPeer, dht: *Node) !void {
    peer.manager.setConnectionHandler(dht, Node.serve);
    dht.enableRelay();
    try peer.start();
}

test "relay: a device no address reaches is reached through one both can" {
    std.debug.print("\n=== Running Test: relay: reached through another device ===\n", .{});
    const allocator = std.testing.allocator;

    // A wants U; U's only known address is dead, but R is connected to both.
    var a = try TestPeer.init(allocator, 13400);
    defer a.deinit();
    var r = try TestPeer.init(allocator, 13401);
    defer r.deinit();
    var u = try TestPeer.init(allocator, 13402);
    defer u.deinit();

    var dht_a = Node.init(allocator, a.manager, a.config.node.swarm_key);
    defer dht_a.deinit();
    var dht_r = Node.init(allocator, r.manager, r.config.node.swarm_key);
    defer dht_r.deinit();
    var dht_u = Node.init(allocator, u.manager, u.config.node.swarm_key);
    defer dht_u.deinit();
    try setUp(&a, &dht_a);
    try setUp(&r, &dht_r);
    try setUp(&u, &dht_u);
    defer {
        a.stop();
        r.stop();
        u.stop();
    }
    nomadfs.sync.sleep(100 * std.time.ns_per_ms);

    // U and A each opened a connection to R (U is behind something R
    // can't dial into, so this is the only link).
    const u_to_r = try u.manager.connectToPeer(r.listen_addr, u.config.node.swarm_key, r.manager.node_id);
    defer u_to_r.deinit();
    const a_to_r = try a.manager.connectToPeer(r.listen_addr, a.config.node.swarm_key, r.manager.node_id);
    defer a_to_r.deinit();
    nomadfs.sync.sleep(100 * std.time.ns_per_ms);

    const dead = try nomadfs.net.compat.Address.parseIp("127.0.0.1", 1);
    const conn = try a.manager.connectToPeerMulti(&.{dead}, a.config.node.swarm_key, u.manager.node_id);
    defer conn.deinit();
    try std.testing.expect(conn.getRemoteNodeID().eql(u.manager.node_id));
    try std.testing.expect(conn.getPeerAddress().isUnspecified());

    // A full request and reply travel end to end.
    try dht_a.ping(conn);

    // The relayed connection is reused, not set up again.
    const count = a.manager.getConnectionsCount();
    const again = try a.manager.connectToPeerMulti(&.{dead}, a.config.node.swarm_key, u.manager.node_id);
    defer again.deinit();
    try std.testing.expectEqual(count, a.manager.getConnectionsCount());

    // U learned A, but never under an address the relay made up.
    nomadfs.sync.sleep(100 * std.time.ns_per_ms);
    dht_u.mutex.lock();
    const seen = dht_u.routing_table.getPeer(a.manager.node_id);
    dht_u.mutex.unlock();
    if (seen) |p| for (p.addresses[0..p.addrs_count]) |addr| {
        try std.testing.expect(!addr.isUnspecified());
    };

    // Unhooked before the nodes go away (stop runs later, in defer order).
    a.manager.relay_dialer = null;
    r.manager.relay_dialer = null;
    u.manager.relay_dialer = null;
}

test "relay: a relay that can't reach the target says no" {
    std.debug.print("\n=== Running Test: relay: refused when the target is unknown ===\n", .{});
    const allocator = std.testing.allocator;

    var a = try TestPeer.init(allocator, 13403);
    defer a.deinit();
    var r = try TestPeer.init(allocator, 13404);
    defer r.deinit();

    var dht_a = Node.init(allocator, a.manager, a.config.node.swarm_key);
    defer dht_a.deinit();
    var dht_r = Node.init(allocator, r.manager, r.config.node.swarm_key);
    defer dht_r.deinit();
    try setUp(&a, &dht_a);
    try setUp(&r, &dht_r);
    defer {
        a.stop();
        r.stop();
    }
    nomadfs.sync.sleep(100 * std.time.ns_per_ms);

    const a_to_r = try a.manager.connectToPeer(r.listen_addr, a.config.node.swarm_key, r.manager.node_id);
    defer a_to_r.deinit();

    const nobody = nomadfs.net.id.NodeID{ .bytes = [_]u8{0x5A} ** 32 };
    try std.testing.expectError(error.NoRelay, dht_a.dialThroughRelay(nobody));
    try std.testing.expectEqual(@as(u32, 0), dht_r.active_relays.load(.acquire));

    a.manager.relay_dialer = null;
    r.manager.relay_dialer = null;
}
