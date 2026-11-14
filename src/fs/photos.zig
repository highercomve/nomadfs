//! The photos timeline: every picture and film in the swarm folder, newest
//! first, whatever folder it is in. Built from the manifest alone (names,
//! times, content IDs; no file is read), kept until the folder changes, and
//! handed out as an index (how many, their times, the folders they are in)
//! and pages of items. Every front end shows this one timeline (the node's
//! `photosIndex` and `photosPage`), encoded once (`indexJson`, `pageJson`).

const std = @import("std");
const sync = @import("../sync.zig");
const media = @import("media.zig");
const swarm_mod = @import("swarm.zig");

const SwarmFolder = swarm_mod.SwarmFolder;

/// The most items one page holds.
pub const max_page = 500;
/// The most folders an index lists (the first ones by path).
pub const max_folders = 1024;
/// Folders are counted down to this depth ("Pixel 8", "Pixel 8/Camera").
pub const folder_depth = 2;
/// The most files a timeline holds: ten times what a manifest takes.
const max_files = 1 << 20;

/// Which kinds a view shows. Photos include HEIC and camera RAW.
pub const KindSet = enum {
    all,
    photos,
    videos,

    pub fn has(self: KindSet, kind: media.Kind) bool {
        return switch (self) {
            .all => kind.isMedia(),
            .photos => kind == .photo or kind == .heic or kind == .raw,
            .videos => kind == .video,
        };
    }

    /// "all", "photos" or "videos"; null for anything else.
    pub fn parse(text: []const u8) ?KindSet {
        return std.meta.stringToEnum(KindSet, text);
    }
};

/// What is known of an item's thumbnail without asking for it.
pub const ThumbHint = enum { ready, none, unknown };

/// Who knows that of a file, by its content ID (thumbs.zig). Asked for
/// each item of a page: it must be cheap, and call nothing here.
pub const ThumbHints = struct {
    ctx: *anyopaque,
    hintFn: *const fn (ctx: *anyopaque, cid: *const [32]u8) ThumbHint,
};

pub const Filter = struct {
    /// Only what is below this folder ("" for everything).
    folder: []const u8 = "",
    kinds: KindSet = .all,
    /// The same content at several paths shows once: the newest, then the
    /// first by path, among what the rest of the filter leaves.
    dedupe: bool = true,
};

pub const FolderCount = struct { path: []const u8, count: u32 };

/// A view as a whole. The fields are in the order of the JSON.
pub const Index = struct {
    generation: u64,
    total: u32,
    photos: u32,
    videos: u32,
    /// Every item's modified time (seconds), in the view's order.
    mtimes: []const u64,
    /// The folders the view's items are in, down to `folder_depth`, by
    /// path; an item counts in each folder above it.
    folders: []const FolderCount,
};

pub const Item = struct {
    /// Its place in the view.
    index: u32,
    path: []const u8,
    /// The file name: the end of `path`.
    name: []const u8,
    cid: [32]u8,
    /// The device that wrote this version (whom a read asks first).
    author: [32]u8,
    size: u64,
    mtime: u64,
    kind: media.Kind,
    thumb: ThumbHint,
};

pub const Page = struct {
    generation: u64,
    /// How many items the whole view has.
    total: u32,
    items: []const Item,
};

