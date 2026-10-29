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
const sync = nomadfs.sync;

fn writeReq(fd: i32, opcode: fuse.Opcode, unique: u64, nodeid: u64, body: []const u8) !void {
    var buf align(8) = [_]u8{0} ** 4096;
    const header: *fuse.InHeader = @ptrCast(&buf);
    header.len = @intCast(@sizeOf(fuse.InHeader) + body.len);
    header.opcode = @intFromEnum(opcode);
    header.unique = unique;
    header.nodeid = nodeid;
    header.uid = 1000;
    header.gid = 1000;
    header.pid = 1;
    header.total_extlen = 0;
    header.padding = 0;
    if (body.len > 0) {
        @memcpy(buf[@sizeOf(fuse.InHeader)..][0..body.len], body);
    }
    const rc = std.os.linux.write(fd, &buf, header.len);
    if (std.os.linux.errno(rc) != .SUCCESS or rc != header.len) return error.WriteFailed;
}

fn readReply(fd: i32, out_buf: []align(8) u8) !usize {
    const rc = std.os.linux.read(fd, out_buf.ptr, out_buf.len);
    if (std.os.linux.errno(rc) != .SUCCESS) return error.ReadFailed;
    return @intCast(rc);
}

fn dummyInodeEq(_: fuse.Inode, _: fuse.Inode) bool {
    return true;
}

test "fuse mt: stalled network op does not block other ops" {
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

    var fds: [2]i32 = undefined;
    if (std.os.linux.socketpair(std.os.linux.AF.UNIX, std.os.linux.SOCK.SEQPACKET, 0, &fds) != 0) return error.SocketPairFailed;

    var mount = try fuse.Mount.init(allocator, null, &store);
    defer mount.deinit();
    mount.swarm = swarm;
    mount.fd = fds[0];

    // Create a fake device with a remote file inode (mount.deinit owns remote_peer)
    const remote_peer = try allocator.create(fuse.Remote);
    // No block manager: reads of this device fail at once (error.PeerDown).
    remote_peer.* = .{
        .block_manager = null,
        .peer = NodeID{ .bytes = [_]u8{0x22} ** 32 },
    };
    try mount.devices.append(allocator, .{
        .name = try allocator.dupe(u8, "RemoteDev"),
        .remote = remote_peer,
        .online = true,
        .last_seen_ms = sync.monotonicMillis(),
    });

    const file_ino = try mount.table.getOrCreate(fuse.root_id, "remote_file", .{
        .kind = .file,
        .device = 0,
        .cid = [_]u8{0x33} ** 32,
        .size = 1024,
        .mtime = 100,
    }, dummyInodeEq);

    const BlockHook = struct {
        mutex: sync.Mutex = .{},
        cond: sync.Condition = .{},
        blocked: bool = false,
        release: bool = false,

        fn hook(ctx: ?*anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            self.mutex.lock();
            self.blocked = true;
            self.cond.signal();
            while (!self.release) {
                self.cond.wait(&self.mutex);
            }
            self.mutex.unlock();
        }
    };

    var block_hook = BlockHook{};
    mount.hooks = .{
        .before_network = BlockHook.hook,
        .ctx = &block_hook,
    };

    const runner = try std.Thread.spawn(.{}, fuse.Mount.run, .{&mount});

    // Send INIT first so mount initializes session
    var init_in = [_]u8{0} ** 56;
    std.mem.writeInt(u32, init_in[0..4], 7, .little); // major
    std.mem.writeInt(u32, init_in[4..8], 31, .little); // minor
    try writeReq(fds[1], .init, 1, 0, &init_in);

    var rep_buf align(8) = [_]u8{0} ** 4096;
    _ = try readReply(fds[1], &rep_buf);

    // 1. Send READ for remote_file (unique = 10). It will hit the hook and block!
    var read_in = fuse.ReadIn{
        .fh = 0,
        .offset = 0,
        .size = 128,
        .read_flags = 0,
        .lock_owner = 0,
        .flags = 0,
        .padding = 0,
    };
    try writeReq(fds[1], .read, 10, file_ino, std.mem.asBytes(&read_in));

    // Wait until worker is blocked in hook
    block_hook.mutex.lock();
    while (!block_hook.blocked) block_hook.cond.wait(&block_hook.mutex);
    block_hook.mutex.unlock();

    // 2. While READ is blocked, send GETATTR, STATFS, LOOKUP on Swarm, and READDIR on root!
    try writeReq(fds[1], .getattr, 20, fuse.root_id, &.{});
    try writeReq(fds[1], .statfs, 30, fuse.root_id, &.{});
    try writeReq(fds[1], .lookup, 40, fuse.root_id, "Swarm\x00");
    var rdir_in = fuse.ReadIn{
        .fh = 0,
        .offset = 0,
        .size = 4096,
        .read_flags = 0,
        .lock_owner = 0,
        .flags = 0,
        .padding = 0,
    };
    try writeReq(fds[1], .readdir, 50, fuse.root_id, std.mem.asBytes(&rdir_in));

    // All 4 requests must reply promptly within 1s while READ is still blocked
    var received_uniques = std.AutoHashMap(u64, void).init(allocator);
    defer received_uniques.deinit();

    var i: usize = 0;
    while (i < 4) : (i += 1) {
        const n = try readReply(fds[1], &rep_buf);
        try std.testing.expect(n >= @sizeOf(fuse.OutHeader));
        const out: *const fuse.OutHeader = @ptrCast(&rep_buf);
        try received_uniques.put(out.unique, {});
    }

    try std.testing.expect(received_uniques.contains(20));
    try std.testing.expect(received_uniques.contains(30));
    try std.testing.expect(received_uniques.contains(40));
    try std.testing.expect(received_uniques.contains(50));
    try std.testing.expect(!received_uniques.contains(10)); // READ still blocked!

    // Now unblock the READ
    block_hook.mutex.lock();
    block_hook.release = true;
    block_hook.cond.signal();
    block_hook.mutex.unlock();

    // Read reply for unique 10 arrives (returns error since remote dial isn't mocked, but arrives!)
    const n = try readReply(fds[1], &rep_buf);
    try std.testing.expect(n >= @sizeOf(fuse.OutHeader));
    const out: *const fuse.OutHeader = @ptrCast(&rep_buf);
    try std.testing.expectEqual(@as(u64, 10), out.unique);

    // Shutdown
    _ = std.os.linux.close(fds[1]);
    runner.join();
}

