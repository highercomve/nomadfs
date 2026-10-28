//! What the scanner learned about each shared file, kept on disk: its size,
//! mtime, ctime, inode and root CID. A restart then re-reads only files that changed; a
//! large share (a media disk) is otherwise hashed again on every start.
//! The file's leaves are not recorded: its parent blocks in the store
//! already list them (scan.zig rebuilds them from there).
//!
//! File `scan-cache` in the store directory: a header, then records
//! appended as files are scanned. The last record for a path wins; a drop
//! record forgets it. A torn record at the end (a crash mid-write) is
//! ignored and overwritten. The file is rewritten without stale records
//! once they outnumber the live ones.
//!
//!   put:  [u8 1][u16 path_len][path][u64 size][i64 mtime_ns][i64 ctime_ns][u64 inode][cid: 32]
//!   drop: [u8 2][u16 path_len][path]
//!
//! Integers are little-endian.

const std = @import("std");
const codec = @import("../storage/mod.zig").dag.codec;

pub const Cid = codec.Cid;

const file_name = "scan-cache";
const tmp_name = "scan-cache.tmp";
const header = "NOMADFS-SCAN-CACHE-2\n";
const tag_put: u8 = 1;
const tag_drop: u8 = 2;
pub const max_cache_bytes = 64 * 1024 * 1024;

pub const Entry = struct {
    size: u64,
    mtime_ns: i64,
    ctime_ns: i64,
    inode: u64,
    cid: Cid,
};

pub const ScanCache = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    /// The store directory (not owned).
    dir: std.Io.Dir,
    file: std.Io.File,
    /// Where the next record goes.
    end: u64,
    /// Records in the file, live or not (compaction trigger).
    records: u64 = 0,
    /// Records not yet written (flush).
    pending: std.ArrayList(u8) = .empty,

    /// Opens (or starts) the cache in `dir` and calls `visitor.put(path,
    /// entry)` / `visitor.drop(path)` for its records, in order. The path
    /// slices are only valid during the call.
    pub fn open(allocator: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, visitor: anytype) !ScanCache {
        var file = try dir.createFile(io, file_name, .{ .truncate = false, .read = true });
        errdefer file.close(io);
        var self = ScanCache{ .allocator = allocator, .io = io, .dir = dir, .file = file, .end = 0 };

        const size = (try file.stat(io)).size;
        if (size > max_cache_bytes) {
            try file.setLength(io, 0);
            try file.writePositionalAll(io, header, 0);
            self.end = header.len;
            return self;
        }
        const bytes = try allocator.alloc(u8, @intCast(size));
        defer allocator.free(bytes);
        const n = try file.readPositionalAll(io, bytes, 0);
        const data = bytes[0..n];

        if (data.len < header.len or !std.mem.eql(u8, data[0..header.len], header)) {
            // New, or not ours (e.g. old cache version): start over.
            try file.setLength(io, 0);
            try file.writePositionalAll(io, header, 0);
            self.end = header.len;
            return self;
        }
        var pos: usize = header.len;
        while (parse(data[pos..])) |rec| {
            switch (rec.kind) {
                .put => try visitor.put(rec.path, rec.entry),
                .drop => try visitor.drop(rec.path),
            }
            pos += rec.len;
            self.records += 1;
        }
        self.end = pos;
        return self;
    }

    pub fn close(self: *ScanCache) void {
        self.flush() catch {};
        self.pending.deinit(self.allocator);
        self.file.close(self.io);
    }

    pub fn put(self: *ScanCache, path: []const u8, entry: Entry) !void {
        if (path.len > std.math.maxInt(u16)) return;
        const w = &self.pending;
        try w.ensureUnusedCapacity(self.allocator, 1 + 2 + path.len + 8 + 8 + 8 + 8 + 32);
        w.appendAssumeCapacity(tag_put);
        appendInt(w, u16, @intCast(path.len));
        w.appendSliceAssumeCapacity(path);
        appendInt(w, u64, entry.size);
        appendInt(w, i64, entry.mtime_ns);
        appendInt(w, i64, entry.ctime_ns);
        appendInt(w, u64, entry.inode);
        w.appendSliceAssumeCapacity(&entry.cid);
        self.records += 1;
    }

    pub fn drop(self: *ScanCache, path: []const u8) !void {
        if (path.len > std.math.maxInt(u16)) return;
        const w = &self.pending;
        try w.ensureUnusedCapacity(self.allocator, 1 + 2 + path.len);
        w.appendAssumeCapacity(tag_drop);
        appendInt(w, u16, @intCast(path.len));
        w.appendSliceAssumeCapacity(path);
        self.records += 1;
    }

    /// Writes the records added since the last flush.
    pub fn flush(self: *ScanCache) !void {
        if (self.pending.items.len == 0) return;
        try self.file.writePositionalAll(self.io, self.pending.items, self.end);
        self.end += self.pending.items.len;
        self.pending.clearRetainingCapacity();
    }

    /// Whether stale records outnumber the `live` entries enough to
    /// rewrite the file.
    pub fn wantsCompaction(self: *const ScanCache, live: u64) bool {
        return self.records > 2 * live + 1024;
    }

    /// Rewrites the file with only `entries` (an iterator whose next()
    /// yields `struct { path: []const u8, entry: Entry }`), then swaps it in.
    pub fn compact(self: *ScanCache, entries: anytype) !void {
        var it = entries;
        var out: ScanCache = .{ .allocator = self.allocator, .io = self.io, .dir = self.dir, .file = undefined, .end = header.len };
        defer out.pending.deinit(self.allocator);
        try out.pending.appendSlice(self.allocator, header);
        while (it.next()) |e| try out.put(e.path, e.entry);

        {
            var tmp = try self.dir.createFile(self.io, tmp_name, .{ .truncate = true });
            defer tmp.close(self.io);
            try tmp.writePositionalAll(self.io, out.pending.items, 0);
        }
        try self.dir.rename(tmp_name, self.dir, file_name, self.io);
        const new_file = try self.dir.createFile(self.io, file_name, .{ .truncate = false, .read = true });
        self.file.close(self.io);
        self.file = new_file;
        self.end = out.pending.items.len;
        self.records = out.records;
        self.pending.clearRetainingCapacity();
    }
};

