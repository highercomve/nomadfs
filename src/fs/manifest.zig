//! The swarm folder's listing: one folder every device can read and
//! write, replicated as a state-based CRDT. Each device holds a full
//! manifest (path -> entry) and merges what peers send; any two devices
//! that have seen the same entries hold the same manifest, whatever order
//! they arrived in.
//!
//! An entry carries a version (Lamport clock, device) and the last few
//! versions it replaced. When two versions of a path meet:
//!   - one lists the other in its history: it descends from it and wins;
//!   - neither does: the edits were concurrent. Both are kept. The higher
//!     version (clock, then device) keeps the path; the other moves to
//!     "name (conflict from <author>).ext", computed the same way on every
//!     device. A delete never beats a concurrent edit.
//! Deletes are tombstones, so they replicate like edits.
//!
//! File bytes are not here: an entry names its content by CID, fetched
//! from whichever device holds it when someone opens it.

const std = @import("std");
const codec = @import("../storage/dag/codec.zig");

pub const Cid = codec.Cid;
pub const DeviceId = [32]u8;

/// Versions an entry remembers having replaced.
pub const history_len = 8;
/// Bounds on what a peer may send.
pub const max_path_len = 1024;
pub const max_depth = 32;
pub const max_entries = 100_000;
pub const max_author_len = 64;
pub const max_bytes = 64 * 1024 * 1024;
pub const max_remote_clock = std.math.maxInt(u64) / 2;

pub const Version = struct {
    clock: u64,
    device: DeviceId,

    pub fn eql(a: Version, b: Version) bool {
        return a.clock == b.clock and std.mem.eql(u8, &a.device, &b.device);
    }

    /// Total order for deterministic tie-breaks.
    pub fn greater(a: Version, b: Version) bool {
        if (a.clock != b.clock) return a.clock > b.clock;
        return std.mem.order(u8, &a.device, &b.device) == .gt;
    }
};

pub const Kind = enum(u8) { file = 0, dir = 1 };

pub const Entry = struct {
    /// '/'-separated, no leading slash, every component a valid name.
    path: []u8,
    kind: Kind,
    cid: Cid = [_]u8{0} ** 32,
    size: u64 = 0,
    mtime: u64 = 0,
    version: Version,
    history: [history_len]?Version = [_]?Version{null} ** history_len,
    deleted: bool = false,
    /// Nickname of the device that made this version (display only).
    author: []u8,

    fn deinit(self: Entry, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        allocator.free(self.author);
    }

    fn clone(self: Entry, allocator: std.mem.Allocator) !Entry {
        var out = self;
        out.path = try allocator.dupe(u8, self.path);
        errdefer allocator.free(out.path);
        out.author = try allocator.dupe(u8, self.author);
        return out;
    }

    /// Whether this version has `v` in its past (or is `v`).
    pub fn descendsFrom(self: Entry, v: Version) bool {
        if (self.version.eql(v)) return true;
        for (self.history) |h| {
            if (h) |hv| if (hv.eql(v)) return true;
        }
        return false;
    }
};

/// Validates a path a peer or the user supplied.
pub fn validPath(path: []const u8) bool {
    if (path.len == 0 or path.len > max_path_len) return false;
    var depth: usize = 0;
    var it = std.mem.splitScalar(u8, path, '/');
    while (it.next()) |part| {
        if (!codec.isValidName(part)) return false;
        depth += 1;
        if (depth > max_depth) return false;
    }
    return true;
}

