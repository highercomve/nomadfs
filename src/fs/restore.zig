//! Restores backup files into a local directory. fs decides which paths are
//! valid, which version of a file is meant and how files reach the disk; the
//! cluster target (offsite.zig) supplies snapshots, history, thaws and
//! verified bytes.
//!
//! Nothing is ever written through a symlink: every directory is opened
//! without following links, every file is written to a new, exclusively
//! created temporary file in the job directory, synced, and renamed into
//! place. The job directory (`.nomadfs-restore/` in the destination) holds
//! the request, the plan and the list of finished files while a restore is
//! under way, so the same call, repeated after a thaw, an error or a crash,
//! continues. The plan is the whole view the job needs: its files and where
//! every block of them is. A later pass reads neither the snapshot nor the
//! index, which the backup may have moved on from in the days a thaw takes.
//! The job asks the backup to keep every pack of its plan (a pin) until it
//! has ended. That is a request, not a lock: when a pack is gone all the
//! same, the plan is made again from the committed head, which always
//! works for what the backup still holds. Only a file purged meanwhile is
//! left out, and the plan keeps its name for every later result.
const std = @import("std");
/// Owner-only on POSIX; Windows has no mode bits (the profile's ACLs apply).
const private_dir: std.Io.File.Permissions = if (@import("builtin").os.tag == .windows) .default_dir else .fromMode(0o700);
const private_file: std.Io.File.Permissions = if (@import("builtin").os.tag == .windows) .default_file else .fromMode(0o600);
const offsite = @import("../cluster/offsite.zig");
const manifest = @import("manifest.zig");
const filestore = @import("filestore.zig");
const Allocator = std.mem.Allocator;
const Cid = [32]u8;
const Dir = std.Io.Dir;

/// Reserved in the destination: no restored path may start with it.
pub const job_dir = ".nomadfs-restore";
const job_file = "job.json";
const plan_file = "plan.bin";
const done_file = "done.log";
const tmp_suffix = ".tmp";
const max_job = 64 * 1024;
const max_plan = 1 << 30;
const plan_magic = "NFRPLAN2";
/// BLAKE3 of the bytes a finished file was written with.
const Digest = [32]u8;
const Blake3 = std.crypto.hash.Blake3;
const max_done = 512 * 1024 * 1024;
/// The finished-files list is synced after this many files.
const sync_every = 64;
const max_stale = 100_000;
/// Times one call makes its plan again when a pack is gone.
const max_replans = 2;

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
    version: u32 = 4,
    /// 32 hex digits: names the job's pin in the bucket.
    id: []const u8 = "",
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

/// One version per path out of the history, whose entries are intervals:
/// the stretch of runs a version was seen in. At a time, the interval that
/// holds it wins, else the last one that began before it (the file was
/// deleted, or changed between two runs); one that began later did not
/// exist yet. Otherwise the newest wins. Runs within one second are told
/// apart by their numbers; of two entries that still tie (a catalog from
/// before the numbers), the one the history lists later wins.
pub fn pick(a: Allocator, versions: []const offsite.File, version: Version) ![]const offsite.File {
    var chosen: std.StringArrayHashMapUnmanaged(offsite.File) = .empty;
    for (versions) |file| {
        switch (version) {
            .latest => {},
            .at => |time| if (file.first_seen > time) continue,
            .cid => |cid| if (!std.mem.eql(u8, &cid, &file.cid)) continue,
        }
        const slot = try chosen.getOrPut(a, file.path);
        if (!slot.found_existing or !newer(slot.value_ptr.*, file, version)) slot.value_ptr.* = file;
    }
    return chosen.values();
}

fn newer(x: offsite.File, y: offsite.File, version: Version) bool {
    const by_first = version == .at;
    // Two intervals can hold a time only at a shared end: the later one wins.
    const hx: u64 = if (by_first) @intFromBool(x.last_seen >= version.at) else 0;
    const hy: u64 = if (by_first) @intFromBool(y.last_seen >= version.at) else 0;
    // Each time with the number of its run: (time, run) orders the runs.
    const kx = if (by_first) [5]u64{ hx, x.first_seen, x.first_run, x.last_seen, x.last_run } else [5]u64{ 0, x.last_seen, x.last_run, x.first_seen, x.first_run };
    const ky = if (by_first) [5]u64{ hy, y.first_seen, y.first_run, y.last_seen, y.last_run } else [5]u64{ 0, y.last_seen, y.last_run, y.first_seen, y.first_run };
    return std.mem.order(u64, &kx, &ky) == .gt;
}

