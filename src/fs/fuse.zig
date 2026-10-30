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
const sync = @import("../sync.zig");
const tree = @import("tree.zig");
const remote_mod = @import("remote.zig");
const swarm_mod = @import("swarm.zig");
const manifest_mod = @import("manifest.zig");
pub const Remote = remote_mod.Remote;
const InodeTable = @import("inode_table.zig").Table(Inode);
const device_names = @import("device_names.zig");
const device_trust = @import("../device/trust.zig");

// ---- Kernel protocol (include/uapi/linux/fuse.h) ----

const kernel_major = 7;
const kernel_minor = 31;
pub const root_id = 1;

pub const Opcode = enum(u32) {
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
pub const CreateIn = extern struct { flags: u32, mode: u32, umask: u32, open_flags: u32 };
pub const WriteIn = extern struct { fh: u64, offset: u64, size: u32, write_flags: u32, lock_owner: u64, flags: u32, padding: u32 };
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
pub const RenameIn = extern struct { newdir: u64 };
pub const Rename2In = extern struct { newdir: u64, flags: u32, padding: u32 };
pub const ReleaseIn = extern struct { fh: u64, flags: u32, release_flags: u32, lock_owner: u64 };

pub const ForgetIn = extern struct { nlookup: u64 };
pub const BatchForgetIn = extern struct { count: u32, dummy: u32 };
pub const ForgetOne = extern struct { nodeid: u64, nlookup: u64 };

const FATTR_SIZE = 1 << 3;
const FATTR_FH = 1 << 6;
const O_TRUNC = 0o1000;
const FUSE_ATOMIC_O_TRUNC = 1 << 3;
const FUSE_BIG_WRITES = 1 << 5;
const max_write = 128 * 1024;

pub const InHeader = extern struct {
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

pub const OutHeader = extern struct {
    len: u32,
    @"error": i32,
    unique: u64,
};

pub const Attr = extern struct {
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

pub const EntryOut = extern struct {
    nodeid: u64,
    generation: u64 = 0,
    entry_valid: u64,
    attr_valid: u64,
    entry_valid_nsec: u32 = 0,
    attr_valid_nsec: u32 = 0,
    attr: Attr,
};

pub const AttrOut = extern struct {
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

pub const ReadIn = extern struct {
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
    std.debug.assert(@sizeOf(ForgetIn) == 8);
    std.debug.assert(@sizeOf(BatchForgetIn) == 8);
    std.debug.assert(@sizeOf(ForgetOne) == 16);
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
    BUSY = 16,
    EXIST = 17,
    XDEV = 18,
    NOTDIR = 20,
    ISDIR = 21,
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
const worker_max = 16;
const refresh_parallel = 8;
const first_refresh_wait_ms = 3000;

threadlocal var tl_reply: std.ArrayList(u8) = .empty;

// ---- Filesystem state ----

pub const Kind = enum {
    root,
    device,
    dir,
    file,
    /// The swarm folder (Swarm/ and folders inside it) and its files.
    swarm_dir,
    swarm_file,

    pub fn isFile(k: Kind) bool {
        return k == .file or k == .swarm_file;
    }
};

pub const Inode = struct {
    kind: Kind,
    /// Index into Mount.devices (device, dir and file inodes).
    device: u32 = 0,
    cid: tree.Cid = undefined,
    size: u64 = 0,
    mtime: u64 = 0,
    /// The device that added a swarm file.
    author: [32]u8 = [_]u8{0} ** 32,
};

/// A swarm file open for writing: bytes go to a staging file and are added
/// to the swarm folder on release.
pub const Handle = struct {
    ino: u64,
    /// Staging file (owned, NUL-terminated for open(2)).
    staging: [:0]u8,
    fd: i32,
    dirty: bool,
};

pub const Device = struct {
    name: []u8,
    remote: *Remote,
    shares: ?tree.Listing = null,
    online: bool = false,
    last_seen_ms: i64 = 0,
    device_id: ?[32]u8 = null,
    claimed: []u8 = &[_]u8{},
};

pub const Mount = struct {
    allocator: std.mem.Allocator,
    block_manager: ?*cluster.BlockManager = null,
    store: *storage.engine.StorageEngine,
    fd: i32 = -1,
    uid: u32,
    gid: u32,
    lock: sync.Mutex = .{},
    table: InodeTable,
    devices: std.ArrayList(Device) = .empty,
    /// Shown as the mtime of the root and device folders.
    mounted_at: u64 = 0,
    /// The swarm folder, shown as <mount>/Swarm when set.
    swarm: ?*swarm_mod.SwarmFolder = null,
    /// Fetches ahead of sequential reads (video players read in order).
    read_ahead: ?*@import("readahead.zig").ReadAhead = null,
    /// Open write handles on swarm files: fh -> handle.
    handles: std.AutoHashMapUnmanaged(u64, Handle) = .empty,
    /// Inode -> the fh writing it, so reads see unsaved bytes.
    writing: std.AutoHashMapUnmanaged(u64, u64) = .empty,
    next_fh: u64 = 1,
    send_hook: ?*const fn (*Mount, []const u8) anyerror!bool = null,
    hooks: struct {
        before_network: ?*const fn (?*anyopaque) void = null,
        ctx: ?*anyopaque = null,
    } = .{},
    stopping: std.atomic.Value(bool) = .init(false),
    idle: std.atomic.Value(u32) = .init(0),
    pool: struct {
        mutex: sync.Mutex = .{},
        threads: std.ArrayList(std.Thread) = .empty,
        count: u32 = 0,
    } = .{},
    refresh: struct {
        mutex: sync.Mutex = .{},
        cond: sync.Condition = .{},
        wanted: bool = false,
        first_done: bool = false,
        last_start_ms: i64 = 0,
        thread: ?std.Thread = null,
    } = .{},

    pub fn init(allocator: std.mem.Allocator, block_manager: ?*cluster.BlockManager, store: *storage.engine.StorageEngine) !Mount {
        var self = Mount{
            .table = try InodeTable.init(allocator, .{ .kind = .root }),
            .allocator = allocator,
            .block_manager = block_manager,
            .store = store,
            .uid = linux.getuid(),
            .gid = linux.getgid(),
        };
        const now = sync.timestamp();
        self.mounted_at = @intCast(@max(0, now));
        errdefer self.table.deinit();
        self.table.map.getPtr(root_id).?.data.mtime = self.mounted_at;
        return self;
    }

    pub fn deinit(self: *Mount) void {
        self.stopping.store(true, .release);
        self.stopRefresher();
        while (true) {
            const thread = blk: {
                self.pool.mutex.lock();
                defer self.pool.mutex.unlock();
                if (self.pool.threads.items.len > 0) {
                    break :blk self.pool.threads.pop();
                }
                break :blk null;
            };
            if (thread) |t| {
                t.join();
            } else {
                break;
            }
        }
        self.pool.threads.deinit(self.allocator);
        if (self.fd >= 0) _ = linux.close(self.fd);
        var hit = self.handles.iterator();
        while (hit.next()) |entry| self.dropHandle(entry.key_ptr.*, entry.value_ptr.*);
        self.handles.deinit(self.allocator);
        self.writing.deinit(self.allocator);
        self.table.deinit();
        for (self.devices.items) |d| {
            self.allocator.free(d.name);
            if (d.claimed.len > 0) self.allocator.free(d.claimed);
            if (d.shares) |s| s.deinit();
            self.allocator.destroy(d.remote);
        }
        self.devices.deinit(self.allocator);
        tl_reply.deinit(self.allocator);
        tl_reply = .empty;
    }

    /// Mounts at `mountpoint` and serves requests until it is unmounted
    /// (fusermount3 -u, or `unmount`).
    pub fn serve(self: *Mount, mountpoint: []const u8) !void {
        if (self.swarm) |s| s.cleanStaging();
        self.fd = try mountWithFusermount(self.allocator, mountpoint);
        try self.run();
    }

    /// Split out so tests can drive it with a socketpair instead of /dev/fuse.
    pub fn run(self: *Mount) !void {
        try self.startRefresher();
        {
            self.pool.mutex.lock();
            self.pool.count = 1;
            self.pool.mutex.unlock();
        }
        self.workerMain();
        self.stopping.store(true, .release);
        self.stopRefresher();
        while (true) {
            const thread = blk: {
                self.pool.mutex.lock();
                defer self.pool.mutex.unlock();
                if (self.pool.threads.items.len > 0) {
                    break :blk self.pool.threads.pop();
                }
                break :blk null;
            };
            if (thread) |t| {
                t.join();
            } else {
                break;
            }
        }
    }

    fn workerMain(self: *Mount) void {
        defer {
            tl_reply.deinit(self.allocator);
            tl_reply = .empty;
        }
        const req_buf = self.allocator.alignedAlloc(u8, .@"8", request_buffer_len) catch |err| {
            std.debug.print("fuse: failed to allocate request buffer: {any}\n", .{err});
            return;
        };
        defer self.allocator.free(req_buf);

        while (!self.stopping.load(.acquire)) {
            _ = self.idle.fetchAdd(1, .monotonic);

            const rc = linux.read(self.fd, req_buf.ptr, req_buf.len);
            if (rc == 0) {
                _ = self.idle.fetchSub(1, .monotonic);
                self.stopping.store(true, .release);
                return;
            }

            switch (linux.errno(rc)) {
                .SUCCESS => {},
                .INTR, .NOENT, .AGAIN => {
                    _ = self.idle.fetchSub(1, .monotonic);
                    continue;
                },
                .NODEV => {
                    _ = self.idle.fetchSub(1, .monotonic);
                    self.stopping.store(true, .release);
                    return;
                },
                else => |e| {
                    _ = self.idle.fetchSub(1, .monotonic);
                    std.debug.print("fuse: read failed: {s}\n", .{@tagName(e)});
                    self.stopping.store(true, .release);
                    return;
                },
            }

            if (rc < @sizeOf(InHeader)) {
                _ = self.idle.fetchSub(1, .monotonic);
                continue;
            }

            const header: *const InHeader = @ptrCast(req_buf.ptr);
            const op: Opcode = @enumFromInt(header.opcode);
            const was_idle = self.idle.fetchSub(1, .monotonic);
            if (op != .forget and op != .batch_forget) {
                if (was_idle == 1) {
                    self.spawnWorker();
                }
            }

            const done = self.dispatch(req_buf[0..rc]) catch |err| blk: {
                std.debug.print("fuse: request failed: {any}\n", .{err});
                break :blk false;
            };
            if (done) {
                self.stopping.store(true, .release);
                return;
            }
        }
    }

    fn spawnWorker(self: *Mount) void {
        self.pool.mutex.lock();
        defer self.pool.mutex.unlock();
        if (self.pool.count >= worker_max or self.stopping.load(.acquire)) return;
        const thread = std.Thread.spawn(.{}, workerMain, .{self}) catch |err| {
            std.debug.print("fuse: failed to spawn worker: {any}\n", .{err});
            return;
        };
        self.pool.threads.append(self.allocator, thread) catch |err| {
            std.debug.print("fuse: failed to track worker thread: {any}\n", .{err});
        };
        self.pool.count += 1;
    }

    fn startRefresher(self: *Mount) !void {
        self.refresh.mutex.lock();
        defer self.refresh.mutex.unlock();
        if (self.refresh.thread != null) return;
        self.refresh.thread = try std.Thread.spawn(.{}, refresherMain, .{self});
    }

    fn stopRefresher(self: *Mount) void {
        const thread = blk: {
            self.refresh.mutex.lock();
            defer self.refresh.mutex.unlock();
            self.refresh.wanted = true;
            self.refresh.cond.broadcast();
            const t = self.refresh.thread;
            self.refresh.thread = null;
            break :blk t;
        };
        if (thread) |t| t.join();
    }

    fn refresherMain(self: *Mount) void {
        while (!self.stopping.load(.acquire)) {
            self.refresh.mutex.lock();
            while (!self.refresh.wanted and !self.stopping.load(.acquire)) {
                self.refresh.cond.wait(&self.refresh.mutex);
            }
            if (self.stopping.load(.acquire)) {
                self.refresh.mutex.unlock();
                return;
            }
            self.refresh.wanted = false;
            self.refresh.last_start_ms = sync.monotonicMillis();
            self.refresh.mutex.unlock();

            self.refreshAll();

            self.refresh.mutex.lock();
            self.refresh.first_done = true;
            self.refresh.cond.broadcast();
            self.refresh.mutex.unlock();
        }
    }

    fn requestRefresh(self: *Mount) void {
        self.refresh.mutex.lock();
        defer self.refresh.mutex.unlock();
        const now = sync.monotonicMillis();
        if (now - self.refresh.last_start_ms >= @divFloor(device_refresh_ns, std.time.ns_per_ms)) {
            self.refresh.wanted = true;
            self.refresh.cond.signal();
        }
    }

    fn refreshAll(self: *Mount) void {
        const bm = self.block_manager orelse return;
        const peers = remote_mod.knownPeers(bm, self.allocator) catch return;
        defer self.allocator.free(peers);

        {
            self.lock.lock();
            defer self.lock.unlock();
            const now = sync.monotonicMillis();
            for (self.devices.items) |*d| {
                if (now - d.last_seen_ms > 10 * 60 * 1000) {
                    if (d.shares) |listing| listing.deinit();
                    d.shares = null;
                    d.online = false;
                }
            }
        }

        var i: usize = 0;
        while (i < peers.len and !self.stopping.load(.acquire)) {
            const batch_end = @min(i + refresh_parallel, peers.len);
            const batch = peers[i..batch_end];
            i = batch_end;

            const ProbeContext = struct {
                mount: *Mount,
                peer: NodeID,
                shares_res: ?Remote.Shares = null,

                fn run(ctx: *@This()) void {
                    var probe = Remote{
                        .block_manager = ctx.mount.block_manager.?,
                        .peer = ctx.peer,
                    };
                    ctx.shares_res = probe.shares(ctx.mount.allocator) catch null;
                }
            };

            var contexts: [refresh_parallel]ProbeContext = undefined;
            var threads: [refresh_parallel]?std.Thread = [_]?std.Thread{null} ** refresh_parallel;

            for (batch, 0..) |peer, b_idx| {
                contexts[b_idx] = .{ .mount = self, .peer = peer };
                threads[b_idx] = std.Thread.spawn(.{}, ProbeContext.run, .{&contexts[b_idx]}) catch null;
                if (threads[b_idx] == null) {
                    contexts[b_idx].run();
                }
            }

            for (batch, 0..) |peer, b_idx| {
                if (threads[b_idx]) |t| t.join();
                if (contexts[b_idx].shares_res) |shares| {
                    self.applyShares(peer, shares);
                } else {
                    self.lock.lock();
                    for (self.devices.items) |*d| {
                        if (d.remote.peer.eql(peer)) {
                            d.online = false;
                            break;
                        }
                    }
                    self.lock.unlock();
                    // Reads of its files fail fast until it answers again.
                    if (bm.fetcher) |*f| f.markDown(peer);
                }
            }
        }
    }

    fn applyShares(self: *Mount, peer: NodeID, shares: Remote.Shares) void {
        defer self.allocator.free(shares.nickname);
        defer self.allocator.free(shares.backup);
        self.lock.lock();
        defer self.lock.unlock();

        const bm = self.block_manager orelse {
            shares.listing.deinit();
            return;
        };
        const index = for (self.devices.items, 0..) |d, i| {
            if (d.remote.peer.eql(peer)) break i;
        } else blk: {
            const remote = self.allocator.create(Remote) catch {
                shares.listing.deinit();
                return;
            };
            errdefer self.allocator.destroy(remote);
            remote.* = .{ .block_manager = bm, .peer = peer };
            const name = self.allocator.dupe(u8, "") catch {
                self.allocator.destroy(remote);
                shares.listing.deinit();
                return;
            };
            self.devices.append(self.allocator, .{ .name = name, .remote = remote }) catch {
                self.allocator.free(name);
                self.allocator.destroy(remote);
                shares.listing.deinit();
                return;
            };
            break :blk self.devices.items.len - 1;
        };
        const device = &self.devices.items[index];

        if (device.shares) |old| old.deinit();
        device.online = true;
        device.last_seen_ms = sync.monotonicMillis();
        device.device_id = if (shares.device_id) |id| id.bytes else peer.bytes;
        if (device.claimed.len > 0) self.allocator.free(device.claimed);
        device.claimed = self.allocator.dupe(u8, shares.nickname) catch &[_]u8{};
        device.shares = shares.listing;

        self.recomputeNames();
    }

    /// Recomputes mount folder names for all online devices.
    /// Caller holds self.lock.
    fn recomputeNames(self: *Mount) void {
        var online_count: usize = 0;
        for (self.devices.items) |d| {
            if (d.online) online_count += 1;
        }
        if (online_count == 0) return;

        const online_indices = self.allocator.alloc(usize, online_count) catch return;
        defer self.allocator.free(online_indices);
        const entries = self.allocator.alloc(device_names.Entry, online_count) catch return;
        defer self.allocator.free(entries);
        const out = self.allocator.alloc([]u8, online_count) catch return;
        defer self.allocator.free(out);

        const trust_store = if (self.block_manager) |bm| bm.dht_node.trust_store else null;
        var trust_entries: std.ArrayList(device_trust.Entry) = .empty;
        defer trust_entries.deinit(self.allocator);
        trust_entries.ensureTotalCapacity(self.allocator, online_count) catch return;

        var j: usize = 0;
        for (self.devices.items, 0..) |d, i| {
            if (!d.online) continue;
            online_indices[j] = i;
            const dev_id = d.device_id orelse d.remote.peer.bytes;
            var trusted_info: ?device_names.TrustedInfo = null;
            if (trust_store) |ts| {
                if (ts.lookup(NodeID{ .bytes = dev_id })) |te| {
                    trust_entries.appendAssumeCapacity(te);
                    const last_te = &trust_entries.items[trust_entries.items.len - 1];
                    trusted_info = .{
                        .label = last_te.labelSlice(),
                        .added_at = last_te.added_at,
                    };
                }
            }
            entries[j] = .{
                .device_id = dev_id,
                .trusted = trusted_info,
                .nickname = d.claimed,
            };
            j += 1;
        }

        device_names.assign(self.allocator, entries, out) catch |err| {
            std.debug.print("recomputeNames: assign failed: {any}\n", .{err});
            return;
        };

        for (online_indices, out) |dev_idx, new_name| {
            const old_name = self.devices.items[dev_idx].name;
            if (std.mem.eql(u8, old_name, new_name)) {
                self.allocator.free(new_name);
                continue;
            }
            self.devices.items[dev_idx].name = new_name;
            self.allocator.free(old_name);
        }
    }

    /// Handles one request; true once the kernel tears the session down.
    pub fn dispatch(self: *Mount, bytes: []align(8) u8) !bool {
        const header: *const InHeader = @ptrCast(bytes.ptr);
        if (bytes.len < @sizeOf(InHeader)) return false;
        if (header.len < @sizeOf(InHeader)) return false;
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
            .forget => if (readStruct(ForgetIn, body)) |in| {
                self.lock.lock();
                defer self.lock.unlock();
                self.table.unref(header.nodeid, in.nlookup);
            },
            .batch_forget => self.opBatchForget(body),
            .interrupt => {},
            .destroy => {
                try self.replyEmpty(header);
                return true;
            },
            else => try self.replyError(header, .NOSYS),
        }
        return false;
    }

    fn opInit(self: *Mount, header: *const InHeader, body: []const u8) !void {
        const in = readStruct(InitIn, body) orelse return self.replyError(header, .IO);
        if (in.major != kernel_major) {
            std.debug.print("fuse: kernel major {d} != {d}\n", .{ in.major, kernel_major });
            return self.replyError(header, .IO);
        }
        try self.replyStruct(header, InitOut{
            .major = kernel_major,
            .minor = @min(kernel_minor, in.minor),
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
        const ino = (self.lookupChild(header.nodeid, name) catch |err| return self.replyError(header, errnoFor(err))) orelse
            return self.replyError(header, .NOENT);
        const node = self.inode(ino) orelse return self.replyError(header, .NOENT);
        try self.replyReferenced(header, ino, EntryOut{
            .nodeid = ino,
            .entry_valid = cache_seconds,
            .attr_valid = cache_seconds,
            .attr = self.attrOf(ino, node),
        }, null);
    }

    fn opGetattr(self: *Mount, header: *const InHeader) !void {
        const node = self.inode(header.nodeid) orelse return self.replyError(header, .NOENT);
        try self.replyStruct(header, AttrOut{ .attr_valid = cache_seconds, .attr = self.attrOf(header.nodeid, node) });
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
                {
                    self.lock.lock();
                    const busy = self.writing.contains(header.nodeid);
                    self.lock.unlock();
                    if (busy) return self.replyError(header, .BUSY);
                }
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
        try tl_reply.resize(self.allocator, @sizeOf(OutHeader) + want);
        const dest = tl_reply.items[@sizeOf(OutHeader)..];
        const n = self.readFile(header.nodeid, node, in.offset, dest) catch |err| {
            std.debug.print("fuse: read of {x} failed: {any}\n", .{ node.cid[0..4], err });
            return self.replyError(header, .IO);
        };
        try self.sendPrepared(header, n);
    }

    fn readFile(self: *Mount, ino: u64, node: Inode, offset: u64, dest: []u8) !usize {
        // A file being written reads from its staging copy.
        const staging_read: ?usize = blk: {
            self.lock.lock();
            defer self.lock.unlock();
            if (self.writingHandle(ino)) |h| {
                const rc = linux.pread(h.fd, dest.ptr, dest.len, @intCast(offset));
                if (linux.errno(rc) != .SUCCESS) return error.InputOutput;
                break :blk @intCast(rc);
            }
            break :blk null;
        };
        if (staging_read) |n| return n;

        if (node.kind == .swarm_file) {
            const folder = self.swarm orelse return error.FileNotFound;
            return folder.readAt(self.allocator, node.cid, node.author, offset, dest);
        }
        const remote = blk: {
            self.lock.lock();
            defer self.lock.unlock();
            if (node.device >= self.devices.items.len) return error.FileNotFound;
            break :blk self.devices.items[node.device].remote;
        };
        if (self.hooks.before_network) |hook| hook(self.hooks.ctx);
        const bm = remote.block_manager orelse return error.PeerDown;
        return remote_mod.readShareAt(self.allocator, bm, self.read_ahead, remote.peer, node.cid, offset, dest);
    }

    fn opReaddir(self: *Mount, header: *const InHeader, body: []const u8) !void {
        const in = readStruct(ReadIn, body) orelse return self.replyError(header, .IO);
        const parent = self.inode(header.nodeid) orelse return self.replyError(header, .NOENT);
        if (parent.kind.isFile()) return self.replyError(header, .NOTDIR);

        var arena_state = std.heap.ArenaAllocator.init(self.allocator);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        const entries = self.childrenOf(arena, header.nodeid, parent) catch |err| return self.replyError(header, errnoFor(err));

        try tl_reply.resize(self.allocator, @sizeOf(OutHeader));
        var index = in.offset;
        while (index < entries.len) : (index += 1) {
            const entry = entries[index];
            const entry_len = std.mem.alignForward(usize, @sizeOf(Dirent) + entry.name.len, 8);
            if (tl_reply.items.len - @sizeOf(OutHeader) + entry_len > in.size) break;
            const ino = blk: {
                self.lock.lock();
                defer self.lock.unlock();
                break :blk self.table.find(header.nodeid, entry.name) orelse synthIno(header.nodeid, entry.name);
            };
            const dirent = Dirent{
                .ino = ino,
                .off = index + 1,
                .namelen = @intCast(entry.name.len),
                .type = if (entry.node.kind.isFile()) DT_REG else DT_DIR,
            };
            try tl_reply.appendSlice(self.allocator, std.mem.asBytes(&dirent));
            try tl_reply.appendSlice(self.allocator, entry.name);
            try tl_reply.appendNTimes(self.allocator, 0, entry_len - @sizeOf(Dirent) - entry.name.len);
        }
        try self.sendPrepared(header, tl_reply.items.len - @sizeOf(OutHeader));
    }

    // ---- Writing (swarm folder only) ----

    fn swarmPath(self: *Mount, arena: std.mem.Allocator, ino: u64) ![]u8 {
        const stop = self.table.find(root_id, "Swarm") orelse return error.Detached;
        return self.table.pathOf(arena, ino, stop);
    }

    fn swarmChildPath(self: *Mount, arena: std.mem.Allocator, parent_ino: u64, name: []const u8) ![]u8 {
        const parent = if (self.table.map.get(parent_ino)) |e| e.data else return error.FileNotFound;
        if (parent.kind != .swarm_dir) return error.ReadOnly;
        if (name.len > 255) return error.NameTooLong;
        const base = try self.swarmPath(arena, parent_ino);
        const path = if (base.len == 0) try arena.dupe(u8, name) else try std.fmt.allocPrint(arena, "{s}/{s}", .{ base, name });
        if (!manifest_mod.validPath(path)) return error.InvalidPath;
        return path;
    }

    fn nowSeconds() u64 {
        const t = sync.timestamp();
        return @intCast(@max(0, t));
    }

    fn writingHandle(self: *Mount, ino: u64) ?*Handle {
        return self.handles.getPtr(self.writing.get(ino) orelse return null);
    }

    /// A staging file and handle for `path`; when `copy_from` is set its
    /// current bytes are copied in first.
    fn newHandle(self: *Mount, ino: u64, copy_from: ?Inode) !u64 {
        const folder = self.swarm orelse return error.ReadOnly;
        {
            self.lock.lock();
            defer self.lock.unlock();
            if (self.writing.contains(ino)) return error.DeviceOrResourceBusy;
        }
        const dir = try folder.stagingDir(self.allocator);
        defer self.allocator.free(dir);

        const fh = blk: {
            self.lock.lock();
            defer self.lock.unlock();
            const f = self.next_fh;
            self.next_fh += 1;
            break :blk f;
        };
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

        // Critical section: atomic check-and-insert under L1
        self.lock.lock();
        defer self.lock.unlock();
        if (self.writing.contains(ino)) return error.DeviceOrResourceBusy;
        try self.handles.ensureUnusedCapacity(self.allocator, 1);
        try self.writing.ensureUnusedCapacity(self.allocator, 1);
        self.handles.putAssumeCapacity(fh, .{ .ino = ino, .staging = staging, .fd = fd, .dirty = copy_from == null });
        self.writing.putAssumeCapacity(ino, fh);
        self.table.pin(ino);
        return fh;
    }

    fn dropHandle(self: *Mount, fh: u64, h: Handle) void {
        _ = linux.close(h.fd);
        _ = linux.unlink(h.staging.ptr);
        {
            self.lock.lock();
            defer self.lock.unlock();
            if (self.writing.get(h.ino)) |wfh| {
                if (wfh == fh) {
                    _ = self.writing.remove(h.ino);
                }
            }
            self.table.unpin(h.ino);
        }
        self.allocator.free(h.staging);
    }

    pub fn openForWrite(self: *Mount, ino: u64, node: Inode, truncate: bool) !u64 {
        const fh = try self.newHandle(ino, if (truncate) null else node);
        if (truncate) {
            self.lock.lock();
            defer self.lock.unlock();
            if (self.table.map.getPtr(ino)) |e| e.data.size = 0;
        }
        return fh;
    }

    /// Adds a handle's bytes to the swarm folder (when changed).
    fn commit(self: *Mount, h: *Handle) !void {
        if (!h.dirty) return;
        const folder = self.swarm orelse return error.ReadOnly;
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const path = blk: {
            self.lock.lock();
            defer self.lock.unlock();
            break :blk self.swarmPath(arena.allocator(), h.ino) catch |err| {
                if (err == error.Detached) {
                    h.dirty = false;
                    return;
                }
                return err;
            };
        };
        const slash = std.mem.lastIndexOfScalar(u8, path, '/');
        const dir = if (slash) |sl| path[0..sl] else "";
        const name = path[if (slash) |sl| sl + 1 else 0..];
        h.dirty = false;
        folder.addFile(dir, name, h.staging) catch |err| {
            h.dirty = true;
            return err;
        };
        if (folder.fileInfo(path)) |info| {
            self.lock.lock();
            defer self.lock.unlock();
            if (self.table.map.getPtr(h.ino)) |e| {
                const node = &e.data;
                node.cid = info.cid;
                node.size = info.size;
                node.mtime = info.mtime;
                node.author = info.author;
            }
        }
    }

    fn opCreate(self: *Mount, header: *const InHeader, body: []const u8) !void {
        if (body.len <= @sizeOf(CreateIn)) return self.replyError(header, .INVAL);
        const name = std.mem.sliceTo(body[@sizeOf(CreateIn)..], 0);
        var arena_state = std.heap.ArenaAllocator.init(self.allocator);
        defer arena_state.deinit();
        {
            self.lock.lock();
            defer self.lock.unlock();
            _ = self.swarmChildPath(arena_state.allocator(), header.nodeid, name) catch |err| return self.replyError(header, errnoFor(err));
        }

        const swarm = self.swarm orelse return self.replyError(header, .ROFS);
        const ino = try self.upsert(header.nodeid, name, .{
            .kind = .swarm_file,
            .size = 0,
            .mtime = nowSeconds(),
            .author = swarm.self_id.bytes,
        });
        const fh = self.newHandle(ino, null) catch |err| {
            self.lock.lock();
            self.table.evictIfDead(ino);
            self.lock.unlock();
            return self.replyError(header, errnoFor(err));
        };
        const node = self.inode(ino) orelse return self.replyError(header, .NOENT);
        const Reply = extern struct { entry: EntryOut, open: OpenOut };
        try self.replyReferenced(header, ino, Reply{
            .entry = .{ .nodeid = ino, .entry_valid = cache_seconds, .attr_valid = cache_seconds, .attr = self.attrOf(ino, node) },
            .open = .{ .fh = fh },
        }, fh);
    }

    fn opWrite(self: *Mount, header: *const InHeader, body: []const u8) !void {
        const in = readStruct(WriteIn, body) orelse return self.replyError(header, .INVAL);
        const data = body[@sizeOf(WriteIn)..];
        if (data.len < in.size) return self.replyError(header, .INVAL);

        {
            self.lock.lock();
            defer self.lock.unlock();
            const h = self.handles.getPtr(in.fh) orelse return self.replyError(header, .BADF);
            var done: usize = 0;
            while (done < in.size) {
                const rc = linux.pwrite(h.fd, data[done..].ptr, in.size - done, @intCast(in.offset + done));
                if (linux.errno(rc) != .SUCCESS) return self.replyError(header, .IO);
                done += rc;
            }
            h.dirty = true;
            if (self.table.map.getPtr(h.ino)) |e| {
                const node = &e.data;
                node.size = @max(node.size, in.offset + in.size);
                node.mtime = nowSeconds();
            }
        }
        try self.replyStruct(header, WriteOut{ .size = in.size });
    }

    fn opSetattr(self: *Mount, header: *const InHeader, body: []const u8) !void {
        const in = readStruct(SetattrIn, body) orelse return self.replyError(header, .INVAL);
        const node = self.inode(header.nodeid) orelse return self.replyError(header, .NOENT);
        if (in.valid & FATTR_SIZE != 0) {
            if (node.kind != .swarm_file) return self.replyError(header, if (node.kind == .file) .ROFS else .ISDIR);
            const fh = blk: {
                self.lock.lock();
                defer self.lock.unlock();
                if (in.valid & FATTR_FH != 0 and self.handles.contains(in.fh)) break :blk in.fh;
                break :blk self.writing.get(header.nodeid);
            };
            if (fh) |f| {
                self.lock.lock();
                defer self.lock.unlock();
                const h = self.handles.getPtr(f) orelse return self.replyError(header, .BADF);
                if (linux.errno(linux.ftruncate(h.fd, @intCast(in.size))) != .SUCCESS) return self.replyError(header, .IO);
                h.dirty = true;
                if (self.table.map.getPtr(header.nodeid)) |e| {
                    e.data.size = in.size;
                }
            } else {
                // Truncate without an open file: stage, cut, add at once.
                const f = self.newHandle(header.nodeid, if (in.size == 0) null else node) catch |err| return self.replyError(header, errnoFor(err));
                var cut_failed = false;
                var h_removed = blk: {
                    self.lock.lock();
                    defer self.lock.unlock();
                    const h = self.handles.getPtr(f) orelse return self.replyError(header, .BADF);
                    if (linux.errno(linux.ftruncate(h.fd, @intCast(in.size))) != .SUCCESS) {
                        cut_failed = true;
                    } else {
                        h.dirty = true;
                    }
                    break :blk self.handles.fetchRemove(f).?.value;
                };
                // dropHandle takes the lock itself, so it runs after the
                // block above has released it.
                if (cut_failed) {
                    self.dropHandle(f, h_removed);
                    return self.replyError(header, .IO);
                }
                self.commit(&h_removed) catch |err| {
                    std.debug.print("fuse: truncate inode {d} failed: {any}\n", .{ h_removed.ino, err });
                };
                self.dropHandle(f, h_removed);
            }
        } else if (node.kind != .swarm_file and node.kind != .swarm_dir and in.valid != 0) {
            // Times and modes on read-only parts are accepted and ignored,
            // so cp -p and touch don't fail; nothing is stored for them.
        }
        const updated = self.inode(header.nodeid) orelse return self.replyError(header, .NOENT);
        try self.replyStruct(header, AttrOut{ .attr_valid = cache_seconds, .attr = self.attrOf(header.nodeid, updated) });
    }

    fn opRelease(self: *Mount, header: *const InHeader, body: []const u8) !void {
        const in = readStruct(ReleaseIn, body) orelse return self.replyEmpty(header);
        // The kernel sends RELEASE after close() has returned, so other
        // workers may already serve a fresh open, read or unlink of this
        // file. The handle stays registered (reads use its staging copy)
        // until the commit has stored the blocks and updated the inode;
        // only then is it removed. No other request uses this fh any more.
        var h = blk: {
            self.lock.lock();
            defer self.lock.unlock();
            break :blk self.handles.get(in.fh) orelse return self.replyEmpty(header);
        };
        self.commit(&h) catch |err| std.debug.print("fuse: saving inode {d} failed: {any}\n", .{ h.ino, err });
        {
            self.lock.lock();
            defer self.lock.unlock();
            _ = self.handles.remove(in.fh);
        }
        self.dropHandle(in.fh, h);
        try self.replyEmpty(header);
    }

    fn opMkdir(self: *Mount, header: *const InHeader, body: []const u8) !void {
        if (body.len <= @sizeOf(MkdirIn)) return self.replyError(header, .INVAL);
        const name = std.mem.sliceTo(body[@sizeOf(MkdirIn)..], 0);
        var arena_state = std.heap.ArenaAllocator.init(self.allocator);
        defer arena_state.deinit();
        const base = blk: {
            self.lock.lock();
            defer self.lock.unlock();
            _ = self.swarmChildPath(arena_state.allocator(), header.nodeid, name) catch |err| return self.replyError(header, errnoFor(err));
            break :blk try self.swarmPath(arena_state.allocator(), header.nodeid);
        };
        if (try self.childEntry(header.nodeid, name) != null) return self.replyError(header, .EXIST);
        const swarm = self.swarm orelse return self.replyError(header, .ROFS);
        swarm.makeDir(base, name) catch |err| return self.replyError(header, errnoFor(err));
        const ino = (try self.lookupChild(header.nodeid, name)) orelse return self.replyError(header, .IO);
        const node = self.inode(ino) orelse return self.replyError(header, .IO);
        try self.replyReferenced(header, ino, EntryOut{ .nodeid = ino, .entry_valid = cache_seconds, .attr_valid = cache_seconds, .attr = self.attrOf(ino, node) }, null);
    }

    fn opRemove(self: *Mount, header: *const InHeader, name: []const u8, want: enum { file, dir }) !void {
        var arena_state = std.heap.ArenaAllocator.init(self.allocator);
        defer arena_state.deinit();
        const path = blk: {
            self.lock.lock();
            defer self.lock.unlock();
            break :blk self.swarmChildPath(arena_state.allocator(), header.nodeid, name) catch |err| return self.replyError(header, errnoFor(err));
        };
        const node = (try self.childEntry(header.nodeid, name)) orelse return self.replyError(header, .NOENT);
        const folder = self.swarm orelse return self.replyError(header, .ROFS);
        switch (want) {
            .file => if (node.kind != .swarm_file) return self.replyError(header, .ISDIR),
            .dir => {
                if (node.kind != .swarm_dir) return self.replyError(header, .NOTDIR);
                if (!(try folder.isEmptyDir(path))) return self.replyError(header, .NOTEMPTY);
            },
        }
        folder.remove(path) catch |err| switch (err) {
            error.FileNotFound => {},
            else => return self.replyError(header, errnoFor(err)),
        };
        {
            self.lock.lock();
            defer self.lock.unlock();
            self.table.detach(header.nodeid, name);
        }
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
        const from = blk: {
            self.lock.lock();
            defer self.lock.unlock();
            break :blk self.swarmChildPath(arena, header.nodeid, old_name) catch |err| return self.replyError(header, errnoFor(err));
        };
        const to = blk: {
            self.lock.lock();
            defer self.lock.unlock();
            break :blk self.swarmChildPath(arena, newdir, new_name) catch |err| return self.replyError(header, errnoFor(err));
        };

        // A file still open for writing is saved before it moves.
        const maybe_h_copy = blk: {
            self.lock.lock();
            defer self.lock.unlock();
            const moved_ino = self.table.find(header.nodeid, old_name);
            if (moved_ino) |ino| {
                if (self.writing.get(ino)) |fh| {
                    if (self.handles.get(fh)) |h| {
                        break :blk h;
                    }
                }
            }
            break :blk null;
        };
        if (maybe_h_copy) |h_const| {
            var h = h_const;
            self.commit(&h) catch {};
        }

        const folder = self.swarm orelse return self.replyError(header, .ROFS);
        folder.move(from, to, .{ .replace = replace }) catch |err| return self.replyError(header, errnoFor(err));
        {
            self.lock.lock();
            defer self.lock.unlock();
            try self.table.move(header.nodeid, old_name, newdir, new_name);
        }
        try self.replyEmpty(header);
    }

    // ---- Tree navigation ----

    fn inode(self: *Mount, ino: u64) ?Inode {
        self.lock.lock();
        defer self.lock.unlock();
        return if (self.table.map.get(ino)) |e| e.data else null;
    }

    fn attr(self: *Mount, ino: u64) Attr {
        self.lock.lock();
        defer self.lock.unlock();
        return self.attrOf(ino, if (self.table.map.get(ino)) |e| e.data else .{ .kind = .root });
    }

    fn attrOf(self: *Mount, ino: u64, node: Inode) Attr {
        const is_file = node.kind.isFile();
        return .{
            .ino = ino,
            .size = node.size,
            .blocks = (node.size +| 511) / 512,
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
    fn childrenOf(self: *Mount, arena: std.mem.Allocator, parent_ino: u64, parent: Inode) ![]Child {
        var out: std.ArrayList(Child) = .empty;
        switch (parent.kind) {
            .file, .swarm_file => return error.NotADirectory,
            .root => {
                if (self.swarm != null) {
                    try out.append(arena, .{ .name = "Swarm", .node = .{ .kind = .swarm_dir, .mtime = self.mounted_at } });
                }
                if (self.refresh.thread != null) {
                    self.requestRefresh();
                    self.refresh.mutex.lock();
                    if (!self.refresh.first_done and !self.stopping.load(.acquire)) {
                        self.refresh.cond.timedWait(&self.refresh.mutex, first_refresh_wait_ms * std.time.ns_per_ms);
                    }
                    self.refresh.mutex.unlock();
                } else {
                    self.refreshAll();
                }
                self.lock.lock();
                defer self.lock.unlock();
                for (self.devices.items, 0..) |d, i| {
                    // A device without a name yet (naming failed) is not listed.
                    if (!d.online or d.name.len == 0) continue;
                    try out.append(arena, .{ .name = try arena.dupe(u8, d.name), .node = .{
                        .kind = .device,
                        .device = @intCast(i),
                        .mtime = self.mounted_at,
                    } });
                }
            },
            .device => {
                self.lock.lock();
                defer self.lock.unlock();
                if (parent.device >= self.devices.items.len) return out.items;
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
                const path = blk: {
                    self.lock.lock();
                    defer self.lock.unlock();
                    break :blk try self.swarmPath(arena, parent_ino);
                };
                const items = try folder.list(arena, path);
                // Files still being written aren't in the manifest yet.
                {
                    self.lock.lock();
                    defer self.lock.unlock();
                    var hit = self.handles.valueIterator();
                    while (hit.next()) |h| {
                        const e = self.table.map.get(h.ino) orelse continue;
                        if (e.parent != parent_ino) continue;
                        const name = e.key[8..];
                        const listed = for (items) |it| {
                            if (std.mem.eql(u8, it.name, name)) break true;
                        } else false;
                        if (listed) continue;
                        try out.append(arena, .{ .name = try arena.dupe(u8, name), .node = e.data });
                    }
                }
                for (items) |it| {
                    try out.append(arena, .{ .name = it.name, .node = .{
                        .kind = if (it.dir) .swarm_dir else .swarm_file,
                        .cid = it.cid orelse [_]u8{0} ** 32,
                        .size = it.size,
                        .mtime = it.mtime,
                        .author = it.author_id orelse [_]u8{0} ** 32,
                    } });
                }
            },
            .dir => {
                const remote = blk: {
                    self.lock.lock();
                    defer self.lock.unlock();
                    if (parent.device >= self.devices.items.len) return error.FileNotFound;
                    break :blk self.devices.items[parent.device].remote;
                };
                const listing = try tree.listDir(arena, remote.loader(), &parent.cid);
                for (listing.entries) |e| {
                    try out.append(arena, .{ .name = try arena.dupe(u8, e.name), .node = .{
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

    /// A listing lookup never allocates a persistent inode.
    fn childEntry(self: *Mount, parent_ino: u64, name: []const u8) !?Inode {
        const parent = self.inode(parent_ino) orelse return null;
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const entries = try self.childrenOf(arena.allocator(), parent_ino, parent);
        for (entries) |e| if (std.mem.eql(u8, e.name, name)) {
            return e.node;
        };
        return null;
    }

    fn lookupChild(self: *Mount, parent: u64, name: []const u8) !?u64 {
        if (try self.childEntry(parent, name)) |node| return try self.upsert(parent, name, node);
        self.lock.lock();
        defer self.lock.unlock();
        self.table.detach(parent, name);
        return null;
    }

    fn sameInode(old: Inode, new: Inode) bool {
        return old.kind.isFile() == new.kind.isFile();
    }

    fn upsert(self: *Mount, parent: u64, name: []const u8, node: Inode) !u64 {
        self.lock.lock();
        defer self.lock.unlock();
        return self.table.getOrCreate(parent, name, node, sameInode);
    }

    fn opBatchForget(self: *Mount, body: []const u8) void {
        const in = readStruct(BatchForgetIn, body) orelse return;
        const n = @min(in.count, (body.len - @sizeOf(BatchForgetIn)) / @sizeOf(ForgetOne));
        self.lock.lock();
        defer self.lock.unlock();
        for (0..n) |i| {
            const one = readStruct(ForgetOne, body[8 + i * 16 ..]).?;
            self.table.unref(one.nodeid, one.nlookup);
        }
    }

    fn replyReferenced(self: *Mount, header: *const InHeader, ino: u64, value: anytype, fh: ?u64) !void {
        {
            self.lock.lock();
            self.table.ref(ino);
            self.lock.unlock();
        }
        const delivered = self.replyValue(header, value) catch |err| {
            self.undoReply(ino, fh);
            return err;
        };
        if (!delivered) self.undoReply(ino, fh);
    }

    fn undoReply(self: *Mount, ino: u64, fh: ?u64) void {
        if (fh) |f| {
            const removed = blk: {
                self.lock.lock();
                defer self.lock.unlock();
                break :blk self.handles.fetchRemove(f);
            };
            if (removed) |kv| {
                self.dropHandle(f, kv.value);
            }
        }
        self.lock.lock();
        defer self.lock.unlock();
        self.table.unref(ino, 1);
    }

    // ---- Replies ----

    fn replyStruct(self: *Mount, header: *const InHeader, value: anytype) !void {
        _ = try self.replyValue(header, value);
    }

    fn replyValue(self: *Mount, header: *const InHeader, value: anytype) !bool {
        const payload = std.mem.asBytes(&value);
        try tl_reply.resize(self.allocator, @sizeOf(OutHeader) + payload.len);
        const out = OutHeader{ .len = @intCast(tl_reply.items.len), .@"error" = 0, .unique = header.unique };
        @memcpy(tl_reply.items[0..@sizeOf(OutHeader)], std.mem.asBytes(&out));
        @memcpy(tl_reply.items[@sizeOf(OutHeader)..], payload);
        return self.send(tl_reply.items);
    }

    fn replyEmpty(self: *Mount, header: *const InHeader) !void {
        const out = OutHeader{ .len = @sizeOf(OutHeader), .@"error" = 0, .unique = header.unique };
        _ = try self.send(std.mem.asBytes(&out));
    }

    fn replyBytes(self: *Mount, header: *const InHeader, bytes: []const u8) !void {
        try tl_reply.resize(self.allocator, @sizeOf(OutHeader) + bytes.len);
        const out = OutHeader{ .len = @intCast(tl_reply.items.len), .@"error" = 0, .unique = header.unique };
        @memcpy(tl_reply.items[0..@sizeOf(OutHeader)], std.mem.asBytes(&out));
        @memcpy(tl_reply.items[@sizeOf(OutHeader)..], bytes);
        _ = try self.send(tl_reply.items);
    }

    /// Sends the first `payload_len` bytes after the header slot in `reply`.
    fn sendPrepared(self: *Mount, header: *const InHeader, payload_len: usize) !void {
        const total = @sizeOf(OutHeader) + payload_len;
        const out: *OutHeader = @ptrCast(@alignCast(tl_reply.items.ptr));
        out.* = .{ .len = @intCast(total), .@"error" = 0, .unique = header.unique };
        _ = try self.send(tl_reply.items[0..total]);
    }

    fn replyError(self: *Mount, header: *const InHeader, err: Errno) !void {
        const out = OutHeader{ .len = @sizeOf(OutHeader), .@"error" = -@intFromEnum(err), .unique = header.unique };
        _ = try self.send(std.mem.asBytes(&out));
    }

    fn send(self: *Mount, bytes: []const u8) !bool {
        if (self.send_hook) |hook| return hook(self, bytes);
        const rc = linux.write(self.fd, bytes.ptr, bytes.len);
        switch (linux.errno(rc)) {
            .SUCCESS => {},
            // The request was interrupted and is gone; nothing to answer.
            .NOENT => return false,
            else => |e| {
                std.debug.print("fuse: reply failed: {s}\n", .{@tagName(e)});
                return error.FuseWriteFailed;
            },
        }
        if (rc != bytes.len) return error.FuseWriteFailed;
        return true;
    }
};

fn synthIno(parent: u64, name: []const u8) u64 {
    var h = std.hash.Wyhash.init(0);
    h.update(std.mem.asBytes(&parent));
    h.update(name);
    return (@as(u64, 1) << 63) | (h.final() >> 1);
}

fn readStruct(comptime T: type, body: []const u8) ?T {
    if (body.len < @sizeOf(T)) return null;
    var value: T = undefined;
    @memcpy(std.mem.asBytes(&value), body[0..@sizeOf(T)]);
    return value;
}

fn errnoFor(err: anyerror) Errno {
    return switch (err) {
        error.FileNotFound => .NOENT,
        error.NotADirectory => .NOTDIR,
        error.IsDirectory => .ISDIR,
        error.ReadOnly => .ROFS,
        error.InvalidPath, error.InvalidName => .INVAL,
        error.NameTooLong => .NAMETOOLONG,
        error.DeviceOrResourceBusy => .BUSY,
        error.DirNotEmpty => .NOTEMPTY,
        error.PathAlreadyExists => .EXIST,
        error.PeerDown => .IO,
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

// ---- Tests ----

test "fuse: attr size does not overflow on 2^64-1" {
    var mount = Mount{
        .table = try InodeTable.init(std.testing.allocator, .{ .kind = .root }),
        .allocator = std.testing.allocator,
        .block_manager = undefined,
        .store = undefined,
        .uid = 1000,
        .gid = 1000,
    };
    defer mount.table.deinit();
    mount.table.map.getPtr(root_id).?.data = .{ .kind = .file, .size = std.math.maxInt(u64), .mtime = 0 };
    const a = mount.attr(1);
    try std.testing.expectEqual(std.math.maxInt(u64), a.size);
    try std.testing.expectEqual(std.math.maxInt(u64) / 512, a.blocks);
}

test "fuse: dispatch skips header shorter than InHeader" {
    var mount = Mount{
        .table = try InodeTable.init(std.testing.allocator, .{ .kind = .root }),
        .allocator = std.testing.allocator,
        .block_manager = undefined,
        .store = undefined,
        .uid = 1000,
        .gid = 1000,
    };
    defer mount.table.deinit();
    var short_buf align(8) = [_]u8{0} ** 40;
    const header: *InHeader = @ptrCast(&short_buf);
    header.len = 20; // less than @sizeOf(InHeader)
    header.opcode = 1;
    header.unique = 1;
    header.nodeid = 1;
    const done = try mount.dispatch(&short_buf);
    try std.testing.expect(!done);
}

test "fuse: dropHandle clears writing entry when fh matches" {
    var mount = Mount{
        .table = try InodeTable.init(std.testing.allocator, .{ .kind = .root }),
        .allocator = std.testing.allocator,
        .block_manager = undefined,
        .store = undefined,
        .uid = 1000,
        .gid = 1000,
    };
    defer mount.table.deinit();
    defer mount.handles.deinit(std.testing.allocator);
    defer mount.writing.deinit(std.testing.allocator);
    try mount.writing.put(std.testing.allocator, 42, 10);
    const h = Handle{
        .ino = 42,
        .staging = try std.testing.allocator.dupeZ(u8, "/dev/null"),
        .fd = -1,
        .dirty = false,
    };
    mount.dropHandle(10, h);
    try std.testing.expect(!mount.writing.contains(42));
}

test "fuse: synthIno has bit 63 set, is stable, and differs for different inputs" {
    const s1 = synthIno(1, "foo");
    const s2 = synthIno(1, "foo");
    const s3 = synthIno(1, "bar");
    const s4 = synthIno(2, "foo");
    try std.testing.expect(s1 & (@as(u64, 1) << 63) != 0);
    try std.testing.expectEqual(s1, s2);
    try std.testing.expect(s1 != s3);
    try std.testing.expect(s1 != s4);
    try std.testing.expect(s1 != 0);
}