pub const Manifest = struct {
    allocator: std.mem.Allocator,
    /// path -> entry; keys alias entry.path.
    entries: std.StringArrayHashMapUnmanaged(Entry) = .empty,
    /// Lamport clock: above every version seen.
    clock: u64 = 0,

    pub fn init(allocator: std.mem.Allocator) Manifest {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Manifest) void {
        for (self.entries.values()) |e| e.deinit(self.allocator);
        self.entries.deinit(self.allocator);
    }

    pub fn get(self: *Manifest, path: []const u8) ?Entry {
        return self.entries.get(path);
    }

    fn observe(self: *Manifest, v: Version) void {
        if (v.clock <= max_remote_clock and v.clock > self.clock) self.clock = v.clock;
    }

    /// A local edit of `path` by `device`: a file (cid/size/mtime), a dir,
    /// or a delete. Returns the new version.
    pub fn edit(self: *Manifest, path: []const u8, change: struct {
        kind: Kind = .file,
        cid: Cid = [_]u8{0} ** 32,
        size: u64 = 0,
        mtime: u64 = 0,
        deleted: bool = false,
    }, device: DeviceId, author: []const u8) !Version {
        if (!validPath(path)) return error.InvalidPath;
        self.clock = std.math.add(u64, self.clock, 1) catch return error.ClockExhausted;
        const version = Version{ .clock = self.clock, .device = device };

        var history = [_]?Version{null} ** history_len;
        if (self.entries.get(path)) |old| {
            // The replaced version first, then its own history.
            history[0] = old.version;
            for (old.history[0 .. history_len - 1], 1..) |h, i| history[i] = h;
        }
        const owned_path = try self.allocator.dupe(u8, path);
        errdefer self.allocator.free(owned_path);
        const owned_author = try self.allocator.dupe(u8, author[0..@min(author.len, max_author_len)]);
        errdefer self.allocator.free(owned_author);
        const entry = Entry{
            .path = owned_path,
            .kind = change.kind,
            .cid = change.cid,
            .size = change.size,
            .mtime = change.mtime,
            .version = version,
            .history = history,
            .deleted = change.deleted,
            .author = owned_author,
        };
        try self.replace(entry);
        return version;
    }

    /// Stores `entry` at its path and takes ownership, freeing what was
    /// there. On error nothing changes and the caller still owns `entry`.
    fn replace(self: *Manifest, entry: Entry) !void {
        if (!self.entries.contains(entry.path) and self.entries.count() >= max_entries) return error.ManifestTooLarge;
        const gop = try self.entries.getOrPut(self.allocator, entry.path);
        if (gop.found_existing) gop.value_ptr.deinit(self.allocator);
        gop.key_ptr.* = entry.path;
        gop.value_ptr.* = entry;
    }

    /// Stores a copy of `entry`.
    fn adopt(self: *Manifest, entry: Entry) !void {
        const copy = try entry.clone(self.allocator);
        errdefer copy.deinit(self.allocator);
        try self.replace(copy);
    }

    /// Merges a peer's entry (borrowed). Returns whether anything changed.
    pub fn merge(self: *Manifest, incoming: Entry) !bool {
        return self.mergeAt(incoming, 0);
    }

    fn mergeAt(self: *Manifest, incoming: Entry, depth: usize) anyerror!bool {
        if (incoming.version.clock > max_remote_clock) return false;
        for (incoming.history) |maybe_h| {
            if (maybe_h) |h| {
                if (h.clock > max_remote_clock) return false;
            }
        }
        if (depth >= max_depth) return error.InvalidPath;
        if (!validPath(incoming.path)) return error.InvalidPath;
        self.observe(incoming.version);
        const local = self.entries.get(incoming.path) orelse {
            try self.adopt(incoming);
            return true;
        };
        if (local.version.eql(incoming.version)) return false;
        if (incoming.descendsFrom(local.version)) {
            try self.adopt(incoming);
            return true;
        }
        if (local.descendsFrom(incoming.version)) return false;

        // Concurrent. An edit beats a delete outright.
        if (local.deleted != incoming.deleted) {
            if (local.deleted) {
                try self.adopt(incoming);
                return true;
            }
            return false;
        }
        if (local.deleted and incoming.deleted) {
            if (incoming.version.greater(local.version)) {
                try self.adopt(incoming);
                return true;
            }
            return false;
        }

        // Keep both: the higher version keeps the path, the other moves.
        const incoming_wins = incoming.version.greater(local.version);
        const loser = if (incoming_wins) local else incoming;
        var moved = try loser.clone(self.allocator);
        const conflict_path = conflictPath(self.allocator, loser.path, loser.author) catch |err| {
            moved.deinit(self.allocator);
            return err;
        };
        self.allocator.free(moved.path);
        moved.path = conflict_path;
        moved.history = [_]?Version{null} ** history_len;
        defer moved.deinit(self.allocator);
        _ = try self.mergeAt(moved, depth + 1);
        // `loser` may alias the entry at the path: move it first, then
        // put the winner in place.
        if (incoming_wins) try self.adopt(incoming);
        return true;
    }

    /// Live (not deleted) children of `dir` ("" for the top), with folders
    /// implied by deeper paths. Names are allocated in `arena`.
    pub fn list(self: *Manifest, arena: std.mem.Allocator, dir: []const u8) ![]Listed {
        var seen: std.StringHashMapUnmanaged(usize) = .empty;
        var out: std.ArrayList(Listed) = .empty;
        const prefix_len = if (dir.len == 0) 0 else dir.len + 1;
        for (self.entries.values()) |e| {
            if (e.deleted) continue;
            if (dir.len > 0 and !(std.mem.startsWith(u8, e.path, dir) and e.path.len > dir.len and e.path[dir.len] == '/')) continue;
            const rest = e.path[prefix_len..];
            const slash = std.mem.indexOfScalar(u8, rest, '/');
            const name = if (slash) |s| rest[0..s] else rest;
            const implied_dir = slash != null;
            if (seen.get(name)) |idx| {
                const item = &out.items[idx];
                if (implied_dir) {
                    item.kind = .dir;
                    item.size +|= e.size;
                    if (e.mtime > item.mtime) item.mtime = e.mtime;
                }
                continue;
            }
            try seen.put(arena, name, out.items.len);
            try out.append(arena, .{
                .name = try arena.dupe(u8, name),
                .kind = if (implied_dir) .dir else e.kind,
                .entry = if (implied_dir) null else e,
                .size = e.size,
                .mtime = e.mtime,
            });
        }
        return out.items;
    }

    pub const Listed = struct {
        name: []const u8,
        kind: Kind,
        /// The entry itself for files and explicit folders.
        entry: ?Entry,
        size: u64,
        mtime: u64,
    };

    /// Deletion mtimes are Unix seconds; unknown timestamps must be kept.
    pub fn pruneTombstones(self: *Manifest, now: u64) void {
        const horizon = 90 * 24 * 60 * 60;
        var i: usize = 0;
        while (i < self.entries.count()) {
            const e = self.entries.values()[i];
            if (e.deleted and e.mtime != 0 and now > e.mtime and now - e.mtime > horizon) {
                self.entries.swapRemoveAt(i);
                e.deinit(self.allocator);
            } else i += 1;
        }
    }

    // ---- Wire / disk format (JSON) ----

    const WireVersion = struct { c: u64, d: []const u8 };
    const WireEntry = struct {
        p: []const u8,
        k: u8,
        h: []const u8 = "",
        s: u64 = 0,
        m: u64 = 0,
        v: WireVersion,
        o: []const WireVersion = &.{},
        x: bool = false,
        a: []const u8 = "",
    };

    /// A digest of the content, the same whatever order the entries are in:
    /// two devices that converged have the same one, so a sync can skip
    /// sending a manifest that wouldn't change anything.
    pub fn digest(self: *Manifest) [32]u8 {
        var out = [_]u8{0} ** 32;
        for (self.entries.values()) |e| {
            var h = std.crypto.hash.blake2.Blake2s256.init(.{});
            var num: [8]u8 = undefined;
            h.update(e.path);
            h.update(&.{ @intFromEnum(e.kind), @intFromBool(e.deleted) });
            h.update(&e.cid);
            std.mem.writeInt(u64, &num, e.size, .big);
            h.update(&num);
            std.mem.writeInt(u64, &num, e.mtime, .big);
            h.update(&num);
            for ([_]?Version{e.version} ++ e.history) |maybe| {
                const v = maybe orelse {
                    h.update(&.{0});
                    continue;
                };
                std.mem.writeInt(u64, &num, v.clock, .big);
                h.update(&.{1});
                h.update(&num);
                h.update(&v.device);
            }
            h.update(e.author);
            var one: [32]u8 = undefined;
            h.final(&one);
            for (&out, one) |*o, b| o.* ^= b;
        }
        return out;
    }

    pub fn encode(self: *Manifest, allocator: std.mem.Allocator) ![]u8 {
        if (self.entries.count() > max_entries) return error.ManifestTooLarge;
        var arena_state = std.heap.ArenaAllocator.init(allocator);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        const wire = try arena.alloc(WireEntry, self.entries.count());
        for (self.entries.values(), wire) |e, *w| {
            var hist: std.ArrayList(WireVersion) = .empty;
            for (e.history) |h| if (h) |hv| try hist.append(arena, .{ .c = hv.clock, .d = try hexDup(arena, &hv.device) });
            w.* = .{
                .p = e.path,
                .k = @intFromEnum(e.kind),
                .h = if (e.kind == .file and !e.deleted) try hexDup(arena, &e.cid) else "",
                .s = e.size,
                .m = e.mtime,
                .v = .{ .c = e.version.clock, .d = try hexDup(arena, &e.version.device) },
                .o = hist.items,
                .x = e.deleted,
                .a = e.author,
            };
        }
        const bytes = try std.json.Stringify.valueAlloc(allocator, wire, .{});
        if (bytes.len > max_bytes) {
            allocator.free(bytes);
            return error.ManifestTooLarge;
        }
        return bytes;
    }

    /// Merges every entry of an encoded manifest. Returns how many changed
    /// something. Entries that fail validation are skipped.
    pub fn mergeEncoded(self: *Manifest, bytes: []const u8) !usize {
        var parsed = try parse(self.allocator, bytes);
        defer parsed.deinit();
        return self.mergeParsed(&parsed);
    }

    /// A peer's manifest, decoded but not merged yet: parsing needs no
    /// lock on the manifest it goes into (mergeParsed does).
    pub const Parsed = struct {
        arena: std.heap.ArenaAllocator,
        wire: []WireEntry,

        pub fn deinit(self: *Parsed) void {
            self.arena.deinit();
        }
    };

    pub fn parse(allocator: std.mem.Allocator, bytes: []const u8) !Parsed {
        if (bytes.len > max_bytes) return error.ManifestTooLarge;
        var arena_state = std.heap.ArenaAllocator.init(allocator);
        errdefer arena_state.deinit();
        const wire = std.json.parseFromSliceLeaky([]WireEntry, arena_state.allocator(), bytes, .{ .ignore_unknown_fields = true }) catch
            return error.InvalidManifest;
        if (wire.len > max_entries) return error.InvalidManifest;
        return .{ .arena = arena_state, .wire = wire };
    }

    /// Merges a parsed manifest; returns how many entries changed.
    pub fn mergeParsed(self: *Manifest, parsed: *const Parsed) usize {
        var changed: usize = 0;
        for (parsed.wire) |w| {
            const entry = fromWire(w) catch continue;
            if (self.merge(entry) catch false) changed += 1;
        }
        return changed;
    }

    fn fromWire(w: WireEntry) !Entry {
        if (w.v.c > max_remote_clock) return error.InvalidEntry;
        if (!validPath(w.p)) return error.InvalidPath;
        const kind = std.enums.fromInt(Kind, w.k) orelse return error.InvalidEntry;
        var e = Entry{
            .path = @constCast(w.p),
            .kind = kind,
            .size = w.s,
            .mtime = w.m,
            .version = .{ .clock = w.v.c, .device = try parseHex32(w.v.d) },
            .deleted = w.x,
            .author = @constCast(w.a[0..@min(w.a.len, max_author_len)]),
        };
        if (kind == .file and !w.x) e.cid = try parseHex32(w.h);
        for (w.o[0..@min(w.o.len, history_len)], 0..) |h, i| {
            if (h.c > max_remote_clock) return error.InvalidEntry;
            e.history[i] = .{ .clock = h.c, .device = try parseHex32(h.d) };
        }
        return e;
    }
};

