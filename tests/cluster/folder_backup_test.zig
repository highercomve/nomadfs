const std = @import("std");
const nomadfs = @import("nomadfs");
const TestPeer = @import("test_helpers").TestPeer;
const DhtNode = nomadfs.net.discovery.Node;
const StorageEngine = nomadfs.storage.engine.StorageEngine;
const BlockManager = nomadfs.cluster.BlockManager;
const fs = nomadfs.fs;

fn always() bool {
    return true;
}

test "folder backup: a marked folder goes into the swarm folder and every backup device keeps it once" {
    std.debug.print("\n=== Running Test: cluster: folder backup through the swarm folder ===\n", .{});
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const cwd = std.Io.Dir.cwd();

    const dirs = [_][]const u8{ "test_fbackup_phone", "test_fbackup_server", "test_fbackup_camera" };
    for (dirs) |d| cwd.deleteTree(io, d) catch {};
    defer for (dirs) |d| cwd.deleteTree(io, d) catch {};
    try cwd.createDirPath(io, "test_fbackup_camera");
    const first = "first photo";
    const second = "second photo, a little longer";
    try cwd.writeFile(io, .{ .sub_path = "test_fbackup_camera/IMG_0001.jpg", .data = first });
    try cwd.writeFile(io, .{ .sub_path = "test_fbackup_camera/IMG_0002.jpg", .data = second });

    var phone_store = try StorageEngine.init(allocator, "test_fbackup_phone");
    defer phone_store.deinit();
    var server_store = try StorageEngine.init(allocator, "test_fbackup_server");
    defer server_store.deinit();

    var phone = try TestPeer.init(allocator, 13192);
    defer phone.deinit();
    var server = try TestPeer.init(allocator, 13193);
    defer server.deinit();
    var phone_dht = DhtNode.init(allocator, phone.manager, phone.config.node.swarm_key);
    defer phone_dht.deinit();
    var server_dht = DhtNode.init(allocator, server.manager, server.config.node.swarm_key);
    defer server_dht.deinit();
    phone_dht.block_store = &phone_store;
    server_dht.block_store = &server_store;

    // The phone shares its camera folder, marked for backup.
    const index = try fs.ShareIndex.create(allocator, io, &phone_store);
    defer index.destroy();
    try index.add("Camera", "test_fbackup_camera");
    try index.setBackup("Camera", true);
    const phone_swarm = try fs.SwarmFolder.create(allocator, io, &phone_store, phone.manager.node_id, "Pixel", "test_fbackup_phone/swarm.json");
    defer phone_swarm.destroy();
    const server_swarm = try fs.SwarmFolder.create(allocator, io, &server_store, server.manager.node_id, "Plex", "test_fbackup_server/swarm.json");
    defer server_swarm.destroy();
    phone_dht.swarm_source = phone_swarm.source();
    server_dht.swarm_source = server_swarm.source();
    const import = try fs.BackupImport.create(allocator, io, phone_swarm, index, &phone_store, "Pixel", "test_fbackup_phone/imported", always);
    defer import.destroy();

    phone.manager.setConnectionHandler(&phone_dht, DhtNode.serve);
    server.manager.setConnectionHandler(&server_dht, DhtNode.serve);
    defer phone.stop();
    defer server.stop();
    try phone.start();
    try server.start();
    nomadfs.sync.sleep(100 * std.time.ns_per_ms);
    {
        const conn = try server.manager.connectToPeer(phone.listen_addr, server.config.node.swarm_key, phone.manager.node_id);
        defer conn.deinit();
        try server_dht.ping(conn);
    }
    const phone_bm = try BlockManager.init(allocator, .{ .network = phone.manager, .dht = &phone_dht, .storage = &phone_store });
    defer phone_bm.deinit();
    const server_bm = try BlockManager.init(allocator, .{ .network = server.manager, .dht = &server_dht, .storage = &server_store });
    defer server_bm.deinit();
    phone_swarm.block_manager = phone_bm;
    server_swarm.block_manager = server_bm;

    // The phone's photos appear in the swarm folder, under its name.
    try std.testing.expectEqual(@as(usize, 2), try import.run());
    try std.testing.expect(phone_swarm.fileInfo("Pixel/Camera/IMG_0001.jpg") != null);

    // The backup device learns them and keeps every one.
    try std.testing.expect(try server_swarm.syncNow() > 0);
    server_swarm.backup_enabled.store(true, .release);
    try server_swarm.backupRound();
    var status = server_swarm.backupStatus();
    try std.testing.expectEqual(@as(usize, 2), status.files);
    try std.testing.expectEqual(@as(usize, 2), status.backed_up);
    // Stored once: what it keeps is exactly the photos' bytes.
    try std.testing.expectEqual(@as(u64, first.len + second.len), status.bytes);

    // Freed on the phone: still in the swarm folder, still kept.
    try cwd.deleteFile(io, "test_fbackup_camera/IMG_0001.jpg");
    try cwd.writeFile(io, .{ .sub_path = "test_fbackup_camera/IMG_0003.jpg", .data = "third" });
    try index.add("Camera", "test_fbackup_camera"); // rescan
    try std.testing.expectEqual(@as(usize, 1), try import.run());
    _ = try server_swarm.syncNow();
    try server_swarm.backupRound();
    status = server_swarm.backupStatus();
    try std.testing.expectEqual(@as(usize, 3), status.files);
    try std.testing.expectEqual(@as(usize, 3), status.backed_up);
    try std.testing.expect(server_swarm.fileInfo("Pixel/Camera/IMG_0001.jpg") != null);
}
