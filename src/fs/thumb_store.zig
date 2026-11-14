//! Where thumbnails live between runs: `<storage_path>.thumbs/`, apart
//! from the block store (a thumbnail is not a block: nothing fetches it by
//! its hash, and the store's sorting of kept and cached blocks never sees
//! it). The key is the content ID of the file the thumbnail shows.
//!
//!   kept/<ab>/<cidhex>.jpg   made on this device; stays while the file is
//!                            in the swarm folder (`sweepKept`)
//!   cache/<ab>/<cidhex>.jpg  got from another device; the least recently
//!                            read go once the cache is over its limit
//!   none/<cidhex>            a marker: no thumbnail can be made of this
//!                            file, and why
//!
//! A marker is 12 bytes: `[version][reason][origin][codec version][i64 time,
//! seconds, little endian]`. Any marker holds only while this build's codec
//! is the one it was written under (a newer one may read the file, here or
//! by asking again); one a peer answered (remote) for a week at most; and
//! "no tool for films", whoever found it, for ten minutes: ffmpeg may be
//! installed meanwhile, or a device that has it come by.
//! Everything is written to a temp file and renamed, so a crash leaves a
//! `.tmp` that is never read and is removed by the next walk (a start, an
//! eviction, a sweep).

const std = @import("std");
const sync = @import("../sync.zig");
const env_mod = @import("../env.zig");
const codec = @import("../codec/mod.zig");

/// The largest thumbnail stored (and, later, taken from a peer).
pub const max_jpeg_len = 128 * 1024;
/// The widest and tallest thumbnail stored.
pub const max_edge = 1024;
/// A marker a peer answered is asked for again after this long.
pub const remote_none_ttl_s: i64 = 7 * 24 * 60 * 60;
/// "No tool for films" is believed this long, here or of a peer.
pub const no_video_tool_ttl_s: i64 = 10 * 60;
/// A film whose frame took longer than the tool is given (a slow or busy
/// device, a heavy 4K file) is tried again after this long.
pub const too_slow_ttl_s: i64 = 24 * 60 * 60;
/// The most entries one walk of a folder looks at.
pub const max_walk = 200_000;

const marker_version: u8 = 1;
const marker_len = 12;
const hex_len = 64;
/// `<ab>/<cidhex>.jpg`.
const sub_path_len = 2 + 1 + hex_len + 4;

/// Why a file has no thumbnail. The numbers are stored (and sent between
/// devices): never renumbered.
pub const Reason = enum(u8) {
    /// No decoder here reads it (HEIC, camera RAW, films for now).
    unsupported_format = 1,
    /// More pixels or bytes than a thumbnail is made from.
    too_large = 2,
    /// It should decode and doesn't: a damaged or unusual picture.
    decode_failed = 3,
    /// A film, and no tool to take a frame of it.
    no_video_tool = 4,
    /// Making it took longer than allowed: tried again a day later.
    too_slow = 5,
};

/// Who found that a file has no thumbnail.
pub const Origin = enum(u8) { local = 0, remote = 1 };

/// What the store holds for a file.
pub const Where = enum { kept, cache, none };

/// Where a thumbnail is put.
pub const Place = enum { kept, cache };

pub const Options = struct {
    /// Most bytes `cache/` holds; 0: no limit.
    cache_limit: u64 = 0,
    /// This build's codec version: a marker written under another one is
    /// not believed (a newer codec may read the file, or ask for it anew).
    codec_ver: u8 = 1,
};