pub const Timeline = struct {
    allocator: std.mem.Allocator,
    folder: *SwarmFolder,
    /// Guards everything below. Taken before the folder's lock, never
    /// inside it.
    mutex: sync.Mutex = .{},
    /// The folder's change generation `files` was built from; 0: not yet.
    built: u64 = 0,
    /// Every media file, newest first then by path. Owned; the paths are
    /// in `strings`.
    files: []File = &.{},
    strings: std.heap.ArenaAllocator,
    /// The view asked for last (one front end pages through one filter).
    view: View = .{},
    /// Fills the items' `thumb`; null: every one is `unknown`. Set once,
    /// before the first `page`, by whoever owns both; it outlives this.
    thumb_hints: ?ThumbHints = null,

    const File = struct {
        path: []const u8,
        cid: [32]u8,
        author: [32]u8,
        size: u64,
        /// When it was taken (`media.takenTime`): the modified time, or the
        /// date in its name when a copy stamped the file on arrival.
        mtime: u64,
        kind: media.Kind,
    };

    /// A filter applied to `files`: the indices it leaves, in order.
    const View = struct {
        valid: bool = false,
        /// Owned.
        folder: []u8 = &.{},
        kinds: KindSet = .all,
        dedupe: bool = true,
        /// Owned.
        rows: []u32 = &.{},
        photos: u32 = 0,
        videos: u32 = 0,

        fn matches(self: *const View, folder: []const u8, filter: Filter) bool {
            return self.valid and self.kinds == filter.kinds and self.dedupe == filter.dedupe and std.mem.eql(u8, self.folder, folder);
        }

        fn clear(self: *View, allocator: std.mem.Allocator) void {
            allocator.free(self.folder);
            allocator.free(self.rows);
            self.* = .{};
        }
    };

    /// A timeline over `folder`, which outlives it. Nothing is read until
    /// the first `index` or `page`.
    pub fn create(allocator: std.mem.Allocator, folder: *SwarmFolder) !*Timeline {
        const self = try allocator.create(Timeline);
        self.* = .{ .allocator = allocator, .folder = folder, .strings = .init(allocator) };
        return self;
    }

    pub fn destroy(self: *Timeline) void {
        self.view.clear(self.allocator);
        self.allocator.free(self.files);
        self.strings.deinit();
        self.allocator.destroy(self);
    }

    /// The view `filter` leaves, as it is now. Allocated in `arena`.
    pub fn index(self: *Timeline, arena: std.mem.Allocator, filter: Filter) !Index {
        self.mutex.lock();
        defer self.mutex.unlock();
        try self.refreshLocked();
        const view = try self.viewLocked(filter);
        const mtimes = try arena.alloc(u64, view.rows.len);
        for (view.rows, mtimes) |row, *m| m.* = self.files[row].mtime;
        return .{
            .generation = self.built,
            .total = @intCast(view.rows.len), // rows.len <= max_files
            .photos = view.photos,
            .videos = view.videos,
            .mtimes = mtimes,
            .folders = try self.foldersLocked(arena, view),
        };
    }

    /// Up to `count` items (`max_page` at most) of the view from `start`;
    /// none past its end. `generation`: the one an index gave, so the page
    /// is of the view that index described (error.Stale once the folder
    /// changed: ask for the index again); 0 takes the view as it is now.
    /// Allocated in `arena`.
    pub fn page(self: *Timeline, arena: std.mem.Allocator, generation: u64, filter: Filter, start: u32, count: u32) !Page {
        var found: Page = undefined;
        const items = try self.itemsOf(arena, generation, filter, start, count, &found);
        // Outside the lock: a few stats per item.
        if (self.thumb_hints) |hints| for (items) |*item| {
            item.thumb = hints.hintFn(hints.ctx, &item.cid);
        };
        return found;
    }

    /// Sets `out` to the page, its items' thumbnails all `unknown`, and
    /// returns those items for `page` to fill them in.
    fn itemsOf(self: *Timeline, arena: std.mem.Allocator, generation: u64, filter: Filter, start: u32, count: u32, out: *Page) ![]Item {
        self.mutex.lock();
        defer self.mutex.unlock();
        try self.refreshLocked();
        if (generation != 0 and generation != self.built) return error.Stale;
        const view = try self.viewLocked(filter);
        const total: u32 = @intCast(view.rows.len); // rows.len <= max_files
        const from = @min(start, total);
        const n = @min(@min(count, max_page), total - from);
        const items = try arena.alloc(Item, n);
        for (view.rows[from..][0..n], items, from..) |row, *item, i| {
            const f = self.files[row];
            const path = try arena.dupe(u8, f.path);
            item.* = .{
                .index = @intCast(i), // i < total
                .path = path,
                .name = SwarmFolder.splitParent(path).name,
                .cid = f.cid,
                .author = f.author,
                .size = f.size,
                .mtime = f.mtime,
                .kind = f.kind,
                .thumb = .unknown,
            };
        }
        out.* = .{ .generation = self.built, .total = total, .items = items };
        return items;
    }

    /// Caller holds `mutex`. Reads the folder again if it changed since
    /// `files` was built; on a failure the old timeline stays.
    fn refreshLocked(self: *Timeline) !void {
        if (self.built == self.folder.changeGeneration()) return;
        var collect = Collect{ .allocator = self.allocator, .strings = .init(self.allocator) };
        errdefer collect.strings.deinit();
        errdefer collect.files.deinit(self.allocator);
        const generation = try self.folder.eachLiveFile(&collect, Collect.add);
        try dropRawTwins(self.allocator, &collect.files);
        const files = try collect.files.toOwnedSlice(self.allocator);
        std.mem.sort(File, files, {}, newerFirst);

        self.view.clear(self.allocator);
        self.allocator.free(self.files);
        self.strings.deinit();
        self.files = files;
        self.strings = collect.strings;
        self.built = generation;
    }

    /// The folder's pass (under its lock): keeps the media files.
    const Collect = struct {
        allocator: std.mem.Allocator,
        strings: std.heap.ArenaAllocator,
        files: std.ArrayList(File) = .empty,

        fn add(self: *Collect, e: *const swarm_mod.Entry) std.mem.Allocator.Error!void {
            const kind = media.kindOfName(e.path);
            if (!kind.isMedia() or hidden(e.path)) return;
            if (self.files.items.len >= max_files) return;
            try self.files.append(self.allocator, .{
                .path = try self.strings.allocator().dupe(u8, e.path),
                .cid = e.cid,
                .author = e.version.device,
                .size = e.size,
                .mtime = media.takenTime(e.path, e.mtime),
                .kind = kind,
            });
        }
    };

    /// A camera that shoots RAW+JPEG saves one shot twice
    /// (`PXL_…RAW-01.MP.jpg` and `PXL_…RAW-02.ORIGINAL.dng`, `IMG_1.JPG` and
    /// `IMG_1.CR2`): the RAW file is left out when a photo of the same
    /// shot, the same folder and name up to the first dot, is there.
    fn dropRawTwins(allocator: std.mem.Allocator, files: *std.ArrayList(File)) !void {
        var shots: std.StringHashMapUnmanaged(void) = .empty;
        defer shots.deinit(allocator);
        for (files.items) |f| {
            if (f.kind == .photo) try shots.put(allocator, shotKey(f.path), {});
        }
        var kept: usize = 0;
        for (files.items) |f| {
            if (f.kind == .raw and shots.contains(shotKey(f.path))) continue;
            files.items[kept] = f;
            kept += 1;
        }
        files.shrinkRetainingCapacity(kept);
    }

    /// The folder and the file name up to its first dot.
    fn shotKey(path: []const u8) []const u8 {
        const name_at = if (std.mem.lastIndexOfScalar(u8, path, '/')) |slash| slash + 1 else 0;
        const dot = std.mem.indexOfScalarPos(u8, path, name_at, '.') orelse return path;
        return path[0..dot];
    }

    fn newerFirst(_: void, a: File, b: File) bool {
        if (a.mtime != b.mtime) return a.mtime > b.mtime;
        return std.mem.order(u8, a.path, b.path) == .lt;
    }

    /// Caller holds `mutex`, after `refreshLocked`. The view for `filter`:
    /// the last one when the filter is the same, else built now.
    fn viewLocked(self: *Timeline, filter: Filter) !*const View {
        const folder = std.mem.trim(u8, filter.folder, "/");
        if (self.view.matches(folder, filter)) return &self.view;

        var rows: std.ArrayList(u32) = .empty;
        errdefer rows.deinit(self.allocator);
        var seen: std.AutoHashMapUnmanaged([32]u8, void) = .empty;
        defer seen.deinit(self.allocator);
        var photos: u32 = 0;
        var videos: u32 = 0;
        for (self.files, 0..) |f, i| {
            if (!filter.kinds.has(f.kind) or !below(f.path, folder)) continue;
            if (filter.dedupe) {
                const entry = try seen.getOrPut(self.allocator, f.cid);
                if (entry.found_existing) continue;
            }
            try rows.append(self.allocator, @intCast(i)); // i < max_files
            if (f.kind == .video) videos += 1 else photos += 1;
        }
        const owned_folder = try self.allocator.dupe(u8, folder);
        errdefer self.allocator.free(owned_folder);
        const owned_rows = try rows.toOwnedSlice(self.allocator);

        self.view.clear(self.allocator);
        self.view = .{ .valid = true, .folder = owned_folder, .kinds = filter.kinds, .dedupe = filter.dedupe, .rows = owned_rows, .photos = photos, .videos = videos };
        return &self.view;
    }

    /// Caller holds `mutex`. How many of the view's items each folder
    /// holds, down to `folder_depth`, by path. Allocated in `arena`.
    fn foldersLocked(self: *Timeline, arena: std.mem.Allocator, view: *const View) ![]const FolderCount {
        var counts: std.StringArrayHashMapUnmanaged(u32) = .empty;
        for (view.rows) |row| {
            const path = self.files[row].path;
            var end: usize = 0;
            for (0..folder_depth) |_| {
                const slash = std.mem.indexOfScalarPos(u8, path, end, '/') orelse break;
                const entry = try counts.getOrPut(arena, path[0..slash]);
                if (!entry.found_existing) entry.value_ptr.* = 0;
                entry.value_ptr.* += 1;
                end = slash + 1;
            }
        }
        const out = try arena.alloc(FolderCount, counts.count());
        // The keys point into `strings`: copied, the caller reads them
        // after the lock.
        for (counts.keys(), counts.values(), out) |path, count, *o| o.* = .{ .path = try arena.dupe(u8, path), .count = count };
        std.mem.sort(FolderCount, out, {}, struct {
            fn before(_: void, a: FolderCount, b: FolderCount) bool {
                return std.mem.order(u8, a.path, b.path) == .lt;
            }
        }.before);
        return out[0..@min(out.len, max_folders)];
    }
};

