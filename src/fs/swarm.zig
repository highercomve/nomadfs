//! The swarm folder: one folder every device in the swarm can read and
//! write. Its listing is a replicated manifest (manifest.zig) that each
//! device keeps on disk and merges with its peers' every few seconds; file
//! bytes stay where they were added and travel only when someone opens
//! them (from the device that added the file, then anyone who cached it).
//! A backup device (`swarm_backup`) copies every file as it appears, so the
//! folder stays readable while the device that added a file is offline.

const std = @import("std");
const sync = @import("../sync.zig");
const cluster = @import("../cluster/mod.zig");
const device = @import("../device/mod.zig");
const storage = @import("../storage/mod.zig");
const NodeID = @import("../net/id.zig").NodeID;
const ShareSource = cluster.ShareSource;
const manifest_mod = @import("manifest.zig");
const remote_mod = @import("remote.zig");
const tree = @import("tree.zig");
const readahead_mod = @import("readahead.zig");

pub const Manifest = manifest_mod.Manifest;
pub const Entry = manifest_mod.Entry;
pub const Kind = manifest_mod.Kind;

pub const SwarmFolder = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    store: *storage.engine.StorageEngine,
    block_manager: ?*cluster.BlockManager = null,
    /// Fetches ahead of sequential reads; without it reads go block by block.
    read_ahead: ?*readahead_mod.ReadAhead = null,
    /// This device as authors are recorded: its transport node ID, the key
    /// peers dial to fetch what it added.
    self_id: NodeID,
    self_name: []u8,
    /// Where the manifest is kept between runs.
    file_path: []u8,
    /// Guards `manifest`, `dirty` and the sync counters.
    mutex: sync.Mutex = .{},
    /// Edited since the last write (flushSave).
    dirty: bool = false,
    /// When the manifest was last written (monotonic ms); writes are at
    /// most one a second, so copying many files doesn't rewrite it each.
    written_ms: i64 = 0,
    /// Serialises manifest writes; taken before `mutex`, never inside it.
    save_mutex: sync.Mutex = .{},
    manifest: Manifest,
    /// The manifest file was missing when the folder was opened.
    manifest_missing: bool = false,
    /// The clock file (`<manifest>.clock`) was found. It holds a bound above
    /// every clock value this device has used, so the clock never goes back
    /// even when the manifest file is lost or older than what peers pulled.
    clock_found: bool = false,
    /// Written ahead: the clock may be used up to here without a write.
    clock_reserved: u64 = 0,
    /// Without both files the clock restarted from zero, and an edit made now
    /// could look older than versions the swarm already holds. Local edits
    /// wait (error.NotSynced) until a sync round merged a reached peer's
    /// manifest, or `alone_grace_ms` passed (a device truly on its own).
    awaiting_pull: bool = false,
    awaiting_since_ms: i64 = 0,
    alone_grace_ms: i64 = 60 * 1000,
    last_sync: u64 = 0,
    peers_synced: u32 = 0,
    peers_failed: u32 = 0,
    sync_interval_ns: u64 = 10 * std.time.ns_per_s,
    /// Serialises sync rounds (the loop and syncNow).
    sync_mutex: sync.Mutex = .{},
    /// Run after each sync round on the folder's thread (backed-up shares
    /// coming in, the notes' legacy renames); added with addAfterSyncHook.
    after_sync: HookList = .{},
    /// Run when a sync round merged something from a peer, on the same
    /// thread; added with addChangeHook.
    on_change: HookList = .{},
    /// The background thread (sync.Worker); its loop watches worker.running.
    worker: sync.Worker = .{},

    /// Backup: a copy of every live file in this device's block store.
    backup_enabled: std.atomic.Value(bool) = .init(false),
    /// Serialises setBackup (the app's switch, shutdown).
    backup_ctl: sync.Mutex = .{},
    /// Copies this device keeps are made by the keeper (cluster/keeper.zig),
    /// which asks `wants` what to hold; null: nobody keeps copies here.
    keeper: ?*cluster.keeper.Keeper = null,
    /// Who keeps which file besides backup devices (cluster/placement.zig).
    placement: ?Placement = null,
    /// Guards `backed_up` and the backup counters.
    backup_mutex: sync.Mutex = .{},
    /// Root CIDs of files copied here in full, kept in `<manifest>.backup`
    /// so a restart doesn't check them all again.
    backed_up: std.AutoHashMapUnmanaged([32]u8, void) = .empty,
    backed_up_loaded: bool = false,
    /// Files no reachable device could serve in the last round.
    backup_unreachable: usize = 0,
    backup_last_round: u64 = 0,
    /// Failures in the round under way, and copies since the list was saved.
    round_failed: usize = 0,
    unsaved: usize = 0,
    saved_at: i64 = 0,
    /// Keeper rounds started (counted in `wants`); a root counts once a round.
    want_round: u64 = 0,
    /// Files whose data the keeper found on no device (see `lostRoot`); a
    /// small table, guarded by `backup_mutex`.
    lost: [max_lost]Lost = undefined,
    lost_count: usize = 0,
    /// A backup device removes an entry whose data is on no device after
    /// this many rounds that found it lost, over at least `lost_span_ms`.
    lost_rounds: u8 = 3,
    lost_span_ms: i64 = 10 * std.time.ms_per_min,

    const max_lost = 64;
    const Lost = struct { root: [32]u8, version: manifest_mod.Version, first_ms: i64, count: u8, round: u64 };

    pub fn create(allocator: std.mem.Allocator, io: std.Io, store: *storage.engine.StorageEngine, self_id: NodeID, self_name: []const u8, file_path: []const u8) !*SwarmFolder {
        const self = try allocator.create(SwarmFolder);
        errdefer allocator.destroy(self);
        self.* = .{
            .allocator = allocator,
            .io = io,
            .store = store,
            .self_id = self_id,
            .self_name = try allocator.dupe(u8, self_name),
            .file_path = undefined,
            .manifest = Manifest.init(allocator),
        };
        errdefer allocator.free(self.self_name);
        self.file_path = try allocator.dupe(u8, file_path);
        errdefer allocator.free(self.file_path);
        errdefer self.manifest.deinit();
        self.cleanStaging();
        try self.load();
        self.loadClock();
        return self;
    }

    /// Clock values reserved ahead of use, and how close to the end of the
    /// reservation the next one is made (an operation edits many entries).
    const clock_block: u64 = 1 << 20;
    const clock_margin: u64 = 1 << 18;

    fn clockPath(self: *SwarmFolder) ![]u8 {
        return std.fmt.allocPrint(self.allocator, "{s}.clock", .{self.file_path});
    }

    /// The clock starts at max(saved bound, manifest's). A file that can't be
    /// read is moved aside and counts as missing.
    fn loadClock(self: *SwarmFolder) void {
        const path = self.clockPath() catch return;
        defer self.allocator.free(path);
        var buf: [32]u8 = undefined;
        const bytes = blk: {
            var file = std.Io.Dir.cwd().openFile(self.io, path, .{}) catch return;
            defer file.close(self.io);
            const n = file.readPositionalAll(self.io, &buf, 0) catch 0;
            break :blk buf[0..n];
        };
        const saved = std.fmt.parseInt(u64, std.mem.trim(u8, bytes, " \n"), 10) catch {
            const aside = std.fmt.allocPrint(self.allocator, "{s}.corrupt-{d}", .{ path, self.now() }) catch return;
            defer self.allocator.free(aside);
            std.Io.Dir.cwd().rename(path, std.Io.Dir.cwd(), aside, self.io) catch {};
            return;
        };
        self.clock_found = true;
        self.clock_reserved = saved;
        self.manifest.raiseClock(saved);
    }

    /// Caller holds `mutex`. Makes sure the clock can be used for a whole
    /// operation: writes a new bound, before any edit that uses it exists.
    fn reserveClockLocked(self: *SwarmFolder) !void {
        if (self.manifest.clock +| clock_margin <= self.clock_reserved) return;
        const bound = self.manifest.clock +| clock_block;
        const path = try self.clockPath();
        defer self.allocator.free(path);
        const tmp = try std.fmt.allocPrint(self.allocator, "{s}.tmp", .{path});
        defer self.allocator.free(tmp);
        var text: [24]u8 = undefined;
        const out = try std.fmt.bufPrint(&text, "{d}\n", .{bound});
        {
            var file = try std.Io.Dir.cwd().createFile(self.io, tmp, .{ .truncate = true });
            defer file.close(self.io);
            try file.writePositionalAll(self.io, out, 0);
        }
        try std.Io.Dir.cwd().rename(tmp, std.Io.Dir.cwd(), path, self.io);
        self.clock_reserved = bound;
    }

    pub fn destroy(self: *SwarmFolder) void {
        self.stop();
        self.writeIfDirty(true); // an edit still unwritten
        self.backup_enabled.store(false, .release);
        self.backed_up.deinit(self.allocator);
        self.manifest.deinit();
        self.allocator.free(self.self_name);
        self.allocator.free(self.file_path);
        self.allocator.destroy(self);
    }

    fn load(self: *SwarmFolder) !void {
        var file = std.Io.Dir.cwd().openFile(self.io, self.file_path, .{}) catch |err| switch (err) {
            error.FileNotFound => {
                self.manifest_missing = true;
                return;
            },
            else => return err,
        };
        defer file.close(self.io);
        const size = (try file.stat(self.io)).size;
        if (size > manifest_mod.max_bytes) {
            self.moveCorruptAside();
            return error.ManifestTooLarge;
        }
        const bytes = try self.allocator.alloc(u8, @intCast(size));
        defer self.allocator.free(bytes);
        if (try file.readPositionalAll(self.io, bytes, 0) != bytes.len) {
            self.moveCorruptAside();
            return error.InvalidManifest;
        }
        _ = self.manifest.mergeEncoded(bytes) catch |err| {
            self.moveCorruptAside();
            return err;
        };
    }

    fn moveCorruptAside(self: *SwarmFolder) void {
        const corrupt_path = std.fmt.allocPrint(self.allocator, "{s}.corrupt-{d}", .{ self.file_path, self.now() }) catch return;
        defer self.allocator.free(corrupt_path);
        std.Io.Dir.cwd().rename(self.file_path, std.Io.Dir.cwd(), corrupt_path, self.io) catch {};
    }

    /// Caller holds `mutex`. Marks the manifest for writing; flushSave,
    /// which the caller runs after unlocking (`defer self.flushSave()`
    /// before the lock), writes it.
    fn saveLocked(self: *SwarmFolder) !void {
        self.dirty = true;
    }

    /// Caller holds `mutex`. Local edits are refused while the folder waits
    /// for its first pull (see `awaiting_pull`).
    fn editAllowedLocked(self: *SwarmFolder) !void {
        if (self.awaitingLocked()) return error.NotSynced;
        try self.reserveClockLocked();
    }

    /// Caller holds `mutex`. Whether local edits must still wait for the
    /// first pull: a device that trusts no other device has nobody whose
    /// copy could hold its older versions, and one that waited
    /// `alone_grace_ms` without reaching anyone goes ahead on its own.
    fn awaitingLocked(self: *SwarmFolder) bool {
        if (!self.awaiting_pull) return false;
        if (self.nobodyToPullFrom() or sync.monotonicMillis() - self.awaiting_since_ms >= self.alone_grace_ms) {
            self.awaiting_pull = false;
            return false;
        }
        return true;
    }

    /// No other device is trusted (a first device, or one not paired yet).
    /// Without placement wired (tests), membership is unknown: keep waiting.
    fn nobodyToPullFrom(self: *const SwarmFolder) bool {
        const p = self.placement orelse return false;
        for (p.trust.list()) |e| {
            if (!std.mem.eql(u8, &e.device_id.bytes, &p.self_device.bytes)) return false;
        }
        return true;
    }

    /// Writes the manifest if it changed and the last write was a second
    /// ago or more; else the folder's thread writes it shortly (flushDue).
    fn flushSave(self: *SwarmFolder) void {
        self.writeIfDirty(false);
    }

    /// Writes an edited manifest now (shutdown), or when a second has
    /// passed since the last write. Encoded under `mutex`, written outside
    /// it, in order (`save_mutex`). A failed write is logged and retried
    /// on the next one.
    fn writeIfDirty(self: *SwarmFolder, now_or_never: bool) void {
        self.save_mutex.lock();
        defer self.save_mutex.unlock();
        const at = sync.monotonicMillis();
        const bytes = blk: {
            self.mutex.lock();
            defer self.mutex.unlock();
            if (!self.dirty) return;
            if (!now_or_never and at - self.written_ms < 1000) return;
            self.manifest.pruneTombstones(self.now());
            const b = self.manifest.encode(self.allocator) catch |err| {
                std.debug.print("swarm: encoding the manifest failed: {any}\n", .{err});
                return;
            };
            self.dirty = false;
            break :blk b;
        };
        defer self.allocator.free(bytes);
        self.written_ms = at;
        if (bytes.len > manifest_mod.max_bytes) {
            std.debug.print("swarm: the manifest is over {d} bytes; not saved\n", .{manifest_mod.max_bytes});
            return;
        }
        self.writeManifest(bytes) catch |err| {
            std.debug.print("swarm: saving the manifest failed: {any}\n", .{err});
            self.mutex.lock();
            defer self.mutex.unlock();
            self.dirty = true; // try again with the next write
        };
    }

    fn writeManifest(self: *SwarmFolder, bytes: []const u8) !void {
        const tmp = try std.fmt.allocPrint(self.allocator, "{s}.tmp", .{self.file_path});
        defer self.allocator.free(tmp);
        {
            var file = try std.Io.Dir.cwd().createFile(self.io, tmp, .{ .truncate = true });
            defer file.close(self.io);
            try file.writePositionalAll(self.io, bytes, 0);
        }
        try std.Io.Dir.cwd().rename(tmp, std.Io.Dir.cwd(), self.file_path, self.io);
    }

    /// Sets a live file's or folder's modified time (touch -d, cp -p, rsync
    /// -t through the mount): a new version, so it spreads like an edit.
    pub fn setMtime(self: *SwarmFolder, path: []const u8, mtime: u64) !void {
        defer self.flushSave(); // after the unlock: writes outside the lock
        self.mutex.lock();
        defer self.mutex.unlock();
        try self.editAllowedLocked();
        const e = self.manifest.get(path) orelse return error.FileNotFound;
        if (e.deleted) return error.FileNotFound;
        if (e.mtime == mtime) return;
        _ = try self.manifest.edit(path, .{ .kind = e.kind, .cid = e.cid, .size = e.size, .mtime = mtime }, self.self_id.bytes, self.self_name);
        try self.saveLocked();
    }

    fn secondsOf(t: std.Io.Timestamp) u64 {
        return @intCast(@max(0, @divFloor(t.nanoseconds, std.time.ns_per_s)));
    }

    fn now(self: *SwarmFolder) u64 {
        const t = std.Io.Timestamp.now(self.io, .real).nanoseconds;
        return @intCast(@max(0, @divFloor(t, std.time.ns_per_s)));
    }

    /// `a/b/c` as `a/b` and `c`; a top-level name has the parent "".
    pub fn splitParent(path: []const u8) struct { dir: []const u8, name: []const u8 } {
        const slash = std.mem.lastIndexOfScalar(u8, path, '/') orelse return .{ .dir = "", .name = path };
        return .{ .dir = path[0..slash], .name = path[slash + 1 ..] };
    }

    fn join(allocator: std.mem.Allocator, dir: []const u8, name: []const u8) ![]u8 {
        if (dir.len == 0) return allocator.dupe(u8, name);
        return std.fmt.allocPrint(allocator, "{s}/{s}", .{ dir, name });
    }

    // ---- Edits (this device) ----

    /// Adds (or replaces) `dir/name` with the contents of the local file
    /// at `local_path`. The bytes go into this device's block store. The
    /// file keeps its own modified time (`mtime` overrides it), so folders
    /// sort by when files changed, not when they were added.
    pub fn addFile(self: *SwarmFolder, dir: []const u8, name: []const u8, local_path: []const u8) !void {
        return self.addFileAt(dir, name, local_path, null);
    }

    pub fn addFileAt(self: *SwarmFolder, dir: []const u8, name: []const u8, local_path: []const u8, mtime: ?u64) !void {
        const path = try join(self.allocator, dir, name);
        defer self.allocator.free(path);
        if (!manifest_mod.validPath(path)) return error.InvalidPath;
        // Checked before the bytes are stored too, so a refusal leaves no
        // blocks behind (and again below, under the lock that edits).
        {
            self.mutex.lock();
            defer self.mutex.unlock();
            if (self.folderAtLocked(path)) return error.IsDirectory;
        }

        var file = try std.Io.Dir.cwd().openFile(self.io, local_path, .{});
        defer file.close(self.io);
        const modified = mtime orelse secondsOf((try file.stat(self.io)).mtime);
        var reader = FileReader{ .io = self.io, .file = file };
        var builder = storage.dag.DagBuilder{ .allocator = self.allocator, .store = self.store, .layout = .Balanced };
        const root = try builder.build(&reader);
        defer self.allocator.free(root);

        defer self.flushSave(); // after the unlock: writes outside the lock
        self.mutex.lock();
        defer self.mutex.unlock();
        try self.editAllowedLocked();
        // A file never replaces a folder: its contents would be left under a file.
        if (self.folderAtLocked(path)) return error.IsDirectory;
        _ = try self.manifest.edit(path, .{ .cid = root[0..32].*, .size = reader.offset, .mtime = modified }, self.self_id.bytes, self.self_name);
        try self.saveLocked();
        // The devices that keep copies pull it (their keepers), once their
        // manifest has it: nothing is pushed from here.
    }

    pub const PutResult = struct { cid: [32]u8, size: u64, mtime: u64 };

    /// Writes bytes at `path` if its current content still matches `base`
    /// (null: only if nothing is live there).
    pub fn putBytes(self: *SwarmFolder, path: []const u8, bytes: []const u8, base: ?[32]u8) !PutResult {
        if (!manifest_mod.validPath(path)) return error.InvalidPath;
        if (bytes.len > 8 * 1024 * 1024) return error.FileTooLarge;
        // Refused before any block is built: a stale save, a taken name or a
        // gated folder leaves nothing in the store. (Checked again below,
        // under the lock that edits: a race can still lose after building.)
        {
            self.mutex.lock();
            defer self.mutex.unlock();
            if (self.awaitingLocked()) return error.NotSynced;
            if (self.folderAtLocked(path)) return error.IsDirectory;
            try self.checkBaseLocked(path, base);
        }
        var reader = storage.chunker.SliceReader{ .buffer = bytes };
        var builder = storage.dag.DagBuilder{ .allocator = self.allocator, .store = self.store, .layout = .Balanced };
        const root = try builder.build(&reader);
        defer self.allocator.free(root);
        const cid: [32]u8 = root[0..32].*;
        defer self.flushSave();
        self.mutex.lock();
        defer self.mutex.unlock();
        try self.editAllowedLocked();
        if (self.folderAtLocked(path)) return error.IsDirectory;
        try self.checkBaseLocked(path, base);
        const mtime = self.now();
        _ = try self.manifest.edit(path, .{ .cid = cid, .size = bytes.len, .mtime = mtime }, self.self_id.bytes, self.self_name);
        try self.saveLocked();
        return .{ .cid = cid, .size = bytes.len, .mtime = mtime };
    }

    /// Caller holds `mutex`. error.Changed unless the live file at `path` is
    /// `base` (null: nothing is live there).
    fn checkBaseLocked(self: *SwarmFolder, path: []const u8, base: ?[32]u8) !void {
        const old = self.manifest.get(path);
        if (base) |expected| {
            if (old == null or old.?.deleted or old.?.kind != .file or !std.mem.eql(u8, &old.?.cid, &expected)) return error.Changed;
        } else if (old != null and !old.?.deleted) return error.Changed;
    }

    /// Moves a file only while its content still matches `base`.
    pub fn moveIfUnchanged(self: *SwarmFolder, path: []const u8, new_path: []const u8, base: [32]u8) !void {
        if (!manifest_mod.validPath(path) or !manifest_mod.validPath(new_path)) return error.InvalidPath;
        defer self.flushSave();
        self.mutex.lock();
        defer self.mutex.unlock();
        try self.editAllowedLocked();
        const entry = self.manifest.get(path) orelse return error.FileNotFound;
        if (entry.deleted or entry.kind != .file) return error.FileNotFound;
        if (!std.mem.eql(u8, &entry.cid, &base)) return error.Changed;
        if (self.folderAtLocked(new_path)) return error.IsDirectory;
        if (self.manifest.get(new_path)) |target| if (!target.deleted) return error.PathAlreadyExists;
        _ = try self.manifest.edit(new_path, .{ .cid = entry.cid, .size = entry.size, .mtime = entry.mtime }, self.self_id.bytes, self.self_name);
        _ = try self.manifest.edit(path, .{ .deleted = true, .mtime = self.now() }, self.self_id.bytes, self.self_name);
        try self.saveLocked();
    }

    /// Root CIDs of the files this device must keep: the ones it wrote or
    /// last changed, and, on a backup device, every file it has copied.
    /// Caller frees.
    pub fn keptRoots(self: *SwarmFolder, allocator: std.mem.Allocator) ![][32]u8 {
        var roots: std.ArrayList([32]u8) = .empty;
        errdefer roots.deinit(allocator);
        self.mutex.lock();
        defer self.mutex.unlock();
        for (self.manifest.entries.values()) |e| {
            if (e.deleted or e.kind != .file) continue;
            if (std.mem.eql(u8, &e.version.device, &self.self_id.bytes)) try roots.append(allocator, e.cid);
        }
        self.backup_mutex.lock();
        defer self.backup_mutex.unlock();
        var it = self.backed_up.keyIterator();
        while (it.next()) |cid| try roots.append(allocator, cid.*);
        return roots.toOwnedSlice(allocator);
    }

    pub fn makeDir(self: *SwarmFolder, dir: []const u8, name: []const u8) !void {
        const path = try join(self.allocator, dir, name);
        defer self.allocator.free(path);
        defer self.flushSave(); // after the unlock: writes outside the lock
        self.mutex.lock();
        defer self.mutex.unlock();
        try self.editAllowedLocked();
        _ = try self.manifest.edit(path, .{ .kind = .dir, .mtime = self.now() }, self.self_id.bytes, self.self_name);
        try self.saveLocked();
    }

    /// Deletes a file, or a folder with everything in it.
    pub fn remove(self: *SwarmFolder, path: []const u8) !void {
        defer self.flushSave(); // after the unlock: writes outside the lock
        self.mutex.lock();
        defer self.mutex.unlock();
        try self.editAllowedLocked();
        const doomed = try self.liveUnderLocked(path);
        defer freePaths(self.allocator, doomed);
        if (doomed.len == 0) return error.FileNotFound;
        for (doomed) |p| _ = try self.manifest.edit(p, .{ .deleted = true, .mtime = self.now() }, self.self_id.bytes, self.self_name);
        try self.saveLocked();
    }

    /// Removes one file, and only while its content is still `base` (null:
    /// whatever it is), all under one lock: an edit that lands between a
    /// caller's check and the removal is never deleted. A folder is
    /// refused (error.IsDirectory): `remove` is for those.
    pub fn removeFile(self: *SwarmFolder, path: []const u8, base: ?[32]u8) !void {
        if (!manifest_mod.validPath(path)) return error.InvalidPath;
        defer self.flushSave(); // after the unlock: writes outside the lock
        self.mutex.lock();
        defer self.mutex.unlock();
        try self.editAllowedLocked();
        if (self.folderAtLocked(path)) return error.IsDirectory;
        const entry = self.manifest.get(path) orelse return error.FileNotFound;
        if (entry.deleted or entry.kind != .file) return error.FileNotFound;
        if (base) |expected| if (!std.mem.eql(u8, &entry.cid, &expected)) return error.Changed;
        _ = try self.manifest.edit(path, .{ .deleted = true, .mtime = self.now() }, self.self_id.bytes, self.self_name);
        try self.saveLocked();
    }

    /// Renames a file or folder in place (same parent folder).
    pub fn rename(self: *SwarmFolder, path: []const u8, new_name: []const u8) !void {
        const new_path = try join(self.allocator, splitParent(path).dir, new_name);
        defer self.allocator.free(new_path);
        return self.move(path, new_path, .{});
    }

    pub const MoveOptions = struct {
        /// Replace whatever is at `new_path` (POSIX rename). Otherwise an
        /// existing target is an error.
        replace: bool = false,
    };

    /// Moves a file or folder to `new_path`, anywhere in the swarm folder.
    pub fn move(self: *SwarmFolder, path: []const u8, new_path: []const u8, options: MoveOptions) !void {
        if (!manifest_mod.validPath(new_path) or !manifest_mod.validPath(path)) return error.InvalidPath;
        if (std.mem.eql(u8, new_path, path)) return;
        // A folder can't move inside itself.
        if (std.mem.startsWith(u8, new_path, path) and new_path.len > path.len and new_path[path.len] == '/') return error.InvalidPath;

        defer self.flushSave(); // after the unlock: writes outside the lock
        self.mutex.lock();
        defer self.mutex.unlock();
        try self.editAllowedLocked();
        const moving = try self.liveUnderLocked(path);
        defer freePaths(self.allocator, moving);
        if (moving.len == 0) return error.FileNotFound;

        const in_the_way = try self.liveUnderLocked(new_path);
        defer freePaths(self.allocator, in_the_way);
        if (in_the_way.len > 0) {
            if (!options.replace) return error.PathAlreadyExists;
            // POSIX rename: a folder replaces only an empty folder, a file
            // only a file. Replacing deletes what is there on every device.
            const moving_dir = self.isDirLocked(path, moving);
            const target_dir = self.isDirLocked(new_path, in_the_way);
            if (moving_dir and !target_dir) return error.NotADirectory;
            if (!moving_dir and target_dir) return error.IsDirectory;
            if (target_dir) for (in_the_way) |p| {
                if (!std.mem.eql(u8, p, new_path)) return error.DirNotEmpty;
            };
            for (in_the_way) |p| _ = try self.manifest.edit(p, .{ .deleted = true, .mtime = self.now() }, self.self_id.bytes, self.self_name);
        }
        for (moving) |old| {
            const e = self.manifest.get(old).?;
            const dest = try std.fmt.allocPrint(self.allocator, "{s}{s}", .{ new_path, old[path.len..] });
            defer self.allocator.free(dest);
            _ = try self.manifest.edit(dest, .{ .kind = e.kind, .cid = e.cid, .size = e.size, .mtime = e.mtime }, self.self_id.bytes, self.self_name);
            _ = try self.manifest.edit(old, .{ .deleted = true, .mtime = self.now() }, self.self_id.bytes, self.self_name);
        }
        try self.saveLocked();
    }

    /// Whether a folder is at `path`: its own entry, or things inside it.
    fn folderAtLocked(self: *SwarmFolder, path: []const u8) bool {
        if (self.manifest.get(path)) |e| if (!e.deleted) return e.kind == .dir;
        for (self.manifest.entries.values()) |e| {
            if (!e.deleted and e.path.len > path.len and e.path[path.len] == '/' and std.mem.startsWith(u8, e.path, path)) return true;
        }
        return false;
    }

    /// Whether `path` is a folder, given what is live under it (itself
    /// included).
    fn isDirLocked(self: *SwarmFolder, path: []const u8, under: []const []const u8) bool {
        if (self.manifest.get(path)) |e| if (!e.deleted) return e.kind == .dir;
        return under.len > 0; // only things inside it: an implied folder
    }

    pub const Info = struct { cid: [32]u8, size: u64, mtime: u64, author: [32]u8 };

    /// A live file's content and author, or null.
    pub fn fileInfo(self: *SwarmFolder, path: []const u8) ?Info {
        self.mutex.lock();
        defer self.mutex.unlock();
        const e = self.manifest.get(path) orelse return null;
        if (e.deleted or e.kind != .file) return null;
        return .{ .cid = e.cid, .size = e.size, .mtime = e.mtime, .author = e.version.device };
    }

    /// Whether `path` is known to be deleted: a tombstone, or no entry at
    /// all once a sync round has run (a tombstone is pruned after 90 days).
    /// Before the first round an unknown path may just not have arrived.
    pub fn isGone(self: *SwarmFolder, path: []const u8) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        const e = self.manifest.get(path) orelse return self.last_sync != 0;
        return e.deleted;
    }

    /// Live files that were moved here from `old_path`, which another device
    /// (or this one) moved: a move writes the new path and then the old
    /// path's tombstone as the very next version of the same device, so the
    /// new entry's version (or one of its history) is the one just before
    /// the tombstone's. A path that was only deleted has none. Paths
    /// allocated in `arena`; usually one, more only by coincidence.
    pub fn movedFrom(self: *SwarmFolder, arena: std.mem.Allocator, old_path: []const u8) ![]const []const u8 {
        self.mutex.lock();
        defer self.mutex.unlock();
        const tomb = self.manifest.get(old_path) orelse return &.{};
        if (!tomb.deleted) return &.{};
        const before = manifest_mod.Version{ .clock = tomb.version.clock -| 1, .device = tomb.version.device };
        var out: std.ArrayList([]const u8) = .empty;
        for (self.manifest.entries.values()) |e| {
            if (e.deleted or e.kind != .file) continue;
            var linked = e.version.eql(before);
            for (e.history) |h| {
                if (h) |hv| linked = linked or hv.eql(before);
            }
            if (linked) try out.append(arena, try arena.dupe(u8, e.path));
        }
        return out.items;
    }

    /// Whether `path` is a folder with nothing live in it.
    pub fn isEmptyDir(self: *SwarmFolder, path: []const u8) !bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        const under = try self.liveUnderLocked(path);
        defer freePaths(self.allocator, under);
        for (under) |p| if (!std.mem.eql(u8, p, path)) return false;
        return true;
    }

    /// A folder for files being written through the mount before they are
    /// added (next to the manifest). Created on demand; caller frees.
    pub fn stagingDir(self: *SwarmFolder, allocator: std.mem.Allocator) ![]u8 {
        const dir = try std.fmt.allocPrint(allocator, "{s}.staging", .{self.file_path});
        errdefer allocator.free(dir);
        try std.Io.Dir.cwd().createDirPath(self.io, dir);
        return dir;
    }

    /// Empties leftover *.part staging files.
    pub fn cleanStaging(self: *SwarmFolder) void {
        const dir_path = self.stagingDir(self.allocator) catch return;
        defer self.allocator.free(dir_path);
        var dir = std.Io.Dir.cwd().openDir(self.io, dir_path, .{ .iterate = true }) catch return;
        defer dir.close(self.io);
        var it = dir.iterate();
        while (it.next(self.io) catch null) |entry| {
            if (std.mem.endsWith(u8, entry.name, ".part")) {
                dir.deleteFile(self.io, entry.name) catch {};
            }
        }
    }

    /// Live entries at `path` or below it (owned copies). Caller holds mutex.
    fn liveUnderLocked(self: *SwarmFolder, path: []const u8) ![][]u8 {
        var out: std.ArrayList([]u8) = .empty;
        errdefer {
            for (out.items) |p| self.allocator.free(p);
            out.deinit(self.allocator);
        }
        for (self.manifest.entries.values()) |e| {
            if (e.deleted) continue;
            const under = std.mem.eql(u8, e.path, path) or
                (std.mem.startsWith(u8, e.path, path) and e.path.len > path.len and e.path[path.len] == '/');
            if (!under) continue;
            try out.append(self.allocator, try self.allocator.dupe(u8, e.path));
        }
        return out.toOwnedSlice(self.allocator);
    }

    fn freePaths(allocator: std.mem.Allocator, paths: [][]u8) void {
        for (paths) |p| allocator.free(p);
        allocator.free(paths);
    }

    // ---- Reading ----

    pub const Item = struct {
        name: []const u8,
        path: []const u8,
        dir: bool,
        size: u64,
        mtime: u64,
        /// Files only: content CID and who added this version.
        cid: ?[32]u8,
        author: []const u8,
        author_id: ?[32]u8,
    };

    /// The folder `dir` ("" for the top), allocated in `arena`.
    pub fn list(self: *SwarmFolder, arena: std.mem.Allocator, dir: []const u8) ![]Item {
        self.mutex.lock();
        defer self.mutex.unlock();
        const listed = try self.manifest.list(arena, dir);
        const out = try arena.alloc(Item, listed.len);
        for (listed, out) |l, *o| {
            const e = l.entry;
            o.* = .{
                .name = l.name,
                .path = try join(arena, dir, l.name),
                .dir = l.kind == .dir,
                .size = l.size,
                .mtime = l.mtime,
                .cid = if (e != null and l.kind == .file) e.?.cid else null,
                .author = if (e) |x| try arena.dupe(u8, x.author) else "",
                .author_id = if (e) |x| x.version.device else null,
            };
        }
        return out;
    }

    /// Every live file at any depth below the folder `dir`, in one pass over
    /// the manifest (listing each folder separately costs a pass per folder).
    /// `name` is the file name, `path` the whole path. Allocated in `arena`.
    pub fn listUnder(self: *SwarmFolder, arena: std.mem.Allocator, dir: []const u8) ![]Item {
        self.mutex.lock();
        defer self.mutex.unlock();
        const found = try self.manifest.listUnder(arena, dir);
        const out = try arena.alloc(Item, found.len);
        for (found, out) |e, *o| o.* = try itemOf(arena, e);
        return out;
    }

    /// The live file at `path`, or null.
    pub fn fileItem(self: *SwarmFolder, arena: std.mem.Allocator, path: []const u8) !?Item {
        self.mutex.lock();
        defer self.mutex.unlock();
        const e = self.manifest.get(path) orelse return null;
        if (e.deleted or e.kind != .file) return null;
        return try itemOf(arena, e);
    }

    fn itemOf(arena: std.mem.Allocator, e: Entry) !Item {
        const path = try arena.dupe(u8, e.path);
        return .{
            .name = splitParent(path).name,
            .path = path,
            .dir = false,
            .size = e.size,
            .mtime = e.mtime,
            .cid = e.cid,
            .author = try arena.dupe(u8, e.author),
            .author_id = e.version.device,
        };
    }

    /// Reads a file's bytes: from the local store, else likely holders
    /// (cluster/holders.zig): the device that added it, devices that keep
    /// swarm backups, then any other known peer.
    pub fn readAt(self: *SwarmFolder, allocator: std.mem.Allocator, cid: [32]u8, author: [32]u8, offset: u64, dest: []u8) !usize {
        const bm = self.block_manager orelse return error.NotRunning;
        var buffer = remote_mod.holdersBuffer();
        const peers = self.holdersOf(allocator, &cid, .{ .bytes = author }, &buffer);
        if (self.read_ahead) |ra| return ra.readAt(allocator, peers, cid, offset, dest);
        var from = remote_mod.Source{ .block_manager = bm, .root = cid, .holders = peers };
        return tree.readAt(allocator, from.loader(), cid, offset, dest);
    }

    /// Like readAt, but only from this device's block store: error.BlockNotFound
    /// when a block isn't here, and no network, so it is safe to call for
    /// every file of a list (snippets, search).
    pub fn readLocal(self: *SwarmFolder, allocator: std.mem.Allocator, cid: [32]u8, offset: u64, dest: []u8) !usize {
        return tree.readAt(allocator, tree.Loader.local(self.store), cid, offset, dest);
    }

    /// Live author, swarm backups, placement replicas, then other peers.
    pub fn holdersOf(self: *SwarmFolder, allocator: std.mem.Allocator, cid: *const [32]u8, author: NodeID, out: *[cluster.fetcher.max_holders]NodeID) []NodeID {
        var placed: [policy_max]NodeID = undefined;
        var replicas: []const NodeID = &.{};
        if (self.placement) |p| {
            const copies = p.policy.copies();
            if (copies > 1) {
                if (cluster.placement.candidates(allocator, p.trust, p.policy, self.self_id, p.self_device)) |members| {
                    defer allocator.free(members);
                    replicas = cluster.placement.replicaHolders(cid, author, copies, members, &placed);
                } else |_| {}
            }
        }
        return self.holderHints(author, replicas, &.{}, out);
    }

    /// Manifest authors survive key rotation; only current IDs are dialed.
    fn liveAuthor(self: *SwarmFolder, author: NodeID) bool {
        const trust = if (self.placement) |p| p.trust else if (self.block_manager) |bm| bm.trustStore() else null;
        const members = trust orelse return true;
        // Connected right now, through the cluster layer's registry (fs/
        // never asks the network directly; a remembered routing ID doesn't
        // count); else the trust store decides.
        if (self.block_manager) |bm| if (bm.holders) |*holds| if (holds.knowsPeer(author)) return true;
        return members.isMemberNode(author);
    }

    /// Shared by reads and keeper wants so both use the same source order.
    /// An author that is gone (not a current member, not connected) is left
    /// out. The keeper's lost verdict needs the author's own "not found",
    /// so such a file is never declared lost: the same as before, when the
    /// gone author was listed but never answered.
    fn holderHints(self: *SwarmFolder, author: NodeID, replicas: []const NodeID, known: []const NodeID, out: *[cluster.fetcher.max_holders]NodeID) []NodeID {
        var n: usize = 0;
        const live = self.liveAuthor(author);
        if (live) addHint(out, &n, author, self.self_id);
        var more = remote_mod.holdersBuffer();
        var rest: []const NodeID = known;
        if (self.block_manager) |bm| {
            if (bm.holders) |*holds| {
                const split = holds.forSwarmSplit(if (live) author else self.self_id, &more);
                for (split.ids[0..split.backups_end]) |h| addHint(out, &n, h, self.self_id);
                rest = split.ids[split.backups_end..];
            }
        }
        for (replicas) |h| addHint(out, &n, h, self.self_id);
        for (rest) |h| addHint(out, &n, h, self.self_id);
        return out[0..n];
    }

    // ---- Sync ----

    /// Adapter for discovery Node.swarm_source (GET_SWARM).
    pub fn source(self: *SwarmFolder) ShareSource {
        return .{ .ctx = self, .listFn = encodeErased, .digestFn = digestErased };
    }

    fn digestErased(ctx: *anyopaque) [32]u8 {
        const self: *SwarmFolder = @ptrCast(@alignCast(ctx));
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.manifest.digest();
    }

    fn encodeErased(ctx: *anyopaque, allocator: std.mem.Allocator) anyerror![]u8 {
        const self: *SwarmFolder = @ptrCast(@alignCast(ctx));
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.manifest.encode(allocator);
    }

    /// `peers_failed`: reached in the last round, but their manifest couldn't
    /// be read or merged (too large, corrupt): edits stop flowing from them.
    /// True until the folder has synced with its peers once since this
    /// device started (or found none to sync with): writes wait for that
    /// (error.NotSynced), so an empty folder on a waking device never
    /// overwrites the swarm's.
    pub fn awaitingFirstSync(self: *SwarmFolder) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.awaitingLocked();
    }

    pub const Status = struct { entries: usize, peers_synced: u32, peers_failed: u32, last_sync: u64 };

    pub fn status(self: *SwarmFolder) Status {
        self.mutex.lock();
        defer self.mutex.unlock();
        var live: usize = 0;
        for (self.manifest.entries.values()) |e| {
            if (!e.deleted) live += 1;
        }
        return .{ .entries = live, .peers_synced = self.peers_synced, .peers_failed = self.peers_failed, .last_sync = self.last_sync };
    }

    /// Pulls every reachable peer's manifest and merges it. Returns how
    /// many entries changed.
    pub fn syncNow(self: *SwarmFolder) !usize {
        const bm = self.block_manager orelse return error.NotRunning;
        self.sync_mutex.lock();
        defer self.sync_mutex.unlock();
        const peers = try remote_mod.knownPeers(bm, self.allocator);
        defer self.allocator.free(peers);

        var changed: usize = 0;
        var reached: u32 = 0;
        var failed: u32 = 0;
        // Peers whose manifest this round compared or merged: what lifts
        // `awaiting_pull` (a reached peer whose manifest failed doesn't).
        var merged_from: u32 = 0;
        for (peers) |peer| {
            const have = blk: {
                self.mutex.lock();
                defer self.mutex.unlock();
                break :blk self.manifest.digest();
            };
            // Its pings say it has the same content: nothing to ask, so a
            // quiet swarm costs no traffic at all here.
            if (bm.peerSwarmDigest(peer)) |theirs| if (std.mem.eql(u8, &theirs, &have)) {
                reached += 1;
                merged_from += 1;
                continue;
            };
            const conn = bm.connectTo(peer) catch continue; // offline: not a failure
            defer conn.deinit();
            // Asked anyway, a peer with the same content answers with nothing.
            const bytes = bm.swarmManifest(self.allocator, conn, have) catch |err| {
                std.debug.print("swarm: no manifest from {x}: {any}\n", .{ peer.bytes[0..4], err });
                failed += 1;
                continue;
            };
            defer self.allocator.free(bytes);
            reached += 1;
            if (bytes.len == 0) {
                merged_from += 1;
                continue;
            }
            changed += self.mergePeerBytes(bytes, peer) orelse {
                failed += 1;
                continue;
            };
            merged_from += 1;
        }
        var hooks: HookList = .{};
        {
            defer self.flushSave(); // after the unlock: writes outside the lock
            self.mutex.lock();
            defer self.mutex.unlock();
            self.peers_synced = reached;
            self.peers_failed = failed;
            self.last_sync = self.now();
            self.roundDoneLocked(merged_from);
            if (changed > 0) {
                self.saveLocked() catch |err| std.debug.print("swarm: saving the manifest failed: {any}\n", .{err});
                // New files may be ones this device keeps.
                if (self.keeper) |k| k.wake();
                hooks = self.on_change;
            }
        }
        // Outside the locks: the hook may read the folder.
        hooks.run();
        return changed;
    }

    /// Caller holds `mutex`. A round that merged no reached peer's manifest
    /// (none known yet, offline, or unreadable) doesn't lift `awaiting_pull`.
    fn roundDoneLocked(self: *SwarmFolder, merged_from: u32) void {
        if (merged_from > 0) self.awaiting_pull = false;
    }

    /// Parses a peer's manifest outside the lock (reads through the mount
    /// don't wait on it) and merges it. Null when it can't be read; else how
    /// many entries changed.
    fn mergePeerBytes(self: *SwarmFolder, bytes: []const u8, peer: NodeID) ?usize {
        var parsed = Manifest.parse(self.allocator, bytes) catch |err| {
            std.debug.print("swarm: {x}'s manifest can't be merged: {any}\n", .{ peer.bytes[0..4], err });
            return null;
        };
        defer parsed.deinit();
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.manifest.mergeParsed(&parsed);
    }

    /// A callback of the folder's thread. Hooks run outside the folder's
    /// locks (they may read it), one after the other, never concurrently.
    pub const Hook = struct { ctx: *anyopaque, runFn: *const fn (ctx: *anyopaque) void };

    /// A small fixed list of hooks: the node wires the few services that
    /// watch the folder (the backup import, the notes).
    pub const HookList = struct {
        items: [max_hooks]Hook = undefined,
        len: usize = 0,

        pub const max_hooks = 4;

        pub fn run(self: HookList) void {
            for (self.items[0..self.len]) |h| h.runFn(h.ctx);
        }
    };

    /// Runs `hook` after every sync round.
    pub fn addAfterSyncHook(self: *SwarmFolder, hook: Hook) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        try addHook(&self.after_sync, hook);
    }

    /// Runs `hook` after a sync round that merged something from a peer.
    pub fn addChangeHook(self: *SwarmFolder, hook: Hook) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        try addHook(&self.on_change, hook);
    }

    fn addHook(hooks: *HookList, hook: Hook) !void {
        if (hooks.len >= HookList.max_hooks) return error.TooManyHooks;
        hooks.items[hooks.len] = hook;
        hooks.len += 1;
    }

    /// The manifest digest of the entries under `prefix` (see
    /// Manifest.digestUnder).
    pub fn digestUnder(self: *SwarmFolder, prefix: []const u8) [32]u8 {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.manifest.digestUnder(prefix);
    }

    /// Whether the clock may have restarted from zero (see `awaiting_pull`).
    fn needsPull(self: *const SwarmFolder) bool {
        return self.manifest_missing and !self.clock_found;
    }

    pub fn start(self: *SwarmFolder, block_manager: *cluster.BlockManager) !void {
        self.block_manager = block_manager;
        self.mutex.lock();
        self.awaiting_pull = self.needsPull();
        self.awaiting_since_ms = sync.monotonicMillis();
        self.mutex.unlock();
        try self.worker.start(loop, .{self});
    }

    pub fn stop(self: *SwarmFolder) void {
        self.worker.stop();
    }

    fn loop(self: *SwarmFolder) void {
        const step = 200 * std.time.ns_per_ms;
        var waited: u64 = self.sync_interval_ns - 2 * std.time.ns_per_s; // first round soon
        while (self.worker.isRunning()) {
            sync.sleep(step);
            waited += step;
            self.flushSave(); // edits batched in the last second
            if (waited < self.sync_interval_ns) continue;
            waited = 0;
            _ = self.syncNow() catch {};
            const hooks = blk: {
                self.mutex.lock();
                defer self.mutex.unlock();
                break :blk self.after_sync;
            };
            hooks.run();
        }
    }

    pub const Import = struct { path: []const u8, cid: [32]u8, size: u64, mtime: u64 };

    /// Live files at or below `path` (a folder).
    pub fn filesUnder(self: *SwarmFolder, path: []const u8) usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        var n: usize = 0;
        for (self.manifest.entries.values()) |e| {
            if (e.deleted or e.kind != .file) continue;
            if (std.mem.startsWith(u8, e.path, path) and e.path.len > path.len and e.path[path.len] == '/') n += 1;
        }
        return n;
    }

    /// Adds files whose blocks this device already has (a backed-up share's,
    /// scanned into the store), in one edit and one save. A path that holds
    /// the same content already is left alone. Returns how many were added.
    pub fn importFiles(self: *SwarmFolder, files: []const Import) !usize {
        defer self.flushSave(); // after the unlock: writes outside the lock
        self.mutex.lock();
        defer self.mutex.unlock();
        try self.editAllowedLocked();
        var added: usize = 0;
        for (files) |f| {
            if (!manifest_mod.validPath(f.path)) continue;
            if (self.manifest.get(f.path)) |e| if (!e.deleted and std.mem.eql(u8, &e.cid, &f.cid)) continue;
            _ = try self.manifest.edit(f.path, .{ .cid = f.cid, .size = f.size, .mtime = f.mtime }, self.self_id.bytes, self.self_name);
            added += 1;
        }
        if (added > 0) {
            try self.saveLocked();
            // Copies are kept by the devices that keep them (their keepers).
            if (self.keeper) |k| k.wake();
        }
        return added;
    }

    // ---- Backup ----

    pub const BackupStatus = struct {
        enabled: bool,
        /// Live files, and how many of them are copied here in full.
        files: usize,
        backed_up: usize,
        /// Size of the copied files.
        bytes: u64,
        /// Files no reachable device could serve in the last round.
        unreachable_files: usize,
        /// Unix seconds; 0 before the first round.
        last_round: u64,
    };

    /// What placement reads: membership, the swarm's policy, this device.
    pub const Placement = struct {
        trust: *device.trust.Store,
        policy: *device.policy.Policy,
        self_device: @import("../net/id.zig").DeviceID,
    };

    /// Turns the backup on or off. On: every live file is kept on this
    /// device (the keeper copies it). Other devices read from here when the
    /// one that added a file is offline. Off: copies made stay; files
    /// placement gives this device are still kept.
    pub fn setBackup(self: *SwarmFolder, on: bool) !void {
        self.backup_ctl.lock();
        defer self.backup_ctl.unlock();
        self.ensureBackedUpLoaded();
        self.backup_enabled.store(on, .release);
        if (on) if (self.keeper) |k| k.wake();
    }

    fn ensureBackedUpLoaded(self: *SwarmFolder) void {
        if (self.backed_up_loaded) return;
        self.loadBackedUp() catch |err| std.debug.print("swarm backup: starting over ({any})\n", .{err});
        self.backed_up_loaded = true;
    }

    /// The keeper's view of this folder (cluster/keeper.zig).
    pub fn keeperProvider(self: *SwarmFolder) cluster.keeper.Provider {
        return .{ .ctx = self, .wantsFn = wantsErased, .doneFn = doneErased };
    }

    fn wantsErased(ctx: *anyopaque, allocator: std.mem.Allocator, out: *std.ArrayList(cluster.keeper.Want), max: usize) anyerror!void {
        const self: *SwarmFolder = @ptrCast(@alignCast(ctx));
        return self.wants(allocator, out, max);
    }

    fn doneErased(ctx: *anyopaque, root: cluster.keeper.Cid, outcome: cluster.keeper.Outcome) void {
        const self: *SwarmFolder = @ptrCast(@alignCast(ctx));
        self.kept(root, outcome);
    }

    /// The live files this device should keep and doesn't yet: all of them
    /// on a backup device; else the ones placement gives it (the swarm's
    /// `copies` above 1). Hints: the author, then the other holders.
    fn wants(self: *SwarmFolder, allocator: std.mem.Allocator, out: *std.ArrayList(cluster.keeper.Want), max: usize) !void {
        {
            self.backup_ctl.lock();
            defer self.backup_ctl.unlock();
            self.ensureBackedUpLoaded();
        }
        {
            // A round starts: the last one's failures are its result.
            self.backup_mutex.lock();
            defer self.backup_mutex.unlock();
            self.backup_unreachable = self.round_failed;
            self.round_failed = 0;
            self.backup_last_round = self.now();
            self.want_round +%= 1;
        }
        const backup = self.backup_enabled.load(.acquire);
        const copies: u8 = if (self.placement) |p| p.policy.copies() else 1;
        if (!backup and copies <= 1) return;
        const bm = self.block_manager orelse return;

        const members: []NodeID = if (self.placement) |p| (if (copies > 1) try cluster.placement.candidates(allocator, p.trust, p.policy, self.self_id, p.self_device) else &.{}) else &.{};
        defer allocator.free(members);
        const known = try remote_mod.knownPeers(bm, allocator);
        defer allocator.free(known);

        self.mutex.lock();
        defer self.mutex.unlock();
        self.backup_mutex.lock();
        defer self.backup_mutex.unlock();
        self.pruneBackedUpLocked(allocator);
        for (self.manifest.entries.values()) |e| {
            if (out.items.len >= max) break;
            if (e.deleted or e.kind != .file or self.backed_up.contains(e.cid)) continue;
            const author: NodeID = .{ .bytes = e.version.device };
            if (author.eql(self.self_id)) continue; // its own: kept already
            var placed: [policy_max]NodeID = undefined;
            const holders = cluster.placement.replicaHolders(&e.cid, author, copies, members, &placed);
            if (!backup and !contains(holders, self.self_id)) continue;
            var hints: [cluster.fetcher.max_holders]NodeID = undefined;
            const sources = self.holderHints(author, holders, known, &hints);
            var want = cluster.keeper.Want.init(e.cid, sources);
            want.author = author;
            try out.append(allocator, want);
        }
    }

    const policy_max = device.policy.max_copies;

    fn contains(ids: []const NodeID, id: NodeID) bool {
        for (ids) |x| if (x.eql(id)) return true;
        return false;
    }

    fn addHint(hints: *[cluster.fetcher.max_holders]NodeID, n: *usize, id: NodeID, self_id: NodeID) void {
        if (n.* >= hints.len or id.eql(self_id) or contains(hints[0..n.*], id)) return;
        hints[n.*] = id;
        n.* += 1;
    }

    /// A copy finished (or failed); the list is saved now and then, so a
    /// long first backup survives a restart.
    fn kept(self: *SwarmFolder, root: [32]u8, outcome: cluster.keeper.Outcome) void {
        if (outcome == .lost) return self.lostRoot(root);
        self.backup_mutex.lock();
        defer self.backup_mutex.unlock();
        self.forgetLostLocked(root);
        if (outcome != .kept) {
            self.round_failed += 1;
            return;
        }
        self.backed_up.put(self.allocator, root, {}) catch return;
        self.unsaved += 1;
        const at = sync.monotonicMillis();
        if (self.unsaved >= 32 or at - self.saved_at > 10 * std.time.ms_per_s) {
            self.saveBackedUpLocked() catch |err| std.debug.print("swarm backup: saving progress failed: {any}\n", .{err});
            self.unsaved = 0;
            self.saved_at = at;
        }
    }

    /// A copy of `root` found its data on no device (every holder asked,
    /// the author among them, answered "not found"; cluster/keeper.zig). A
    /// photo deleted on the phone before any backup device copied it. The
    /// entry stays at first ("backup, not mirror"; the data may come back
    /// with the phone's next sync); only when the same file came out lost in
    /// `lost_rounds` rounds spanning `lost_span_ms`, and the entry is still
    /// the version that failed, this backup device deletes it, as any edit,
    /// so the tombstone reaches every device. The phone's import remembers
    /// the content, so it isn't added again.
    fn lostRoot(self: *SwarmFolder, root: [32]u8) void {
        defer self.flushSave(); // after the unlock: writes outside the lock
        self.mutex.lock();
        defer self.mutex.unlock();
        self.backup_mutex.lock();
        defer self.backup_mutex.unlock();
        self.round_failed += 1;
        // The entry that wanted it (the same checks `wants` makes).
        var target: ?Entry = null;
        if (self.backup_enabled.load(.acquire)) {
            for (self.manifest.entries.values()) |e| {
                if (e.deleted or e.kind != .file or !std.mem.eql(u8, &e.cid, &root)) continue;
                if (std.mem.eql(u8, &e.version.device, &self.self_id.bytes)) continue;
                target = e;
                break;
            }
        }
        const entry = target orelse return self.forgetLostLocked(root);
        const at = sync.monotonicMillis();
        const row = blk: {
            for (self.lost[0..self.lost_count]) |*r| if (std.mem.eql(u8, &r.root, &root)) {
                if (!r.version.eql(entry.version)) { // changed meanwhile: start over
                    r.* = .{ .root = root, .version = entry.version, .first_ms = at, .count = 1, .round = self.want_round };
                } else if (r.round != self.want_round) {
                    r.count +|= 1;
                    r.round = self.want_round;
                }
                break :blk r;
            };
            const fresh: Lost = .{ .root = root, .version = entry.version, .first_ms = at, .count = 1, .round = self.want_round };
            if (self.lost_count < max_lost) {
                self.lost[self.lost_count] = fresh;
                self.lost_count += 1;
                break :blk &self.lost[self.lost_count - 1];
            }
            var oldest: usize = 0; // full: the one lost longest ago makes room
            for (self.lost[0..self.lost_count], 0..) |r, i| if (r.first_ms < self.lost[oldest].first_ms) {
                oldest = i;
            };
            self.lost[oldest] = fresh;
            break :blk &self.lost[oldest];
        };
        if (row.count < self.lost_rounds or at - row.first_ms < self.lost_span_ms) return;
        // Still the version that failed (we hold the lock that edits).
        const path = self.allocator.dupe(u8, entry.path) catch return;
        defer self.allocator.free(path);
        self.editAllowedLocked() catch return; // the same gate as any edit; tried again next round
        _ = self.manifest.edit(path, .{ .deleted = true, .mtime = self.now() }, self.self_id.bytes, self.self_name) catch return;
        self.saveLocked() catch return;
        self.forgetLostLocked(root);
        std.debug.print("swarm: removed {s}: its data is on no device (deleted before any backup copied it)\n", .{path});
    }

    /// Caller holds `backup_mutex`.
    fn forgetLostLocked(self: *SwarmFolder, root: [32]u8) void {
        for (self.lost[0..self.lost_count], 0..) |r, i| if (std.mem.eql(u8, &r.root, &root)) {
            self.lost_count -= 1;
            self.lost[i] = self.lost[self.lost_count];
            return;
        };
    }

    pub fn backupStatus(self: *SwarmFolder) BackupStatus {
        var files: usize = 0;
        var done: usize = 0;
        var bytes: u64 = 0;
        self.mutex.lock();
        self.backup_mutex.lock();
        for (self.manifest.entries.values()) |e| {
            if (e.deleted or e.kind != .file) continue;
            files += 1;
            if (self.backed_up.contains(e.cid)) {
                done += 1;
                bytes +|= e.size;
            }
        }
        const out: BackupStatus = .{
            .enabled = self.backup_enabled.load(.acquire),
            .files = files,
            .backed_up = done,
            .bytes = bytes,
            .unreachable_files = self.backup_unreachable,
            .last_round = self.backup_last_round,
        };
        self.backup_mutex.unlock();
        self.mutex.unlock();
        return out;
    }

    /// One keeping round without the keeper's thread (tests, the app's
    /// "sync now"): copies every wanted file through the keeper's copy.
    pub fn backupRound(self: *SwarmFolder) !void {
        const bm = self.block_manager orelse return;
        const fetcher = &(bm.fetcher orelse return error.StorageDisabled);
        var todo: std.ArrayList(cluster.keeper.Want) = .empty;
        defer todo.deinit(self.allocator);
        try self.wants(self.allocator, &todo, std.math.maxInt(usize));
        var go: std.atomic.Value(bool) = .init(true);
        for (todo.items) |*w| {
            const outcome: cluster.keeper.Outcome = if (cluster.keeper.copy(self.allocator, fetcher, self.store, w.root, w.holders(), w.author, &go)) |_| .kept else |err| cluster.keeper.failure(err, w);
            self.kept(w.root, outcome);
        }
        self.backup_mutex.lock();
        defer self.backup_mutex.unlock();
        self.backup_unreachable = self.round_failed;
        self.saveBackedUpLocked() catch {};
        self.unsaved = 0;
    }

    fn backupPath(self: *SwarmFolder) ![]u8 {
        return std.fmt.allocPrint(self.allocator, "{s}.backup", .{self.file_path});
    }

    /// `<manifest>.backup`: the copied files' root CIDs, 32 bytes each.
    fn loadBackedUp(self: *SwarmFolder) !void {
        const path = try self.backupPath();
        defer self.allocator.free(path);
        var file = std.Io.Dir.cwd().openFile(self.io, path, .{}) catch |err| switch (err) {
            error.FileNotFound => return,
            else => return err,
        };
        defer file.close(self.io);
        const size = (try file.stat(self.io)).size;
        if (size % 32 != 0 or size > manifest_mod.max_bytes) return error.BackupListCorrupt;
        const bytes = try self.allocator.alloc(u8, @intCast(size));
        defer self.allocator.free(bytes);
        _ = try file.readPositionalAll(self.io, bytes, 0);
        self.backup_mutex.lock();
        defer self.backup_mutex.unlock();
        var i: usize = 0;
        while (i < bytes.len) : (i += 32) try self.backed_up.put(self.allocator, bytes[i..][0..32].*, {});
    }

    /// Forgets copies of content no live file has any more, so the list
    /// stays within the manifest's size. Caller holds `mutex` and
    /// `backup_mutex`. Best effort: without memory it keeps the list.
    fn pruneBackedUpLocked(self: *SwarmFolder, allocator: std.mem.Allocator) void {
        var live: std.AutoHashMapUnmanaged([32]u8, void) = .empty;
        defer live.deinit(allocator);
        for (self.manifest.entries.values()) |e| {
            if (e.deleted or e.kind != .file) continue;
            live.put(allocator, e.cid, {}) catch return;
        }
        var gone: std.ArrayList([32]u8) = .empty;
        defer gone.deinit(allocator);
        var it = self.backed_up.keyIterator();
        while (it.next()) |cid| if (!live.contains(cid.*)) gone.append(allocator, cid.*) catch return;
        if (gone.items.len == 0) return;
        for (gone.items) |cid| _ = self.backed_up.remove(cid);
        self.unsaved += 1; // written with the next progress save
    }

    /// Caller holds `backup_mutex`. Temp file, then rename.
    fn saveBackedUpLocked(self: *SwarmFolder) !void {
        const path = try self.backupPath();
        defer self.allocator.free(path);
        const tmp = try std.fmt.allocPrint(self.allocator, "{s}.tmp", .{path});
        defer self.allocator.free(tmp);
        const bytes = try self.allocator.alloc(u8, self.backed_up.count() * 32);
        defer self.allocator.free(bytes);
        var it = self.backed_up.keyIterator();
        var i: usize = 0;
        while (it.next()) |k| : (i += 32) @memcpy(bytes[i..][0..32], k);
        {
            var file = try std.Io.Dir.cwd().createFile(self.io, tmp, .{ .truncate = true });
            defer file.close(self.io);
            try file.writePositionalAll(self.io, bytes, 0);
        }
        try std.Io.Dir.cwd().rename(tmp, std.Io.Dir.cwd(), path, self.io);
    }
};

