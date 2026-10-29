//! Folder backup. A device marks some of its shares for backup (a phone's
//! camera folder); every swarm backup device keeps a copy of the marked
//! shares of the swarm's members:
//!
//! - It asks each member which shares it wants kept (the SHARES `backup`
//!   field), copies every block of a share whose root changed, and keeps
//!   them (`RepairManager.syncWhile` stores into the kept area).
//! - It merges each new version into its own tree of that share: files and
//!   folders deleted at the source stay, so a phone can free space without
//!   losing a photo. The newest version of a file wins.
//! - It lists that tree as a share of its own, `<device> · <share>
//!   (backup)`, which any device can browse and restore from while the
//!   source is off, and tells everyone which backups it holds, so the
//!   source can show where it is backed up.

const std = @import("std");
const sync = @import("../sync.zig");
const storage = @import("../storage/mod.zig");
const codec = storage.dag.codec;
const Cid = codec.Cid;
const tree = @import("tree.zig");
const remote_mod = @import("remote.zig");
const shares_mod = @import("shares.zig");
const cluster = @import("../cluster/mod.zig");
const device_trust = @import("../device/trust.zig");

// ---- The SHARES `backup` field ----

const info_version: u8 = 1;
/// Most entries of either list a reply carries.
pub const max_info_entries = 255;

/// A backup a device holds for another one.
pub const HeldInfo = struct {
    owner: [32]u8,
    share: []const u8,
    /// The owner's share root last copied: equal to the owner's current
    /// root means the backup is up to date.
    source_root: Cid,
    synced_at: u64,
};

pub const Info = struct {
    /// Shares the sender asks backup devices to keep.
    wanted: []const []const u8 = &.{},
    /// Backups the sender holds for others.
    held: []const HeldInfo = &.{},
    arena: std.heap.ArenaAllocator,

    pub fn deinit(self: *Info) void {
        self.arena.deinit();
    }
};

/// `[u8 version][u8 n]{[u8 len][name]}[u8 m]{[owner 32][u8 len][share][root 32][u64 synced_at]}`.
pub fn encodeInfo(allocator: std.mem.Allocator, wanted: []const []const u8, held: []const HeldInfo) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.append(allocator, info_version);
    const n = @min(wanted.len, max_info_entries);
    try out.append(allocator, @intCast(n));
    for (wanted[0..n]) |name| try appendName(allocator, &out, name);
    const m = @min(held.len, max_info_entries);
    try out.append(allocator, @intCast(m));
    for (held[0..m]) |h| {
        try out.appendSlice(allocator, &h.owner);
        try appendName(allocator, &out, h.share);
        try out.appendSlice(allocator, &h.source_root);
        var at: [8]u8 = undefined;
        std.mem.writeInt(u64, &at, h.synced_at, .big);
        try out.appendSlice(allocator, &at);
    }
    return out.toOwnedSlice(allocator);
}

fn appendName(allocator: std.mem.Allocator, out: *std.ArrayList(u8), name: []const u8) !void {
    if (!codec.isValidName(name)) return error.InvalidName;
    try out.append(allocator, @intCast(name.len));
    try out.appendSlice(allocator, name);
}

/// Decodes a `backup` field; an empty one (an older sender, or nothing to
/// say) is an empty Info. Names are validated like any share name.
pub fn decodeInfo(allocator: std.mem.Allocator, bytes: []const u8) !Info {
    var info = Info{ .arena = std.heap.ArenaAllocator.init(allocator) };
    errdefer info.deinit();
    if (bytes.len == 0) return info;
    const a = info.arena.allocator();
    var r = Reader{ .bytes = bytes };
    if (try r.byte() != info_version) return error.UnsupportedBackupInfo;
    const n = try r.byte();
    const wanted = try a.alloc([]const u8, n);
    for (wanted) |*w| w.* = try r.name();
    const m = try r.byte();
    const held = try a.alloc(HeldInfo, m);
    for (held) |*h| {
        h.owner = (try r.take(32))[0..32].*;
        h.share = try r.name();
        h.source_root = (try r.take(32))[0..32].*;
        h.synced_at = std.mem.readInt(u64, (try r.take(8))[0..8], .big);
    }
    if (r.pos != bytes.len) return error.InvalidBackupInfo;
    info.wanted = wanted;
    info.held = held;
    return info;
}

