//! Read-only FUSE mount of every reachable device's shares (Linux):
//!
//!   <mountpoint>/<device>/<share>/<path...>
//!
//! Speaks the kernel's FUSE protocol directly on /dev/fuse, so neither
//! libfuse nor libc is needed. The device is mounted the unprivileged way:
//! fusermount3 opens /dev/fuse, mounts it and hands the descriptor back over
//! a socketpair (_FUSE_COMMFD).
//!
//! Directory listings load one dir block; reads load only the blocks that
//! cover the requested range (tree.readAt). Fetched blocks stay in the local
//! store, so whatever was opened once keeps working offline.

const std = @import("std");
const linux = std.os.linux;
const NodeID = @import("../net/id.zig").NodeID;
const cluster = @import("../cluster/mod.zig");
const storage = @import("../storage/mod.zig");
const tree = @import("tree.zig");
const remote_mod = @import("remote.zig");
const swarm_mod = @import("swarm.zig");
const manifest_mod = @import("manifest.zig");
const Remote = remote_mod.Remote;

// ---- Kernel protocol (include/uapi/linux/fuse.h) ----

const kernel_major = 7;
const kernel_minor = 31;
const root_id = 1;

const Opcode = enum(u32) {
    lookup = 1,
    forget = 2,
    getattr = 3,
    setattr = 4,
    mkdir = 9,
    unlink = 10,
    rmdir = 11,
    rename = 12,
    open = 14,
    read = 15,
    write = 16,
    statfs = 17,
    release = 18,
    fsync = 20,
    getxattr = 22,
    listxattr = 23,
    flush = 25,
    init = 26,
    opendir = 27,
    readdir = 28,
    releasedir = 29,
    access = 34,
    create = 35,
    interrupt = 36,
    destroy = 38,
    batch_forget = 42,
    rename2 = 45,
    _,
};

// Write side (only the swarm folder is writable).
const CreateIn = extern struct { flags: u32, mode: u32, umask: u32, open_flags: u32 };
const WriteIn = extern struct { fh: u64, offset: u64, size: u32, write_flags: u32, lock_owner: u64, flags: u32, padding: u32 };
const WriteOut = extern struct { size: u32, padding: u32 = 0 };
const SetattrIn = extern struct {
    valid: u32,
    padding: u32,
    fh: u64,
    size: u64,
    lock_owner: u64,
    atime: u64,
    mtime: u64,
    ctime: u64,
    atimensec: u32,
    mtimensec: u32,
    ctimensec: u32,
    mode: u32,
    unused4: u32,
    uid: u32,
    gid: u32,
    unused5: u32,
};
const MkdirIn = extern struct { mode: u32, umask: u32 };
const RenameIn = extern struct { newdir: u64 };
const Rename2In = extern struct { newdir: u64, flags: u32, padding: u32 };
const ReleaseIn = extern struct { fh: u64, flags: u32, release_flags: u32, lock_owner: u64 };

const FATTR_SIZE = 1 << 3;
const FATTR_FH = 1 << 6;
const O_TRUNC = 0o1000;
const FUSE_ATOMIC_O_TRUNC = 1 << 3;
const FUSE_BIG_WRITES = 1 << 5;
const max_write = 128 * 1024;

const InHeader = extern struct {
    len: u32,
    opcode: u32,
    unique: u64,
    nodeid: u64,
    uid: u32,
    gid: u32,
    pid: u32,
    total_extlen: u16,
    padding: u16,
};

const OutHeader = extern struct {
    len: u32,
    @"error": i32,
    unique: u64,
};

const Attr = extern struct {
    ino: u64,
    size: u64,
    blocks: u64,
    atime: u64,
    mtime: u64,
    ctime: u64,
    atimensec: u32 = 0,
    mtimensec: u32 = 0,
    ctimensec: u32 = 0,
    mode: u32,
    nlink: u32,
    uid: u32,
    gid: u32,
    rdev: u32 = 0,
    blksize: u32 = 4096,
    flags: u32 = 0,
};

const EntryOut = extern struct {
    nodeid: u64,
    generation: u64 = 0,
    entry_valid: u64,
    attr_valid: u64,
    entry_valid_nsec: u32 = 0,
    attr_valid_nsec: u32 = 0,
    attr: Attr,
};

const AttrOut = extern struct {
    attr_valid: u64,
    attr_valid_nsec: u32 = 0,
    dummy: u32 = 0,
    attr: Attr,
};

const InitIn = extern struct {
    major: u32,
    minor: u32,
    max_readahead: u32,
    flags: u32,
};

const InitOut = extern struct {
    major: u32,
    minor: u32,
    max_readahead: u32,
    flags: u32,
    max_background: u16 = 0,
    congestion_threshold: u16 = 0,
    max_write: u32,
    time_gran: u32 = 1,
    max_pages: u16 = 0,
    map_alignment: u16 = 0,
    flags2: u32 = 0,
    unused: [7]u32 = .{0} ** 7,
};

const OpenIn = extern struct {
    flags: u32,
    open_flags: u32,
};

const OpenOut = extern struct {
    fh: u64 = 0,
    open_flags: u32 = 0,
    padding: u32 = 0,
};

const ReadIn = extern struct {
    fh: u64,
    offset: u64,
    size: u32,
    read_flags: u32,
    lock_owner: u64,
    flags: u32,
    padding: u32,
};

const AccessIn = extern struct {
    mask: u32,
    padding: u32,
};

const Dirent = extern struct {
    ino: u64,
    off: u64,
    namelen: u32,
    type: u32,
};

const StatfsOut = extern struct {
    blocks: u64 = 0,
    bfree: u64 = 0,
    bavail: u64 = 0,
    files: u64 = 0,
    ffree: u64 = 0,
    bsize: u32 = 4096,
    namelen: u32 = 255,
    frsize: u32 = 4096,
    padding: u32 = 0,
    spare: [6]u32 = .{0} ** 6,
};

comptime {
    std.debug.assert(@sizeOf(InHeader) == 40);
    std.debug.assert(@sizeOf(Attr) == 88);
    std.debug.assert(@sizeOf(EntryOut) == 128);
    std.debug.assert(@sizeOf(InitOut) == 64);
    std.debug.assert(@sizeOf(StatfsOut) == 80);
    std.debug.assert(@sizeOf(CreateIn) == 16);
    std.debug.assert(@sizeOf(WriteIn) == 40);
    std.debug.assert(@sizeOf(SetattrIn) == 88);
    std.debug.assert(@sizeOf(ReleaseIn) == 24);
}

