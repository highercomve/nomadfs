//! Writing through the mount, as the kernel drives it: a pool of workers
//! serves requests from a socket, and the test plays the kernel. A write
//! that close() acknowledged must be in the swarm folder afterwards.
const std = @import("std");
const builtin = @import("builtin");
const nomadfs = @import("nomadfs");
const StorageEngine = nomadfs.storage.engine.StorageEngine;
const fs = nomadfs.fs;
const fuse = fs.fuse;
const SwarmFolder = fs.SwarmFolder;
const NodeID = nomadfs.net.id.NodeID;
const sync = nomadfs.sync;
const linux = std.os.linux;

const ENOENT = 2;
const EIO = 5;
const FATTR_MTIME = 1 << 5;

const Reply = struct {
    done: std.atomic.Value(bool) = .init(false),
    err: i32 = 0,
    len: usize = 0,
    bytes: [256]u8 align(8) = undefined,

    fn value(self: *const Reply, comptime T: type, offset: usize) T {
        var v: T = undefined;
        @memcpy(std.mem.asBytes(&v), self.bytes[offset..][0..@sizeOf(T)]);
        return v;
    }
};

/// The kernel's side of the FUSE channel: sends requests, and a reader
/// thread hands each reply to the caller waiting for its `unique`.
const Kernel = struct {
    fd: i32,
    mutex: sync.Mutex = .{},
    next: u64 = 1,
    waiting: [64]?Waiting = [_]?Waiting{null} ** 64,

    const Waiting = struct { unique: u64, reply: *Reply };

    fn readerMain(self: *Kernel) void {
        var buf: [4096]u8 align(8) = undefined;
        while (true) {
            const rc = linux.read(self.fd, &buf, buf.len);
            if (linux.errno(rc) != .SUCCESS or rc < @sizeOf(fuse.OutHeader)) return;
            const out: *const fuse.OutHeader = @ptrCast(&buf);
            self.mutex.lock();
            defer self.mutex.unlock();
            for (&self.waiting) |*slot| {
                const w = slot.* orelse continue;
                if (w.unique != out.unique) continue;
                w.reply.err = -out.@"error";
                w.reply.len = @min(rc - @sizeOf(fuse.OutHeader), w.reply.bytes.len);
                @memcpy(w.reply.bytes[0..w.reply.len], buf[@sizeOf(fuse.OutHeader)..][0..w.reply.len]);
                slot.* = null;
                w.reply.done.store(true, .release);
                break;
            }
        }
    }

    fn send(self: *Kernel, unique: u64, opcode: fuse.Opcode, nodeid: u64, parts: []const []const u8) !void {
        var total: usize = @sizeOf(fuse.InHeader);
        for (parts) |p| total += p.len;
        var header = std.mem.zeroes(fuse.InHeader);
        header.len = @intCast(total);
        header.opcode = @intFromEnum(opcode);
        header.unique = unique;
        header.nodeid = nodeid;
        header.uid = 1000;
        header.gid = 1000;
        header.pid = 1;
        var iov: [4]std.posix.iovec_const = undefined;
        iov[0] = .{ .base = std.mem.asBytes(&header), .len = @sizeOf(fuse.InHeader) };
        for (parts, 1..) |p, i| iov[i] = .{ .base = p.ptr, .len = p.len };
        // One message per request (SEQPACKET), whatever thread sends it.
        const rc = linux.writev(self.fd, &iov, parts.len + 1);
        if (linux.errno(rc) != .SUCCESS or rc != total) return error.SendFailed;
    }

    /// Sends a request and waits for its reply.
    fn call(self: *Kernel, opcode: fuse.Opcode, nodeid: u64, parts: []const []const u8) !Reply {
        var reply: Reply = .{};
        const unique = blk: {
            self.mutex.lock();
            defer self.mutex.unlock();
            const u = self.next;
            self.next += 1;
            for (&self.waiting) |*slot| if (slot.* == null) {
                slot.* = .{ .unique = u, .reply = &reply };
                break :blk u;
            };
            return error.TooManyRequests;
        };
        try self.send(unique, opcode, nodeid, parts);
        var waited: u64 = 0;
        while (!reply.done.load(.acquire)) : (waited += 1) {
            if (waited > 120 * 20_000) return error.NoReply; // two minutes
            sync.sleep(50 * std.time.ns_per_us);
        }
        return reply;
    }

    /// Sends a request nobody waits for: RELEASE (the kernel sends it after
    /// close() has returned) and FORGET (which has no reply).
    fn post(self: *Kernel, opcode: fuse.Opcode, nodeid: u64, parts: []const []const u8) !void {
        const unique = blk: {
            self.mutex.lock();
            defer self.mutex.unlock();
            const u = self.next;
            self.next += 1;
            break :blk u;
        };
        try self.send(unique, opcode, nodeid, parts);
    }

    fn lookup(self: *Kernel, parent: u64, name: []const u8) !?u64 {
        const r = try self.call(.lookup, parent, &.{ name, "\x00" });
        if (r.err == ENOENT) return null;
        if (r.err != 0) return error.LookupFailed;
        return r.value(fuse.EntryOut, 0).nodeid;
    }

    fn mkdir(self: *Kernel, parent: u64, name: []const u8) !u64 {
        const in = fuse.MkdirIn{ .mode = 0o755, .umask = 0 };
        const r = try self.call(.mkdir, parent, &.{ std.mem.asBytes(&in), name, "\x00" });
        if (r.err != 0) return error.MkdirFailed;
        return r.value(fuse.EntryOut, 0).nodeid;
    }

    const Created = struct { err: i32, ino: u64 = 0, fh: u64 = 0 };

    fn create(self: *Kernel, parent: u64, name: []const u8) !Created {
        const in = fuse.CreateIn{ .flags = 0, .mode = 0o644, .umask = 0, .open_flags = 0 };
        const r = try self.call(.create, parent, &.{ std.mem.asBytes(&in), name, "\x00" });
        if (r.err != 0) return .{ .err = r.err };
        return .{ .err = 0, .ino = r.value(fuse.EntryOut, 0).nodeid, .fh = r.value(u64, @sizeOf(fuse.EntryOut)) };
    }

    fn write(self: *Kernel, ino: u64, fh: u64, offset: u64, data: []const u8) !i32 {
        const in = fuse.WriteIn{ .fh = fh, .offset = offset, .size = @intCast(data.len), .write_flags = 0, .lock_owner = 0, .flags = 0, .padding = 0 };
        return (try self.call(.write, ino, &.{ std.mem.asBytes(&in), data })).err;
    }

    /// What close() returns.
    fn flush(self: *Kernel, ino: u64, fh: u64) !i32 {
        const in = extern struct { fh: u64, unused: u32 = 0, padding: u32 = 0, lock_owner: u64 = 0 }{ .fh = fh };
        return (try self.call(.flush, ino, &.{std.mem.asBytes(&in)})).err;
    }

    fn release(self: *Kernel, ino: u64, fh: u64) !void {
        const in = fuse.ReleaseIn{ .fh = fh, .flags = 0, .release_flags = 0, .lock_owner = 0 };
        try self.post(.release, ino, &.{std.mem.asBytes(&in)});
    }

    fn setMtime(self: *Kernel, ino: u64, mtime: u64) !i32 {
        var in = std.mem.zeroes(fuse.SetattrIn);
        in.valid = FATTR_MTIME;
        in.mtime = mtime;
        return (try self.call(.setattr, ino, &.{std.mem.asBytes(&in)})).err;
    }

    fn forget(self: *Kernel, ino: u64) !void {
        const in = fuse.ForgetIn{ .nlookup = 1 };
        try self.post(.forget, ino, &.{std.mem.asBytes(&in)});
    }
};