const Reader = struct {
    bytes: []const u8,
    pos: usize = 0,

    fn take(self: *Reader, n: usize) ![]const u8 {
        if (self.bytes.len - self.pos < n) return error.InvalidBackupInfo;
        defer self.pos += n;
        return self.bytes[self.pos..][0..n];
    }
    fn byte(self: *Reader) !u8 {
        return (try self.take(1))[0];
    }
    fn name(self: *Reader) ![]const u8 {
        const s = try self.take(try self.byte());
        if (!codec.isValidName(s)) return error.InvalidBackupInfo;
        return s;
    }
};

// ---- Merging: what was deleted at the source stays ----

pub const Merged = struct { root: Cid, size: u64 };

/// The union of the dir trees `old` and `new`, both held in `store`: every
/// entry of `new`, plus every entry of `old` that `new` no longer has. Where
/// both have a folder of the same name the folders are merged; otherwise
/// `new` wins. Writes the merged dir blocks into the kept area.
pub fn merge(allocator: std.mem.Allocator, store: *storage.engine.StorageEngine, old: ?Cid, new: Cid) !Merged {
    const loader = tree.Loader.local(store);
    var new_list = try tree.listDir(allocator, loader, &new);
    defer new_list.deinit();
    const old_cid = old orelse return .{ .root = new, .size = sumSizes(new_list.entries) };
    if (std.mem.eql(u8, &old_cid, &new)) return .{ .root = new, .size = sumSizes(new_list.entries) };
    var old_list = try tree.listDir(allocator, loader, &old_cid);
    defer old_list.deinit();

    // Child merges produce new CIDs; keep them alive until the encode.
    var cids: std.ArrayList(Cid) = .empty;
    defer cids.deinit(allocator);
    try cids.ensureTotalCapacity(allocator, new_list.entries.len + old_list.entries.len);
    var entries: std.ArrayList(codec.DirEntry) = .empty;
    defer entries.deinit(allocator);

    for (new_list.entries) |e| {
        var cid = e.cid;
        var size = e.size;
        if (e.kind == .dir) if (old_list.find(e.name)) |o| if (o.kind == .dir and !std.mem.eql(u8, &o.cid, &e.cid)) {
            const m = try merge(allocator, store, o.cid, e.cid);
            cid = m.root;
            size = m.size;
        };
        cids.appendAssumeCapacity(cid);
        try entries.append(allocator, .{ .name = e.name, .cid = &cids.items[cids.items.len - 1], .size = size, .kind = e.kind, .mtime = e.mtime });
    }
    for (old_list.entries) |o| {
        if (new_list.find(o.name) != null) continue;
        cids.appendAssumeCapacity(o.cid);
        try entries.append(allocator, .{ .name = o.name, .cid = &cids.items[cids.items.len - 1], .size = o.size, .kind = o.kind, .mtime = o.mtime });
    }
    std.mem.sort(codec.DirEntry, entries.items, {}, struct {
        fn less(_: void, a: codec.DirEntry, b: codec.DirEntry) bool {
            return std.mem.order(u8, a.name, b.name) == .lt;
        }
    }.less);
    const bytes = try codec.encodeDir(allocator, entries.items);
    defer allocator.free(bytes);
    const block = storage.block.Block.new(bytes);
    try store.put(block);
    var size: u64 = 0;
    for (entries.items) |e| size +|= e.size;
    return .{ .root = block.cid, .size = size };
}

fn sumSizes(entries: []const tree.Entry) u64 {
    var size: u64 = 0;
    for (entries) |e| size +|= e.size;
    return size;
}

/// The name a backup is listed under: `<device> · <share> (backup)`, made
/// a valid entry name.
pub fn displayName(buf: []u8, device: []const u8, share: []const u8) []const u8 {
    const raw = std.fmt.bufPrint(buf, "{s} · {s} (backup)", .{ device, share }) catch buf[0..@min(buf.len, codec.max_name_len)];
    const out = buf[0..@min(raw.len, codec.max_name_len)];
    for (out) |*c| if (c.* == '/' or c.* == '\\' or c.* == 0) {
        c.* = '-';
    };
    return out;
}

// ---- The backup device ----