const S_IFDIR = 0o040000;
const S_IFREG = 0o100000;
const DT_DIR = 4;
const DT_REG = 8;
const W_OK = 2;
const O_ACCMODE = 3;

const Errno = enum(i32) {
    NOENT = 2,
    IO = 5,
    BADF = 9,
    ACCES = 13,
    NOTDIR = 20,
    ISDIR = 21,
    BUSY = 16,
    EXIST = 17,
    XDEV = 18,
    INVAL = 22,
    ROFS = 30,
    NAMETOOLONG = 36,
    NOSYS = 38,
    NOTEMPTY = 39,
};

/// Seconds the kernel may cache names and attributes. Short, because a
/// share's content changes whenever its folder does.
const cache_seconds = 1;
/// How long a device list stays fresh before peers are asked again.
const device_refresh_ns = 5 * std.time.ns_per_s;
/// Large enough for any request a read-only mount receives.
const request_buffer_len = 1024 * 1024 + 4096;

// ---- Filesystem state ----

const Kind = enum {
    root,
    device,
    dir,
    file,
    /// The swarm folder (Swarm/ and folders inside it) and its files.
    swarm_dir,
    swarm_file,

    fn isFile(k: Kind) bool {
        return k == .file or k == .swarm_file;
    }
};

const Inode = struct {
    kind: Kind,
    /// Index into Mount.devices (device, dir and file inodes).
    device: u32 = 0,
    cid: tree.Cid = undefined,
    size: u64 = 0,
    mtime: u64 = 0,
    /// Swarm inodes: path inside the swarm folder (owned by path_arena)
    /// and the device that added the file.
    swarm_path: []const u8 = "",
    author: [32]u8 = [_]u8{0} ** 32,
};

/// A swarm file open for writing: bytes go to a staging file and are added
/// to the swarm folder on release.
const Handle = struct {
    ino: u64,
    /// Path inside the swarm folder (owned).
    path: []u8,
    /// Staging file (owned, NUL-terminated for open(2)).
    staging: [:0]u8,
    fd: i32,
    dirty: bool,
};

const Device = struct {
    name: []u8,
    remote: *Remote,
    shares: ?tree.Listing = null,
    online: bool = false,
};