/// A swarm folder mounted and served by the worker pool.
const Fixture = struct {
    allocator: std.mem.Allocator,
    tmp: std.testing.TmpDir,
    store: StorageEngine,
    swarm: *SwarmFolder,
    mount: fuse.Mount,
    kernel: Kernel,
    runner: std.Thread,
    reader: std.Thread,
    swarm_ino: u64,

    fn init(self: *Fixture) !void {
        const allocator = std.testing.allocator;
        const io = std.Io.Threaded.global_single_threaded.io();
        self.allocator = allocator;
        self.tmp = std.testing.tmpDir(.{});
        var path_buf: [std.fs.max_path_bytes]u8 = undefined;
        const tmp_path = path_buf[0..try self.tmp.dir.realPath(io, &path_buf)];
        const manifest_path = try std.fs.path.join(allocator, &.{ tmp_path, "manifest.json" });
        defer allocator.free(manifest_path);
        self.store = try StorageEngine.init(allocator, tmp_path);
        self.swarm = try SwarmFolder.create(allocator, io, &self.store, .{ .bytes = [_]u8{0x11} ** 32 }, "test", manifest_path);

        var fds: [2]i32 = undefined;
        if (linux.socketpair(linux.AF.UNIX, linux.SOCK.SEQPACKET, 0, &fds) != 0) return error.SocketPairFailed;
        self.mount = try fuse.Mount.init(allocator, null, &self.store);
        self.mount.swarm = self.swarm;
        self.mount.fd = fds[0];
        self.kernel = .{ .fd = fds[1] };
        self.runner = try std.Thread.spawn(.{}, fuse.Mount.run, .{&self.mount});
        self.reader = try std.Thread.spawn(.{}, Kernel.readerMain, .{&self.kernel});
        self.swarm_ino = (try self.kernel.lookup(fuse.root_id, "Swarm")).?;
    }

    fn deinit(self: *Fixture) void {
        // The channel closes: the workers and the reader see the end.
        _ = linux.shutdown(self.kernel.fd, linux.SHUT.RDWR);
        self.runner.join();
        self.reader.join();
        _ = linux.close(self.kernel.fd);
        self.mount.deinit();
        self.swarm.destroy();
        self.store.deinit();
        self.tmp.cleanup();
    }

    /// Waits until every RELEASE sent has been served.
    fn drained(self: *Fixture) !void {
        var waited: u32 = 0;
        while (waited < 60_000) : (waited += 1) {
            {
                self.mount.lock.lock();
                defer self.mount.lock.unlock();
                if (self.mount.handles.count() == 0) return;
            }
            sync.sleep(std.time.ns_per_ms);
        }
        return error.ReleasesStuck;
    }
};