fn hexDup(arena: std.mem.Allocator, bytes: *const [32]u8) ![]const u8 {
    const hex = std.fmt.bytesToHex(bytes.*, .lower);
    return arena.dupe(u8, &hex);
}

fn parseHex32(text: []const u8) ![32]u8 {
    if (text.len != 64) return error.InvalidEntry;
    var out: [32]u8 = undefined;
    _ = std.fmt.hexToBytes(&out, text) catch return error.InvalidEntry;
    return out;
}

/// "dir/name.ext" -> "dir/name (conflict from <author>).ext".
pub fn conflictPath(allocator: std.mem.Allocator, path: []const u8, author: []const u8) ![]u8 {
    const slash = std.mem.lastIndexOfScalar(u8, path, '/');
    const dir = if (slash) |s| path[0 .. s + 1] else "";
    const base = path[dir.len..];
    const dot = std.mem.lastIndexOfScalar(u8, base, '.');
    const stem = if (dot) |d| (if (d == 0) base else base[0..d]) else base;
    const ext = if (dot) |d| (if (d == 0) "" else base[d..]) else "";
    var who_buf: [max_author_len]u8 = undefined;
    var who_len: usize = 0;
    for (author) |c| {
        if (who_len == who_buf.len) break;
        who_buf[who_len] = if (c == '/' or c == '\\' or c < 0x20 or c == 0x7f) '_' else c;
        who_len += 1;
    }
    const who = if (who_len == 0) "another device" else who_buf[0..who_len];
    const name = try std.fmt.allocPrint(allocator, "{s}{s} (conflict from {s}){s}", .{ dir, stem, who, ext });
    if (validPath(name)) return name;
    allocator.free(name);
    const short = try std.fmt.allocPrint(allocator, "{s}conflict{s}", .{ dir, ext });
    if (validPath(short)) return short;
    allocator.free(short);
    // Always valid, the same on every device: the original name (a valid
    // path) with its first character marked, so the same length.
    const marked = try allocator.dupe(u8, path);
    marked[dir.len] = if (marked[dir.len] == '~') '_' else '~';
    return marked;
}