const FileReader = storage.FileReader;

test "swarm: moveCorruptAside moves corrupt manifest aside on load" {
    const testing = std.testing;
    const allocator = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var store_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmp_path = store_path_buf[0..try tmp.dir.realPath(io, &store_path_buf)];
    const manifest_path = try std.fs.path.join(allocator, &.{ tmp_path, "manifest.json" });
    defer allocator.free(manifest_path);

    // Write corrupt manifest
    try tmp.dir.writeFile(io, .{ .sub_path = "manifest.json", .data = "not a valid json manifest {" });

    var store = try storage.engine.StorageEngine.init(allocator, tmp_path);
    defer store.deinit();

    const dev_id = NodeID{ .bytes = [_]u8{0x11} ** 32 };
    const res = SwarmFolder.create(allocator, io, &store, dev_id, "test", manifest_path);
    try testing.expectError(error.InvalidManifest, res);

    // Verify manifest was moved aside
    var dir = try std.Io.Dir.cwd().openDir(io, tmp_path, .{ .iterate = true });
    defer dir.close(io);
    var found_corrupt = false;
    var it = dir.iterate();
    while (try it.next(io)) |e| {
        if (std.mem.startsWith(u8, e.name, "manifest.json.corrupt-")) found_corrupt = true;
    }
    try testing.expect(found_corrupt);
}

