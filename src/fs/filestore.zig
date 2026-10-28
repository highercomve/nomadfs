//! Leaf blocks of shared files, served from the files themselves. A shared
//! folder is not copied into the block store: the scanner records where
//! each leaf's bytes sit (file, offset, length) and only the small parent
//! and dir blocks are stored. The StorageEngine asks here for blocks it has
//! no file for (StorageEngine.External), so peers fetch shared files with
//! the same GET_BLOCK as anything else.
//!
//! Bytes are re-hashed on every read: a file edited since the scan no
//! longer matches its recorded CIDs and reads as missing, never as wrong
//! data. The next rescan records the new content.

const std = @import("std");
const sync = @import("../sync.zig");
const storage = @import("../storage/mod.zig");
const codec = storage.dag.codec;

pub const Cid = codec.Cid;

pub const Leaf = struct {
    cid: Cid,
    offset: u64,
    len: u32,
};

const Ref = struct {
    file: u32,
    offset: u64,
    len: u32,
};

/// Where one share's leaves live. Built by a scan, then handed to the
/// Filestore whole, so readers never see a half-built table.
pub const Table = struct {
    allocator: std.mem.Allocator,
    /// File index -> absolute path.
    paths: std.ArrayList([]const u8) = .empty,
    refs: std.AutoHashMapUnmanaged(Cid, Ref) = .empty,

    pub fn init(allocator: std.mem.Allocator) Table {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Table) void {
        for (self.paths.items) |p| self.allocator.free(p);
        self.paths.deinit(self.allocator);
        self.refs.deinit(self.allocator);
    }

    /// Records every leaf of the file at `path`.
    pub fn addFile(self: *Table, path: []const u8, leaves: []const Leaf) !void {
        if (leaves.len == 0) return;
        const owned = try self.allocator.dupe(u8, path);
        errdefer self.allocator.free(owned);
        try self.paths.ensureUnusedCapacity(self.allocator, 1);
        try self.refs.ensureUnusedCapacity(self.allocator, @intCast(leaves.len));
        const file: u32 = @intCast(self.paths.items.len);
        self.paths.appendAssumeCapacity(owned);
        for (leaves) |leaf| {
            // Identical chunks in several files: any copy serves.
            self.refs.putAssumeCapacity(leaf.cid, .{ .file = file, .offset = leaf.offset, .len = leaf.len });
        }
    }
};