// ---- Tests ----

test "manifest: a conflict copy's name is always a valid path" {
    const a = std.testing.allocator;
    // A short name at the path limit: too long for " (conflict from …)"
    // and for "conflict.jpg".
    const part = "d" ** 250;
    const path = part ++ "/" ++ part ++ "/" ++ part ++ "/" ++ part ++ "/" ++ ("e" ** 14) ++ "/a.jpg";
    try std.testing.expectEqual(@as(usize, max_path_len), path.len);
    try std.testing.expect(validPath(path));
    const c = try conflictPath(a, path, "Google Pixel 8");
    defer a.free(c);
    try std.testing.expect(validPath(c));
    try std.testing.expect(!std.mem.eql(u8, c, path));
}

const testing = std.testing;
const dev_a: DeviceId = [_]u8{0xAA} ** 32;
const dev_b: DeviceId = [_]u8{0xBB} ** 32;
const cid1: Cid = [_]u8{1} ** 32;
const cid2: Cid = [_]u8{2} ** 32;
const cid3: Cid = [_]u8{3} ** 32;

fn syncInto(dst: *Manifest, src: *Manifest) !usize {
    const bytes = try src.encode(testing.allocator);
    defer testing.allocator.free(bytes);
    return dst.mergeEncoded(bytes);
}

