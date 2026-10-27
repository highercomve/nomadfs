//! Self-describing block encoding for DAG nodes.
//!
//!   leaf:   [tag = 0x00][raw data ...]
//!   parent: [tag = 0x01][u16 link_count]
//!           link_count x { [cid: 32][u64 size][u16 name_len][name] }
//!   dir:    [tag = 0x02][u16 entry_count]
//!           entry_count x { [cid: 32][u64 size][u8 kind][u64 mtime]
//!                           [u16 name_len][name] }
//!
//! A dir entry points at a file DAG (kind = file) or another dir block
//! (kind = dir); `size` is the file's byte length, or the sum over a
//! subdirectory. Entry names are validated path components in strictly
//! ascending byte order, so a directory has exactly one encoding and a
//! listing from a peer can be mapped onto a filesystem without escaping it.
//!
//! All integers are big-endian. A node's CID is SHA-256 over these bytes, so
//! a parent commits to its children's CIDs, sizes and names, and a block
//! fetched from a peer can be decoded without any outside type information.

const std = @import("std");
const DagLink = @import("node.zig").DagLink;

pub const cid_len = 32;
pub const Cid = [cid_len]u8;

pub const Tag = enum(u8) {
    leaf = 0,
    parent = 1,
    dir = 2,
};

pub const EntryKind = enum(u8) {
    file = 0,
    dir = 1,
};

pub const max_links = std.math.maxInt(u16);
pub const max_name_len = 255;

const link_header_len = cid_len + @sizeOf(u64) + @sizeOf(u16);
const entry_header_len = cid_len + @sizeOf(u64) + 1 + @sizeOf(u64) + @sizeOf(u16);

/// Upper bound on an encoded dir block, well under the RPC value limit so
/// a listing always fits one GET_BLOCK reply.
pub const max_dir_block_len = 4 * 1024 * 1024;

pub const Error = error{InvalidBlock};

/// A decoded block. Slices point into the encoded bytes; nothing is owned.
pub const View = union(Tag) {
    leaf: []const u8,
    parent: LinkIterator,
    dir: EntryIterator,
};

pub const LinkView = struct {
    cid: *const Cid,
    size: u64,
    name: []const u8,
};

/// Iterates links of a parent block that decode() already validated, so
/// iteration cannot fail.
pub const LinkIterator = struct {
    bytes: []const u8,
    count: u16,
    index: u16 = 0,
    pos: usize = 0,

    pub fn next(self: *LinkIterator) ?LinkView {
        if (self.index == self.count) return null;
        const at = self.bytes[self.pos..];
        const name_len = std.mem.readInt(u16, at[cid_len + 8 ..][0..2], .big);
        const link = LinkView{
            .cid = at[0..cid_len],
            .size = std.mem.readInt(u64, at[cid_len..][0..8], .big),
            .name = at[link_header_len..][0..name_len],
        };
        self.pos += link_header_len + name_len;
        self.index += 1;
        return link;
    }
};

pub const EntryView = struct {
    cid: *const Cid,
    size: u64,
    kind: EntryKind,
    mtime: u64,
    name: []const u8,
};

/// Iterates entries of a dir block that decode() already validated.
pub const EntryIterator = struct {
    bytes: []const u8,
    count: u16,
    index: u16 = 0,
    pos: usize = 0,

    pub fn next(self: *EntryIterator) ?EntryView {
        if (self.index == self.count) return null;
        const at = self.bytes[self.pos..];
        const name_len = std.mem.readInt(u16, at[entry_header_len - 2 ..][0..2], .big);
        const entry = EntryView{
            .cid = at[0..cid_len],
            .size = std.mem.readInt(u64, at[cid_len..][0..8], .big),
            .kind = @enumFromInt(at[cid_len + 8]),
            .mtime = std.mem.readInt(u64, at[cid_len + 9 ..][0..8], .big),
            .name = at[entry_header_len..][0..name_len],
        };
        self.pos += entry_header_len + name_len;
        self.index += 1;
        return entry;
    }
};

/// Whether `name` is a single path component a filesystem can hold: not
/// empty, not "." or "..", no '/' and no NUL.
pub fn isValidName(name: []const u8) bool {
    if (name.len == 0 or name.len > max_name_len) return false;
    if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) return false;
    return std.mem.indexOfAny(u8, name, "/\\\x00") == null;
}