/// A file or one of its folders starts with a dot: Android's
/// `.trashed-…` and `.pending-…` files, `.thumbnails` folders.
fn hidden(path: []const u8) bool {
    return path.len > 0 and (path[0] == '.' or std.mem.indexOf(u8, path, "/.") != null);
}

/// Whether `path` is below `folder` ("" holds everything).
fn below(path: []const u8, folder: []const u8) bool {
    if (folder.len == 0) return true;
    return path.len > folder.len and path[folder.len] == '/' and std.mem.startsWith(u8, path, folder);
}

/// An index as every front end sends it:
/// `{"generation","total","photos","videos","mtimes":[…],"folders":[{"path","count"}]}`.
pub fn indexJson(arena: std.mem.Allocator, value: Index) ![]u8 {
    return std.json.Stringify.valueAlloc(arena, value, .{});
}

/// A page as every front end sends it: `{"generation","total","items":[…]}`,
/// an item being `{"index","path","name","cid","author","size","mtime",
/// "kind","thumb"}` with the IDs in hex.
pub const WirePage = struct {
    generation: u64,
    total: u32,
    items: []const WireItem,
};
pub const WireItem = struct {
    index: u32,
    path: []const u8,
    name: []const u8,
    cid: [64]u8,
    author: [64]u8,
    size: u64,
    mtime: u64,
    kind: []const u8,
    thumb: []const u8,
};