fn appendInt(w: *std.ArrayList(u8), comptime T: type, v: T) void {
    var buf: [@sizeOf(T)]u8 = undefined;
    std.mem.writeInt(T, &buf, v, .little);
    w.appendSliceAssumeCapacity(&buf);
}

const Parsed = struct {
    kind: enum { put, drop },
    path: []const u8,
    entry: Entry = undefined,
    len: usize,
};

/// The record at the start of `data`, or null at the end or at a torn or
/// unknown record.
fn parse(data: []const u8) ?Parsed {
    if (data.len < 3) return null;
    const path_len = std.mem.readInt(u16, data[1..3], .little);
    const path_end = 3 + @as(usize, path_len);
    if (data.len < path_end or path_len == 0) return null;
    const path = data[3..path_end];
    switch (data[0]) {
        tag_drop => return .{ .kind = .drop, .path = path, .len = path_end },
        tag_put => {
            const len = path_end + 8 + 8 + 8 + 8 + 32;
            if (data.len < len) return null;
            return .{ .kind = .put, .path = path, .len = len, .entry = .{
                .size = std.mem.readInt(u64, data[path_end..][0..8], .little),
                .mtime_ns = std.mem.readInt(i64, data[path_end + 8 ..][0..8], .little),
                .ctime_ns = std.mem.readInt(i64, data[path_end + 16 ..][0..8], .little),
                .inode = std.mem.readInt(u64, data[path_end + 24 ..][0..8], .little),
                .cid = data[path_end + 32 ..][0..32].*,
            } };
        },
        else => return null,
    }
}

