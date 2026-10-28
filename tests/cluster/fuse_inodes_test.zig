const std = @import("std");
const builtin = @import("builtin");
const nomadfs = @import("nomadfs");
const TestPeer = @import("test_helpers").TestPeer;
const DhtNode = nomadfs.net.discovery.Node;
const StorageEngine = nomadfs.storage.engine.StorageEngine;
const BlockManager = nomadfs.cluster.BlockManager;
const fs = nomadfs.fs;
const fuse = fs.fuse;
const SwarmFolder = fs.SwarmFolder;
const NodeID = nomadfs.net.id.NodeID;

fn sendLookup(mount: *fuse.Mount, parent_ino: u64, name: []const u8) !void {
    var buf align(8) = [_]u8{0} ** 512;
    const header: *fuse.InHeader = @ptrCast(&buf);
    header.len = @intCast(@sizeOf(fuse.InHeader) + name.len + 1);
    header.opcode = @intFromEnum(fuse.Opcode.lookup);
    header.unique = 1;
    header.nodeid = parent_ino;
    @memcpy(buf[@sizeOf(fuse.InHeader)..][0..name.len], name);
    buf[@sizeOf(fuse.InHeader) + name.len] = 0;
    _ = try mount.dispatch(buf[0..header.len]);
}

fn sendForget(mount: *fuse.Mount, ino: u64, nlookup: u64) !void {
    var buf align(8) = [_]u8{0} ** 64;
    const header: *fuse.InHeader = @ptrCast(&buf);
    header.len = @sizeOf(fuse.InHeader) + @sizeOf(fuse.ForgetIn);
    header.opcode = @intFromEnum(fuse.Opcode.forget);
    header.unique = 0;
    header.nodeid = ino;
    const in: *fuse.ForgetIn = @ptrCast(@alignCast(buf[@sizeOf(fuse.InHeader)..].ptr));
    in.* = .{ .nlookup = nlookup };
    _ = try mount.dispatch(buf[0..header.len]);
}

fn sendBatchForget(mount: *fuse.Mount, forgets: []const fuse.ForgetOne, count_override: ?u32) !void {
    var buf align(8) = [_]u8{0} ** 512;
    const header: *fuse.InHeader = @ptrCast(&buf);
    const body_len = @sizeOf(fuse.BatchForgetIn) + forgets.len * @sizeOf(fuse.ForgetOne);
    header.len = @intCast(@sizeOf(fuse.InHeader) + body_len);
    header.opcode = @intFromEnum(fuse.Opcode.batch_forget);
    header.unique = 0;
    header.nodeid = 0;
    const in: *fuse.BatchForgetIn = @ptrCast(@alignCast(buf[@sizeOf(fuse.InHeader)..].ptr));
    in.* = .{ .count = count_override orelse @intCast(forgets.len), .dummy = 0 };
    for (forgets, 0..) |f, i| {
        const one: *fuse.ForgetOne = @ptrCast(@alignCast(buf[@sizeOf(fuse.InHeader) + @sizeOf(fuse.BatchForgetIn) + i * @sizeOf(fuse.ForgetOne) ..].ptr));
        one.* = f;
    }
    _ = try mount.dispatch(buf[0..header.len]);
}

fn sendCreate(mount: *fuse.Mount, parent_ino: u64, name: []const u8) !void {
    var buf align(8) = [_]u8{0} ** 512;
    const header: *fuse.InHeader = @ptrCast(&buf);
    const body_len = @sizeOf(fuse.CreateIn) + name.len + 1;
    header.len = @intCast(@sizeOf(fuse.InHeader) + body_len);
    header.opcode = @intFromEnum(fuse.Opcode.create);
    header.unique = 2;
    header.nodeid = parent_ino;
    const in: *fuse.CreateIn = @ptrCast(@alignCast(buf[@sizeOf(fuse.InHeader)..].ptr));
    in.* = .{ .flags = 0, .mode = 0o644, .umask = 0, .open_flags = 0 };
    @memcpy(buf[@sizeOf(fuse.InHeader) + @sizeOf(fuse.CreateIn) ..][0..name.len], name);
    buf[@sizeOf(fuse.InHeader) + @sizeOf(fuse.CreateIn) + name.len] = 0;
    _ = try mount.dispatch(buf[0..header.len]);
}