test "fuse mt: out-of-order replies match by unique" {
    if (builtin.os.tag != .linux or builtin.abi.isAndroid()) return;
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var store_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmp_path = store_path_buf[0..try tmp.dir.realPath(io, &store_path_buf)];

    var store = try StorageEngine.init(allocator, tmp_path);
    defer store.deinit();

    var fds: [2]i32 = undefined;
    if (std.os.linux.socketpair(std.os.linux.AF.UNIX, std.os.linux.SOCK.SEQPACKET, 0, &fds) != 0) return error.SocketPairFailed;

    var mount = try fuse.Mount.init(allocator, null, &store);
    defer mount.deinit();
    mount.fd = fds[0];

    const remote_peer = try allocator.create(fuse.Remote);
    remote_peer.* = .{
        .block_manager = null,
        .peer = NodeID{ .bytes = [_]u8{0x44} ** 32 },
    };
    try mount.devices.append(allocator, .{
        .name = try allocator.dupe(u8, "RemoteDev"),
        .remote = remote_peer,
        .online = true,
        .last_seen_ms = sync.monotonicMillis(),
    });

    const file_ino = try mount.table.getOrCreate(fuse.root_id, "rf", .{
        .kind = .file,
        .device = 0,
        .cid = [_]u8{0x55} ** 32,
        .size = 1024,
        .mtime = 100,
    }, dummyInodeEq);

    const ReleaseControl = struct {
        mutex: sync.Mutex = .{},
        cond: sync.Condition = .{},
        entered: u32 = 0,
        allowed_id: ?u64 = null,

        fn hook(ctx: ?*anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            self.mutex.lock();
            self.entered += 1;
            self.cond.broadcast();
            while (self.allowed_id == null) {
                self.cond.wait(&self.mutex);
            }
            self.allowed_id = null;
            self.mutex.unlock();
        }
    };

    var ctrl = ReleaseControl{};
    mount.hooks = .{
        .before_network = ReleaseControl.hook,
        .ctx = &ctrl,
    };

    const runner = try std.Thread.spawn(.{}, fuse.Mount.run, .{&mount});

    // Send INIT
    var init_in = [_]u8{0} ** 56;
    std.mem.writeInt(u32, init_in[0..4], 7, .little);
    std.mem.writeInt(u32, init_in[4..8], 31, .little);
    try writeReq(fds[1], .init, 1, 0, &init_in);
    var rep_buf align(8) = [_]u8{0} ** 4096;
    _ = try readReply(fds[1], &rep_buf);

    var read_in = fuse.ReadIn{
        .fh = 0,
        .offset = 0,
        .size = 64,
        .read_flags = 0,
        .lock_owner = 0,
        .flags = 0,
        .padding = 0,
    };

    // Send requests 101, 102, 103
    try writeReq(fds[1], .read, 101, file_ino, std.mem.asBytes(&read_in));
    try writeReq(fds[1], .read, 102, file_ino, std.mem.asBytes(&read_in));
    try writeReq(fds[1], .read, 103, file_ino, std.mem.asBytes(&read_in));

    ctrl.mutex.lock();
    while (ctrl.entered < 3) ctrl.cond.wait(&ctrl.mutex);
    ctrl.mutex.unlock();

    // Release one by one
    ctrl.mutex.lock();
    ctrl.allowed_id = 1;
    ctrl.cond.signal();
    ctrl.mutex.unlock();

    const n1 = try readReply(fds[1], &rep_buf);
    try std.testing.expect(n1 >= @sizeOf(fuse.OutHeader));

    ctrl.mutex.lock();
    ctrl.allowed_id = 2;
    ctrl.cond.signal();
    ctrl.mutex.unlock();

    const n2 = try readReply(fds[1], &rep_buf);
    try std.testing.expect(n2 >= @sizeOf(fuse.OutHeader));

    ctrl.mutex.lock();
    ctrl.allowed_id = 3;
    ctrl.cond.signal();
    ctrl.mutex.unlock();

    const n3 = try readReply(fds[1], &rep_buf);
    try std.testing.expect(n3 >= @sizeOf(fuse.OutHeader));

    _ = std.os.linux.close(fds[1]);
    runner.join();
}

