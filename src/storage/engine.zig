const std = @import("std");
const builtin = @import("builtin");
const Block = @import("block.zig").Block;
const dag_codec = @import("dag/codec.zig");
const sync = @import("../sync.zig");
const env_mod = @import("../env.zig");

/// Length of a block's file name: its CID in lowercase hex. Temporary files
/// are longer, so they never match.
const hex_cid_len = 64;

/// Subdirectory of the store holding the read cache.
const cache_dir_name = "cache";

fn isHexCid(name: []const u8) bool {
    if (name.len != hex_cid_len) return false;
    for (name) |c| if (!((c >= '0' and c <= '9') or (c >= 'a' and c <= 'f'))) return false;
    return true;
}

/// Bytes and count of the block files directly in `dir`.
fn sumDir(dir: std.Io.Dir) !struct { bytes: u64, blocks: u64 } {
    const io = std.Io.Threaded.global_single_threaded.io();
    var bytes: u64 = 0;
    var blocks: u64 = 0;
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file or !isHexCid(entry.name)) continue;
        bytes = try std.math.add(u64, bytes, (try dir.statFile(io, entry.name, .{})).size);
        blocks += 1;
    }
    return .{ .bytes = bytes, .blocks = blocks };
}

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
    /// The read cache: blocks fetched from other devices only to be read,
    /// kept in `cache/` and evicted least recently used first. Everything
    /// else (this device's writes, backups, replicas) lives in the root and
    /// is never evicted. A block in either place counts as held.
    cache_dir: std.Io.Dir,
    /// Most bytes the read cache may hold, or null for no limit. Past it,
    /// the least recently read blocks go until it is back under
    /// 90% of the limit (lowWater).
    cache_limit: ?u64 = null,
    cache_bytes: u64 = 0,
    cache_blocks: u64 = 0,

    pub const External = struct {
        ctx: *anyopaque,
        /// Caller-owned block bytes for `cid`, or null when not held.
        getFn: *const fn (ctx: *anyopaque, cid: *const [32]u8, allocator: std.mem.Allocator) anyerror!?[]u8,
        hasFn: *const fn (ctx: *anyopaque, cid: *const [32]u8) bool,
    };

    pub fn init(allocator: std.mem.Allocator, path: []const u8) !StorageEngine {
        const owned_path = try env_mod.expandHome(allocator, path);
        defer if (owned_path) |p| allocator.free(p);
        const expanded_path = owned_path orelse path;

        const io = std.Io.Threaded.global_single_threaded.io();
        std.Io.Dir.cwd().createDirPath(io, expanded_path) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };

        // Iterable so setQuota can count the blocks already stored.
        const dir = try std.Io.Dir.cwd().openDir(io, expanded_path, .{ .iterate = true });
        errdefer dir.close(io);
        dir.createDirPath(io, cache_dir_name) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };
        const cache_dir = try dir.openDir(io, cache_dir_name, .{ .iterate = true });
        errdefer cache_dir.close(io);
        var engine = StorageEngine{
            .root_dir = dir,
            .allocator = allocator,
            .cache_dir = cache_dir,
        };
        // The cache is bounded, so counting it at open is cheap; it keeps
        // the size the app shows exact.
        const totals = try sumDir(cache_dir);
        engine.cache_bytes = totals.bytes;
        engine.cache_blocks = totals.blocks;
        return engine;
    }

    pub fn deinit(self: *StorageEngine) void {
        const io = std.Io.Threaded.global_single_threaded.io();
        self.cache_dir.close(io);
        self.root_dir.close(io);
    }

    pub const CacheStats = struct { bytes: u64, blocks: u64, limit: ?u64 };

    /// Where this store holds a block.
    pub const Where = enum {
        /// A block this device keeps (its own data, backups, replicas).
        kept,
        /// In the read cache: fetched to be read, evictable.
        cached,
        /// Read from a shared file on this device (the filestore).
        external,
        /// Not here: fetched from another device when read.
        missing,
    };

    pub fn locate(self: *StorageEngine, cid: *const [32]u8) Where {
        const hex_cid = std.fmt.bytesToHex(cid.*, .lower);
        {
            self.mutex.lock();
            defer self.mutex.unlock();
            if (self.rootHasLocked(&hex_cid)) return .kept;
            const io = std.Io.Threaded.global_single_threaded.io();
            if (self.cache_dir.statFile(io, &hex_cid, .{})) |_| return .cached else |_| {}
        }
        if (self.external) |ext| if (ext.hasFn(ext.ctx, cid)) return .external;
        return .missing;
    }

    /// Bytes and blocks this store keeps (not the read cache). Counted from
    /// the directory without the lock: a block written meanwhile may or may
    /// not count.
    pub fn keptUsage(self: *StorageEngine) !struct { bytes: u64, blocks: u64 } {
        const t = try sumDir(self.root_dir);
        return .{ .bytes = t.bytes, .blocks = t.blocks };
    }

    /// Whether `cid` is held here as a leaf (file data). Reads one byte, so a
    /// walk can skip the chunks it already has without reading them; they
    /// were verified when stored. Leaves of shared files count too.
    pub fn heldLeaf(self: *StorageEngine, cid: *const [32]u8) bool {
        const hex_cid = std.fmt.bytesToHex(cid.*, .lower);
        {
            self.mutex.lock();
            defer self.mutex.unlock();
            const io = std.Io.Threaded.global_single_threaded.io();
            const file = self.root_dir.openFile(io, &hex_cid, .{}) catch
                self.cache_dir.openFile(io, &hex_cid, .{}) catch null;
            if (file) |f| {
                defer f.close(io);
                var tag: [1]u8 = undefined;
                const n = f.readPositionalAll(io, &tag, 0) catch return false;
                return n == 1 and tag[0] == @intFromEnum(dag_codec.Tag.leaf);
            }
        }
        // The filestore serves only leaves.
        if (self.external) |ext| return ext.hasFn(ext.ctx, cid);
        return false;
    }

    /// Counted from the directory, so a cache cleared by another process
    /// (the command line while the app runs) reads right.
    pub fn cacheStats(self: *StorageEngine) CacheStats {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (sumDir(self.cache_dir)) |t| {
            self.cache_bytes = t.bytes;
            self.cache_blocks = t.blocks;
        } else |_| {}
        return .{ .bytes = self.cache_bytes, .blocks = self.cache_blocks, .limit = self.cache_limit };
    }

    /// Caps the read cache; null removes the cap. A cap below what is cached
    /// evicts at once.
    pub fn setCacheLimit(self: *StorageEngine, limit: ?u64) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.cache_limit = limit;
        if (limit) |l| if (self.cache_bytes > l) try self.evictLocked(lowWater(l));
    }

    /// Deletes every block of the read cache and returns the bytes freed.
    /// Blocks this device keeps are not touched; a deleted block is fetched
    /// again the next time it is read.
    pub fn clearCache(self: *StorageEngine) !u64 {
        self.mutex.lock();
        defer self.mutex.unlock();
        const io = std.Io.Threaded.global_single_threaded.io();
        const freed = self.cache_bytes;
        var names: std.ArrayList([hex_cid_len]u8) = .empty;
        defer names.deinit(self.allocator);
        var it = self.cache_dir.iterate();
        while (try it.next(io)) |entry| {
            if (entry.kind != .file or !isHexCid(entry.name)) continue;
            try names.append(self.allocator, entry.name[0..hex_cid_len].*);
        }
        for (names.items) |*name| self.cache_dir.deleteFile(io, name) catch {};
        self.cache_bytes = 0;
        self.cache_blocks = 0;
        return freed;
    }

    /// Moves a cached block out of the read cache, so it is kept: called
    /// when this device takes responsibility for it (a backup, a repair).
    /// Does nothing for a block that is already kept or not held.
    pub fn pin(self: *StorageEngine, cid: *const [32]u8) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        const io = std.Io.Threaded.global_single_threaded.io();
        const hex_cid = std.fmt.bytesToHex(cid.*, .lower);
        if (self.rootHasLocked(&hex_cid)) return;
        const stat = self.cache_dir.statFile(io, &hex_cid, .{}) catch return;
        // Keeping it counts against the quota, like a put.
        if (self.quota) |limit| if (self.used_bytes > limit or stat.size > limit - self.used_bytes) return error.StorageFull;
        try self.cache_dir.rename(&hex_cid, self.root_dir, &hex_cid, io);
        self.cache_bytes -|= stat.size;
        self.cache_blocks -|= 1;
        if (self.quota != null) self.used_bytes += stat.size;
    }

    /// Stores a block fetched only to be read, in the read cache. Kept
    /// blocks are never duplicated into the cache. Past the cache limit, the
    /// least recently read blocks are evicted.
    pub fn putCached(self: *StorageEngine, block: Block) !void {
        var hash: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(block.data, &hash, .{});
        if (!std.mem.eql(u8, &hash, &block.cid)) return error.HashMismatch;

        self.mutex.lock();
        defer self.mutex.unlock();

        const hex_cid = std.fmt.bytesToHex(block.cid, .lower);
        if (self.hasLocked(&hex_cid)) return;

        const io = std.Io.Threaded.global_single_threaded.io();
        const tmp_name = hex_cid ++ ".tmp".*;
        var file = try self.cache_dir.createFile(io, &tmp_name, .{});
        errdefer self.cache_dir.deleteFile(io, &tmp_name) catch {};
        {
            defer file.close(io);
            try file.writePositionalAll(io, block.data, 0);
        }
        try self.cache_dir.rename(&tmp_name, self.cache_dir, &hex_cid, io);
        self.cache_bytes += block.data.len;
        self.cache_blocks += 1;
        if (self.cache_limit) |l| if (self.cache_bytes > l) try self.evictLocked(lowWater(l));
    }

    /// Moves every kept block not in `keep` into the read cache, where it
    /// becomes evictable. Before the cache existed, blocks fetched only to be
    /// read were stored with the kept ones; this sorts them out once.
    pub fn demoteExcept(self: *StorageEngine, keep: *const std.AutoHashMapUnmanaged([32]u8, void)) !struct { blocks: u64, bytes: u64 } {
        self.mutex.lock();
        defer self.mutex.unlock();
        const io = std.Io.Threaded.global_single_threaded.io();
        var names: std.ArrayList([hex_cid_len]u8) = .empty;
        defer names.deinit(self.allocator);
        var it = self.root_dir.iterate();
        while (try it.next(io)) |entry| {
            if (entry.kind != .file or !isHexCid(entry.name)) continue;
            var cid: [32]u8 = undefined;
            _ = std.fmt.hexToBytes(&cid, entry.name) catch continue;
            if (keep.contains(cid)) continue;
            try names.append(self.allocator, entry.name[0..hex_cid_len].*);
        }
        var moved: u64 = 0;
        var bytes: u64 = 0;
        for (names.items) |*name| {
            const stat = self.root_dir.statFile(io, name, .{}) catch continue;
            self.root_dir.rename(name, self.cache_dir, name, io) catch continue;
            moved += 1;
            bytes += stat.size;
        }
        self.cache_bytes += bytes;
        self.cache_blocks += moved;
        if (self.quota != null) self.used_bytes -|= bytes;
        if (self.cache_limit) |l| if (self.cache_bytes > l) try self.evictLocked(lowWater(l));
        return .{ .blocks = moved, .bytes = bytes };
    }

    /// Deletes the least recently read cache blocks until the cache holds at
    /// most `target` bytes. A read refreshes a block's mtime, so mtime order
    /// is recency order. Caller holds the lock.
    fn evictLocked(self: *StorageEngine, target: u64) !void {
        const io = std.Io.Threaded.global_single_threaded.io();
        const Entry = struct { name: [hex_cid_len]u8, mtime: i96, size: u64 };
        var entries: std.ArrayList(Entry) = .empty;
        defer entries.deinit(self.allocator);
        var it = self.cache_dir.iterate();
        while (try it.next(io)) |entry| {
            if (entry.kind != .file or !isHexCid(entry.name)) continue;
            const stat = self.cache_dir.statFile(io, entry.name, .{}) catch continue;
            try entries.append(self.allocator, .{ .name = entry.name[0..hex_cid_len].*, .mtime = stat.mtime.nanoseconds, .size = stat.size });
        }
        std.mem.sort(Entry, entries.items, {}, struct {
            fn older(_: void, a: Entry, b: Entry) bool {
                return a.mtime < b.mtime;
            }
        }.older);
        for (entries.items) |*e| {
            if (self.cache_bytes <= target) break;
            self.cache_dir.deleteFile(io, &e.name) catch continue;
            self.cache_bytes -|= e.size;
            self.cache_blocks -|= 1;
        }
    }

    /// Eviction stops below the limit, so a cache at its limit doesn't evict
    /// on every new block.
    fn lowWater(limit: u64) u64 {
        return limit - limit / 10;
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
        if (self.rootHasLocked(&hex_cid)) return;

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
        // Kept now: a cached copy would only count twice.
        if (self.cache_dir.statFile(io, &hex_cid, .{})) |stat| {
            self.cache_dir.deleteFile(io, &hex_cid) catch return;
            self.cache_bytes -|= stat.size;
            self.cache_blocks -|= 1;
        } else |_| {}
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
        if (self.rootHasLocked(hex_cid)) return true;
        const io = std.Io.Threaded.global_single_threaded.io();
        _ = self.cache_dir.statFile(io, hex_cid, .{}) catch return false;
        return true;
    }

    fn rootHasLocked(self: *StorageEngine, hex_cid: []const u8) bool {
        const io = std.Io.Threaded.global_single_threaded.io();
        _ = self.root_dir.statFile(io, hex_cid, .{}) catch return false;
        return true;
    }

    /// Total size of the kept block files. Caller holds the lock.
    fn sumBlocksLocked(self: *StorageEngine) !u64 {
        return (try sumDir(self.root_dir)).bytes;
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
            error.FileNotFound => cached: {
                const f = self.cache_dir.openFile(io, hex_cid, .{}) catch |e| switch (e) {
                    error.FileNotFound => return null,
                    else => return e,
                };
                // A read makes the block the most recently used.
                f.setTimestampsNow(io) catch {};
                break :cached f;
            },
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
    while (try it.next(io)) |entry| {
        if (entry.kind == .file) count += 1;
    }
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

test "read cache evicts the least recently read block first" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const test_path = "test_storage_engine_lru";
    std.Io.Dir.cwd().deleteTree(io, test_path) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, test_path) catch {};

    var engine = try StorageEngine.init(allocator, test_path);
    defer engine.deinit();
    try engine.setCacheLimit(30);

    const a = Block.new("aaaaaaaaaa");
    const b = Block.new("bbbbbbbbbb");
    const c = Block.new("cccccccccc");
    try engine.putCached(a);
    sync.sleep(20 * std.time.ns_per_ms);
    try engine.putCached(b);
    sync.sleep(20 * std.time.ns_per_ms);
    try engine.putCached(c);
    sync.sleep(20 * std.time.ns_per_ms);
    // Reading `a` makes it the most recently used: `b` is now the oldest.
    const got = (try engine.get(&a.cid, allocator)).?;
    allocator.free(got.data);
    sync.sleep(20 * std.time.ns_per_ms);

    const d = Block.new("dddddddddd");
    try engine.putCached(d); // 40 bytes > 30: evict down to 27.
    try std.testing.expect(!engine.has(&b.cid));
    try std.testing.expect(!engine.has(&c.cid));
    try std.testing.expect(engine.has(&a.cid));
    try std.testing.expect(engine.has(&d.cid));
    try std.testing.expectEqual(@as(u64, 20), engine.cacheStats().bytes);
}

