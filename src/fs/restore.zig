//! Restores backup files into a local directory. fs decides which paths are
//! valid, which version of a file is meant and how files reach the disk; the
//! cluster target (offsite.zig) supplies snapshots, history, thaws and
//! verified bytes.
//!
//! Nothing is ever written through a symlink: every directory is opened
//! without following links, every file is written to a new, exclusively
//! created temporary file in the job directory, synced, and renamed into
//! place. The job directory (`.nomadfs-restore/` in the destination) holds
//! the request and the list of finished files while a restore is under way,
//! so the same call, repeated after a thaw, an error or a crash, continues.
const std = @import("std");
const offsite = @import("../cluster/offsite.zig");
const manifest = @import("manifest.zig");
const Allocator = std.mem.Allocator;
const Cid = [32]u8;
const Dir = std.Io.Dir;

/// Reserved in the destination: no restored path may start with it.
pub const job_dir = ".nomadfs-restore";
const job_file = "job.json";
const done_file = "done.log";
const tmp_suffix = ".tmp";
const max_job = 64 * 1024;
const max_done = 512 * 1024 * 1024;
/// The finished-files list is synced after this many files.
const sync_every = 64;
const max_stale = 100_000;

/// Which version of a file the history restores: the newest, the one that
/// was current at a time, or one exact content.
pub const Version = union(enum) { latest, at: u64, cid: Cid };
/// A kept snapshot, or the history (also files no kept snapshot lists).
pub const From = union(enum) { snapshot: []const u8, history: Version };
pub const Request = struct {
    from: From,
    /// One file or subtree; null is everything.
    path: ?[]const u8 = null,
    tier: offsite.Tier = .Bulk,
};

const Job = struct {
    version: u32 = 2,
    /// "snapshots/<id>", or the picked history version ("latest", "at:…", "cid:…").
    source: []const u8,
    history: bool = false,
    path: ?[]const u8 = null,
    tier: offsite.Tier = .Bulk,
    requested: u64 = 0,
};

/// Null or "latest": the newest. 64 hex digits: that content. Digits: a
/// Unix time. "YYYY-MM-DD": the end of that day (UTC).
pub fn parseVersion(text: ?[]const u8) !Version {
    const t = text orelse return .latest;
    if (std.mem.eql(u8, t, "latest")) return .latest;
    if (t.len == 64) {
        var cid: Cid = undefined;
        _ = std.fmt.hexToBytes(&cid, t) catch return error.InvalidVersion;
        return .{ .cid = cid };
    }
    if (t.len == 10 and t[4] == '-' and t[7] == '-') {
        const year = std.fmt.parseInt(u16, t[0..4], 10) catch return error.InvalidVersion;
        const month = std.fmt.parseInt(u8, t[5..7], 10) catch return error.InvalidVersion;
        const day = std.fmt.parseInt(u8, t[8..10], 10) catch return error.InvalidVersion;
        if (year < 1970 or month < 1 or month > 12 or day < 1) return error.InvalidVersion;
        if (day > std.time.epoch.getDaysInMonth(year, @enumFromInt(month))) return error.InvalidVersion;
        var days: u64 = 0;
        for (1970..year) |y| days += std.time.epoch.getDaysInYear(@intCast(y));
        for (1..month) |m| days += std.time.epoch.getDaysInMonth(year, @enumFromInt(m));
        return .{ .at = (days + day) * 86400 - 1 };
    }
    return .{ .at = std.fmt.parseInt(u64, t, 10) catch return error.InvalidVersion };
}

fn describe(a: Allocator, from: From) ![]const u8 {
    return switch (from) {
        .snapshot => |name| name,
        .history => |version| switch (version) {
            .latest => "latest",
            .at => |time| std.fmt.allocPrint(a, "at:{d}", .{time}),
            .cid => |cid| std.fmt.allocPrint(a, "cid:{s}", .{std.fmt.bytesToHex(cid, .lower)}),
        },
    };
}

/// One version per path out of the history. A version seen first after
/// `at` did not exist yet; among the rest the newest wins.
pub fn pick(a: Allocator, versions: []const offsite.File, version: Version) ![]const offsite.File {
    var chosen: std.StringArrayHashMapUnmanaged(offsite.File) = .empty;
    for (versions) |file| {
        switch (version) {
            .latest => {},
            .at => |time| if (file.first_seen > time) continue,
            .cid => |cid| if (!std.mem.eql(u8, &cid, &file.cid)) continue,
        }
        const slot = try chosen.getOrPut(a, file.path);
        if (!slot.found_existing or newer(file, slot.value_ptr.*, version == .at)) slot.value_ptr.* = file;
    }
    return chosen.values();
}

