const std = @import("std");
const nomadfs = @import("nomadfs");
const TestPeer = @import("test_helpers").TestPeer;
const DhtNode = nomadfs.net.discovery.Node;
const Identity = nomadfs.device.identity.Identity;
const TrustStore = nomadfs.device.trust.Store;
const node_info = nomadfs.node_info;

const Source = struct {
    fn info(_: *anyopaque, allocator: std.mem.Allocator) anyerror![]u8 {
        var i: node_info.Info = .{ .uptime_s = 7, .disk_total = 1000, .disk_free = 400, .shares = 2 };
        i.version = .init("9.9.9");
        return node_info.encode(allocator, i);
    }
};

test "cluster: a trusted device learns about another; others don't" {
    std.debug.print("\n=== Running Test: cluster: node info ===\n", .{});
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const asker_id = try Identity.fromSeed([_]u8{0xA1} ** nomadfs.device.identity.seed_len);
    const server_id = try Identity.fromSeed([_]u8{0xA2} ** nomadfs.device.identity.seed_len);

    const trust_path = "test_node_info.store";
    std.Io.Dir.cwd().deleteFile(io, trust_path) catch {};
    defer std.Io.Dir.cwd().deleteFile(io, trust_path) catch {};

    var asker = try TestPeer.init(allocator, 13230);
    defer asker.deinit();
    var server = try TestPeer.init(allocator, 13231);
    defer server.deinit();
    defer asker.stop();
    defer server.stop();

    var trust = try TrustStore.load(allocator, trust_path, null);
    defer trust.deinit();
    asker.manager.setDeviceAuthenticator(.{ .identity = asker_id });
    server.manager.setDeviceAuthenticator(.{ .identity = server_id, .trust = &trust });

    var asker_dht = DhtNode.init(allocator, asker.manager, asker.config.node.swarm_key);
    defer asker_dht.deinit();
    var server_dht = DhtNode.init(allocator, server.manager, server.config.node.swarm_key);
    defer server_dht.deinit();
    server_dht.trust_store = &trust;
    var ctx: u8 = 0;
    server_dht.info_source = .{ .ctx = &ctx, .infoFn = Source.info };
    asker.manager.setConnectionHandler(&asker_dht, DhtNode.serve);
    server.manager.setConnectionHandler(&server_dht, DhtNode.serve);
    try asker.start();
    try server.start();
    nomadfs.sync.sleep(100 * std.time.ns_per_ms);

    // Not trusted yet: an empty answer.
    {
        const conn = try asker.manager.connectToPeer(server.listen_addr, asker.config.node.swarm_key, server.manager.node_id);
        defer conn.deinit();
        try std.testing.expectError(error.NotTrusted, asker_dht.fetchNodeInfo(conn, allocator));
    }

    // Trusted: the info.
    _ = try trust.upsert(asker_id.publicKey(), asker.manager.identity_key.public_key, "Laptop", 1);
    const conn = try asker.manager.connectToPeer(server.listen_addr, asker.config.node.swarm_key, server.manager.node_id);
    defer conn.deinit();
    const bytes = try asker_dht.fetchNodeInfo(conn, allocator);
    defer allocator.free(bytes);
    const got = try node_info.decode(bytes);
    try std.testing.expectEqualStrings("9.9.9", got.version.slice());
    try std.testing.expectEqual(@as(u64, 400), got.disk_free);
    try std.testing.expectEqual(@as(u32, 2), got.shares);
}
