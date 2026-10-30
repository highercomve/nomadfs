//! Backed-up shares go into the swarm folder. A share this device marks for
//! backup (a phone's Camera) appears there as `<device>/<share>/...`, every
//! file with its own modified time, and swarm backup devices keep a copy of
//! it like any swarm file (cluster/keeper.zig).
//!
//! Backup, not mirror: a file deleted from the share stays in the swarm
//! folder. One deleted (or moved) in the swarm folder is not added again:
//! the content of every file ever imported is remembered (`imported`, saved
//! next to the manifest), so only new or edited files come in. The blocks
//! are the ones the share's scan already put in the store: nothing is
//! copied. Imports run only on an unmetered network, so a phone on mobile
//! data doesn't hand out its photos.

const std = @import("std");
const tree = @import("tree.zig");
const shares_mod = @import("shares.zig");
const swarm_mod = @import("swarm.zig");
const codec = @import("../storage/dag/codec.zig");
const storage = @import("../storage/mod.zig");
const device_trust = @import("../device/trust.zig");

const Cid = [32]u8;

/// Folder levels walked below a share.
const max_depth = 32;
/// Files taken from one share in a round (the manifest's own cap).
const max_files = @import("manifest.zig").max_entries;
/// Contents remembered as imported (32 bytes each on disk).
const max_imported = 1 << 20;