pub const Mount = struct {
    allocator: std.mem.Allocator,
    block_manager: *cluster.BlockManager,
    store: *storage.engine.StorageEngine,
    fd: i32 = -1,
    uid: u32,
    gid: u32,
    /// inode number - 1 -> inode. Inodes are never reused while mounted.
    inodes: std.ArrayList(Inode) = .empty,
    /// (parent inode, name) -> inode number, so a path keeps its inode.
    children: std.StringHashMapUnmanaged(u64) = .empty,
    devices: std.ArrayList(Device) = .empty,
    devices_refreshed_ns: i96 = 0,
    request: []align(8) u8 = &.{},
    /// Shown as the mtime of the root and device folders.
    mounted_at: u64 = 0,
    /// The swarm folder, shown as <mount>/Swarm when set.
    swarm: ?*swarm_mod.SwarmFolder = null,
    /// Swarm paths held by inodes.
    path_arena: std.heap.ArenaAllocator,
    /// Open write handles on swarm files: fh -> handle.
    handles: std.AutoHashMapUnmanaged(u64, Handle) = .empty,
    /// Inode -> the fh writing it, so reads see unsaved bytes.
    writing: std.AutoHashMapUnmanaged(u64, u64) = .empty,
    next_fh: u64 = 1,
    reply: std.ArrayList(u8) = .empty,

    pub fn init(allocator: std.mem.Allocator, block_manager: *cluster.BlockManager, store: *storage.engine.StorageEngine) !Mount {
        var self = Mount{
            .path_arena = std.heap.ArenaAllocator.init(allocator),
            .allocator = allocator,
            .block_manager = block_manager,
            .store = store,
            .uid = linux.getuid(),
            .gid = linux.getgid(),
        };
        const now = std.Io.Timestamp.now(std.Io.Threaded.global_single_threaded.io(), .real).nanoseconds;
        self.mounted_at = @intCast(@max(0, @divFloor(now, std.time.ns_per_s)));
        try self.inodes.append(allocator, .{ .kind = .root, .mtime = self.mounted_at });
        self.request = try allocator.alignedAlloc(u8, .@"8", request_buffer_len);
        return self;
    }

    pub fn deinit(self: *Mount) void {
        if (self.fd >= 0) _ = linux.close(self.fd);
        var hit = self.handles.valueIterator();
        while (hit.next()) |h| self.dropHandle(h.*);
        self.handles.deinit(self.allocator);
        self.writing.deinit(self.allocator);
        self.path_arena.deinit();
        var it = self.children.keyIterator();
        while (it.next()) |k| self.allocator.free(k.*);
        self.children.deinit(self.allocator);
        for (self.devices.items) |d| {
            self.allocator.free(d.name);
            if (d.shares) |s| s.deinit();
            self.allocator.destroy(d.remote);
        }
        self.devices.deinit(self.allocator);
        self.inodes.deinit(self.allocator);
        self.allocator.free(self.request);
        self.reply.deinit(self.allocator);
    }

    /// Mounts at `mountpoint` and serves requests until it is unmounted
    /// (fusermount3 -u, or `unmount`).
    pub fn serve(self: *Mount, mountpoint: []const u8) !void {
        self.fd = try mountWithFusermount(self.allocator, mountpoint);
        while (true) {
            const rc = linux.read(self.fd, self.request.ptr, self.request.len);
            switch (linux.errno(rc)) {
                .SUCCESS => {},
                // Interrupted, or the request was aborted before we read it.
                .INTR, .NOENT, .AGAIN => continue,
                // Unmounted.
                .NODEV => return,
                else => |e| {
                    std.debug.print("fuse: read failed: {s}\n", .{@tagName(e)});
                    return error.FuseReadFailed;
                },
            }
            if (rc < @sizeOf(InHeader)) continue;
            const done = self.dispatch(self.request[0..rc]) catch |err| blk: {
                std.debug.print("fuse: request failed: {any}\n", .{err});
                break :blk false;
            };
            if (done) return;
        }
    }

    /// Handles one request; true once the kernel tears the session down.
    fn dispatch(self: *Mount, bytes: []align(8) u8) !bool {
        const header: *const InHeader = @ptrCast(bytes.ptr);
        const body = bytes[@sizeOf(InHeader)..@min(bytes.len, header.len)];
        const op: Opcode = @enumFromInt(header.opcode);
        switch (op) {
            .init => try self.opInit(header, body),
            .lookup => try self.opLookup(header, std.mem.sliceTo(body, 0)),
            .getattr => try self.opGetattr(header),
            .opendir => try self.opOpen(header, .dir, body),
            .open => try self.opOpen(header, .file, body),
            .readdir => try self.opReaddir(header, body),
            .read => try self.opRead(header, body),
            .statfs => try self.replyStruct(header, StatfsOut{}),
            .access => try self.opAccess(header, body),
            .release => try self.opRelease(header, body),
            .releasedir, .flush, .fsync => try self.replyEmpty(header),
            .create => try self.opCreate(header, body),
            .write => try self.opWrite(header, body),
            .setattr => try self.opSetattr(header, body),
            .mkdir => try self.opMkdir(header, body),
            .unlink => try self.opRemove(header, std.mem.sliceTo(body, 0), .file),
            .rmdir => try self.opRemove(header, std.mem.sliceTo(body, 0), .dir),
            .rename => try self.opRename(header, body, false),
            .rename2 => try self.opRename(header, body, true),
            // No reply expected.
            .forget, .batch_forget, .interrupt => {},
            .destroy => {
                try self.replyEmpty(header);
                return true;
            },
            .getxattr, .listxattr => try self.replyError(header, .NOSYS),
            _ => try self.replyError(header, .NOSYS),
        }
        return false;
    }

    // ---- Operations ----

    fn opInit(self: *Mount, header: *const InHeader, body: []const u8) !void {
        const in = readStruct(InitIn, body) orelse return self.replyError(header, .IO);
        if (in.major != kernel_major) return self.replyError(header, .IO);
        try self.replyStruct(header, InitOut{
            .major = kernel_major,
            .minor = @min(in.minor, kernel_minor),
            .max_readahead = in.max_readahead,
            .flags = in.flags & (FUSE_ATOMIC_O_TRUNC | FUSE_BIG_WRITES),
            .max_write = max_write,
        });
    }

    fn opAccess(self: *Mount, header: *const InHeader, body: []const u8) !void {
        const in = readStruct(AccessIn, body) orelse return self.replyError(header, .IO);
        const node = self.inode(header.nodeid) orelse return self.replyError(header, .NOENT);
        const writable = node.kind == .swarm_dir or node.kind == .swarm_file;
        if (in.mask & W_OK != 0 and !writable) return self.replyError(header, .ROFS);
        try self.replyEmpty(header);
    }

    fn opLookup(self: *Mount, header: *const InHeader, name: []const u8) !void {
        const ino = (self.child(header.nodeid, name) catch |err| return self.replyError(header, errnoFor(err))) orelse
            return self.replyError(header, .NOENT);
        try self.replyStruct(header, EntryOut{
            .nodeid = ino,
            .entry_valid = cache_seconds,
            .attr_valid = cache_seconds,
            .attr = self.attr(ino),
        });
    }

    fn opGetattr(self: *Mount, header: *const InHeader) !void {
        if (header.nodeid == 0 or header.nodeid > self.inodes.items.len) return self.replyError(header, .NOENT);
        try self.replyStruct(header, AttrOut{ .attr_valid = cache_seconds, .attr = self.attr(header.nodeid) });
    }

    fn opOpen(self: *Mount, header: *const InHeader, want: enum { dir, file }, body: []const u8) !void {
        const node = self.inode(header.nodeid) orelse return self.replyError(header, .NOENT);
        const is_file = node.kind.isFile();
        if (want == .file and !is_file) return self.replyError(header, .ISDIR);
        if (want == .dir and is_file) return self.replyError(header, .NOTDIR);
        if (want == .file) {
            const in = readStruct(OpenIn, body) orelse return self.replyError(header, .IO);
            if (in.flags & O_ACCMODE != 0) {
                if (node.kind != .swarm_file) return self.replyError(header, .ROFS);
                const fh = self.openForWrite(header.nodeid, node, in.flags & O_TRUNC != 0) catch |err| return self.replyError(header, errnoFor(err));
                return self.replyStruct(header, OpenOut{ .fh = fh });
            }
        }
        try self.replyStruct(header, OpenOut{});
    }

    fn opRead(self: *Mount, header: *const InHeader, body: []const u8) !void {
        const in = readStruct(ReadIn, body) orelse return self.replyError(header, .IO);
        const node = self.inode(header.nodeid) orelse return self.replyError(header, .NOENT);
        if (!node.kind.isFile()) return self.replyError(header, .ISDIR);
        if (in.offset >= node.size) return self.replyBytes(header, &.{});

        const want: usize = @intCast(@min(in.size, node.size - in.offset));
        try self.reply.resize(self.allocator, @sizeOf(OutHeader) + want);
        const dest = self.reply.items[@sizeOf(OutHeader)..];
        const n = self.readFile(node, in.offset, dest) catch |err| {
            std.debug.print("fuse: read of {x} failed: {any}\n", .{ node.cid[0..4], err });
            return self.replyError(header, .IO);
        };
        try self.sendPrepared(header, n);
    }

    fn readFile(self: *Mount, node: Inode, offset: u64, dest: []u8) !usize {
        // A file being written reads from its staging copy.
        if (self.writingHandle(node)) |h| {
            const rc = linux.pread(h.fd, dest.ptr, dest.len, @intCast(offset));
            if (linux.errno(rc) != .SUCCESS) return error.InputOutput;
            return rc;
        }
        if (node.kind == .swarm_file) {
            const folder = self.swarm orelse return error.FileNotFound;
            return folder.readAt(self.allocator, node.cid, node.author, offset, dest);
        }
        const remote = self.devices.items[node.device].remote;
        return tree.readAt(self.allocator, remote.loader(), node.cid, offset, dest);
    }

    fn opReaddir(self: *Mount, header: *const InHeader, body: []const u8) !void {
        const in = readStruct(ReadIn, body) orelse return self.replyError(header, .IO);
        const node = self.inode(header.nodeid) orelse return self.replyError(header, .NOENT);

        var arena_state = std.heap.ArenaAllocator.init(self.allocator);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        const entries = self.childrenOf(arena, node) catch |err| return self.replyError(header, errnoFor(err));

        self.reply.clearRetainingCapacity();
        try self.reply.appendNTimes(self.allocator, 0, @sizeOf(OutHeader));
        var index: usize = @intCast(@min(in.offset, entries.len));
        while (index < entries.len) : (index += 1) {
            const entry = entries[index];
            const entry_len = std.mem.alignForward(usize, @sizeOf(Dirent) + entry.name.len, 8);
            if (self.reply.items.len - @sizeOf(OutHeader) + entry_len > in.size) break;
            const ino = try self.upsert(header.nodeid, entry.name, entry.node);
            const dirent = Dirent{
                .ino = ino,
                .off = index + 1,
                .namelen = @intCast(entry.name.len),
                .type = if (entry.node.kind.isFile()) DT_REG else DT_DIR,
            };
            try self.reply.appendSlice(self.allocator, std.mem.asBytes(&dirent));
            try self.reply.appendSlice(self.allocator, entry.name);
            try self.reply.appendNTimes(self.allocator, 0, entry_len - @sizeOf(Dirent) - entry.name.len);
        }
        try self.sendPrepared(header, self.reply.items.len - @sizeOf(OutHeader));
    }

    // ---- Writing (swarm folder only) ----

    fn swarmChildPath(self: *Mount, arena: std.mem.Allocator, parent: Inode, name: []const u8) ![]u8 {
        _ = self;
        if (parent.kind != .swarm_dir) return error.ReadOnly;
        if (name.len > 255) return error.NameTooLong;
        const path = if (parent.swarm_path.len == 0)
            try arena.dupe(u8, name)
        else
            try std.fmt.allocPrint(arena, "{s}/{s}", .{ parent.swarm_path, name });
        if (!manifest_mod.validPath(path)) return error.InvalidPath;
        return path;
    }

    fn nowSeconds() u64 {
        const t = std.Io.Timestamp.now(std.Io.Threaded.global_single_threaded.io(), .real).nanoseconds;
        return @intCast(@max(0, @divFloor(t, std.time.ns_per_s)));
    }

    fn writingHandle(self: *Mount, node: Inode) ?*Handle {
        if (node.kind != .swarm_file) return null;
        // Find the inode number for this node via the handle table.
        var it = self.handles.valueIterator();
        while (it.next()) |h| {
            if (std.mem.eql(u8, self.inodes.items[h.ino - 1].swarm_path, node.swarm_path)) return h;
        }
        return null;
    }

    /// A staging file and handle for `path`; when `copy_from` is set its
    /// current bytes are copied in first.
    fn newHandle(self: *Mount, ino: u64, path: []const u8, copy_from: ?Inode) !u64 {
        const folder = self.swarm orelse return error.ReadOnly;
        const dir = try folder.stagingDir(self.allocator);
        defer self.allocator.free(dir);
        const fh = self.next_fh;
        self.next_fh += 1;
        const staging = try std.fmt.allocPrintSentinel(self.allocator, "{s}/{d}.part", .{ dir, fh }, 0);
        errdefer self.allocator.free(staging);
        const rc = linux.open(staging.ptr, .{ .ACCMODE = .RDWR, .CREAT = true, .TRUNC = true, .CLOEXEC = true }, 0o600);
        if (linux.errno(rc) != .SUCCESS) return error.InputOutput;
        const fd: i32 = @intCast(rc);
        errdefer {
            _ = linux.close(fd);
            _ = linux.unlink(staging.ptr);
        }
        if (copy_from) |src| {
            const buf = try self.allocator.alloc(u8, 1024 * 1024);
            defer self.allocator.free(buf);
            var offset: u64 = 0;
            while (offset < src.size) {
                const n = try folder.readAt(self.allocator, src.cid, src.author, offset, buf);
                if (n == 0) break;
                if (linux.errno(linux.pwrite(fd, buf.ptr, n, @intCast(offset))) != .SUCCESS) return error.InputOutput;
                offset += n;
            }
        }
        const owned_path = try self.allocator.dupe(u8, path);
        errdefer self.allocator.free(owned_path);
        try self.handles.put(self.allocator, fh, .{ .ino = ino, .path = owned_path, .staging = staging, .fd = fd, .dirty = copy_from == null });
        try self.writing.put(self.allocator, ino, fh);
        return fh;
    }

    fn dropHandle(self: *Mount, h: Handle) void {
        _ = linux.close(h.fd);
        _ = linux.unlink(h.staging.ptr);
        if (self.writing.get(h.ino)) |fh| {
            if (self.handles.get(fh)) |cur| if (cur.fd == h.fd) {
                _ = self.writing.remove(h.ino);
            };
        }
        self.allocator.free(h.path);
        self.allocator.free(h.staging);
    }

    fn openForWrite(self: *Mount, ino: u64, node: Inode, truncate: bool) !u64 {
        const fh = try self.newHandle(ino, node.swarm_path, if (truncate) null else node);
        if (truncate) self.inodes.items[ino - 1].size = 0;
        return fh;
    }

    /// Adds a handle's bytes to the swarm folder (when changed).
    fn commit(self: *Mount, h: *Handle) !void {
        if (!h.dirty) return;
        const folder = self.swarm orelse return error.ReadOnly;
        const slash = std.mem.lastIndexOfScalar(u8, h.path, '/');
        const dir = if (slash) |sl| h.path[0..sl] else "";
        const name = h.path[if (slash) |sl| sl + 1 else 0..];
        try folder.addFile(dir, name, h.staging);
        h.dirty = false;
        if (folder.fileInfo(h.path)) |info| {
            const node = &self.inodes.items[h.ino - 1];
            node.cid = info.cid;
            node.size = info.size;
            node.mtime = info.mtime;
            node.author = info.author;
        }
    }

    fn opCreate(self: *Mount, header: *const InHeader, body: []const u8) !void {
        if (body.len <= @sizeOf(CreateIn)) return self.replyError(header, .INVAL);
        const name = std.mem.sliceTo(body[@sizeOf(CreateIn)..], 0);
        const parent = self.inode(header.nodeid) orelse return self.replyError(header, .NOENT);
        var arena_state = std.heap.ArenaAllocator.init(self.allocator);
        defer arena_state.deinit();
        const path = self.swarmChildPath(arena_state.allocator(), parent, name) catch |err| return self.replyError(header, errnoFor(err));

        const ino = try self.upsert(header.nodeid, name, .{
            .kind = .swarm_file,
            .size = 0,
            .mtime = nowSeconds(),
            .swarm_path = path,
            .author = (self.swarm.?.self_id).bytes,
        });
        const fh = self.newHandle(ino, path, null) catch |err| return self.replyError(header, errnoFor(err));
        const Reply = extern struct { entry: EntryOut, open: OpenOut };
        try self.replyStruct(header, Reply{
            .entry = .{ .nodeid = ino, .entry_valid = cache_seconds, .attr_valid = cache_seconds, .attr = self.attr(ino) },
            .open = .{ .fh = fh },
        });
    }

    fn opWrite(self: *Mount, header: *const InHeader, body: []const u8) !void {
        const in = readStruct(WriteIn, body) orelse return self.replyError(header, .INVAL);
        const data = body[@sizeOf(WriteIn)..];
        if (data.len < in.size) return self.replyError(header, .INVAL);
        const h = self.handles.getPtr(in.fh) orelse return self.replyError(header, .BADF);
        var done: usize = 0;
        while (done < in.size) {
            const rc = linux.pwrite(h.fd, data[done..].ptr, in.size - done, @intCast(in.offset + done));
            if (linux.errno(rc) != .SUCCESS) return self.replyError(header, .IO);
            done += rc;
        }
        h.dirty = true;
        const node = &self.inodes.items[h.ino - 1];
        node.size = @max(node.size, in.offset + in.size);
        node.mtime = nowSeconds();
        try self.replyStruct(header, WriteOut{ .size = in.size });
    }

    fn opSetattr(self: *Mount, header: *const InHeader, body: []const u8) !void {
        const in = readStruct(SetattrIn, body) orelse return self.replyError(header, .INVAL);
        const node = self.inode(header.nodeid) orelse return self.replyError(header, .NOENT);
        if (in.valid & FATTR_SIZE != 0) {
            if (node.kind != .swarm_file) return self.replyError(header, if (node.kind == .file) .ROFS else .ISDIR);
            const fh = if (in.valid & FATTR_FH != 0 and self.handles.contains(in.fh)) in.fh else self.writing.get(header.nodeid);
            if (fh) |f| {
                const h = self.handles.getPtr(f).?;
                if (linux.errno(linux.ftruncate(h.fd, @intCast(in.size))) != .SUCCESS) return self.replyError(header, .IO);
                h.dirty = true;
                self.inodes.items[header.nodeid - 1].size = in.size;
            } else {
                // Truncate without an open file: stage, cut, add at once.
                const f = self.newHandle(header.nodeid, node.swarm_path, if (in.size == 0) null else node) catch |err| return self.replyError(header, errnoFor(err));
                const h = self.handles.getPtr(f).?;
                _ = linux.ftruncate(h.fd, @intCast(in.size));
                h.dirty = true;
                self.commit(h) catch |err| {
                    std.debug.print("fuse: truncate of {s} failed: {any}\n", .{ h.path, err });
                };
                const removed = self.handles.fetchRemove(f).?;
                self.dropHandle(removed.value);
            }
        } else if (node.kind != .swarm_file and node.kind != .swarm_dir and in.valid != 0) {
            // Times and modes on read-only parts are accepted and ignored,
            // so cp -p and touch don't fail; nothing is stored for them.
        }
        try self.replyStruct(header, AttrOut{ .attr_valid = cache_seconds, .attr = self.attr(header.nodeid) });
    }

    fn opRelease(self: *Mount, header: *const InHeader, body: []const u8) !void {
        const in = readStruct(ReleaseIn, body) orelse return self.replyEmpty(header);
        if (self.handles.getPtr(in.fh)) |h| {
            self.commit(h) catch |err| std.debug.print("fuse: saving {s} to the swarm folder failed: {any}\n", .{ h.path, err });
            const removed = self.handles.fetchRemove(in.fh).?;
            self.dropHandle(removed.value);
        }
        try self.replyEmpty(header);
    }

    fn opMkdir(self: *Mount, header: *const InHeader, body: []const u8) !void {
        if (body.len <= @sizeOf(MkdirIn)) return self.replyError(header, .INVAL);
        const name = std.mem.sliceTo(body[@sizeOf(MkdirIn)..], 0);
        const parent = self.inode(header.nodeid) orelse return self.replyError(header, .NOENT);
        var arena_state = std.heap.ArenaAllocator.init(self.allocator);
        defer arena_state.deinit();
        _ = self.swarmChildPath(arena_state.allocator(), parent, name) catch |err| return self.replyError(header, errnoFor(err));
        if (try self.child(header.nodeid, name) != null) return self.replyError(header, .EXIST);
        self.swarm.?.makeDir(parent.swarm_path, name) catch |err| return self.replyError(header, errnoFor(err));
        const ino = (try self.child(header.nodeid, name)) orelse return self.replyError(header, .IO);
        try self.replyStruct(header, EntryOut{ .nodeid = ino, .entry_valid = cache_seconds, .attr_valid = cache_seconds, .attr = self.attr(ino) });
    }

    fn opRemove(self: *Mount, header: *const InHeader, name: []const u8, want: enum { file, dir }) !void {
        const parent = self.inode(header.nodeid) orelse return self.replyError(header, .NOENT);
        var arena_state = std.heap.ArenaAllocator.init(self.allocator);
        defer arena_state.deinit();
        const path = self.swarmChildPath(arena_state.allocator(), parent, name) catch |err| return self.replyError(header, errnoFor(err));
        const ino = (try self.child(header.nodeid, name)) orelse return self.replyError(header, .NOENT);
        const node = self.inodes.items[ino - 1];
        const folder = self.swarm.?;
        switch (want) {
            .file => if (node.kind != .swarm_file) return self.replyError(header, .ISDIR),
            .dir => {
                if (node.kind != .swarm_dir) return self.replyError(header, .NOTDIR);
                if (!(try folder.isEmptyDir(path))) return self.replyError(header, .NOTEMPTY);
            },
        }
        folder.remove(path) catch |err| switch (err) {
            // An empty folder only implied by a pending file, or already gone.
            error.FileNotFound => {},
            else => return self.replyError(header, errnoFor(err)),
        };
        try self.replyEmpty(header);
    }

    fn opRename(self: *Mount, header: *const InHeader, body: []const u8, v2: bool) !void {
        const head_len: usize = if (v2) @sizeOf(Rename2In) else @sizeOf(RenameIn);
        if (body.len <= head_len) return self.replyError(header, .INVAL);
        const newdir = std.mem.readInt(u64, body[0..8], .little);
        var replace = true;
        if (v2) {
            const flags = std.mem.readInt(u32, body[8..12], .little);
            if (flags & ~@as(u32, 1) != 0) return self.replyError(header, .INVAL); // only NOREPLACE
            replace = flags & 1 == 0;
        }
        const names = body[head_len..];
        const old_name = std.mem.sliceTo(names, 0);
        if (old_name.len + 1 >= names.len) return self.replyError(header, .INVAL);
        const new_name = std.mem.sliceTo(names[old_name.len + 1 ..], 0);

        const old_parent = self.inode(header.nodeid) orelse return self.replyError(header, .NOENT);
        const new_parent = self.inode(newdir) orelse return self.replyError(header, .NOENT);
        if (old_parent.kind != .swarm_dir or new_parent.kind != .swarm_dir) {
            const either_swarm = old_parent.kind == .swarm_dir or new_parent.kind == .swarm_dir;
            return self.replyError(header, if (either_swarm) .XDEV else .ROFS);
        }
        var arena_state = std.heap.ArenaAllocator.init(self.allocator);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        const from = self.swarmChildPath(arena, old_parent, old_name) catch |err| return self.replyError(header, errnoFor(err));
        const to = self.swarmChildPath(arena, new_parent, new_name) catch |err| return self.replyError(header, errnoFor(err));
        const moved_ino = try self.child(header.nodeid, old_name);
        // A file still open for writing is saved before it moves.
        if (moved_ino) |ino| {
            if (self.writing.get(ino)) |fh| {
                if (self.handles.getPtr(fh)) |h| self.commit(h) catch {};
            }
        }
        self.swarm.?.move(from, to, .{ .replace = replace }) catch |err| return self.replyError(header, errnoFor(err));
        // The kernel keeps the moved inode under its new name: point it at
        // the new path (its children refresh from it on their next lookup).
        if (moved_ino) |ino| try self.rekey(header.nodeid, old_name, newdir, new_name, ino, to);
        try self.repath(from, to);
        try self.replyEmpty(header);
    }

    /// Cached swarm inodes below a moved folder take its new path.
    fn repath(self: *Mount, from: []const u8, to: []const u8) !void {
        for (self.inodes.items) |*node| {
            if (node.kind != .swarm_dir and node.kind != .swarm_file) continue;
            const p = node.swarm_path;
            if (!(p.len > from.len and std.mem.startsWith(u8, p, from) and p[from.len] == '/')) continue;
            node.swarm_path = try std.fmt.allocPrint(self.path_arena.allocator(), "{s}{s}", .{ to, p[from.len..] });
        }
    }

    fn childKey(buf: *[8 + 256]u8, parent_ino: u64, name: []const u8) []const u8 {
        std.mem.writeInt(u64, buf[0..8], parent_ino, .little);
        @memcpy(buf[8..][0..name.len], name);
        return buf[0 .. 8 + name.len];
    }

    fn rekey(self: *Mount, old_parent: u64, old_name: []const u8, new_parent: u64, new_name: []const u8, ino: u64, new_path: []const u8) !void {
        var buf: [8 + 256]u8 = undefined;
        if (self.children.fetchRemove(childKey(&buf, old_parent, old_name))) |kv| self.allocator.free(kv.key);
        const key = try self.allocator.dupe(u8, childKey(&buf, new_parent, new_name));
        errdefer self.allocator.free(key);
        const gop = try self.children.getOrPut(self.allocator, key);
        if (gop.found_existing) self.allocator.free(key) else gop.key_ptr.* = key;
        gop.value_ptr.* = ino;
        self.inodes.items[ino - 1].swarm_path = try self.path_arena.allocator().dupe(u8, new_path);
    }

    // ---- Tree navigation ----

    fn inode(self: *Mount, ino: u64) ?Inode {
        if (ino == 0 or ino > self.inodes.items.len) return null;
        return self.inodes.items[ino - 1];
    }

    fn attr(self: *Mount, ino: u64) Attr {
        const node = self.inodes.items[ino - 1];
        const is_file = node.kind.isFile();
        return .{
            .ino = ino,
            .size = node.size,
            .blocks = (node.size + 511) / 512,
            .atime = node.mtime,
            .mtime = node.mtime,
            .ctime = node.mtime,
            .mode = switch (node.kind) {
                .swarm_file => S_IFREG | 0o644,
                .swarm_dir => S_IFDIR | 0o755,
                else => if (is_file) S_IFREG | 0o444 else S_IFDIR | 0o555,
            },
            .nlink = if (is_file) 1 else 2,
            .uid = self.uid,
            .gid = self.gid,
        };
    }

    const Child = struct { name: []const u8, node: Inode };

    /// What `parent` contains, in listing order (allocated in `arena`).
    fn childrenOf(self: *Mount, arena: std.mem.Allocator, parent: Inode) ![]Child {
        var out: std.ArrayList(Child) = .empty;
        switch (parent.kind) {
            .file, .swarm_file => return error.NotADirectory,
            .root => {
                if (self.swarm != null) {
                    try out.append(arena, .{ .name = "Swarm", .node = .{ .kind = .swarm_dir, .mtime = self.mounted_at } });
                }
                self.refreshDevices();
                for (self.devices.items, 0..) |d, i| {
                    if (!d.online) continue;
                    try out.append(arena, .{ .name = try arena.dupe(u8, d.name), .node = .{
                        .kind = .device,
                        .device = @intCast(i),
                        .mtime = self.mounted_at,
                    } });
                }
            },
            .device => {
                const listing = self.devices.items[parent.device].shares orelse return out.items;
                for (listing.entries) |e| {
                    try out.append(arena, .{ .name = try arena.dupe(u8, e.name), .node = .{
                        .kind = .dir,
                        .device = parent.device,
                        .cid = e.cid,
                        .size = e.size,
                        .mtime = e.mtime,
                    } });
                }
            },
            .swarm_dir => {
                const folder = self.swarm orelse return out.items;
                const items = try folder.list(arena, parent.swarm_path);
                // Files still being written aren't in the manifest yet.
                var hit = self.handles.valueIterator();
                while (hit.next()) |h| {
                    const slash = std.mem.lastIndexOfScalar(u8, h.path, '/');
                    const dir = if (slash) |sl| h.path[0..sl] else "";
                    if (!std.mem.eql(u8, dir, parent.swarm_path)) continue;
                    const name = h.path[if (slash) |sl| sl + 1 else 0..];
                    const listed = for (items) |it| {
                        if (std.mem.eql(u8, it.name, name)) break true;
                    } else false;
                    if (listed) continue;
                    try out.append(arena, .{ .name = name, .node = self.inodes.items[h.ino - 1] });
                }
                for (items) |it| {
                    try out.append(arena, .{ .name = it.name, .node = .{
                        .kind = if (it.dir) .swarm_dir else .swarm_file,
                        .cid = it.cid orelse [_]u8{0} ** 32,
                        .size = it.size,
                        .mtime = it.mtime,
                        .swarm_path = it.path,
                        .author = it.author_id orelse [_]u8{0} ** 32,
                    } });
                }
            },
            .dir => {
                const listing = try tree.listDir(arena, self.devices.items[parent.device].remote.loader(), &parent.cid);
                for (listing.entries) |e| {
                    try out.append(arena, .{ .name = e.name, .node = .{
                        .kind = if (e.kind == .dir) .dir else .file,
                        .device = parent.device,
                        .cid = e.cid,
                        .size = e.size,
                        .mtime = e.mtime,
                    } });
                }
            },
        }
        return out.items;
    }

    /// The inode of `name` under `parent_ino` from the parent's current
    /// listing; null when there is no such entry.
    fn child(self: *Mount, parent_ino: u64, name: []const u8) !?u64 {
        const parent = self.inode(parent_ino) orelse return null;
        var arena_state = std.heap.ArenaAllocator.init(self.allocator);
        defer arena_state.deinit();
        const entries = try self.childrenOf(arena_state.allocator(), parent);
        // Listings are sorted by name except the device list; both are small
        // or already decoded, so a scan is fine.
        for (entries) |e| {
            if (std.mem.eql(u8, e.name, name)) return try self.upsert(parent_ino, name, e.node);
        }
        return null;
    }

    /// Records `node` as `name` under `parent_ino`, keeping the inode
    /// number a path already has (its content may have changed).
    fn upsert(self: *Mount, parent_ino: u64, name: []const u8, node: Inode) !u64 {
        var key_buf: [8 + 256]u8 = undefined;
        if (name.len > 256) return error.NameTooLong;
        std.mem.writeInt(u64, key_buf[0..8], parent_ino, .little);
        @memcpy(key_buf[8..][0..name.len], name);
        const key = key_buf[0 .. 8 + name.len];

        // A swarm path comes from a temporary listing: keep a lasting copy,
        // reusing the inode's own when it hasn't changed.
        var stored = node;
        if (node.swarm_path.len > 0) {
            const old = if (self.children.get(key)) |ino| self.inodes.items[ino - 1].swarm_path else "";
            stored.swarm_path = if (std.mem.eql(u8, old, node.swarm_path)) old else try self.path_arena.allocator().dupe(u8, node.swarm_path);
        }
        if (self.children.get(key)) |ino| {
            self.inodes.items[ino - 1] = stored;
            return ino;
        }
        try self.inodes.append(self.allocator, stored);
        const ino: u64 = self.inodes.items.len;
        const owned = try self.allocator.dupe(u8, key);
        errdefer self.allocator.free(owned);
        try self.children.put(self.allocator, owned, ino);
        return ino;
    }

    /// Asks every known peer for its shares (at most every few seconds).
    /// Devices that do not answer stay listed as offline: their inodes keep
    /// working for content already cached.
    fn refreshDevices(self: *Mount) void {
        const now = std.Io.Timestamp.now(std.Io.Threaded.global_single_threaded.io(), .awake).nanoseconds;
        if (self.devices.items.len > 0 and now - self.devices_refreshed_ns < device_refresh_ns) return;
        self.devices_refreshed_ns = now;

        const peers = remote_mod.knownPeers(self.block_manager, self.allocator) catch return;
        defer self.allocator.free(peers);
        for (self.devices.items) |*d| d.online = false;
        for (peers) |peer| self.refreshDevice(peer) catch |err| {
            std.debug.print("fuse: device {x} unavailable: {any}\n", .{ peer.bytes[0..4], err });
        };
    }

    fn refreshDevice(self: *Mount, peer: NodeID) !void {
        const index = for (self.devices.items, 0..) |d, i| {
            if (d.remote.peer.eql(peer)) break i;
        } else blk: {
            const remote = try self.allocator.create(Remote);
            errdefer self.allocator.destroy(remote);
            remote.* = .{ .block_manager = self.block_manager, .store = self.store, .peer = peer };
            try self.devices.append(self.allocator, .{ .name = try self.allocator.dupe(u8, ""), .remote = remote });
            break :blk self.devices.items.len - 1;
        };
        const device = &self.devices.items[index];
        const shares = try device.remote.shares(self.allocator);
        defer self.allocator.free(shares.nickname);

        if (device.shares) |old| old.deinit();
        device.shares = shares.listing;
        device.online = true;
        if (device.name.len == 0) {
            const name = try self.deviceName(shares.nickname, peer);
            self.allocator.free(device.name);
            device.name = name;
        }
    }

    /// A folder name for a device: its nickname made path-safe, with a
    /// short ID suffix when empty or already taken.
    fn deviceName(self: *Mount, nickname: []const u8, peer: NodeID) ![]u8 {
        var buf: [64]u8 = undefined;
        var len: usize = 0;
        for (nickname) |c| {
            if (len == buf.len) break;
            buf[len] = if (c == '/' or c == 0 or c == '\\') '_' else c;
            len += 1;
        }
        const base = buf[0..len];
        var taken = len == 0 or std.mem.eql(u8, base, ".") or std.mem.eql(u8, base, "..");
        for (self.devices.items) |d| {
            if (std.mem.eql(u8, d.name, base)) taken = true;
        }
        if (!taken) return self.allocator.dupe(u8, base);
        const short = std.fmt.bytesToHex(peer.bytes[0..4], .lower);
        if (len == 0) return self.allocator.dupe(u8, &short);
        return std.fmt.allocPrint(self.allocator, "{s}-{s}", .{ base, short });
    }

    // ---- Replies ----

    fn replyStruct(self: *Mount, header: *const InHeader, value: anytype) !void {
        try self.replyBytes(header, std.mem.asBytes(&value));
    }

    fn replyEmpty(self: *Mount, header: *const InHeader) !void {
        try self.replyBytes(header, &.{});
    }

    fn replyBytes(self: *Mount, header: *const InHeader, payload: []const u8) !void {
        try self.reply.resize(self.allocator, @sizeOf(OutHeader) + payload.len);
        @memcpy(self.reply.items[@sizeOf(OutHeader)..], payload);
        try self.sendPrepared(header, payload.len);
    }

    /// Sends the first `payload_len` bytes after the header slot in `reply`.
    fn sendPrepared(self: *Mount, header: *const InHeader, payload_len: usize) !void {
        const total = @sizeOf(OutHeader) + payload_len;
        const out = OutHeader{ .len = @intCast(total), .@"error" = 0, .unique = header.unique };
        @memcpy(self.reply.items[0..@sizeOf(OutHeader)], std.mem.asBytes(&out));
        try self.send(self.reply.items[0..total]);
    }

    fn replyError(self: *Mount, header: *const InHeader, err: Errno) !void {
        const out = OutHeader{ .len = @sizeOf(OutHeader), .@"error" = -@intFromEnum(err), .unique = header.unique };
        try self.send(std.mem.asBytes(&out));
    }

    fn send(self: *Mount, bytes: []const u8) !void {
        const rc = linux.write(self.fd, bytes.ptr, bytes.len);
        switch (linux.errno(rc)) {
            .SUCCESS => {},
            // The request was interrupted and is gone; nothing to answer.
            .NOENT => {},
            else => |e| {
                std.debug.print("fuse: reply failed: {s}\n", .{@tagName(e)});
                return error.FuseWriteFailed;
            },
        }
    }
};

