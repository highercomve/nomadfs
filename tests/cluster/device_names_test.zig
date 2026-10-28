const std = @import("std");
const builtin = @import("builtin");
const nomadfs = @import("nomadfs");
const TestPeer = @import("test_helpers").TestPeer;
const DhtNode = nomadfs.net.discovery.Node;
const StorageEngine = nomadfs.storage.engine.StorageEngine;
const BlockManager = nomadfs.cluster.BlockManager;
const Identity = nomadfs.device.identity.Identity;
const TrustStore = nomadfs.device.trust.Store;
const NodeID = nomadfs.net.id.NodeID;
const fs = nomadfs.fs;
const device_names = fs.device_names;
const fuse = fs.fuse;
const SwarmFolder = fs.SwarmFolder;
const sync = nomadfs.sync;

fn identityWith(seed_byte: u8) !Identity {
    return Identity.fromSeed([_]u8{seed_byte} ** nomadfs.device.identity.seed_len);
}

test "device names: loopback peer shares returns authenticated device_id and assign prioritizes trust" {
    std.debug.print("\n=== Running Test: device names: loopback peer shares ===\n", .{});
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const cwd = std.Io.Dir.cwd();

    const store_a_dir = "test_devnames_a_dir";
    const store_b_dir = "test_devnames_b_dir";
    const store_c_dir = "test_devnames_c_dir";
    const trust_b_path = "test_devnames_b.trust";

    for ([_][]const u8{ store_a_dir, store_b_dir, store_c_dir }) |d| cwd.deleteTree(io, d) catch {};
    defer for ([_][]const u8{ store_a_dir, store_b_dir, store_c_dir }) |d| cwd.deleteTree(io, d) catch {};
    cwd.deleteFile(io, trust_b_path) catch {};
    defer cwd.deleteFile(io, trust_b_path) catch {};

    var store_a = try StorageEngine.init(allocator, store_a_dir);
    defer store_a.deinit();
    var store_b = try StorageEngine.init(allocator, store_b_dir);
    defer store_b.deinit();
    var store_c = try StorageEngine.init(allocator, store_c_dir);
    defer store_c.deinit();

    const id_a = try identityWith(0x81);
    const id_b = try identityWith(0x82);
    const id_c = try identityWith(0x83);

    var trust_b = try TrustStore.load(allocator, trust_b_path, null);
    defer trust_b.deinit();

    var peer_a = try TestPeer.init(allocator, 13210);
    defer peer_a.deinit();
    var peer_b = try TestPeer.init(allocator, 13211);
    defer peer_b.deinit();
    var peer_c = try TestPeer.init(allocator, 13212);
    defer peer_c.deinit();

    // Node A is paired in Node B's trust store with label "Alpha"
    _ = try trust_b.upsert(id_a.publicKey(), peer_a.manager.identity_key.public_key, "Alpha", 100);

    peer_a.manager.setDeviceAuthenticator(.{ .identity = id_a });
    peer_b.manager.setDeviceAuthenticator(.{ .identity = id_b, .trust = &trust_b });
    peer_c.manager.setDeviceAuthenticator(.{ .identity = id_c });

    var dht_a = DhtNode.init(allocator, peer_a.manager, peer_a.config.node.swarm_key);
    defer dht_a.deinit();
    var dht_b = DhtNode.init(allocator, peer_b.manager, peer_b.config.node.swarm_key);
    defer dht_b.deinit();
    var dht_c = DhtNode.init(allocator, peer_c.manager, peer_c.config.node.swarm_key);
    defer dht_c.deinit();

    dht_a.block_store = &store_a;
    dht_a.nickname = "Alpha";
    dht_b.block_store = &store_b;
    dht_b.trust_store = &trust_b;
    dht_c.block_store = &store_c;
    dht_c.nickname = "Alpha"; // C attempts to spoof Alpha!

    // Setup dummy shares on A and C
    const folder_a = "test_devnames_folder_a";
    const folder_c = "test_devnames_folder_c";
    cwd.deleteTree(io, folder_a) catch {};
    defer cwd.deleteTree(io, folder_a) catch {};
    cwd.deleteTree(io, folder_c) catch {};
    defer cwd.deleteTree(io, folder_c) catch {};
    try cwd.createDirPath(io, folder_a);
    try cwd.createDirPath(io, folder_c);
    try cwd.writeFile(io, .{ .sub_path = folder_a ++ "/a.txt", .data = "hello from a" });
    try cwd.writeFile(io, .{ .sub_path = folder_c ++ "/c.txt", .data = "hello from c" });

    const idx_a = try fs.ShareIndex.create(allocator, io, &store_a);
    defer idx_a.destroy();
    try idx_a.add("ShareA", folder_a);
    dht_a.share_source = idx_a.source();

    const idx_c = try fs.ShareIndex.create(allocator, io, &store_c);
    defer idx_c.destroy();
    try idx_c.add("ShareC", folder_c);
    dht_c.share_source = idx_c.source();

    peer_a.manager.setConnectionHandler(&dht_a, DhtNode.serve);
    peer_b.manager.setConnectionHandler(&dht_b, DhtNode.serve);
    peer_c.manager.setConnectionHandler(&dht_c, DhtNode.serve);
    defer peer_a.stop();
    defer peer_b.stop();
    defer peer_c.stop();
    try peer_a.start();
    try peer_b.start();
    try peer_c.start();
    sync.sleep(100 * std.time.ns_per_ms);

    // B dials A and C to establish connections
    {
        const conn_a = try peer_b.manager.connectToPeer(peer_a.listen_addr, peer_b.config.node.swarm_key, peer_a.manager.node_id);
        defer conn_a.deinit();
        try dht_b.ping(conn_a);

        const conn_c = try peer_b.manager.connectToPeer(peer_c.listen_addr, peer_b.config.node.swarm_key, peer_c.manager.node_id);
        defer conn_c.deinit();
        try dht_b.ping(conn_c);
    }
    sync.sleep(100 * std.time.ns_per_ms);

    const bm_b = try BlockManager.init(allocator, .{ .network = peer_b.manager, .dht = &dht_b, .storage = &store_b });
    defer bm_b.deinit();

    // 9. Remote.shares returns authenticated device_id
    var remote_a = fs.Remote{ .block_manager = bm_b, .store = &store_b, .peer = peer_a.manager.node_id };
    const shares_a = try remote_a.shares(allocator);
    defer shares_a.deinit(allocator);

    const expected_a_did = NodeID.fromPublicKey(id_a.publicKey());
    try std.testing.expect(shares_a.device_id != null);
    try std.testing.expect(shares_a.device_id.?.eql(expected_a_did));

    var remote_c = fs.Remote{ .block_manager = bm_b, .store = &store_b, .peer = peer_c.manager.node_id };
    const shares_c = try remote_c.shares(allocator);
    defer shares_c.deinit(allocator);

    const expected_c_did = NodeID.fromPublicKey(id_c.publicKey());
    try std.testing.expect(shares_c.device_id != null);
    try std.testing.expect(shares_c.device_id.?.eql(expected_c_did));
    try std.testing.expect(!shares_c.device_id.?.eql(expected_a_did));

    // Assign names: A is trusted, C is untrusted
    const entry_a = device_names.Entry{
        .device_id = shares_a.device_id.?.bytes,
        .trusted = .{ .label = "Alpha", .added_at = 100 },
        .nickname = shares_a.nickname,
    };
    const entry_c = device_names.Entry{
        .device_id = shares_c.device_id.?.bytes,
        .trusted = null,
        .nickname = shares_c.nickname,
    };

    var assigned: [2][]u8 = undefined;
    try device_names.assign(allocator, &[2]device_names.Entry{ entry_a, entry_c }, &assigned);
    defer for (assigned) |s| allocator.free(s);

    try std.testing.expectEqualStrings("Alpha", assigned[0]);
    var expected_c_buf: [64]u8 = undefined;
    const expected_c_name = try std.fmt.bufPrint(&expected_c_buf, "Alpha-{s}", .{std.fmt.bytesToHex(expected_c_did.bytes[0..4], .lower)});
    try std.testing.expectEqualStrings(expected_c_name, assigned[1]);

    // 10. Revoke A in B's store -> next assign names A "Alpha-<fp8(A)>"
    try std.testing.expect(trust_b.revoke(expected_a_did));

    const entry_a_revoked = device_names.Entry{
        .device_id = shares_a.device_id.?.bytes,
        .trusted = null,
        .nickname = shares_a.nickname,
    };

    var assigned_revoked: [2][]u8 = undefined;
    try device_names.assign(allocator, &[2]device_names.Entry{ entry_a_revoked, entry_c }, &assigned_revoked);
    defer for (assigned_revoked) |s| allocator.free(s);

    var expected_a_buf: [64]u8 = undefined;
    const expected_a_name = try std.fmt.bufPrint(&expected_a_buf, "Alpha-{s}", .{std.fmt.bytesToHex(expected_a_did.bytes[0..4], .lower)});
    try std.testing.expectEqualStrings(expected_a_name, assigned_revoked[0]);
    try std.testing.expectEqualStrings(expected_c_name, assigned_revoked[1]);
}