/// `value` in the shape front ends send (IDs as hex); allocated in `arena`.
pub fn wirePage(arena: std.mem.Allocator, value: Page) !WirePage {
    const items = try arena.alloc(WireItem, value.items.len);
    for (value.items, items) |it, *w| w.* = .{
        .index = it.index,
        .path = it.path,
        .name = it.name,
        .cid = std.fmt.bytesToHex(it.cid, .lower),
        .author = std.fmt.bytesToHex(it.author, .lower),
        .size = it.size,
        .mtime = it.mtime,
        .kind = @tagName(it.kind),
        .thumb = @tagName(it.thumb),
    };
    return .{ .generation = value.generation, .total = value.total, .items = items };
}

pub fn pageJson(arena: std.mem.Allocator, value: Page) ![]u8 {
    return std.json.Stringify.valueAlloc(arena, try wirePage(arena, value), .{});
}

const testing = std.testing;
const TestFolder = @import("test_fixture.zig").Fixture(SwarmFolder);

/// A file with `bytes` at `path`, modified at `mtime`.
fn put(folder: *SwarmFolder, path: []const u8, bytes: []const u8, mtime: u64) !void {
    _ = try folder.putBytes(path, bytes, null);
    try folder.setMtime(path, mtime);
}

/// A folder with five media files in two devices' folders, one twice.
fn fill(folder: *SwarmFolder) !void {
    try put(folder, "Pixel 8/Camera/b.jpg", "b", 300);
    try put(folder, "Pixel 8/Camera/a.jpg", "a", 300);
    try put(folder, "Pixel 8/Camera/clip.MP4", "clip", 400);
    try put(folder, "Pixel 8/Camera/.trashed-x.jpg", "gone", 900);
    try put(folder, "Pixel 8/.thumbnails/t.jpg", "thumb", 900);
    try put(folder, "Pixel 8/notes.md", "text", 900);
    try put(folder, "Laptop/Pictures/2024/old.heic", "old", 100);
    try put(folder, "Laptop/copy of a.jpg", "a", 200);
    try put(folder, "top.png", "top", 500);
}

