//! Pictures in, a small JPEG out. `info` reads a picture's size from its
//! header; `thumbnail` decodes a JPEG, PNG, GIF or BMP, scales it down,
//! turns it the way its EXIF orientation says and encodes a baseline JPEG.
//!
//! The bytes are untrusted (they come from files, and thumbnails from
//! peers): the size is read and checked before anything is decoded, and
//! stb's memory is capped per call (budget.zig) from that checked size, so
//! a header that lies makes the decode fail instead of taking the memory.

const std = @import("std");
const budget = @import("budget.zig");
const exif = @import("exif.zig");

const Allocator = std.mem.Allocator;

/// Width and height in pixels, as stored (before any EXIF orientation).
pub const Dims = struct {
    width: u32,
    height: u32,

    pub fn longEdge(self: Dims) u32 {
        return @max(self.width, self.height);
    }

    pub fn pixels(self: Dims) u64 {
        return @as(u64, self.width) * self.height;
    }
};

/// Widest and tallest picture decoded (`STBI_MAX_DIMENSIONS` in
/// stb/stb_impl.c).
pub const max_dimension = 16384;

pub const Options = struct {
    /// Long edge of the thumbnail. A smaller picture keeps its size.
    max_edge: u32 = 320,
    /// JPEG quality, 1 to 100.
    quality: u8 = 75,
    /// Pictures with more pixels than this are refused (`error.TooLarge`):
    /// decoding takes several bytes per pixel.
    max_pixels: u64 = 50_000_000,
};

pub const Error = error{
    /// Not a JPEG, PNG, GIF or BMP, or its header is broken.
    UnknownFormat,
    /// More pixels than `max_pixels`, or decoding needs more memory than a
    /// picture of its size may take.
    TooLarge,
    /// The header reads, the picture data doesn't decode.
    DecodeFailed,
    OutOfMemory,
};

/// An embedded EXIF preview is used instead of the full picture when its
/// long edge is at least this.
const min_preview_edge = 240;
/// The smallest EXIF preview used for a picture too large to decode.
const min_tiny_preview_edge = 96;

/// Bytes of stb memory allowed per pixel of the picture being decoded. The
/// worst cases: a 16-bit RGBA PNG (8 inflated + 8 unfiltered), a
/// progressive 4:4:4 JPEG (6 coefficients + 3 planes + 3 output).
const decode_bytes_per_pixel = 16;
/// Plus this, for decoder state and the resizer's working rows. Measured:
/// scaling 16384 x 16384 down to 320 peaks under 2 MiB; a baseline JPEG
/// decodes in 4 bytes per pixel, an 8-bit PNG in 6.
const scratch_budget = 8 << 20;
/// For reading a header (stb allocates its decoder state) and for encoding.
const small_budget = 1 << 20;

/// The size of the picture in `bytes`, from its header alone.
pub fn info(bytes: []const u8) Error!Dims {
    const len = std.math.cast(c_int, bytes.len) orelse return error.TooLarge;
    if (len == 0) return error.UnknownFormat;
    var w: c_int = 0;
    var h: c_int = 0;
    var comp: c_int = 0;
    budget.begin(small_budget);
    defer budget.end();
    if (stbi_info_from_memory(bytes.ptr, len, &w, &h, &comp) == 0) {
        return if (budget.outOfMemory()) error.OutOfMemory else error.UnknownFormat;
    }
    if (w <= 0 or h <= 0) return error.UnknownFormat;
    if (w > max_dimension or h > max_dimension) return error.TooLarge;
    return .{ .width = @intCast(w), .height = @intCast(h) };
}

/// A JPEG of the picture in `bytes`, its long edge at most `opts.max_edge`,
/// shown the way up its EXIF orientation says. Caller-owned.
pub fn thumbnail(allocator: Allocator, bytes: []const u8, opts: Options) Error![]u8 {
    std.debug.assert(opts.max_edge >= 1);
    if (std.mem.startsWith(u8, bytes, "II*\x00") or std.mem.startsWith(u8, bytes, "MM\x00*")) {
        const raw = @import("raw.zig");
        const jpeg = (try raw.previewJpeg(allocator, bytes)) orelse return error.UnknownFormat;
        defer allocator.free(jpeg);
        const tiff_turn = raw.orientation(bytes);
        return thumbnailJpeg(allocator, jpeg, opts, tiff_turn);
    }
    return thumbnailJpeg(allocator, bytes, opts, null);
}