pub const FolderBackup = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    store: *storage.engine.StorageEngine,
    shares: *shares_mod.ShareIndex,
    trust: *device_trust.Store,
    block_manager: *cluster.BlockManager,
    /// Whether this device is a swarm backup device (SwarmFolder's flag).
    enabled: *const std.atomic.Value(bool),
    /// Where the held backups are remembered across restarts.
    state_path: []u8,
    interval_ns: u64 = 60 * std.time.ns_per_s,
    running: std.atomic.Value(bool) = .init(false),
    thread: ?std.Thread = null,
    /// Serializes rounds and state saves.
    round_mutex: sync.Mutex = .{},

    pub fn create(
        allocator: std.mem.Allocator,
        io: std.Io,
        store: *storage.engine.StorageEngine,
        shares: *shares_mod.ShareIndex,
        trust: *device_trust.Store,
        block_manager: *cluster.BlockManager,
        enabled: *const std.atomic.Value(bool),
        state_path: []const u8,
    ) !*FolderBackup {
        const self = try allocator.create(FolderBackup);
        errdefer allocator.destroy(self);
        self.* = .{
            .allocator = allocator,
            .io = io,
            .store = store,
            .shares = shares,
            .trust = trust,
            .block_manager = block_manager,
            .enabled = enabled,
            .state_path = try allocator.dupe(u8, state_path),
        };
        self.load() catch |err| std.debug.print("backup: couldn't read {s}: {any}\n", .{ state_path, err });
        return self;
    }

    pub fn destroy(self: *FolderBackup) void {
        self.stop();
        self.allocator.free(self.state_path);
        self.allocator.destroy(self);
    }

    pub fn start(self: *FolderBackup) !void {
        if (self.thread != null) return;
        self.running.store(true, .release);
        self.thread = try std.Thread.spawn(.{}, loop, .{self});
    }

    pub fn stop(self: *FolderBackup) void {
        self.running.store(false, .release);
        if (self.thread) |t| t.join();
        self.thread = null;
    }

    fn loop(self: *FolderBackup) void {
        // A little after start, then every interval; only while this
        // device is a backup device.
        var wait: u64 = 15 * std.time.ns_per_s;
        while (true) {
            const step = 100 * std.time.ns_per_ms;
            var slept: u64 = 0;
            while (slept < wait) : (slept += step) {
                if (!self.running.load(.acquire)) return;
                sync.sleep(step);
            }
            wait = self.interval_ns;
            if (!self.enabled.load(.acquire)) continue;
            _ = self.round() catch |err| std.debug.print("backup: round failed: {any}\n", .{err});
        }
    }

    /// One pass over the swarm's members: copies every marked share whose
    /// root changed. Returns how many shares were brought up to date.
    pub fn round(self: *FolderBackup) !usize {
        self.round_mutex.lock();
        defer self.round_mutex.unlock();
        const peers = try remote_mod.knownPeers(self.block_manager, self.allocator);
        defer self.allocator.free(peers);
        var updated: usize = 0;
        for (peers) |peer| {
            if (!self.running.load(.acquire) or !self.enabled.load(.acquire)) break;
            updated += self.backUpPeer(peer) catch |err| blk: {
                std.debug.print("backup: {x}: {any}\n", .{ peer.bytes[0..4], err });
                break :blk 0;
            };
        }
        return updated;
    }

    fn backUpPeer(self: *FolderBackup, peer: @import("../net/id.zig").NodeID) !usize {
        var remote = remote_mod.Remote{ .block_manager = self.block_manager, .store = self.store, .peer = peer };
        var listed = try remote.shares(self.allocator);
        defer listed.deinit(self.allocator);
        // Only the swarm's members are backed up.
        const owner = listed.device_id orelse return 0;
        const member = self.trust.lookup(owner) orelse return 0;
        var info = decodeInfo(self.allocator, listed.backup) catch return 0;
        defer info.deinit();

        var updated: usize = 0;
        for (info.wanted) |share| {
            const entry = listed.listing.find(share) orelse continue;
            if (entry.kind != .dir) continue;
            if (self.findHeld(owner.bytes, share)) |h| if (std.mem.eql(u8, &h.source_root, &entry.cid)) continue;
            try self.copyShare(peer, owner.bytes, member.labelSlice(), share, entry.cid);
            updated += 1;
        }
        return updated;
    }

    fn findHeld(self: *FolderBackup, owner: [32]u8, share: []const u8) ?shares_mod.ShareIndex.Held {
        const held = self.shares.heldSnapshot(self.allocator) catch return null;
        defer shares_mod.ShareIndex.freeHeldSnapshot(self.allocator, held);
        for (held) |h| if (std.mem.eql(u8, &h.owner, &owner) and std.mem.eql(u8, h.share, share)) {
            var copy = h;
            copy.share = &.{};
            copy.display = &.{};
            return copy;
        };
        return null;
    }

    fn copyShare(self: *FolderBackup, peer: @import("../net/id.zig").NodeID, owner: [32]u8, label: []const u8, share: []const u8, root: Cid) !void {
        const conn = try self.block_manager.connectTo(peer);
        defer conn.deinit();
        const fetched = try cluster.repair.RepairManager.syncWhile(self.allocator, self.block_manager.dht_node, self.store, conn, &root, self.enabled);
        const previous = self.findHeld(owner, share);
        const merged = try merge(self.allocator, self.store, if (previous) |p| p.root else null, root);
        var name_buf: [codec.max_name_len + 64]u8 = undefined;
        const display = displayName(&name_buf, label, share);
        try self.shares.setHeld(.{
            .owner = owner,
            .share = @constCast(share),
            .display = @constCast(display),
            .root = merged.root,
            .source_root = root,
            .size = merged.size,
            .synced_at = std.math.cast(u64, sync.timestamp()) orelse 0,
        });
        try self.save();
        std.debug.print("backup: kept {s} ({d} new blocks)\n", .{ display, fetched });
    }

    // ---- State: `owner\tshare_b64\tdisplay_b64\troot\tsource_root\tsize\tsynced_at` per line ----

    fn save(self: *FolderBackup) !void {
        const held = try self.shares.heldSnapshot(self.allocator);
        defer shares_mod.ShareIndex.freeHeldSnapshot(self.allocator, held);
        var out: std.Io.Writer.Allocating = .init(self.allocator);
        defer out.deinit();
        const b64 = std.base64.url_safe_no_pad.Encoder;
        for (held) |h| {
            var share_buf: [512]u8 = undefined;
            var display_buf: [512]u8 = undefined;
            try out.writer.print("{s}\t{s}\t{s}\t{s}\t{s}\t{d}\t{d}\n", .{
                std.fmt.bytesToHex(h.owner, .lower),
                b64.encode(&share_buf, h.share),
                b64.encode(&display_buf, h.display),
                std.fmt.bytesToHex(h.root, .lower),
                std.fmt.bytesToHex(h.source_root, .lower),
                h.size,
                h.synced_at,
            });
        }
        var tmp_buf: [std.fs.max_path_bytes]u8 = undefined;
        const tmp = try std.fmt.bufPrint(&tmp_buf, "{s}.tmp", .{self.state_path});
        const cwd = std.Io.Dir.cwd();
        {
            var file = try cwd.createFile(self.io, tmp, .{ .truncate = true });
            defer file.close(self.io);
            try file.writePositionalAll(self.io, out.written(), 0);
            try file.sync(self.io);
        }
        try cwd.rename(tmp, cwd, self.state_path, self.io);
    }

    fn load(self: *FolderBackup) !void {
        const cwd = std.Io.Dir.cwd();
        var file = cwd.openFile(self.io, self.state_path, .{}) catch |err| switch (err) {
            error.FileNotFound => return,
            else => return err,
        };
        defer file.close(self.io);
        const size = (try file.stat(self.io)).size;
        if (size > 4 * 1024 * 1024) return error.StateTooLarge;
        const text = try self.allocator.alloc(u8, @intCast(size));
        defer self.allocator.free(text);
        _ = try file.readPositionalAll(self.io, text, 0);
        const b64 = std.base64.url_safe_no_pad.Decoder;
        var lines = std.mem.splitScalar(u8, text, '\n');
        while (lines.next()) |line| {
            if (line.len == 0) continue;
            var f = std.mem.splitScalar(u8, line, '\t');
            var h: shares_mod.ShareIndex.Held = undefined;
            _ = std.fmt.hexToBytes(&h.owner, f.next() orelse continue) catch continue;
            var share_buf: [512]u8 = undefined;
            var display_buf: [512]u8 = undefined;
            const share_text = f.next() orelse continue;
            const display_text = f.next() orelse continue;
            const share_len = b64.calcSizeForSlice(share_text) catch continue;
            const display_len = b64.calcSizeForSlice(display_text) catch continue;
            if (share_len > share_buf.len or display_len > display_buf.len) continue;
            b64.decode(share_buf[0..share_len], share_text) catch continue;
            b64.decode(display_buf[0..display_len], display_text) catch continue;
            _ = std.fmt.hexToBytes(&h.root, f.next() orelse continue) catch continue;
            _ = std.fmt.hexToBytes(&h.source_root, f.next() orelse continue) catch continue;
            h.size = std.fmt.parseInt(u64, f.next() orelse continue, 10) catch continue;
            h.synced_at = std.fmt.parseInt(u64, f.next() orelse continue, 10) catch continue;
            h.share = share_buf[0..share_len];
            h.display = display_buf[0..display_len];
            if (!codec.isValidName(h.share) or !codec.isValidName(h.display)) continue;
            try self.shares.setHeld(h);
        }
    }
};

