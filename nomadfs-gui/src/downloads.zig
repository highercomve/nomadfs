//! Downloads: files copied from a device's share or the swarm folder into
//! Downloads/NomadFS. Each copy runs on its own thread and pushes its
//! progress to the page (`download://progress`); the list is kept in
//! `downloads.json` beside the config, so the Downloads view still shows
//! where earlier ones went after a restart.

const std = @import("std");
const builtin = @import("builtin");
const oriel = @import("oriel");
const nomadfs = @import("nomadfs");
const commands = @import("commands.zig");

const gpa = std.heap.smp_allocator;
const FileSource = nomadfs.Node.FileSource;

pub const State = enum { running, done, failed, canceled };

/// The `download://progress` payload: sent every quarter second while a
/// copy runs, and once when it ends.
pub const Progress = struct { id: u32, done: u64, size: u64, state: State, @"error": []const u8 };

const events = oriel.App.events(struct { @"download://progress": Progress });

/// Downloads remembered; the oldest finished ones go first.
const max_entries = 200;
const emit_interval_ms = 250;

const Download = struct {
    id: u32,
    name: []const u8,
    path: []const u8,
    source: FileSource,
    size: u64,
    done: std.atomic.Value(u64) = .init(0),
    state: State = .running,
    err: []const u8 = "",
    started: i64,
    finished: i64 = 0,
    cancel: std.atomic.Value(bool) = .init(false),
    last_emit_ms: i64 = 0,

    fn destroy(self: *Download) void {
        gpa.free(self.name);
        gpa.free(self.path);
        gpa.free(self.err);
        gpa.destroy(self);
    }
};

var g_mutex: nomadfs.sync.Mutex = .{};
var g_loaded = false;
var g_next_id: u32 = 1;
var g_list: std.ArrayList(*Download) = .empty;
/// Copies running; cancelAll waits for them.
var g_running: std.atomic.Value(u32) = .init(0);

/// A download as the page sees it.
pub const Info = struct {
    id: u32,
    name: []const u8,
    path: []const u8,
    /// The folder it is in.
    folder: []const u8,
    size: u64,
    done: u64,
    state: State,
    @"error": []const u8,
    started: i64,
    finished: i64,
    /// Where it came from, to download it again or stream it: "device"
    /// (`source_id` is the device sharing it) or "swarm" (who added it).
    kind: []const u8,
    source_id: []const u8,
    cid: []const u8,
    /// The saved file is still there (not moved or deleted since).
    exists: bool,
};

pub const DeviceArgs = struct { peer: []const u8, cid: []const u8, name: []const u8, size: u64 };
pub const SwarmArgs = struct { cid: []const u8, author_id: []const u8, name: []const u8, size: u64 };
pub const IdArgs = struct { id: u32 };
pub const RemoveArgs = struct { id: u32, delete_file: bool = false };
pub const RangeArgs = struct { id: u32, offset: u64, len: u32 };

/// `invoke("download", { peer, cid, name, size })`: a file a device shares.
pub fn fromDevice(alloc: std.mem.Allocator, args: DeviceArgs) !Info {
    return start(alloc, .{ .share = .{ .peer = .{ .bytes = try commands.parseHex32(args.peer) }, .cid = try commands.parseHex32(args.cid) } }, args.name, args.size);
}

/// `invoke("swarm_download", { cid, author_id, name, size })`.
pub fn fromSwarm(alloc: std.mem.Allocator, args: SwarmArgs) !Info {
    return start(alloc, .{ .swarm = .{ .cid = try commands.parseHex32(args.cid), .author = try commands.parseHex32(args.author_id) } }, args.name, args.size);
}

/// `invoke("download_read_range", { id, offset, len })`: base64 bytes of a
/// finished download's saved file, for previews.
pub fn readRange(alloc: std.mem.Allocator, args: RangeArgs) ![]const u8 {
    if (args.len == 0 or args.len > commands.max_range_len) return error.InvalidArgument;
    const buf = try alloc.alloc(u8, args.len);
    defer alloc.free(buf);
    const n = try readSaved(args.id, args.offset, buf);
    return commands.base64Alloc(alloc, buf[0..n]);
}