fn expectPaths(want: []const []const u8, got: []const Item) !void {
    try testing.expectEqual(want.len, got.len);
    for (want, got) |w, g| try testing.expectEqualStrings(w, g.path);
}

test "photos: newest first then by path, hidden files and other kinds left out" {
    var t: TestFolder = undefined;
    try t.open(0x51, "Desk");
    defer t.close();
    try fill(t.folder);
    const timeline = try Timeline.create(testing.allocator, t.folder);
    defer timeline.destroy();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const all = try timeline.page(arena, 0, .{ .dedupe = false }, 0, 100);
    try expectPaths(&.{ "top.png", "Pixel 8/Camera/clip.MP4", "Pixel 8/Camera/a.jpg", "Pixel 8/Camera/b.jpg", "Laptop/copy of a.jpg", "Laptop/Pictures/2024/old.heic" }, all.items);
    try testing.expectEqual(@as(u32, 6), all.total);
    for (all.items, 0..) |item, i| {
        try testing.expectEqual(i, @as(usize, item.index));
        try testing.expectEqual(ThumbHint.unknown, item.thumb);
        try testing.expectEqualSlices(u8, &([_]u8{0x51} ** 32), &item.author);
    }
    const clip = all.items[1];
    try testing.expectEqualStrings("clip.MP4", clip.name);
    try testing.expectEqual(media.Kind.video, clip.kind);
    try testing.expectEqual(@as(u64, 4), clip.size);
    try testing.expectEqual(@as(u64, 400), clip.mtime);
    try testing.expectEqualSlices(u8, &t.folder.fileInfo("Pixel 8/Camera/clip.MP4").?.cid, &clip.cid);
    try testing.expectEqual(media.Kind.heic, all.items[5].kind);
}

test "photos: the same content at two paths shows once, the newest" {
    var t: TestFolder = undefined;
    try t.open(0x52, "Desk");
    defer t.close();
    try fill(t.folder);
    const timeline = try Timeline.create(testing.allocator, t.folder);
    defer timeline.destroy();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const once = try timeline.page(arena, 0, .{}, 0, 100);
    try expectPaths(&.{ "top.png", "Pixel 8/Camera/clip.MP4", "Pixel 8/Camera/a.jpg", "Pixel 8/Camera/b.jpg", "Laptop/Pictures/2024/old.heic" }, once.items);
    // In its own folder the copy is the only one, so it shows.
    const laptop = try timeline.page(arena, 0, .{ .folder = "Laptop" }, 0, 100);
    try expectPaths(&.{ "Laptop/copy of a.jpg", "Laptop/Pictures/2024/old.heic" }, laptop.items);
}

