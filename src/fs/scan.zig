//! Turns a local folder into a Merkle tree: every regular file becomes a
//! file DAG (DagBuilder) and every directory a dir block (codec.encodeDir)
//! listing its children by name. The folder's root CID changes whenever
//! anything under it changes, and unchanged files reuse their blocks.
//!
//! With a filestore table set, file bytes are not copied: leaves are
//! recorded as (file, offset, length) and served from the files themselves
//! (filestore.zig); only dir and parent blocks enter the store.
//!
//! Files whose size and mtime match the previous scan are not re-read: the
//! scanner remembers their CIDs (and leaf locations). Symlinks, devices, sockets, names a peer
//! could not map onto its own filesystem, and entries that cannot be read
//! are skipped rather than failing the whole share.

const std = @import("std");
const storage = @import("../storage/mod.zig");
const codec = storage.dag.codec;
const StorageEngine = storage.engine.StorageEngine;
const Block = storage.block.Block;
const filestore = @import("filestore.zig");

pub const Cid = codec.Cid;

/// Directory nesting a scan follows. Deeper subtrees are skipped.
pub const max_depth = 32;

pub const Result = struct {
    root: Cid,
    /// Sum of file sizes under the folder.
    size: u64,
    files: u64,
};

const Remembered = struct {
    size: u64,
    mtime_ns: i96,
    cid: Cid,
    /// Where the file's leaves sit (filestore scans only; owned).
    leaves: []filestore.Leaf = &.{},
};