/// Parses and fully validates an encoded block. Input may come from the
/// network: truncation, trailing bytes and oversized names are rejected.
pub fn decode(bytes: []const u8) Error!View {
    if (bytes.len == 0) return error.InvalidBlock;
    const tag = std.enums.fromInt(Tag, bytes[0]) orelse return error.InvalidBlock;
    const body = bytes[1..];
    switch (tag) {
        .leaf => return .{ .leaf = body },
        .parent => {
            if (body.len < 2) return error.InvalidBlock;
            const count = std.mem.readInt(u16, body[0..2], .big);
            const links = body[2..];

            var pos: usize = 0;
            var i: u16 = 0;
            while (i < count) : (i += 1) {
                if (links.len - pos < link_header_len) return error.InvalidBlock;
                const name_len = std.mem.readInt(u16, links[pos + cid_len + 8 ..][0..2], .big);
                if (name_len > max_name_len) return error.InvalidBlock;
                if (links.len - pos - link_header_len < name_len) return error.InvalidBlock;
                pos += link_header_len + name_len;
            }
            if (pos != links.len) return error.InvalidBlock;
            return .{ .parent = .{ .bytes = links, .count = count } };
        },
        .dir => {
            if (bytes.len > max_dir_block_len or body.len < 2) return error.InvalidBlock;
            const count = std.mem.readInt(u16, body[0..2], .big);
            const entries = body[2..];

            var pos: usize = 0;
            var prev: ?[]const u8 = null;
            var i: u16 = 0;
            while (i < count) : (i += 1) {
                if (entries.len - pos < entry_header_len) return error.InvalidBlock;
                const at = entries[pos..];
                _ = std.enums.fromInt(EntryKind, at[cid_len + 8]) orelse return error.InvalidBlock;
                const name_len = std.mem.readInt(u16, at[entry_header_len - 2 ..][0..2], .big);
                if (entries.len - pos - entry_header_len < name_len) return error.InvalidBlock;
                const name = at[entry_header_len..][0..name_len];
                if (!isValidName(name)) return error.InvalidBlock;
                if (prev) |p| {
                    if (std.mem.order(u8, p, name) != .lt) return error.InvalidBlock;
                }
                prev = name;
                pos += entry_header_len + name_len;
            }
            if (pos != entries.len) return error.InvalidBlock;
            return .{ .dir = .{ .bytes = entries, .count = count } };
        },
    }
}

pub const DirEntry = struct {
    name: []const u8,
    cid: []const u8,
    size: u64,
    kind: EntryKind,
    mtime: u64,
};

/// Encodes a dir block; the result is caller-owned. `entries` must be
/// sorted by name (byte order) with valid, distinct names.
pub fn encodeDir(allocator: std.mem.Allocator, entries: []const DirEntry) ![]u8 {
    if (entries.len > max_links) return error.TooManyEntries;

    var len: usize = 1 + 2;
    for (entries, 0..) |entry, i| {
        std.debug.assert(entry.cid.len == cid_len);
        if (!isValidName(entry.name)) return error.InvalidName;
        if (i > 0 and std.mem.order(u8, entries[i - 1].name, entry.name) != .lt) return error.UnsortedEntries;
        len += entry_header_len + entry.name.len;
    }
    if (len > max_dir_block_len) return error.DirectoryTooLarge;

    const out = try allocator.alloc(u8, len);
    out[0] = @intFromEnum(Tag.dir);
    std.mem.writeInt(u16, out[1..3], @intCast(entries.len), .big);
    var pos: usize = 3;
    for (entries) |entry| {
        @memcpy(out[pos..][0..cid_len], entry.cid);
        std.mem.writeInt(u64, out[pos + cid_len ..][0..8], entry.size, .big);
        out[pos + cid_len + 8] = @intFromEnum(entry.kind);
        std.mem.writeInt(u64, out[pos + cid_len + 9 ..][0..8], entry.mtime, .big);
        std.mem.writeInt(u16, out[pos + entry_header_len - 2 ..][0..2], @intCast(entry.name.len), .big);
        @memcpy(out[pos + entry_header_len ..][0..entry.name.len], entry.name);
        pos += entry_header_len + entry.name.len;
    }
    std.debug.assert(pos == len);
    return out;
}

/// Encodes a parent block; the result is caller-owned.
pub fn encodeParent(allocator: std.mem.Allocator, links: []const DagLink) ![]u8 {
    if (links.len > max_links) return error.TooManyLinks;

    var len: usize = 1 + 2;
    for (links) |link| {
        std.debug.assert(link.cid.len == cid_len);
        if (link.name.len > max_name_len) return error.NameTooLong;
        len += link_header_len + link.name.len;
    }

    const out = try allocator.alloc(u8, len);
    out[0] = @intFromEnum(Tag.parent);
    std.mem.writeInt(u16, out[1..3], @intCast(links.len), .big);
    var pos: usize = 3;
    for (links) |link| {
        @memcpy(out[pos..][0..cid_len], link.cid);
        std.mem.writeInt(u64, out[pos + cid_len ..][0..8], link.size, .big);
        std.mem.writeInt(u16, out[pos + cid_len + 8 ..][0..2], @intCast(link.name.len), .big);
        @memcpy(out[pos + link_header_len ..][0..link.name.len], link.name);
        pos += link_header_len + link.name.len;
    }
    std.debug.assert(pos == len);
    return out;
}