pub const BackupImport = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    swarm: *swarm_mod.SwarmFolder,
    shares: *shares_mod.ShareIndex,
    store: *storage.engine.StorageEngine,
    /// The folder this device's shares go into (its name in the swarm).
    device: []u8,
    /// Where `imported` is saved.
    path: []u8,
    /// Whether this device may import now (an unmetered network).
    allowed: *const fn () bool,
    /// Contents imported once, ever.
    imported: std.AutoHashMapUnmanaged(Cid, void) = .empty,
    /// Share name -> the root last imported, so an unchanged share costs
    /// nothing. Only touched on the swarm folder's thread.
    done: std.StringHashMapUnmanaged(Cid) = .empty,

    pub fn create(
        allocator: std.mem.Allocator,
        io: std.Io,
        swarm: *swarm_mod.SwarmFolder,
        shares: *shares_mod.ShareIndex,
        store: *storage.engine.StorageEngine,
        device: []const u8,
        path: []const u8,
        allowed: *const fn () bool,
    ) !*BackupImport {
        const self = try allocator.create(BackupImport);
        errdefer allocator.destroy(self);
        const name = try folderName(allocator, device);
        errdefer allocator.free(name);
        const owned_path = try allocator.dupe(u8, path);
        errdefer allocator.free(owned_path);
        self.* = .{ .allocator = allocator, .io = io, .swarm = swarm, .shares = shares, .store = store, .device = name, .path = owned_path, .allowed = allowed };
        errdefer self.imported.deinit(allocator);
        try self.load();
        return self;
    }

    pub fn destroy(self: *BackupImport) void {
        var it = self.done.keyIterator();
        while (it.next()) |k| self.allocator.free(k.*);
        self.done.deinit(self.allocator);
        self.imported.deinit(self.allocator);
        self.allocator.free(self.device);
        self.allocator.free(self.path);
        self.allocator.destroy(self);
    }

    /// The swarm folder's after-sync hook.
    pub fn hook(self: *BackupImport) swarm_mod.SwarmFolder.AfterSync {
        return .{ .ctx = self, .runFn = runErased };
    }

    fn runErased(ctx: *anyopaque) void {
        const self: *BackupImport = @ptrCast(@alignCast(ctx));
        _ = self.run() catch |err| std.debug.print("backup: importing into the swarm folder failed: {any}\n", .{err});
    }

    /// Imports every marked share that changed since its last import.
    /// Returns how many files were added.
    pub fn run(self: *BackupImport) !usize {
        if (!self.allowed()) return 0;
        const snap = try self.shares.snapshot(self.allocator);
        defer shares_mod.ShareIndex.freeSnapshot(self.allocator, snap);
        var added: usize = 0;
        for (snap) |s| {
            if (!self.shares.isBackup(s.name)) continue;
            const root = s.root orelse continue;
            if (s.indexing) continue; // partial: wait for the whole scan
            if (self.done.get(s.name)) |r| if (std.mem.eql(u8, &r, &root)) continue;
            added += try self.importShare(s.name, root);
            try self.remember(s.name, root);
        }
        return added;
    }

    fn importShare(self: *BackupImport, share: []const u8, root: Cid) !usize {
        var arena_state = std.heap.ArenaAllocator.init(self.allocator);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        var files: std.ArrayList(swarm_mod.SwarmFolder.Import) = .empty;
        const base = try std.fmt.allocPrint(arena, "{s}/{s}", .{ self.device, share });
        try self.collect(arena, base, root, 0, &files);
        if (files.items.len == 0) return 0;
        const added = try self.swarm.importFiles(files.items);
        // Remembered once in the swarm folder: deleting or moving it there
        // is final, even after the deletion is forgotten.
        for (files.items) |f| {
            if (self.imported.count() >= max_imported) break;
            try self.imported.put(self.allocator, f.cid, {});
        }
        try self.save();
        if (added > 0) std.debug.print("backup: {d} file(s) of {s} added to the swarm folder\n", .{ added, share });
        return added;
    }

    /// Files under `dir` not imported before, with their paths below `base`.
    fn collect(self: *BackupImport, arena: std.mem.Allocator, base: []const u8, dir: Cid, depth: usize, out: *std.ArrayList(swarm_mod.SwarmFolder.Import)) !void {
        if (depth >= max_depth) return;
        const listing = tree.listDir(arena, tree.Loader.local(self.store), &dir) catch |err| switch (err) {
            error.BlockNotFound => return, // not scanned in yet
            else => return err,
        };
        for (listing.entries) |e| {
            if (out.items.len >= max_files) return;
            const path = try std.fmt.allocPrint(arena, "{s}/{s}", .{ base, e.name });
            switch (e.kind) {
                .dir => try self.collect(arena, path, e.cid, depth + 1, out),
                .file => {
                    if (self.imported.contains(e.cid)) continue;
                    try out.append(arena, .{ .path = path, .cid = e.cid, .size = e.size, .mtime = e.mtime });
                },
            }
        }
    }

    fn remember(self: *BackupImport, share: []const u8, root: Cid) !void {
        if (self.done.getPtr(share)) |r| {
            r.* = root;
            return;
        }
        const key = try self.allocator.dupe(u8, share);
        errdefer self.allocator.free(key);
        try self.done.put(self.allocator, key, root);
    }

    // ---- The imported contents, on disk: 32 bytes each ----

    fn load(self: *BackupImport) !void {
        var file = std.Io.Dir.cwd().openFile(self.io, self.path, .{}) catch |err| switch (err) {
            error.FileNotFound => return,
            else => return err,
        };
        defer file.close(self.io);
        const size = (try file.stat(self.io)).size;
        if (size % 32 != 0 or size / 32 > max_imported) {
            std.debug.print("backup: {s} is not a list of contents; starting empty\n", .{self.path});
            return;
        }
        const bytes = try self.allocator.alloc(u8, @intCast(size));
        defer self.allocator.free(bytes);
        if (try file.readPositionalAll(self.io, bytes, 0) != bytes.len) return error.ShortRead;
        try self.imported.ensureTotalCapacity(self.allocator, @intCast(size / 32));
        var i: usize = 0;
        while (i < bytes.len) : (i += 32) self.imported.putAssumeCapacity(bytes[i..][0..32].*, {});
    }

    fn save(self: *BackupImport) !void {
        const bytes = try self.allocator.alloc(u8, self.imported.count() * 32);
        defer self.allocator.free(bytes);
        var it = self.imported.keyIterator();
        var i: usize = 0;
        while (it.next()) |k| : (i += 32) @memcpy(bytes[i..][0..32], k);
        const tmp = try std.fmt.allocPrint(self.allocator, "{s}.tmp", .{self.path});
        defer self.allocator.free(tmp);
        {
            var file = try std.Io.Dir.cwd().createFile(self.io, tmp, .{ .truncate = true });
            defer file.close(self.io);
            try file.writePositionalAll(self.io, bytes, 0);
        }
        try std.Io.Dir.cwd().rename(tmp, std.Io.Dir.cwd(), self.path, self.io);
    }

    // ---- Status ----

    pub const ShareStatus = struct {
        share: []const u8,
        /// Where it is in the swarm folder: `<device>/<share>`.
        path: []const u8,
        /// Files there now.
        files: usize,
    };

    /// The shares marked for backup and where they are in the swarm
    /// folder. Allocated in `allocator`: pass an arena.
    pub fn status(self: *BackupImport, allocator: std.mem.Allocator) ![]ShareStatus {
        const snap = try self.shares.snapshot(allocator);
        var out: std.ArrayList(ShareStatus) = .empty;
        for (snap) |s| {
            if (!self.shares.isBackup(s.name)) continue;
            const path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ self.device, s.name });
            try out.append(allocator, .{ .share = s.name, .path = path, .files = self.swarm.filesUnder(path) });
        }
        return out.toOwnedSlice(allocator);
    }
};