test "fuse write: a save that fails makes close() fail, and the bytes are still saved on a retry" {
    if (builtin.os.tag != .linux or builtin.abi.isAndroid()) return;
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const k = &f.kernel;

    // The folder refuses edits (as after a start without its files, until
    // the first sync): every save fails.
    {
        f.swarm.mutex.lock();
        defer f.swarm.mutex.unlock();
        f.swarm.awaiting_pull = true;
        f.swarm.awaiting_since_ms = sync.monotonicMillis();
    }
    const c = try k.create(f.swarm_ino, "video.mp4");
    try std.testing.expectEqual(@as(i32, 0), c.err);
    const data = [_]u8{0x5a} ** 40_000;
    try std.testing.expectEqual(@as(i32, 0), try k.write(c.ino, c.fh, 0, &data));

    // close(): it either says the file wasn't saved, or the file is there.
    const closed = try k.flush(c.ino, c.fh);
    if (closed == 0) try std.testing.expect(f.swarm.fileInfo("video.mp4") != null);
    try std.testing.expect(closed != 0);
    try std.testing.expect(f.swarm.fileInfo("video.mp4") == null);

    // The folder accepts edits again: the bytes were kept, and the next
    // flush saves them.
    {
        f.swarm.mutex.lock();
        defer f.swarm.mutex.unlock();
        f.swarm.awaiting_pull = false;
    }
    try std.testing.expectEqual(@as(i32, 0), try k.flush(c.ino, c.fh));
    try std.testing.expectEqual(@as(u64, data.len), f.swarm.fileInfo("video.mp4").?.size);
    try k.release(c.ino, c.fh);
    try f.drained();
    try std.testing.expectEqual(@as(u64, data.len), f.swarm.fileInfo("video.mp4").?.size);
}