test "photos: folder and kind filters, the index and its folder counts" {
    var t: TestFolder = undefined;
    try t.open(0x53, "Desk");
    defer t.close();
    try fill(t.folder);
    const timeline = try Timeline.create(testing.allocator, t.folder);
    defer timeline.destroy();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const whole = try timeline.index(arena, .{});
    try testing.expectEqual(@as(u32, 5), whole.total);
    try testing.expectEqual(@as(u32, 4), whole.photos);
    try testing.expectEqual(@as(u32, 1), whole.videos);
    try testing.expectEqualSlices(u64, &.{ 500, 400, 300, 300, 100 }, whole.mtimes);
    try testing.expectEqual(t.folder.changeGeneration(), whole.generation);
    // Down to two levels; "Laptop/Pictures/2024" counts in the two above it.
    const want = [_]FolderCount{
        .{ .path = "Laptop", .count = 1 },
        .{ .path = "Laptop/Pictures", .count = 1 },
        .{ .path = "Pixel 8", .count = 3 },
        .{ .path = "Pixel 8/Camera", .count = 3 },
    };
    try testing.expectEqual(want.len, whole.folders.len);
    for (want, whole.folders) |w, g| {
        try testing.expectEqualStrings(w.path, g.path);
        try testing.expectEqual(w.count, g.count);
    }

    // A folder, with or without slashes around it; not a name's prefix.
    const camera = try timeline.page(arena, whole.generation, .{ .folder = "/Pixel 8/Camera/" }, 0, 100);
    try expectPaths(&.{ "Pixel 8/Camera/clip.MP4", "Pixel 8/Camera/a.jpg", "Pixel 8/Camera/b.jpg" }, camera.items);
    try testing.expectEqual(@as(u32, 0), (try timeline.index(arena, .{ .folder = "Pixel" })).total);

    const videos = try timeline.index(arena, .{ .kinds = .videos });
    try testing.expectEqual(@as(u32, 1), videos.total);
    try testing.expectEqual(@as(u32, 0), videos.photos);
    const photos = try timeline.page(arena, 0, .{ .kinds = .photos, .folder = "Pixel 8" }, 0, 100);
    try expectPaths(&.{ "Pixel 8/Camera/a.jpg", "Pixel 8/Camera/b.jpg" }, photos.items);
}

test "photos: pages cut the view, and past its end there is nothing" {
    var t: TestFolder = undefined;
    try t.open(0x54, "Desk");
    defer t.close();
    try fill(t.folder);
    const timeline = try Timeline.create(testing.allocator, t.folder);
    defer timeline.destroy();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const second = try timeline.page(arena, 0, .{}, 2, 2);
    try expectPaths(&.{ "Pixel 8/Camera/a.jpg", "Pixel 8/Camera/b.jpg" }, second.items);
    try testing.expectEqual(@as(u32, 2), second.items[0].index);
    try testing.expectEqual(@as(u32, 5), second.total);
    const last = try timeline.page(arena, 0, .{}, 4, 100);
    try expectPaths(&.{"Laptop/Pictures/2024/old.heic"}, last.items);
    try testing.expectEqual(@as(usize, 0), (try timeline.page(arena, 0, .{}, 5, 10)).items.len);
    try testing.expectEqual(@as(usize, 0), (try timeline.page(arena, 0, .{}, std.math.maxInt(u32), std.math.maxInt(u32))).items.len);
    try testing.expectEqual(@as(usize, 0), (try timeline.page(arena, 0, .{}, 0, 0)).items.len);
}

test "photos: a page holds max_page items at most" {
    var t: TestFolder = undefined;
    try t.open(0x55, "Desk");
    defer t.close();
    var name_buf: [32]u8 = undefined;
    for (0..max_page + 3) |i| {
        const name = try std.fmt.bufPrint(&name_buf, "p/{d:0>4}.jpg", .{i});
        _ = try t.folder.putBytes(name, name, null);
    }
    const timeline = try Timeline.create(testing.allocator, t.folder);
    defer timeline.destroy();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();

    const page = try timeline.page(arena_state.allocator(), 0, .{}, 0, 10_000);
    try testing.expectEqual(@as(usize, max_page), page.items.len);
    try testing.expectEqual(@as(u32, max_page + 3), page.total);
}