// ---- The backups kept before they went into the swarm folder ----

/// Moves the folder backups a backup device used to keep on its own
/// (`<storage>.backups`, one tree per member's share) into the swarm folder
/// at `<member>/<share>/`, where the members' backups go now. The blocks
/// are already here; files a member deleted since stay, at their old paths
/// (the old `Deleted before …` folders are unwrapped). The state file is
/// renamed `.migrated` once done. Returns how many files were added.
pub fn migrateOldBackups(
    allocator: std.mem.Allocator,
    io: std.Io,
    swarm: *swarm_mod.SwarmFolder,
    store: *storage.engine.StorageEngine,
    trust: *device_trust.Store,
    state_path: []const u8,
) !usize {
    const cwd = std.Io.Dir.cwd();
    const text = blk: {
        var file = cwd.openFile(io, state_path, .{}) catch |err| switch (err) {
            error.FileNotFound => return 0,
            else => return err,
        };
        defer file.close(io);
        const size = (try file.stat(io)).size;
        if (size > 64 * 1024 * 1024) return error.StateTooLarge;
        const buf = try allocator.alloc(u8, @intCast(size));
        errdefer allocator.free(buf);
        if (try file.readPositionalAll(io, buf, 0) != buf.len) return error.ShortRead;
        break :blk buf;
    };
    defer allocator.free(text);

    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var files: std.ArrayList(swarm_mod.SwarmFolder.Import) = .empty;
    const b64 = std.base64.url_safe_no_pad.Decoder;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        // owner, share, display (base64), root, source_root, size, synced_at
        var f = std.mem.splitScalar(u8, line, '\t');
        const owner = hex32(f.next() orelse continue) orelse continue;
        const share_b64 = f.next() orelse continue;
        const display_b64 = f.next() orelse continue;
        const root = hex32(f.next() orelse continue) orelse continue;
        const share = try arena.alloc(u8, b64.calcSizeForSlice(share_b64) catch continue);
        b64.decode(share, share_b64) catch continue;
        const device = if (trust.lookup(.{ .bytes = owner })) |e| try arena.dupe(u8, e.labelSlice()) else blk: {
            // Not a member any more: the device part of the name it was
            // listed under (`<device> · <share> (backup)`).
            const display = try arena.alloc(u8, b64.calcSizeForSlice(display_b64) catch continue);
            b64.decode(display, display_b64) catch continue;
            break :blk display[0 .. std.mem.indexOf(u8, display, " · ") orelse display.len];
        };
        const base = try std.fmt.allocPrint(arena, "{s}/{s}", .{ try folderName(arena, device), share });
        collectKept(arena, store, base, root, 0, &files) catch |err|
            std.debug.print("backup: {s}: part of the old backup can't be read: {any}\n", .{ base, err });
    }
    const added = if (files.items.len > 0) try swarm.importFiles(files.items) else 0;
    var aside_buf: [std.fs.max_path_bytes]u8 = undefined;
    const aside = try std.fmt.bufPrint(&aside_buf, "{s}.migrated", .{state_path});
    try cwd.rename(state_path, cwd, aside, io);
    std.debug.print("backup: moved {d} file(s) of the old folder backups into the swarm folder\n", .{added});
    return added;
}

