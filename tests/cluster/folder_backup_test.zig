const std = @import("std");
const nomadfs = @import("nomadfs");
const TestPeer = @import("test_helpers").TestPeer;
const DhtNode = nomadfs.net.discovery.Node;
const StorageEngine = nomadfs.storage.engine.StorageEngine;
const BlockManager = nomadfs.cluster.BlockManager;
const Identity = nomadfs.device.identity.Identity;
const TrustStore = nomadfs.device.trust.Store;
const fs = nomadfs.fs;

fn identityWith(seed_byte: u8) !Identity {
    return Identity.fromSeed([_]u8{seed_byte} ** nomadfs.device.identity.seed_len);
}

test "folder backup: a backup device keeps a member's marked folder, deletions included" {
    std.debug.print("\n=== Running Test: cluster: folder backup ===\n", .{});
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const cwd = std.Io.Dir.cwd();

    const phone_dir = "test_fbackup_store_phone";
    const backup_dir = "test_fbackup_store_backup";
    const folder = "test_fbackup_camera";
    const trust_path = "test_fbackup_trust.store";
    const state_path = "test_fbackup_store_backup.backups";
    for ([_][]const u8{ phone_dir, backup_dir, folder }) |d| cwd.deleteTree(io, d) catch {};
    defer for ([_][]const u8{ phone_dir, backup_dir, folder }) |d| cwd.deleteTree(io, d) catch {};
    cwd.deleteFile(io, trust_path) catch {};
    defer cwd.deleteFile(io, trust_path) catch {};
    cwd.deleteFile(io, state_path) catch {};
    defer cwd.deleteFile(io, state_path) catch {};

    try cwd.createDirPath(io, folder);
    try cwd.writeFile(io, .{ .sub_path = folder ++ "/IMG_0001.jpg", .data = "first photo" });
    try cwd.writeFile(io, .{ .sub_path = folder ++ "/IMG_0002.jpg", .data = "second photo" });

    var phone_store = try StorageEngine.init(allocator, phone_dir);
    defer phone_store.deinit();
    var backup_store = try StorageEngine.init(allocator, backup_dir);
    defer backup_store.deinit();

    var phone = try TestPeer.init(allocator, 13192);
    defer phone.deinit();
    var backup = try TestPeer.init(allocator, 13193);
    defer backup.deinit();

    const phone_id = try identityWith(0xA1);
    const backup_id = try identityWith(0xA2);
    var trust = try TrustStore.load(allocator, trust_path, null);
    defer trust.deinit();
    _ = try trust.upsert(phone_id.publicKey(), phone.manager.identity_key.public_key, "Pixel", 1);
    phone.manager.setDeviceAuthenticator(.{ .identity = phone_id });
    backup.manager.setDeviceAuthenticator(.{ .identity = backup_id, .trust = &trust });

    var phone_dht = DhtNode.init(allocator, phone.manager, phone.config.node.swarm_key);
    defer phone_dht.deinit();
    var backup_dht = DhtNode.init(allocator, backup.manager, backup.config.node.swarm_key);
    defer backup_dht.deinit();
    phone_dht.block_store = &phone_store;
    phone_dht.nickname = "Pixel";
    backup_dht.block_store = &backup_store;

    const phone_index = try fs.ShareIndex.create(allocator, io, &phone_store);
    defer phone_index.destroy();
    try phone_index.add("Camera", folder);
    try phone_index.setBackup("Camera", true);
    phone_dht.share_source = phone_index.source();
    const backup_index = try fs.ShareIndex.create(allocator, io, &backup_store);
    defer backup_index.destroy();
    backup_dht.share_source = backup_index.source();

    phone.manager.setConnectionHandler(&phone_dht, DhtNode.serve);
    backup.manager.setConnectionHandler(&backup_dht, DhtNode.serve);
    defer phone.stop();
    defer backup.stop();
    try phone.start();
    try backup.start();
    nomadfs.sync.sleep(100 * std.time.ns_per_ms);
    {
        const conn = try backup.manager.connectToPeer(phone.listen_addr, backup.config.node.swarm_key, phone.manager.node_id);
        defer conn.deinit();
        try backup_dht.ping(conn);
    }

    const bm = try BlockManager.init(allocator, .{ .network = backup.manager, .dht = &backup_dht, .storage = &backup_store });
    defer bm.deinit();
    var enabled = std.atomic.Value(bool).init(true);
    const folder_backup = try fs.FolderBackup.create(allocator, io, &backup_store, backup_index, &trust, bm, &enabled, state_path);
    defer folder_backup.destroy();
    folder_backup.running.store(true, .release);

    // First round: the whole folder is copied and listed as a backup share.
    try std.testing.expectEqual(@as(usize, 1), try folder_backup.round());
    var held = try backup_index.heldSnapshot(allocator);
    try std.testing.expectEqual(@as(usize, 1), held.len);
    try std.testing.expectEqualStrings("Pixel · Camera (backup)", held[0].display);
    const loader = fs.tree.Loader.local(&backup_store);
    const first = try fs.tree.resolve(allocator, loader, held[0].root, "IMG_0001.jpg");
    var buf: [64]u8 = undefined;
    const n = try fs.tree.readAt(allocator, loader, first.cid, 0, &buf);
    try std.testing.expectEqualStrings("first photo", buf[0..n]);
    fs.ShareIndex.freeHeldSnapshot(allocator, held);

    // Nothing changed: nothing to do.
    try std.testing.expectEqual(@as(usize, 0), try folder_backup.round());

    // A photo is deleted and one added on the phone: the backup keeps both.
    try cwd.deleteFile(io, folder ++ "/IMG_0001.jpg");
    try cwd.writeFile(io, .{ .sub_path = folder ++ "/IMG_0003.jpg", .data = "third photo" });
    phone_index.rescanAll();
    try std.testing.expectEqual(@as(usize, 1), try folder_backup.round());
    held = try backup_index.heldSnapshot(allocator);
    defer fs.ShareIndex.freeHeldSnapshot(allocator, held);
    var listing = try fs.tree.listDir(allocator, loader, &held[0].root);
    defer listing.deinit();
    try std.testing.expectEqual(@as(usize, 3), listing.entries.len);
    try std.testing.expect(listing.find("IMG_0001.jpg") != null);

    // The backup device tells the swarm what it holds.
    const info_bytes = try backup_index.backupInfo(allocator);
    defer allocator.free(info_bytes);
    var info = try fs.backup.decodeInfo(allocator, info_bytes);
    defer info.deinit();
    try std.testing.expectEqual(@as(usize, 1), info.held.len);
    try std.testing.expectEqual(phone_id.deviceId().bytes, info.held[0].owner);
    try std.testing.expectEqualStrings("Camera", info.held[0].share);
}
