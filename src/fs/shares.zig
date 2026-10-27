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
    /// Null until the first scan finishes; unscanned shares are not listed.
    root: ?codec.Cid = null,
    size: u64 = 0,
    files: u64 = 0,
    scanned_at: u64 = 0,
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
    running: std.atomic.Value(bool) = .init(false),
    thread: ?std.Thread = null,

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
        return self;
    }

    pub fn destroy(self: *ShareIndex) void {
        self.stop();
        self.store.external = null;
        for (self.shares.items) |s| freeShare(self.allocator, s);
        self.shares.deinit(self.allocator);
        self.scanner.deinit();
        self.files.deinit();
        self.allocator.destroy(self);
    }

    fn freeShare(allocator: std.mem.Allocator, s: Share) void {
        allocator.free(s.name);
        allocator.free(s.path);
    }

    /// Shares `path` as `name`, replacing any share of that name. The
    /// folder is scanned before this returns, so it is listed right away.
    pub fn add(self: *ShareIndex, name: []const u8, path: []const u8) !void {
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
                freeShare(self.allocator, self.shares.items[at.index]);
                self.shares.items[at.index] = .{ .name = owned_name, .path = owned_path };
            } else {
                try self.shares.insert(self.allocator, at.index, .{ .name = owned_name, .path = owned_path });
            }
        }
        self.rescanOne(name);
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
    fn indexOf(self: *ShareIndex, name: []const u8) Position {
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

        const path = blk: {
            self.mutex.lock();
            defer self.mutex.unlock();
            const at = self.indexOf(name);
            if (!at.found) return;
            break :blk self.allocator.dupe(u8, self.shares.items[at.index].path) catch return;
        };
        defer self.allocator.free(path);

        const table = self.allocator.create(filestore.Table) catch return;
        table.* = filestore.Table.init(self.allocator);
        var installed = false;
        defer if (!installed) {
            table.deinit();
            self.allocator.destroy(table);
        };
        self.scanner.table = table;
        defer self.scanner.table = null;
        const result = self.scanner.scan(path) catch |err| {
            std.debug.print("share '{s}': scan of {s} failed: {any}\n", .{ name, path, err });
            return;
        };

        self.mutex.lock();
        defer self.mutex.unlock();
        const at = self.indexOf(name);
        if (!at.found) return; // removed while scanning
        self.files.replace(name, table) catch return;
        installed = true;
        const share = &self.shares.items[at.index];
        share.root = result.root;
        share.size = result.size;
        share.files = result.files;
        share.scanned_at = nowSeconds(self.io);
    }

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

    /// The GET_SHARES reply: a dir block of the scanned shares.
    pub fn listing(self: *ShareIndex, allocator: std.mem.Allocator) ![]u8 {
        self.mutex.lock();
        defer self.mutex.unlock();
        var entries: std.ArrayList(codec.DirEntry) = .empty;
        defer entries.deinit(allocator);
        for (self.shares.items) |*s| {
            const root = &(s.root orelse continue);
            try entries.append(allocator, .{
                .name = s.name,
                .cid = root,
                .size = s.size,
                .kind = .dir,
                .mtime = s.scanned_at,
            });
        }
        return codec.encodeDir(allocator, entries.items);
    }

    /// Adapter for discovery Node.share_source.
    pub fn source(self: *ShareIndex) @import("../net/discovery/node.zig").Node.ShareSource {
        return .{ .ctx = self, .listFn = listingErased };
    }

    fn listingErased(ctx: *anyopaque, allocator: std.mem.Allocator) anyerror![]u8 {
        const self: *ShareIndex = @ptrCast(@alignCast(ctx));
        return self.listing(allocator);
    }

    /// Starts the periodic rescan thread (idempotent).
    pub fn start(self: *ShareIndex) !void {
        if (self.running.swap(true, .acq_rel)) return;
        self.thread = std.Thread.spawn(.{}, rescanLoop, .{self}) catch |err| {
            self.running.store(false, .release);
            return err;
        };
    }

    pub fn stop(self: *ShareIndex) void {
        if (!self.running.swap(false, .acq_rel)) return;
        if (self.thread) |t| t.join();
        self.thread = null;
    }

    fn rescanLoop(self: *ShareIndex) void {
        const step = 200 * std.time.ns_per_ms;
        var waited: u64 = 0;
        while (self.running.load(.acquire)) {
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
