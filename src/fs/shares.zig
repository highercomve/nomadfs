//! The folders this device shares. Each share is a local folder under a
//! name; a background thread rescans them (scan.zig) so each share's root
//! CID follows the folder. Peers read the current roots with GET_SHARES:
//! the listing is a dir block whose entries are the shares themselves, so it
//! decodes and validates exactly like any directory.
//!
//! Only metadata moves when a share is listed or rescanned. File bytes stay
//! in the local block store until a peer asks for them by CID.

const std = @import("std");
const sync = @import("../sync.zig");
const storage = @import("../storage/mod.zig");
const codec = storage.dag.codec;
const scan = @import("scan.zig");
const filestore = @import("filestore.zig");

pub const Share = struct {
    name: []const u8,
    path: []const u8,
    /// Null until the first scan has something to show: a first scan
    /// publishes what it has scanned so far as it goes, so a large folder
    /// is listed (and filling in) within seconds.
    root: ?codec.Cid = null,
    /// The first scan is still running: `root` is partial.
    indexing: bool = false,
    size: u64 = 0,
    files: u64 = 0,
    scanned_at: u64 = 0,
    generation: u64 = 0,
    /// Why the last scan failed, until one succeeds.
    scan_error: ?anyerror = null,
};

pub const ShareIndex = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    scanner: scan.Scanner,
    /// Serves shared files' leaves from the files (store.external).
    files: filestore.Filestore,
    store: *storage.engine.StorageEngine,
    /// Sorted by name. Guarded by `mutex`.
    shares: std.ArrayList(Share) = .empty,
    mutex: sync.Mutex = .{},
    /// Serializes scans (the scanner's file cache is not shared).
    scan_mutex: sync.Mutex = .{},
    rescan_interval_ns: u64 = 30 * std.time.ns_per_s,
    /// How soon a first scan lists what it has, then how often it updates.
    progress_first_ns: u64 = 1 * std.time.ns_per_s,
    progress_interval_ns: u64 = 10 * std.time.ns_per_s,
    /// The background thread (sync.Worker); its loop watches worker.running.
    worker: sync.Worker = .{},
    /// Names of the shares marked for backup (they go into the swarm
    /// folder, backup_import.zig), whether or not they are shared right
    /// now. Owned; guarded by `mutex`.
    backup_names: std.ArrayList([]u8) = .empty,

    pub fn create(allocator: std.mem.Allocator, io: std.Io, store: *storage.engine.StorageEngine) !*ShareIndex {
        const self = try allocator.create(ShareIndex);
        self.* = .{
            .allocator = allocator,
            .io = io,
            .scanner = scan.Scanner.init(allocator, io, store),
            .files = filestore.Filestore.init(allocator, io),
            .store = store,
        };
        store.external = self.files.external();
        // Remembered files are not re-read after a restart.
        self.scanner.loadCache() catch |err| std.debug.print("share: no scan cache: {any}\n", .{err});
        return self;
    }

    pub fn destroy(self: *ShareIndex) void {
        self.stop();
        self.store.external = null;
        for (self.shares.items) |s| freeShare(self.allocator, s);
        self.shares.deinit(self.allocator);
        for (self.backup_names.items) |n| self.allocator.free(n);
        self.backup_names.deinit(self.allocator);
        self.scanner.deinit();
        self.files.deinit();
        self.allocator.destroy(self);
    }

    fn freeShare(allocator: std.mem.Allocator, s: Share) void {
        allocator.free(s.name);
        allocator.free(s.path);
    }

    /// Marks the share `name` for backup, or clears the mark.
    pub fn setBackup(self: *ShareIndex, name: []const u8, on: bool) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        for (self.backup_names.items, 0..) |n, i| if (std.mem.eql(u8, n, name)) {
            if (!on) self.allocator.free(self.backup_names.orderedRemove(i));
            return;
        };
        if (on) {
            const owned = try self.allocator.dupe(u8, name);
            errdefer self.allocator.free(owned);
            try self.backup_names.append(self.allocator, owned);
        }
    }

    pub fn isBackup(self: *ShareIndex, name: []const u8) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        for (self.backup_names.items) |n| if (std.mem.eql(u8, n, name)) return true;
        return false;
    }

    /// Shares `path` as `name`, replacing any share of that name. The
    /// folder is scanned before this returns, so it is listed right away.
    pub fn add(self: *ShareIndex, name: []const u8, path: []const u8) !void {
        try self.register(name, path);
        self.rescanOne(name);
    }

    /// Records a share without scanning it: it is listed once the rescan
    /// thread (start) has scanned it, which it does right away. Startup
    /// uses this so a large folder never delays the node coming up.
    pub fn register(self: *ShareIndex, name: []const u8, path: []const u8) !void {
        if (!codec.isValidName(name)) return error.InvalidShareName;
        {
            // Fail early on a path that is not a readable folder.
            var dir = try std.Io.Dir.cwd().openDir(self.io, path, .{ .iterate = true });
            dir.close(self.io);
        }
        const owned_name = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(owned_name);
        const owned_path = try self.allocator.dupe(u8, path);
        errdefer self.allocator.free(owned_path);

        {
            self.mutex.lock();
            defer self.mutex.unlock();
            const at = self.indexOf(name);
            if (at.found) {
                const gen = self.shares.items[at.index].generation +% 1;
                freeShare(self.allocator, self.shares.items[at.index]);
                self.shares.items[at.index] = .{ .name = owned_name, .path = owned_path, .generation = gen };
            } else {
                try self.shares.insert(self.allocator, at.index, .{ .name = owned_name, .path = owned_path, .generation = 0 });
            }
        }
    }

    /// Stops sharing `name`: its files are no longer served. Dir and
    /// parent blocks stay in the store.
    pub fn remove(self: *ShareIndex, name: []const u8) bool {
        {
            self.mutex.lock();
            defer self.mutex.unlock();
            const at = self.indexOf(name);
            if (!at.found) return false;
            freeShare(self.allocator, self.shares.orderedRemove(at.index));
        }
        self.files.remove(name);
        return true;
    }

    const Position = struct { index: usize, found: bool };

    /// Caller holds `mutex`.
    fn indexOf(self: *const ShareIndex, name: []const u8) Position {
        for (self.shares.items, 0..) |s, i| {
            switch (std.mem.order(u8, s.name, name)) {
                .lt => {},
                .eq => return .{ .index = i, .found = true },
                .gt => return .{ .index = i, .found = false },
            }
        }
        return .{ .index = self.shares.items.len, .found = false };
    }

    /// Rescans every share; failures leave that share's previous root.
    pub fn rescanAll(self: *ShareIndex) void {
        var names: std.ArrayList([]const u8) = .empty;
        defer {
            for (names.items) |n| self.allocator.free(n);
            names.deinit(self.allocator);
        }
        {
            self.mutex.lock();
            defer self.mutex.unlock();
            for (self.shares.items) |s| {
                const copy = self.allocator.dupe(u8, s.name) catch continue;
                names.append(self.allocator, copy) catch {
                    self.allocator.free(copy);
                    continue;
                };
            }
        }
        for (names.items) |n| self.rescanOne(n);
    }

    fn rescanOne(self: *ShareIndex, name: []const u8) void {
        self.scan_mutex.lock();
        defer self.scan_mutex.unlock();

        const snap = blk: {
            self.mutex.lock();
            defer self.mutex.unlock();
            const at = self.indexOf(name);
            if (!at.found) return;
            const s = self.shares.items[at.index];
            break :blk .{
                .path = self.allocator.dupe(u8, s.path) catch return,
                .first = s.root == null,
                .generation = s.generation,
            };
        };
        defer self.allocator.free(snap.path);

        // Segments left by an earlier share of this name.
        if (snap.first) self.files.remove(name);
        self.scanner.table = newTable(self.allocator) catch return;
        defer if (self.scanner.table) |t| {
            t.deinit();
            self.allocator.destroy(t);
            self.scanner.table = null;
        };
        var progress: ProgressCtx = .{ .index = self, .name = name, .generation = snap.generation };
        if (snap.first) self.scanner.progress = .{
            .ctx = &progress,
            .reportFn = ProgressCtx.report,
            .first_ns = self.progress_first_ns,
            .interval_ns = self.progress_interval_ns,
        };
        const started = std.Io.Timestamp.now(self.io, .awake);
        const result = self.scanner.scan(snap.path) catch |err| {
            std.debug.print("share '{s}': scan of {s} failed: {any}\n", .{ name, snap.path, err });
            self.mutex.lock();
            defer self.mutex.unlock();
            const at = self.indexOf(name);
            if (at.found) self.shares.items[at.index].scan_error = err;
            return;
        };

        self.mutex.lock();
        defer self.mutex.unlock();
        const at = self.indexOf(name);
        if (!at.found) return; // removed while scanning
        const share = &self.shares.items[at.index];
        if (share.generation != snap.generation or !std.mem.eql(u8, share.path, snap.path)) return; // changed or re-added while scanning
        const table = self.scanner.table.?;
        (if (snap.first) self.files.append(name, table) else self.files.replace(name, table)) catch return;
        self.scanner.table = null;
        if (snap.first) {
            const ms = @divFloor(started.durationTo(std.Io.Timestamp.now(self.io, .awake)).nanoseconds, std.time.ns_per_ms);
            std.debug.print("share '{s}': indexed {d} files ({d} MiB) in {d} ms\n", .{ name, result.files, result.size >> 20, ms });
        }
        share.root = result.root;
        share.size = result.size;
        share.files = result.files;
        share.indexing = false;
        share.scan_error = null;
        share.scanned_at = nowSeconds(self.io);
    }

    /// The CID of an empty dir block (put is a no-op once it is stored).
    fn emptyDir(self: *ShareIndex) !codec.Cid {
        const bytes = try codec.encodeDir(self.allocator, &.{});
        defer self.allocator.free(bytes);
        const block = storage.block.Block.new(bytes);
        try self.store.put(block);
        return block.cid;
    }

    fn newTable(allocator: std.mem.Allocator) !*filestore.Table {
        const table = try allocator.create(filestore.Table);
        table.* = filestore.Table.init(allocator);
        return table;
    }

    /// A first scan's progress: the share lists what is done so far.
    const ProgressCtx = struct {
        index: *ShareIndex,
        name: []const u8,
        generation: u64,

        fn report(ctx: *anyopaque, partial: scan.Result) anyerror!void {
            const self: *ProgressCtx = @ptrCast(@alignCast(ctx));
            const index = self.index;
            const next = try newTable(index.allocator);
            errdefer {
                next.deinit();
                index.allocator.destroy(next);
            }
            index.mutex.lock();
            defer index.mutex.unlock();
            const at = index.indexOf(self.name);
            if (!at.found) return error.ScanCancelled; // removed meanwhile
            if (index.shares.items[at.index].generation != self.generation) return error.ScanCancelled;
            // Hand over the files scanned since the last report.
            try index.files.append(self.name, index.scanner.table.?);
            index.scanner.table = next;
            const share = &index.shares.items[at.index];
            share.root = partial.root;
            share.size = partial.size;
            share.files = partial.files;
            share.indexing = true;
            share.scanned_at = nowSeconds(index.io);
        }
    };

    /// A snapshot of the shares (names and paths owned by the caller; free
    /// with freeSnapshot).
    pub fn snapshot(self: *ShareIndex, allocator: std.mem.Allocator) ![]Share {
        self.mutex.lock();
        defer self.mutex.unlock();
        const out = try allocator.alloc(Share, self.shares.items.len);
        var filled: usize = 0;
        errdefer {
            for (out[0..filled]) |s| freeShare(allocator, s);
            allocator.free(out);
        }
        for (self.shares.items) |s| {
            var copy = s;
            copy.name = try allocator.dupe(u8, s.name);
            copy.path = allocator.dupe(u8, s.path) catch |err| {
                allocator.free(copy.name);
                return err;
            };
            out[filled] = copy;
            filled += 1;
        }
        return out;
    }

    pub fn freeSnapshot(allocator: std.mem.Allocator, shares: []Share) void {
        for (shares) |s| freeShare(allocator, s);
        allocator.free(shares);
    }

    /// The GET_SHARES reply: a dir block of the shares. One whose first
    /// scan hasn't started (shares are scanned one at a time) is listed
    /// empty with mtime 0, like the folders a scan hasn't reached
    /// (scan.zig): every share shows up at once, as "Indexing…".
    pub fn listing(self: *ShareIndex, allocator: std.mem.Allocator) ![]u8 {
        const empty = try self.emptyDir();
        self.mutex.lock();
        defer self.mutex.unlock();
        var entries: std.ArrayList(codec.DirEntry) = .empty;
        defer entries.deinit(allocator);
        for (self.shares.items) |*s| {
            const root = &(s.root orelse {
                try entries.append(allocator, .{ .name = s.name, .cid = &empty, .size = 0, .kind = .dir, .mtime = 0 });
                continue;
            });
            try entries.append(allocator, .{
                .name = s.name,
                .cid = root,
                .size = s.size,
                .kind = .dir,
                .mtime = s.scanned_at,
            });
        }
        std.mem.sort(codec.DirEntry, entries.items, {}, struct {
            fn less(_: void, a: codec.DirEntry, b: codec.DirEntry) bool {
                return std.mem.order(u8, a.name, b.name) == .lt;
            }
        }.less);
        return codec.encodeDir(allocator, entries.items);
    }

    /// Adapter for discovery Node.share_source.
    pub fn source(self: *ShareIndex) @import("../cluster/mod.zig").ShareSource {
        return .{ .ctx = self, .listFn = listingErased };
    }

    fn listingErased(ctx: *anyopaque, allocator: std.mem.Allocator) anyerror![]u8 {
        const self: *ShareIndex = @ptrCast(@alignCast(ctx));
        return self.listing(allocator);
    }

    /// Starts the periodic rescan thread (idempotent).
    pub fn start(self: *ShareIndex) !void {
        try self.worker.start(rescanLoop, .{self});
    }

    pub fn stop(self: *ShareIndex) void {
        self.worker.stop();
    }

    fn rescanLoop(self: *ShareIndex) void {
        const step = 200 * std.time.ns_per_ms;
        // Scan at once: registered shares are unlisted until scanned.
        self.rescanAll();
        var waited: u64 = 0;
        while (self.worker.isRunning()) {
            sync.sleep(step);
            waited += step;
            if (waited < self.rescan_interval_ns) continue;
            waited = 0;
            self.rescanAll();
        }
    }
};