pub const ThumbStore = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    kept: std.Io.Dir,
    cache: std.Io.Dir,
    none: std.Io.Dir,
    codec_ver: u8,
    cache_limit: u64,
    /// Serialises writes, evictions and sweeps (no temp file is live while
    /// it is held by a walk), and guards `cache_bytes`. Reads take no lock:
    /// a stored file never changes.
    mutex: sync.Mutex = .{},
    /// Bytes in `cache/`: counted at open, kept current by `put` and
    /// evictions.
    cache_bytes: u64 = 0,

    /// Opens (creating it) the store at `path`; `~` is this user's home.
    pub fn open(allocator: std.mem.Allocator, io: std.Io, path: []const u8, opts: Options) !ThumbStore {
        const owned = try env_mod.expandHome(allocator, path);
        defer if (owned) |p| allocator.free(p);
        const cwd = std.Io.Dir.cwd();
        try makeDir(io, cwd, owned orelse path);
        var root = try cwd.openDir(io, owned orelse path, .{});
        defer root.close(io);
        const kept = try openSub(io, root, "kept");
        errdefer kept.close(io);
        const cache = try openSub(io, root, "cache");
        errdefer cache.close(io);
        const none = try openSub(io, root, "none");
        errdefer none.close(io);
        var self: ThumbStore = .{
            .allocator = allocator,
            .io = io,
            .kept = kept,
            .cache = cache,
            .none = none,
            .codec_ver = opts.codec_ver,
            .cache_limit = opts.cache_limit,
        };
        // The cache is bounded, so counting it is cheap; the walk removes
        // what a crash left.
        var found: std.ArrayList(Stored) = .empty;
        defer found.deinit(allocator);
        try self.collect(self.cache, &found, true);
        for (found.items) |e| self.cache_bytes +|= e.size;
        if (self.overLimit()) self.evictLocked(lowWater(self.cache_limit)) catch {}; // tried again by the next put
        return self;
    }

    pub fn close(self: *ThumbStore) void {
        self.kept.close(self.io);
        self.cache.close(self.io);
        self.none.close(self.io);
    }

    /// What is held for `cid`: a thumbnail (kept or cached), a marker that
    /// still holds, or nothing (null). A few stats: cheap enough for every
    /// item of a list.
    pub fn lookup(self: *ThumbStore, cid: *const [32]u8) ?Where {
        return self.lookupAt(cid, sync.timestamp());
    }

    fn lookupAt(self: *ThumbStore, cid: *const [32]u8, now_s: i64) ?Where {
        const name = subPath(cid, ".jpg");
        if (self.exists(self.kept, &name)) return .kept;
        if (self.exists(self.cache, &name)) return .cache;
        if (self.noneAt(cid, now_s) != null) return .none;
        return null;
    }

    /// Why `cid` has no thumbnail, while its marker holds.
    pub fn noneReason(self: *ThumbStore, cid: *const [32]u8) ?Reason {
        const marker = self.noneMarker(cid, sync.timestamp()) orelse return null;
        return marker.reason;
    }

    /// Why `cid` has no thumbnail, only when this device found it out
    /// itself (not what another device answered): what it tells others.
    pub fn localNoneReason(self: *ThumbStore, cid: *const [32]u8) ?Reason {
        const marker = self.noneMarker(cid, sync.timestamp()) orelse return null;
        return if (marker.origin == .local) marker.reason else null;
    }

    fn noneAt(self: *ThumbStore, cid: *const [32]u8, now_s: i64) ?Reason {
        const marker = self.noneMarker(cid, now_s) orelse return null;
        return marker.reason;
    }

    const Marker = struct { reason: Reason, origin: Origin };

    fn noneMarker(self: *ThumbStore, cid: *const [32]u8, now_s: i64) ?Marker {
        const hex = std.fmt.bytesToHex(cid.*, .lower);
        var file = self.none.openFile(self.io, &hex, .{}) catch return null;
        var raw: [marker_len + 1]u8 = undefined;
        const n = file.readPositionalAll(self.io, &raw, 0) catch 0;
        file.close(self.io);
        if (self.markerHolds(raw[0..n], now_s)) |reason| return .{ .reason = reason, .origin = @enumFromInt(raw[2]) };
        // Damaged, another codec's or expired: gone, so the next ask tries.
        self.none.deleteFile(self.io, &hex) catch {};
        return null;
    }

    /// The reason a marker's bytes give, when they are a marker that still
    /// holds at `now_s`.
    fn markerHolds(self: *const ThumbStore, raw: []const u8, now_s: i64) ?Reason {
        if (raw.len != marker_len or raw[0] != marker_version) return null;
        const reason = std.enums.fromInt(Reason, raw[1]) orelse return null;
        const origin = std.enums.fromInt(Origin, raw[2]) orelse return null;
        if (raw[3] != self.codec_ver) return null;
        const ttl: ?i64 = switch (reason) {
            .no_video_tool => no_video_tool_ttl_s,
            .too_slow => too_slow_ttl_s,
            else => switch (origin) {
                .local => null,
                .remote => remote_none_ttl_s,
            },
        };
        if (ttl) |limit| {
            const at = std.mem.readInt(i64, raw[4..12], .little);
            // A time ahead of the clock counts from now: it expires too.
            if (now_s -| @min(at, now_s) >= limit) return null;
        }
        return reason;
    }

    /// The length of the thumbnail held for `cid`, or null.
    pub fn sizeOf(self: *ThumbStore, cid: *const [32]u8) ?u32 {
        const name = subPath(cid, ".jpg");
        const stat = self.kept.statFile(self.io, &name, .{}) catch
            self.cache.statFile(self.io, &name, .{}) catch return null;
        if (stat.size == 0 or stat.size > max_jpeg_len) return null;
        return @intCast(stat.size); // <= max_jpeg_len
    }

    /// Copies the thumbnail's bytes from `offset` into `dest`; how many
    /// (less than dest.len only at its end). error.FileNotFound when none
    /// is held. Reading a cached one from its start makes it the most
    /// recently used.
    pub fn read(self: *ThumbStore, cid: *const [32]u8, offset: u64, dest: []u8) !usize {
        const name = subPath(cid, ".jpg");
        var file = self.kept.openFile(self.io, &name, .{}) catch |err| switch (err) {
            error.FileNotFound => cached: {
                const f = try self.cache.openFile(self.io, &name, .{});
                if (offset == 0) f.setTimestampsNow(self.io) catch {}; // only the order of eviction
                break :cached f;
            },
            else => return err,
        };
        defer file.close(self.io);
        return file.readPositionalAll(self.io, dest, offset);
    }

    /// Stores `jpeg` as the thumbnail of `cid`. Checked first, wherever it
    /// came from (`validate`): error.InvalidThumbnail. One already held is
    /// left as it is; a kept one replaces the cached copy, and either ends
    /// the file's marker.
    pub fn put(self: *ThumbStore, cid: *const [32]u8, place: Place, jpeg: []const u8) !void {
        try validate(jpeg);
        self.mutex.lock();
        defer self.mutex.unlock();
        const name = subPath(cid, ".jpg");
        if (self.exists(self.kept, &name)) return;
        if (place == .cache and self.exists(self.cache, &name)) return;

        try self.writeLocked(if (place == .kept) self.kept else self.cache, &name, jpeg);
        const hex = std.fmt.bytesToHex(cid.*, .lower);
        self.none.deleteFile(self.io, &hex) catch {}; // usually not there
        switch (place) {
            // Kept now: a cached copy would only count twice.
            .kept => if (self.cache.statFile(self.io, &name, .{})) |stat| {
                self.cache.deleteFile(self.io, &name) catch return;
                self.cache_bytes -|= stat.size;
            } else |_| {},
            .cache => {
                self.cache_bytes +|= jpeg.len;
                // The thumbnail is stored; an eviction that fails is tried
                // again by the next put.
                if (self.overLimit()) self.evictLocked(lowWater(self.cache_limit)) catch {};
            },
        }
    }

    /// Marks `cid` as having no thumbnail. A thumbnail held for it stays
    /// (and is what `lookup` answers).
    pub fn putNone(self: *ThumbStore, cid: *const [32]u8, reason: Reason, origin: Origin) !void {
        var raw: [marker_len]u8 = undefined;
        raw[0..4].* = .{ marker_version, @intFromEnum(reason), @intFromEnum(origin), self.codec_ver };
        std.mem.writeInt(i64, raw[4..12], sync.timestamp(), .little);
        const hex = std.fmt.bytesToHex(cid.*, .lower);
        self.mutex.lock();
        defer self.mutex.unlock();
        try self.writeLocked(self.none, &hex, &raw);
    }

    /// Deletes the least recently read cached thumbnails until the cache
    /// holds at most `target` bytes. Caller holds `mutex`.
    pub fn evictLocked(self: *ThumbStore, target: u64) !void {
        var found: std.ArrayList(Stored) = .empty;
        defer found.deinit(self.allocator);
        try self.collect(self.cache, &found, true);
        // The walk is what is there (unless it was cut short).
        if (found.items.len < max_walk) {
            var total: u64 = 0;
            for (found.items) |e| total +|= e.size;
            self.cache_bytes = total;
        }
        std.mem.sort(Stored, found.items, {}, struct {
            fn older(_: void, a: Stored, b: Stored) bool {
                return a.mtime < b.mtime;
            }
        }.older);
        for (found.items) |e| {
            if (self.cache_bytes <= target) break;
            self.cache.deleteFile(self.io, &subPath(&e.cid, ".jpg")) catch continue;
            self.cache_bytes -|= e.size;
        }
    }

    /// Removes the kept thumbnails and the markers of files that are not
    /// in `live` (the content IDs the swarm folder still has); how many
    /// went. The cache needs none of this: it evicts.
    pub fn sweepKept(self: *ThumbStore, live: *const std.AutoHashMapUnmanaged([32]u8, void)) !usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        var removed: usize = 0;
        var found: std.ArrayList(Stored) = .empty;
        defer found.deinit(self.allocator);
        try self.collect(self.kept, &found, false);
        for (found.items) |e| {
            if (live.contains(e.cid)) continue;
            self.kept.deleteFile(self.io, &subPath(&e.cid, ".jpg")) catch continue;
            removed += 1;
        }

        // Markers, and the temp files a crash left of them (none is being
        // written: the lock is held).
        var gone: std.ArrayList([hex_len]u8) = .empty;
        defer gone.deinit(self.allocator);
        var torn: std.ArrayList([hex_len + 4]u8) = .empty;
        defer torn.deinit(self.allocator);
        var it = self.none.iterate();
        var seen: usize = 0;
        while (seen < max_walk) : (seen += 1) {
            const entry = (it.next(self.io) catch break) orelse break;
            if (entry.kind != .file) continue;
            if (cidOfName(entry.name, ".tmp") != null) {
                try torn.append(self.allocator, entry.name[0 .. hex_len + 4].*);
            } else if (cidOfName(entry.name, "")) |cid| {
                if (!live.contains(cid)) try gone.append(self.allocator, entry.name[0..hex_len].*);
            }
        }
        for (torn.items) |*name| self.none.deleteFile(self.io, name) catch {};
        for (gone.items) |*name| {
            self.none.deleteFile(self.io, name) catch continue;
            removed += 1;
        }
        return removed;
    }

    /// Bytes the cache holds.
    pub fn cacheBytes(self: *ThumbStore) u64 {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.cache_bytes;
    }

    fn overLimit(self: *const ThumbStore) bool {
        return self.cache_limit != 0 and self.cache_bytes > self.cache_limit;
    }

    fn exists(self: *const ThumbStore, dir: std.Io.Dir, name: []const u8) bool {
        _ = dir.statFile(self.io, name, .{}) catch return false;
        return true;
    }

    /// `bytes` at `name` in `dir` (`<ab>/<hex>.jpg`, or a marker's `<hex>`),
    /// through `<hex>.tmp` beside it. Caller holds `mutex`.
    fn writeLocked(self: *ThumbStore, dir: std.Io.Dir, name: []const u8, bytes: []const u8) !void {
        var tmp_buf: [sub_path_len]u8 = undefined;
        const stem = if (std.mem.endsWith(u8, name, ".jpg")) name[0 .. name.len - 4] else name;
        const tmp = std.fmt.bufPrint(&tmp_buf, "{s}.tmp", .{stem}) catch unreachable; // stem + 4 <= sub_path_len
        if (std.fs.path.dirname(name)) |sub| try makeDir(self.io, dir, sub);
        var file = try dir.createFile(self.io, tmp, .{});
        errdefer dir.deleteFile(self.io, tmp) catch {};
        {
            defer file.close(self.io);
            try file.writePositionalAll(self.io, bytes, 0);
        }
        try dir.rename(tmp, dir, name, self.io);
    }

    // @atlas allow: a stored thumbnail by content ID; the scanner's file records only share the field names
    const Stored = struct { cid: [32]u8, size: u64, mtime: i96 };

    /// Appends every thumbnail below `top` (`<ab>/<cidhex>.jpg`), looking
    /// at `max_walk` entries at most; `stat`: with its size and time (else
    /// 0). Temp files a crash left are removed. Caller holds `mutex` (or
    /// is `open`).
    fn collect(self: *ThumbStore, top: std.Io.Dir, out: *std.ArrayList(Stored), stat: bool) !void {
        var seen: usize = 0;
        var subs = top.iterate();
        // 256 folders at most are ours; the bound holds for whatever else
        // is there.
        while (seen < max_walk) : (seen += 1) {
            const sub = (subs.next(self.io) catch break) orelse break;
            if (sub.kind != .directory or sub.name.len != 2) continue;
            var dir = top.openDir(self.io, sub.name, .{ .iterate = true }) catch continue;
            defer dir.close(self.io);
            var torn: std.ArrayList([hex_len + 4]u8) = .empty;
            defer torn.deinit(self.allocator);
            var it = dir.iterate();
            while (seen < max_walk) : (seen += 1) {
                const entry = (it.next(self.io) catch break) orelse break;
                if (entry.kind != .file) continue;
                if (cidOfName(entry.name, ".tmp") != null) {
                    try torn.append(self.allocator, entry.name[0 .. hex_len + 4].*);
                    continue;
                }
                const cid = cidOfName(entry.name, ".jpg") orelse continue;
                if (!std.mem.eql(u8, sub.name, entry.name[0..2])) continue; // not where it is looked up
                var e: Stored = .{ .cid = cid, .size = 0, .mtime = 0 };
                if (stat) {
                    const st = dir.statFile(self.io, entry.name, .{}) catch continue;
                    e.size = st.size;
                    e.mtime = st.mtime.nanoseconds;
                }
                try out.append(self.allocator, e);
            }
            for (torn.items) |*name| dir.deleteFile(self.io, name) catch {};
        }
    }
};

