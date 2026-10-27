//! Reads shared trees one block at a time. Listing a directory loads only
//! its dir block and reading a file range loads only the blocks on the path
//! to the bytes asked for, so a remote share can be browsed and streamed
//! without copying it. Where blocks come from is up to the Loader: the local
//! store, or the store backed by a peer (remote.zig).

const std = @import("std");
const storage = @import("../storage/mod.zig");
const codec = storage.dag.codec;
const StorageEngine = storage.engine.StorageEngine;

pub const Cid = codec.Cid;
pub const EntryKind = codec.EntryKind;

/// Source of verified blocks. `loadFn` returns caller-owned bytes whose
/// SHA-256 matches `cid`, or error.BlockNotFound.
pub const Loader = struct {
    ctx: *anyopaque,
    loadFn: *const fn (ctx: *anyopaque, cid: *const Cid, allocator: std.mem.Allocator) anyerror![]u8,

    pub fn load(self: Loader, cid: *const Cid, allocator: std.mem.Allocator) ![]u8 {
        return self.loadFn(self.ctx, cid, allocator);
    }

    /// Blocks from `store` only.
    pub fn local(store: *StorageEngine) Loader {
        return .{ .ctx = store, .loadFn = loadLocal };
    }

    fn loadLocal(ctx: *anyopaque, cid: *const Cid, allocator: std.mem.Allocator) anyerror![]u8 {
        const store: *StorageEngine = @ptrCast(@alignCast(ctx));
        const block = (try store.get(cid, allocator)) orelse return error.BlockNotFound;
        return @constCast(block.data);
    }
};

pub const Entry = struct {
    name: []const u8,
    cid: Cid,
    size: u64,
    kind: EntryKind,
    mtime: u64,
};

/// A directory listing; names are owned by the listing.
pub const Listing = struct {
    entries: []Entry,
    allocator: std.mem.Allocator,

    pub fn deinit(self: Listing) void {
        for (self.entries) |e| self.allocator.free(e.name);
        self.allocator.free(self.entries);
    }

    /// Entries are sorted by name, so lookups are a binary search.
    pub fn find(self: Listing, name: []const u8) ?Entry {
        var lo: usize = 0;
        var hi: usize = self.entries.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            switch (std.mem.order(u8, self.entries[mid].name, name)) {
                .eq => return self.entries[mid],
                .lt => lo = mid + 1,
                .gt => hi = mid,
            }
        }
        return null;
    }
};

/// Decodes an encoded dir block (a dir from a tree, or a share listing).
pub fn decodeListing(allocator: std.mem.Allocator, bytes: []const u8) !Listing {
    var it = switch (try codec.decode(bytes)) {
        .dir => |d| d,
        else => return error.NotADirectory,
    };
    const entries = try allocator.alloc(Entry, it.count);
    var filled: usize = 0;
    errdefer {
        for (entries[0..filled]) |e| allocator.free(e.name);
        allocator.free(entries);
    }
    while (it.next()) |e| : (filled += 1) {
        entries[filled] = .{
            .name = try allocator.dupe(u8, e.name),
            .cid = e.cid.*,
            .size = e.size,
            .kind = e.kind,
            .mtime = e.mtime,
        };
    }
    return .{ .entries = entries, .allocator = allocator };
}

pub fn listDir(allocator: std.mem.Allocator, loader: Loader, cid: *const Cid) !Listing {
    const bytes = try loader.load(cid, allocator);
    defer allocator.free(bytes);
    return decodeListing(allocator, bytes);
}

/// Resolves a '/'-separated `path` below the dir `root`. An empty path (or
/// "/") is the root itself, returned as a dir entry named "".
pub fn resolve(allocator: std.mem.Allocator, loader: Loader, root: Cid, path: []const u8) !Entry {
    var current = Entry{ .name = "", .cid = root, .size = 0, .kind = .dir, .mtime = 0 };
    var parts = std.mem.tokenizeScalar(u8, path, '/');
    while (parts.next()) |part| {
        if (current.kind != .dir) return error.NotADirectory;
        const listing = try listDir(allocator, loader, &current.cid);
        defer listing.deinit();
        const found = listing.find(part) orelse return error.FileNotFound;
        current = .{ .name = "", .cid = found.cid, .size = found.size, .kind = found.kind, .mtime = found.mtime };
    }
    return current;
}