test "backup: the info field round-trips and rejects junk" {
    const a = std.testing.allocator;
    const held = [_]HeldInfo{.{ .owner = [_]u8{7} ** 32, .share = "Camera", .source_root = [_]u8{9} ** 32, .synced_at = 42 }};
    const bytes = try encodeInfo(a, &.{ "Camera", "Screenshots" }, &held);
    defer a.free(bytes);
    var info = try decodeInfo(a, bytes);
    defer info.deinit();
    try std.testing.expectEqual(@as(usize, 2), info.wanted.len);
    try std.testing.expectEqualStrings("Screenshots", info.wanted[1]);
    try std.testing.expectEqualStrings("Camera", info.held[0].share);
    try std.testing.expectEqual(@as(u64, 42), info.held[0].synced_at);
    var empty = try decodeInfo(a, "");
    defer empty.deinit();
    try std.testing.expectEqual(@as(usize, 0), empty.wanted.len);
    try std.testing.expectError(error.InvalidBackupInfo, decodeInfo(a, bytes[0 .. bytes.len - 1]));
}

test "backup: merging keeps what the new version no longer has" {
    const a = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const path = "test_backup_merge";
    std.Io.Dir.cwd().deleteTree(io, path) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, path) catch {};
    var store = try storage.engine.StorageEngine.init(a, path);
    defer store.deinit();

    const put = struct {
        fn dir(s: *storage.engine.StorageEngine, al: std.mem.Allocator, entries: []const codec.DirEntry) !Cid {
            const bytes = try codec.encodeDir(al, entries);
            defer al.free(bytes);
            const b = storage.block.Block.new(bytes);
            try s.put(b);
            return b.cid;
        }
    }.dir;
    const f1 = [_]u8{1} ** 32;
    const f2 = [_]u8{2} ** 32;
    const f3 = [_]u8{3} ** 32;
    // v1: a.jpg, b.jpg, sub/old.jpg. v2: b.jpg changed, c.jpg new, a.jpg and sub/old.jpg deleted.
    const sub_v1 = try put(&store, a, &.{.{ .name = "old.jpg", .cid = &f1, .size = 5, .kind = .file, .mtime = 1 }});
    const v1 = try put(&store, a, &.{
        .{ .name = "a.jpg", .cid = &f1, .size = 10, .kind = .file, .mtime = 1 },
        .{ .name = "b.jpg", .cid = &f1, .size = 10, .kind = .file, .mtime = 1 },
        .{ .name = "sub", .cid = &sub_v1, .size = 5, .kind = .dir, .mtime = 1 },
    });
    const sub_v2 = try put(&store, a, &.{.{ .name = "new.jpg", .cid = &f3, .size = 7, .kind = .file, .mtime = 2 }});
    const v2 = try put(&store, a, &.{
        .{ .name = "b.jpg", .cid = &f2, .size = 20, .kind = .file, .mtime = 2 },
        .{ .name = "c.jpg", .cid = &f3, .size = 30, .kind = .file, .mtime = 2 },
        .{ .name = "sub", .cid = &sub_v2, .size = 7, .kind = .dir, .mtime = 2 },
    });

    const m = try merge(a, &store, v1, v2);
    var top = try tree.listDir(a, tree.Loader.local(&store), &m.root);
    defer top.deinit();
    try std.testing.expectEqual(@as(usize, 4), top.entries.len);
    try std.testing.expect(top.find("a.jpg") != null); // deleted at the source, kept
    try std.testing.expectEqual(f2, top.find("b.jpg").?.cid); // the newer version wins
    try std.testing.expect(top.find("c.jpg") != null);
    var sub = try tree.listDir(a, tree.Loader.local(&store), &top.find("sub").?.cid);
    defer sub.deinit();
    try std.testing.expectEqual(@as(usize, 2), sub.entries.len); // old.jpg kept, new.jpg added
    try std.testing.expectEqual(@as(u64, 10 + 20 + 30 + 12), m.size);
}