/// Files of a kept tree, with `Deleted before …` folders unwrapped.
fn collectKept(arena: std.mem.Allocator, store: *storage.engine.StorageEngine, base: []const u8, dir: Cid, depth: usize, out: *std.ArrayList(swarm_mod.SwarmFolder.Import)) !void {
    if (depth >= max_depth) return;
    const listing = try tree.listDir(arena, tree.Loader.local(store), &dir);
    for (listing.entries) |e| {
        if (out.items.len >= max_files) return;
        switch (e.kind) {
            .dir => {
                const path = if (std.mem.startsWith(u8, e.name, "Deleted before ")) base else try std.fmt.allocPrint(arena, "{s}/{s}", .{ base, e.name });
                try collectKept(arena, store, path, e.cid, depth + 1, out);
            },
            .file => try out.append(arena, .{ .path = try std.fmt.allocPrint(arena, "{s}/{s}", .{ base, e.name }), .cid = e.cid, .size = e.size, .mtime = e.mtime }),
        }
    }
}

fn hex32(text: []const u8) ?Cid {
    if (text.len != 64) return null;
    var out: Cid = undefined;
    _ = std.fmt.hexToBytes(&out, text) catch return null;
    return out;
}

/// A device's name as a folder name: no slashes, never empty.
fn folderName(allocator: std.mem.Allocator, device: []const u8) ![]u8 {
    const trimmed = std.mem.trim(u8, device, " \t");
    const name = try allocator.dupe(u8, if (trimmed.len == 0) "This device" else trimmed[0..@min(trimmed.len, codec.max_name_len)]);
    for (name) |*c| if (c.* == '/' or c.* == '\\' or c.* == 0) {
        c.* = '-';
    };
    return name;
}

fn alwaysAllowed() bool {
    return true;
}

test "backup import: a marked share goes into the swarm folder, as a backup" {
    const testing = std.testing;
    const allocator = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "Camera/2024");
    try tmp.dir.createDirPath(io, "blocks");
    try tmp.dir.writeFile(io, .{ .sub_path = "Camera/a.jpg", .data = "photo a" });
    try tmp.dir.writeFile(io, .{ .sub_path = "Camera/2024/b.jpg", .data = "photo b" });

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const base = path_buf[0..try tmp.dir.realPath(io, &path_buf)];
    const blocks = try std.fs.path.join(allocator, &.{ base, "blocks" });
    defer allocator.free(blocks);
    const camera = try std.fs.path.join(allocator, &.{ base, "Camera" });
    defer allocator.free(camera);
    const manifest_path = try std.fs.path.join(allocator, &.{ base, "swarm.json" });
    defer allocator.free(manifest_path);
    const imported_path = try std.fs.path.join(allocator, &.{ base, "imported" });
    defer allocator.free(imported_path);

    var store = try storage.engine.StorageEngine.init(allocator, blocks);
    defer store.deinit();
    const index = try shares_mod.ShareIndex.create(allocator, io, &store);
    defer index.destroy();
    try index.add("Camera", camera);
    const folder = try swarm_mod.SwarmFolder.create(allocator, io, &store, .{ .bytes = [_]u8{0x11} ** 32 }, "Pixel", manifest_path);
    defer folder.destroy();
    const imp = try BackupImport.create(allocator, io, folder, index, &store, "Pixel 8", imported_path, alwaysAllowed);
    defer imp.destroy();

    // Not marked: nothing comes in.
    try testing.expectEqual(@as(usize, 0), try imp.run());
    try index.setBackup("Camera", true);
    try testing.expectEqual(@as(usize, 2), try imp.run());
    try testing.expect(folder.fileInfo("Pixel 8/Camera/a.jpg") != null);
    try testing.expect(folder.fileInfo("Pixel 8/Camera/2024/b.jpg") != null);
    // Unchanged: nothing to do.
    try testing.expectEqual(@as(usize, 0), try imp.run());

    // Deleted on the phone: kept. Deleted in the swarm folder: not added again.
    try tmp.dir.deleteFile(io, "Camera/a.jpg");
    try folder.remove("Pixel 8/Camera/2024/b.jpg");
    try tmp.dir.writeFile(io, .{ .sub_path = "Camera/c.jpg", .data = "photo c" });
    try index.add("Camera", camera); // rescan
    try testing.expectEqual(@as(usize, 1), try imp.run()); // only c.jpg
    try testing.expect(folder.fileInfo("Pixel 8/Camera/a.jpg") != null);
    try testing.expect(folder.fileInfo("Pixel 8/Camera/2024/b.jpg") == null);
    try testing.expect(folder.fileInfo("Pixel 8/Camera/c.jpg") != null);

    // Remembered across restarts.
    const again = try BackupImport.create(allocator, io, folder, index, &store, "Pixel 8", imported_path, alwaysAllowed);
    defer again.destroy();
    try testing.expectEqual(@as(usize, 0), try again.run());
}