/// Starts copying `source` into Downloads/NomadFS; returns at once.
pub fn start(alloc: std.mem.Allocator, source: FileSource, name: []const u8, size: u64) !Info {
    if (!nomadfs.storage.dag.codec.isValidName(name)) return error.InvalidName;
    const io = std.Io.Threaded.global_single_threaded.io();
    const dir = try downloadsDir(gpa);
    defer gpa.free(dir);
    try std.Io.Dir.cwd().createDirPath(io, dir);

    g_mutex.lock();
    defer g_mutex.unlock();
    loadLocked();
    const d = try gpa.create(Download);
    errdefer gpa.destroy(d);
    const path = try uniquePathLocked(dir, name);
    errdefer gpa.free(path);
    d.* = .{ .id = g_next_id, .name = try gpa.dupe(u8, name), .path = path, .source = source, .size = size, .started = nomadfs.sync.timestamp() };
    errdefer gpa.free(d.name);
    try g_list.append(gpa, d);
    errdefer _ = g_list.pop();
    _ = g_running.fetchAdd(1, .acq_rel);
    errdefer _ = g_running.fetchSub(1, .acq_rel);
    const thread = try std.Thread.spawn(.{}, run, .{d});
    thread.detach();
    g_next_id += 1;
    trimLocked();
    return infoLocked(alloc, d);
}

fn run(d: *Download) void {
    defer _ = g_running.fetchSub(1, .acq_rel);
    const result = copy(d);
    g_mutex.lock();
    d.finished = nomadfs.sync.timestamp();
    if (result) |n| {
        d.done.store(n, .release);
        d.state = .done;
    } else |err| {
        d.state = if (err == error.Canceled) .canceled else .failed;
        d.err = gpa.dupe(u8, describe(err)) catch "";
    }
    saveLocked();
    const payload: Progress = .{ .id = d.id, .done = d.done.load(.acquire), .size = d.size, .state = d.state, .@"error" = d.err };
    g_mutex.unlock();
    events.emit(.@"download://progress", payload);
}

fn copy(d: *Download) !u64 {
    // Pinned, not under the command lock: a slow device doesn't stall the
    // app; closing the node cancels the copy first (cancelAll).
    const handle = commands.mediaAcquire() orelse return error.NotRunning;
    defer commands.mediaRelease();
    return handle.node.saveFile(gpa, d.source, d.path, d.size, .{ .ctx = d, .on_bytes = onBytes, .cancel = &d.cancel });
}

fn onBytes(ctx: ?*anyopaque, done: u64) void {
    const d: *Download = @ptrCast(@alignCast(ctx.?));
    d.done.store(done, .release);
    const now = nomadfs.sync.monotonicMillis();
    if (now - d.last_emit_ms < emit_interval_ms) return;
    d.last_emit_ms = now;
    events.emit(.@"download://progress", .{ .id = d.id, .done = done, .size = d.size, .state = .running, .@"error" = "" });
}

fn describe(err: anyerror) []const u8 {
    return switch (err) {
        error.Canceled => "Canceled",
        error.NotRunning => "NomadFS isn't running",
        error.BlockNotFound, error.AllAddressesFailed => "The device that has it is offline",
        error.NoSpaceLeft => "The disk is full",
        error.AccessDenied, error.PermissionDenied => "No permission to write to the Downloads folder",
        error.FileTooLarge => "The file is larger than its listing said",
        else => @errorName(err),
    };
}

/// Stops every copy and waits for them (the node is about to close).
pub fn cancelAll() void {
    {
        g_mutex.lock();
        defer g_mutex.unlock();
        for (g_list.items) |d| if (d.state == .running) d.cancel.store(true, .release);
    }
    while (g_running.load(.acquire) > 0) nomadfs.sync.sleep(10 * std.time.ns_per_ms);
}