/// Whether `jpeg` is a thumbnail this store takes: a whole JPEG (it starts
/// and ends as one), `max_jpeg_len` bytes at most, `max_edge` pixels at
/// most each way. The bytes may come from a peer.
pub fn validate(jpeg: []const u8) error{InvalidThumbnail}!void {
    if (jpeg.len < 4 or jpeg.len > max_jpeg_len) return error.InvalidThumbnail;
    if (jpeg[0] != 0xFF or jpeg[1] != 0xD8) return error.InvalidThumbnail;
    if (jpeg[jpeg.len - 2] != 0xFF or jpeg[jpeg.len - 1] != 0xD9) return error.InvalidThumbnail;
    const dims = codec.image.info(jpeg) catch return error.InvalidThumbnail;
    if (dims.width > max_edge or dims.height > max_edge) return error.InvalidThumbnail;
}

/// Eviction stops below the limit, so a cache at its limit doesn't evict
/// on every put.
fn lowWater(limit: u64) u64 {
    return limit - limit / 10;
}

/// `<ab>/<cidhex><ext>`, `ext` being ".jpg" or ".tmp".
fn subPath(cid: *const [32]u8, comptime ext: *const [4]u8) [sub_path_len]u8 {
    const hex = std.fmt.bytesToHex(cid.*, .lower);
    var out: [sub_path_len]u8 = undefined;
    out[0..2].* = hex[0..2].*;
    out[2] = '/';
    out[3..][0..hex_len].* = hex;
    out[3 + hex_len ..][0..4].* = ext.*;
    return out;
}