test "device names: mount readdir lists Swarm and avoids reserved name collision" {
    if (builtin.os.tag != .linux or builtin.abi.isAndroid()) return;
    std.debug.print("\n=== Running Test: device names: mount readdir Swarm reservation ===\n", .{});
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var store_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmp_path = store_path_buf[0..try tmp.dir.realPath(io, &store_path_buf)];
    const manifest_path = try std.fs.path.join(allocator, &.{ tmp_path, "manifest.json" });
    defer allocator.free(manifest_path);

    var store = try StorageEngine.init(allocator, tmp_path);
    defer store.deinit();

    const dev_id = NodeID{ .bytes = [_]u8{0x11} ** 32 };
    const swarm = try SwarmFolder.create(allocator, io, &store, dev_id, "test", manifest_path);
    defer swarm.destroy();

    var mount = try fuse.Mount.init(allocator, null, &store);
    defer mount.deinit();
    mount.swarm = swarm;

    // Add three fake devices directly
    const dev_a = try allocator.create(fuse.Remote);
    dev_a.* = .{ .block_manager = undefined, .store = &store, .peer = NodeID{ .bytes = [_]u8{0xaa} ** 32 } };
    try mount.devices.append(allocator, .{
        .name = try allocator.dupe(u8, "Alpha"),
        .remote = dev_a,
        .online = true,
        .last_seen_ms = sync.monotonicMillis(),
    });

    const dev_c = try allocator.create(fuse.Remote);
    dev_c.* = .{ .block_manager = undefined, .store = &store, .peer = NodeID{ .bytes = [_]u8{0xcc} ** 32 } };
    try mount.devices.append(allocator, .{
        .name = try allocator.dupe(u8, "Alpha-cccccccc"),
        .remote = dev_c,
        .online = true,
        .last_seen_ms = sync.monotonicMillis(),
    });

    // Device D claims "Swarm" but gets suffixed
    const dev_d = try allocator.create(fuse.Remote);
    dev_d.* = .{ .block_manager = undefined, .store = &store, .peer = NodeID{ .bytes = [_]u8{0xdd} ** 32 } };
    try mount.devices.append(allocator, .{
        .name = try allocator.dupe(u8, "Swarm-dddddddd"),
        .remote = dev_d,
        .online = true,
        .last_seen_ms = sync.monotonicMillis(),
    });

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const root_inode = mount.table.map.get(fuse.root_id).?.data;
    // Inspect childrenOf(.root)
    mount.lock.lock();
    const children = blk: {
        var out: std.ArrayList(struct { name: []const u8 }) = .empty;
        if (mount.swarm != null) {
            try out.append(arena.allocator(), .{ .name = "Swarm" });
        }
        for (mount.devices.items) |d| {
            if (!d.online) continue;
            try out.append(arena.allocator(), .{ .name = try arena.allocator().dupe(u8, d.name) });
        }
        break :blk out.items;
    };
    mount.lock.unlock();

    // Verify: exactly 4 items, Swarm appears exactly once, no duplicates
    try std.testing.expectEqual(@as(usize, 4), children.len);
    try std.testing.expectEqualStrings("Swarm", children[0].name);
    try std.testing.expectEqualStrings("Alpha", children[1].name);
    try std.testing.expectEqualStrings("Alpha-cccccccc", children[2].name);
    try std.testing.expectEqualStrings("Swarm-dddddddd", children[3].name);

    var count_swarm: usize = 0;
    for (children) |c| {
        if (std.mem.eql(u8, c.name, "Swarm")) count_swarm += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), count_swarm);
    _ = root_inode;
}