fn thumbnailJpeg(allocator: Allocator, bytes: []const u8, opts: Options, override_turn: ?u8) Error![]u8 {
    const dims = try info(bytes);
    const exif_turn = exif.orientation(bytes);
    const turn = if (override_turn) |t| (if (exif_turn != 1) exif_turn else t) else exif_turn;
    if (dims.pixels() > opts.max_pixels) {
        // Too big to decode here: the camera's own small preview, however
        // small, beats no thumbnail at all.
        const preview = exif.embeddedThumb(bytes) orelse return error.TooLarge;
        const small = info(preview) catch return error.TooLarge;
        if (small.longEdge() < min_tiny_preview_edge or small.pixels() > opts.max_pixels) return error.TooLarge;
        return render(allocator, preview, small, turn, opts, decodeBudget(small)) catch |err| switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            else => error.TooLarge,
        };
    }

    // Cameras store a small preview in the EXIF block: decoding that is
    // far cheaper than the full picture.
    if (exif.embeddedThumb(bytes)) |preview| {
        if (fromPreview(allocator, preview, dims, turn, opts)) |jpeg| {
            return jpeg;
        } else |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            // Too small, another shape or broken: use the full picture.
            error.UnknownFormat, error.TooLarge, error.DecodeFailed => {},
        }
    }
    return render(allocator, bytes, dims, turn, opts, decodeBudget(dims));
}

/// The thumbnail made from the EXIF preview of a picture of size `full`.
/// Fails with `error.DecodeFailed` when the preview is not usable.
fn fromPreview(allocator: Allocator, preview: []const u8, full: Dims, turn: u8, opts: Options) Error![]u8 {
    const dims = try info(preview);
    if (dims.longEdge() < min_preview_edge) return error.DecodeFailed;
    if (dims.pixels() > full.pixels()) return error.DecodeFailed;
    // Some cameras pad the preview to 4:3 with black bars; only a preview
    // of the picture's own shape (within 1/32) stands in for it.
    const a = @as(u64, dims.width) * full.height;
    const b = @as(u64, dims.height) * full.width;
    if (@max(a, b) - @min(a, b) > @max(a, b) / 32) return error.DecodeFailed;
    return render(allocator, preview, dims, turn, opts, decodeBudget(dims));
}

fn decodeBudget(dims: Dims) usize {
    const bytes = dims.pixels() *| decode_bytes_per_pixel +| scratch_budget;
    return std.math.cast(usize, bytes) orelse std.math.maxInt(usize);
}

/// Decodes `bytes` (a picture of size `dims`) with at most `limit` bytes of
/// stb memory, scales, turns and encodes it.
fn render(allocator: Allocator, bytes: []const u8, dims: Dims, turn: u8, opts: Options, limit: usize) Error![]u8 {
    const size = fit(dims, opts.max_edge);
    const scaled = try allocator.alloc(u8, rgbLen(size));
    defer allocator.free(scaled);
    try decodeScaled(bytes, dims, size, scaled, limit);

    const turned = try orient(allocator, scaled, size, turn);
    defer if (turned.pixels.ptr != scaled.ptr) allocator.free(turned.pixels);
    return encodeJpeg(allocator, turned.pixels, turned.dims, opts.quality);
}

