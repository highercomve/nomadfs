//! Finding and extracting embedded preview pictures from TIFF-based RAW files
//! (.dng, .nef, .arw, .cr2).
//!
//! A RAW picture from a camera embeds one or more JPEG previews (and often an
//! uncompressed RGB thumbnail) in its TIFF IFD tree. This decoder traverses
//! IFD0, its next-IFD chain, and SubIFDs (tag 330) up to a bounded depth and
//! IFD count, returning the largest decodable embedded JPEG (or an RGB preview
//! encoded to JPEG as fallback). RAW sensor data (such as lossless JPEG) is
//! skipped without demosaicing.
//!
//! The layer sits below fs and uses only std and codec helpers (image.zig,
//! budget.zig).

const std = @import("std");
const budget = @import("budget.zig");
const image = @import("image.zig");

const Allocator = std.mem.Allocator;
const Dims = image.Dims;

/// Most IFDs examined across next-IFD links and SubIFD references.
pub const max_ifds = 8;
/// Most directory entries accepted in a single IFD.
pub const max_entries = 256;
/// Maximum depth of SubIFD recursion (IFD0 is depth 0).
pub const max_depth = 2;

const tag_image_width = 0x0100; // 256
const tag_image_length = 0x0101; // 257
const tag_bits_per_sample = 0x0102; // 258
const tag_compression = 0x0103; // 259
const tag_photometric = 0x0106; // 262
const tag_strip_offsets = 0x0111; // 273
const tag_orientation = 0x0112; // 274
const tag_samples_per_pixel = 0x0115; // 277
const tag_strip_byte_counts = 0x0117; // 279
const tag_tile_offsets = 0x0144; // 324
const tag_tile_byte_counts = 0x0145; // 325
const tag_sub_ifds = 0x014a; // 330
const tag_jpeg_interchange_format = 0x0201; // 513
const tag_jpeg_interchange_format_length = 0x0202; // 514

const type_byte = 1;
const type_short = 3;
const type_long = 4;
const type_ifd = 13;

/// The largest embedded JPEG preview inside `bytes`, or null if none is found.
/// Returned slice borrows from `bytes`.
pub fn preview(bytes: []const u8) ?[]const u8 {
    const tiff = Tiff.init(bytes) orelse return null;
    const first = tiff.firstIfd() orelse return null;
    var walker = Walker{ .tiff = tiff };
    walker.walk(first, 0);
    if (walker.best_jpeg) |cand| {
        return bytes[cand.offset .. cand.offset + cand.len];
    }
    return null;
}

/// Fallback preview: an uncompressed RGB IFD (Compression 1, Photometric 2,
/// 8-bit, 3 samples) encoded to baseline JPEG with the stb writer. Caller-owned.
pub fn rgbPreview(allocator: Allocator, bytes: []const u8) !?[]u8 {
    const tiff = Tiff.init(bytes) orelse return null;
    const first = tiff.firstIfd() orelse return null;
    var walker = Walker{ .tiff = tiff };
    walker.walk(first, 0);
    const cand = walker.best_rgb orelse return null;
    const slice = bytes[cand.offset .. cand.offset + cand.len];
    const dims: Dims = .{ .width = cand.width, .height = cand.height };
    return image.encodeJpeg(allocator, slice, dims, 85) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return null,
    };
}

/// The preview JPEG of `bytes`, either the largest embedded JPEG or the
/// uncompressed RGB fallback encoded to JPEG. Caller-owned.
pub fn previewJpeg(allocator: Allocator, bytes: []const u8) !?[]u8 {
    if (preview(bytes)) |jpeg| {
        return try allocator.dupe(u8, jpeg);
    }
    return rgbPreview(allocator, bytes);
}

/// The EXIF orientation from IFD0 tag 274 (0x0112), 1 to 8; 1 when missing
/// or invalid.
pub fn orientation(bytes: []const u8) u8 {
    const tiff = Tiff.init(bytes) orelse return 1;
    const ifd0_off = tiff.firstIfd() orelse return 1;
    const ifd0 = tiff.ifd(ifd0_off) orelse return 1;
    const entry = tiff.findEntry(ifd0, tag_orientation) orelse return 1;
    const val = tiff.longValue(entry) orelse return 1;
    return if (val >= 1 and val <= 8) @intCast(val) else 1;
}

const CandidateJpeg = struct {
    offset: usize,
    len: usize,
    pixels: u64,
};