test "fuse write: a file open in a folder that left the listing is saved, and the folder stays usable" {
    if (builtin.os.tag != .linux or builtin.abi.isAndroid()) return;
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const k = &f.kernel;

    const dir = try k.mkdir(f.swarm_ino, "Album");
    const c = try k.create(dir, "clip.mp4");
    try std.testing.expectEqual(@as(i32, 0), c.err);
    const data = [_]u8{0x33} ** 70_000;
    try std.testing.expectEqual(@as(i32, 0), try k.write(c.ino, c.fh, 0, &data));

    // The folder goes from the manifest while the file is being written
    // (another device, or the app, removed or renamed it), and the kernel
    // looks its name up again, as it does every second.
    try f.swarm.remove("Album");
    _ = try k.lookup(f.swarm_ino, "Album");

    // The next file of the import, created through the folder the kernel
    // still holds.
    const next = try k.create(dir, "photo.jpg");
    try std.testing.expectEqual(@as(i32, 0), next.err);
    try std.testing.expectEqual(@as(i32, 0), try k.write(next.ino, next.fh, 0, data[0..1000]));

    // close() succeeded: both files are in the folder.
    try std.testing.expectEqual(@as(i32, 0), try k.flush(c.ino, c.fh));
    try k.release(c.ino, c.fh);
    try std.testing.expectEqual(@as(i32, 0), try k.flush(next.ino, next.fh));
    try k.release(next.ino, next.fh);
    try std.testing.expectEqual(@as(i32, 0), try k.setMtime(c.ino, 1_500_000_000));
    try f.drained();
    const clip = f.swarm.fileInfo("Album/clip.mp4") orelse return error.FileLost;
    try std.testing.expectEqual(@as(u64, data.len), clip.size);
    try std.testing.expectEqual(@as(u64, 1_500_000_000), clip.mtime);
    try std.testing.expectEqual(@as(u64, 1000), (f.swarm.fileInfo("Album/photo.jpg") orelse return error.FileLost).size);
}

/// One importer: for each file create, write, close, set the time, as
/// `open(O_CREAT|O_EXCL); write; close; utime` reaches the mount.
const Importer = struct {
    f: *Fixture,
    id: usize,
    dirs: [2]u64,
    files: usize,
    failed: std.atomic.Value(u32) = .init(0),

    const dir_names = [2][]const u8{ "Photos", "Videos" };
    const chunk = 64 * 1024;

    fn sizeOf(i: usize) usize {
        return if (i % 5 == 0) 3 * chunk + 123 else 1000 + i;
    }

    fn mtimeOf(self: *const Importer, i: usize) u64 {
        return 1_400_000_000 + self.id * 100_000 + i;
    }

    fn nameOf(self: *const Importer, buf: []u8, i: usize) []const u8 {
        return std.fmt.bufPrint(buf, "imp{d}-{d}.bin", .{ self.id, i }) catch unreachable;
    }

    fn run(self: *Importer) void {
        self.work() catch |err| {
            std.debug.print("importer {d}: {any}\n", .{ self.id, err });
            _ = self.failed.fetchAdd(1, .monotonic);
        };
    }

    fn work(self: *Importer) !void {
        const k = &self.f.kernel;
        var data: [chunk]u8 = undefined;
        @memset(&data, @intCast(0x40 + self.id));
        for (0..self.files) |i| {
            var name_buf: [64]u8 = undefined;
            const name = self.nameOf(&name_buf, i);
            const dir = self.dirs[i % 2];
            if (try k.lookup(dir, name) != null) return error.AlreadyThere;
            const c = try k.create(dir, name);
            if (c.err != 0) return error.CreateFailed;
            var left = sizeOf(i);
            var offset: u64 = 0;
            while (left > 0) {
                const n = @min(left, chunk);
                if (try k.write(c.ino, c.fh, offset, data[0..n]) != 0) return error.WriteFailed;
                offset += n;
                left -= n;
            }
            if (try k.flush(c.ino, c.fh) != 0) return error.CloseFailed;
            // RELEASE is on its way; utime follows without waiting for it,
            // by name (the kernel's entry for it has expired).
            try k.release(c.ino, c.fh);
            const again = (try k.lookup(dir, name)) orelse return error.GoneAfterClose;
            if (try k.setMtime(again, self.mtimeOf(i)) != 0) return error.UtimeFailed;
            try k.forget(again);
            try k.forget(c.ino);
        }
    }
};