test "swarm: a move replaces only an empty folder, and a file only a file" {
    const testing = std.testing;
    const allocator = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmp_path = path_buf[0..try tmp.dir.realPath(io, &path_buf)];
    const manifest_path = try std.fs.path.join(allocator, &.{ tmp_path, "manifest.json" });
    defer allocator.free(manifest_path);
    var store = try storage.engine.StorageEngine.init(allocator, tmp_path);
    defer store.deinit();
    const folder = try SwarmFolder.create(allocator, io, &store, .{ .bytes = [_]u8{0x11} ** 32 }, "test", manifest_path);
    defer folder.destroy();

    try folder.makeDir("", "A");
    try folder.makeDir("", "B");
    try folder.makeDir("B", "keep");
    try folder.makeDir("", "E");

    // A folder doesn't replace a folder with things in it (ENOTEMPTY).
    try testing.expectError(error.DirNotEmpty, folder.move("A", "B", .{ .replace = true }));
    try testing.expect(!(try folder.isEmptyDir("B")));
    // An empty one, it does.
    try folder.move("A", "E", .{ .replace = true });
    try testing.expectError(error.FileNotFound, folder.move("A", "X", .{}));
    // A file and a folder never replace each other.
    try tmp.dir.writeFile(io, .{ .sub_path = "f.txt", .data = "hello" });
    const file_path = try std.fs.path.join(allocator, &.{ tmp_path, "f.txt" });
    defer allocator.free(file_path);
    try folder.addFile("", "f", file_path);
    try testing.expectError(error.NotADirectory, folder.move("E", "f", .{ .replace = true }));
    try testing.expectError(error.IsDirectory, folder.move("f", "E", .{ .replace = true }));
    // Nor does adding a file over a folder, empty or implied by its contents.
    try testing.expectError(error.IsDirectory, folder.addFile("", "E", file_path));
    try folder.addFile("deep/er", "g", file_path);
    try testing.expectError(error.IsDirectory, folder.addFile("", "deep", file_path));
    try testing.expect(folder.fileInfo("deep/er/g") != null);
}