/// The content ID a file name `<cidhex><ext>` holds (lowercase hex).
fn cidOfName(name: []const u8, comptime ext: []const u8) ?[32]u8 {
    if (name.len != hex_len + ext.len or !std.mem.endsWith(u8, name, ext)) return null;
    for (name[0..hex_len]) |c| if (!((c >= '0' and c <= '9') or (c >= 'a' and c <= 'f'))) return null;
    var cid: [32]u8 = undefined;
    _ = std.fmt.hexToBytes(&cid, name[0..hex_len]) catch return null;
    return cid;
}

fn makeDir(io: std.Io, dir: std.Io.Dir, path: []const u8) !void {
    dir.createDirPath(io, path) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
}

fn openSub(io: std.Io, root: std.Io.Dir, name: []const u8) !std.Io.Dir {
    try makeDir(io, root, name);
    return root.openDir(io, name, .{ .iterate = true });
}

const testing = std.testing;

/// A store in a temporary directory, and a JPEG to put in it.
const TestStore = struct {
    tmp: testing.TmpDir,
    path: []u8,
    store: ThumbStore,
    jpeg: []u8,

    fn open(self: *TestStore, opts: Options) !void {
        self.tmp = testing.tmpDir(.{});
        errdefer self.tmp.cleanup();
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const dir = buf[0..try self.tmp.dir.realPath(testing.io, &buf)];
        self.path = try std.fs.path.join(testing.allocator, &.{ dir, "data.thumbs" });
        errdefer testing.allocator.free(self.path);
        self.jpeg = try codec.image.testing.gradientJpeg(testing.allocator, 320, 240, 9);
        errdefer testing.allocator.free(self.jpeg);
        self.store = try ThumbStore.open(testing.allocator, testing.io, self.path, opts);
    }

    /// A restart, with `opts`.
    fn reopen(self: *TestStore, opts: Options) !void {
        self.store.close();
        self.store = try ThumbStore.open(testing.allocator, testing.io, self.path, opts);
    }

    fn close(self: *TestStore) void {
        self.store.close();
        testing.allocator.free(self.jpeg);
        testing.allocator.free(self.path);
        self.tmp.cleanup();
    }

    /// The store's folder, to plant files in.
    fn rootDir(self: *TestStore) !std.Io.Dir {
        return std.Io.Dir.cwd().openDir(testing.io, self.path, .{});
    }
};