/// Another device's edits arriving, and the kernel checking the folders'
/// names again and dropping what it cached, while the import runs.
const Background = struct {
    f: *Fixture,
    stop: std.atomic.Value(bool) = .init(false),
    failed: std.atomic.Value(u32) = .init(0),

    fn remote(self: *Background) void {
        self.remoteWork() catch |err| {
            std.debug.print("remote device: {any}\n", .{err});
            _ = self.failed.fetchAdd(1, .monotonic);
        };
    }

    fn remoteWork(self: *Background) !void {
        const allocator = self.f.allocator;
        var theirs = fs.manifest.Manifest.init(allocator);
        defer theirs.deinit();
        const phone = [_]u8{0x22} ** 32;
        var n: usize = 0;
        while (!self.stop.load(.acquire)) : (n += 1) {
            var path_buf: [64]u8 = undefined;
            const path = try std.fmt.bufPrint(&path_buf, "{s}/phone-{d}.jpg", .{ Importer.dir_names[n % 2], n });
            _ = try theirs.edit(path, .{ .cid = [_]u8{0x77} ** 32, .size = 10, .mtime = 1000 + n }, phone, "phone");
            const bytes = try theirs.encode(allocator);
            defer allocator.free(bytes);
            {
                self.f.swarm.mutex.lock();
                defer self.f.swarm.mutex.unlock();
                if (try self.f.swarm.manifest.mergeEncoded(bytes) > 0) _ = self.f.swarm.generation.fetchAdd(1, .release);
            }
            sync.sleep(2 * std.time.ns_per_ms);
        }
    }

    fn revalidate(self: *Background) void {
        const k = &self.f.kernel;
        while (!self.stop.load(.acquire)) {
            for (Importer.dir_names) |name| {
                const ino = (k.lookup(self.f.swarm_ino, name) catch null) orelse {
                    std.debug.print("folder {s} went missing\n", .{name});
                    _ = self.failed.fetchAdd(1, .monotonic);
                    return;
                };
                k.forget(ino) catch {};
            }
            sync.sleep(std.time.ns_per_ms);
        }
    }
};