pub const Scanner = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    store: *StorageEngine,
    /// Absolute file path -> what the last scan built from it.
    remembered: std.StringHashMapUnmanaged(Remembered) = .empty,
    /// When set, file bytes stay in the files: leaves are recorded here
    /// instead of copied into `store` (see filestore.zig). Dir and parent
    /// blocks are stored either way.
    table: ?*filestore.Table = null,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, store: *StorageEngine) Scanner {
        return .{ .allocator = allocator, .io = io, .store = store };
    }

    pub fn deinit(self: *Scanner) void {
        var it = self.remembered.iterator();
        while (it.next()) |e| {
            self.allocator.free(e.key_ptr.*);
            self.allocator.free(e.value_ptr.leaves);
        }
        self.remembered.deinit(self.allocator);
    }

    /// Builds the tree for the folder at `path` (absolute or cwd-relative).
    pub fn scan(self: *Scanner, path: []const u8) !Result {
        var dir = try std.Io.Dir.cwd().openDir(self.io, path, .{ .iterate = true });
        defer dir.close(self.io);
        var files: u64 = 0;
        const node = try self.scanDir(dir, path, 0, &files);
        return .{ .root = node.cid, .size = node.size, .files = files };
    }

    const Node = struct { cid: Cid, size: u64 };

    fn scanDir(self: *Scanner, dir: std.Io.Dir, path: []const u8, depth: u8, files: *u64) anyerror!Node {
        var arena_state = std.heap.ArenaAllocator.init(self.allocator);
        defer arena_state.deinit();
        const arena = arena_state.allocator();

        var entries: std.ArrayList(codec.DirEntry) = .empty;
        var total: u64 = 0;

        var it = dir.iterate();
        while (try it.next(self.io)) |entry| {
            if (!codec.isValidName(entry.name)) continue;
            const child_path = try std.fs.path.join(arena, &.{ path, entry.name });
            switch (entry.kind) {
                .file => {
                    const built = self.scanFile(dir, entry.name, child_path) catch |err| {
                        std.debug.print("share: skipping {s}: {any}\n", .{ child_path, err });
                        continue;
                    };
                    try entries.append(arena, .{
                        .name = try arena.dupe(u8, entry.name),
                        .cid = try arena.dupe(u8, &built.cid),
                        .size = built.size,
                        .kind = .file,
                        .mtime = built.mtime,
                    });
                    total += built.size;
                    files.* += 1;
                },
                .directory => {
                    if (depth + 1 >= max_depth) continue;
                    var sub = dir.openDir(self.io, entry.name, .{ .iterate = true, .follow_symlinks = false }) catch |err| {
                        std.debug.print("share: skipping {s}: {any}\n", .{ child_path, err });
                        continue;
                    };
                    defer sub.close(self.io);
                    const mtime = mtimeSeconds((sub.stat(self.io) catch null));
                    const child = self.scanDir(sub, child_path, depth + 1, files) catch |err| {
                        std.debug.print("share: skipping {s}: {any}\n", .{ child_path, err });
                        continue;
                    };
                    try entries.append(arena, .{
                        .name = try arena.dupe(u8, entry.name),
                        .cid = try arena.dupe(u8, &child.cid),
                        .size = child.size,
                        .kind = .dir,
                        .mtime = mtime,
                    });
                    total += child.size;
                },
                else => {},
            }
        }

        std.mem.sort(codec.DirEntry, entries.items, {}, struct {
            fn lessThan(_: void, a: codec.DirEntry, b: codec.DirEntry) bool {
                return std.mem.order(u8, a.name, b.name) == .lt;
            }
        }.lessThan);

        const bytes = try codec.encodeDir(self.allocator, entries.items);
        defer self.allocator.free(bytes);
        const block = Block.new(bytes);
        try self.store.put(block);
        return .{ .cid = block.cid, .size = total };
    }

    const Built = struct { cid: Cid, size: u64, mtime: u64 };

    fn scanFile(self: *Scanner, dir: std.Io.Dir, name: []const u8, full_path: []const u8) !Built {
        var file = try dir.openFile(self.io, name, .{});
        defer file.close(self.io);
        const stat = try file.stat(self.io);
        const mtime_ns = stat.mtime.nanoseconds;

        if (self.remembered.get(full_path)) |seen| {
            const usable = self.table == null or seen.leaves.len > 0 or seen.size == 0;
            if (usable and seen.size == stat.size and seen.mtime_ns == mtime_ns) {
                if (self.table) |table| try table.addFile(full_path, seen.leaves);
                return .{ .cid = seen.cid, .size = seen.size, .mtime = mtimeSeconds(stat) };
            }
        }

        var leaves: std.ArrayList(filestore.Leaf) = .empty;
        defer leaves.deinit(self.allocator);
        var collector = LeafCollector{ .allocator = self.allocator, .leaves = &leaves };

        var builder = storage.dag.DagBuilder{
            .allocator = self.allocator,
            .store = self.store,
            .layout = .Balanced,
            .leaf_sink = if (self.table != null) collector.sink() else null,
        };
        var reader = FileReader{ .io = self.io, .file = file };
        const root = try builder.build(&reader);
        defer self.allocator.free(root);
        const cid: Cid = root[0..codec.cid_len].*;

        if (self.table) |table| try table.addFile(full_path, leaves.items);
        const owned_leaves = try leaves.toOwnedSlice(self.allocator);
        errdefer self.allocator.free(owned_leaves);

        const gop = try self.remembered.getOrPut(self.allocator, full_path);
        if (gop.found_existing) {
            self.allocator.free(gop.value_ptr.leaves);
        } else {
            gop.key_ptr.* = self.allocator.dupe(u8, full_path) catch |err| {
                self.remembered.removeByPtr(gop.key_ptr);
                return err;
            };
        }
        gop.value_ptr.* = .{ .size = reader.offset, .mtime_ns = mtime_ns, .cid = cid, .leaves = owned_leaves };
        return .{ .cid = cid, .size = reader.offset, .mtime = mtimeSeconds(stat) };
    }
};

const LeafCollector = struct {
    allocator: std.mem.Allocator,
    leaves: *std.ArrayList(filestore.Leaf),

    fn sink(self: *LeafCollector) storage.dag.DagBuilder.LeafSink {
        return .{ .ctx = self, .recordFn = record };
    }

    fn record(ctx: *anyopaque, cid: *const [32]u8, offset: u64, len: u32) anyerror!void {
        const self: *LeafCollector = @ptrCast(@alignCast(ctx));
        try self.leaves.append(self.allocator, .{ .cid = cid.*, .offset = offset, .len = len });
    }
};

fn mtimeSeconds(stat: ?std.Io.File.Stat) u64 {
    const s = stat orelse return 0;
    return @intCast(@max(0, @divFloor(s.mtime.nanoseconds, std.time.ns_per_s)));
}

const FileReader = struct {
    io: std.Io,
    file: std.Io.File,
    offset: u64 = 0,

    pub fn read(self: *FileReader, dest: []u8) std.Io.File.ReadPositionalError!usize {
        if (dest.len == 0) return 0;
        const n = try self.file.readPositional(self.io, &.{dest}, self.offset);
        self.offset += n;
        return n;
    }
};
