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
//! scanner remembers their CIDs (and leaf locations), across restarts too
//! with a scan cache (scan_cache.zig). Symlinks, devices, sockets, names a peer
//! could not map onto its own filesystem, and entries that cannot be read
//! are skipped rather than failing the whole share.
//!
//! A first scan of a large folder takes long, so it can report progress: a
//! root of everything scanned so far, every `Progress.interval_ns`.

const std = @import("std");
const storage = @import("../storage/mod.zig");
const codec = storage.dag.codec;
const StorageEngine = storage.engine.StorageEngine;
const Block = storage.block.Block;
const filestore = @import("filestore.zig");
const ScanCache = @import("scan_cache.zig").ScanCache;

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
    /// Where the file's leaves sit (filestore scans only; owned). Empty
    /// for an entry loaded from the scan cache until a scan needs them.
    leaves: []filestore.Leaf = &.{},
    /// The scan that last saw the file (pruning).
    generation: u32 = 0,
};

/// Called during a long scan with a root of what has been scanned so far
/// (partial directories included). An error aborts the scan.
pub const Progress = struct {
    ctx: *anyopaque,
    reportFn: *const fn (ctx: *anyopaque, partial: Result) anyerror!void,
    /// The first report comes after `first_ns`, then every `interval_ns`.
    first_ns: u64 = 1 * std.time.ns_per_s,
    interval_ns: u64 = 10 * std.time.ns_per_s,
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
    /// The chunking buffers, reused for every file (allocated on first use).
    scratch: ?storage.dag.DagBuilder.Scratch = null,
    /// What `remembered` is saved to (loadCache).
    cache: ?ScanCache = null,
    /// The scan in progress, for `Remembered.generation`.
    generation: u32 = 0,
    /// Set for the next scan only (scan clears it).
    progress: ?Progress = null,
    /// The directories being scanned, outermost first (progress reports).
    frames: std.ArrayList(Frame) = .empty,
    next_report_ns: i96 = 0,
    files_seen: u64 = 0,
    /// Files read and hashed (not reused), since init.
    files_hashed: u64 = 0,

    const Frame = struct {
        name: []const u8,
        entries: *std.ArrayList(codec.DirEntry),
        total: *const u64,
    };

    pub fn init(allocator: std.mem.Allocator, io: std.Io, store: *StorageEngine) Scanner {
        return .{ .allocator = allocator, .io = io, .store = store };
    }

    /// Loads the scan cache kept in the store's directory, and saves to it
    /// from then on. Without it every start re-reads every shared file.
    pub fn loadCache(self: *Scanner) !void {
        if (self.cache != null) return;
        self.cache = try ScanCache.open(self.allocator, self.io, self.store.root_dir, self);
        std.debug.print("share: scan cache has {d} files\n", .{self.remembered.count()});
    }

    /// ScanCache.open visitor: an entry from disk.
    pub fn put(self: *Scanner, path: []const u8, e: @import("scan_cache.zig").Entry) !void {
        const gop = try self.remembered.getOrPut(self.allocator, path);
        if (gop.found_existing) {
            self.allocator.free(gop.value_ptr.leaves);
        } else {
            gop.key_ptr.* = self.allocator.dupe(u8, path) catch |err| {
                self.remembered.removeByPtr(gop.key_ptr);
                return err;
            };
        }
        gop.value_ptr.* = .{ .size = e.size, .mtime_ns = e.mtime_ns, .cid = e.cid };
    }

    /// ScanCache.open visitor: a forgotten entry.
    pub fn drop(self: *Scanner, path: []const u8) !void {
        const kv = self.remembered.fetchRemove(path) orelse return;
        self.allocator.free(kv.key);
        self.allocator.free(kv.value.leaves);
    }

    pub fn deinit(self: *Scanner) void {
        if (self.cache) |*c| c.close();
        self.frames.deinit(self.allocator);
        if (self.scratch) |*sc| sc.deinit(self.allocator);
        var it = self.remembered.iterator();
        while (it.next()) |e| {
            self.allocator.free(e.key_ptr.*);
            self.allocator.free(e.value_ptr.leaves);
        }
        self.remembered.deinit(self.allocator);
    }

    /// Builds the tree for the folder at `path` (absolute or cwd-relative).
    pub fn scan(self: *Scanner, path: []const u8) !Result {
        defer self.progress = null;
        defer self.frames.clearRetainingCapacity();
        self.generation +%= 1;
        self.files_seen = 0;
        if (self.progress) |p| self.next_report_ns = now(self.io) + p.first_ns;

        var dir = try std.Io.Dir.cwd().openDir(self.io, path, .{ .iterate = true });
        defer dir.close(self.io);
        var files: u64 = 0;
        const node = try self.scanDir(dir, "", path, 0, &files);
        self.forgetUnseen(path);
        self.saveCache();
        return .{ .root = node.cid, .size = node.size, .files = files };
    }

    /// Drops what's remembered under `root` that this scan didn't see
    /// (deleted or moved files).
    fn forgetUnseen(self: *Scanner, root: []const u8) void {
        const prefix = std.mem.trimEnd(u8, root, "/");
        var gone: std.ArrayList([]const u8) = .empty;
        defer gone.deinit(self.allocator);
        var it = self.remembered.iterator();
        while (it.next()) |e| {
            if (e.value_ptr.generation == self.generation) continue;
            const key = e.key_ptr.*;
            if (key.len <= prefix.len or !std.mem.startsWith(u8, key, prefix) or key[prefix.len] != '/') continue;
            gone.append(self.allocator, key) catch return;
        }
        for (gone.items) |key| {
            if (self.cache) |*c| c.drop(key) catch {};
            const kv = self.remembered.fetchRemove(key) orelse continue;
            self.allocator.free(kv.value.leaves);
            self.allocator.free(kv.key);
        }
    }

    /// Writes new cache records; rewrites the cache once it is mostly stale.
    fn saveCache(self: *Scanner) void {
        const c = &(self.cache orelse return);
        c.flush() catch |err| std.debug.print("share: saving the scan cache failed: {any}\n", .{err});
        if (!c.wantsCompaction(self.remembered.count())) return;
        var live: LiveEntries = .{ .it = self.remembered.iterator() };
        c.compact(&live) catch |err| std.debug.print("share: compacting the scan cache failed: {any}\n", .{err});
    }

    const LiveEntries = struct {
        it: std.StringHashMapUnmanaged(Remembered).Iterator,
        pub fn next(self: *LiveEntries) ?struct { path: []const u8, entry: @import("scan_cache.zig").Entry } {
            const e = self.it.next() orelse return null;
            return .{ .path = e.key_ptr.*, .entry = cacheEntry(e.value_ptr.*) };
        }
    };

    /// Reports progress when it's due: a root built from the directories
    /// still being scanned, each holding what it has so far.
    fn checkpoint(self: *Scanner) !void {
        const p = self.progress orelse return;
        const t = now(self.io);
        if (t < self.next_report_ns) return;
        self.next_report_ns = t + p.interval_ns;
        var child: ?codec.DirEntry = null;
        var child_cid: Cid = undefined;
        var i = self.frames.items.len;
        while (i > 0) {
            i -= 1;
            const frame = self.frames.items[i];
            var entries: std.ArrayList(codec.DirEntry) = .empty;
            defer entries.deinit(self.allocator);
            try entries.appendSlice(self.allocator, frame.entries.items);
            var size = frame.total.*;
            if (child) |c| {
                try entries.append(self.allocator, c);
                size += c.size;
            }
            sortEntries(entries.items);
            const bytes = try codec.encodeDir(self.allocator, entries.items);
            defer self.allocator.free(bytes);
            const block = Block.new(bytes);
            try self.store.put(block);
            child_cid = block.cid;
            child = .{ .name = frame.name, .cid = &child_cid, .size = size, .kind = .dir, .mtime = 0 };
        }
        const root = child orelse return;
        self.saveCache();
        try p.reportFn(p.ctx, .{ .root = child_cid, .size = root.size, .files = self.files_seen });
    }

    const Node = struct { cid: Cid, size: u64 };

    fn scanDir(self: *Scanner, dir: std.Io.Dir, name: []const u8, path: []const u8, depth: u8, files: *u64) anyerror!Node {
        var arena_state = std.heap.ArenaAllocator.init(self.allocator);
        defer arena_state.deinit();
        const arena = arena_state.allocator();

        var entries: std.ArrayList(codec.DirEntry) = .empty;
        var total: u64 = 0;
        try self.frames.append(self.allocator, .{ .name = name, .entries = &entries, .total = &total });
        defer _ = self.frames.pop();

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
                    self.files_seen += 1;
                    // A failed report is retried at the next one; only a
                    // cancelled scan stops.
                    self.checkpoint() catch |err| {
                        if (err == error.ScanCancelled) return err;
                        std.debug.print("share: progress report failed: {any}\n", .{err});
                    };
                },
                .directory => {
                    if (depth + 1 >= max_depth) continue;
                    var sub = dir.openDir(self.io, entry.name, .{ .iterate = true, .follow_symlinks = false }) catch |err| {
                        std.debug.print("share: skipping {s}: {any}\n", .{ child_path, err });
                        continue;
                    };
                    defer sub.close(self.io);
                    const mtime = mtimeSeconds((sub.stat(self.io) catch null));
                    const child = self.scanDir(sub, entry.name, child_path, depth + 1, files) catch |err| switch (err) {
                        error.ScanCancelled => return err,
                        else => {
                            std.debug.print("share: skipping {s}: {any}\n", .{ child_path, err });
                            continue;
                        },
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

        sortEntries(entries.items);
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

        if (self.remembered.getPtr(full_path)) |seen| reuse: {
            if (seen.size != stat.size or seen.mtime_ns != mtime_ns) break :reuse;
            if (self.table) |table| {
                // From the scan cache: the leaves are listed by the file's
                // parent blocks, already in the store.
                if (seen.leaves.len == 0 and seen.size > 0) {
                    seen.leaves = (self.leavesFromStore(seen.cid, seen.size) catch null) orelse break :reuse;
                }
                try table.addFile(full_path, seen.leaves);
            }
            seen.generation = self.generation;
            return .{ .cid = seen.cid, .size = seen.size, .mtime = mtimeSeconds(stat) };
        }

        var leaves: std.ArrayList(filestore.Leaf) = .empty;
        defer leaves.deinit(self.allocator);
        var collector = LeafCollector{ .allocator = self.allocator, .leaves = &leaves };

        if (self.scratch == null) self.scratch = try storage.dag.DagBuilder.Scratch.init(self.allocator);
        var builder = storage.dag.DagBuilder{
            .allocator = self.allocator,
            .store = self.store,
            .layout = .Balanced,
            .leaf_sink = if (self.table != null) collector.sink() else null,
            .scratch = &self.scratch.?,
        };
        var reader = FileReader{ .io = self.io, .file = file };
        const root = try builder.build(&reader);
        self.files_hashed += 1;
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
        gop.value_ptr.* = .{ .size = reader.offset, .mtime_ns = mtime_ns, .cid = cid, .leaves = owned_leaves, .generation = self.generation };
        if (self.cache) |*c| c.put(full_path, cacheEntry(gop.value_ptr.*)) catch {};
        return .{ .cid = cid, .size = reader.offset, .mtime = mtimeSeconds(stat) };
    }

    /// The leaves of the file DAG at `root`, read from its parent blocks in
    /// the store (leaves themselves are not stored for shared files), or
    /// null when a block is missing. Owned by the caller.
    fn leavesFromStore(self: *Scanner, root: Cid, size: u64) !?[]filestore.Leaf {
        var leaves: std.ArrayList(filestore.Leaf) = .empty;
        errdefer leaves.deinit(self.allocator);
        const bytes = try self.store.getLocal(&root, self.allocator) orelse {
            // Not stored: the file is a single leaf.
            if (size > storage.dag.builder.chunk_params.max_size) return null;
            try leaves.append(self.allocator, .{ .cid = root, .offset = 0, .len = @intCast(size) });
            return try leaves.toOwnedSlice(self.allocator);
        };
        defer self.allocator.free(bytes);
        var offset: u64 = 0;
        switch (codec.decode(bytes) catch return null) {
            .parent => |links| if (!try self.appendLeaves(links, &offset, &leaves)) return null,
            else => return null,
        }
        if (offset != size) return null;
        return try leaves.toOwnedSlice(self.allocator);
    }

    /// Appends the leaves under a parent's `links`. A balanced DAG keeps
    /// all leaves at one depth, so the first child tells whether these
    /// links are leaves (not stored) or parents.
    fn appendLeaves(self: *Scanner, links: codec.LinkIterator, offset: *u64, out: *std.ArrayList(filestore.Leaf)) !bool {
        var it = links;
        var probe = links;
        const first = probe.next() orelse return true;
        const first_bytes = try self.store.getLocal(first.cid, self.allocator);
        if (first_bytes == null) {
            while (it.next()) |link| {
                if (link.size > storage.dag.builder.chunk_params.max_size) return false;
                try out.append(self.allocator, .{ .cid = link.cid.*, .offset = offset.*, .len = @intCast(link.size) });
                offset.* += link.size;
            }
            return true;
        }
        self.allocator.free(first_bytes.?);
        while (it.next()) |link| {
            const bytes = try self.store.getLocal(link.cid, self.allocator) orelse return false;
            defer self.allocator.free(bytes);
            switch (codec.decode(bytes) catch return false) {
                .parent => |sub| if (!try self.appendLeaves(sub, offset, out)) return false,
                else => return false,
            }
        }
        return true;
    }
};

fn sortEntries(entries: []codec.DirEntry) void {
    std.mem.sort(codec.DirEntry, entries, {}, struct {
        fn lessThan(_: void, a: codec.DirEntry, b: codec.DirEntry) bool {
            return std.mem.order(u8, a.name, b.name) == .lt;
        }
    }.lessThan);
}

fn cacheEntry(r: Remembered) @import("scan_cache.zig").Entry {
    return .{ .size = r.size, .mtime_ns = @intCast(std.math.clamp(r.mtime_ns, std.math.minInt(i64), std.math.maxInt(i64))), .cid = r.cid };
}

fn now(io: std.Io) i96 {
    return std.Io.Timestamp.now(io, .awake).nanoseconds;
}

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