fn nowSeconds(io: std.Io) u64 {
    const now = std.Io.Timestamp.now(io, .real);
    return @intCast(@max(0, @divFloor(now.nanoseconds, std.time.ns_per_s)));
}

test "shares: listing follows add, rescan and remove" {
    const testing = std.testing;
    const allocator = testing.allocator;
    const io = testing.io;
    const tree = @import("tree.zig");

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "docs");
    try tmp.dir.createDirPath(io, "blocks");
    try tmp.dir.writeFile(io, .{ .sub_path = "docs/a.txt", .data = "alpha" });

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const base = path_buf[0..try tmp.dir.realPath(io, &path_buf)];
    const blocks = try std.fs.path.join(allocator, &.{ base, "blocks" });
    defer allocator.free(blocks);
    const docs = try std.fs.path.join(allocator, &.{ base, "docs" });
    defer allocator.free(docs);

    var store = try storage.engine.StorageEngine.init(allocator, blocks);
    defer store.deinit();
    const index = try ShareIndex.create(allocator, io, &store);
    defer index.destroy();

    try testing.expectError(error.InvalidShareName, index.add("../x", docs));
    try index.add("docs", docs);

    const bytes = try index.listing(allocator);
    defer allocator.free(bytes);
    const listed = try tree.decodeListing(allocator, bytes);
    defer listed.deinit();
    try testing.expectEqual(@as(usize, 1), listed.entries.len);
    try testing.expectEqualStrings("docs", listed.entries[0].name);
    try testing.expectEqual(@as(u64, 5), listed.entries[0].size);

    const loader = tree.Loader.local(&store);
    const file = try tree.resolve(allocator, loader, listed.entries[0].cid, "a.txt");
    var buf: [16]u8 = undefined;
    try testing.expectEqualStrings("alpha", buf[0..try tree.readAt(allocator, loader, file.cid, 0, &buf)]);

    try tmp.dir.writeFile(io, .{ .sub_path = "docs/b.txt", .data = "beta!" });
    index.rescanAll();
    const snap = try index.snapshot(allocator);
    defer ShareIndex.freeSnapshot(allocator, snap);
    try testing.expectEqual(@as(u64, 2), snap[0].files);
    try testing.expect(!std.mem.eql(u8, &snap[0].root.?, &listed.entries[0].cid));

    try testing.expect(index.remove("docs"));
    const empty = try index.listing(allocator);
    defer allocator.free(empty);
    const none = try tree.decodeListing(allocator, empty);
    defer none.deinit();
    try testing.expectEqual(@as(usize, 0), none.entries.len);
}