/// Decodes `bytes` to RGB and scales it to `size` into `out`.
fn decodeScaled(bytes: []const u8, dims: Dims, size: Dims, out: []u8, limit: usize) Error!void {
    std.debug.assert(out.len == rgbLen(size));
    const len = std.math.cast(c_int, bytes.len) orelse return error.TooLarge;
    budget.begin(limit);
    defer budget.end();

    var w: c_int = 0;
    var h: c_int = 0;
    var comp: c_int = 0;
    const decoded = stbi_load_from_memory(bytes.ptr, len, &w, &h, &comp, 3) orelse return stbFailure();
    defer stbi_image_free(decoded);
    // The decoder and the header check must agree on the size: `decoded`
    // is read as dims.width x dims.height below.
    if (w != dims.width or h != dims.height) return error.DecodeFailed;

    if (size.width == dims.width and size.height == dims.height) {
        @memcpy(out, decoded[0..out.len]);
        return;
    }
    const resized = stbir_resize_uint8_srgb(
        decoded,
        w,
        h,
        @as(i64, w) * 3,
        out.ptr,
        @intCast(size.width),
        @intCast(size.height),
        @as(i64, size.width) * 3,
        stbir_rgb,
    );
    if (resized == null) return stbFailure();
}

/// Why stb returned nothing, from what the budget saw.
fn stbFailure() Error {
    if (budget.outOfMemory()) return error.OutOfMemory;
    if (budget.denied()) return error.TooLarge;
    return error.DecodeFailed;
}

/// `dims` scaled to a long edge of `max_edge`; unchanged when smaller.
fn fit(dims: Dims, max_edge: u32) Dims {
    const long: u64 = dims.longEdge();
    if (long <= max_edge) return dims;
    return .{
        .width = scaleEdge(dims.width, max_edge, long),
        .height = scaleEdge(dims.height, max_edge, long),
    };
}

fn scaleEdge(edge: u32, max_edge: u32, long: u64) u32 {
    const scaled = (@as(u64, edge) * max_edge + long / 2) / long;
    return @intCast(@max(scaled, 1)); // at most max_edge: edge <= long
}

fn rgbLen(dims: Dims) usize {
    return @as(usize, dims.width) * dims.height * 3;
}

const Raster = struct { pixels: []u8, dims: Dims };

/// `src` (RGB, `dims`) turned as EXIF orientation `turn` (1 to 8) says.
/// Orientation 1 returns `src` itself; any other a new caller-owned buffer.
fn orient(allocator: Allocator, src: []u8, dims: Dims, turn: u8) Allocator.Error!Raster {
    if (turn <= 1 or turn > 8) return .{ .pixels = src, .dims = dims };
    const w: usize = dims.width;
    const h: usize = dims.height;
    const swapped = turn >= 5;
    const out_dims: Dims = if (swapped) .{ .width = dims.height, .height = dims.width } else dims;
    const out = try allocator.alloc(u8, src.len);
    const out_w: usize = out_dims.width;
    for (0..out_dims.height) |y| {
        for (0..out_w) |x| {
            // Where in the stored picture the pixel shown at (x, y) is.
            const sx, const sy = switch (turn) {
                2 => .{ w - 1 - x, y }, // mirrored
                3 => .{ w - 1 - x, h - 1 - y }, // upside down
                4 => .{ x, h - 1 - y }, // flipped
                5 => .{ y, x }, // transposed
                6 => .{ y, h - 1 - x }, // needs a quarter turn clockwise
                7 => .{ w - 1 - y, h - 1 - x }, // transverse
                8 => .{ w - 1 - y, x }, // needs a quarter turn anticlockwise
                else => unreachable,
            };
            const from = (sy * w + sx) * 3;
            const to = (y * out_w + x) * 3;
            out[to..][0..3].* = src[from..][0..3].*;
        }
    }
    return .{ .pixels = out, .dims = out_dims };
}

/// What stb's JPEG writer writes into.
const Sink = struct {
    allocator: Allocator,
    bytes: std.ArrayList(u8) = .empty,
    failed: bool = false,

    fn write(context: ?*anyopaque, data: ?*anyopaque, size: c_int) callconv(.c) void {
        const self: *Sink = @ptrCast(@alignCast(context.?));
        if (self.failed or size <= 0) return;
        const chunk = @as([*]const u8, @ptrCast(data.?))[0..@intCast(size)];
        self.bytes.appendSlice(self.allocator, chunk) catch {
            self.failed = true; // reported by the caller after the writer returns
        };
    }
};