test "manifest: an edit propagates and a later edit replaces it" {
    var a = Manifest.init(testing.allocator);
    defer a.deinit();
    var b = Manifest.init(testing.allocator);
    defer b.deinit();

    _ = try a.edit("docs/plan.txt", .{ .cid = cid1, .size = 10 }, dev_a, "Desk");
    try testing.expectEqual(@as(usize, 1), try syncInto(&b, &a));
    try testing.expectEqualSlices(u8, &cid1, &b.get("docs/plan.txt").?.cid);

    // B edits what it saw; A takes it without a conflict.
    _ = try b.edit("docs/plan.txt", .{ .cid = cid2, .size = 12 }, dev_b, "Phone");
    try testing.expectEqual(@as(usize, 1), try syncInto(&a, &b));
    try testing.expectEqualSlices(u8, &cid2, &a.get("docs/plan.txt").?.cid);
    try testing.expectEqual(@as(usize, 1), a.entries.count());
    // Syncing again changes nothing.
    try testing.expectEqual(@as(usize, 0), try syncInto(&a, &b));
    try testing.expectEqual(@as(usize, 0), try syncInto(&b, &a));
}

test "manifest: concurrent edits keep both, identically on both sides" {
    var a = Manifest.init(testing.allocator);
    defer a.deinit();
    var b = Manifest.init(testing.allocator);
    defer b.deinit();
    _ = try a.edit("notes.md", .{ .cid = cid1 }, dev_a, "Desk");
    _ = try syncInto(&b, &a);

    _ = try a.edit("notes.md", .{ .cid = cid2 }, dev_a, "Desk");
    _ = try b.edit("notes.md", .{ .cid = cid3 }, dev_b, "Phone");
    _ = try syncInto(&a, &b);
    _ = try syncInto(&b, &a);

    // Same clock: device BB > AA, so Phone's version keeps the name.
    for ([_]*Manifest{ &a, &b }) |m| {
        try testing.expectEqual(@as(usize, 2), m.entries.count());
        try testing.expectEqualSlices(u8, &cid3, &m.get("notes.md").?.cid);
        try testing.expectEqualSlices(u8, &cid2, &m.get("notes (conflict from Desk).md").?.cid);
    }
    // And it is stable.
    try testing.expectEqual(@as(usize, 0), try syncInto(&a, &b));
}