fn newer(x: offsite.File, y: offsite.File, by_first: bool) bool {
    const kx = if (by_first) [3]u64{ x.first_seen, x.last_seen, x.mtime } else [3]u64{ x.last_seen, x.first_seen, x.mtime };
    const ky = if (by_first) [3]u64{ y.first_seen, y.last_seen, y.mtime } else [3]u64{ y.last_seen, y.first_seen, y.mtime };
    return std.mem.order(u64, &kx, &ky) == .gt;
}

/// True for a path the restore keeps for its own files.
fn reserved(path: []const u8) bool {
    return offsite.under(path, job_dir);
}

/// The files the request names, checked: every path is a valid swarm path
/// and none collides with the job directory.
fn select(a: Allocator, service: *offsite.Service, request: Request) ![]const offsite.File {
    if (request.path) |p| if (!manifest.validPath(p)) return error.InvalidPath;
    var files: std.ArrayList(offsite.File) = .empty;
    switch (request.from) {
        .snapshot => |name| for ((try service.snapshot(name)).files) |file| {
            if (request.path) |p| if (!offsite.under(file.path, p)) continue;
            try files.append(a, file);
        },
        .history => |version| try files.appendSlice(a, try pick(a, try service.history(request.path), version)),
    }
    if (files.items.len > manifest.max_entries) return error.InvalidSnapshot;
    for (files.items) |file| {
        if (!manifest.validPath(file.path)) return error.InvalidSnapshot;
        if (reserved(file.path)) return error.ReservedPath;
    }
    if (files.items.len == 0 and (request.path != null or request.from == .history)) return error.PathNotFound;
    return files.items;
}

/// Opens the directory `sub` below `root`, one component at a time and
/// never through a symlink. `create` makes the missing ones; without it a
/// missing component answers null.
fn openBelow(io: std.Io, root: Dir, sub: []const u8, create: bool) !?Dir {
    var dir = try root.openDir(io, ".", .{ .follow_symlinks = false });
    errdefer dir.close(io);
    var parts = std.mem.splitScalar(u8, sub, '/');
    while (parts.next()) |part| {
        if (part.len == 0) continue;
        if (create) dir.createDir(io, part, .fromMode(0o700)) catch |err| if (err != error.PathAlreadyExists) return err;
        const next = dir.openDir(io, part, .{ .follow_symlinks = false }) catch |err| {
            if (err != error.FileNotFound or create) return err;
            dir.close(io);
            return null;
        };
        dir.close(io);
        dir = next;
    }
    return dir;
}