fn cidOf(byte: u8) [32]u8 {
    return @splat(byte);
}

test "thumb store: a thumbnail put is found, read back and still there after a restart" {
    var t: TestStore = undefined;
    try t.open(.{});
    defer t.close();
    const s = &t.store;
    const a = cidOf(0xa1);
    const b = cidOf(0xb2);

    try testing.expect(s.lookup(&a) == null);
    try testing.expect(s.sizeOf(&a) == null);
    var buf: [max_jpeg_len]u8 = undefined;
    try testing.expectError(error.FileNotFound, s.read(&a, 0, &buf));

    try s.put(&a, .kept, t.jpeg);
    try s.put(&b, .cache, t.jpeg);
    try testing.expectEqual(Where.kept, s.lookup(&a).?);
    try testing.expectEqual(Where.cache, s.lookup(&b).?);
    try testing.expectEqual(@as(u32, @intCast(t.jpeg.len)), s.sizeOf(&a).?);
    try testing.expectEqual(@as(u64, t.jpeg.len), s.cacheBytes());
    for ([_]*const [32]u8{ &a, &b }) |cid| {
        const n = try s.read(cid, 0, &buf);
        try testing.expectEqualSlices(u8, t.jpeg, buf[0..n]);
    }
    // From an offset; past the end there is nothing.
    try testing.expectEqual(@as(usize, 10), try s.read(&a, t.jpeg.len - 10, buf[0..64]));
    try testing.expectEqualSlices(u8, t.jpeg[t.jpeg.len - 10 ..], buf[0..10]);
    try testing.expectEqual(@as(usize, 0), try s.read(&b, t.jpeg.len, &buf));

    // Where the plan says they are.
    var root = try t.rootDir();
    defer root.close(testing.io);
    _ = try root.statFile(testing.io, "kept/a1/" ++ "a1" ** 32 ++ ".jpg", .{});
    _ = try root.statFile(testing.io, "cache/b2/" ++ "b2" ** 32 ++ ".jpg", .{});

    try t.reopen(.{});
    try testing.expectEqual(Where.kept, t.store.lookup(&a).?);
    try testing.expectEqual(Where.cache, t.store.lookup(&b).?);
    try testing.expectEqual(@as(u64, t.jpeg.len), t.store.cacheBytes());

    // Made here now: the cached copy goes.
    try t.store.put(&b, .kept, t.jpeg);
    try testing.expectEqual(Where.kept, t.store.lookup(&b).?);
    try testing.expectEqual(@as(u64, 0), t.store.cacheBytes());
    try testing.expectError(error.FileNotFound, root.statFile(testing.io, "cache/b2/" ++ "b2" ** 32 ++ ".jpg", .{}));
}