/// RGB pixels as a baseline JPEG. Caller-owned.
pub fn encodeJpeg(allocator: Allocator, pixels: []const u8, dims: Dims, quality: u8) Error![]u8 {
    std.debug.assert(pixels.len == rgbLen(dims));
    var sink: Sink = .{ .allocator = allocator };
    errdefer sink.bytes.deinit(allocator);
    budget.begin(small_budget);
    defer budget.end();
    const ok = stbi_write_jpg_to_func(
        Sink.write,
        &sink,
        @intCast(dims.width),
        @intCast(dims.height),
        3,
        pixels.ptr,
        std.math.clamp(quality, 1, 100),
    );
    if (sink.failed) return error.OutOfMemory;
    if (ok == 0) return stbFailure();
    return sink.bytes.toOwnedSlice(allocator);
}

// The stb functions used, compiled in stb/stb_impl.c.
const stbir_rgb: c_int = 3; // STBIR_RGB
const WriteFn = *const fn (context: ?*anyopaque, data: ?*anyopaque, size: c_int) callconv(.c) void;
extern fn stbi_info_from_memory(buffer: [*]const u8, len: c_int, x: *c_int, y: *c_int, comp: *c_int) c_int;
extern fn stbi_load_from_memory(buffer: [*]const u8, len: c_int, x: *c_int, y: *c_int, channels_in_file: *c_int, desired_channels: c_int) ?[*]u8;
extern fn stbi_image_free(pixels: ?*anyopaque) void;
extern fn stbir_resize_uint8_srgb(input: [*]const u8, input_w: c_int, input_h: c_int, input_stride: i64, output: ?[*]u8, output_w: c_int, output_h: c_int, output_stride: i64, layout: c_int) ?[*]u8;
extern fn stbi_write_jpg_to_func(func: WriteFn, context: ?*anyopaque, x: c_int, y: c_int, comp: c_int, data: *const anyopaque, quality: c_int) c_int;
extern fn stbi_write_png_to_func(func: WriteFn, context: ?*anyopaque, x: c_int, y: c_int, comp: c_int, data: *const anyopaque, stride: c_int) c_int;

/// Test fixtures: pictures made in memory.
pub const testing = struct {
    /// A `width` x `height` gradient as RGB: red grows to the right, green
    /// downwards, blue is `blue` everywhere. Caller-owned.
    pub fn gradient(allocator: Allocator, width: u32, height: u32, blue: u8) ![]u8 {
        const pixels = try allocator.alloc(u8, rgbLen(.{ .width = width, .height = height }));
        for (0..height) |y| {
            for (0..width) |x| {
                const at = (y * width + x) * 3;
                pixels[at] = @intCast(x * 255 / @max(width - 1, 1));
                pixels[at + 1] = @intCast(y * 255 / @max(height - 1, 1));
                pixels[at + 2] = blue;
            }
        }
        return pixels;
    }

    /// The gradient as a JPEG. Caller-owned.
    pub fn gradientJpeg(allocator: Allocator, width: u32, height: u32, blue: u8) ![]u8 {
        const pixels = try gradient(allocator, width, height, blue);
        defer allocator.free(pixels);
        return encodeJpeg(allocator, pixels, .{ .width = width, .height = height }, 90);
    }

    /// The gradient as a PNG. Caller-owned.
    pub fn gradientPng(allocator: Allocator, width: u32, height: u32, blue: u8) ![]u8 {
        const pixels = try gradient(allocator, width, height, blue);
        defer allocator.free(pixels);
        var sink: Sink = .{ .allocator = allocator };
        errdefer sink.bytes.deinit(allocator);
        budget.begin(decodeBudget(.{ .width = width, .height = height }));
        defer budget.end();
        const ok = stbi_write_png_to_func(Sink.write, &sink, @intCast(width), @intCast(height), 3, pixels.ptr, @intCast(width * 3));
        if (sink.failed or ok == 0) return error.OutOfMemory;
        return sink.bytes.toOwnedSlice(allocator);
    }

    /// `jpeg` with an EXIF block: orientation `turn` and, when `preview`
    /// is not empty, that JPEG as its embedded preview. Caller-owned.
    pub fn withExif(allocator: Allocator, jpeg: []const u8, turn: u16, preview: []const u8) ![]u8 {
        const segment = try exif.testing.app1(allocator, turn, preview);
        defer allocator.free(segment);
        return exif.testing.insertAfterSoi(allocator, jpeg, segment);
    }

    /// A picture decoded to RGB at its own size. `pixels` is caller-owned.
    pub fn decode(allocator: Allocator, bytes: []const u8) !Raster {
        const dims = try info(bytes);
        const pixels = try allocator.alloc(u8, rgbLen(dims));
        errdefer allocator.free(pixels);
        try decodeScaled(bytes, dims, dims, pixels, decodeBudget(dims));
        return .{ .pixels = pixels, .dims = dims };
    }

    fn pixelAt(raster: Raster, x: u32, y: u32) [3]u8 {
        return raster.pixels[(@as(usize, y) * raster.dims.width + x) * 3 ..][0..3].*;
    }
};