test "photos: an edit moves the generation, and a page of the old one is stale" {
    var t: TestFolder = undefined;
    try t.open(0x56, "Desk");
    defer t.close();
    try fill(t.folder);
    const timeline = try Timeline.create(testing.allocator, t.folder);
    defer timeline.destroy();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const before = try timeline.index(arena, .{});
    // Unchanged: the same generation, and its pages are served.
    try testing.expectEqual(before.generation, (try timeline.index(arena, .{})).generation);
    _ = try timeline.page(arena, before.generation, .{}, 0, 10);

    try put(t.folder, "new.jpg", "new", 1000);
    try testing.expectError(error.Stale, timeline.page(arena, before.generation, .{}, 0, 10));
    const after = try timeline.index(arena, .{});
    try testing.expect(after.generation != before.generation);
    try testing.expectEqual(before.total + 1, after.total);
    const page = try timeline.page(arena, after.generation, .{}, 0, 1);
    try expectPaths(&.{"new.jpg"}, page.items);

    // A removal too.
    try t.folder.remove("new.jpg");
    try testing.expectError(error.Stale, timeline.page(arena, after.generation, .{}, 0, 1));
    try testing.expectEqual(before.total, (try timeline.index(arena, .{})).total);
}

test "photos: the JSON every front end sends" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const index = Index{
        .generation = 7,
        .total = 2,
        .photos = 1,
        .videos = 1,
        .mtimes = &.{ 1700000000, 1600000000 },
        .folders = &.{.{ .path = "Google Pixel 8", .count = 2 }},
    };
    try testing.expectEqualStrings(
        \\{"generation":7,"total":2,"photos":1,"videos":1,"mtimes":[1700000000,1600000000],"folders":[{"path":"Google Pixel 8","count":2}]}
    , try indexJson(arena, index));

    const page = Page{ .generation = 7, .total = 2, .items = &.{.{
        .index = 1,
        .path = "Google Pixel 8/a \"b\".mp4",
        .name = "a \"b\".mp4",
        .cid = @splat(0xab),
        .author = @splat(0x01),
        .size = 12,
        .mtime = 1600000000,
        .kind = .video,
        .thumb = .unknown,
    }} };
    try testing.expectEqualStrings(
        \\{"generation":7,"total":2,"items":[{"index":1,"path":"Google Pixel 8/a \"b\".mp4","name":"a \"b\".mp4","cid":"
    ++ "ab" ** 32 ++
        \\","author":"
    ++ "01" ** 32 ++
        \\","size":12,"mtime":1600000000,"kind":"video","thumb":"unknown"}]}
    , try pageJson(arena, page));
    try testing.expectEqualStrings(
        \\{"generation":3,"total":0,"items":[]}
    , try pageJson(arena, .{ .generation = 3, .total = 0, .items = &.{} }));
}

test hidden {
    try testing.expect(hidden(".trashed-1.jpg"));
    try testing.expect(hidden("DCIM/.pending-2.jpg"));
    try testing.expect(hidden("DCIM/.thumbnails/3.jpg"));
    try testing.expect(!hidden("DCIM/a.b.jpg"));
    try testing.expect(!hidden("a/b.jpg"));
}

test "KindSet.parse" {
    try testing.expectEqual(KindSet.videos, KindSet.parse("videos").?);
    try testing.expectEqual(KindSet.all, KindSet.parse("all").?);
    try testing.expect(KindSet.parse("films") == null);
}

test "photos: a RAW+JPEG shot shows once" {
    var t: TestFolder = undefined;
    try t.open(0x52, "Desk");
    defer t.close();
    const folder = t.folder;
    try put(folder, "P/Camera/PXL_1.RAW-01.MP.jpg", "jpg", 500);
    try put(folder, "P/Camera/PXL_1.RAW-02.ORIGINAL.dng", "dng", 500);
    try put(folder, "P/Camera/IMG_2.dng", "lone raw", 400);
    try put(folder, "P/Other/PXL_1.RAW-02.ORIGINAL.dng", "other folder", 300);
    const timeline = try Timeline.create(testing.allocator, folder);
    defer timeline.destroy();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const page = try timeline.page(arena.allocator(), 0, .{}, 0, 10);
    try testing.expectEqual(@as(u32, 3), page.total);
    try testing.expectEqualStrings("P/Camera/PXL_1.RAW-01.MP.jpg", page.items[0].path);
    try testing.expectEqualStrings("P/Camera/IMG_2.dng", page.items[1].path);
    try testing.expectEqualStrings("P/Other/PXL_1.RAW-02.ORIGINAL.dng", page.items[2].path);
}