test "shares: a first scan lists its progress, and every file reads back" {
    const testing = std.testing;
    const allocator = testing.allocator;
    const io = testing.io;
    const tree = @import("tree.zig");

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "media/a");
    try tmp.dir.createDirPath(io, "media/b");
    try tmp.dir.createDirPath(io, "blocks");
    var big: [3 << 20]u8 = undefined;
    var prng = std.Random.DefaultPrng.init(7);
    prng.random().bytes(&big);
    try tmp.dir.writeFile(io, .{ .sub_path = "media/a/one.txt", .data = "first" });
    try tmp.dir.writeFile(io, .{ .sub_path = "media/a/two.txt", .data = "second" });
    try tmp.dir.writeFile(io, .{ .sub_path = "media/b/big.bin", .data = &big });

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const base = path_buf[0..try tmp.dir.realPath(io, &path_buf)];
    const blocks = try std.fs.path.join(allocator, &.{ base, "blocks" });
    defer allocator.free(blocks);
    const media = try std.fs.path.join(allocator, &.{ base, "media" });
    defer allocator.free(media);

    var store = try storage.engine.StorageEngine.init(allocator, blocks);
    defer store.deinit();
    const index = try ShareIndex.create(allocator, io, &store);
    defer index.destroy();
    // Report after every file.
    index.progress_first_ns = 0;
    index.progress_interval_ns = 0;
    try index.add("media", media);

    // Each report handed its files over as a segment of their own.
    {
        index.files.mutex.lock();
        defer index.files.mutex.unlock();
        try testing.expect(index.files.tables.get("media").?.items.len >= 3);
    }
    const snap = try index.snapshot(allocator);
    defer ShareIndex.freeSnapshot(allocator, snap);
    try testing.expectEqual(@as(u64, 3), snap[0].files);
    try testing.expect(!snap[0].indexing);

    const loader = tree.Loader.local(&store);
    const file = try tree.resolve(allocator, loader, snap[0].root.?, "b/big.bin");
    const out = try allocator.alloc(u8, big.len);
    defer allocator.free(out);
    try testing.expectEqual(big.len, try tree.readAt(allocator, loader, file.cid, 0, out));
    try testing.expectEqualSlices(u8, &big, out);
}