fn readStruct(comptime T: type, body: []const u8) ?T {
    if (body.len < @sizeOf(T)) return null;
    var value: T = undefined;
    @memcpy(std.mem.asBytes(&value), body[0..@sizeOf(T)]);
    return value;
}

fn errnoFor(err: anyerror) Errno {
    return switch (err) {
        error.NotADirectory => .NOTDIR,
        error.IsDirectory => .ISDIR,
        error.FileNotFound => .NOENT,
        error.PathAlreadyExists => .EXIST,
        error.ReadOnly => .ROFS,
        error.InvalidPath, error.InvalidName => .INVAL,
        error.NameTooLong => .NAMETOOLONG,
        else => .IO,
    };
}

// ---- Mounting ----

const fusermount_paths = [_][:0]const u8{ "/usr/bin/fusermount3", "/bin/fusermount3", "/usr/local/bin/fusermount3" };

fn findFusermount() ?[:0]const u8 {
    for (fusermount_paths) |p| {
        if (linux.errno(linux.access(p.ptr, linux.X_OK)) == .SUCCESS) return p;
    }
    return null;
}

/// Runs `fusermount3 [args] <mountpoint>` with `env`, waits for it and
/// returns its exit status.
fn runFusermount(allocator: std.mem.Allocator, args: []const []const u8, mountpoint: []const u8, env: ?[:0]const u8) !u32 {
    const program = findFusermount() orelse return error.FusermountNotFound;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const argv = try arena.allocSentinel(?[*:0]const u8, args.len + 2, null);
    argv[0] = program.ptr;
    for (args, 1..) |a, i| argv[i] = (try arena.dupeZ(u8, a)).ptr;
    argv[args.len + 1] = (try arena.dupeZ(u8, mountpoint)).ptr;
    const envp = try arena.allocSentinel(?[*:0]const u8, if (env == null) 0 else 1, null);
    if (env) |e| envp[0] = e.ptr;

    const pid = linux.fork();
    if (linux.errno(pid) != .SUCCESS) return error.ForkFailed;
    if (pid == 0) {
        _ = linux.execve(program.ptr, argv.ptr, envp.ptr);
        linux.exit(127);
    }
    var status: u32 = 0;
    while (true) {
        const rc = linux.wait4(@intCast(pid), &status, 0, null);
        if (linux.errno(rc) != .INTR) break;
    }
    return status;
}