const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectError = std.testing.expectError;

test "a large picture becomes a 320 pixel JPEG of the same shape" {
    const allocator = std.testing.allocator;
    const jpeg = try testing.gradientJpeg(allocator, 2000, 1500, 128);
    defer allocator.free(jpeg);
    try expectEqual(Dims{ .width = 2000, .height = 1500 }, try info(jpeg));

    const thumb = try thumbnail(allocator, jpeg, .{});
    defer allocator.free(thumb);
    try expect(std.mem.startsWith(u8, thumb, &.{ 0xFF, 0xD8 }));
    try expect(std.mem.endsWith(u8, thumb, &.{ 0xFF, 0xD9 }));
    try expect(thumb.len < 64 << 10);

    const shown = try testing.decode(allocator, thumb);
    defer allocator.free(shown.pixels);
    try expectEqual(Dims{ .width = 320, .height = 240 }, shown.dims);
    // Still the same gradient: dark red on the left, bright on the right.
    try expect(testing.pixelAt(shown, 4, 120)[0] < 40);
    try expect(testing.pixelAt(shown, 315, 120)[0] > 215);
    try expect(testing.pixelAt(shown, 160, 4)[1] < 40);
    try expect(testing.pixelAt(shown, 160, 235)[1] > 215);
}

test "portrait, PNG and small pictures" {
    const allocator = std.testing.allocator;

    const tall = try testing.gradientJpeg(allocator, 300, 1200, 0);
    defer allocator.free(tall);
    const tall_thumb = try thumbnail(allocator, tall, .{});
    defer allocator.free(tall_thumb);
    try expectEqual(Dims{ .width = 80, .height = 320 }, try info(tall_thumb));

    const png = try testing.gradientPng(allocator, 640, 400, 200);
    defer allocator.free(png);
    const png_thumb = try thumbnail(allocator, png, .{});
    defer allocator.free(png_thumb);
    try expectEqual(Dims{ .width = 320, .height = 200 }, try info(png_thumb));

    // Never scaled up.
    const small = try testing.gradientJpeg(allocator, 100, 60, 0);
    defer allocator.free(small);
    const small_thumb = try thumbnail(allocator, small, .{});
    defer allocator.free(small_thumb);
    try expectEqual(Dims{ .width = 100, .height = 60 }, try info(small_thumb));

    // A sliver keeps at least one pixel across.
    try expectEqual(Dims{ .width = 320, .height = 1 }, fit(.{ .width = 16000, .height = 2 }, 320));
}