test "fuse write: files imported while another device's changes arrive are all in the folder" {
    if (builtin.os.tag != .linux or builtin.abi.isAndroid()) return;
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const k = &f.kernel;

    const dirs = [2]u64{ try k.mkdir(f.swarm_ino, "Photos"), try k.mkdir(f.swarm_ino, "Videos") };
    var background = Background{ .f = &f };
    const remote = try std.Thread.spawn(.{}, Background.remote, .{&background});
    const revalidate = try std.Thread.spawn(.{}, Background.revalidate, .{&background});

    var importers: [4]Importer = undefined;
    var threads: [4]std.Thread = undefined;
    for (&importers, 0..) |*imp, id| imp.* = .{ .f = &f, .id = id, .dirs = dirs, .files = 40 };
    for (&importers, &threads) |*imp, *t| t.* = try std.Thread.spawn(.{}, Importer.run, .{imp});
    for (threads) |t| t.join();
    background.stop.store(true, .release);
    remote.join();
    revalidate.join();
    try f.drained();

    try std.testing.expectEqual(@as(u32, 0), background.failed.load(.monotonic));
    for (&importers) |*imp| {
        try std.testing.expectEqual(@as(u32, 0), imp.failed.load(.monotonic));
        for (0..imp.files) |i| {
            var name_buf: [64]u8 = undefined;
            var path_buf: [128]u8 = undefined;
            const path = try std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ Importer.dir_names[i % 2], imp.nameOf(&name_buf, i) });
            const info = f.swarm.fileInfo(path) orelse {
                std.debug.print("lost: {s}\n", .{path});
                return error.FileLost;
            };
            try std.testing.expectEqual(@as(u64, Importer.sizeOf(i)), info.size);
            try std.testing.expectEqual(imp.mtimeOf(i), info.mtime);
        }
    }
}

test "fuse write: an import that outruns the saves loses nothing when descriptors are scarce" {
    if (builtin.os.tag != .linux or builtin.abi.isAndroid()) return;
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const k = &f.kernel;
    const dir = try k.mkdir(f.swarm_ino, "Takeout");

    // Room for a few dozen more descriptors, as a busy node has left of its
    // 1024: each file waiting to be saved holds one.
    var old: linux.rlimit = undefined;
    try std.testing.expectEqual(@as(usize, 0), linux.getrlimit(.NOFILE, &old));
    const probe = linux.open("/dev/null", .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
    try std.testing.expect(linux.errno(probe) == .SUCCESS);
    _ = linux.close(@intCast(probe));
    const tight = linux.rlimit{ .cur = @min(old.cur, probe + 14), .max = old.max };
    try std.testing.expectEqual(@as(usize, 0), linux.setrlimit(.NOFILE, &tight));
    defer _ = linux.setrlimit(.NOFILE, &old);

    const files = 300;
    var data: [64 * 1024]u8 = undefined;
    @memset(&data, 0x6b);
    var acknowledged = [_]bool{false} ** files;
    var refused: usize = 0;
    for (0..files) |i| {
        var name_buf: [32]u8 = undefined;
        const name = try std.fmt.bufPrint(&name_buf, "v{d}.mp4", .{i});
        const c = try k.create(dir, name);
        if (c.err != 0) {
            refused += 1;
            continue;
        }
        var ok = true;
        for (0..16) |n| ok = (try k.write(c.ino, c.fh, n * data.len, &data)) == 0 and ok;
        ok = (try k.flush(c.ino, c.fh)) == 0 and ok;
        try k.release(c.ino, c.fh);
        ok = (try k.setMtime(c.ino, 1_600_000_000 + i)) == 0 and ok;
        acknowledged[i] = ok;
    }
    try f.drained();
    _ = linux.setrlimit(.NOFILE, &old);

    // Whatever the writer was told is saved, is.
    var lost: usize = 0;
    for (acknowledged, 0..) |ok, i| {
        if (!ok) continue;
        var path_buf: [48]u8 = undefined;
        const path = try std.fmt.bufPrint(&path_buf, "Takeout/v{d}.mp4", .{i});
        const info = f.swarm.fileInfo(path) orelse {
            lost += 1;
            continue;
        };
        try std.testing.expectEqual(@as(u64, 16 * data.len), info.size);
        try std.testing.expectEqual(@as(u64, 1_600_000_000 + i), info.mtime);
    }
    if (lost > 0 or refused > 0) std.debug.print("{d} files lost after a successful close, {d} creates refused\n", .{ lost, refused });
    try std.testing.expectEqual(@as(usize, 0), lost);
    // close() waits for the save now, so files no longer pile up waiting
    // and the creates aren't refused either.
    try std.testing.expectEqual(@as(usize, 0), refused);
}