/// Every download, newest first.
pub fn list(alloc: std.mem.Allocator) ![]Info {
    g_mutex.lock();
    defer g_mutex.unlock();
    loadLocked();
    const out = try alloc.alloc(Info, g_list.items.len);
    for (out, 0..) |*o, i| o.* = try infoLocked(alloc, g_list.items[g_list.items.len - 1 - i]);
    return out;
}

/// Stops a running copy (its partial file is deleted).
pub fn cancel(id: u32) !void {
    g_mutex.lock();
    defer g_mutex.unlock();
    const d = findLocked(id) orelse return error.NotFound;
    d.cancel.store(true, .release);
}

/// Takes a finished download off the list; `delete_file` deletes it too.
pub fn remove(id: u32, delete_file: bool) !void {
    g_mutex.lock();
    defer g_mutex.unlock();
    for (g_list.items, 0..) |d, i| {
        if (d.id != id) continue;
        if (d.state == .running) return error.StillRunning;
        if (delete_file and d.state == .done) {
            const io = std.Io.Threaded.global_single_threaded.io();
            std.Io.Dir.cwd().deleteFile(io, d.path) catch |err| switch (err) {
                error.FileNotFound => {},
                else => return err,
            };
        }
        _ = g_list.orderedRemove(i);
        d.destroy();
        saveLocked();
        return;
    }
    return error.NotFound;
}

pub const OpenArgs = struct { id: u32, mime: []const u8 };

/// `invoke("download_open", { id, mime })`: the saved file in another app
/// (the chooser on Android, the default app for `mime` on the desktop).
pub fn open(args: OpenArgs) !void {
    if (!validMime(args.mime)) return error.InvalidArgument;
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try savedPathZ(args.id, &path_buf);
    var mime_buf: [128]u8 = undefined;
    oriel.App.openPath(path, try std.fmt.bufPrintZ(&mime_buf, "{s}", .{args.mime}));
}

/// `invoke("downloads_open_folder")`: the downloads folder in the file
/// manager (Files on Android).
pub fn openFolder() !void {
    const dir = try folder(gpa);
    defer gpa.free(dir);
    const dir_z = try gpa.dupeZ(u8, dir);
    defer gpa.free(dir_z);
    oriel.App.openPath(dir_z, "inode/directory");
}

/// A finished download's path, NUL-terminated in `buf`.
fn savedPathZ(id: u32, buf: *[std.fs.max_path_bytes]u8) ![:0]const u8 {
    g_mutex.lock();
    defer g_mutex.unlock();
    loadLocked();
    const d = findLocked(id) orelse return error.NotFound;
    if (d.state != .done) return error.FileNotFound;
    return std.fmt.bufPrintZ(buf, "{s}", .{d.path}) catch error.NameTooLong;
}

/// `type/subtype` from [a-z0-9.+-].
fn validMime(m: []const u8) bool {
    if (m.len == 0 or m.len > 100) return false;
    var slashes: usize = 0;
    for (m) |c| switch (c) {
        'a'...'z', 'A'...'Z', '0'...'9', '.', '+', '-' => {},
        '/' => slashes += 1,
        else => return false,
    };
    return slashes == 1 and m[0] != '/' and m[m.len - 1] != '/';
}

/// Takes every finished download off the list (the files stay).
pub fn clearFinished() void {
    g_mutex.lock();
    defer g_mutex.unlock();
    var i: usize = 0;
    while (i < g_list.items.len) {
        const d = g_list.items[i];
        if (d.state == .running) {
            i += 1;
            continue;
        }
        _ = g_list.orderedRemove(i);
        d.destroy();
    }
    saveLocked();
}

/// Reads a finished download's saved file: previews and the media server
/// play it from the disk instead of the network.
pub fn readSaved(id: u32, offset: u64, dest: []u8) !usize {
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = blk: {
        g_mutex.lock();
        defer g_mutex.unlock();
        loadLocked();
        const d = findLocked(id) orelse return error.FileNotFound;
        if (d.state != .done or d.path.len > path_buf.len) return error.FileNotFound;
        @memcpy(path_buf[0..d.path.len], d.path);
        break :blk path_buf[0..d.path.len];
    };
    const io = std.Io.Threaded.global_single_threaded.io();
    var file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    return file.readPositionalAll(io, dest, offset);
}