test "swarm: files keep their own modified time" {
    const testing = std.testing;
    const allocator = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmp_path = path_buf[0..try tmp.dir.realPath(io, &path_buf)];
    const manifest_path = try std.fs.path.join(allocator, &.{ tmp_path, "manifest.json" });
    defer allocator.free(manifest_path);
    var store = try storage.engine.StorageEngine.init(allocator, tmp_path);
    defer store.deinit();
    const folder = try SwarmFolder.create(allocator, io, &store, .{ .bytes = [_]u8{0x11} ** 32 }, "test", manifest_path);
    defer folder.destroy();

    try tmp.dir.writeFile(io, .{ .sub_path = "photo.jpg", .data = "jpeg" });
    const src = try std.fs.path.join(allocator, &.{ tmp_path, "photo.jpg" });
    defer allocator.free(src);
    const stat = try std.Io.Dir.cwd().statFile(io, src, .{});

    // Added: the file's own time, not the time of adding.
    try folder.addFile("", "photo.jpg", src);
    try testing.expectEqual(SwarmFolder.secondsOf(stat.mtime), folder.fileInfo("photo.jpg").?.mtime);
    // An explicit one (the mount, after cp -p) wins.
    try folder.addFileAt("", "old.jpg", src, 1_500_000_000);
    try testing.expectEqual(@as(u64, 1_500_000_000), folder.fileInfo("old.jpg").?.mtime);
    // touch -d on a file already there.
    try folder.setMtime("photo.jpg", 1_400_000_000);
    try testing.expectEqual(@as(u64, 1_400_000_000), folder.fileInfo("photo.jpg").?.mtime);
    // A move keeps it.
    try folder.move("photo.jpg", "moved.jpg", .{});
    try testing.expectEqual(@as(u64, 1_400_000_000), folder.fileInfo("moved.jpg").?.mtime);
}