/// Mounts a FUSE filesystem at `mountpoint` and returns the /dev/fuse
/// descriptor serving it.
fn mountWithFusermount(allocator: std.mem.Allocator, mountpoint: []const u8) !i32 {
    var fds: [2]i32 = undefined;
    // Not CLOEXEC: fusermount3 inherits fds[1] across exec.
    if (linux.errno(linux.socketpair(linux.AF.UNIX, linux.SOCK.STREAM, 0, &fds)) != .SUCCESS) return error.SocketPairFailed;
    defer _ = linux.close(fds[0]);
    var child_open = true;
    defer if (child_open) {
        _ = linux.close(fds[1]);
    };

    var env_buf: [32]u8 = undefined;
    const env = try std.fmt.bufPrintZ(&env_buf, "_FUSE_COMMFD={d}", .{fds[1]});
    const status = try runFusermount(allocator, &.{ "-o", "rw,nosuid,nodev,default_permissions,fsname=nomadfs,subtype=nomadfs", "--" }, mountpoint, env);
    _ = linux.close(fds[1]);
    child_open = false;
    if (status != 0) return error.MountFailed;

    // fusermount3 sends the /dev/fuse descriptor as SCM_RIGHTS.
    var byte: [1]u8 = undefined;
    var iov = [_]std.posix.iovec{.{ .base = &byte, .len = 1 }};
    // CMSG_SPACE(sizeof(int)): header plus the fd, padded to 8 bytes.
    var control: [std.mem.alignForward(usize, @sizeOf(linux.cmsghdr) + @sizeOf(i32), 8)]u8 align(8) = undefined;
    var msg = linux.msghdr{
        .name = null,
        .namelen = 0,
        .iov = &iov,
        .iovlen = 1,
        .control = &control,
        .controllen = control.len,
        .flags = 0,
    };
    const rc = linux.recvmsg(fds[0], &msg, 0);
    if (linux.errno(rc) != .SUCCESS or rc == 0) return error.NoFuseDescriptor;
    const cmsg: *const linux.cmsghdr = @ptrCast(&control);
    if (msg.controllen < @sizeOf(linux.cmsghdr) or cmsg.level != linux.SOL.SOCKET or cmsg.type != linux.SCM.RIGHTS) {
        return error.NoFuseDescriptor;
    }
    var fd: i32 = undefined;
    @memcpy(std.mem.asBytes(&fd), control[@sizeOf(linux.cmsghdr)..][0..@sizeOf(i32)]);
    return fd;
}

/// Lazily unmounts `mountpoint` (the kernel detaches it once idle). Safe to
/// call from a signal handler: it only forks and execs.
pub fn unmount(mountpoint: [:0]const u8) void {
    const program = findFusermount() orelse return;
    const argv = [_:null]?[*:0]const u8{ program.ptr, "-u", "-z", mountpoint.ptr };
    const envp = [_:null]?[*:0]const u8{};
    const pid = linux.fork();
    if (pid == 0) {
        _ = linux.execve(program.ptr, &argv, &envp);
        linux.exit(127);
    }
    if (linux.errno(pid) != .SUCCESS) return;
    var status: u32 = 0;
    _ = linux.wait4(@intCast(pid), &status, 0, null);
}