/// True when something (a file, a link, a directory) is at `path`.
fn exists(io: std.Io, root: Dir, path: []const u8) !bool {
    var parent = (try openBelow(io, root, std.fs.path.dirname(path) orelse "", false)) orelse return false;
    defer parent.close(io);
    _ = parent.statFile(io, std.fs.path.basename(path), .{ .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    return true;
}

/// A regular file's bytes, read without following a link; null when missing.
fn readPlain(a: Allocator, io: std.Io, dir: Dir, name: []const u8, limit: usize) !?[]u8 {
    const file = dir.openFile(io, name, .{ .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer file.close(io);
    const st = try file.stat(io);
    if (st.kind != .file) return error.InvalidRestoreJob;
    if (st.size > limit) return error.RestoreJobTooLarge;
    const bytes = try a.alloc(u8, @intCast(st.size));
    const got = try file.readPositionalAll(io, bytes, 0);
    return bytes[0..got];
}

/// "<prefix>-<32 random hex digits>.tmp": never guessable, so never placed
/// in advance by someone else.
fn tmpName(prefix: []const u8, out: *[64]u8) ![]const u8 {
    var random: [16]u8 = undefined;
    try std.Io.Threaded.global_single_threaded.io().randomSecure(&random);
    return std.fmt.bufPrint(out, "{s}-{s}" ++ tmp_suffix, .{ prefix, std.fmt.bytesToHex(random, .lower) }) catch unreachable;
}

/// The state of one restore into one destination.
const Session = struct {
    a: Allocator,
    io: std.Io,
    destination: Dir,
    dir: Dir,
    /// True when an earlier call left this job: files in the way are its own.
    resumed: bool,
    /// Finished files: path to content id.
    done: std.StringHashMapUnmanaged(Cid) = .empty,
    log: std.Io.File,
    log_end: u64 = 0,
    unsynced: usize = 0,

    fn open(a: Allocator, io: std.Io, destination: Dir, job: Job, files: []const offsite.File) !Session {
        const existed = try exists(io, destination, job_dir);
        // An exclusive create never follows a link; an existing entry must
        // be a real directory (opened without following a link).
        if (!existed) try destination.createDir(io, job_dir, .fromMode(0o700));
        var dir = try destination.openDir(io, job_dir, .{ .follow_symlinks = false, .iterate = true });
        errdefer dir.close(io);
        if (existed) try sweep(a, io, dir);
        var resumed = false;
        if (try readPlain(a, io, dir, job_file, max_job)) |bytes| {
            const old = std.json.parseFromSliceLeaky(Job, a, bytes, .{ .ignore_unknown_fields = true }) catch return error.InvalidRestoreJob;
            const same_path = if (old.path) |p| job.path != null and std.mem.eql(u8, p, job.path.?) else job.path == null;
            if (old.version != job.version or old.history != job.history or !std.mem.eql(u8, old.source, job.source) or !same_path) return error.RestoreJobMismatch;
            resumed = true;
        } else {
            // A new job: nothing it will write may be there already, so
            // whatever a later pass finds at those paths is this job's.
            errdefer if (!existed) destination.deleteTree(io, job_dir) catch {};
            for (files) |file| if (!file.directory and try exists(io, destination, file.path)) return error.PathAlreadyExists;
            var buf: [64]u8 = undefined;
            const tmp = try tmpName("job", &buf);
            errdefer dir.deleteFile(io, tmp) catch {};
            {
                const out = try dir.createFile(io, tmp, .{ .exclusive = true, .permissions = .fromMode(0o600) });
                defer out.close(io);
                try out.writePositionalAll(io, try std.json.Stringify.valueAlloc(a, job, .{}), 0);
                try out.sync(io);
            }
            try dir.rename(tmp, dir, job_file, io);
        }
        var self: Session = .{ .a = a, .io = io, .destination = destination, .dir = dir, .resumed = resumed, .log = undefined };
        const kept = if (resumed) (try readPlain(a, io, dir, done_file, max_done)) orelse "" else "";
        // Only whole lines count: a crash can cut the last one.
        var lines = std.mem.splitScalar(u8, kept, '\n');
        while (lines.next()) |line| {
            if (lines.peek() == null) break;
            self.log_end += line.len + 1;
            if (line.len < 67 or line[64] != ' ') continue;
            var cid: Cid = undefined;
            _ = std.fmt.hexToBytes(&cid, line[0..64]) catch continue;
            const path = std.json.parseFromSliceLeaky([]const u8, a, line[65..], .{}) catch continue;
            try self.done.put(a, path, cid);
        }
        self.log = dir.createFile(io, done_file, .{ .exclusive = true, .permissions = .fromMode(0o600) }) catch |err| switch (err) {
            error.PathAlreadyExists => try dir.openFile(io, done_file, .{ .mode = .read_write, .follow_symlinks = false }),
            else => return err,
        };
        errdefer self.log.close(io);
        if ((try self.log.stat(io)).kind != .file) return error.InvalidRestoreJob;
        try self.log.setLength(io, self.log_end);
        return self;
    }
    fn close(self: *Session) void {
        self.log.close(self.io);
        self.dir.close(self.io);
    }
    /// Temporary files an interrupted pass left in the job directory.
    fn sweep(a: Allocator, io: std.Io, dir: Dir) !void {
        var stale: std.ArrayList([]const u8) = .empty;
        var it = dir.iterate();
        while (try it.next(io)) |entry| {
            if (stale.items.len >= max_stale) break;
            if (std.mem.endsWith(u8, entry.name, tmp_suffix)) try stale.append(a, try a.dupe(u8, entry.name));
        }
        for (stale.items) |name| dir.deleteFile(io, name) catch {};
    }
    /// True when an earlier pass finished this file and it is still there.
    fn finished(self: *Session, parent: Dir, file: offsite.File) !bool {
        const cid = self.done.get(file.path) orelse return false;
        if (!std.mem.eql(u8, &cid, &file.cid)) return false;
        const st = parent.statFile(self.io, std.fs.path.basename(file.path), .{ .follow_symlinks = false }) catch |err| switch (err) {
            error.FileNotFound => return false,
            else => return err,
        };
        return st.kind == .file and st.size == file.size;
    }
    fn record(self: *Session, file: offsite.File) !void {
        const quoted = try std.json.Stringify.valueAlloc(self.a, file.path, .{});
        const line = try std.fmt.allocPrint(self.a, "{s} {s}\n", .{ std.fmt.bytesToHex(file.cid, .lower), quoted });
        try self.log.writePositionalAll(self.io, line, self.log_end);
        self.log_end += line.len;
        self.unsynced += 1;
        if (self.unsynced >= sync_every) try self.flush();
    }
    fn flush(self: *Session) !void {
        if (self.unsynced == 0) return;
        try self.log.sync(self.io);
        self.unsynced = 0;
    }
    /// Writes one file: a new temporary file in the job directory, synced,
    /// then renamed over whatever is at the final name (a link is replaced,
    /// never followed).
    fn write(self: *Session, service: *offsite.Service, parent: Dir, file: offsite.File) !void {
        const base = std.fs.path.basename(file.path);
        if (!self.resumed and try exists(self.io, parent, base)) return error.PathAlreadyExists;
        var buf: [64]u8 = undefined;
        const tmp = try tmpName("file", &buf);
        errdefer self.dir.deleteFile(self.io, tmp) catch {};
        {
            const out = try self.dir.createFile(self.io, tmp, .{ .exclusive = true, .permissions = .fromMode(0o600) });
            defer out.close(self.io);
            var target: Output = .{ .io = self.io, .file = out };
            try service.streamFile(file, .{ .ctx = &target, .writeFn = Output.write });
            try out.sync(self.io);
        }
        try self.dir.rename(tmp, parent, base, self.io);
        try self.record(file);
    }
};

const Output = struct {
    io: std.Io,
    file: std.Io.File,
    fn write(ctx: *anyopaque, offset: u64, bytes: []const u8) anyerror!void {
        const self: *Output = @ptrCast(@alignCast(ctx));
        try self.file.writePositionalAll(self.io, bytes, offset);
    }
};

/// Restores through an already-open directory capability. A cold target is
/// first asked to thaw every pack the request needs; the files whose packs
/// are readable are written, and the job stays in the destination while
/// packs are thawing. The same call, repeated, skips the files the job
/// recorded as finished, writes every other one again (a file changed or
/// cut short in between is replaced) and ends when none is left.
/// A new restore refuses a destination that already has one of its files.
pub fn restore(a: Allocator, io: std.Io, service: *offsite.Service, request: Request, destination: Dir) !offsite.Restore {
    var arena_state: std.heap.ArenaAllocator = .init(a);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const files = try select(arena, service, request);
    const job: Job = .{ .source = try describe(arena, request.from), .history = request.from == .history, .path = request.path, .tier = request.tier, .requested = service.now() };
    var session = try Session.open(arena, io, destination, job, files);
    var open = true;
    defer if (open) session.close();
    var result: offsite.Restore = .{};
    var ready: offsite.Packs = .init(a);
    defer ready.deinit();
    const is_cold = service.cold();
    for (files) |file| {
        if (file.directory) {
            var made = (try openBelow(io, destination, file.path, true)).?;
            made.close(io);
            continue;
        }
        if (is_cold and !(try service.fileReady(file, &ready, request.tier, &result))) continue;
        var parent = (try openBelow(io, destination, std.fs.path.dirname(file.path) orelse "", true)).?;
        defer parent.close(io);
        if (!(try session.finished(parent, file))) {
            session.write(service, parent, file) catch |err| {
                session.flush() catch {};
                return err;
            };
        }
        result.files += 1;
    }
    try session.flush();
    if (result.thawing_packs > 0) return result;
    session.close();
    open = false;
    try destination.deleteTree(io, job_dir);
    return result;
}

test "offsite: restore version is the newest, one content, or the one current at a time" {
    const a = std.testing.allocator;
    try std.testing.expectEqual(Version.latest, try parseVersion(null));
    try std.testing.expectEqual(@as(u64, 1_700_000_000), (try parseVersion("1700000000")).at);
    try std.testing.expectEqual(@as(u64, 86400 * 366 - 1), (try parseVersion("1971-01-01")).at);
    try std.testing.expectEqual(@as(u8, 0xab), (try parseVersion("ab" ** 32)).cid[31]);
    try std.testing.expectError(error.InvalidVersion, parseVersion("2026-13-01"));
    try std.testing.expectError(error.InvalidVersion, parseVersion("yesterday"));
    const versions = [_]offsite.File{
        .{ .path = "a", .cid = [_]u8{1} ** 32, .size = 1, .blocks = &.{}, .first_seen = 10, .last_seen = 20 },
        .{ .path = "a", .cid = [_]u8{2} ** 32, .size = 2, .blocks = &.{}, .first_seen = 30, .last_seen = 40 },
        .{ .path = "b", .cid = [_]u8{3} ** 32, .size = 3, .blocks = &.{}, .first_seen = 35, .last_seen = 35 },
    };
    var arena: std.heap.ArenaAllocator = .init(a);
    defer arena.deinit();
    const latest = try pick(arena.allocator(), &versions, .latest);
    try std.testing.expectEqual(@as(usize, 2), latest.len);
    try std.testing.expectEqual(@as(u64, 2), latest[0].size);
    const early = try pick(arena.allocator(), &versions, .{ .at = 25 });
    try std.testing.expectEqual(@as(usize, 1), early.len);
    try std.testing.expectEqual(@as(u64, 1), early[0].size);
    const exact = try pick(arena.allocator(), &versions, .{ .cid = [_]u8{1} ** 32 });
    try std.testing.expectEqual(@as(u64, 1), exact[0].size);
    try std.testing.expect(reserved(".nomadfs-restore/job.json") and reserved(".nomadfs-restore") and !reserved(".nomadfs-restore.json"));
}