test "codec: parent round trip" {
    const allocator = std.testing.allocator;
    const cid_a: Cid = [_]u8{0xAA} ** cid_len;
    const cid_b: Cid = [_]u8{0xBB} ** cid_len;
    const links = [_]DagLink{
        .{ .name = "data", .cid = &cid_a, .size = 10 },
        .{ .name = "", .cid = &cid_b, .size = 1 << 40 },
    };

    const bytes = try encodeParent(allocator, &links);
    defer allocator.free(bytes);

    var it = (try decode(bytes)).parent;
    const first = it.next().?;
    try std.testing.expectEqualSlices(u8, &cid_a, first.cid);
    try std.testing.expectEqualStrings("data", first.name);
    try std.testing.expectEqual(@as(u64, 10), first.size);
    const second = it.next().?;
    try std.testing.expectEqualSlices(u8, &cid_b, second.cid);
    try std.testing.expectEqual(@as(u64, 1 << 40), second.size);
    try std.testing.expect(it.next() == null);
}

test "codec: leaf and malformed blocks" {
    try std.testing.expectEqualStrings("hi", (try decode(&.{ 0, 'h', 'i' })).leaf);
    try std.testing.expectEqualStrings("", (try decode(&.{0})).leaf);

    try std.testing.expectError(error.InvalidBlock, decode(""));
    try std.testing.expectError(error.InvalidBlock, decode(&.{7}));
    try std.testing.expectError(error.InvalidBlock, decode(&.{1}));
    // Claims one link but has none.
    try std.testing.expectError(error.InvalidBlock, decode(&.{ 1, 0, 1 }));

    const allocator = std.testing.allocator;
    const cid: Cid = [_]u8{1} ** cid_len;
    const bytes = try encodeParent(allocator, &.{.{ .name = "x", .cid = &cid, .size = 1 }});
    defer allocator.free(bytes);
    // Every truncation of a valid block is rejected.
    for (0..bytes.len) |cut| {
        try std.testing.expectError(error.InvalidBlock, decode(bytes[0..cut]));
    }
    // Trailing garbage is rejected.
    const padded = try std.mem.concat(allocator, u8, &.{ bytes, "!" });
    defer allocator.free(padded);
    try std.testing.expectError(error.InvalidBlock, decode(padded));
}

test "codec: dir round trip and validation" {
    const allocator = std.testing.allocator;
    const cid_a: Cid = [_]u8{0xAA} ** cid_len;
    const cid_b: Cid = [_]u8{0xBB} ** cid_len;
    const entries = [_]DirEntry{
        .{ .name = "notes.txt", .cid = &cid_a, .size = 42, .kind = .file, .mtime = 1700000000 },
        .{ .name = "photos", .cid = &cid_b, .size = 1 << 33, .kind = .dir, .mtime = 0 },
    };
    const bytes = try encodeDir(allocator, &entries);
    defer allocator.free(bytes);

    var it = (try decode(bytes)).dir;
    const first = it.next().?;
    try std.testing.expectEqualStrings("notes.txt", first.name);
    try std.testing.expectEqual(EntryKind.file, first.kind);
    try std.testing.expectEqual(@as(u64, 1700000000), first.mtime);
    const second = it.next().?;
    try std.testing.expectEqualSlices(u8, &cid_b, second.cid);
    try std.testing.expectEqual(EntryKind.dir, second.kind);
    try std.testing.expectEqual(@as(u64, 1 << 33), second.size);
    try std.testing.expect(it.next() == null);

    for (0..bytes.len) |cut| {
        try std.testing.expectError(error.InvalidBlock, decode(bytes[0..cut]));
    }

    // Unsorted or unsafe names never encode...
    const unsorted = [_]DirEntry{ entries[1], entries[0] };
    try std.testing.expectError(error.UnsortedEntries, encodeDir(allocator, &unsorted));
    const escape = [_]DirEntry{.{ .name = "..", .cid = &cid_a, .size = 0, .kind = .file, .mtime = 0 }};
    try std.testing.expectError(error.InvalidName, encodeDir(allocator, &escape));

    // ...and never decode when a peer sends them.
    const tampered = try allocator.dupe(u8, bytes);
    defer allocator.free(tampered);
    const name_at = 3 + entry_header_len; // first entry's name
    @memcpy(tampered[name_at..][0..2], "..");
    tampered[name_at - 1] = 2;
    // Shorten the name to "..": shift the tail left by the dropped bytes.
    const dropped = "notes.txt".len - 2;
    std.mem.copyForwards(u8, tampered[name_at + 2 ..], tampered[name_at + 2 + dropped ..]);
    try std.testing.expectError(error.InvalidBlock, decode(tampered[0 .. tampered.len - dropped]));
    tampered[name_at] = 'a';
    tampered[name_at + 1] = '/';
    try std.testing.expectError(error.InvalidBlock, decode(tampered[0 .. tampered.len - dropped]));
    tampered[name_at + 1] = 'b';
    _ = try decode(tampered[0 .. tampered.len - dropped]);
}
