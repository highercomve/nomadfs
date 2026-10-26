//! Self-describing block encoding for DAG nodes.
//!
//!   leaf:   [tag = 0x00][raw data ...]
//!   parent: [tag = 0x01][u16 link_count]
//!           link_count x { [cid: 32][u64 size][u16 name_len][name] }
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
};

pub const max_links = std.math.maxInt(u16);
pub const max_name_len = 255;

const link_header_len = cid_len + @sizeOf(u64) + @sizeOf(u16);

pub const Error = error{InvalidBlock};

/// A decoded block. Slices point into the encoded bytes; nothing is owned.
pub const View = union(Tag) {
    leaf: []const u8,
    parent: LinkIterator,
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
    }
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