test "manifest: an edit beats a concurrent delete; deletes replicate" {
    var a = Manifest.init(testing.allocator);
    defer a.deinit();
    var b = Manifest.init(testing.allocator);
    defer b.deinit();
    _ = try a.edit("x.txt", .{ .cid = cid1 }, dev_a, "Desk");
    _ = try a.edit("y.txt", .{ .cid = cid1 }, dev_a, "Desk");
    _ = try syncInto(&b, &a);

    _ = try a.edit("x.txt", .{ .deleted = true }, dev_a, "Desk");
    _ = try b.edit("x.txt", .{ .cid = cid2 }, dev_b, "Phone");
    _ = try b.edit("y.txt", .{ .deleted = true }, dev_b, "Phone");
    _ = try syncInto(&a, &b);
    _ = try syncInto(&b, &a);

    for ([_]*Manifest{ &a, &b }) |m| {
        try testing.expect(!m.get("x.txt").?.deleted);
        try testing.expectEqualSlices(u8, &cid2, &m.get("x.txt").?.cid);
        try testing.expect(m.get("y.txt").?.deleted);
    }
}

test "manifest: listing implies folders and hides deletes" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var m = Manifest.init(testing.allocator);
    defer m.deinit();
    _ = try m.edit("a.txt", .{ .cid = cid1, .size = 3 }, dev_a, "Desk");
    _ = try m.edit("photos/2024/one.jpg", .{ .cid = cid1, .size = 100 }, dev_a, "Desk");
    _ = try m.edit("photos/two.jpg", .{ .cid = cid2, .size = 50 }, dev_a, "Desk");
    _ = try m.edit("gone.txt", .{ .cid = cid1 }, dev_a, "Desk");
    _ = try m.edit("gone.txt", .{ .deleted = true }, dev_a, "Desk");

    const top = try m.list(arena_state.allocator(), "");
    try testing.expectEqual(@as(usize, 2), top.len);
    const photos = try m.list(arena_state.allocator(), "photos");
    try testing.expectEqual(@as(usize, 2), photos.len);
    for (photos) |p| {
        if (std.mem.eql(u8, p.name, "2024")) try testing.expectEqual(Kind.dir, p.kind);
        if (std.mem.eql(u8, p.name, "two.jpg")) try testing.expectEqual(Kind.file, p.kind);
    }
    for (top) |t| if (std.mem.eql(u8, t.name, "photos")) try testing.expectEqual(@as(u64, 150), t.size);
}

test "manifest: peers cannot send unsafe paths" {
    var m = Manifest.init(testing.allocator);
    defer m.deinit();
    try testing.expectError(error.InvalidPath, m.edit("../etc/passwd", .{}, dev_a, "x"));
    try testing.expectError(error.InvalidPath, m.edit("/abs", .{}, dev_a, "x"));
    try testing.expectError(error.InvalidPath, m.edit("a//b", .{}, dev_a, "x"));
    const hostile =
        \\[{"p":"../x","k":0,"h":"0101010101010101010101010101010101010101010101010101010101010101","v":{"c":1,"d":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}}]
    ;
    try testing.expectEqual(@as(usize, 0), try m.mergeEncoded(hostile));
    try testing.expectEqual(@as(usize, 0), m.entries.count());
}

test "manifest: conflict names" {
    const p = try conflictPath(testing.allocator, "photos/IMG_1.jpg", "Xiaomi M2007J20CG");
    defer testing.allocator.free(p);
    try testing.expectEqualStrings("photos/IMG_1 (conflict from Xiaomi M2007J20CG).jpg", p);
    const q = try conflictPath(testing.allocator, "README", "Desk");
    defer testing.allocator.free(q);
    try testing.expectEqualStrings("README (conflict from Desk)", q);
}