const TestFolder = @import("test_fixture.zig").Fixture(SwarmFolder);
/// This node's device identity in the placement tests: its own value, not
/// derived from the transport self_id (the two spaces never mix).
const test_device = @import("../net/id.zig").DeviceID{ .bytes = [_]u8{0xde} ** 32 };

test "swarm: putBytes writes new content and replaces it only from its base" {
    var t: TestFolder = undefined;
    try t.open(0x21, "Desk");
    defer t.close();
    const folder = t.folder;

    const first = try folder.putBytes("Notes/one.md", "one", null);
    try std.testing.expectEqual(@as(u64, 3), first.size);
    try std.testing.expectEqualSlices(u8, &first.cid, &folder.fileInfo("Notes/one.md").?.cid);
    var buf: [8]u8 = undefined;
    const n = try folder.readLocal(std.testing.allocator, first.cid, 0, &buf);
    try std.testing.expectEqualStrings("one", buf[0..n]);

    const second = try folder.putBytes("Notes/one.md", "two", first.cid);
    try std.testing.expect(!std.mem.eql(u8, &first.cid, &second.cid));
    // The stale base no longer matches.
    try std.testing.expectError(error.Changed, folder.putBytes("Notes/one.md", "three", first.cid));
    try std.testing.expectEqualSlices(u8, &second.cid, &folder.fileInfo("Notes/one.md").?.cid);
}