fn findLocked(id: u32) ?*Download {
    for (g_list.items) |d| if (d.id == id) return d;
    return null;
}

fn infoLocked(alloc: std.mem.Allocator, d: *Download) !Info {
    const io = std.Io.Threaded.global_single_threaded.io();
    const exists = if (std.Io.Dir.cwd().statFile(io, d.path, .{})) |_| true else |_| false;
    const kind: []const u8, const source_id: [32]u8, const cid: [32]u8 = switch (d.source) {
        .share => |s| .{ "device", s.peer.bytes, s.cid },
        .swarm => |s| .{ "swarm", s.author, s.cid },
    };
    return .{
        .id = d.id,
        .name = try alloc.dupe(u8, d.name),
        .path = try alloc.dupe(u8, d.path),
        .folder = try alloc.dupe(u8, std.fs.path.dirname(d.path) orelse ""),
        .size = d.size,
        .done = d.done.load(.acquire),
        .state = d.state,
        .@"error" = try alloc.dupe(u8, d.err),
        .started = d.started,
        .finished = d.finished,
        .kind = kind,
        .source_id = try alloc.dupe(u8, &std.fmt.bytesToHex(source_id, .lower)),
        .cid = try alloc.dupe(u8, &std.fmt.bytesToHex(cid, .lower)),
        .exists = exists,
    };
}

/// Forgets the oldest finished downloads past max_entries.
fn trimLocked() void {
    var i: usize = 0;
    while (g_list.items.len > max_entries and i < g_list.items.len) {
        const d = g_list.items[i];
        if (d.state == .running) {
            i += 1;
            continue;
        }
        _ = g_list.orderedRemove(i);
        d.destroy();
    }
}

/// Downloads/NomadFS: the shared Download folder on Android (readable by
/// other apps; needs all-files access), $HOME/Downloads elsewhere.
fn downloadsDir(alloc: std.mem.Allocator) ![]const u8 {
    if (builtin.abi.isAndroid()) return alloc.dupe(u8, "/storage/emulated/0/Download/NomadFS");
    const home_env = if (builtin.os.tag == .windows) "USERPROFILE" else "HOME";
    const home = nomadfs.env.getEnv(alloc, home_env) orelse return error.HomeNotFound;
    defer alloc.free(home);
    return std.fs.path.join(alloc, &.{ home, "Downloads", "NomadFS" });
}

/// The downloads folder, created if missing (the page opens it).
pub fn folder(alloc: std.mem.Allocator) ![]const u8 {
    const dir = try downloadsDir(alloc);
    errdefer alloc.free(dir);
    std.Io.Dir.cwd().createDirPath(std.Io.Threaded.global_single_threaded.io(), dir) catch {};
    return dir;
}

/// `dir/name`, or `dir/name (n).ext` when a file or a running download
/// has that name already.
fn uniquePathLocked(dir: []const u8, name: []const u8) ![]const u8 {
    const io = std.Io.Threaded.global_single_threaded.io();
    const ext = std.fs.path.extension(name);
    const stem = name[0 .. name.len - ext.len];
    var n: u32 = 0;
    while (n < 1000) : (n += 1) {
        const candidate = if (n == 0)
            try std.fs.path.join(gpa, &.{ dir, name })
        else
            try std.fmt.allocPrint(gpa, "{s}/{s} ({d}){s}", .{ dir, stem, n, ext });
        const taken = for (g_list.items) |d| {
            if (d.state == .running and std.mem.eql(u8, d.path, candidate)) break true;
        } else false;
        if (!taken) {
            _ = std.Io.Dir.cwd().statFile(io, candidate, .{}) catch return candidate;
        }
        gpa.free(candidate);
    }
    return error.PathAlreadyExists;
}

// ---- downloads.json ----