test "backup import: the old folder backups move into the swarm folder" {
    const testing = std.testing;
    const allocator = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    // A kept tree as the old backup device left it: a file deleted at the
    // source in an overflow folder.
    try tmp.dir.createDirPath(io, "kept/2024");
    try tmp.dir.createDirPath(io, "kept/Deleted before 2026-10-01");
    try tmp.dir.createDirPath(io, "blocks");
    try tmp.dir.writeFile(io, .{ .sub_path = "kept/a.jpg", .data = "a" });
    try tmp.dir.writeFile(io, .{ .sub_path = "kept/2024/b.jpg", .data = "b" });
    try tmp.dir.writeFile(io, .{ .sub_path = "kept/Deleted before 2026-10-01/gone.jpg", .data = "gone" });

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const base = path_buf[0..try tmp.dir.realPath(io, &path_buf)];
    const blocks = try std.fs.path.join(allocator, &.{ base, "blocks" });
    defer allocator.free(blocks);
    const kept = try std.fs.path.join(allocator, &.{ base, "kept" });
    defer allocator.free(kept);
    const manifest_path = try std.fs.path.join(allocator, &.{ base, "swarm.json" });
    defer allocator.free(manifest_path);
    const state_path = try std.fs.path.join(allocator, &.{ base, "store.backups" });
    defer allocator.free(state_path);
    const trust_path = try std.fs.path.join(allocator, &.{ base, "trust.store" });
    defer allocator.free(trust_path);

    var store = try storage.engine.StorageEngine.init(allocator, blocks);
    defer store.deinit();
    const index = try shares_mod.ShareIndex.create(allocator, io, &store);
    defer index.destroy();
    try index.add("kept", kept);
    const snap = try index.snapshot(allocator);
    defer shares_mod.ShareIndex.freeSnapshot(allocator, snap);
    const root = snap[0].root.?;
    const folder = try swarm_mod.SwarmFolder.create(allocator, io, &store, .{ .bytes = [_]u8{0x22} ** 32 }, "Plex", manifest_path);
    defer folder.destroy();
    var trust = try device_trust.Store.load(allocator, trust_path, null);
    defer trust.deinit();

    // A member that's gone: named after the listing's device part.
    const b64 = std.base64.url_safe_no_pad.Encoder;
    var share_buf: [32]u8 = undefined;
    var display_buf: [64]u8 = undefined;
    const line = try std.fmt.allocPrint(allocator, "{s}\t{s}\t{s}\t{s}\t{s}\t9\t1\n", .{
        std.fmt.bytesToHex([_]u8{0xab} ** 32, .lower),
        b64.encode(&share_buf, "Camera"),
        b64.encode(&display_buf, "Pixel · Camera (backup)"),
        std.fmt.bytesToHex(root, .lower),
        std.fmt.bytesToHex(root, .lower),
    });
    defer allocator.free(line);
    try tmp.dir.writeFile(io, .{ .sub_path = "store.backups", .data = line });

    try testing.expectEqual(@as(usize, 3), try migrateOldBackups(allocator, io, folder, &store, &trust, state_path));
    try testing.expect(folder.fileInfo("Pixel/Camera/a.jpg") != null);
    try testing.expect(folder.fileInfo("Pixel/Camera/2024/b.jpg") != null);
    try testing.expect(folder.fileInfo("Pixel/Camera/gone.jpg") != null); // unwrapped
    // Done once: the state is set aside.
    try testing.expectError(error.FileNotFound, tmp.dir.statFile(io, "store.backups", .{}));
    _ = try tmp.dir.statFile(io, "store.backups.migrated", .{});
    try testing.expectEqual(@as(usize, 0), try migrateOldBackups(allocator, io, folder, &store, &trust, state_path));
}
