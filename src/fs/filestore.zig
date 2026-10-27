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
        try self.paths.append(self.allocator, owned);
        const file: u32 = @intCast(self.paths.items.len - 1);
        try self.refs.ensureUnusedCapacity(self.allocator, @intCast(leaves.len));
        for (leaves) |leaf| {
            // Identical chunks in several files: any copy serves.
            self.refs.putAssumeCapacity(leaf.cid, .{ .file = file, .offset = leaf.offset, .len = leaf.len });
        }
    }
};

pub const Filestore = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    /// Share name -> its table. Guarded by `mutex`.
    tables: std.StringHashMapUnmanaged(*Table) = .empty,
    mutex: sync.Mutex = .{},

    pub fn init(allocator: std.mem.Allocator, io: std.Io) Filestore {
        return .{ .allocator = allocator, .io = io };
    }

    pub fn deinit(self: *Filestore) void {
        var it = self.tables.iterator();
        while (it.next()) |e| {
            self.allocator.free(e.key_ptr.*);
            e.value_ptr.*.deinit();
            self.allocator.destroy(e.value_ptr.*);
        }
        self.tables.deinit(self.allocator);
    }

    /// Installs `table` (heap-allocated with this allocator) as `share`'s,
    /// replacing and freeing the previous one.
    pub fn replace(self: *Filestore, share: []const u8, table: *Table) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        const gop = try self.tables.getOrPut(self.allocator, share);
        if (gop.found_existing) {
            gop.value_ptr.*.deinit();
            self.allocator.destroy(gop.value_ptr.*);
        } else {
            gop.key_ptr.* = self.allocator.dupe(u8, share) catch |err| {
                self.tables.removeByPtr(gop.key_ptr);
                return err;
            };
        }
        gop.value_ptr.* = table;
    }

    pub fn remove(self: *Filestore, share: []const u8) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        const kv = self.tables.fetchRemove(share) orelse return;
        self.allocator.free(kv.key);
        kv.value.deinit();
        self.allocator.destroy(kv.value);
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
        while (it.next()) |table| {
            const ref = table.*.refs.get(cid.*) orelse continue;
            const path = table.*.paths.items[ref.file];
            var out = Located{ .path_buf = undefined, .path_len = path.len, .ref = ref };
            if (path.len > out.path_buf.len) return null;
            @memcpy(out.path_buf[0..path.len], path);
            return out;
        }
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

        var file = std.Io.Dir.cwd().openFile(self.io, path, .{}) catch return null;
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