/// One line of downloads.json; CIDs and device IDs as hex.
const Saved = struct {
    id: u32,
    name: []const u8,
    path: []const u8,
    kind: []const u8,
    source_id: []const u8,
    cid: []const u8,
    size: u64,
    done: u64,
    state: State,
    @"error": []const u8 = "",
    started: i64,
    finished: i64,
};

fn jsonPath(alloc: std.mem.Allocator) ![]const u8 {
    const dir = try commands.dataDir(alloc);
    defer alloc.free(dir);
    return std.fs.path.join(alloc, &.{ dir, "downloads.json" });
}

/// Reads downloads.json once. A copy the app was running when it stopped
/// is marked failed, and its partial file deleted.
fn loadLocked() void {
    if (g_loaded) return;
    g_loaded = true;
    const io = std.Io.Threaded.global_single_threaded.io();
    const path = jsonPath(gpa) catch return;
    defer gpa.free(path);
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(4 << 20)) catch return;
    defer gpa.free(bytes);
    const parsed = std.json.parseFromSlice([]Saved, gpa, bytes, .{ .ignore_unknown_fields = true }) catch return;
    defer parsed.deinit();
    var interrupted = false;
    for (parsed.value) |s| {
        const d = fromSaved(s) catch continue;
        if (d.state == .running) {
            std.Io.Dir.cwd().deleteFile(io, d.path) catch {};
            d.state = .failed;
            d.err = gpa.dupe(u8, "Interrupted: NomadFS stopped") catch "";
            interrupted = true;
        }
        g_list.append(gpa, d) catch {
            d.destroy();
            break;
        };
        g_next_id = @max(g_next_id, d.id +% 1);
    }
    if (interrupted) saveLocked();
}

fn fromSaved(s: Saved) !*Download {
    var source_id: [32]u8 = undefined;
    var cid: [32]u8 = undefined;
    if (s.source_id.len != 64 or s.cid.len != 64) return error.InvalidArgument;
    _ = try std.fmt.hexToBytes(&source_id, s.source_id);
    _ = try std.fmt.hexToBytes(&cid, s.cid);
    const source: FileSource = if (std.mem.eql(u8, s.kind, "swarm"))
        .{ .swarm = .{ .cid = cid, .author = source_id } }
    else
        .{ .share = .{ .peer = .{ .bytes = source_id }, .cid = cid } };
    const d = try gpa.create(Download);
    errdefer gpa.destroy(d);
    const name = try gpa.dupe(u8, s.name);
    errdefer gpa.free(name);
    const path = try gpa.dupe(u8, s.path);
    errdefer gpa.free(path);
    d.* = .{ .id = s.id, .name = name, .path = path, .source = source, .size = s.size, .state = s.state, .err = try gpa.dupe(u8, s.@"error"), .started = s.started, .finished = s.finished };
    d.done.store(s.done, .release);
    return d;
}

/// Writes downloads.json (temp file, then rename); a failure only loses
/// the list, never a download.
fn saveLocked() void {
    saveFallible() catch |err| std.log.warn("downloads: can't save the list: {s}", .{@errorName(err)});
}

fn saveFallible() !void {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const out = try arena.alloc(Saved, g_list.items.len);
    for (g_list.items, out) |d, *o| {
        const info = try infoLocked(arena, d);
        o.* = .{ .id = d.id, .name = d.name, .path = d.path, .kind = info.kind, .source_id = info.source_id, .cid = info.cid, .size = d.size, .done = d.done.load(.acquire), .state = d.state, .@"error" = d.err, .started = d.started, .finished = d.finished };
    }
    const bytes = try std.json.Stringify.valueAlloc(arena, out, .{});
    const path = try jsonPath(arena);
    const tmp = try std.fmt.allocPrint(arena, "{s}.tmp", .{path});
    const io = std.Io.Threaded.global_single_threaded.io();
    {
        var file = try std.Io.Dir.cwd().createFile(io, tmp, .{ .truncate = true });
        defer file.close(io);
        try file.writePositionalAll(io, bytes, 0);
    }
    try std.Io.Dir.cwd().rename(tmp, std.Io.Dir.cwd(), path, io);
}