fn sendUnlink(mount: *fuse.Mount, parent_ino: u64, name: []const u8) !void {
    var buf align(8) = [_]u8{0} ** 512;
    const header: *fuse.InHeader = @ptrCast(&buf);
    header.len = @intCast(@sizeOf(fuse.InHeader) + name.len + 1);
    header.opcode = @intFromEnum(fuse.Opcode.unlink);
    header.unique = 3;
    header.nodeid = parent_ino;
    @memcpy(buf[@sizeOf(fuse.InHeader)..][0..name.len], name);
    buf[@sizeOf(fuse.InHeader) + name.len] = 0;
    _ = try mount.dispatch(buf[0..header.len]);
}

fn sendRename(mount: *fuse.Mount, old_parent: u64, old_name: []const u8, new_parent: u64, new_name: []const u8) !void {
    var buf align(8) = [_]u8{0} ** 512;
    const header: *fuse.InHeader = @ptrCast(&buf);
    const body_len = @sizeOf(fuse.RenameIn) + old_name.len + 1 + new_name.len + 1;
    header.len = @intCast(@sizeOf(fuse.InHeader) + body_len);
    header.opcode = @intFromEnum(fuse.Opcode.rename);
    header.unique = 4;
    header.nodeid = old_parent;
    const in: *fuse.RenameIn = @ptrCast(@alignCast(buf[@sizeOf(fuse.InHeader)..].ptr));
    in.* = .{ .newdir = new_parent };
    const names = buf[@sizeOf(fuse.InHeader) + @sizeOf(fuse.RenameIn) ..];
    @memcpy(names[0..old_name.len], old_name);
    names[old_name.len] = 0;
    @memcpy(names[old_name.len + 1 ..][0..new_name.len], new_name);
    names[old_name.len + 1 + new_name.len] = 0;
    _ = try mount.dispatch(buf[0..header.len]);
}

fn sendReaddir(mount: *fuse.Mount, dir_ino: u64) !void {
    var buf align(8) = [_]u8{0} ** 128;
    const header: *fuse.InHeader = @ptrCast(&buf);
    header.len = @sizeOf(fuse.InHeader) + @sizeOf(fuse.ReadIn);
    header.opcode = @intFromEnum(fuse.Opcode.readdir);
    header.unique = 5;
    header.nodeid = dir_ino;
    const in: *fuse.ReadIn = @ptrCast(@alignCast(buf[@sizeOf(fuse.InHeader)..].ptr));
    in.* = .{ .fh = 0, .offset = 0, .size = 4096, .read_flags = 0, .lock_owner = 0, .flags = 0, .padding = 0 };
    _ = try mount.dispatch(buf[0..header.len]);
}

fn sendGetattr(mount: *fuse.Mount, ino: u64) !void {
    var buf align(8) = [_]u8{0} ** 64;
    const header: *fuse.InHeader = @ptrCast(&buf);
    header.len = @sizeOf(fuse.InHeader);
    header.opcode = @intFromEnum(fuse.Opcode.getattr);
    header.unique = 6;
    header.nodeid = ino;
    _ = try mount.dispatch(buf[0..header.len]);
}

fn sendRelease(mount: *fuse.Mount, ino: u64, fh: u64) !void {
    var buf align(8) = [_]u8{0} ** 64;
    const header: *fuse.InHeader = @ptrCast(&buf);
    header.len = @sizeOf(fuse.InHeader) + @sizeOf(fuse.ReleaseIn);
    header.opcode = @intFromEnum(fuse.Opcode.release);
    header.unique = 7;
    header.nodeid = ino;
    const in: *fuse.ReleaseIn = @ptrCast(@alignCast(buf[@sizeOf(fuse.InHeader)..].ptr));
    in.* = .{ .fh = fh, .flags = 0, .release_flags = 0, .lock_owner = 0 };
    _ = try mount.dispatch(buf[0..header.len]);
}