test "thumb store: only whole, small JPEGs are taken" {
    var t: TestStore = undefined;
    try t.open(.{});
    defer t.close();
    const cid = cidOf(0x01);
    const allocator = testing.allocator;

    try testing.expectError(error.InvalidThumbnail, t.store.put(&cid, .cache, ""));
    try testing.expectError(error.InvalidThumbnail, t.store.put(&cid, .cache, "\x89PNG\r\n\x1a\n not a jpeg \xFF\xD9"));
    // Cut short: no end marker.
    try testing.expectError(error.InvalidThumbnail, t.store.put(&cid, .cache, t.jpeg[0 .. t.jpeg.len - 2]));
    try testing.expectError(error.InvalidThumbnail, t.store.put(&cid, .kept, t.jpeg[0 .. t.jpeg.len / 2]));
    // The marks of a JPEG around nothing.
    try testing.expectError(error.InvalidThumbnail, t.store.put(&cid, .cache, "\xFF\xD8\xFF\xD9"));
    // Too wide.
    const wide = try codec.image.testing.gradientJpeg(allocator, max_edge + 1, 8, 0);
    defer allocator.free(wide);
    try testing.expectError(error.InvalidThumbnail, t.store.put(&cid, .cache, wide));
    // Too long: a JPEG's start and end around more than a thumbnail is.
    const long = try allocator.alloc(u8, max_jpeg_len + 1);
    defer allocator.free(long);
    @memset(long, 0);
    @memcpy(long[0..t.jpeg.len], t.jpeg);
    long[long.len - 2 ..][0..2].* = .{ 0xFF, 0xD9 };
    try testing.expectError(error.InvalidThumbnail, t.store.put(&cid, .cache, long));

    try testing.expect(t.store.lookup(&cid) == null);
    try testing.expectEqual(@as(u64, 0), t.store.cacheBytes());
    // At the limit each way it is taken.
    const edge = try codec.image.testing.gradientJpeg(allocator, max_edge, 4, 0);
    defer allocator.free(edge);
    try t.store.put(&cid, .cache, edge);
    try testing.expectEqual(Where.cache, t.store.lookup(&cid).?);
}