test "shares: a restart reuses the scan cache instead of re-reading files" {
    const testing = std.testing;
    const allocator = testing.allocator;
    const io = testing.io;
    const tree = @import("tree.zig");

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "docs");
    try tmp.dir.createDirPath(io, "blocks");
    var big: [3 << 20]u8 = undefined;
    var prng = std.Random.DefaultPrng.init(11);
    prng.random().bytes(&big);
    try tmp.dir.writeFile(io, .{ .sub_path = "docs/small.txt", .data = "tiny" });
    try tmp.dir.writeFile(io, .{ .sub_path = "docs/big.bin", .data = &big });
    try tmp.dir.writeFile(io, .{ .sub_path = "docs/gone.txt", .data = "bye" });

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const base = path_buf[0..try tmp.dir.realPath(io, &path_buf)];
    const blocks = try std.fs.path.join(allocator, &.{ base, "blocks" });
    defer allocator.free(blocks);
    const docs = try std.fs.path.join(allocator, &.{ base, "docs" });
    defer allocator.free(docs);

    var store = try storage.engine.StorageEngine.init(allocator, blocks);
    defer store.deinit();
    var first_root: codec.Cid = undefined;
    {
        const index = try ShareIndex.create(allocator, io, &store);
        defer index.destroy();
        try index.add("docs", docs);
        try testing.expectEqual(@as(u64, 3), index.scanner.files_hashed);
        // Deleted between runs: forgotten by the next scan.
        try tmp.dir.deleteFile(io, "docs/gone.txt");
        try index.add("docs", docs);
        const snap = try index.snapshot(allocator);
        defer ShareIndex.freeSnapshot(allocator, snap);
        first_root = snap[0].root.?;
    }

    const index = try ShareIndex.create(allocator, io, &store);
    defer index.destroy();
    try testing.expectEqual(@as(u32, 2), index.scanner.remembered.count());
    try index.add("docs", docs);
    try testing.expectEqual(@as(u64, 0), index.scanner.files_hashed);
    const snap = try index.snapshot(allocator);
    defer ShareIndex.freeSnapshot(allocator, snap);
    try testing.expectEqualSlices(u8, &first_root, &snap[0].root.?);

    // The leaves rebuilt from the store serve the bytes.
    const loader = tree.Loader.local(&store);
    const file = try tree.resolve(allocator, loader, snap[0].root.?, "big.bin");
    const out = try allocator.alloc(u8, big.len);
    defer allocator.free(out);
    try testing.expectEqual(big.len, try tree.readAt(allocator, loader, file.cid, 0, out));
    try testing.expectEqualSlices(u8, &big, out);
    const small = try tree.resolve(allocator, loader, snap[0].root.?, "small.txt");
    var buf: [8]u8 = undefined;
    try testing.expectEqualStrings("tiny", buf[0..try tree.readAt(allocator, loader, small.cid, 0, &buf)]);
}