test "EXIF orientation 6 turns the thumbnail a quarter clockwise" {
    const allocator = std.testing.allocator;
    const plain = try testing.gradientJpeg(allocator, 800, 400, 0);
    defer allocator.free(plain);
    const jpeg = try testing.withExif(allocator, plain, 6, "");
    defer allocator.free(jpeg);
    try expectEqual(Dims{ .width = 800, .height = 400 }, try info(jpeg));

    const thumb = try thumbnail(allocator, jpeg, .{});
    defer allocator.free(thumb);
    const shown = try testing.decode(allocator, thumb);
    defer allocator.free(shown.pixels);
    try expectEqual(Dims{ .width = 160, .height = 320 }, shown.dims);
    // The stored top-left (dark) is now top-right; the stored right edge
    // (red) is the bottom, the stored bottom edge (green) the left.
    const top_right = testing.pixelAt(shown, 155, 4);
    try expect(top_right[0] < 50 and top_right[1] < 50);
    const bottom_right = testing.pixelAt(shown, 155, 315);
    try expect(bottom_right[0] > 205 and bottom_right[1] < 50);
    const top_left = testing.pixelAt(shown, 4, 4);
    try expect(top_left[0] < 50 and top_left[1] > 205);
}

test "every EXIF orientation puts each corner where it is shown" {
    // 2x2: a=top-left, b=top-right, c=bottom-left, d=bottom-right.
    var src = [_]u8{ 'a', 'a', 'a', 'b', 'b', 'b', 'c', 'c', 'c', 'd', 'd', 'd' };
    const shown = [_][]const u8{ "abcd", "badc", "dcba", "cdab", "acbd", "cadb", "dbca", "bdac" };
    for (shown, 1..) |want, turn| {
        const got = try orient(std.testing.allocator, &src, .{ .width = 2, .height = 2 }, @intCast(turn));
        defer if (turn != 1) std.testing.allocator.free(got.pixels);
        for (want, 0..) |corner, i| try expectEqual(corner, got.pixels[i * 3]);
    }
    // A 3x1 strip stands up for the quarter turns.
    var strip = [_]u8{ 1, 1, 1, 2, 2, 2, 3, 3, 3 };
    const up = try orient(std.testing.allocator, &strip, .{ .width = 3, .height = 1 }, 8);
    defer std.testing.allocator.free(up.pixels);
    try expectEqual(Dims{ .width = 1, .height = 3 }, up.dims);
    try expectEqual(@as(u8, 3), up.pixels[0]);
    try expectEqual(@as(u8, 1), up.pixels[6]);
}

test "a large enough embedded preview is decoded instead of the picture" {
    const allocator = std.testing.allocator;
    // The picture has no blue, its previews are all blue: the thumbnail's
    // blue says which one was decoded.
    const plain = try testing.gradientJpeg(allocator, 1600, 1200, 0);
    defer allocator.free(plain);

    const cases = [_]struct { w: u32, h: u32, used: bool }{
        .{ .w = 320, .h = 240, .used = true },
        .{ .w = 240, .h = 180, .used = true },
        .{ .w = 160, .h = 120, .used = false }, // too small
        .{ .w = 320, .h = 320, .used = false }, // not the picture's shape
    };
    for (cases) |case| {
        const preview = try testing.gradientJpeg(allocator, case.w, case.h, 255);
        defer allocator.free(preview);
        const jpeg = try testing.withExif(allocator, plain, 1, preview);
        defer allocator.free(jpeg);
        const thumb = try thumbnail(allocator, jpeg, .{});
        defer allocator.free(thumb);
        const shown = try testing.decode(allocator, thumb);
        defer allocator.free(shown.pixels);
        const blue = testing.pixelAt(shown, shown.dims.width / 2, shown.dims.height / 2)[2];
        try expectEqual(case.used, blue > 200);
        try expectEqual(@as(u32, if (case.used) case.w else 320), shown.dims.width);
    }

    // A preview that doesn't decode falls back to the picture.
    const broken = try testing.gradientJpeg(allocator, 320, 240, 255);
    defer allocator.free(broken);
    const jpeg = try testing.withExif(allocator, plain, 1, broken[0 .. broken.len / 2]);
    defer allocator.free(jpeg);
    const thumb = try thumbnail(allocator, jpeg, .{});
    defer allocator.free(thumb);
    try expectEqual(Dims{ .width = 320, .height = 240 }, try info(thumb));
}