test "swarm: putBytes with no base refuses an existing path but not a deleted one" {
    var t: TestFolder = undefined;
    try t.open(0x22, "Desk");
    defer t.close();
    const folder = t.folder;

    _ = try folder.putBytes("Notes/one.md", "one", null);
    try std.testing.expectError(error.Changed, folder.putBytes("Notes/one.md", "two", null));
    try std.testing.expectError(error.Changed, folder.putBytes("Notes/none.md", "x", [_]u8{1} ** 32));
    try folder.remove("Notes/one.md");
    _ = try folder.putBytes("Notes/one.md", "again", null);
    try std.testing.expect(folder.fileInfo("Notes/one.md") != null);
}

test "swarm: removeFile removes one file, only from its base, never a folder" {
    var t: TestFolder = undefined;
    try t.open(0x23, "Desk");
    defer t.close();
    const folder = t.folder;

    const one = try folder.putBytes("locket/vault (conflict).enc", "one", null);
    _ = try folder.putBytes("locket/vault.enc", "main", null);
    // Edited after the caller read it: the stale version isn't removed.
    const two = try folder.putBytes("locket/vault (conflict).enc", "two", one.cid);
    try std.testing.expectError(error.Changed, folder.removeFile("locket/vault (conflict).enc", one.cid));
    try std.testing.expect(folder.fileInfo("locket/vault (conflict).enc") != null);
    try folder.removeFile("locket/vault (conflict).enc", two.cid);
    try std.testing.expect(folder.fileInfo("locket/vault (conflict).enc") == null);
    try std.testing.expectError(error.FileNotFound, folder.removeFile("locket/vault (conflict).enc", null));
    // A folder, and what's in it, stays.
    try std.testing.expectError(error.IsDirectory, folder.removeFile("locket", null));
    try std.testing.expect(folder.fileInfo("locket/vault.enc") != null);
}

test "swarm: a refused putBytes builds no blocks" {
    var t: TestFolder = undefined;
    try t.open(0x2d, "Desk");
    defer t.close();
    const folder = t.folder;

    const first = try folder.putBytes("Notes/one.md", "one", null);
    const before = try t.store.keptUsage();
    // A taken name, a stale base: refused before the text is hashed and stored.
    try std.testing.expectError(error.Changed, folder.putBytes("Notes/one.md", "different text " ** 100, null));
    try std.testing.expectError(error.Changed, folder.putBytes("Notes/one.md", "other text " ** 100, [_]u8{9} ** 32));
    folder.awaiting_pull = true;
    folder.awaiting_since_ms = sync.monotonicMillis();
    try std.testing.expectError(error.NotSynced, folder.putBytes("Notes/two.md", "gated text " ** 100, null));
    folder.awaiting_pull = false;
    const after = try t.store.keptUsage();
    try std.testing.expectEqual(before.blocks, after.blocks);
    try std.testing.expectEqual(before.bytes, after.bytes);
    _ = first;
}

test "swarm: a file moved by a device is found from the tombstone of its old path" {
    var t: TestFolder = undefined;
    try t.open(0x2e, "Desk");
    defer t.close();
    const folder = t.folder;
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    _ = try folder.putBytes("Notes/a.md", "a", null);
    _ = try folder.putBytes("Notes/other.md", "o", null);
    try folder.move("Notes/a.md", "Notes/b.md", .{});
    const moved = try folder.movedFrom(arena, "Notes/a.md");
    try std.testing.expectEqual(@as(usize, 1), moved.len);
    try std.testing.expectEqualStrings("Notes/b.md", moved[0]);
    // A delete is no move, even with a note written just before it.
    _ = try folder.putBytes("Notes/c.md", "c", null);
    _ = try folder.putBytes("Notes/last.md", "l", null);
    try folder.remove("Notes/c.md");
    try std.testing.expectEqual(@as(usize, 1), (try folder.movedFrom(arena, "Notes/c.md")).len); // coincidence: the caller checks content or name
    try std.testing.expectEqual(@as(usize, 0), (try folder.movedFrom(arena, "Notes/never.md")).len);
    try std.testing.expectEqual(@as(usize, 0), (try folder.movedFrom(arena, "Notes/b.md")).len); // live
}

test "swarm: hooks run in order, up to a small fixed number" {
    var t: TestFolder = undefined;
    try t.open(0x2f, "Desk");
    defer t.close();
    const folder = t.folder;

    const Order = struct {
        var seen: [8]u8 = undefined;
        var n: usize = 0;
        fn first(_: *anyopaque) void {
            seen[n] = 1;
            n += 1;
        }
        fn second(_: *anyopaque) void {
            seen[n] = 2;
            n += 1;
        }
    };
    var token: u8 = 0;
    Order.n = 0;
    try folder.addAfterSyncHook(.{ .ctx = &token, .runFn = Order.first });
    try folder.addAfterSyncHook(.{ .ctx = &token, .runFn = Order.second });
    folder.after_sync.run();
    try std.testing.expectEqualSlices(u8, &.{ 1, 2 }, Order.seen[0..Order.n]);
    try folder.addChangeHook(.{ .ctx = &token, .runFn = Order.first });
    try folder.addChangeHook(.{ .ctx = &token, .runFn = Order.first });
    try folder.addChangeHook(.{ .ctx = &token, .runFn = Order.first });
    try folder.addChangeHook(.{ .ctx = &token, .runFn = Order.first });
    try std.testing.expectError(error.TooManyHooks, folder.addChangeHook(.{ .ctx = &token, .runFn = Order.first }));
}

test "swarm: putBytes never replaces a folder" {
    var t: TestFolder = undefined;
    try t.open(0x23, "Desk");
    defer t.close();
    const folder = t.folder;

    try folder.makeDir("Notes", "folder");
    try std.testing.expectError(error.IsDirectory, folder.putBytes("Notes/folder", "x", null));
    // A folder that exists only because of what is inside it.
    _ = try folder.putBytes("Notes/Work/a.md", "a", null);
    try std.testing.expectError(error.IsDirectory, folder.putBytes("Notes/Work", "x", null));
    try std.testing.expectError(error.InvalidPath, folder.putBytes("../x", "x", null));
}

