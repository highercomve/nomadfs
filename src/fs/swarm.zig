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
const ShareSource = @import("../net/discovery/node.zig").Node.ShareSource;
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
    /// Guards `manifest` and the sync counters.
    mutex: sync.Mutex = .{},
    manifest: Manifest,
    last_sync: u64 = 0,
    peers_synced: u32 = 0,
    peers_failed: u32 = 0,
    sync_interval_ns: u64 = 10 * std.time.ns_per_s,
    /// Serialises sync rounds (the loop and syncNow).
    sync_mutex: sync.Mutex = .{},
    running: std.atomic.Value(bool) = .init(false),
    thread: ?std.Thread = null,

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
        return self;
    }

    pub fn destroy(self: *SwarmFolder) void {
        self.stop();
        self.backup_enabled.store(false, .release);
        self.backed_up.deinit(self.allocator);
        self.manifest.deinit();
        self.allocator.free(self.self_name);
        self.allocator.free(self.file_path);
        self.allocator.destroy(self);
    }

    fn load(self: *SwarmFolder) !void {
        var file = std.Io.Dir.cwd().openFile(self.io, self.file_path, .{}) catch |err| switch (err) {
            error.FileNotFound => return,
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

    /// Caller holds `mutex`. Written to a temp file and renamed into place.
    fn saveLocked(self: *SwarmFolder) !void {
        self.manifest.pruneTombstones(self.now());
        const bytes = try self.manifest.encode(self.allocator);
        defer self.allocator.free(bytes);
        if (bytes.len > manifest_mod.max_bytes) return error.ManifestTooLarge;
        const tmp = try std.fmt.allocPrint(self.allocator, "{s}.tmp", .{self.file_path});
        defer self.allocator.free(tmp);
        {
            var file = try std.Io.Dir.cwd().createFile(self.io, tmp, .{ .truncate = true });
            defer file.close(self.io);
            try file.writePositionalAll(self.io, bytes, 0);
        }
        try std.Io.Dir.cwd().rename(tmp, std.Io.Dir.cwd(), self.file_path, self.io);
    }

    fn now(self: *SwarmFolder) u64 {
        const t = std.Io.Timestamp.now(self.io, .real).nanoseconds;
        return @intCast(@max(0, @divFloor(t, std.time.ns_per_s)));
    }

    fn join(allocator: std.mem.Allocator, dir: []const u8, name: []const u8) ![]u8 {
        if (dir.len == 0) return allocator.dupe(u8, name);
        return std.fmt.allocPrint(allocator, "{s}/{s}", .{ dir, name });
    }

    // ---- Edits (this device) ----

    /// Adds (or replaces) `dir/name` with the contents of the local file
    /// at `local_path`. The bytes go into this device's block store.
    pub fn addFile(self: *SwarmFolder, dir: []const u8, name: []const u8, local_path: []const u8) !void {
        const path = try join(self.allocator, dir, name);
        defer self.allocator.free(path);
        if (!manifest_mod.validPath(path)) return error.InvalidPath;

        var file = try std.Io.Dir.cwd().openFile(self.io, local_path, .{});
        defer file.close(self.io);
        var reader = FileReader{ .io = self.io, .file = file };
        var builder = storage.dag.DagBuilder{ .allocator = self.allocator, .store = self.store, .layout = .Balanced };
        const root = try builder.build(&reader);
        defer self.allocator.free(root);

        self.mutex.lock();
        defer self.mutex.unlock();
        _ = try self.manifest.edit(path, .{ .cid = root[0..32].*, .size = reader.offset, .mtime = self.now() }, self.self_id.bytes, self.self_name);
        try self.saveLocked();
        // The devices that keep copies pull it (their keepers), once their
        // manifest has it: nothing is pushed from here.
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
        self.mutex.lock();
        defer self.mutex.unlock();
        _ = try self.manifest.edit(path, .{ .kind = .dir, .mtime = self.now() }, self.self_id.bytes, self.self_name);
        try self.saveLocked();
    }

    /// Deletes a file, or a folder with everything in it.
    pub fn remove(self: *SwarmFolder, path: []const u8) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        const doomed = try self.liveUnderLocked(path);
        defer freePaths(self.allocator, doomed);
        if (doomed.len == 0) return error.FileNotFound;
        for (doomed) |p| _ = try self.manifest.edit(p, .{ .deleted = true, .mtime = self.now() }, self.self_id.bytes, self.self_name);
        try self.saveLocked();
    }

    /// Renames a file or folder in place (same parent folder).
    pub fn rename(self: *SwarmFolder, path: []const u8, new_name: []const u8) !void {
        const slash = std.mem.lastIndexOfScalar(u8, path, '/');
        const parent = if (slash) |s| path[0..s] else "";
        const new_path = try join(self.allocator, parent, new_name);
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

        self.mutex.lock();
        defer self.mutex.unlock();
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

    /// The devices likely to hold a swarm file, best first: its author, the
    /// devices placement gives it (the swarm's `copies`), then the cluster's
    /// list (swarm backup devices, everyone else).
    fn holdersOf(self: *SwarmFolder, allocator: std.mem.Allocator, cid: *const [32]u8, author: NodeID, out: *[cluster.fetcher.max_holders]NodeID) []NodeID {
        var n: usize = 0;
        addHint(out, &n, author, self.self_id);
        if (self.placement) |p| {
            const copies = p.policy.copies();
            if (copies > 1) {
                if (cluster.placement.candidates(allocator, p.trust, p.policy, self.self_id, p.self_device)) |members| {
                    defer allocator.free(members);
                    var placed: [policy_max]NodeID = undefined;
                    for (cluster.placement.replicaHolders(cid, author, copies, members, &placed)) |h| addHint(out, &n, h, self.self_id);
                } else |_| {}
            }
        }
        const bm = self.block_manager orelse return out[0..n];
        if (bm.holders) |*holds| {
            var more = remote_mod.holdersBuffer();
            for (holds.forSwarm(author, &more)) |h| addHint(out, &n, h, self.self_id);
        }
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
        for (peers) |peer| {
            const conn = bm.connectTo(peer) catch continue;
            defer conn.deinit();
            // A peer with the same content answers with nothing: a quiet
            // swarm costs a digest per peer per round, not the manifest.
            const have = blk: {
                self.mutex.lock();
                defer self.mutex.unlock();
                break :blk self.manifest.digest();
            };
            const bytes = bm.dht_node.fetchSwarm(conn, have) catch |err| {
                std.debug.print("swarm: no manifest from {x}: {any}\n", .{ peer.bytes[0..4], err });
                failed += 1;
                continue;
            };
            defer bm.dht_node.allocator.free(bytes);
            reached += 1;
            if (bytes.len == 0) continue;
            self.mutex.lock();
            defer self.mutex.unlock();
            changed += self.manifest.mergeEncoded(bytes) catch |err| {
                std.debug.print("swarm: {x}'s manifest can't be merged: {any}\n", .{ peer.bytes[0..4], err });
                failed += 1;
                continue;
            };
        }
        self.mutex.lock();
        defer self.mutex.unlock();
        self.peers_synced = reached;
        self.peers_failed = failed;
        self.last_sync = self.now();
        if (changed > 0) {
            self.saveLocked() catch |err| std.debug.print("swarm: saving the manifest failed: {any}\n", .{err});
            // New files may be ones this device keeps.
            if (self.keeper) |k| k.wake();
        }
        return changed;
    }

    pub fn start(self: *SwarmFolder, block_manager: *cluster.BlockManager) !void {
        self.block_manager = block_manager;
        if (self.running.swap(true, .acq_rel)) return;
        self.thread = std.Thread.spawn(.{}, loop, .{self}) catch |err| {
            self.running.store(false, .release);
            return err;
        };
    }

    pub fn stop(self: *SwarmFolder) void {
        if (!self.running.swap(false, .acq_rel)) return;
        if (self.thread) |t| t.join();
        self.thread = null;
    }

    fn loop(self: *SwarmFolder) void {
        const step = 200 * std.time.ns_per_ms;
        var waited: u64 = self.sync_interval_ns - 2 * std.time.ns_per_s; // first round soon
        while (self.running.load(.acquire)) {
            sync.sleep(step);
            waited += step;
            if (waited < self.sync_interval_ns) continue;
            waited = 0;
            _ = self.syncNow() catch {};
        }
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
        self_device: NodeID,
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

    fn doneErased(ctx: *anyopaque, root: cluster.keeper.Cid, ok: bool) void {
        const self: *SwarmFolder = @ptrCast(@alignCast(ctx));
        self.kept(root, ok);
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
        for (self.manifest.entries.values()) |e| {
            if (out.items.len >= max) break;
            if (e.deleted or e.kind != .file or self.backed_up.contains(e.cid)) continue;
            const author: NodeID = .{ .bytes = e.version.device };
            if (author.eql(self.self_id)) continue; // its own: kept already
            var placed: [policy_max]NodeID = undefined;
            const holders = cluster.placement.replicaHolders(&e.cid, author, copies, members, &placed);
            if (!backup and !contains(holders, self.self_id)) continue;
            var hints: [cluster.fetcher.max_holders]NodeID = undefined;
            var n: usize = 0;
            hints[0] = author;
            n = 1;
            for (holders) |h| addHint(&hints, &n, h, self.self_id);
            if (bm.holders) |*holds| {
                var more = remote_mod.holdersBuffer();
                for (holds.forSwarm(author, &more)) |h| addHint(&hints, &n, h, self.self_id);
            } else for (known) |h| addHint(&hints, &n, h, self.self_id);
            try out.append(allocator, cluster.keeper.Want.init(e.cid, hints[0..n]));
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
    fn kept(self: *SwarmFolder, root: [32]u8, ok: bool) void {
        self.backup_mutex.lock();
        defer self.backup_mutex.unlock();
        if (!ok) {
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
            const ok = if (cluster.keeper.copy(self.allocator, fetcher, self.store, w.root, w.holders(), &go)) |_| true else |_| false;
            self.kept(w.root, ok);
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
}
