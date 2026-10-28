const std = @import("std");
const builtin = @import("builtin");
const Block = @import("block.zig").Block;
const sync = @import("../sync.zig");
const env_mod = @import("../env.zig");

/// Length of a block's file name: its CID in lowercase hex. Temporary files
/// are longer, so they never match.
const hex_cid_len = 64;

pub const StorageEngine = struct {
    root_dir: std.Io.Dir,
    allocator: std.mem.Allocator,
    mutex: sync.Mutex = .{},
    /// Blocks held outside the store (shared folders' file bytes). Asked
    /// only when no block file exists; what it returns is verified like any
    /// stored block.
    external: ?External = null,
    /// Most bytes of block files this store may hold, or null for no limit
    /// (the default). Set with setQuota.
    quota: ?u64 = null,
    /// Bytes of block files held here. Only kept current while `quota` is
    /// set: setQuota counts the existing blocks once, when a quota is first
    /// set, so an unlimited store does no counting at open or on put.
    used_bytes: u64 = 0,

    pub const External = struct {
        ctx: *anyopaque,
        /// Caller-owned block bytes for `cid`, or null when not held.
        getFn: *const fn (ctx: *anyopaque, cid: *const [32]u8, allocator: std.mem.Allocator) anyerror!?[]u8,
        hasFn: *const fn (ctx: *anyopaque, cid: *const [32]u8) bool,
    };

    pub fn init(allocator: std.mem.Allocator, path: []const u8) !StorageEngine {
        var expanded_path: []const u8 = path;
        var owned_path: ?[]const u8 = null;
        defer if (owned_path) |p| allocator.free(p);

        if (std.mem.startsWith(u8, path, "~")) {
            const home_env = if (builtin.os.tag == .windows) "USERPROFILE" else "HOME";
            if (env_mod.getEnv(allocator, home_env)) |home| {
                defer allocator.free(home);
                owned_path = try std.fs.path.join(allocator, &.{ home, path[1..] });
                expanded_path = owned_path.?;
            }
        }

        const io = std.Io.Threaded.global_single_threaded.io();
        std.Io.Dir.cwd().createDirPath(io, expanded_path) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };

        // Iterable so setQuota can count the blocks already stored.
        const dir = try std.Io.Dir.cwd().openDir(io, expanded_path, .{ .iterate = true });
        return StorageEngine{
            .root_dir = dir,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *StorageEngine) void {
        const io = std.Io.Threaded.global_single_threaded.io();
        self.root_dir.close(io);
    }

    /// Caps the bytes of block files kept here; null removes the cap. Turning
    /// a cap on counts the blocks already stored with one directory scan, so
    /// that cost is paid here and not at open.
    pub fn setQuota(self: *StorageEngine, quota: ?u64) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (quota != null and self.quota == null) {
            self.used_bytes = try self.sumBlocksLocked();
        }
        self.quota = quota;
    }

    /// Stores a block after checking its hash. Content addressing makes this
    /// idempotent; the block is written to a temporary file and renamed into
    /// place, so a crash never leaves a truncated block under its CID.
    /// Returns error.StorageFull, writing nothing, when the block would take
    /// the store past its quota.
    pub fn put(self: *StorageEngine, block: Block) !void {
        var hash: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(block.data, &hash, .{});
        if (!std.mem.eql(u8, &hash, &block.cid)) {
            return error.HashMismatch;
        }

        self.mutex.lock();
        defer self.mutex.unlock();

        const hex_cid = std.fmt.bytesToHex(block.cid, .lower);
        if (self.hasLocked(&hex_cid)) return;

        const size: u64 = block.data.len;
        if (self.quota) |limit| {
            if (self.used_bytes > limit or size > limit - self.used_bytes) return error.StorageFull;
        }

        const io = std.Io.Threaded.global_single_threaded.io();
        const tmp_name = hex_cid ++ ".tmp".*;
        var file = try self.root_dir.createFile(io, &tmp_name, .{});
        errdefer self.root_dir.deleteFile(io, &tmp_name) catch {};
        {
            defer file.close(io);
            try file.writePositionalAll(io, block.data, 0);
        }
        try self.root_dir.rename(&tmp_name, self.root_dir, &hex_cid, io);
        if (self.quota != null) self.used_bytes += size;
    }

    pub fn has(self: *StorageEngine, cid: []const u8) bool {
        if (cid.len != 32) return false;
        const hex_cid = std.fmt.bytesToHex(cid[0..32], .lower);
        {
            self.mutex.lock();
            defer self.mutex.unlock();
            if (self.hasLocked(&hex_cid)) return true;
        }
        // Outside the lock: the external source may take locks of its own.
        const ext = self.external orelse return false;
        return ext.hasFn(ext.ctx, cid[0..32]);
    }

    fn hasLocked(self: *StorageEngine, hex_cid: []const u8) bool {
        const io = std.Io.Threaded.global_single_threaded.io();
        _ = self.root_dir.statFile(io, hex_cid, .{}) catch return false;
        return true;
    }

    /// Total size of the block files in the directory. Caller holds the lock.
    fn sumBlocksLocked(self: *StorageEngine) !u64 {
        const io = std.Io.Threaded.global_single_threaded.io();
        var total: u64 = 0;
        var it = self.root_dir.iterate();
        while (try it.next(io)) |entry| {
            if (entry.kind != .file or entry.name.len != hex_cid_len) continue;
            for (entry.name) |c| {
                if (!((c >= '0' and c <= '9') or (c >= 'a' and c <= 'f'))) break;
            } else {
                total = try std.math.add(u64, total, (try self.root_dir.statFile(io, entry.name, .{})).size);
            }
        }
        return total;
    }

    /// The bytes of a block stored here (not `external`), unverified, or
    /// null. For walking this device's own parent blocks cheaply: a shared
    /// file's leaves are never read.
    pub fn getLocal(self: *StorageEngine, cid: *const [32]u8, allocator: std.mem.Allocator) !?[]u8 {
        const hex_cid = std.fmt.bytesToHex(cid.*, .lower);
        return self.readStored(&hex_cid, allocator);
    }

    /// Returns the block, or null if it is not stored. The data is verified
    /// against the CID so on-disk corruption is reported, not returned.
    pub fn get(self: *StorageEngine, cid: []const u8, allocator: std.mem.Allocator) !?Block {
        if (cid.len != 32) return error.InvalidBlock;
        const hex_cid = std.fmt.bytesToHex(cid[0..32], .lower);

        const buffer = (try self.readStored(&hex_cid, allocator)) orelse blk: {
            // Not stored here. The external source reads and hashes files of
            // its own, so it is asked without the engine lock held.
            const ext = self.external orelse return null;
            break :blk (try ext.getFn(ext.ctx, cid[0..32], allocator)) orelse return null;
        };
        errdefer allocator.free(buffer);

        var hash: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(buffer, &hash, .{});
        if (!std.mem.eql(u8, &hash, cid)) return error.CorruptBlock;

        return Block{
            .cid = cid[0..32].*,
            .data = buffer,
        };
    }

    /// The bytes of the block file `hex_cid`, caller-owned, or null when
    /// there is none. Holds the lock for the disk read.
    fn readStored(self: *StorageEngine, hex_cid: []const u8, allocator: std.mem.Allocator) !?[]u8 {
        self.mutex.lock();
        defer self.mutex.unlock();

        const io = std.Io.Threaded.global_single_threaded.io();
        var file = self.root_dir.openFile(io, hex_cid, .{}) catch |err| switch (err) {
            error.FileNotFound => return null,
            else => return err,
        };
        defer file.close(io);

        const size = (try file.stat(io)).size;
        const buffer = try allocator.alloc(u8, size);
        errdefer allocator.free(buffer);
        if (try file.readPositionalAll(io, buffer, 0) != size) return error.ReadError;
        return buffer;
    }
};