test "thumb store: over its limit the cache drops the least recently read" {
    var t: TestStore = undefined;
    try t.open(.{});
    defer t.close();
    // Room for three, not four; eviction stops at 90%: three stay.
    const len: u64 = t.jpeg.len;
    try t.reopen(.{ .cache_limit = 4 * len - 1 });
    const s = &t.store;
    const a = cidOf(0x0a);
    const b = cidOf(0x0b);
    const c = cidOf(0x0c);
    const d = cidOf(0x0d);
    const kept = cidOf(0x0e);
    // Times apart: the order is the files' modified times.
    const tick = 20 * std.time.ns_per_ms;
    try s.put(&kept, .kept, t.jpeg);
    try s.put(&a, .cache, t.jpeg);
    sync.sleep(tick);
    try s.put(&b, .cache, t.jpeg);
    sync.sleep(tick);
    try s.put(&c, .cache, t.jpeg);
    sync.sleep(tick);
    try testing.expectEqual(3 * len, s.cacheBytes());
    // `a` is read: `b` is now the oldest.
    var buf: [max_jpeg_len]u8 = undefined;
    _ = try s.read(&a, 0, &buf);
    sync.sleep(tick);

    try s.put(&d, .cache, t.jpeg);
    try testing.expectEqual(3 * len, s.cacheBytes());
    try testing.expect(s.lookup(&b) == null);
    try testing.expectEqual(Where.cache, s.lookup(&a).?);
    try testing.expectEqual(Where.cache, s.lookup(&c).?);
    try testing.expectEqual(Where.cache, s.lookup(&d).?);
    // What was made here is never evicted.
    try testing.expectEqual(Where.kept, s.lookup(&kept).?);

    // A smaller limit at the next start evicts at once.
    try t.reopen(.{ .cache_limit = 2 * len - 1 });
    try testing.expectEqual(len, t.store.cacheBytes());
    try testing.expectEqual(Where.cache, t.store.lookup(&d).?);
    try testing.expect(t.store.lookup(&a) == null and t.store.lookup(&c) == null);
}

test "thumb store: a marker holds until the codec changes, a remote one for a week at most" {
    var t: TestStore = undefined;
    try t.open(.{ .codec_ver = 1 });
    defer t.close();
    const local = cidOf(0x10);
    const remote = cidOf(0x20);
    const now = sync.timestamp();
    const day: i64 = 24 * 60 * 60;

    try t.store.putNone(&local, .unsupported_format, .local);
    try t.store.putNone(&remote, .too_large, .remote);
    try testing.expectEqual(Where.none, t.store.lookup(&local).?);
    try testing.expectEqual(Reason.unsupported_format, t.store.noneReason(&local).?);
    try testing.expectEqual(Reason.too_large, t.store.noneReason(&remote).?);
    var root = try t.rootDir();
    defer root.close(testing.io);
    try testing.expectEqual(@as(u64, marker_len), (try root.statFile(testing.io, "none/" ++ "10" ** 32, .{})).size);

    // Years on, the local one still holds; the remote one for six days,
    // not eight.
    try testing.expectEqual(Where.none, t.store.lookupAt(&local, now + 3650 * day).?);
    try testing.expectEqual(Where.none, t.store.lookupAt(&remote, now + 6 * day).?);
    try testing.expect(t.store.lookupAt(&remote, now + 8 * day) == null);
    // Expired, it is gone: asked for again from now on.
    try testing.expect(t.store.lookup(&remote) == null);

    // A newer codec: what this device found is tried again, and what a
    // peer answered asked again (it may be asked for something else now).
    try t.store.putNone(&remote, .decode_failed, .remote);
    try testing.expectEqual(Reason.decode_failed, t.store.noneReason(&remote).?);
    try t.reopen(.{ .codec_ver = 2 });
    try testing.expect(t.store.lookup(&remote) == null);
    try testing.expect(t.store.lookup(&local) == null);
    try testing.expectError(error.FileNotFound, root.statFile(testing.io, "none/" ++ "20" ** 32, .{}));

    // A thumbnail ends the marker, and is what is found.
    try t.store.putNone(&local, .decode_failed, .local);
    try t.store.put(&local, .kept, t.jpeg);
    try testing.expectEqual(Where.kept, t.store.lookup(&local).?);
    try testing.expect(t.store.noneReason(&local) == null);
}

test "thumb store: no tool for films is believed for ten minutes, whoever said it" {
    var t: TestStore = undefined;
    try t.open(.{});
    defer t.close();
    const here = cidOf(0x41);
    const peer = cidOf(0x42);
    const now = sync.timestamp();
    try t.store.putNone(&here, .no_video_tool, .local);
    try t.store.putNone(&peer, .no_video_tool, .remote);
    for ([_]*const [32]u8{ &here, &peer }) |cid| {
        try testing.expectEqual(Where.none, t.store.lookupAt(cid, now + no_video_tool_ttl_s - 60).?);
        // ffmpeg may be there by now, or a device that has it.
        try testing.expect(t.store.lookupAt(cid, now + no_video_tool_ttl_s + 60) == null);
        try testing.expect(t.store.lookup(cid) == null);
    }
}