pub const Filestore = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    /// Share name -> its tables: one after a scan, or the segments a first
    /// scan hands over as it goes (append). Guarded by `mutex`.
    tables: std.StringHashMapUnmanaged(Segments) = .empty,
    mutex: sync.Mutex = .{},

    pub fn init(allocator: std.mem.Allocator, io: std.Io) Filestore {
        return .{ .allocator = allocator, .io = io };
    }

    pub fn deinit(self: *Filestore) void {
        var it = self.tables.iterator();
        while (it.next()) |e| {
            self.allocator.free(e.key_ptr.*);
            self.freeSegments(e.value_ptr);
        }
        self.tables.deinit(self.allocator);
    }

    const Segments = std.ArrayList(*Table);

    fn freeSegments(self: *Filestore, segments: *Segments) void {
        for (segments.items) |t| {
            t.deinit();
            self.allocator.destroy(t);
        }
        segments.deinit(self.allocator);
    }

    /// Installs `table` (heap-allocated with this allocator) as `share`'s,
    /// replacing and freeing the previous ones.
    pub fn replace(self: *Filestore, share: []const u8, table: *Table) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        const segments = try self.segmentsLocked(share);
        try segments.ensureUnusedCapacity(self.allocator, 1);
        for (segments.items) |t| {
            t.deinit();
            self.allocator.destroy(t);
        }
        segments.clearRetainingCapacity();
        segments.appendAssumeCapacity(table);
    }

    /// Adds `table` to `share`'s, keeping the others: a first scan hands
    /// over the files it has done so far, then starts a new table.
    pub fn append(self: *Filestore, share: []const u8, table: *Table) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        const segments = try self.segmentsLocked(share);
        try segments.append(self.allocator, table);
    }

    fn segmentsLocked(self: *Filestore, share: []const u8) !*Segments {
        const gop = try self.tables.getOrPut(self.allocator, share);
        if (!gop.found_existing) {
            gop.key_ptr.* = self.allocator.dupe(u8, share) catch |err| {
                self.tables.removeByPtr(gop.key_ptr);
                return err;
            };
            gop.value_ptr.* = .empty;
        }
        return gop.value_ptr;
    }

    pub fn remove(self: *Filestore, share: []const u8) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        var kv = self.tables.fetchRemove(share) orelse return;
        self.allocator.free(kv.key);
        self.freeSegments(&kv.value);
    }

    /// Adapter for StorageEngine.external.
    pub fn external(self: *Filestore) storage.engine.StorageEngine.External {
        return .{ .ctx = self, .getFn = getErased, .hasFn = hasErased };
    }

    const Located = struct { path_buf: [std.fs.max_path_bytes]u8, path_len: usize, ref: Ref };

    fn locate(self: *Filestore, cid: *const Cid) ?Located {
        self.mutex.lock();
        defer self.mutex.unlock();
        var it = self.tables.valueIterator();
        while (it.next()) |segments| for (segments.items) |table| {
            const ref = table.refs.get(cid.*) orelse continue;
            const path = table.paths.items[ref.file];
            var out = Located{ .path_buf = undefined, .path_len = path.len, .ref = ref };
            if (path.len > out.path_buf.len) return null;
            @memcpy(out.path_buf[0..path.len], path);
            return out;
        };
        return null;
    }

    pub fn has(self: *Filestore, cid: *const Cid) bool {
        return self.locate(cid) != null;
    }

    /// The leaf block (tag byte + data) read back from its file, or null
    /// when the file is gone or no longer holds those bytes.
    pub fn get(self: *Filestore, cid: *const Cid, allocator: std.mem.Allocator) !?[]u8 {
        const at = self.locate(cid) orelse return null;
        const path = at.path_buf[0..at.path_len];

        var file = openRegular(self.io, std.Io.Dir.cwd(), path) catch return null;
        defer file.close(self.io);
        const block = try allocator.alloc(u8, 1 + @as(usize, at.ref.len));
        errdefer allocator.free(block);
        block[0] = @intFromEnum(codec.Tag.leaf);
        const n = file.readPositionalAll(self.io, block[1..], at.ref.offset) catch {
            allocator.free(block);
            return null;
        };

        var hash: Cid = undefined;
        std.crypto.hash.sha2.Sha256.hash(block, &hash, .{});
        if (n != at.ref.len or !std.mem.eql(u8, &hash, cid)) {
            allocator.free(block);
            return null; // edited since the scan
        }
        return block;
    }

    fn getErased(ctx: *anyopaque, cid: *const [32]u8, allocator: std.mem.Allocator) anyerror!?[]u8 {
        const self: *Filestore = @ptrCast(@alignCast(ctx));
        return self.get(cid, allocator);
    }

    fn hasErased(ctx: *anyopaque, cid: *const [32]u8) bool {
        const self: *Filestore = @ptrCast(@alignCast(ctx));
        return self.has(cid);
    }
};

/// Do not follow a swapped-in symlink or wait for a FIFO writer.
pub fn openRegular(io: std.Io, dir: std.Io.Dir, path: []const u8) !std.Io.File {
    var file: std.Io.File = if (@import("builtin").os.tag == .windows)
        try dir.openFile(io, path, .{ .follow_symlinks = false })
    else
        .{
            .handle = try std.posix.openat(dir.handle, path, .{ .ACCMODE = .RDONLY, .NOFOLLOW = true, .NONBLOCK = true, .CLOEXEC = true }, 0),
            .flags = .{ .nonblocking = true },
        };
    errdefer file.close(io);
    if ((try file.stat(io)).kind != .file) return error.NotRegularFile;
    return file;
}