/// True for a path the restore keeps for its own files.
fn reserved(path: []const u8) bool {
    return offsite.under(path, job_dir);
}

/// The files the request names, checked: every path is a valid swarm path
/// and none collides with the job directory.
fn select(a: Allocator, service: *offsite.Service, request: Request) ![]const offsite.File {
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
        if (create) dir.createDir(io, part, private_dir) catch |err| if (err != error.PathAlreadyExists) return err;
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
    const file = filestore.openNoFollow(io, dir, name, .read_only) catch |err| switch (err) {
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

/// Writes `bytes` to `name` in the job directory: a new temporary file,
/// synced, then renamed.
fn writeWhole(io: std.Io, dir: Dir, prefix: []const u8, name: []const u8, bytes: []const u8) !void {
    var buf: [64]u8 = undefined;
    const tmp = try tmpName(prefix, &buf);
    errdefer dir.deleteFile(io, tmp) catch {};
    {
        const out = try dir.createFile(io, tmp, .{ .exclusive = true, .permissions = private_file });
        defer out.close(io);
        try out.writePositionalAll(io, bytes, 0);
        try out.sync(io);
    }
    try dir.rename(tmp, dir, name, io);
}

/// The digest of a regular file of exactly `size` bytes, read without
/// following a link; null when what is there is anything else.
fn digestOf(io: std.Io, dir: Dir, name: []const u8, size: u64) !?Digest {
    const st = dir.statFile(io, name, .{ .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    if (st.kind != .file or st.size != size) return null;
    const file = filestore.openNoFollow(io, dir, name, .read_only) catch |err| switch (err) {
        error.FileNotFound, error.SymLinkLoop => return null,
        else => return err,
    };
    defer file.close(io);
    if ((try file.stat(io)).kind != .file) return null;
    var hasher = Blake3.init(.{});
    var buf: [64 * 1024]u8 = undefined;
    var offset: u64 = 0;
    while (offset < size) {
        const got = try file.readPositionalAll(io, buf[0..@intCast(@min(buf.len, size - offset))], offset);
        if (got == 0) return null;
        hasher.update(buf[0..got]);
        offset += got;
    }
    var digest: Digest = undefined;
    hasher.final(&digest);
    return digest;
}

fn putInt(a: Allocator, out: *std.ArrayList(u8), comptime T: type, value: T) !void {
    var buf: [@sizeOf(T)]u8 = undefined;
    std.mem.writeInt(T, &buf, value, .little);
    try out.appendSlice(a, &buf);
}

/// Reads a stored plan; anything that does not fit is an invalid job.
const Cursor = struct {
    bytes: []const u8,
    at: usize = 0,
    fn take(self: *Cursor, len: usize) ![]const u8 {
        if (self.bytes.len - self.at < len) return error.InvalidRestoreJob;
        defer self.at += len;
        return self.bytes[self.at..][0..len];
    }
    fn int(self: *Cursor, comptime T: type) !T {
        return std.mem.readInt(T, (try self.take(@sizeOf(T)))[0..@sizeOf(T)], .little);
    }
    /// A count of records of at least `each` bytes: never more than fit.
    fn count(self: *Cursor, each: usize) !usize {
        const n = try self.int(u32);
        if (n > (self.bytes.len - self.at) / each) return error.InvalidRestoreJob;
        return n;
    }
};

/// What a job restores and where every block of it is, fixed when the job
/// starts and kept in the job directory. `packs`: each pack the job reads
/// with the class it was uploaded with (null: the head had no record).
const Plan = struct {
    files: []const offsite.File = &.{},
    packs: std.AutoArrayHashMapUnmanaged([16]u8, ?offsite.Class) = .empty,
    blocks: std.AutoArrayHashMapUnmanaged(Cid, Block) = .empty,
    /// Every file an earlier plan of this job had and the backup no longer
    /// holds: purged since the job began. Kept for as long as the job, in
    /// the same file as the plan, so no result ever misses one.
    omitted: []const offsite.Version = &.{},

    const Block = struct { pack: u32, offset: u64, length: u32 };

    fn add(self: *Plan, a: Allocator, cid: Cid, at: offsite.Location, class: ?offsite.Class) !void {
        const pack = try self.packs.getOrPut(a, at.pack_id);
        if (!pack.found_existing) pack.value_ptr.* = class;
        try self.blocks.put(a, cid, .{ .pack = @intCast(pack.index), .offset = at.offset, .length = at.length });
    }
    /// True when the committed index has every block of the file.
    fn held(service: *offsite.Service, file: offsite.File) bool {
        for (file.blocks) |cid| _ = service.locate(cid) catch return false;
        return true;
    }
    fn addHeld(self: *Plan, a: Allocator, service: *offsite.Service, file: offsite.File) !void {
        for (file.blocks) |cid| {
            const at = try service.locate(cid);
            try self.add(a, cid, at, service.recordedClass(at.pack_id));
        }
    }
    /// The plan of a new job: where the committed index has every block.
    fn build(a: Allocator, service: *offsite.Service, files: []const offsite.File) !Plan {
        var self: Plan = .{ .files = files };
        for (files) |file| try self.addHeld(a, service, file);
        return self;
    }
    /// `old` planned again from the committed head, which never fails: a
    /// file the head holds is read where its blocks are now, whether it was
    /// written already or not. One it no longer holds was purged: when its
    /// output is intact (`intact`, checked by digest) it stays, with the
    /// places `old` had and nothing left to read; else it joins `omitted`.
    fn again(a: Allocator, service: *offsite.Service, old: *const Plan, intact: *const Done) !Plan {
        var self: Plan = .{};
        var planned: std.ArrayList(offsite.File) = .empty;
        var omitted: std.ArrayList(offsite.Version) = .empty;
        try omitted.appendSlice(a, old.omitted);
        for (old.files) |file| {
            if (held(service, file)) {
                try self.addHeld(a, service, file);
            } else if (intact.contains(file.path)) {
                for (file.blocks) |cid| {
                    const block = old.blocks.get(cid) orelse return error.InvalidRestoreJob;
                    try self.add(a, cid, .{ .pack_id = old.packs.keys()[block.pack], .offset = block.offset, .length = block.length }, old.packs.values()[block.pack]);
                }
            } else {
                try omitted.append(a, .{ .path = file.path, .cid = file.cid });
                continue;
            }
            try planned.append(a, file);
        }
        self.files = planned.items;
        self.omitted = omitted.items;
        return self;
    }
    fn find(ctx: *anyopaque, cid: Cid) ?offsite.Location {
        const self: *const Plan = @ptrCast(@alignCast(ctx));
        const block = self.blocks.get(cid) orelse return null;
        return .{ .pack_id = self.packs.keys()[block.pack], .offset = block.offset, .length = block.length };
    }
    fn locator(self: *Plan) offsite.Locator {
        return .{ .ctx = self, .findFn = find };
    }
    fn encode(self: *const Plan, a: Allocator) ![]const u8 {
        var out: std.ArrayList(u8) = .empty;
        try out.appendSlice(a, plan_magic);
        try putInt(a, &out, u32, @intCast(self.packs.count()));
        for (self.packs.keys(), self.packs.values()) |id, class| {
            try out.appendSlice(a, &id);
            try out.append(a, if (class) |c| @as(u8, @intFromEnum(c)) + 1 else 0);
        }
        try putInt(a, &out, u32, @intCast(self.blocks.count()));
        for (self.blocks.keys(), self.blocks.values()) |cid, block| {
            try out.appendSlice(a, &cid);
            try putInt(a, &out, u32, block.pack);
            try putInt(a, &out, u64, block.offset);
            try putInt(a, &out, u32, block.length);
        }
        try putInt(a, &out, u32, @intCast(self.files.len));
        for (self.files) |file| {
            try out.append(a, @intFromBool(file.directory));
            try out.appendSlice(a, &file.cid);
            try putInt(a, &out, u64, file.size);
            try putInt(a, &out, u64, file.mtime);
            try putInt(a, &out, u32, @intCast(file.path.len));
            try out.appendSlice(a, file.path);
            try putInt(a, &out, u32, @intCast(file.blocks.len));
            for (file.blocks) |cid| try putInt(a, &out, u32, @intCast(self.blocks.getIndex(cid).?));
        }
        try putInt(a, &out, u32, @intCast(self.omitted.len));
        for (self.omitted) |gone| {
            try out.appendSlice(a, &gone.cid);
            try putInt(a, &out, u32, @intCast(gone.path.len));
            try out.appendSlice(a, gone.path);
        }
        if (out.items.len > max_plan) return error.RestoreJobTooLarge;
        return out.items;
    }
    /// The job directory is not trusted more than a snapshot: every path is
    /// checked again before anything is written.
    fn decode(a: Allocator, bytes: []const u8) !Plan {
        var in: Cursor = .{ .bytes = bytes };
        if (!std.mem.eql(u8, try in.take(plan_magic.len), plan_magic)) return error.InvalidRestoreJob;
        var self: Plan = .{};
        for (0..try in.count(17)) |_| {
            const id = (try in.take(16))[0..16].*;
            const tag = try in.int(u8);
            const class: ?offsite.Class = if (tag == 0) null else std.enums.fromInt(offsite.Class, tag - 1) orelse return error.InvalidRestoreJob;
            try self.packs.put(a, id, class);
        }
        for (0..try in.count(48)) |_| {
            const cid = (try in.take(32))[0..32].*;
            const block: Block = .{ .pack = try in.int(u32), .offset = try in.int(u64), .length = try in.int(u32) };
            if (block.pack >= self.packs.count()) return error.InvalidRestoreJob;
            try self.blocks.put(a, cid, block);
        }
        const files = try a.alloc(offsite.File, try in.count(57));
        if (files.len > manifest.max_entries) return error.InvalidRestoreJob;
        for (files) |*file| {
            const directory = (try in.int(u8)) != 0;
            const cid = (try in.take(32))[0..32].*;
            const size = try in.int(u64);
            const mtime = try in.int(u64);
            const path = try in.take(try in.int(u32));
            const blocks = try a.alloc(Cid, try in.count(4));
            for (blocks) |*cid_out| {
                const index = try in.int(u32);
                if (index >= self.blocks.count()) return error.InvalidRestoreJob;
                cid_out.* = self.blocks.keys()[index];
            }
            if (!manifest.validPath(path) or reserved(path)) return error.InvalidRestoreJob;
            file.* = .{ .path = path, .cid = cid, .size = size, .mtime = mtime, .blocks = blocks, .directory = directory };
        }
        const omitted = try a.alloc(offsite.Version, try in.count(36));
        if (omitted.len > manifest.max_entries) return error.InvalidRestoreJob;
        for (omitted) |*gone| {
            const cid = (try in.take(32))[0..32].*;
            const path = try in.take(try in.int(u32));
            if (!manifest.validPath(path)) return error.InvalidRestoreJob;
            gone.* = .{ .path = path, .cid = cid };
        }
        if (in.at != bytes.len) return error.InvalidRestoreJob;
        self.files = files;
        self.omitted = omitted;
        return self;
    }
};

/// Finished files: path to the content it is and the bytes it was written with.
const Finished = struct { cid: Cid, digest: Digest };
const Done = std.StringHashMapUnmanaged(Finished);
/// One line of the finished-files list.
fn doneLine(a: Allocator, path: []const u8, entry: Finished) ![]const u8 {
    const quoted = try std.json.Stringify.valueAlloc(a, path, .{});
    return std.fmt.allocPrint(a, "{s} {s} {s}\n", .{ std.fmt.bytesToHex(entry.cid, .lower), std.fmt.bytesToHex(entry.digest, .lower), quoted });
}

/// The state of one restore into one destination.
const Session = struct {
    a: Allocator,
    io: std.Io,
    destination: Dir,
    dir: Dir,
    /// True when an earlier call left this job: files in the way are its own.
    resumed: bool = false,
    id: [16]u8 = undefined,
    /// When the job began: its pin protects nothing for ever after that.
    created: u64 = 0,
    plan: Plan = .{},
    /// The files whose output is in place and intact: recorded by an earlier
    /// pass and checked by digest when this call began, or written by it.
    done: Done = .empty,
    log: std.Io.File,
    log_end: u64 = 0,
    unsynced: usize = 0,

    /// Continues the job the destination holds, from its own plan, or starts
    /// one: only a new job reads the snapshot or the history and the index.
    fn open(a: Allocator, io: std.Io, destination: Dir, service: *offsite.Service, request: Request) !Session {
        const existed = try exists(io, destination, job_dir);
        // An exclusive create never follows a link; an existing entry must
        // be a real directory (opened without following a link).
        if (!existed) try destination.createDir(io, job_dir, private_dir);
        errdefer if (!existed) destination.deleteTree(io, job_dir) catch {};
        var dir = try destination.openDir(io, job_dir, .{ .follow_symlinks = false, .iterate = true });
        errdefer dir.close(io);
        if (existed) try sweep(a, io, dir);
        var self: Session = .{ .a = a, .io = io, .destination = destination, .dir = dir, .log = undefined };
        var job: Job = .{ .source = try describe(a, request.from), .history = request.from == .history, .path = request.path, .tier = request.tier, .requested = service.now() };
        if (try readPlain(a, io, dir, job_file, max_job)) |bytes| {
            const old = std.json.parseFromSliceLeaky(Job, a, bytes, .{ .ignore_unknown_fields = true }) catch return error.InvalidRestoreJob;
            const same_path = if (old.path) |p| job.path != null and std.mem.eql(u8, p, job.path.?) else job.path == null;
            if (old.version != job.version or old.history != job.history or !std.mem.eql(u8, old.source, job.source) or !same_path) return error.RestoreJobMismatch;
            if (old.id.len != 32) return error.InvalidRestoreJob;
            _ = std.fmt.hexToBytes(&self.id, old.id) catch return error.InvalidRestoreJob;
            self.plan = try Plan.decode(a, (try readPlain(a, io, dir, plan_file, max_plan)) orelse return error.InvalidRestoreJob);
            self.created = old.requested;
            self.resumed = true;
        } else {
            // A new job: nothing it will write may be there already, so
            // whatever a later pass finds at those paths is this job's.
            const files = try select(a, service, request);
            self.plan = try Plan.build(a, service, files);
            self.created = job.requested;
            for (files) |file| if (!file.directory and try exists(io, destination, file.path)) return error.PathAlreadyExists;
            try std.Io.Threaded.global_single_threaded.io().randomSecure(&self.id);
            job.id = try a.dupe(u8, &std.fmt.bytesToHex(self.id, .lower));
            // The plan first: a job file always has its plan.
            try writeWhole(io, dir, "plan", plan_file, try self.plan.encode(a));
            try writeWhole(io, dir, "job", job_file, try std.json.Stringify.valueAlloc(a, job, .{}));
        }
        const kept = if (self.resumed) (try readPlain(a, io, dir, done_file, max_done)) orelse "" else "";
        // Only whole lines count: a crash can cut the last one.
        var lines = std.mem.splitScalar(u8, kept, '\n');
        while (lines.next()) |line| {
            if (lines.peek() == null) break;
            self.log_end += line.len + 1;
            if (line.len < 132 or line[64] != ' ' or line[129] != ' ') continue;
            var cid: Cid = undefined;
            var digest: Digest = undefined;
            _ = std.fmt.hexToBytes(&cid, line[0..64]) catch continue;
            _ = std.fmt.hexToBytes(&digest, line[65..129]) catch continue;
            const path = std.json.parseFromSliceLeaky([]const u8, a, line[130..], .{}) catch continue;
            try self.done.put(a, path, .{ .cid = cid, .digest = digest });
        }
        // Before anything is planned or pinned: a record whose output is no
        // longer the bytes written is no record.
        if (try self.verify()) |intact| {
            try writeWhole(io, dir, "done", done_file, intact);
            self.log_end = intact.len;
        }
        self.log = dir.createFile(io, done_file, .{ .exclusive = true, .permissions = private_file }) catch |err| switch (err) {
            error.PathAlreadyExists => try filestore.openNoFollow(io, dir, done_file, .read_write),
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
    /// Checks every recorded output against the digest it was written with
    /// (a size and a log line prove nothing) and forgets the records that
    /// fail, or name no file of the plan. Returns the list without them when
    /// one went, for the caller to store; null when all hold.
    fn verify(self: *Session) !?[]const u8 {
        var intact: Done = .empty;
        var list: std.ArrayList(u8) = .empty;
        for (self.plan.files) |file| {
            if (file.directory) continue;
            const entry = self.done.get(file.path) orelse continue;
            if (!std.mem.eql(u8, &entry.cid, &file.cid)) continue;
            var parent = (try openBelow(self.io, self.destination, std.fs.path.dirname(file.path) orelse "", false)) orelse continue;
            defer parent.close(self.io);
            const digest = (try digestOf(self.io, parent, std.fs.path.basename(file.path), file.size)) orelse continue;
            if (!std.mem.eql(u8, &digest, &entry.digest)) continue;
            try intact.put(self.a, file.path, entry);
            try list.appendSlice(self.a, try doneLine(self.a, file.path, entry));
        }
        const all = intact.count() == self.done.count();
        self.done = intact;
        return if (all) null else list.items;
    }
    /// True when this file's output is in place and intact.
    fn finished(self: *Session, file: offsite.File) bool {
        const entry = self.done.get(file.path) orelse return false;
        return std.mem.eql(u8, &entry.cid, &file.cid);
    }
    fn record(self: *Session, file: offsite.File, digest: Digest) !void {
        const line = try doneLine(self.a, file.path, .{ .cid = file.cid, .digest = digest });
        try self.log.writePositionalAll(self.io, line, self.log_end);
        self.log_end += line.len;
        self.unsynced += 1;
        try self.done.put(self.a, file.path, .{ .cid = file.cid, .digest = digest });
        if (self.unsynced >= sync_every) try self.flush();
    }
    fn flush(self: *Session) !void {
        if (self.unsynced == 0) return;
        try self.log.sync(self.io);
        self.unsynced = 0;
    }
    /// Writes one file: a new temporary file in the job directory, synced,
    /// then renamed over whatever is at the final name (a link is replaced,
    /// never followed). The digest of the bytes written goes on record.
    fn write(self: *Session, service: *offsite.Service, parent: Dir, file: offsite.File) !void {
        const base = std.fs.path.basename(file.path);
        if (!self.resumed and try exists(self.io, parent, base)) return error.PathAlreadyExists;
        var buf: [64]u8 = undefined;
        const tmp = try tmpName("file", &buf);
        errdefer self.dir.deleteFile(self.io, tmp) catch {};
        var target: Output = .{ .io = self.io, .file = undefined, .hasher = Blake3.init(.{}) };
        {
            const out = try self.dir.createFile(self.io, tmp, .{ .exclusive = true, .permissions = private_file });
            defer out.close(self.io);
            target.file = out;
            try service.streamFile(file, self.plan.locator(), .{ .ctx = &target, .writeFn = Output.write });
            try out.sync(self.io);
        }
        try self.dir.rename(tmp, parent, base, self.io);
        var digest: Digest = undefined;
        target.hasher.final(&digest);
        try self.record(file, digest);
    }
    /// What the job's pin names: every pack of the plan, also those of the
    /// files already written, until the job has ended. An output found
    /// changed on a later pass is then written again from the same packs.
    fn pinned(self: *Session) []const [16]u8 {
        return self.plan.packs.keys();
    }
    /// True when every pack of the file can be read now; asks for the thaw
    /// of each archived one. Decided pack by pack, from the class each was
    /// uploaded with or what the bucket reports, never from today's settings.
    fn ready(self: *Session, service: *offsite.Service, file: offsite.File, packs: *offsite.Packs, tier: offsite.Tier, result: *offsite.Restore) !bool {
        var all = true;
        for (file.blocks) |cid| {
            const block = self.plan.blocks.get(cid) orelse return error.InvalidRestoreJob;
            const id = self.plan.packs.keys()[block.pack];
            if (!(try service.packReady(id, self.plan.packs.values()[block.pack], packs, tier, result))) all = false;
        }
        return all;
    }
    /// A read was refused as archived: asks for the thaw of the file's
    /// packs. True when one is thawing now, so the file waits for a later pass.
    fn refused(self: *Session, service: *offsite.Service, file: offsite.File, packs: *offsite.Packs, tier: offsite.Tier, result: *offsite.Restore) !bool {
        var thawing = false;
        for (file.blocks) |cid| {
            const block = self.plan.blocks.get(cid) orelse return error.InvalidRestoreJob;
            if (!(try service.packRefused(self.plan.packs.keys()[block.pack], packs, tier, result))) thawing = true;
        }
        return thawing;
    }
    /// One pass over the plan: the files already written and intact are
    /// counted, the ones whose packs are readable are written, the others
    /// wait for their thaw.
    fn pass(self: *Session, gpa: Allocator, service: *offsite.Service, tier: offsite.Tier) !offsite.Restore {
        var result: offsite.Restore = .{};
        var packs: offsite.Packs = .init(gpa);
        defer packs.deinit();
        for (self.plan.files) |file| {
            if (file.directory) {
                var made = (try openBelow(self.io, self.destination, file.path, true)).?;
                made.close(self.io);
                continue;
            }
            if (self.finished(file)) {
                result.files += 1;
                continue;
            }
            if (!(try self.ready(service, file, &packs, tier, &result))) continue;
            var parent = (try openBelow(self.io, self.destination, std.fs.path.dirname(file.path) orelse "", true)).?;
            defer parent.close(self.io);
            self.write(service, parent, file) catch |err| {
                self.flush() catch {};
                if (err == error.InvalidObjectState and try self.refused(service, file, &packs, tier, &result)) continue;
                return err;
            };
            result.files += 1;
        }
        try self.flush();
        return result;
    }
    /// A pack of the plan is gone from the bucket: the plan is made again
    /// from the current head, where the blocks are now. A file purged since
    /// leaves it and is named in the new plan, stored with it in one write.
    fn replan(self: *Session, service: *offsite.Service) !void {
        try self.flush();
        try service.refresh();
        const old = self.plan;
        self.plan = try Plan.again(self.a, service, &old, &self.done);
        try writeWhole(self.io, self.dir, "plan", plan_file, try self.plan.encode(self.a));
    }
    /// The files the job left out since it began, for the caller to free.
    fn omitted(self: *Session, a: Allocator) ![]const offsite.Version {
        const list = try a.alloc(offsite.Version, self.plan.omitted.len);
        var copied: usize = 0;
        errdefer {
            for (list[0..copied]) |v| a.free(v.path);
            a.free(list);
        }
        for (self.plan.omitted, list) |gone, *out| {
            out.* = .{ .path = try a.dupe(u8, gone.path), .cid = gone.cid };
            copied += 1;
        }
        return list;
    }
};

/// Receives a file's bytes in order and hashes them on the way to the disk.
const Output = struct {
    io: std.Io,
    file: std.Io.File,
    hasher: Blake3,
    written: u64 = 0,
    fn write(ctx: *anyopaque, offset: u64, bytes: []const u8) anyerror!void {
        const self: *Output = @ptrCast(@alignCast(ctx));
        if (offset != self.written) return error.SizeMismatch;
        try self.file.writePositionalAll(self.io, bytes, offset);
        self.hasher.update(bytes);
        self.written += bytes.len;
    }
};

/// Restores through an already-open directory capability. A new restore
/// refuses a destination that already has one of its files, and writes its
/// plan into the job directory: the files and where each of their blocks is.
/// A resumed one first checks every recorded output by digest and forgets
/// the records that fail. Every pass pins all packs of the plan (the backup
/// keeps them while it repacks and prunes), asks for the thaw of each
/// archived one, writes the files whose packs are readable and leaves the
/// job while packs are thawing. The same call, repeated, continues from the
/// plan alone and ends when no file is left. If a pack is gone all the same
/// (the pin ran out, reached its limit or lost a race with a run), the plan
/// is made again from the current head. The result of every call names the
/// files left out since the job began (`omitted`, freed with `deinit`); the
/// job directory goes only with a result that carries them.
pub fn restore(a: Allocator, io: std.Io, service: *offsite.Service, request: Request, destination: Dir) !offsite.Restore {
    var arena_state: std.heap.ArenaAllocator = .init(a);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    if (request.path) |p| if (!manifest.validPath(p)) return error.InvalidPath;
    var session = try Session.open(arena, io, destination, service, request);
    var open = true;
    defer if (open) session.close();
    var result: offsite.Restore = .{};
    for (0..max_replans + 1) |round| {
        // Credentials that may only read cannot pin: the restore goes on and
        // plans again should a pack go.
        service.pin(session.id, session.pinned(), session.created) catch |err| if (err != error.AccessDenied) return err;
        result = session.pass(a, service, request.tier) catch |err| switch (err) {
            error.PackMissing, error.NotFound => {
                if (round == max_replans) return err;
                try session.replan(service);
                continue;
            },
            else => return err,
        };
        break;
    }
    result.omitted = try session.omitted(a);
    errdefer result.deinit(a);
    result.purged_files = result.omitted.len;
    if (result.thawing_packs > 0) return result;
    service.unpin(session.id) catch {};
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
    // One content came back after another: its two stretches are two entries,
    // and a time picks the stretch that holds it (or the last one before it).
    const reverted = [_]offsite.File{
        .{ .path = "a", .cid = [_]u8{1} ** 32, .size = 1, .blocks = &.{}, .first_seen = 10, .last_seen = 20 },
        .{ .path = "a", .cid = [_]u8{2} ** 32, .size = 2, .blocks = &.{}, .first_seen = 30, .last_seen = 40 },
        .{ .path = "a", .cid = [_]u8{1} ** 32, .size = 1, .blocks = &.{}, .first_seen = 50, .last_seen = 60 },
    };
    for ([_][2]u64{ .{ 10, 1 }, .{ 25, 1 }, .{ 30, 2 }, .{ 40, 2 }, .{ 45, 2 }, .{ 50, 1 }, .{ 60, 1 }, .{ 99, 1 } }) |case| {
        const at = try pick(arena.allocator(), &reverted, .{ .at = case[0] });
        try std.testing.expectEqual(case[1], at[0].size);
    }
    try std.testing.expectEqual(@as(usize, 0), (try pick(arena.allocator(), &reverted, .{ .at = 9 })).len);
    try std.testing.expectEqual(@as(u64, 60), (try pick(arena.allocator(), &reverted, .latest))[0].last_seen);
    // A catalog written before intervals were kept merged the two stretches:
    // the version seen in between still wins at its own time.
    const merged = [_]offsite.File{
        .{ .path = "a", .cid = [_]u8{1} ** 32, .size = 1, .blocks = &.{}, .first_seen = 10, .last_seen = 60 },
        .{ .path = "a", .cid = [_]u8{2} ** 32, .size = 2, .blocks = &.{}, .first_seen = 30, .last_seen = 40 },
    };
    try std.testing.expectEqual(@as(u64, 2), (try pick(arena.allocator(), &merged, .{ .at = 35 }))[0].size);
    try std.testing.expectEqual(@as(u64, 1), (try pick(arena.allocator(), &merged, .{ .at = 60 }))[0].size);
    // Runs within one second: the number of the run decides, also at a time.
    const same = [_]offsite.File{
        .{ .path = "a", .cid = [_]u8{2} ** 32, .size = 2, .blocks = &.{}, .first_seen = 10, .last_seen = 10, .first_run = 8, .last_run = 8 },
        .{ .path = "a", .cid = [_]u8{1} ** 32, .size = 1, .blocks = &.{}, .first_seen = 10, .last_seen = 10, .first_run = 7, .last_run = 7 },
        .{ .path = "a", .cid = [_]u8{3} ** 32, .size = 3, .blocks = &.{}, .first_seen = 5, .last_seen = 10, .first_run = 3, .last_run = 6, .mtime = 99 },
    };
    try std.testing.expectEqual(@as(u64, 2), (try pick(arena.allocator(), &same, .latest))[0].size);
    try std.testing.expectEqual(@as(u64, 2), (try pick(arena.allocator(), &same, .{ .at = 10 }))[0].size);
    try std.testing.expectEqual(@as(u64, 3), (try pick(arena.allocator(), &same, .{ .at = 9 }))[0].size);
    // No numbers (an older catalog) and the same times: the later entry.
    const unnumbered = [_]offsite.File{
        .{ .path = "a", .cid = [_]u8{1} ** 32, .size = 1, .blocks = &.{}, .first_seen = 10, .last_seen = 10, .mtime = 50 },
        .{ .path = "a", .cid = [_]u8{2} ** 32, .size = 2, .blocks = &.{}, .first_seen = 10, .last_seen = 10, .mtime = 40 },
    };
    try std.testing.expectEqual(@as(u64, 2), (try pick(arena.allocator(), &unnumbered, .latest))[0].size);
    try std.testing.expect(reserved(".nomadfs-restore/job.json") and reserved(".nomadfs-restore") and !reserved(".nomadfs-restore.json"));
}