test "thumb store: torn temp files and damaged markers are not read" {
    var t: TestStore = undefined;
    try t.open(.{});
    defer t.close();
    const cid = cidOf(0xc3);
    const hex = "c3" ** 32;
    var root = try t.rootDir();
    defer root.close(testing.io);
    // A crash between the write and the rename, in each folder.
    try root.createDirPath(testing.io, "cache/c3");
    try root.createDirPath(testing.io, "kept/c3");
    try root.writeFile(testing.io, .{ .sub_path = "cache/c3/" ++ hex ++ ".tmp", .data = t.jpeg[0 .. t.jpeg.len / 2] });
    try root.writeFile(testing.io, .{ .sub_path = "kept/c3/" ++ hex ++ ".tmp", .data = t.jpeg[0..10] });
    try root.writeFile(testing.io, .{ .sub_path = "none/" ++ hex ++ ".tmp", .data = "\x01\x01" });
    try testing.expect(t.store.lookup(&cid) == null);
    try testing.expect(t.store.sizeOf(&cid) == null);

    // The next start counts none of it and clears the cache's.
    try t.reopen(.{});
    try testing.expectEqual(@as(u64, 0), t.store.cacheBytes());
    try testing.expectError(error.FileNotFound, root.statFile(testing.io, "cache/c3/" ++ hex ++ ".tmp", .{}));
    try testing.expect(t.store.lookup(&cid) == null);

    // Markers: too short, an unknown version, an unknown reason.
    for ([_][]const u8{ "\x01\x01\x00\x01", "\x09\x01\x00\x01" ++ "\x00" ** 8, "\x01\x63\x00\x01" ++ "\x00" ** 8 }) |raw| {
        try root.writeFile(testing.io, .{ .sub_path = "none/" ++ hex, .data = raw });
        try testing.expect(t.store.lookup(&cid) == null);
        try testing.expectError(error.FileNotFound, root.statFile(testing.io, "none/" ++ hex, .{}));
    }

    // A put goes through its temp file and leaves none.
    try t.store.put(&cid, .cache, t.jpeg);
    try testing.expectEqual(Where.cache, t.store.lookup(&cid).?);
    try testing.expectError(error.FileNotFound, root.statFile(testing.io, "cache/c3/" ++ hex ++ ".tmp", .{}));
}

test "thumb store: a sweep drops kept thumbnails and markers of files that are gone" {
    var t: TestStore = undefined;
    try t.open(.{});
    defer t.close();
    const live_thumb = cidOf(0x31);
    const dead_thumb = cidOf(0x32);
    const live_none = cidOf(0x33);
    const dead_none = cidOf(0x34);
    const cached = cidOf(0x35);
    try t.store.put(&live_thumb, .kept, t.jpeg);
    try t.store.put(&dead_thumb, .kept, t.jpeg);
    try t.store.put(&cached, .cache, t.jpeg);
    try t.store.putNone(&live_none, .too_large, .local);
    try t.store.putNone(&dead_none, .too_large, .local);

    var live: std.AutoHashMapUnmanaged([32]u8, void) = .empty;
    defer live.deinit(testing.allocator);
    try live.put(testing.allocator, live_thumb, {});
    try live.put(testing.allocator, live_none, {});
    try testing.expectEqual(@as(usize, 2), try t.store.sweepKept(&live));
    try testing.expectEqual(Where.kept, t.store.lookup(&live_thumb).?);
    try testing.expectEqual(Where.none, t.store.lookup(&live_none).?);
    try testing.expect(t.store.lookup(&dead_thumb) == null);
    try testing.expect(t.store.lookup(&dead_none) == null);
    // The cache is not the sweep's.
    try testing.expectEqual(Where.cache, t.store.lookup(&cached).?);
    // What a crash left of a marker goes with it.
    var root = try t.rootDir();
    defer root.close(testing.io);
    try root.writeFile(testing.io, .{ .sub_path = "none/" ++ "36" ** 32 ++ ".tmp", .data = "\x01" });
    try testing.expectEqual(@as(usize, 0), try t.store.sweepKept(&live));
    try testing.expectError(error.FileNotFound, root.statFile(testing.io, "none/" ++ "36" ** 32 ++ ".tmp", .{}));
}

test subPath {
    try testing.expectEqualStrings("ab/" ++ "ab" ** 32 ++ ".jpg", &subPath(&cidOf(0xab), ".jpg"));
    try testing.expectEqual(cidOf(0xab), cidOfName("ab" ** 32 ++ ".tmp", ".tmp").?);
    try testing.expect(cidOfName("AB" ** 32 ++ ".jpg", ".jpg") == null);
    try testing.expect(cidOfName("ab" ** 32, ".jpg") == null);
}

test "thumb store: a too-slow film is tried again after a day" {
    var t: TestStore = undefined;
    try t.open(.{});
    defer t.close();
    const cid: [32]u8 = @splat(0x51);
    try t.store.putNone(&cid, .too_slow, .local);
    const now = sync.timestamp();
    try testing.expectEqual(Where.none, t.store.lookupAt(&cid, now + 60).?);
    try testing.expect(t.store.lookupAt(&cid, now + too_slow_ttl_s + 60) == null);
}