test "fuse inodes: 3x LOOKUP of swarm file and FORGET/BATCH_FORGET" {
    if (builtin.os.tag != .linux or builtin.abi.isAndroid()) return;
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

    const source_path = try std.fs.path.join(allocator, &.{ tmp_path, "source.txt" });
    defer allocator.free(source_path);
    try tmp.dir.writeFile(io, .{ .sub_path = "source.txt", .data = "hello world" });
    try swarm.addFile("", "test.txt", source_path);

    var pipe_fds: [2]i32 = undefined;
    _ = std.os.linux.pipe(&pipe_fds);
    defer _ = std.os.linux.close(pipe_fds[0]);

    var mount = try fuse.Mount.init(allocator, null, &store);
    defer mount.deinit();
    mount.swarm = swarm;
    mount.fd = pipe_fds[1];

    try std.testing.expectEqual(@as(usize, 1), mount.table.count());

    // 1. LOOKUP Swarm
    try sendLookup(&mount, fuse.root_id, "Swarm");
    const swarm_ino = mount.table.find(fuse.root_id, "Swarm").?;
    try std.testing.expectEqual(@as(usize, 2), mount.table.count());

    // 2. 3 x LOOKUP of test.txt
    try sendLookup(&mount, swarm_ino, "test.txt");
    const file_ino = mount.table.find(swarm_ino, "test.txt").?;
    try std.testing.expectEqual(@as(usize, 3), mount.table.count());
    try std.testing.expectEqual(@as(u64, 1), mount.table.map.get(file_ino).?.nlookup);

    try sendLookup(&mount, swarm_ino, "test.txt");
    try sendLookup(&mount, swarm_ino, "test.txt");
    try std.testing.expectEqual(@as(u64, 3), mount.table.map.get(file_ino).?.nlookup);

    // 3. FORGET with nlookup = 3 returns count to baseline
    try sendForget(&mount, file_ino, 3);
    try std.testing.expectEqual(@as(usize, 2), mount.table.count());
    try std.testing.expect(mount.table.find(swarm_ino, "test.txt") == null);

    // 4. BATCH_FORGET with 2 entries
    try swarm.addFile("", "test2.txt", source_path);
    try sendLookup(&mount, swarm_ino, "test.txt");
    const ino1 = mount.table.find(swarm_ino, "test.txt").?;
    try sendLookup(&mount, swarm_ino, "test2.txt");
    const ino2 = mount.table.find(swarm_ino, "test2.txt").?;
    try std.testing.expectEqual(@as(usize, 4), mount.table.count());

    const forgets = [_]fuse.ForgetOne{
        .{ .nodeid = ino1, .nlookup = 1 },
        .{ .nodeid = ino2, .nlookup = 1 },
    };
    try sendBatchForget(&mount, &forgets, null);
    try std.testing.expectEqual(@as(usize, 2), mount.table.count());

    // 5. Batch forget with count exceeding body is ignored safely without crash
    try sendBatchForget(&mount, &forgets, 1000);
    try std.testing.expectEqual(@as(usize, 2), mount.table.count());
}

test "fuse inodes: READDIR creates zero inode table entries" {
    if (builtin.os.tag != .linux or builtin.abi.isAndroid()) return;
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

    // Populate manifest with 10 000 synthetic entries directly in manifest
    const cid = [_]u8{0xaa} ** 32;
    for (0..10_000) |i| {
        var name_buf: [32]u8 = undefined;
        const name = try std.fmt.bufPrint(&name_buf, "f{d}.txt", .{i});
        _ = try swarm.manifest.edit(name, .{ .kind = .file, .cid = cid, .size = 100, .mtime = 1000 }, dev_id.bytes, "test");
    }

    var pipe_fds: [2]i32 = undefined;
    _ = std.os.linux.pipe(&pipe_fds);
    defer _ = std.os.linux.close(pipe_fds[0]);

    var mount = try fuse.Mount.init(allocator, null, &store);
    defer mount.deinit();
    mount.swarm = swarm;
    mount.fd = pipe_fds[1];

    try sendLookup(&mount, fuse.root_id, "Swarm");
    const swarm_ino = mount.table.find(fuse.root_id, "Swarm").?;

    const baseline = mount.table.count();
    try std.testing.expectEqual(@as(usize, 2), baseline);

    // READDIR must create 0 table entries
    try sendReaddir(&mount, swarm_ino);
    try std.testing.expectEqual(baseline, mount.table.count());
}