test "fuse mt: pool growth up to worker_max" {
    if (builtin.os.tag != .linux or builtin.abi.isAndroid()) return;
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var store_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmp_path = store_path_buf[0..try tmp.dir.realPath(io, &store_path_buf)];

    var store = try StorageEngine.init(allocator, tmp_path);
    defer store.deinit();

    var fds: [2]i32 = undefined;
    if (std.os.linux.socketpair(std.os.linux.AF.UNIX, std.os.linux.SOCK.SEQPACKET, 0, &fds) != 0) return error.SocketPairFailed;

    var mount = try fuse.Mount.init(allocator, null, &store);
    defer mount.deinit();
    mount.fd = fds[0];

    const remote_peer = try allocator.create(fuse.Remote);
    remote_peer.* = .{
        .block_manager = null,
        .peer = NodeID{ .bytes = [_]u8{0x66} ** 32 },
    };
    try mount.devices.append(allocator, .{
        .name = try allocator.dupe(u8, "RemoteDev"),
        .remote = remote_peer,
        .online = true,
        .last_seen_ms = sync.monotonicMillis(),
    });

    const file_ino = try mount.table.getOrCreate(fuse.root_id, "rf", .{
        .kind = .file,
        .device = 0,
        .cid = [_]u8{0x77} ** 32,
        .size = 1024,
        .mtime = 100,
    }, dummyInodeEq);

    const Gate = struct {
        mutex: sync.Mutex = .{},
        cond: sync.Condition = .{},
        active: u32 = 0,
        release: bool = false,

        fn hook(ctx: ?*anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            self.mutex.lock();
            self.active += 1;
            self.cond.broadcast();
            while (!self.release) {
                self.cond.wait(&self.mutex);
            }
            self.mutex.unlock();
        }
    };

    var gate = Gate{};
    mount.hooks = .{
        .before_network = Gate.hook,
        .ctx = &gate,
    };

    const runner = try std.Thread.spawn(.{}, fuse.Mount.run, .{&mount});

    // INIT
    var init_in = [_]u8{0} ** 56;
    std.mem.writeInt(u32, init_in[0..4], 7, .little);
    std.mem.writeInt(u32, init_in[4..8], 31, .little);
    try writeReq(fds[1], .init, 1, 0, &init_in);
    var rep_buf align(8) = [_]u8{0} ** 4096;
    _ = try readReply(fds[1], &rep_buf);

    var read_in = fuse.ReadIn{
        .fh = 0,
        .offset = 0,
        .size = 64,
        .read_flags = 0,
        .lock_owner = 0,
        .flags = 0,
        .padding = 0,
    };

    // Send 20 requests
    for (0..20) |i| {
        try writeReq(fds[1], .read, 200 + i, file_ino, std.mem.asBytes(&read_in));
    }

    // Wait until 16 workers enter the hook
    gate.mutex.lock();
    while (gate.active < 16) {
        gate.cond.wait(&gate.mutex);
    }
    gate.mutex.unlock();

    // Pool count must be exactly worker_max (16)
    mount.pool.mutex.lock();
    const count = mount.pool.count;
    mount.pool.mutex.unlock();
    try std.testing.expectEqual(@as(u32, 16), count);

    // Release all
    gate.mutex.lock();
    gate.release = true;
    gate.cond.broadcast();
    gate.mutex.unlock();

    // Read all 20 replies
    for (0..20) |_| {
        _ = try readReply(fds[1], &rep_buf);
    }

    _ = std.os.linux.close(fds[1]);
    runner.join();
}