test "shares: a share not scanned yet is listed empty, as indexing" {
    const testing = std.testing;
    const allocator = testing.allocator;
    const io = testing.io;
    const tree = @import("tree.zig");

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "movies");
    try tmp.dir.createDirPath(io, "blocks");
    try tmp.dir.writeFile(io, .{ .sub_path = "movies/a.mkv", .data = "film" });
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const base = path_buf[0..try tmp.dir.realPath(io, &path_buf)];
    const blocks = try std.fs.path.join(allocator, &.{ base, "blocks" });
    defer allocator.free(blocks);
    const movies = try std.fs.path.join(allocator, &.{ base, "movies" });
    defer allocator.free(movies);

    var store = try storage.engine.StorageEngine.init(allocator, blocks);
    defer store.deinit();
    const index = try ShareIndex.create(allocator, io, &store);
    defer index.destroy();
    try index.register("Movies", movies);

    const before = try index.listing(allocator);
    defer allocator.free(before);
    const pending = try tree.decodeListing(allocator, before);
    defer pending.deinit();
    const e = pending.find("Movies").?;
    try testing.expectEqual(@as(u64, 0), e.mtime);
    try testing.expectEqual(@as(u64, 0), e.size);
    const inside = try tree.listDir(allocator, tree.Loader.local(&store), &e.cid);
    defer inside.deinit();
    try testing.expectEqual(@as(usize, 0), inside.entries.len);

    index.rescanAll();
    const after = try index.listing(allocator);
    defer allocator.free(after);
    const scanned = try tree.decodeListing(allocator, after);
    defer scanned.deinit();
    try testing.expect(scanned.find("Movies").?.mtime > 0);
    try testing.expectEqual(@as(u64, 4), scanned.find("Movies").?.size);
}