const CandidateRgb = struct {
    width: u32,
    height: u32,
    offset: usize,
    len: usize,
    pixels: u64,
};

const Ifd = struct {
    off: usize,
    count: u16,
};

const Entry = struct {
    tag: u16,
    kind: u16,
    count: u32,
    value_off: usize,
};

const Tiff = struct {
    data: []const u8,
    endian: std.builtin.Endian,

    fn init(bytes: []const u8) ?Tiff {
        if (bytes.len < 8) return null;
        const endian: std.builtin.Endian = if (std.mem.startsWith(u8, bytes, "II*\x00"))
            .little
        else if (std.mem.startsWith(u8, bytes, "MM\x00*"))
            .big
        else
            return null;
        return .{ .data = bytes, .endian = endian };
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

    fn ifd(self: Tiff, off: u32) ?Ifd {
        if (off < 8 or off >= self.data.len) return null;
        const count = self.u16At(off) orelse return null;
        if (count > max_entries) return null;
        const end = @as(usize, off) + 2 + @as(usize, count) * 12 + 4;
        if (end > self.data.len) return null;
        return .{ .off = off, .count = count };
    }

    fn nextIfd(self: Tiff, from: Ifd) ?u32 {
        const next = self.u32At(from.off + 2 + @as(usize, from.count) * 12) orelse return null;
        if (next == 0 or next >= self.data.len) return null;
        return next;
    }

    fn entryAt(self: Tiff, in: Ifd, index: u16) ?Entry {
        if (index >= in.count) return null;
        const off = in.off + 2 + @as(usize, index) * 12;
        return .{
            .tag = self.u16At(off) orelse return null,
            .kind = self.u16At(off + 2) orelse return null,
            .count = self.u32At(off + 4) orelse return null,
            .value_off = off + 8,
        };
    }

    fn findEntry(self: Tiff, in: Ifd, tag: u16) ?Entry {
        for (0..in.count) |i| {
            const e = self.entryAt(in, @intCast(i)) orelse continue;
            if (e.tag == tag) return e;
        }
        return null;
    }

    fn longValue(self: Tiff, e: Entry) ?u32 {
        if (e.count != 1) return null;
        return switch (e.kind) {
            type_byte => self.data[e.value_off],
            type_short => if (self.u16At(e.value_off)) |v| @as(u32, v) else null,
            type_long, type_ifd => self.u32At(e.value_off),
            else => null,
        };
    }
};

const Walker = struct {
    tiff: Tiff,
    visited: [max_ifds]usize = undefined,
    visited_count: usize = 0,
    best_jpeg: ?CandidateJpeg = null,
    best_rgb: ?CandidateRgb = null,

    fn isVisited(self: *Walker, off: usize) bool {
        for (self.visited[0..self.visited_count]) |v| {
            if (v == off) return true;
        }
        return false;
    }

    fn walk(self: *Walker, off: usize, depth: usize) void {
        if (self.visited_count >= max_ifds) return;
        if (off == 0 or off >= self.tiff.data.len) return;
        if (self.isVisited(off)) return;

        self.visited[self.visited_count] = off;
        self.visited_count += 1;

        const current_ifd = self.tiff.ifd(@intCast(off)) orelse return;

        // Check for JPEG candidates in this IFD
        self.checkJpegCandidates(current_ifd);

        // Check for uncompressed RGB candidate in this IFD
        self.checkRgbCandidate(current_ifd);

        // SubIFDs (tag 330) up to max_depth
        if (depth < max_depth) {
            if (self.tiff.findEntry(current_ifd, tag_sub_ifds)) |sub_entry| {
                var subs: [max_ifds]u32 = undefined;
                const count = subIfdOffsets(self.tiff, sub_entry, &subs);
                for (subs[0..count]) |sub_off| {
                    self.walk(sub_off, depth + 1);
                }
            }
        }

        // Next IFD in main chain
        if (self.tiff.nextIfd(current_ifd)) |next_off| {
            self.walk(next_off, depth);
        }
    }

    fn checkJpegCandidates(self: *Walker, in: Ifd) void {
        // (a) JPEGInterchangeFormat / Length (513 / 514)
        if (self.tiff.findEntry(in, tag_jpeg_interchange_format)) |e513| {
            if (self.tiff.findEntry(in, tag_jpeg_interchange_format_length)) |e514| {
                const off = self.tiff.longValue(e513);
                const len = self.tiff.longValue(e514);
                if (off) |o| if (len) |l| {
                    self.recordJpegCandidate(o, l);
                };
            }
        }

        // (b) Compression 6 or 7 single strip or tile
        if (self.tiff.findEntry(in, tag_compression)) |comp_entry| {
            const comp = self.tiff.longValue(comp_entry) orelse 0;
            if (comp == 6 or comp == 7) {
                // Single strip (273 / 279)
                if (self.tiff.findEntry(in, tag_strip_offsets)) |so| {
                    if (self.tiff.findEntry(in, tag_strip_byte_counts)) |sbc| {
                        if (so.count == 1 and sbc.count == 1) {
                            const off = self.tiff.longValue(so);
                            const len = self.tiff.longValue(sbc);
                            if (off) |o| if (len) |l| {
                                self.recordJpegCandidate(o, l);
                            };
                        }
                    }
                }
                // Single tile (324 / 325)
                if (self.tiff.findEntry(in, tag_tile_offsets)) |to| {
                    if (self.tiff.findEntry(in, tag_tile_byte_counts)) |tbc| {
                        if (to.count == 1 and tbc.count == 1) {
                            const off = self.tiff.longValue(to);
                            const len = self.tiff.longValue(tbc);
                            if (off) |o| if (len) |l| {
                                self.recordJpegCandidate(o, l);
                            };
                        }
                    }
                }
            }
        }
    }

    fn recordJpegCandidate(self: *Walker, off: usize, len: usize) void {
        if (len < 4 or off > self.tiff.data.len or len > self.tiff.data.len - off) return;
        const slice = self.tiff.data[off .. off + len];
        if (slice[0] != 0xFF or slice[1] != 0xD8) return;
        const dims = image.info(slice) catch return;
        const cand: CandidateJpeg = .{
            .offset = off,
            .len = len,
            .pixels = dims.pixels(),
        };
        if (self.best_jpeg == null or cand.pixels > self.best_jpeg.?.pixels) {
            self.best_jpeg = cand;
        }
    }

    fn checkRgbCandidate(self: *Walker, in: Ifd) void {
        const comp_entry = self.tiff.findEntry(in, tag_compression) orelse return;
        if ((self.tiff.longValue(comp_entry) orelse 0) != 1) return;

        const photo_entry = self.tiff.findEntry(in, tag_photometric) orelse return;
        if ((self.tiff.longValue(photo_entry) orelse 0) != 2) return; // RGB

        if (!isRgb8(self.tiff, in)) return;

        const w_entry = self.tiff.findEntry(in, tag_image_width) orelse return;
        const h_entry = self.tiff.findEntry(in, tag_image_length) orelse return;
        const w = self.tiff.longValue(w_entry) orelse return;
        const h = self.tiff.longValue(h_entry) orelse return;
        if (w == 0 or h == 0 or w > image.max_dimension or h > image.max_dimension) return;
        const pixels = @as(u64, w) * h;
        if (pixels > 50_000_000) return;

        const needed_bytes = std.math.mul(usize, @as(usize, w) * h, 3) catch return;

        // Check single strip
        const so_entry = self.tiff.findEntry(in, tag_strip_offsets) orelse return;
        if (so_entry.count != 1) return;
        const off = self.tiff.longValue(so_entry) orelse return;

        var len = needed_bytes;
        if (self.tiff.findEntry(in, tag_strip_byte_counts)) |sbc| {
            if (sbc.count == 1) {
                if (self.tiff.longValue(sbc)) |sbc_len| {
                    if (sbc_len < needed_bytes) return;
                    len = sbc_len;
                }
            }
        }
        if (off > self.tiff.data.len or needed_bytes > self.tiff.data.len - off) return;

        const cand: CandidateRgb = .{
            .width = w,
            .height = h,
            .offset = off,
            .len = needed_bytes,
            .pixels = pixels,
        };
        if (self.best_rgb == null or cand.pixels > self.best_rgb.?.pixels) {
            self.best_rgb = cand;
        }
    }
};

fn subIfdOffsets(tiff: Tiff, entry: Entry, out: *[max_ifds]u32) usize {
    if (entry.count == 0) return 0;
    const n = @min(entry.count, max_ifds);
    if (entry.count == 1) {
        if (tiff.longValue(entry)) |v| {
            out[0] = v;
            return 1;
        }
        return 0;
    }
    const arr_off = tiff.u32At(entry.value_off) orelse return 0;
    var filled: usize = 0;
    for (0..n) |i| {
        const off = arr_off + i * 4;
        if (tiff.u32At(off)) |sub_off| {
            out[filled] = sub_off;
            filled += 1;
        }
    }
    return filled;
}

fn isRgb8(tiff: Tiff, in: Ifd) bool {
    const bps_entry = tiff.findEntry(in, tag_bits_per_sample) orelse return false;
    if (bps_entry.count == 1) {
        return (tiff.longValue(bps_entry) orelse 0) == 8;
    }
    if (bps_entry.count == 3) {
        if (bps_entry.kind == type_short) {
            const arr_off = tiff.u32At(bps_entry.value_off) orelse return false;
            const b0 = tiff.u16At(arr_off) orelse return false;
            const b1 = tiff.u16At(arr_off + 2) orelse return false;
            const b2 = tiff.u16At(arr_off + 4) orelse return false;
            return b0 == 8 and b1 == 8 and b2 == 8;
        } else if (bps_entry.kind == type_byte) {
            if (bps_entry.value_off + 3 > tiff.data.len) return false;
            return tiff.data[bps_entry.value_off] == 8 and
                tiff.data[bps_entry.value_off + 1] == 8 and
                tiff.data[bps_entry.value_off + 2] == 8;
        }
    }
    return false;
}

/// Test utilities to construct synthetic TIFF files in memory.
pub const testing = struct {
    pub const Builder = struct {
        allocator: Allocator,
        endian: std.builtin.Endian,
        bytes: std.ArrayList(u8),

        pub fn init(allocator: Allocator, endian: std.builtin.Endian) Builder {
            return .{
                .allocator = allocator,
                .endian = endian,
                .bytes = .empty,
            };
        }

        pub fn deinit(self: *Builder) void {
            self.bytes.deinit(self.allocator);
        }

        pub fn writeHeader(self: *Builder, first_ifd: u32) !void {
            const magic = if (self.endian == .little) "II*\x00" else "MM\x00*";
            try self.bytes.appendSlice(self.allocator, magic);
            var buf: [4]u8 = undefined;
            std.mem.writeInt(u32, &buf, first_ifd, self.endian);
            try self.bytes.appendSlice(self.allocator, &buf);
        }

        pub fn writeU16(self: *Builder, val: u16) !void {
            var buf: [2]u8 = undefined;
            std.mem.writeInt(u16, &buf, val, self.endian);
            try self.bytes.appendSlice(self.allocator, &buf);
        }

        pub fn writeU32(self: *Builder, val: u32) !void {
            var buf: [4]u8 = undefined;
            std.mem.writeInt(u32, &buf, val, self.endian);
            try self.bytes.appendSlice(self.allocator, &buf);
        }

        pub fn writeEntry(self: *Builder, tag: u16, kind: u16, count: u32, val_or_off: u32) !void {
            try self.writeU16(tag);
            try self.writeU16(kind);
            try self.writeU32(count);
            if (kind == type_short and count == 1) {
                try self.writeU16(@intCast(val_or_off));
                try self.writeU16(0);
            } else {
                try self.writeU32(val_or_off);
            }
        }

        pub fn appendBytes(self: *Builder, slice: []const u8) !u32 {
            const off: u32 = @intCast(self.bytes.items.len);
            try self.bytes.appendSlice(self.allocator, slice);
            return off;
        }

        pub fn toOwnedSlice(self: *Builder) ![]u8 {
            return self.bytes.toOwnedSlice(self.allocator);
        }
    };
};

const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;

test "raw: IFD0 with RGB strip and SubIFD with embedded JPEG" {
    const allocator = std.testing.allocator;
    var b = testing.Builder.init(allocator, .little);
    defer b.deinit();

    // Make an embedded JPEG preview (32x24)
    const jpeg = try image.testing.gradientJpeg(allocator, 32, 24, 128);
    defer allocator.free(jpeg);

    // Make an uncompressed RGB strip for IFD0 (4x4)
    const rgb = try image.testing.gradient(allocator, 4, 4, 0);
    defer allocator.free(rgb);

    // Layout:
    // 0..8: header (first IFD at 8)
    // 8..118: IFD0 (9 entries: 2 + 9*12 + 4 = 114 bytes) -> 8..122
    // 122..: SubIFD1 (5 entries: 2 + 5*12 + 4 = 66 bytes) -> 122..188
    // 188..: RGB strip (48 bytes) -> 188..236
    // 236..: JPEG data
    try b.writeHeader(8);

    const ifd0_entries: u16 = 9;
    try b.writeU16(ifd0_entries);
    try b.writeEntry(tag_image_width, type_short, 1, 4);
    try b.writeEntry(tag_image_length, type_short, 1, 4);
    try b.writeEntry(tag_bits_per_sample, type_short, 1, 8);
    try b.writeEntry(tag_compression, type_short, 1, 1); // uncompressed
    try b.writeEntry(tag_photometric, type_short, 1, 2); // RGB
    try b.writeEntry(tag_orientation, type_short, 1, 6); // turn 6
    const subifd_offset: u32 = 8 + 2 + ifd0_entries * 12 + 4;
    const subifd_entries: u16 = 5;
    const rgb_offset = subifd_offset + 2 + subifd_entries * 12 + 4;
    const jpeg_offset = rgb_offset + @as(u32, @intCast(rgb.len));
    try b.writeEntry(tag_strip_offsets, type_long, 1, rgb_offset);
    try b.writeEntry(tag_strip_byte_counts, type_long, 1, @intCast(rgb.len));
    try b.writeEntry(tag_sub_ifds, type_ifd, 1, subifd_offset);
    try b.writeU32(0); // next IFD = 0

    // SubIFD1
    try b.writeU16(subifd_entries);
    try b.writeEntry(tag_image_width, type_short, 1, 32);
    try b.writeEntry(tag_image_length, type_short, 1, 24);
    try b.writeEntry(tag_compression, type_short, 1, 7); // JPEG
    try b.writeEntry(tag_strip_offsets, type_long, 1, jpeg_offset);
    try b.writeEntry(tag_strip_byte_counts, type_long, 1, @intCast(jpeg.len));
    try b.writeU32(0); // next IFD = 0

    // Data payloads
    _ = try b.appendBytes(rgb);
    _ = try b.appendBytes(jpeg);

    const raw_bytes = b.bytes.items;

    // 1. Orientation from IFD0
    try expectEqual(@as(u8, 6), orientation(raw_bytes));

    // 2. Largest JPEG found is SubIFD1's JPEG
    const found_jpeg = preview(raw_bytes);
    try expect(found_jpeg != null);
    try std.testing.expectEqualSlices(u8, jpeg, found_jpeg.?);

    // 3. previewJpeg returns owned copy
    const owned_jpeg = (try previewJpeg(allocator, raw_bytes)).?;
    defer allocator.free(owned_jpeg);
    try std.testing.expectEqualSlices(u8, jpeg, owned_jpeg);

    // 4. thumbnail turns and resizes as IFD0 orientation says
    const thumb = try image.thumbnail(allocator, raw_bytes, .{});
    defer allocator.free(thumb);
    const thumb_dims = try image.info(thumb);
    // 32x24 with orientation 6 (swaps w and h) -> 24x32
    try expectEqual(@as(u32, 24), thumb_dims.width);
    try expectEqual(@as(u32, 32), thumb_dims.height);
}

test "raw: big-endian MM TIFF with JPEG preview" {
    const allocator = std.testing.allocator;
    var b = testing.Builder.init(allocator, .big);
    defer b.deinit();

    const jpeg = try image.testing.gradientJpeg(allocator, 16, 16, 200);
    defer allocator.free(jpeg);

    try b.writeHeader(8);

    const ifd_entries: u16 = 5;
    const jpeg_offset: u32 = 8 + 2 + ifd_entries * 12 + 4;

    try b.writeU16(ifd_entries);
    try b.writeEntry(tag_image_width, type_short, 1, 16);
    try b.writeEntry(tag_image_length, type_short, 1, 16);
    try b.writeEntry(tag_compression, type_short, 1, 7);
    try b.writeEntry(tag_strip_offsets, type_long, 1, jpeg_offset);
    try b.writeEntry(tag_strip_byte_counts, type_long, 1, @intCast(jpeg.len));
    try b.writeU32(0);

    _ = try b.appendBytes(jpeg);

    const raw_bytes = b.bytes.items;
    const found = preview(raw_bytes);
    try expect(found != null);
    try std.testing.expectEqualSlices(u8, jpeg, found.?);

    const owned = (try previewJpeg(allocator, raw_bytes)).?;
    defer allocator.free(owned);
    try std.testing.expectEqualSlices(u8, jpeg, owned);
}

test "raw: lossless-JPEG-like strip skipped, falls back to uncompressed RGB" {
    const allocator = std.testing.allocator;
    var b = testing.Builder.init(allocator, .little);
    defer b.deinit();

    // Fake lossless JPEG strip: starts with FFD8 then non-decodable data
    const fake_lossless = [_]u8{ 0xFF, 0xD8, 0xFF, 0xC3, 0x00, 0x0B, 0x08, 0x00, 0x10, 0x00, 0x10, 0x01, 0x01, 0x11, 0x00 };

    // Valid 4x4 uncompressed RGB
    const rgb = try image.testing.gradient(allocator, 4, 4, 10);
    defer allocator.free(rgb);

    try b.writeHeader(8);

    const ifd_entries: u16 = 9;
    const fake_offset: u32 = 8 + 2 + ifd_entries * 12 + 4;
    const rgb_offset = fake_offset + @as(u32, @intCast(fake_lossless.len));

    try b.writeU16(ifd_entries);
    try b.writeEntry(tag_image_width, type_short, 1, 4);
    try b.writeEntry(tag_image_length, type_short, 1, 4);
    try b.writeEntry(tag_bits_per_sample, type_short, 1, 8);
    try b.writeEntry(tag_compression, type_short, 1, 1); // RGB IFD
    try b.writeEntry(tag_photometric, type_short, 1, 2);
    try b.writeEntry(tag_strip_offsets, type_long, 1, rgb_offset);
    try b.writeEntry(tag_strip_byte_counts, type_long, 1, @intCast(rgb.len));
    // Add tag 513/514 pointing to the fake lossless JPEG
    try b.writeEntry(tag_jpeg_interchange_format, type_long, 1, fake_offset);
    try b.writeEntry(tag_jpeg_interchange_format_length, type_long, 1, @intCast(fake_lossless.len));
    try b.writeU32(0);

    _ = try b.appendBytes(&fake_lossless);
    _ = try b.appendBytes(rgb);

    const raw_bytes = b.bytes.items;

    // preview() returns null because the candidate JPEG fails stb info check
    try expect(preview(raw_bytes) == null);

    // previewJpeg falls back to encoding the RGB strip
    const jpeg = (try previewJpeg(allocator, raw_bytes)).?;
    defer allocator.free(jpeg);
    try expect(std.mem.startsWith(u8, jpeg, &.{ 0xFF, 0xD8 }));
    const dims = try image.info(jpeg);
    try expectEqual(@as(u32, 4), dims.width);
    try expectEqual(@as(u32, 4), dims.height);
}

test "raw: random, truncated and corrupted input never panics" {
    const allocator = std.testing.allocator;
    var prng = std.Random.DefaultPrng.init(0x726177646e67); // "rawdng"
    const random = prng.random();

    // Create a seed valid TIFF
    var b = testing.Builder.init(allocator, .little);
    defer b.deinit();
    const fake_jpeg = [_]u8{ 0xFF, 0xD8, 0xFF, 0xD9 };
    try b.writeHeader(8);
    try b.writeU16(3);
    try b.writeEntry(tag_compression, type_short, 1, 7);
    try b.writeEntry(tag_strip_offsets, type_long, 1, 48);
    try b.writeEntry(tag_strip_byte_counts, type_long, 1, fake_jpeg.len);
    try b.writeU32(0);
    _ = try b.appendBytes(&fake_jpeg);

    const seed = b.bytes.items;
    var noise: [2048]u8 = undefined;

    for (0..256) |round| {
        const input = try allocator.dupe(u8, seed);
        defer allocator.free(input);
        var bytes: []const u8 = input;
        switch (round % 4) {
            0 => bytes = input[0..random.uintLessThan(usize, input.len)],
            1 => for (0..1 + random.uintLessThan(usize, 8)) |_| {
                input[random.uintLessThan(usize, input.len)] = random.int(u8);
            },
            2 => {
                const keep = random.uintLessThan(usize, @min(input.len, 16));
                random.bytes(input[keep..]);
            },
            else => {
                random.bytes(&noise);
                bytes = noise[0..random.uintLessThan(usize, noise.len)];
            },
        }

        _ = preview(bytes);
        _ = orientation(bytes);
        if (previewJpeg(allocator, bytes)) |maybe| {
            if (maybe) |j| allocator.free(j);
        } else |_| {}
        if (image.thumbnail(allocator, bytes, .{})) |thumb| {
            allocator.free(thumb);
        } else |_| {}
    }
}