test "fuse inodes: unlink while open retains inode until unpin and separates new creation" {
    if (builtin.os.tag != .linux or builtin.abi.isAndroid()) return;
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

    var pipe_fds: [2]i32 = undefined;
    _ = std.os.linux.pipe(&pipe_fds);
    defer _ = std.os.linux.close(pipe_fds[0]);

    var mount = try fuse.Mount.init(allocator, null, &store);
    defer mount.deinit();
    mount.swarm = swarm;
    mount.fd = pipe_fds[1];

    try sendLookup(&mount, fuse.root_id, "Swarm");
    const swarm_ino = mount.table.find(fuse.root_id, "Swarm").?;

    // 1. CREATE f (handle 1 opened)
    try sendCreate(&mount, swarm_ino, "file_held.txt");
    const ino1 = mount.table.find(swarm_ino, "file_held.txt").?;
    try std.testing.expect(mount.table.map.get(ino1).?.pins > 0);

    // 2. UNLINK f while open
    try sendUnlink(&mount, swarm_ino, "file_held.txt");
    // Name detached, but entry kept alive by handle pin
    try std.testing.expect(mount.table.find(swarm_ino, "file_held.txt") == null);
    try std.testing.expect(mount.table.map.contains(ino1));
    try std.testing.expectEqual(@as(u64, 0), mount.table.map.get(ino1).?.parent);

    // 3. CREATE f again -> returns a DIFFERENT inode number
    try sendCreate(&mount, swarm_ino, "file_held.txt");
    const ino2 = mount.table.find(swarm_ino, "file_held.txt").?;
    try std.testing.expect(ino2 != ino1);
    try std.testing.expect(mount.table.map.contains(ino1));
    try std.testing.expect(mount.table.map.contains(ino2));

    // 4. Release handle for ino1: pins drop to 0, entry survives while nlookup > 0
    try sendRelease(&mount, ino1, 1);
    try std.testing.expect(mount.table.map.contains(ino1));
    // When kernel forgets ino1, it is evicted
    try sendForget(&mount, ino1, 1);
    try std.testing.expect(!mount.table.map.contains(ino1));
    try std.testing.expect(mount.table.map.contains(ino2));
}

test "fuse inodes: interrupted reply undoes ref and evicts inode" {
    if (builtin.os.tag != .linux or builtin.abi.isAndroid()) return;
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

    const source_path = try std.fs.path.join(allocator, &.{ tmp_path, "source.txt" });
    defer allocator.free(source_path);
    try tmp.dir.writeFile(io, .{ .sub_path = "source.txt", .data = "hello" });
    try swarm.addFile("", "interrupted.txt", source_path);

    var pipe_fds: [2]i32 = undefined;
    _ = std.os.linux.pipe(&pipe_fds);
    defer _ = std.os.linux.close(pipe_fds[0]);

    var mount = try fuse.Mount.init(allocator, null, &store);
    defer mount.deinit();
    mount.swarm = swarm;
    mount.fd = pipe_fds[1];

    try sendLookup(&mount, fuse.root_id, "Swarm");
    const swarm_ino = mount.table.find(fuse.root_id, "Swarm").?;
    const baseline = mount.table.count();

    // Hook send to return false (simulating interrupted write / ENOENT)
    const InterruptedHook = struct {
        fn fail(_: *fuse.Mount, _: []const u8) anyerror!bool {
            return false;
        }
    };
    mount.send_hook = InterruptedHook.fail;

    try sendLookup(&mount, swarm_ino, "interrupted.txt");

    // Undelivered reply rolled back lookup count and evicted the node
    try std.testing.expectEqual(baseline, mount.table.count());
    try std.testing.expect(mount.table.find(swarm_ino, "interrupted.txt") == null);
}