/// Copies bytes of the file DAG `root` starting at `offset` into `dest`.
/// Returns how many were copied: less than dest.len only at end of file.
/// Each leaf is reached by descending from the root using the subtree
/// sizes stored in parent links, so only the blocks covering the range are
/// loaded.
pub fn readAt(allocator: std.mem.Allocator, loader: Loader, root: Cid, offset: u64, dest: []u8) !usize {
    var copied: usize = 0;
    while (copied < dest.len) {
        const n = try readLeafAt(allocator, loader, root, offset + copied, dest[copied..]);
        if (n == 0) break;
        copied += n;
    }
    return copied;
}

/// Bound on parent levels between a file root and its leaves.
const max_tree_depth = 64;

/// Copies from the single leaf holding byte `pos`; 0 past end of file.
fn readLeafAt(allocator: std.mem.Allocator, loader: Loader, root: Cid, pos: u64, dest: []u8) !usize {
    var cid = root;
    var rel = pos;
    var depth: usize = 0;
    while (depth < max_tree_depth) : (depth += 1) {
        const bytes = try loader.load(&cid, allocator);
        defer allocator.free(bytes);
        switch (try codec.decode(bytes)) {
            .leaf => |data| {
                if (rel >= data.len) return 0;
                const n: usize = @intCast(@min(data.len - rel, dest.len));
                @memcpy(dest[0..n], data[@intCast(rel)..][0..n]);
                return n;
            },
            .parent => |links| {
                var it = links;
                const child = while (it.next()) |link| {
                    if (rel < link.size) break link.cid.*;
                    rel -= link.size;
                } else return 0;
                cid = child;
            },
            .dir => return error.IsDirectory,
        }
    }
    return error.DagTooDeep;
}

test "tree: scan a folder, list it and read ranges" {
    const testing = std.testing;
    const allocator = testing.allocator;
    const io = testing.io;
    const scan = @import("scan.zig");

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "share/sub");
    try tmp.dir.writeFile(io, .{ .sub_path = "share/hello.txt", .data = "hello world" });
    // Big enough for several chunks, so reads cross leaf boundaries.
    const big = try allocator.alloc(u8, 3 * 1024 * 1024 + 17);
    defer allocator.free(big);
    for (big, 0..) |*b, i| b.* = @truncate(i *% 2654435761 >> 13);
    try tmp.dir.writeFile(io, .{ .sub_path = "share/sub/big.bin", .data = big });

    var store_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmp_path = store_path_buf[0..try tmp.dir.realPath(io, &store_path_buf)];
    const store_path = try std.fs.path.join(allocator, &.{ tmp_path, "blocks" });
    defer allocator.free(store_path);
    try tmp.dir.createDirPath(io, "blocks");
    var store = try StorageEngine.init(allocator, store_path);
    defer store.deinit();

    const share_path = try std.fs.path.join(allocator, &.{ tmp_path, "share" });
    defer allocator.free(share_path);
    var scanner = scan.Scanner.init(allocator, io, &store);
    defer scanner.deinit();
    const result = try scanner.scan(share_path);
    try testing.expectEqual(@as(u64, 2), result.files);
    try testing.expectEqual(@as(u64, 11 + big.len), result.size);

    const loader = Loader.local(&store);
    const top = try listDir(allocator, loader, &result.root);
    defer top.deinit();
    try testing.expectEqual(@as(usize, 2), top.entries.len);
    try testing.expectEqualStrings("hello.txt", top.entries[0].name);
    try testing.expectEqual(EntryKind.file, top.entries[0].kind);
    try testing.expectEqualStrings("sub", top.entries[1].name);
    try testing.expectEqual(EntryKind.dir, top.entries[1].kind);

    const file = try resolve(allocator, loader, result.root, "sub/big.bin");
    try testing.expectEqual(@as(u64, big.len), file.size);
    var buf: [100_000]u8 = undefined;
    for ([_]u64{ 0, 1, 262_143, 1_000_000, big.len - 50_000 }) |off| {
        const n = try readAt(allocator, loader, file.cid, off, &buf);
        const want = @min(buf.len, big.len - off);
        try testing.expectEqual(want, n);
        try testing.expectEqualSlices(u8, big[@intCast(off)..][0..want], buf[0..n]);
    }
    try testing.expectEqual(@as(usize, 0), try readAt(allocator, loader, file.cid, big.len, &buf));
    try testing.expectError(error.FileNotFound, resolve(allocator, loader, result.root, "nope"));

    // An unchanged rescan reproduces the same root; an edit changes it.
    const again = try scanner.scan(share_path);
    try testing.expectEqualSlices(u8, &result.root, &again.root);
    try tmp.dir.writeFile(io, .{ .sub_path = "share/hello.txt", .data = "hello there" });
    const edited = try scanner.scan(share_path);
    try testing.expect(!std.mem.eql(u8, &result.root, &edited.root));
}