test "pictures over max_pixels and unknown formats are refused" {
    const allocator = std.testing.allocator;
    const jpeg = try testing.gradientJpeg(allocator, 400, 300, 0);
    defer allocator.free(jpeg);
    try expectError(error.TooLarge, thumbnail(allocator, jpeg, .{ .max_pixels = 400 * 300 - 1 }));
    const exact = try thumbnail(allocator, jpeg, .{ .max_pixels = 400 * 300 });
    allocator.free(exact);

    try expectError(error.UnknownFormat, info(""));
    try expectError(error.UnknownFormat, info("not a picture"));
    try expectError(error.UnknownFormat, thumbnail(allocator, "\x00\x00\x00\x18ftypheic", .{}));
}

test "a decode that needs more than its budget fails cleanly" {
    const allocator = std.testing.allocator;
    const jpeg = try testing.gradientJpeg(allocator, 400, 300, 0);
    defer allocator.free(jpeg);
    const dims = try info(jpeg);
    // 400x300 RGB alone is 360 kB: stb is refused the memory and the
    // decode ends with everything it did get freed (budget.end asserts it).
    for ([_]usize{ 0, 4096, 64 << 10, 300 << 10 }) |limit| {
        try expectError(error.TooLarge, render(allocator, jpeg, dims, 1, .{}, limit));
    }
    const thumb = try render(allocator, jpeg, dims, 1, .{}, decodeBudget(dims));
    allocator.free(thumb);
}

test "the resizer's working memory fits the scratch budget" {
    const allocator = std.testing.allocator;
    const wide: Dims = .{ .width = max_dimension, .height = 64 };
    const pixels = try testing.gradient(allocator, wide.width, wide.height, 0);
    defer allocator.free(pixels);
    const jpeg = try encodeJpeg(allocator, pixels, wide, 50);
    defer allocator.free(jpeg);
    const thumb = try thumbnail(allocator, jpeg, .{});
    defer allocator.free(thumb);
    try expectEqual(Dims{ .width = 320, .height = 1 }, try info(thumb));
}

test "random, truncated and corrupted input never panics" {
    const allocator = std.testing.allocator;
    var prng = std.Random.DefaultPrng.init(0x70686f746f73);
    const random = prng.random();

    const plain = try testing.gradientJpeg(allocator, 96, 64, 10);
    defer allocator.free(plain);
    const preview = try testing.gradientJpeg(allocator, 240, 160, 10);
    defer allocator.free(preview);
    const with_exif = try testing.withExif(allocator, plain, 6, preview);
    defer allocator.free(with_exif);
    const png = try testing.gradientPng(allocator, 96, 64, 10);
    defer allocator.free(png);
    const seeds = [_][]const u8{ plain, with_exif, png };

    var noise: [2048]u8 = undefined;
    for (0..256) |round| {
        const seed = seeds[round % seeds.len];
        const input = try allocator.dupe(u8, seed);
        defer allocator.free(input);
        var bytes: []const u8 = input;
        switch (round % 4) {
            0 => bytes = input[0..random.uintLessThan(usize, input.len)],
            1 => for (0..1 + random.uintLessThan(usize, 8)) |_| {
                input[random.uintLessThan(usize, input.len)] = random.int(u8);
            },
            2 => { // a real header, then noise
                const keep = random.uintLessThan(usize, @min(input.len, 256));
                random.bytes(input[keep..]);
            },
            else => {
                random.bytes(&noise);
                bytes = noise[0..random.uintLessThan(usize, noise.len)];
            },
        }
        _ = info(bytes) catch {};
        _ = exif.orientation(bytes);
        _ = exif.embeddedThumb(bytes);
        if (thumbnail(allocator, bytes, .{ .max_pixels = 1 << 20 })) |thumb| {
            defer allocator.free(thumb);
            const dims = try info(thumb);
            try expect(dims.longEdge() <= 320);
        } else |err| switch (err) {
            error.UnknownFormat, error.TooLarge, error.DecodeFailed => {},
            error.OutOfMemory => return err,
        }
    }
}