test "put refuses a block that would pass the quota and writes nothing" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const test_path = "test_storage_engine_quota";
    std.Io.Dir.cwd().deleteTree(io, test_path) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, test_path) catch {};

    var engine = try StorageEngine.init(allocator, test_path);
    defer engine.deinit();
    try engine.setQuota(10);

    try engine.put(Block.new("123456"));
    const over = Block.new("abcdef");
    try std.testing.expectError(error.StorageFull, engine.put(over));
    try std.testing.expect(!engine.has(&over.cid));
    try std.testing.expectEqual(@as(u64, 6), engine.used_bytes);

    // Idempotent puts do not consume more quota.
    try engine.put(Block.new("123456"));
    try std.testing.expectEqual(@as(u64, 6), engine.used_bytes);

    // Filling the quota exactly is allowed.
    try engine.put(Block.new("wxyz"));
    try std.testing.expectEqual(@as(u64, 10), engine.used_bytes);

    // Only the two stored blocks are in the directory: the refused put left no temporary file.
    var count: usize = 0;
    var it = engine.root_dir.iterate();
    while (try it.next(io)) |_| count += 1;
    try std.testing.expectEqual(@as(usize, 2), count);
}

test "setQuota counts the blocks already stored" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const test_path = "test_storage_engine_quota_reopen";
    std.Io.Dir.cwd().deleteTree(io, test_path) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, test_path) catch {};

    {
        var first = try StorageEngine.init(allocator, test_path);
        defer first.deinit();
        try first.put(Block.new("aaaa"));
    }

    var engine = try StorageEngine.init(allocator, test_path);
    defer engine.deinit();
    try engine.setQuota(6);
    try std.testing.expectEqual(@as(u64, 4), engine.used_bytes);
    try std.testing.expectError(error.StorageFull, engine.put(Block.new("bbb")));
    try engine.put(Block.new("bb"));

    try engine.setQuota(null);
    try engine.put(Block.new("unlimited again"));
    try engine.setQuota(20);
    try std.testing.expectEqual(@as(u64, 21), engine.used_bytes);
    try std.testing.expectError(error.StorageFull, engine.put(Block.new("x")));
}

test "external source is called without the engine lock" {
    const allocator = std.testing.allocator;
    const test_path = "test_storage_engine_external";
    const io = std.Io.Threaded.global_single_threaded.io();
    std.Io.Dir.cwd().deleteTree(io, test_path) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, test_path) catch {};

    var engine = try StorageEngine.init(allocator, test_path);
    defer engine.deinit();

    const payload = "held outside the store";
    const block = Block.new(payload);

    const Source = struct {
        store: *StorageEngine,
        cid: [32]u8,
        data: []const u8,

        fn getFn(ctx: *anyopaque, cid: *const [32]u8, alloc: std.mem.Allocator) anyerror!?[]u8 {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            // Re-enters the engine: this would deadlock if get held the lock.
            if (!self.store.has(cid)) return null;
            return try alloc.dupe(u8, self.data);
        }

        fn hasFn(ctx: *anyopaque, cid: *const [32]u8) bool {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            return std.mem.eql(u8, cid, &self.cid);
        }
    };
    var source = Source{ .store = &engine, .cid = block.cid, .data = payload };
    engine.external = .{ .ctx = &source, .getFn = Source.getFn, .hasFn = Source.hasFn };

    const got = (try engine.get(&block.cid, allocator)) orelse return error.TestUnexpectedResult;
    defer allocator.free(got.data);
    try std.testing.expectEqualStrings(payload, got.data);
}
