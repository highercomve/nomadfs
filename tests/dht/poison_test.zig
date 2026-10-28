//! Loopback tests cannot model a public replier's loopback announcement;
//! node.zig's scope-policy unit test covers that boundary.
const std = @import("std");
const nomadfs = @import("nomadfs");
const TestPeer = @import("test_helpers").TestPeer;
const Node = nomadfs.net.discovery.Node;
const PeerInfo = nomadfs.net.discovery.kbucket.PeerInfo;
const Address = nomadfs.net.compat.Address;
const NodeID = nomadfs.net.id.NodeID;

test "dht: hearsay addresses are not stored as the peer's addresses" {
    const allocator = std.testing.allocator;
    var peers: [3]TestPeer = undefined;
    var nodes: [3]Node = undefined;
    var initialized: usize = 0;
    defer {
        for (peers[0..initialized]) |*peer| peer.stop();
        for (nodes[0..initialized]) |*node| node.deinit();
        for (peers[0..initialized]) |*peer| peer.deinit();
    }
    for (0..peers.len) |i| {
        peers[i] = try TestPeer.init(allocator, @intCast(13500 + i));
        nodes[i] = Node.init(allocator, peers[i].manager, peers[i].config.node.swarm_key);
        initialized += 1;
        peers[i].manager.setConnectionHandler(&nodes[i], Node.serve);
        try peers[i].start();
    }
    var liar = PeerInfo{ .id = peers[1].manager.node_id, .last_seen = 1 };
    _ = liar.addAddress(peers[1].listen_addr);
    _ = try nodes[0].routing_table.addPeer(liar);
    var victim = PeerInfo{ .id = peers[2].manager.node_id, .last_seen = 1 };
    _ = victim.addAddress(peers[2].listen_addr);
    const junk = [_]Address{
        Address.initIp4(.{ 192, 0, 2, 1 }, 9),
        Address.initIp4(.{ 198, 51, 100, 7 }, 14700),
        Address.initIp4(.{ 203, 0, 113, 9 }, 1),
        Address.initIp4(.{ 0, 0, 0, 0 }, 0),
        Address.initIp4(.{ 224, 0, 0, 251 }, 5354),
        Address.initIp4(.{ 10, 255, 255, 1 }, 14700),
    };
    for (junk) |addr| _ = victim.addAddress(addr);
    _ = try nodes[1].routing_table.addPeer(victim);
    try nodes[0].lookup(victim.id);
    nodes[0].mutex.lock();
    const learned = nodes[0].routing_table.getPeer(victim.id);
    nodes[0].mutex.unlock();
    try std.testing.expect(learned != null);
    try std.testing.expectEqual(@as(u8, 1), learned.?.addrs_count);
    try std.testing.expect(learned.?.addresses[0].eql(peers[2].listen_addr));
}

test "dht: a peer's own address displaces stale ones" {
    const allocator = std.testing.allocator;
    var a = try TestPeer.init(allocator, 13503);
    defer a.deinit();
    var b = try TestPeer.init(allocator, 13504);
    defer b.deinit();
    var a_node = Node.init(allocator, a.manager, a.config.node.swarm_key);
    defer a_node.deinit();
    var b_node = Node.init(allocator, b.manager, b.config.node.swarm_key);
    defer b_node.deinit();
    a.manager.setConnectionHandler(&a_node, Node.serve);
    b.manager.setConnectionHandler(&b_node, Node.serve);
    try a.start();
    try b.start();
    defer {
        a.stop();
        b.stop();
    }
    var stale = PeerInfo{ .id = b.manager.node_id, .last_seen = 1 };
    for (0..8) |i| _ = stale.addAddressFrom(Address.initIp4(.{ 192, 0, 2, @intCast(i + 1) }, 9), .announced, 1);
    _ = try a_node.routing_table.addPeer(stale);
    const conn = try a.manager.connectToPeer(b.listen_addr, a.config.node.swarm_key, stale.id);
    defer conn.deinit();
    try a_node.ping(conn);
    a_node.mutex.lock();
    const learned = a_node.routing_table.getPeer(stale.id).?;
    a_node.mutex.unlock();
    var present = false;
    for (learned.addresses[0..learned.addrs_count]) |addr| present = present or addr.eql(b.listen_addr);
    try std.testing.expect(present);
}

test "dht: a failed hearsay lookup does not evict a known peer" {
    const allocator = std.testing.allocator;
    var a = try TestPeer.init(allocator, 13504);
    defer a.deinit();
    var m = try TestPeer.init(allocator, 13505);
    defer m.deinit();
    var a_node = Node.init(allocator, a.manager, a.config.node.swarm_key);
    defer a_node.deinit();
    var m_node = Node.init(allocator, m.manager, m.config.node.swarm_key);
    defer m_node.deinit();
    a.manager.setConnectionHandler(&a_node, Node.serve);
    m.manager.setConnectionHandler(&m_node, Node.serve);
    try a.start();
    try m.start();
    defer {
        a.stop();
        m.stop();
    }

    var liar = PeerInfo{ .id = m.manager.node_id, .last_seen = 1 };
    _ = liar.addAddress(m.listen_addr);
    _ = try a_node.routing_table.addPeer(liar);

    // M advertises an unreachable candidate with only invalid/dropped addresses
    // so it enters A's lookup as hearsay and fails without evicting known peers.
    const c_id = NodeID{ .bytes = [_]u8{0x54} ** 32 };
    var poisoned_c = PeerInfo{ .id = c_id, .last_seen = 1 };
    _ = poisoned_c.addAddress(Address.initIp4(.{ 127, 0, 0, 1 }, 13505));
    _ = try m_node.routing_table.addPeer(poisoned_c);
    m_node.routing_table.buckets[m_node.routing_table.local_id.commonPrefixLen(c_id)].peers.items[0].addresses[0] = Address.initIp4(.{ 0, 0, 0, 0 }, 0);

    try a_node.lookup(c_id);
    a_node.mutex.lock();
    const still_has_m = a_node.routing_table.contains(m.manager.node_id);
    const has_c = a_node.routing_table.contains(c_id);
    a_node.mutex.unlock();
    try std.testing.expect(still_has_m);
    try std.testing.expect(!has_c);
}