test "fuse inodes: rename over existing target preserves target until forgotten" {
    if (builtin.os.tag != .linux or builtin.abi.isAndroid()) return;
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

    const source_path = try std.fs.path.join(allocator, &.{ tmp_path, "source.txt" });
    defer allocator.free(source_path);
    try tmp.dir.writeFile(io, .{ .sub_path = "source.txt", .data = "hello" });
    try swarm.addFile("", "src.txt", source_path);
    try swarm.addFile("", "dst.txt", source_path);

    var pipe_fds: [2]i32 = undefined;
    _ = std.os.linux.pipe(&pipe_fds);
    defer _ = std.os.linux.close(pipe_fds[0]);

    var mount = try fuse.Mount.init(allocator, null, &store);
    defer mount.deinit();
    mount.swarm = swarm;
    mount.fd = pipe_fds[1];

    try sendLookup(&mount, fuse.root_id, "Swarm");
    const swarm_ino = mount.table.find(fuse.root_id, "Swarm").?;

    try sendLookup(&mount, swarm_ino, "dst.txt");
    const dst_ino = mount.table.find(swarm_ino, "dst.txt").?;
    try sendLookup(&mount, swarm_ino, "src.txt");
    const src_ino = mount.table.find(swarm_ino, "src.txt").?;

    // Rename src -> dst over existing target
    try sendRename(&mount, swarm_ino, "src.txt", swarm_ino, "dst.txt");

    // dst now maps to src_ino; target dst_ino is detached but still exists because nlookup == 1
    try std.testing.expectEqual(src_ino, mount.table.find(swarm_ino, "dst.txt").?);
    try std.testing.expect(mount.table.map.contains(dst_ino));
    try std.testing.expectEqual(@as(u64, 0), mount.table.map.get(dst_ino).?.parent);

    // Target still answers GETATTR
    try sendGetattr(&mount, dst_ino);

    // After FORGET, target is evicted
    try sendForget(&mount, dst_ino, 1);
    try std.testing.expect(!mount.table.map.contains(dst_ino));
}