const TestMap = struct {
    map: std.StringHashMapUnmanaged(Entry) = .empty,
    allocator: std.mem.Allocator,

    fn deinit(self: *TestMap) void {
        var it = self.map.keyIterator();
        while (it.next()) |k| self.allocator.free(k.*);
        self.map.deinit(self.allocator);
    }
    pub fn put(self: *TestMap, path: []const u8, e: Entry) !void {
        const gop = try self.map.getOrPut(self.allocator, path);
        if (!gop.found_existing) gop.key_ptr.* = try self.allocator.dupe(u8, path);
        gop.value_ptr.* = e;
    }
    pub fn drop(self: *TestMap, path: []const u8) !void {
        const kv = self.map.fetchRemove(path) orelse return;
        self.allocator.free(kv.key);
    }
};

test "scan cache: records survive a reopen, last one wins, torn tail ignored" {
    const testing = std.testing;
    const allocator = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const a: Entry = .{ .size = 5, .mtime_ns = 100, .ctime_ns = 100, .inode = 1, .cid = [_]u8{1} ** 32 };
    const b: Entry = .{ .size = 7, .mtime_ns = 200, .ctime_ns = 200, .inode = 2, .cid = [_]u8{2} ** 32 };
    {
        var empty: TestMap = .{ .allocator = allocator };
        defer empty.deinit();
        var cache = try ScanCache.open(allocator, io, tmp.dir, &empty);
        defer cache.close();
        try cache.put("/share/a", a);
        try cache.put("/share/b", a);
        try cache.put("/share/a", b);
        try cache.drop("/share/b");
    }
    {
        // A crash mid-record leaves a torn tail.
        var f = try tmp.dir.openFile(io, file_name, .{ .mode = .read_write });
        defer f.close(io);
        const size = (try f.stat(io)).size;
        try f.writePositionalAll(io, &.{ tag_put, 9, 0, '/' }, size);
    }
    var seen: TestMap = .{ .allocator = allocator };
    defer seen.deinit();
    var cache = try ScanCache.open(allocator, io, tmp.dir, &seen);
    defer cache.close();
    try testing.expectEqual(@as(u32, 1), seen.map.count());
    try testing.expectEqual(b, seen.map.get("/share/a").?);

    // Appends after the torn record replace it.
    try cache.put("/share/c", a);
    try cache.flush();
    var again: TestMap = .{ .allocator = allocator };
    defer again.deinit();
    var reopened = try ScanCache.open(allocator, io, tmp.dir, &again);
    defer reopened.close();
    try testing.expectEqual(@as(u32, 2), again.map.count());
}

test "scan cache: compaction keeps only live entries" {
    const testing = std.testing;
    const allocator = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const e: Entry = .{ .size = 1, .mtime_ns = 1, .ctime_ns = 1, .inode = 1, .cid = [_]u8{3} ** 32 };
    var empty: TestMap = .{ .allocator = allocator };
    defer empty.deinit();
    var cache = try ScanCache.open(allocator, io, tmp.dir, &empty);
    defer cache.close();
    for (0..10) |_| try cache.put("/x", e);
    try cache.flush();

    const Live = struct {
        done: bool = false,
        pub fn next(self: *@This()) ?struct { path: []const u8, entry: Entry } {
            if (self.done) return null;
            self.done = true;
            return .{ .path = "/x", .entry = e };
        }
    };
    var live: Live = .{};
    try cache.compact(&live);
    try testing.expectEqual(@as(u64, 1), cache.records);
    try cache.put("/y", e);
    try cache.flush();

    var seen: TestMap = .{ .allocator = allocator };
    defer seen.deinit();
    var reopened = try ScanCache.open(allocator, io, tmp.dir, &seen);
    defer reopened.close();
    try testing.expectEqual(@as(u32, 2), seen.map.count());
    try testing.expectEqual(@as(u64, 2), reopened.records);
}

test "scan cache: old cache format version drops old cache cleanly" {
    const testing = std.testing;
    const allocator = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    // Write a v1 cache
    {
        var f = try tmp.dir.createFile(io, file_name, .{ .truncate = true });
        defer f.close(io);
        try f.writePositionalAll(io, "NOMADFS-SCAN-CACHE-1\n", 0);
    }

    var seen: TestMap = .{ .allocator = allocator };
    defer seen.deinit();
    var cache = try ScanCache.open(allocator, io, tmp.dir, &seen);
    defer cache.close();
    try testing.expectEqual(@as(u32, 0), seen.map.count());
}