test "fuse mt: clean shutdown and leak free" {
    if (builtin.os.tag != .linux or builtin.abi.isAndroid()) return;
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var store_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmp_path = store_path_buf[0..try tmp.dir.realPath(io, &store_path_buf)];

    var store = try StorageEngine.init(allocator, tmp_path);
    defer store.deinit();

    var fds: [2]i32 = undefined;
    if (std.os.linux.socketpair(std.os.linux.AF.UNIX, std.os.linux.SOCK.SEQPACKET, 0, &fds) != 0) return error.SocketPairFailed;

    var mount = try fuse.Mount.init(allocator, null, &store);
    defer mount.deinit();
    mount.fd = fds[0];

    const runner = try std.Thread.spawn(.{}, fuse.Mount.run, .{&mount});

    // Close socket: EOF causes workers to terminate
    _ = std.os.linux.close(fds[1]);
    runner.join();
}

test "fuse mt: atomic writer check (16 concurrent writers)" {
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

    const file_path = try std.fs.path.join(allocator, &.{ tmp_path, "shared.txt" });
    defer allocator.free(file_path);
    try tmp.dir.writeFile(io, .{ .sub_path = "shared.txt", .data = "initial content" });
    try swarm.addFile("", "shared.txt", file_path);

    var mount = try fuse.Mount.init(allocator, null, &store);
    defer mount.deinit();
    mount.swarm = swarm;

    const swarm_ino = try mount.table.getOrCreate(fuse.root_id, "Swarm", .{
        .kind = .swarm_dir,
        .mtime = 100,
    }, dummyInodeEq);
    const file_ino = try mount.table.getOrCreate(swarm_ino, "shared.txt", .{
        .kind = .swarm_file,
        .size = 15,
        .mtime = 100,
        .author = dev_id.bytes,
    }, dummyInodeEq);

    const Opener = struct {
        mount: *fuse.Mount,
        ino: u64,
        succeeded: std.atomic.Value(u32) = .init(0),
        busy: std.atomic.Value(u32) = .init(0),
        barrier: sync.WaitGroup = .{},

        fn run(self: *@This()) void {
            self.barrier.wait();
            const node = self.mount.table.map.get(self.ino).?.data;
            if (self.mount.openForWrite(self.ino, node, true)) |_| {
                _ = self.succeeded.fetchAdd(1, .monotonic);
            } else |err| {
                if (err == error.DeviceOrResourceBusy) {
                    _ = self.busy.fetchAdd(1, .monotonic);
                }
            }
        }
    };

    var opener = Opener{ .mount = &mount, .ino = file_ino };
    opener.barrier.start();

    var threads: [16]std.Thread = undefined;
    for (0..16) |i| {
        threads[i] = try std.Thread.spawn(.{}, Opener.run, .{&opener});
    }

    // Release all 16 simultaneously
    opener.barrier.finish();

    for (0..16) |i| {
        threads[i].join();
    }

    try std.testing.expectEqual(@as(u32, 1), opener.succeeded.load(.monotonic));
    try std.testing.expectEqual(@as(u32, 15), opener.busy.load(.monotonic));
}
