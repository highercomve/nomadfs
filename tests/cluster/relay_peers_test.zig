const std = @import("std");
const nomadfs = @import("nomadfs");
const TestPeer = @import("test_helpers").TestPeer;
const DhtNode = nomadfs.net.discovery.Node;
const StorageEngine = nomadfs.storage.engine.StorageEngine;
const BlockManager = nomadfs.cluster.BlockManager;

// A phone outside the house: it reaches the public node R, and the home
// device U only through R. U never enters the phone's routing table (its
// only address there would be the relay's), yet the folder layer must list
// it and reach it, or nothing at home shows up away from home.
test "relay: a device reached only through a relay is listed and reachable" {
    std.debug.print("\n=== Running Test: relay: listed and reachable through a relay ===\n", .{});
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const cwd = std.Io.Dir.cwd();
    cwd.deleteTree(io, "test_relay_peers") catch {};
    defer cwd.deleteTree(io, "test_relay_peers") catch {};
    try cwd.createDirPath(io, "test_relay_peers");

    var a = try TestPeer.init(allocator, 13410);
    defer a.deinit();
    var r = try TestPeer.init(allocator, 13411);
    defer r.deinit();
    var u = try TestPeer.init(allocator, 13412);
    defer u.deinit();
    var dht_a = DhtNode.init(allocator, a.manager, a.config.node.swarm_key);
    defer dht_a.deinit();
    var dht_r = DhtNode.init(allocator, r.manager, r.config.node.swarm_key);
    defer dht_r.deinit();
    var dht_u = DhtNode.init(allocator, u.manager, u.config.node.swarm_key);
    defer dht_u.deinit();
    for ([_]*TestPeer{ &a, &r, &u }, [_]*DhtNode{ &dht_a, &dht_r, &dht_u }) |p, d| {
        p.manager.setConnectionHandler(d, DhtNode.serve);
        d.enableRelay();
        try p.start();
    }
    defer {
        a.manager.relay_dialer = null;
        r.manager.relay_dialer = null;
        u.manager.relay_dialer = null;
        a.stop();
        r.stop();
        u.stop();
    }

    var store = try StorageEngine.init(allocator, "test_relay_peers");
    defer store.deinit();
    dht_a.block_store = &store;
    const bm = try BlockManager.init(allocator, .{ .network = a.manager, .dht = &dht_a, .storage = &store });
    defer bm.deinit();

    // U and A each dialed R (nothing dials into U).
    const u_to_r = try u.manager.connectToPeer(r.listen_addr, u.config.node.swarm_key, r.manager.node_id);
    defer u_to_r.deinit();
    const a_to_r = try a.manager.connectToPeer(r.listen_addr, a.config.node.swarm_key, r.manager.node_id);
    defer a_to_r.deinit();
    nomadfs.sync.sleep(100 * std.time.ns_per_ms);

    // U isn't in A's routing table, and no connection to it exists yet.
    {
        dht_a.mutex.lock();
        defer dht_a.mutex.unlock();
        try std.testing.expect(dht_a.routing_table.getPeer(u.manager.node_id) == null);
    }

    // Reaching it anyway: no address of its own, so through R.
    const conn = try bm.connectTo(u.manager.node_id);
    defer conn.deinit();
    try std.testing.expect(conn.getRemoteNodeID().eql(u.manager.node_id));
    try std.testing.expect(conn.getPeerAddress().isUnspecified());
    try dht_a.ping(conn);

    // And listed with the devices the folder layer asks for shares.
    const peers = try bm.knownPeers(allocator);
    defer allocator.free(peers);
    var listed = false;
    for (peers) |p| {
        if (p.eql(u.manager.node_id)) listed = true;
    }
    try std.testing.expect(listed);
}