test "manifest: reject remote clock > maxInt(u64)/2 and local edit succeeds" {
    var m = Manifest.init(testing.allocator);
    defer m.deinit();

    const bad_entry = Entry{
        .path = try testing.allocator.dupe(u8, "poison.txt"),
        .kind = .file,
        .cid = cid1,
        .size = 10,
        .mtime = 1,
        .version = .{ .clock = std.math.maxInt(u64), .device = dev_b },
        .author = try testing.allocator.dupe(u8, "BadGuy"),
    };
    defer bad_entry.deinit(testing.allocator);

    const changed = try m.merge(bad_entry);
    try testing.expect(!changed);
    try testing.expectEqual(@as(usize, 0), m.entries.count());
    try testing.expect(m.clock < max_remote_clock);

    // Hostile clock on wire JSON is skipped as well
    const hostile_clock =
        \\[{"p":"poison2.txt","k":0,"h":"0101010101010101010101010101010101010101010101010101010101010101","v":{"c":18446744073709551615,"d":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}}]
    ;
    try testing.expectEqual(@as(usize, 0), try m.mergeEncoded(hostile_clock));
    try testing.expectEqual(@as(usize, 0), m.entries.count());

    // Local edit succeeds without panic
    const v = try m.edit("clean.txt", .{ .cid = cid2, .size = 20 }, dev_a, "Desk");
    try testing.expectEqual(@as(u64, 1), v.clock);
    try testing.expectEqual(@as(usize, 1), m.entries.count());
}

test "manifest: conflict copy merge does not overwrite newer local edit of conflict path" {
    var a = Manifest.init(testing.allocator);
    defer a.deinit();
    var b = Manifest.init(testing.allocator);
    defer b.deinit();

    _ = try a.edit("file.txt", .{ .cid = cid1 }, dev_a, "Desk");
    _ = try syncInto(&b, &a);

    // Concurrent edits
    _ = try a.edit("file.txt", .{ .cid = cid2 }, dev_a, "Desk");
    _ = try b.edit("file.txt", .{ .cid = cid3 }, dev_b, "Phone");

    _ = try syncInto(&a, &b);
    try testing.expect(a.get("file (conflict from Desk).txt") != null);

    // Local user on A edits the conflict copy
    _ = try a.edit("file (conflict from Desk).txt", .{ .cid = cid1 }, dev_a, "Desk");
    const clk = a.get("file (conflict from Desk).txt").?.version.clock;

    // Redundant sync from B must not overwrite A's edit of conflict copy
    _ = try syncInto(&a, &b);
    try testing.expectEqual(clk, a.get("file (conflict from Desk).txt").?.version.clock);
    try testing.expectEqualSlices(u8, &cid1, &a.get("file (conflict from Desk).txt").?.cid);
}

test "manifest: prune tombstones after 90 days" {
    var m = Manifest.init(testing.allocator);
    defer m.deinit();

    _ = try m.edit("keep.txt", .{ .cid = cid1 }, dev_a, "Desk");
    _ = try m.edit("recent_del.txt", .{ .deleted = true, .mtime = 1_000_000 + 90 * 24 * 60 * 60 }, dev_a, "Desk");
    _ = try m.edit("old_del.txt", .{ .deleted = true, .mtime = 1_000_000 }, dev_a, "Desk");
    _ = try m.edit("unknown_del.txt", .{ .deleted = true, .mtime = 0 }, dev_a, "Desk");

    try testing.expectEqual(@as(usize, 4), m.entries.count());

    // 90 days = 7_776_000 seconds
    const now = 1_000_000 + 90 * 24 * 60 * 60 + 10;
    m.pruneTombstones(now);

    try testing.expect(m.get("keep.txt") != null);
    try testing.expect(m.get("recent_del.txt") != null);
    try testing.expect(m.get("unknown_del.txt") != null); // mtime == 0 kept
    try testing.expect(m.get("old_del.txt") == null); // pruned!
    try testing.expectEqual(@as(usize, 3), m.entries.count());
}

test "manifest: the digest ignores order, changes on edits, and agrees once synced" {
    var a = Manifest.init(testing.allocator);
    defer a.deinit();
    var b = Manifest.init(testing.allocator);
    defer b.deinit();
    const empty = a.digest();
    _ = try a.edit("one.txt", .{ .cid = cid1, .size = 10 }, dev_a, "Desk");
    _ = try a.edit("two.txt", .{ .cid = cid2, .size = 20 }, dev_a, "Desk");
    try testing.expect(!std.mem.eql(u8, &empty, &a.digest()));
    // B learns the entries in the other order: same content, same digest.
    _ = try b.edit("two.txt", .{ .cid = cid2, .size = 20 }, dev_b, "Phone");
    _ = try syncInto(&b, &a);
    _ = try syncInto(&a, &b);
    try testing.expectEqualSlices(u8, &a.digest(), &b.digest());
    // Any edit changes it.
    const before = a.digest();
    _ = try a.edit("one.txt", .{ .cid = cid2, .size = 11 }, dev_a, "Desk");
    try testing.expect(!std.mem.eql(u8, &before, &a.digest()));
}
