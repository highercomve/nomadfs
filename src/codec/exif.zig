//! The two things a thumbnail needs from a JPEG's EXIF block: which way up
//! the picture goes (the orientation tag) and the small preview the camera
//! stored next to it. The parser is bounded: a few segments, at most two
//! IFDs of at most `max_entries` entries, every offset checked against the
//! data before it is read.

const std = @import("std");

/// Entries read from one IFD at most.
pub const max_entries = 64;
/// JPEG segments looked at before giving up on finding EXIF.
const max_segments = 32;

const tag_orientation = 0x0112;
const tag_thumb_offset = 0x0201;
const tag_thumb_length = 0x0202;

const type_short = 3;
const type_long = 4;

/// The EXIF orientation of a JPEG, 1 to 8; 1 (as stored) when there is no
/// EXIF block or the value is not a valid one.
pub fn orientation(bytes: []const u8) u8 {
    const tiff = Tiff.find(bytes) orelse return 1;
    const ifd0 = tiff.ifd(tiff.firstIfd() orelse return 1) orelse return 1;
    const entry = tiff.entry(ifd0, tag_orientation) orelse return 1;
    if (entry.kind != type_short) return 1;
    const value = tiff.u16At(entry.value_off) orelse return 1;
    return if (value >= 1 and value <= 8) @intCast(value) else 1;
}

/// The JPEG preview stored in IFD1, if there is one. A slice of `bytes`.
pub fn embeddedThumb(bytes: []const u8) ?[]const u8 {
    const tiff = Tiff.find(bytes) orelse return null;
    const ifd0 = tiff.ifd(tiff.firstIfd() orelse return null) orelse return null;
    const ifd1 = tiff.ifd(tiff.nextIfd(ifd0) orelse return null) orelse return null;
    const start = tiff.longValue(tiff.entry(ifd1, tag_thumb_offset) orelse return null) orelse return null;
    const len = tiff.longValue(tiff.entry(ifd1, tag_thumb_length) orelse return null) orelse return null;
    if (len < 4 or start > tiff.data.len or len > tiff.data.len - start) return null;
    const thumb = tiff.data[start..][0..len];
    if (thumb[0] != 0xFF or thumb[1] != 0xD8) return null;
    return thumb;
}

const Ifd = struct { off: usize, count: u16 };

const Entry = struct {
    kind: u16,
    count: u32,
    /// Where the 4-byte value field starts in the TIFF data.
    value_off: usize,
};

/// The TIFF structure inside a JPEG's APP1 "Exif" segment.
const Tiff = struct {
    data: []const u8,
    endian: std.builtin.Endian,

    fn find(bytes: []const u8) ?Tiff {
        const payload = exifPayload(bytes) orelse return null;
        if (payload.len < 8) return null;
        const endian: std.builtin.Endian = if (std.mem.eql(u8, payload[0..4], "II*\x00"))
            .little
        else if (std.mem.eql(u8, payload[0..4], "MM\x00*"))
            .big
        else
            return null;
        return .{ .data = payload, .endian = endian };
    }

    fn u16At(self: Tiff, off: usize) ?u16 {
        if (off > self.data.len or self.data.len - off < 2) return null;
        return std.mem.readInt(u16, self.data[off..][0..2], self.endian);
    }

    fn u32At(self: Tiff, off: usize) ?u32 {
        if (off > self.data.len or self.data.len - off < 4) return null;
        return std.mem.readInt(u32, self.data[off..][0..4], self.endian);
    }

    fn firstIfd(self: Tiff) ?u32 {
        return self.u32At(4);
    }

    /// The IFD at `off`, when its entries and next-IFD link fit the data.
    fn ifd(self: Tiff, off: u32) ?Ifd {
        if (off < 8) return null;
        const count = self.u16At(off) orelse return null;
        if (count > max_entries) return null;
        const end = @as(usize, off) + 2 + @as(usize, count) * 12 + 4;
        if (end > self.data.len) return null;
        return .{ .off = off, .count = count };
    }

    fn nextIfd(self: Tiff, from: Ifd) ?u32 {
        const next = self.u32At(from.off + 2 + @as(usize, from.count) * 12) orelse return null;
        // A link back to (or before) this IFD would loop; 0 means none.
        if (next <= from.off) return null;
        return next;
    }

    fn entry(self: Tiff, in: Ifd, tag: u16) ?Entry {
        for (0..in.count) |i| {
            const off = in.off + 2 + i * 12;
            if (self.u16At(off) != tag) continue;
            return .{
                .kind = self.u16At(off + 2) orelse return null,
                .count = self.u32At(off + 4) orelse return null,
                .value_off = off + 8,
            };
        }
        return null;
    }

    /// A single SHORT or LONG value (offsets and lengths come as either).
    fn longValue(self: Tiff, e: Entry) ?u32 {
        if (e.count != 1) return null;
        return switch (e.kind) {
            type_short => if (self.u16At(e.value_off)) |short| short else null,
            type_long => self.u32At(e.value_off),
            else => null,
        };
    }
};

/// The TIFF bytes of the first APP1 "Exif" segment before the image data.
fn exifPayload(bytes: []const u8) ?[]const u8 {
    if (bytes.len < 4 or bytes[0] != 0xFF or bytes[1] != 0xD8) return null;
    var pos: usize = 2;
    for (0..max_segments) |_| {
        if (bytes.len - pos < 4 or bytes[pos] != 0xFF) return null;
        const marker = bytes[pos + 1];
        switch (marker) {
            0xFF => { // fill byte
                pos += 1;
                continue;
            },
            0x01, 0xD0...0xD8 => { // no length field
                pos += 2;
                continue;
            },
            0xD9, 0xDA => return null, // end of image, start of scan
            else => {},
        }
        const len = std.mem.readInt(u16, bytes[pos + 2 ..][0..2], .big);
        if (len < 2 or len - 2 > bytes.len - pos - 4) return null;
        const segment = bytes[pos + 4 ..][0 .. len - 2];
        if (marker == 0xE1 and std.mem.startsWith(u8, segment, "Exif\x00\x00")) return segment[6..];
        pos += 2 + @as(usize, len);
    }
    return null;
}

