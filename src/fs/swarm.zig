//! The swarm folder: one folder every device in the swarm can read and
//! write. Its listing is a replicated manifest (manifest.zig) that each
//! device keeps on disk and merges with its peers' every few seconds; file
//! bytes stay where they were added and travel only when someone opens
//! them (from the device that added the file, then anyone who cached it).

const std = @import("std");
const sync = @import("../sync.zig");
const cluster = @import("../cluster/mod.zig");
const storage = @import("../storage/mod.zig");
const NodeID = @import("../net/id.zig").NodeID;
const ShareSource = @import("../net/discovery/node.zig").Node.ShareSource;
const manifest_mod = @import("manifest.zig");
const remote_mod = @import("remote.zig");
const tree = @import("tree.zig");

pub const Manifest = manifest_mod.Manifest;
pub const Entry = manifest_mod.Entry;
pub const Kind = manifest_mod.Kind;

pub const SwarmFolder = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    store: *storage.engine.StorageEngine,
    block_manager: ?*cluster.BlockManager = null,
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
    sync_interval_ns: u64 = 10 * std.time.ns_per_s,
    /// Serialises sync rounds (the loop and syncNow).
    sync_mutex: sync.Mutex = .{},
    running: std.atomic.Value(bool) = .init(false),
    thread: ?std.Thread = null,

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
        self.load() catch |err| std.debug.print("swarm: starting with an empty folder ({any})\n", .{err});
        return self;
    }

    pub fn destroy(self: *SwarmFolder) void {
        self.stop();
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
        if (size > 64 * 1024 * 1024) return error.ManifestTooLarge;
        const bytes = try self.allocator.alloc(u8, @intCast(size));
        defer self.allocator.free(bytes);
        _ = try file.readPositionalAll(self.io, bytes, 0);
        _ = try self.manifest.mergeEncoded(bytes);
    }

    /// Caller holds `mutex`. Written to a temp file and renamed into place.
    fn saveLocked(self: *SwarmFolder) !void {
        const bytes = try self.manifest.encode(self.allocator);
        defer self.allocator.free(bytes);
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

    /// Reads a file's bytes: from the local store, else the device that
    /// added it, else any other known peer.
    pub fn readAt(self: *SwarmFolder, allocator: std.mem.Allocator, cid: [32]u8, author: [32]u8, offset: u64, dest: []u8) !usize {
        const bm = self.block_manager orelse return error.NotRunning;
        const known = try remote_mod.knownPeers(bm, allocator);
        defer allocator.free(known);
        var peers: std.ArrayList(NodeID) = .empty;
        defer peers.deinit(allocator);
        try peers.append(allocator, .{ .bytes = author });
        for (known) |p| if (!std.mem.eql(u8, &p.bytes, &author)) try peers.append(allocator, p);
        var multi = remote_mod.MultiRemote{ .block_manager = bm, .store = self.store, .peers = peers.items };
        return tree.readAt(allocator, multi.loader(), cid, offset, dest);
    }

    // ---- Sync ----

    /// Adapter for discovery Node.swarm_source (GET_SWARM).
    pub fn source(self: *SwarmFolder) ShareSource {
        return .{ .ctx = self, .listFn = encodeErased };
    }

    fn encodeErased(ctx: *anyopaque, allocator: std.mem.Allocator) anyerror![]u8 {
        const self: *SwarmFolder = @ptrCast(@alignCast(ctx));
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.manifest.encode(allocator);
    }

    pub const Status = struct { entries: usize, peers_synced: u32, last_sync: u64 };

    pub fn status(self: *SwarmFolder) Status {
        self.mutex.lock();
        defer self.mutex.unlock();
        var live: usize = 0;
        for (self.manifest.entries.values()) |e| {
            if (!e.deleted) live += 1;
        }
        return .{ .entries = live, .peers_synced = self.peers_synced, .last_sync = self.last_sync };
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
        for (peers) |peer| {
            const conn = bm.connectTo(peer) catch continue;
            defer conn.deinit();
            const bytes = bm.dht_node.fetchSwarm(conn) catch continue;
            defer bm.dht_node.allocator.free(bytes);
            reached += 1;
            self.mutex.lock();
            defer self.mutex.unlock();
            changed += self.manifest.mergeEncoded(bytes) catch continue;
        }
        self.mutex.lock();
        defer self.mutex.unlock();
        self.peers_synced = reached;
        self.last_sync = self.now();
        if (changed > 0) self.saveLocked() catch |err| std.debug.print("swarm: saving the manifest failed: {any}\n", .{err});
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
