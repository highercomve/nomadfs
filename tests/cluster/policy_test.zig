const std = @import("std");
const nomadfs = @import("nomadfs");
const TestPeer = @import("test_helpers").TestPeer;
const DhtNode = nomadfs.net.discovery.Node;
const Identity = nomadfs.device.identity.Identity;
const TrustStore = nomadfs.device.trust.Store;
const Policy = nomadfs.device.policy.Policy;

test "cluster: the swarm policy spreads once per change" {
    std.debug.print("\n=== Running Test: cluster: policy spreads ===\n", .{});
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const files = [_][]const u8{ "test_policy_a.store", "test_policy_b.store", "test_policy_a.bin", "test_policy_b.bin" };
    for (files) |f| std.Io.Dir.cwd().deleteFile(io, f) catch {};
    defer for (files) |f| std.Io.Dir.cwd().deleteFile(io, f) catch {};

    const id_a = try Identity.fromSeed([_]u8{0xB1} ** nomadfs.device.identity.seed_len);
    const id_b = try Identity.fromSeed([_]u8{0xB2} ** nomadfs.device.identity.seed_len);

    var a = try TestPeer.init(allocator, 13262);
    defer a.deinit();
    var b = try TestPeer.init(allocator, 13263);
    defer b.deinit();
    defer a.stop();
    defer b.stop();

    // Members of each other.
    var trust_a = try TrustStore.load(allocator, files[0], null);
    defer trust_a.deinit();
    var trust_b = try TrustStore.load(allocator, files[1], null);
    defer trust_b.deinit();
    _ = try trust_a.upsert(id_b.publicKey(), b.manager.identity_key.public_key, "B", 1);
    _ = try trust_b.upsert(id_a.publicKey(), a.manager.identity_key.public_key, "A", 1);
    a.manager.setDeviceAuthenticator(.{ .identity = id_a, .trust = &trust_a });
    b.manager.setDeviceAuthenticator(.{ .identity = id_b, .trust = &trust_b });

    const policy_a = try Policy.load(allocator, files[2]);
    defer policy_a.destroy();
    const policy_b = try Policy.load(allocator, files[3]);
    defer policy_b.destroy();

    var dht_a = DhtNode.init(allocator, a.manager, a.config.node.swarm_key);
    defer dht_a.deinit();
    var dht_b = DhtNode.init(allocator, b.manager, b.config.node.swarm_key);
    defer dht_b.deinit();
    dht_a.trust_store = &trust_a;
    dht_a.device_identity = id_a;
    dht_a.policy = policy_a;
    dht_b.trust_store = &trust_b;
    dht_b.device_identity = id_b;
    dht_b.policy = policy_b;
    a.manager.setConnectionHandler(&dht_a, DhtNode.serve);
    b.manager.setConnectionHandler(&dht_b, DhtNode.serve);
    try a.start();
    try b.start();
    nomadfs.sync.sleep(100 * std.time.ns_per_ms);

    const conn = try a.manager.connectToPeer(b.listen_addr, a.config.node.swarm_key, b.manager.node_id);
    defer conn.deinit();

    // Nothing to send yet.
    try std.testing.expectEqual(@as(usize, 0), try dht_a.pushPolicy(conn));

    // A sets copies = 3: B takes it; sent again unchanged: nothing.
    const now = nomadfs.nowSeconds();
    _ = try policy_a.setCopies(id_a, &trust_a, 3, now);
    try std.testing.expectEqual(@as(usize, 1), try dht_a.pushPolicy(conn));
    try std.testing.expectEqual(@as(u8, 3), policy_b.copies());
    try std.testing.expectEqual(@as(usize, 0), try dht_a.pushPolicy(conn));

    // B already has a newer setting: A's older one is acknowledged, not applied.
    _ = try policy_b.setCopies(id_b, &trust_b, 2, now + 5);
    _ = try policy_a.setCopies(id_a, &trust_a, 4, now + 1);
    try std.testing.expectEqual(@as(usize, 1), try dht_a.pushPolicy(conn));
    try std.testing.expectEqual(@as(u8, 2), policy_b.copies());
}