test "swarm: moveIfUnchanged moves only an unchanged file to a free name" {
    var t: TestFolder = undefined;
    try t.open(0x24, "Desk");
    defer t.close();
    const folder = t.folder;

    const first = try folder.putBytes("Notes/one.md", "one", null);
    const second = try folder.putBytes("Notes/one.md", "two", first.cid);
    try std.testing.expectError(error.Changed, folder.moveIfUnchanged("Notes/one.md", "Notes/two.md", first.cid));
    try std.testing.expectError(error.FileNotFound, folder.moveIfUnchanged("Notes/none.md", "Notes/x.md", second.cid));
    _ = try folder.putBytes("Notes/taken.md", "t", null);
    try std.testing.expectError(error.PathAlreadyExists, folder.moveIfUnchanged("Notes/one.md", "Notes/taken.md", second.cid));
    try folder.moveIfUnchanged("Notes/one.md", "Notes/two.md", second.cid);
    try std.testing.expect(folder.fileInfo("Notes/one.md") == null);
    const moved = folder.fileInfo("Notes/two.md").?;
    try std.testing.expectEqualSlices(u8, &second.cid, &moved.cid);
    try std.testing.expectEqual(second.mtime, moved.mtime);
    try folder.makeDir("Notes", "dir");
    try std.testing.expectError(error.IsDirectory, folder.moveIfUnchanged("Notes/two.md", "Notes/dir", second.cid));
}

test "swarm: a folder whose manifest was missing takes no local edit before its first pull" {
    var t: TestFolder = undefined;
    try t.open(0x25, "Desk");
    defer t.close();
    const folder = t.folder;

    // No manifest file at open; the clock may have restarted.
    try std.testing.expect(folder.manifest_missing);
    // Before start() nothing waits (tests, tools); start() sets the gate.
    _ = try folder.putBytes("Notes/a.md", "a", null);
    folder.awaiting_pull = folder.manifest_missing;
    folder.awaiting_since_ms = sync.monotonicMillis();
    try std.testing.expectError(error.NotSynced, folder.putBytes("Notes/b.md", "b", null));
    try std.testing.expectError(error.NotSynced, folder.makeDir("Notes", "d"));
    try std.testing.expectError(error.NotSynced, folder.remove("Notes/a.md"));
    try std.testing.expectError(error.NotSynced, folder.move("Notes/a.md", "Notes/c.md", .{}));
    try std.testing.expectError(error.NotSynced, folder.setMtime("Notes/a.md", 5));
    // Reading is unaffected.
    try std.testing.expect(folder.fileInfo("Notes/a.md") != null);
    // A sync round that merged a reached peer's manifest lifts it.
    folder.mutex.lock();
    folder.roundDoneLocked(1);
    folder.mutex.unlock();
    try std.testing.expect(!folder.awaiting_pull);
    _ = try folder.putBytes("Notes/b.md", "b", null);
}

test "swarm: the first round with no peers known yet, or an unreadable peer manifest, keeps the gate" {
    var t: TestFolder = undefined;
    try t.open(0x27, "Desk");
    defer t.close();
    const folder = t.folder;
    folder.awaiting_pull = true;
    folder.awaiting_since_ms = sync.monotonicMillis();

    // No peer in the routing table yet: nothing merged.
    folder.mutex.lock();
    folder.roundDoneLocked(0);
    folder.mutex.unlock();
    try std.testing.expect(folder.awaiting_pull);
    try std.testing.expectError(error.NotSynced, folder.putBytes("Notes/a.md", "a", null));

    // A peer answered with something that isn't a manifest: not a pull.
    const peer = NodeID{ .bytes = [_]u8{0x31} ** 32 };
    try std.testing.expect(folder.mergePeerBytes("not a manifest {", peer) == null);
    try std.testing.expect(folder.awaiting_pull);

    // A readable one is.
    var other: TestFolder = undefined;
    try other.open(0x28, "Pixel");
    defer other.close();
    _ = try other.folder.putBytes("Notes/theirs.md", "t", null);
    const bytes = try other.folder.manifest.encode(std.testing.allocator);
    defer std.testing.allocator.free(bytes);
    try std.testing.expectEqual(@as(usize, 1), folder.mergePeerBytes(bytes, peer).?);
    folder.mutex.lock();
    folder.roundDoneLocked(1);
    folder.mutex.unlock();
    _ = try folder.putBytes("Notes/a.md", "a", null);
}

test "swarm: a device that is truly alone may edit after the grace period" {
    var t: TestFolder = undefined;
    try t.open(0x29, "Desk");
    defer t.close();
    const folder = t.folder;
    folder.awaiting_pull = true;
    folder.awaiting_since_ms = sync.monotonicMillis();
    try std.testing.expectError(error.NotSynced, folder.putBytes("Notes/a.md", "a", null));
    folder.awaiting_since_ms -= folder.alone_grace_ms + 1;
    _ = try folder.putBytes("Notes/a.md", "a", null);
    try std.testing.expect(!folder.awaiting_pull);
}

test "swarm: a device that trusts no other device doesn't wait for a pull" {
    var t: TestFolder = undefined;
    try t.open(0x2b, "Desk");
    defer t.close();
    const path = "test_swarm_alone_trust.store";
    std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    var trust = try device.trust.Store.load(std.testing.allocator, path, null);
    defer trust.deinit();
    var policy: device.policy.Policy = undefined; // not read by the edit gate
    const folder = t.folder;
    folder.placement = .{ .trust = &trust, .policy = &policy, .self_device = test_device };
    defer folder.placement = null;
    folder.awaiting_pull = true;
    folder.awaiting_since_ms = sync.monotonicMillis();
    _ = try folder.putBytes("Notes/a.md", "a", null); // first device: nobody to pull from
    try std.testing.expect(!folder.awaiting_pull);

    // Once another device is trusted, a lost manifest waits for it again.
    _ = try trust.upsert([_]u8{7} ** 32, [_]u8{8} ** 32, "Phone", 1);
    folder.awaiting_pull = true;
    folder.awaiting_since_ms = sync.monotonicMillis();
    try std.testing.expectError(error.NotSynced, folder.putBytes("Notes/b.md", "b", null));
}

test "swarm: the clock never goes back when the manifest file is lost" {
    var t: TestFolder = undefined;
    try t.open(0x2a, "Desk");
    defer t.close();
    var note = try t.folder.putBytes("Notes/a.md", "v1", null);
    for (0..5) |i| {
        var text: [8]u8 = undefined;
        const body = try std.fmt.bufPrint(&text, "v{d}", .{i + 2});
        note = try t.folder.putBytes("Notes/a.md", body, note.cid);
    }
    const used = t.folder.manifest.clock;
    try std.testing.expect(used >= 6);

    // The manifest is lost; the clock file is not.
    try t.reopen(true);
    try std.testing.expect(t.folder.manifest_missing);
    try std.testing.expect(t.folder.clock_found);
    try std.testing.expect(t.folder.manifest.clock >= used);
    // The clock file was there: no reason to wait for a peer.
    try std.testing.expect(!t.folder.needsPull());
    _ = try t.folder.putBytes("Notes/b.md", "b", null);
    try std.testing.expect(t.folder.manifest.get("Notes/b.md").?.version.clock > used);

    // Both files lost: the clock restarted, so the gate applies.
    try t.reopen(true);
    std.Io.Dir.cwd().deleteFile(std.testing.io, t.clock_path) catch {};
    try t.reopen(false);
    try std.testing.expect(t.folder.needsPull());
}

test "swarm: a crash that lost unsaved edits does not lower the clock" {
    var t: TestFolder = undefined;
    try t.open(0x2b, "Desk");
    defer t.close();
    _ = try t.folder.putBytes("Notes/a.md", "a", null);
    // Edited, but the manifest is not written yet (the 1 s batch): a restart
    // that loses the edit still starts above it.
    _ = try t.folder.putBytes("Notes/c.md", "c", null);
    const used = t.folder.manifest.clock;
    t.folder.dirty = false; // the "crash": destroy writes nothing
    try t.reopen(true);
    try std.testing.expect(t.folder.manifest.clock >= used);
}

test "swarm: a corrupt clock file is moved aside" {
    var t: TestFolder = undefined;
    try t.open(0x2c, "Desk");
    defer t.close();
    _ = try t.folder.putBytes("Notes/a.md", "a", null);
    try t.reopen(false);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = t.clock_path, .data = "garbage" });
    try t.reopen(false);
    try std.testing.expect(!t.folder.clock_found);
    // Written fresh by the next edit.
    _ = try t.folder.putBytes("Notes/b.md", "b", null);
    var buf: [32]u8 = undefined;
    const bytes = try std.Io.Dir.cwd().readFile(std.testing.io, t.clock_path, &buf);
    try std.testing.expect(bytes.len > 0 and bytes[0] != 'g');
}

test "swarm: digestUnder tells whether something under a folder changed" {
    var t: TestFolder = undefined;
    try t.open(0x26, "Desk");
    defer t.close();
    const folder = t.folder;

    const empty = folder.digestUnder("Notes/");
    _ = try folder.putBytes("Docs/a.txt", "a", null);
    try std.testing.expectEqualSlices(u8, &empty, &folder.digestUnder("Notes/"));
    const note = try folder.putBytes("Notes/a.md", "a", null);
    const with_note = folder.digestUnder("Notes/");
    try std.testing.expect(!std.mem.eql(u8, &empty, &with_note));
    _ = try folder.putBytes("Notes/a.md", "b", note.cid);
    try std.testing.expect(!std.mem.eql(u8, &with_note, &folder.digestUnder("Notes/")));
    try std.testing.expectEqualSlices(u8, &folder.manifest.digest(), &folder.digestUnder(""));
}

/// Merges `from`'s manifest into `into`'s, as a sync round does.
fn mergeManifest(into: *SwarmFolder, from: *SwarmFolder) !void {
    from.mutex.lock();
    const bytes = from.manifest.encode(std.testing.allocator) catch |err| {
        from.mutex.unlock();
        return err;
    };
    from.mutex.unlock();
    defer std.testing.allocator.free(bytes);
    into.mutex.lock();
    defer into.mutex.unlock();
    _ = try into.manifest.mergeEncoded(bytes);
}

/// One keeper round that found `root` with `outcome`.
fn lostRound(folder: *SwarmFolder, root: [32]u8, outcome: cluster.keeper.Outcome) void {
    folder.want_round += 1;
    folder.kept(root, outcome);
}

fn liveAt(folder: *SwarmFolder, path: []const u8) bool {
    folder.mutex.lock();
    defer folder.mutex.unlock();
    const e = folder.manifest.get(path) orelse return false;
    return !e.deleted;
}

test "swarm: a file lost in three rounds over the time threshold is removed by a backup device" {
    var phone: TestFolder = undefined;
    try phone.open(0x31, "Phone");
    defer phone.close();
    var backup: TestFolder = undefined;
    try backup.open(0x32, "Backup");
    defer backup.close();
    const b = backup.folder;
    b.backup_enabled.store(true, .release);
    b.lost_span_ms = 0;

    const put = try phone.folder.putBytes("Phone/Camera/a.jpg", "photo a", null);
    try mergeManifest(b, phone.folder);
    try std.testing.expect(liveAt(b, "Phone/Camera/a.jpg"));
    lostRound(b, put.cid, .lost);
    lostRound(b, put.cid, .lost);
    try std.testing.expect(liveAt(b, "Phone/Camera/a.jpg"));
    lostRound(b, put.cid, .lost);
    try std.testing.expect(!liveAt(b, "Phone/Camera/a.jpg"));
    // A tombstone made by the backup device, so it reaches the others.
    const e = b.manifest.get("Phone/Camera/a.jpg").?;
    try std.testing.expect(e.deleted and std.mem.eql(u8, &e.version.device, &b.self_id.bytes));
    try mergeManifest(phone.folder, b);
    try std.testing.expect(!liveAt(phone.folder, "Phone/Camera/a.jpg"));
    try std.testing.expectEqual(@as(usize, 0), b.lost_count);
}