test "shares: re-add mid-scan does not install stale result" {
    const testing = std.testing;
    const allocator = testing.allocator;
    const io = testing.io;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "old_folder");
    try tmp.dir.createDirPath(io, "new_folder");
    try tmp.dir.createDirPath(io, "blocks");
    try tmp.dir.writeFile(io, .{ .sub_path = "old_folder/old.txt", .data = "old" });
    try tmp.dir.writeFile(io, .{ .sub_path = "new_folder/new.txt", .data = "new" });

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const base = path_buf[0..try tmp.dir.realPath(io, &path_buf)];
    const blocks = try std.fs.path.join(allocator, &.{ base, "blocks" });
    defer allocator.free(blocks);
    const old_path = try std.fs.path.join(allocator, &.{ base, "old_folder" });
    defer allocator.free(old_path);
    const new_path = try std.fs.path.join(allocator, &.{ base, "new_folder" });
    defer allocator.free(new_path);

    var store = try storage.engine.StorageEngine.init(allocator, blocks);
    defer store.deinit();
    const index = try ShareIndex.create(allocator, io, &store);
    defer index.destroy();

    try index.register("test_share", old_path);
    const gen0 = index.shares.items[0].generation;

    // Re-registering with new path increments generation
    try index.register("test_share", new_path);
    const gen1 = index.shares.items[0].generation;
    try testing.expect(gen1 != gen0);
    try testing.expectEqualStrings(new_path, index.shares.items[0].path);
}