/// Test fixtures: an APP1 EXIF segment to put after a JPEG's SOI marker.
pub const testing = struct {
    /// An APP1 segment with an orientation tag and, when `thumb` is not
    /// empty, that JPEG as the IFD1 preview. Little-endian TIFF.
    pub fn app1(allocator: std.mem.Allocator, orient: u16, thumb: []const u8) ![]u8 {
        var tiff: std.ArrayList(u8) = .empty;
        defer tiff.deinit(allocator);
        try tiff.appendSlice(allocator, "II*\x00");
        try putU32(allocator, &tiff, 8);
        // IFD0 at 8: one entry, then the link to IFD1 (at 26) or 0.
        try putU16(allocator, &tiff, 1);
        try putEntry(allocator, &tiff, tag_orientation, type_short, orient);
        try putU32(allocator, &tiff, if (thumb.len > 0) 26 else 0);
        if (thumb.len > 0) {
            // IFD1 at 26: offset and length of the preview, which follows.
            try putU16(allocator, &tiff, 2);
            try putEntry(allocator, &tiff, tag_thumb_offset, type_long, 26 + 2 + 2 * 12 + 4);
            try putEntry(allocator, &tiff, tag_thumb_length, type_long, @intCast(thumb.len));
            try putU32(allocator, &tiff, 0);
            try tiff.appendSlice(allocator, thumb);
        }
        const len = 2 + 6 + tiff.items.len;
        if (len > std.math.maxInt(u16)) return error.TooLarge;
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(allocator);
        try out.appendSlice(allocator, &.{ 0xFF, 0xE1, @intCast(len >> 8), @truncate(len) });
        try out.appendSlice(allocator, "Exif\x00\x00");
        try out.appendSlice(allocator, tiff.items);
        return out.toOwnedSlice(allocator);
    }

    /// `jpeg` with `segment` inserted right after its SOI marker.
    pub fn insertAfterSoi(allocator: std.mem.Allocator, jpeg: []const u8, segment: []const u8) ![]u8 {
        std.debug.assert(jpeg.len >= 2);
        return std.mem.concat(allocator, u8, &.{ jpeg[0..2], segment, jpeg[2..] });
    }

    fn putU16(allocator: std.mem.Allocator, list: *std.ArrayList(u8), v: u16) !void {
        var buf: [2]u8 = undefined;
        std.mem.writeInt(u16, &buf, v, .little);
        try list.appendSlice(allocator, &buf);
    }

    fn putU32(allocator: std.mem.Allocator, list: *std.ArrayList(u8), v: u32) !void {
        var buf: [4]u8 = undefined;
        std.mem.writeInt(u32, &buf, v, .little);
        try list.appendSlice(allocator, &buf);
    }

    fn putEntry(allocator: std.mem.Allocator, list: *std.ArrayList(u8), tag: u16, kind: u16, value: u32) !void {
        try putU16(allocator, list, tag);
        try putU16(allocator, list, kind);
        try putU32(allocator, list, 1);
        if (kind == type_short) {
            try putU16(allocator, list, @intCast(value));
            try putU16(allocator, list, 0);
        } else {
            try putU32(allocator, list, value);
        }
    }
};

test "orientation and preview from an EXIF segment" {
    const allocator = std.testing.allocator;
    const fake_thumb = [_]u8{ 0xFF, 0xD8, 1, 2, 3, 0xFF, 0xD9 };
    const segment = try testing.app1(allocator, 6, &fake_thumb);
    defer allocator.free(segment);
    const jpeg = try testing.insertAfterSoi(allocator, &.{ 0xFF, 0xD8, 0xFF, 0xD9 }, segment);
    defer allocator.free(jpeg);

    try std.testing.expectEqual(@as(u8, 6), orientation(jpeg));
    try std.testing.expectEqualSlices(u8, &fake_thumb, embeddedThumb(jpeg).?);
}

test "no EXIF, or a broken one, reads as upright with no preview" {
    try std.testing.expectEqual(@as(u8, 1), orientation(""));
    try std.testing.expectEqual(@as(u8, 1), orientation(&.{ 0xFF, 0xD8, 0xFF, 0xD9 }));
    try std.testing.expect(embeddedThumb("not a jpeg") == null);

    const allocator = std.testing.allocator;
    const segment = try testing.app1(allocator, 9, "");
    defer allocator.free(segment);
    const jpeg = try testing.insertAfterSoi(allocator, &.{ 0xFF, 0xD8, 0xFF, 0xD9 }, segment);
    defer allocator.free(jpeg);
    try std.testing.expectEqual(@as(u8, 1), orientation(jpeg)); // 9 is not a valid value
    try std.testing.expect(embeddedThumb(jpeg) == null);

    // Every truncation of a valid segment parses without reading past the end.
    const with_thumb = try testing.app1(allocator, 3, &.{ 0xFF, 0xD8, 0, 0xFF, 0xD9 });
    defer allocator.free(with_thumb);
    const full = try testing.insertAfterSoi(allocator, &.{ 0xFF, 0xD8, 0xFF, 0xD9 }, with_thumb);
    defer allocator.free(full);
    for (0..full.len) |n| {
        _ = orientation(full[0..n]);
        _ = embeddedThumb(full[0..n]);
    }
}