test "fuse inodes: 3-node loopback share walk with FORGET bounds inode table" {
    std.debug.print("\n=== Running Test: fuse inodes: 3-node loopback share walk ===\n", .{});
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const cwd = std.Io.Dir.cwd();

    const owner_dir = "test_fuse_store_owner";
    const reader_dir = "test_fuse_store_reader";
    const folder = "test_fuse_share_folder";
    for ([_][]const u8{ owner_dir, reader_dir, folder }) |d| cwd.deleteTree(io, d) catch {};
    defer for ([_][]const u8{ owner_dir, reader_dir, folder }) |d| cwd.deleteTree(io, d) catch {};

    try cwd.createDirPath(io, folder ++ "/dir1/dir2");
    try cwd.writeFile(io, .{ .sub_path = folder ++ "/root1.txt", .data = "root file 1" });
    try cwd.writeFile(io, .{ .sub_path = folder ++ "/root2.txt", .data = "root file 2" });
    try cwd.writeFile(io, .{ .sub_path = folder ++ "/dir1/f1.txt", .data = "dir1 file 1" });
    try cwd.writeFile(io, .{ .sub_path = folder ++ "/dir1/f2.txt", .data = "dir1 file 2" });
    try cwd.writeFile(io, .{ .sub_path = folder ++ "/dir1/dir2/leaf.txt", .data = "deep file" });

    var owner_store = try StorageEngine.init(allocator, owner_dir);
    defer owner_store.deinit();
    var reader_store = try StorageEngine.init(allocator, reader_dir);
    defer reader_store.deinit();

    var owner = try TestPeer.init(allocator, 13190);
    defer owner.deinit();
    var reader = try TestPeer.init(allocator, 13191);
    defer reader.deinit();

    var owner_dht = DhtNode.init(allocator, owner.manager, owner.config.node.swarm_key);
    defer owner_dht.deinit();
    var reader_dht = DhtNode.init(allocator, reader.manager, reader.config.node.swarm_key);
    defer reader_dht.deinit();
    owner_dht.block_store = &owner_store;
    owner_dht.nickname = "OwnerDevice";
    reader_dht.block_store = &reader_store;

    const index = try fs.ShareIndex.create(allocator, io, &owner_store);
    defer index.destroy();
    try index.add("SharedDocs", folder);
    owner_dht.share_source = index.source();

    owner.manager.setConnectionHandler(&owner_dht, DhtNode.serve);
    reader.manager.setConnectionHandler(&reader_dht, DhtNode.serve);
    defer owner.stop();
    defer reader.stop();
    try owner.start();
    try reader.start();
    nomadfs.sync.sleep(100 * std.time.ns_per_ms);
    {
        const conn = try reader.manager.connectToPeer(owner.listen_addr, reader.config.node.swarm_key, owner.manager.node_id);
        defer conn.deinit();
        try reader_dht.ping(conn);
    }
    nomadfs.sync.sleep(200 * std.time.ns_per_ms);

    const bm = try BlockManager.init(allocator, .{ .network = reader.manager, .dht = &reader_dht, .storage = &reader_store });
    defer bm.deinit();

    var pipe_fds: [2]i32 = undefined;
    _ = std.os.linux.pipe(&pipe_fds);
    defer _ = std.os.linux.close(pipe_fds[0]);

    var mount = try fuse.Mount.init(allocator, bm, &reader_store);
    defer mount.deinit();
    mount.fd = pipe_fds[1];

    // Initial table count has just root (1)
    try std.testing.expectEqual(@as(usize, 1), mount.table.count());

    // 1. LOOKUP device (unpaired devices have fingerprint suffix)
    try sendReaddir(&mount, fuse.root_id);
    // A copy: a refresh may rename the device and free its name.
    const dev_name = try allocator.dupe(u8, mount.devices.items[0].name);
    defer allocator.free(dev_name);
    try sendLookup(&mount, fuse.root_id, dev_name);
    const dev_ino = mount.table.find(fuse.root_id, dev_name).?;
    try std.testing.expectEqual(@as(usize, 2), mount.table.count());

    // 2. LOOKUP share "SharedDocs"
    try sendLookup(&mount, dev_ino, "SharedDocs");
    const share_ino = mount.table.find(dev_ino, "SharedDocs").?;
    try std.testing.expectEqual(@as(usize, 3), mount.table.count());

    // 3. READDIR share: contains root1.txt, root2.txt, dir1
    // READDIR must NOT add any inodes to the table!
    try sendReaddir(&mount, share_ino);
    try std.testing.expectEqual(@as(usize, 3), mount.table.count());

    // 4. LOOKUP "dir1"
    try sendLookup(&mount, share_ino, "dir1");
    const dir1_ino = mount.table.find(share_ino, "dir1").?;
    try std.testing.expectEqual(@as(usize, 4), mount.table.count());

    // 5. READDIR "dir1": contains f1.txt, f2.txt, dir2
    // READDIR must NOT add any inodes to the table!
    try sendReaddir(&mount, dir1_ino);
    try std.testing.expectEqual(@as(usize, 4), mount.table.count());

    // 6. LOOKUP "dir2"
    try sendLookup(&mount, dir1_ino, "dir2");
    const dir2_ino = mount.table.find(dir1_ino, "dir2").?;
    try std.testing.expectEqual(@as(usize, 5), mount.table.count());

    // 7. FORGET dir2
    try sendForget(&mount, dir2_ino, 1);
    try std.testing.expectEqual(@as(usize, 4), mount.table.count());

    // 8. FORGET dir1
    try sendForget(&mount, dir1_ino, 1);
    try std.testing.expectEqual(@as(usize, 3), mount.table.count());

    // 9. FORGET share
    try sendForget(&mount, share_ino, 1);
    try std.testing.expectEqual(@as(usize, 2), mount.table.count());

    // 10. FORGET device
    try sendForget(&mount, dev_ino, 1);
    try std.testing.expectEqual(@as(usize, 1), mount.table.count());
}