test "kept blocks are never cached twice, pinned blocks leave the cache, clear keeps them" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const test_path = "test_storage_engine_pin";
    std.Io.Dir.cwd().deleteTree(io, test_path) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, test_path) catch {};

    var engine = try StorageEngine.init(allocator, test_path);
    defer engine.deinit();

    const kept = Block.new("kept block");
    const read = Block.new("read block");
    const pinned = Block.new("pinned blk");
    try engine.put(kept);
    try engine.putCached(kept); // already kept: no cached copy
    try engine.putCached(read);
    try engine.putCached(pinned);
    try std.testing.expectEqual(@as(u64, 2), engine.cacheStats().blocks);

    try engine.pin(&pinned.cid);
    try std.testing.expectEqual(@as(u64, 1), engine.cacheStats().blocks);

    // A kept put of a cached block moves it out of the cache.
    try engine.putCached(Block.new("both ways."));
    try engine.put(Block.new("both ways."));
    try std.testing.expectEqual(@as(u64, 1), engine.cacheStats().blocks);

    try std.testing.expectEqual(@as(u64, 10), try engine.clearCache());
    try std.testing.expect(!engine.has(&read.cid));
    try std.testing.expect(engine.has(&kept.cid));
    try std.testing.expect(engine.has(&pinned.cid));
    try std.testing.expectEqual(@as(u64, 0), engine.cacheStats().bytes);
}

test "demoteExcept moves only blocks outside the keep set into the cache" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const test_path = "test_storage_engine_demote";
    std.Io.Dir.cwd().deleteTree(io, test_path) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, test_path) catch {};

    var engine = try StorageEngine.init(allocator, test_path);
    defer engine.deinit();
    const mine = Block.new("my own block");
    const old_read = Block.new("old read blk");
    try engine.put(mine);
    try engine.put(old_read); // stored before the cache existed

    var keep: std.AutoHashMapUnmanaged([32]u8, void) = .empty;
    defer keep.deinit(allocator);
    try keep.put(allocator, mine.cid, {});
    const moved = try engine.demoteExcept(&keep);
    try std.testing.expectEqual(@as(u64, 1), moved.blocks);
    try std.testing.expectEqual(@as(u64, 1), engine.cacheStats().blocks);

    _ = try engine.clearCache();
    try std.testing.expect(engine.has(&mine.cid));
    try std.testing.expect(!engine.has(&old_read.cid));
}
