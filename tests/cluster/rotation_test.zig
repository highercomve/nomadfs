const std = @import("std");
const nomadfs = @import("nomadfs");
const TestPeer = @import("test_helpers").TestPeer;
const DhtNode = nomadfs.net.discovery.Node;
const Identity = nomadfs.device.identity.Identity;
const TrustStore = nomadfs.device.trust.Store;

fn identityWith(seed_byte: u8) !Identity {
    return Identity.fromSeed([_]u8{seed_byte} ** nomadfs.device.identity.seed_len);
}

const Captured = struct {
    calls: usize = 0,
    key: [32]u8 = undefined,
    epoch: u64 = 0,

    fn apply(ctx: *anyopaque, key: [32]u8, epoch: u64) void {
        const self: *Captured = @ptrCast(@alignCast(ctx));
        self.calls += 1;
        self.key = key;
        self.epoch = epoch;
    }
};

test "cluster: swarm key rotation reaches trusted devices only, once per epoch" {
    std.debug.print("\n=== Running Test: cluster: swarm key rotation ===\n", .{});
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();

    const admin = try identityWith(0x91);
    const receiver = try identityWith(0x92);
    const stranger = try identityWith(0x93);

    const store_path = "test_rotation.store";
    std.Io.Dir.cwd().deleteFile(io, store_path) catch {};
    defer std.Io.Dir.cwd().deleteFile(io, store_path) catch {};
    var store = try TrustStore.load(allocator, store_path, null);
    defer store.deinit();

    var peer_admin = try TestPeer.init(allocator, 13160);
    defer peer_admin.deinit();
    var peer_receiver = try TestPeer.init(allocator, 13161);
    defer peer_receiver.deinit();
    var peer_stranger = try TestPeer.init(allocator, 13162);
    defer peer_stranger.deinit();
    defer peer_admin.stop();
    defer peer_receiver.stop();
    defer peer_stranger.stop();

    // Paired with the admin (pinning its real transport key, as pairing
    // does); the stranger only has the swarm key.
    _ = try store.upsert(admin.publicKey(), peer_admin.manager.identity_key.public_key, "admin", 1);

    // Handshakes prove each side's device identity.
    peer_admin.manager.setDeviceAuthenticator(.{ .identity = admin });
    peer_receiver.manager.setDeviceAuthenticator(.{ .identity = receiver, .trust = &store });
    peer_stranger.manager.setDeviceAuthenticator(.{ .identity = stranger });

    var dht_admin = DhtNode.init(allocator, peer_admin.manager, peer_admin.config.node.swarm_key);
    defer dht_admin.deinit();
    var dht_receiver = DhtNode.init(allocator, peer_receiver.manager, peer_receiver.config.node.swarm_key);
    defer dht_receiver.deinit();
    var dht_stranger = DhtNode.init(allocator, peer_stranger.manager, peer_stranger.config.node.swarm_key);
    defer dht_stranger.deinit();
    dht_admin.device_identity = admin;
    dht_stranger.device_identity = stranger;
    dht_receiver.trust_store = &store;
    var captured = Captured{};
    dht_receiver.rotation_sink = .{ .ctx = &captured, .applyFn = Captured.apply };

    peer_admin.manager.setConnectionHandler(&dht_admin, DhtNode.serve);
    peer_receiver.manager.setConnectionHandler(&dht_receiver, DhtNode.serve);
    peer_stranger.manager.setConnectionHandler(&dht_stranger, DhtNode.serve);
    try peer_admin.start();
    try peer_receiver.start();
    try peer_stranger.start();
    nomadfs.sync.sleep(100 * std.time.ns_per_ms);

    const new_key = [_]u8{0x5E} ** 32;
    {
        const conn = try peer_admin.manager.connectToPeer(peer_receiver.listen_addr, peer_admin.config.node.swarm_key, peer_receiver.manager.node_id);
        defer conn.deinit();
        // The admin sees the receiver's verified identity on the connection.
        try std.testing.expect(conn.getRemoteDeviceID().?.eql(receiver.deviceId()));

        // Accepted once: the sink gets the key and the epoch moves on.
        try std.testing.expect(try dht_admin.sendRotation(conn, new_key, 1));
        try std.testing.expectEqual(@as(usize, 1), captured.calls);
        try std.testing.expectEqualSlices(u8, &new_key, &captured.key);
        try std.testing.expectEqual(@as(u64, 1), dht_receiver.swarm_epoch);

        // Replaying the same rotation is refused.
        try std.testing.expect(!try dht_admin.sendRotation(conn, new_key, 1));
        try std.testing.expectEqual(@as(usize, 1), captured.calls);
    }
    {
        // A device that only holds the swarm key: a valid signature, but
        // not one this receiver trusts.
        const conn = try peer_stranger.manager.connectToPeer(peer_receiver.listen_addr, peer_stranger.config.node.swarm_key, peer_receiver.manager.node_id);
        defer conn.deinit();
        try std.testing.expect(!try dht_stranger.sendRotation(conn, [_]u8{0x66} ** 32, 9));
        try std.testing.expectEqual(@as(usize, 1), captured.calls);
        try std.testing.expectEqual(@as(u64, 1), dht_receiver.swarm_epoch);
    }
    {
        // Without a sink (no way to apply it) a node refuses rotations.
        dht_receiver.rotation_sink = null;
        const conn = try peer_admin.manager.connectToPeer(peer_receiver.listen_addr, peer_admin.config.node.swarm_key, peer_receiver.manager.node_id);
        defer conn.deinit();
        try std.testing.expect(!try dht_admin.sendRotation(conn, new_key, 2));
    }
}