test "swarm: a lost file stays under the time threshold, with fewer rounds, or on a device that isn't a backup" {
    var phone: TestFolder = undefined;
    try phone.open(0x33, "Phone");
    defer phone.close();
    var backup: TestFolder = undefined;
    try backup.open(0x34, "Backup");
    defer backup.close();
    const b = backup.folder;
    b.backup_enabled.store(true, .release);

    const put = try phone.folder.putBytes("Phone/Camera/a.jpg", "photo a", null);
    try mergeManifest(b, phone.folder);
    // Default threshold (10 minutes): many rounds in a moment change nothing.
    for (0..5) |_| lostRound(b, put.cid, .lost);
    try std.testing.expect(liveAt(b, "Phone/Camera/a.jpg"));
    // Time is there but only two rounds; one root counts once per round.
    b.lost_span_ms = 0;
    b.lost_count = 0;
    lostRound(b, put.cid, .lost);
    b.kept(put.cid, .lost); // same round again (a second entry with this content)
    lostRound(b, put.cid, .lost);
    try std.testing.expect(liveAt(b, "Phone/Camera/a.jpg"));
    // Not a backup device: never.
    b.backup_enabled.store(false, .release);
    for (0..4) |_| lostRound(b, put.cid, .lost);
    try std.testing.expect(liveAt(b, "Phone/Camera/a.jpg"));
}

test "swarm: kept or failed in between starts the lost count over" {
    var phone: TestFolder = undefined;
    try phone.open(0x35, "Phone");
    defer phone.close();
    var backup: TestFolder = undefined;
    try backup.open(0x36, "Backup");
    defer backup.close();
    const b = backup.folder;
    b.backup_enabled.store(true, .release);
    b.lost_span_ms = 0;

    const put = try phone.folder.putBytes("Phone/Camera/a.jpg", "photo a", null);
    try mergeManifest(b, phone.folder);
    lostRound(b, put.cid, .lost);
    lostRound(b, put.cid, .lost);
    lostRound(b, put.cid, .failed); // the phone was unreachable once
    lostRound(b, put.cid, .lost);
    lostRound(b, put.cid, .lost);
    try std.testing.expect(liveAt(b, "Phone/Camera/a.jpg"));
    lostRound(b, put.cid, .lost);
    try std.testing.expect(!liveAt(b, "Phone/Camera/a.jpg"));
}

test "swarm: an entry that changed while it was lost is kept" {
    var phone: TestFolder = undefined;
    try phone.open(0x37, "Phone");
    defer phone.close();
    var backup: TestFolder = undefined;
    try backup.open(0x38, "Backup");
    defer backup.close();
    const b = backup.folder;
    b.backup_enabled.store(true, .release);
    b.lost_span_ms = 0;

    const old = try phone.folder.putBytes("Phone/Camera/a.jpg", "photo a", null);
    try mergeManifest(b, phone.folder);
    lostRound(b, old.cid, .lost);
    lostRound(b, old.cid, .lost);
    // The phone edits the file; the old content is no entry any more.
    const new = try phone.folder.putBytes("Phone/Camera/a.jpg", "photo a, edited", old.cid);
    try mergeManifest(b, phone.folder);
    lostRound(b, old.cid, .lost);
    try std.testing.expect(liveAt(b, "Phone/Camera/a.jpg"));
    // The new content starts its own count.
    lostRound(b, new.cid, .lost);
    lostRound(b, new.cid, .lost);
    try std.testing.expect(liveAt(b, "Phone/Camera/a.jpg"));
    lostRound(b, new.cid, .lost);
    try std.testing.expect(!liveAt(b, "Phone/Camera/a.jpg"));
}

test "swarm: same content under a new version restarts the count" {
    var phone: TestFolder = undefined;
    try phone.open(0x39, "Phone");
    defer phone.close();
    var backup: TestFolder = undefined;
    try backup.open(0x3a, "Backup");
    defer backup.close();
    const b = backup.folder;
    b.backup_enabled.store(true, .release);
    b.lost_span_ms = 0;

    const put = try phone.folder.putBytes("Phone/Camera/a.jpg", "photo a", null);
    try mergeManifest(b, phone.folder);
    lostRound(b, put.cid, .lost);
    lostRound(b, put.cid, .lost);
    try phone.folder.setMtime("Phone/Camera/a.jpg", 12345); // a new version, same content
    try mergeManifest(b, phone.folder);
    lostRound(b, put.cid, .lost);
    try std.testing.expect(liveAt(b, "Phone/Camera/a.jpg"));
}

test "swarm: backups precede placement replicas with eight copies" {
    const Fake = struct {
        fn roles(_: *anyopaque, _: NodeID) ?u8 {
            return 1;
        }
        fn live(_: *anyopaque, out: []NodeID) usize {
            if (out.len == 0) return 0;
            out[0] = .{ .bytes = [_]u8{0xbb} ** 32 };
            return 1;
        }
        fn known(_: *anyopaque, _: []NodeID) usize {
            return 0;
        }
    };
    var t: TestFolder = undefined;
    try t.open(0xee, "reader");
    defer t.close();
    const path = try std.fs.path.join(std.testing.allocator, &.{ t.dir, "trust" });
    defer std.testing.allocator.free(path);
    var trust = try device.trust.Store.load(std.testing.allocator, path, null);
    defer trust.deinit();
    for (1..9) |i| {
        const b: u8 = @intCast(i);
        _ = try trust.upsert([_]u8{b} ** 32, [_]u8{b + 20} ** 32, "member", 1);
    }
    var policy: device.policy.Policy = .{ .allocator = std.testing.allocator, .path = &.{}, .copies_record = .{
        .kind = .copies,
        .subject = .{ .bytes = [_]u8{0} ** 32 },
        .value = 8,
        .at = 1,
        .signer_key = [_]u8{0} ** 32,
        .signature = [_]u8{0} ** 64,
    } };
    t.folder.placement = .{ .trust = &trust, .policy = &policy, .self_device = test_device };
    var bm: cluster.BlockManager = undefined;
    bm.holders = .{ .self_id = t.folder.self_id, .peers = .{
        .ctx = &bm,
        .rolesFn = Fake.roles,
        .knownFn = Fake.known,
        .connectedFn = Fake.live,
    } };
    t.folder.block_manager = &bm;
    const members = try cluster.placement.candidates(std.testing.allocator, &trust, &policy, t.folder.self_id, test_device);
    defer std.testing.allocator.free(members);
    const author = NodeID.fromPublicKey([_]u8{21} ** 32);
    var root = [_]u8{0} ** 32;
    var placed: [8]NodeID = undefined;
    for (0..256) |i| {
        root[0] = @intCast(i);
        const replicas = cluster.placement.replicaHolders(&root, author, 8, members, &placed);
        if (!SwarmFolder.contains(replicas, t.folder.self_id)) break;
    } else return error.NoFixture;
    var out: [8]NodeID = undefined;
    const list = t.folder.holdersOf(std.testing.allocator, &root, author, &out);
    try std.testing.expectEqual(author, list[0]);
    try std.testing.expectEqual(NodeID{ .bytes = [_]u8{0xbb} ** 32 }, list[1]);
    try std.testing.expectEqual(@as(usize, 8), list.len);
    const hints = t.folder.holderHints(author, placed[0..7], &.{}, &out);
    try std.testing.expectEqual(author, hints[0]);
    try std.testing.expectEqual(NodeID{ .bytes = [_]u8{0xbb} ** 32 }, hints[1]);
}

test "swarm: only current transport authors are kept with trust membership" {
    var t: TestFolder = undefined;
    try t.open(0xef, "reader");
    defer t.close();
    const allocator = std.testing.allocator;
    const path = try std.fs.path.join(allocator, &.{ t.dir, "trust" });
    defer allocator.free(path);
    var trust = try device.trust.Store.load(allocator, path, null);
    defer trust.deinit();
    var policy: device.policy.Policy = .{ .allocator = allocator, .path = &.{} };
    const key = [_]u8{71} ** 32;
    const author = NodeID.fromPublicKey(key);
    var out: [cluster.fetcher.max_holders]NodeID = undefined;
    const root = [_]u8{9} ** 32;
    try std.testing.expectEqualSlices(NodeID, &.{author}, t.folder.holdersOf(allocator, &root, author, &out));
    t.folder.placement = .{ .trust = &trust, .policy = &policy, .self_device = test_device };
    try std.testing.expectEqual(@as(usize, 0), t.folder.holdersOf(allocator, &root, author, &out).len);
    _ = try trust.upsert([_]u8{72} ** 32, key, "member", 1);
    try std.testing.expect(!NodeID.fromPublicKey([_]u8{72} ** 32).eql(author));
    try std.testing.expectEqualSlices(NodeID, &.{author}, t.folder.holdersOf(allocator, &root, author, &out));
    const dead = NodeID{ .bytes = [_]u8{73} ** 32 };
    try std.testing.expectEqual(@as(usize, 0), t.folder.holderHints(dead, &.{}, &.{}, &out).len);
}

test "swarm: a connected author stays live without a trust entry; a remembered one doesn't" {
    const Peers = struct {
        fn roles(_: *anyopaque, _: NodeID) ?u8 {
            return null;
        }
        fn connected(_: *anyopaque, out: []NodeID) usize {
            if (out.len == 0) return 0;
            out[0] = .{ .bytes = [_]u8{51} ** 32 };
            return 1;
        }
        fn known(_: *anyopaque, out: []NodeID) usize {
            if (out.len == 0) return 0;
            out[0] = .{ .bytes = [_]u8{52} ** 32 };
            return 1;
        }
    };
    var t: TestFolder = undefined;
    try t.open(0xed, "reader");
    defer t.close();
    const allocator = std.testing.allocator;
    const path = try std.fs.path.join(allocator, &.{ t.dir, "trust" });
    defer allocator.free(path);
    var trust = try device.trust.Store.load(allocator, path, null);
    defer trust.deinit();
    var policy: device.policy.Policy = .{ .allocator = allocator, .path = &.{} };
    t.folder.placement = .{ .trust = &trust, .policy = &policy, .self_device = test_device };
    var bm: cluster.BlockManager = undefined;
    bm.holders = .{ .self_id = t.folder.self_id, .peers = .{
        .ctx = &bm,
        .rolesFn = Peers.roles,
        .knownFn = Peers.known,
        .connectedFn = Peers.connected,
    } };
    t.folder.block_manager = &bm;
    const root = [_]u8{9} ** 32;
    var out: [cluster.fetcher.max_holders]NodeID = undefined;
    // 51 is connected: kept first.
    const connected = NodeID{ .bytes = [_]u8{51} ** 32 };
    try std.testing.expectEqual(connected, t.folder.holdersOf(allocator, &root, connected, &out)[0]);
    // 52 is only in the routing table (an ID from before a re-join can
    // linger there): not a member, not connected, so not listed first.
    const remembered = NodeID{ .bytes = [_]u8{52} ** 32 };
    const list = t.folder.holdersOf(allocator, &root, remembered, &out);
    try std.testing.expect(list.len == 0 or !list[0].eql(remembered));
}

test "swarm: a read whose only holder is a gone author reports NoHolders" {
    var t: TestFolder = undefined;
    try t.open(0xec, "reader");
    defer t.close();
    const allocator = std.testing.allocator;
    const path = try std.fs.path.join(allocator, &.{ t.dir, "trust" });
    defer allocator.free(path);
    var trust = try device.trust.Store.load(allocator, path, null);
    defer trust.deinit();
    var policy: device.policy.Policy = .{ .allocator = allocator, .path = &.{} };
    t.folder.placement = .{ .trust = &trust, .policy = &policy, .self_device = test_device };
    // A node with nobody else around: the author (an ID from before a
    // re-join) is no member and not connected, so nobody is left to ask.
    var peers = [_]cluster.fetcher.FakeNet.Peer{};
    var net: cluster.fetcher.FakeNet = .{ .peers = &peers };
    var bm: cluster.BlockManager = undefined;
    bm.fetcher = cluster.fetcher.Fetcher.init(&t.store, net.transport());
    bm.holders = null;
    t.folder.block_manager = &bm;
    t.folder.read_ahead = null;
    const gone = NodeID{ .bytes = [_]u8{0x73} ** 32 };
    var dest: [16]u8 = undefined;
    // The app shows NoHolders as "no device is known to keep it yet".
    try std.testing.expectError(error.NoHolders, t.folder.readAt(allocator, [_]u8{0x44} ** 32, gone.bytes, 0, &dest));
}
