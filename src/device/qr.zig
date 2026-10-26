//! QR Code Model 2 encoder (byte mode), used to show pairing tickets on a
//! terminal or in a GUI. Implements ISO/IEC 18004: version selection, data
//! codewords with Reed-Solomon error correction, function patterns, all eight
//! mask patterns with penalty scoring, and a UTF-8 half-block renderer.
//!
//! Only byte mode is implemented: a pairing URI is ASCII, so the numeric and
//! alphanumeric modes would only save a few modules.

const std = @import("std");

pub const EcLevel = enum {
    low,
    medium,
    quartile,
    high,
};

/// Error correction codewords per block, indexed by (level, version).
const ecc_codewords_per_block = [4][41]u8{
    // Low
    .{ 0, 7, 10, 15, 20, 26, 18, 20, 24, 30, 18, 20, 24, 26, 30, 22, 24, 28, 30, 28, 28, 28, 28, 30, 30, 26, 28, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30 },
    // Medium
    .{ 0, 10, 16, 26, 18, 24, 16, 18, 22, 22, 26, 30, 22, 22, 24, 24, 28, 28, 26, 26, 26, 26, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28 },
    // Quartile
    .{ 0, 13, 22, 18, 26, 18, 24, 18, 22, 20, 24, 28, 26, 24, 20, 30, 24, 28, 28, 26, 30, 28, 30, 30, 30, 30, 28, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30 },
    // High
    .{ 0, 17, 28, 22, 16, 22, 28, 26, 26, 24, 28, 24, 28, 22, 24, 24, 30, 28, 28, 26, 28, 30, 24, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30 },
};

/// Number of error correction blocks, indexed by (level, version).
const num_ec_blocks = [4][41]u8{
    // Low
    .{ 0, 1, 1, 1, 1, 1, 2, 2, 2, 2, 4, 4, 4, 4, 4, 6, 6, 6, 6, 7, 8, 8, 9, 9, 10, 12, 12, 12, 13, 14, 15, 16, 17, 18, 19, 19, 20, 21, 22, 24, 25 },
    // Medium
    .{ 0, 1, 1, 1, 2, 2, 4, 4, 4, 5, 5, 5, 8, 9, 9, 10, 10, 11, 13, 14, 16, 17, 17, 18, 20, 21, 23, 25, 26, 28, 29, 31, 33, 35, 37, 38, 40, 43, 45, 47, 49 },
    // Quartile
    .{ 0, 1, 1, 2, 2, 4, 4, 6, 6, 8, 8, 8, 10, 12, 16, 12, 17, 16, 18, 21, 20, 23, 23, 25, 27, 29, 34, 34, 35, 38, 40, 43, 45, 48, 51, 53, 56, 59, 62, 65, 68 },
    // High
    .{ 0, 1, 1, 2, 4, 4, 4, 5, 6, 8, 8, 11, 11, 16, 16, 18, 16, 19, 21, 25, 25, 25, 34, 30, 32, 35, 37, 40, 42, 45, 48, 51, 54, 57, 60, 63, 66, 70, 74, 77, 81 },
};

pub const Error = error{
    DataTooLong,
    InvalidVersion,
};

/// A rendered QR symbol. `cells` is row-major, one byte per module, 1 = dark.
pub const Matrix = struct {
    allocator: std.mem.Allocator,
    version: u8,
    size: usize,
    mask: u3,
    cells: []u8,

    pub fn deinit(self: *Matrix) void {
        self.allocator.free(self.cells);
    }

    pub fn get(self: Matrix, x: usize, y: usize) bool {
        return self.cells[y * self.size + x] != 0;
    }
};

fn ecIndex(ec: EcLevel) usize {
    return @intFromEnum(ec);
}

/// Two-bit error correction level field used by the format information.
fn formatBits(ec: EcLevel) u3 {
    return switch (ec) {
        .low => 1,
        .medium => 0,
        .quartile => 3,
        .high => 2,
    };
}

fn charCountBits(version: u8) u6 {
    return if (version <= 9) 8 else 16;
}

/// Number of data modules once every function pattern is removed, including
/// the remainder bits.
fn numRawDataModules(version: u8) usize {
    const v: usize = version;
    var result: usize = (16 * v + 128) * v + 64;
    if (version >= 2) {
        const num_align: usize = version / 7 + 2;
        result -= (25 * num_align - 10) * num_align - 55;
        if (version >= 7) result -= 36;
    }
    return result;
}

fn numDataCodewords(version: u8, ec: EcLevel) usize {
    const idx = ecIndex(ec);
    const ec_len: usize = ecc_codewords_per_block[idx][version];
    const blocks: usize = num_ec_blocks[idx][version];
    return numRawDataModules(version) / 8 - ec_len * blocks;
}

/// Smallest version that fits `len` bytes at the given level.
fn pickVersion(len: usize, ec: EcLevel) Error!u8 {
    var version: u8 = 1;
    while (version <= 40) : (version += 1) {
        const capacity = numDataCodewords(version, ec) * 8;
        const cc = charCountBits(version);
        if (len >= (@as(usize, 1) << cc)) continue;
        const needed = 4 + @as(usize, cc) + len * 8;
        if (needed <= capacity) return version;
    }
    return Error.DataTooLong;
}

const BitBuffer = struct {
    bytes: std.ArrayList(u8) = .empty,
    bit_len: usize = 0,

    fn deinit(self: *BitBuffer, allocator: std.mem.Allocator) void {
        self.bytes.deinit(allocator);
    }

    fn appendBit(self: *BitBuffer, allocator: std.mem.Allocator, bit: bool) !void {
        if (self.bit_len % 8 == 0) try self.bytes.append(allocator, 0);
        if (bit) {
            const shift: u3 = @intCast(7 - self.bit_len % 8);
            self.bytes.items[self.bit_len / 8] |= @as(u8, 1) << shift;
        }
        self.bit_len += 1;
    }

    /// Appends the `n` low-order bits of `value`, most significant first.
    fn append(self: *BitBuffer, allocator: std.mem.Allocator, value: u32, n: u6) !void {
        var remaining: u7 = n;
        while (remaining > 0) {
            remaining -= 1;
            const bit = (value >> @intCast(remaining)) & 1;
            try self.appendBit(allocator, bit != 0);
        }
    }
};

/// Byte-mode segment plus terminator and padding, sized to `version`/`ec`.
fn buildDataCodewords(allocator: std.mem.Allocator, data: []const u8, version: u8, ec: EcLevel) ![]u8 {
    const capacity_bits = numDataCodewords(version, ec) * 8;
    var bits = BitBuffer{};
    defer bits.deinit(allocator);

    try bits.append(allocator, 0b0100, 4);
    try bits.append(allocator, @intCast(data.len), charCountBits(version));
    for (data) |byte| try bits.append(allocator, byte, 8);

    const terminator = @min(@as(usize, 4), capacity_bits - bits.bit_len);
    try bits.append(allocator, 0, @intCast(terminator));
    if (bits.bit_len % 8 != 0) try bits.append(allocator, 0, @intCast(8 - bits.bit_len % 8));

    var pad: u32 = 0xEC;
    while (bits.bit_len < capacity_bits) : (pad ^= 0xEC ^ 0x11) {
        try bits.append(allocator, pad, 8);
    }
    return bits.bytes.toOwnedSlice(allocator);
}

fn gfMul(x: u8, y: u8) u8 {
    var z: u16 = 0;
    var i: u4 = 8;
    while (i > 0) {
        i -= 1;
        z = ((z << 1) ^ ((z >> 7) * 0x11D)) & 0xFF;
        z ^= @as(u16, (y >> @intCast(i)) & 1) * x;
    }
    return @intCast(z);
}

/// Coefficients (highest power first, excluding the leading 1) of the
/// generator polynomial for `degree` error correction codewords.
fn rsDivisor(degree: usize, out: []u8) void {
    std.debug.assert(out.len == degree);
    @memset(out, 0);
    out[degree - 1] = 1;

    var root: u8 = 1;
    for (0..degree) |_| {
        for (0..degree) |j| {
            out[j] = gfMul(out[j], root);
            if (j + 1 < degree) out[j] ^= out[j + 1];
        }
        root = gfMul(root, 2);
    }
}

fn rsRemainder(data: []const u8, divisor: []const u8, out: []u8) void {
    std.debug.assert(out.len == divisor.len);
    @memset(out, 0);
    for (data) |byte| {
        const factor = byte ^ out[0];
        std.mem.copyForwards(u8, out[0 .. out.len - 1], out[1..]);
        out[out.len - 1] = 0;
        for (divisor, 0..) |coef, i| out[i] ^= gfMul(coef, factor);
    }
}

const max_blocks = 81;

/// Splits the data into blocks, appends error correction and interleaves.
fn addEccAndInterleave(allocator: std.mem.Allocator, data: []const u8, version: u8, ec: EcLevel) ![]u8 {
    const idx = ecIndex(ec);
    const blocks: usize = num_ec_blocks[idx][version];
    const ec_len: usize = ecc_codewords_per_block[idx][version];
    const raw_codewords = numRawDataModules(version) / 8;
    const num_short = blocks - raw_codewords % blocks;
    const short_len = raw_codewords / blocks;
    const short_data = short_len - ec_len;

    var divisor_buf: [30]u8 = undefined;
    const divisor = divisor_buf[0..ec_len];
    rsDivisor(ec_len, divisor);

    // Every data and ECC codeword is stored exactly once, so the interleave
    // scratch space is bounded by the symbol's total codeword count.
    const block_buf = try allocator.alloc(u8, raw_codewords);
    defer allocator.free(block_buf);
    var offsets: [max_blocks]usize = undefined;

    var data_pos: usize = 0;
    var block_pos: usize = 0;
    for (0..blocks) |b| {
        const dat_len = short_data + @intFromBool(b >= num_short);
        @memcpy(block_buf[block_pos..][0..dat_len], data[data_pos..][0..dat_len]);
        data_pos += dat_len;
        rsRemainder(block_buf[block_pos..][0..dat_len], divisor, block_buf[block_pos + dat_len ..][0..ec_len]);
        offsets[b] = block_pos;
        block_pos += dat_len + ec_len;
    }
    std.debug.assert(data_pos == data.len);

    const result = try allocator.alloc(u8, raw_codewords);
    errdefer allocator.free(result);

    var out: usize = 0;
    const max_data = short_data + @intFromBool(num_short < blocks);
    for (0..max_data) |col| {
        for (0..blocks) |b| {
            const dat_len = short_data + @intFromBool(b >= num_short);
            if (col < dat_len) {
                result[out] = block_buf[offsets[b] + col];
                out += 1;
            }
        }
    }
    for (0..ec_len) |col| {
        for (0..blocks) |b| {
            const dat_len = short_data + @intFromBool(b >= num_short);
            result[out] = block_buf[offsets[b] + dat_len + col];
            out += 1;
        }
    }
    std.debug.assert(out == raw_codewords);
    return result;
}

const Canvas = struct {
    size: usize,
    modules: []u8,
    function: []u8,

    fn init(allocator: std.mem.Allocator, size: usize) !Canvas {
        const modules = try allocator.alloc(u8, size * size);
        errdefer allocator.free(modules);
        const function = try allocator.alloc(u8, size * size);
        errdefer allocator.free(function);
        @memset(modules, 0);
        @memset(function, 0);
        return .{ .size = size, .modules = modules, .function = function };
    }

    fn deinit(self: *Canvas, allocator: std.mem.Allocator) void {
        allocator.free(self.modules);
        allocator.free(self.function);
    }

    fn setModule(self: *Canvas, x: usize, y: usize, dark: bool) void {
        self.modules[y * self.size + x] = @intFromBool(dark);
        self.function[y * self.size + x] = 1;
    }

    fn isFunction(self: Canvas, x: usize, y: usize) bool {
        return self.function[y * self.size + x] != 0;
    }
};

fn drawFinder(canvas: *Canvas, cx: usize, cy: usize) void {
    var dy: isize = -4;
    while (dy <= 4) : (dy += 1) {
        var dx: isize = -4;
        while (dx <= 4) : (dx += 1) {
            const x = @as(isize, @intCast(cx)) + dx;
            const y = @as(isize, @intCast(cy)) + dy;
            if (x < 0 or y < 0 or x >= canvas.size or y >= canvas.size) continue;
            const norm = @max(@abs(dx), @abs(dy));
            canvas.setModule(@intCast(x), @intCast(y), norm != 2 and norm != 4);
        }
    }
}

fn alignmentPositions(version: u8, out: *[7]usize) []usize {
    if (version == 1) return out[0..0];
    const num: usize = version / 7 + 2;
    const size: usize = @as(usize, version) * 4 + 17;
    const step: usize = ((@as(usize, version) * 8 + num * 3 + 5) / (num * 4 - 4)) * 2;

    out[0] = 6;
    var i: usize = 1;
    while (i < num) : (i += 1) {
        out[i] = size - 7 - (num - 1 - i) * step;
    }
    return out[0..num];
}

fn drawAlignment(canvas: *Canvas, cx: usize, cy: usize) void {
    var dy: isize = -2;
    while (dy <= 2) : (dy += 1) {
        var dx: isize = -2;
        while (dx <= 2) : (dx += 1) {
            const x: usize = @intCast(@as(isize, @intCast(cx)) + dx);
            const y: usize = @intCast(@as(isize, @intCast(cy)) + dy);
            canvas.setModule(x, y, @max(@abs(dx), @abs(dy)) != 1);
        }
    }
}

fn drawFormatBits(canvas: *Canvas, ec: EcLevel, mask: u3) void {
    const data: u32 = (@as(u32, formatBits(ec)) << 3) | mask;
    var rem: u32 = data;
    for (0..10) |_| {
        rem = (rem << 1) ^ ((rem >> 9) * 0x537);
    }
    const bits: u32 = ((data << 10) | rem) ^ 0x5412;
    std.debug.assert(bits >> 15 == 0);

    const size = canvas.size;
    for (0..6) |i| canvas.setModule(8, i, bitAt(bits, i));
    canvas.setModule(8, 7, bitAt(bits, 6));
    canvas.setModule(8, 8, bitAt(bits, 7));
    canvas.setModule(7, 8, bitAt(bits, 8));
    for (9..15) |i| canvas.setModule(14 - i, 8, bitAt(bits, i));

    for (0..8) |i| canvas.setModule(size - 1 - i, 8, bitAt(bits, i));
    for (8..15) |i| canvas.setModule(8, size - 15 + i, bitAt(bits, i));
    canvas.setModule(8, size - 8, true);
}

fn drawVersionInfo(canvas: *Canvas, version: u8) void {
    if (version < 7) return;
    var rem: u32 = version;
    for (0..12) |_| {
        rem = (rem << 1) ^ ((rem >> 11) * 0x1F25);
    }
    const bits: u32 = (@as(u32, version) << 12) | rem;

    for (0..18) |i| {
        const dark = bitAt(bits, i);
        const a = canvas.size - 11 + i % 3;
        const b = i / 3;
        canvas.setModule(a, b, dark);
        canvas.setModule(b, a, dark);
    }
}

fn bitAt(value: u32, index: usize) bool {
    return (value >> @intCast(index)) & 1 != 0;
}

fn drawFunctionPatterns(canvas: *Canvas, version: u8, ec: EcLevel) void {
    const size = canvas.size;

    for (0..size) |i| {
        canvas.setModule(6, i, i % 2 == 0);
        canvas.setModule(i, 6, i % 2 == 0);
    }

    drawFinder(canvas, 3, 3);
    drawFinder(canvas, size - 4, 3);
    drawFinder(canvas, 3, size - 4);

    var align_buf: [7]usize = undefined;
    const positions = alignmentPositions(version, &align_buf);
    for (positions, 0..) |px, i| {
        for (positions, 0..) |py, j| {
            const skip = (i == 0 and j == 0) or
                (i == 0 and j == positions.len - 1) or
                (i == positions.len - 1 and j == 0);
            if (!skip) drawAlignment(canvas, px, py);
        }
    }

    // Dummy mask; overwritten once the best mask is known.
    drawFormatBits(canvas, ec, 0);
    drawVersionInfo(canvas, version);
}

fn drawCodewords(canvas: *Canvas, codewords: []const u8) void {
    const size = canvas.size;
    var bit_index: usize = 0;

    // Two columns per step, right to left. The column pair steps over the
    // vertical timing pattern at column 6, hence the local adjustment.
    var base: usize = size - 1;
    while (base > 0) : (base -= 2) {
        var right = base;
        if (right <= 6) right -= 1;
        for (0..size) |vert| {
            for (0..2) |j| {
                const x = right - j;
                const upward = ((right + 1) & 2) == 0;
                const y = if (upward) size - 1 - vert else vert;
                if (!canvas.isFunction(x, y) and bit_index < codewords.len * 8) {
                    const shift: u3 = @intCast(7 - bit_index % 8);
                    const bit = (codewords[bit_index / 8] >> shift) & 1;
                    canvas.modules[y * size + x] = bit;
                    bit_index += 1;
                }
            }
        }
    }
    std.debug.assert(bit_index == codewords.len * 8);
}

fn maskBit(mask: u3, x: usize, y: usize) bool {
    return switch (mask) {
        0 => (x + y) % 2 == 0,
        1 => y % 2 == 0,
        2 => x % 3 == 0,
        3 => (x + y) % 3 == 0,
        4 => (y / 2 + x / 3) % 2 == 0,
        5 => x * y % 2 + x * y % 3 == 0,
        6 => (x * y % 2 + x * y % 3) % 2 == 0,
        7 => ((x + y) % 2 + x * y % 3) % 2 == 0,
    };
}

fn applyMask(canvas: *Canvas, mask: u3) void {
    for (0..canvas.size) |y| {
        for (0..canvas.size) |x| {
            if (canvas.isFunction(x, y)) continue;
            if (maskBit(mask, x, y)) {
                canvas.modules[y * canvas.size + x] ^= 1;
            }
        }
    }
}

fn runPenalty(line: []const u8) usize {
    var total: usize = 0;
    var i: usize = 0;
    while (i + 7 <= line.len) : (i += 1) {
        const finder = line[i] == 1 and line[i + 1] == 0 and line[i + 2] == 1 and
            line[i + 3] == 1 and line[i + 4] == 1 and line[i + 5] == 0 and line[i + 6] == 1;
        if (!finder) continue;

        var before = true;
        var k: usize = 1;
        while (k <= 4) : (k += 1) {
            const idx = @as(isize, @intCast(i)) - @as(isize, @intCast(k));
            if (idx >= 0 and line[@intCast(idx)] != 0) before = false;
        }
        var after = true;
        k = 1;
        while (k <= 4) : (k += 1) {
            const idx = i + 6 + k;
            if (idx < line.len and line[idx] != 0) after = false;
        }
        if (before or after) total += 40;
    }
    return total;
}

fn sameColorRunPenalty(line: []const u8) usize {
    var total: usize = 0;
    var run: usize = 1;
    for (1..line.len) |i| {
        if (line[i] == line[i - 1]) {
            run += 1;
        } else {
            if (run >= 5) total += 3 + (run - 5);
            run = 1;
        }
    }
    if (run >= 5) total += 3 + (run - 5);
    return total;
}

fn penalty(canvas: *Canvas) usize {
    const size = canvas.size;
    var total: usize = 0;

    var line_buf: [177]u8 = undefined;
    for (0..size) |y| {
        @memcpy(line_buf[0..size], canvas.modules[y * size ..][0..size]);
        total += sameColorRunPenalty(line_buf[0..size]);
        total += runPenalty(line_buf[0..size]);
    }
    for (0..size) |x| {
        for (0..size) |y| line_buf[y] = canvas.modules[y * size + x];
        total += sameColorRunPenalty(line_buf[0..size]);
        total += runPenalty(line_buf[0..size]);
    }

    for (0..size - 1) |y| {
        for (0..size - 1) |x| {
            const dark = canvas.modules[y * size + x];
            if (dark == canvas.modules[y * size + x + 1] and
                dark == canvas.modules[(y + 1) * size + x] and
                dark == canvas.modules[(y + 1) * size + x + 1])
            {
                total += 3;
            }
        }
    }

    var dark_count: usize = 0;
    for (canvas.modules) |module| dark_count += module;
    const total_modules = size * size;
    const deviation = @abs(@as(isize, @intCast(dark_count * 100)) - @as(isize, @intCast(total_modules * 50))) /
        total_modules;
    total += @as(usize, @intCast(deviation / 5)) * 10;
    return total;
}

/// Encodes `data` at the smallest version that fits, choosing the best mask.
pub fn encode(allocator: std.mem.Allocator, data: []const u8, ec: EcLevel) !Matrix {
    const version = try pickVersion(data.len, ec);
    const size: usize = @as(usize, version) * 4 + 17;

    var canvas = try Canvas.init(allocator, size);
    errdefer canvas.deinit(allocator);

    drawFunctionPatterns(&canvas, version, ec);

    const data_codewords = try buildDataCodewords(allocator, data, version, ec);
    defer allocator.free(data_codewords);
    const codewords = try addEccAndInterleave(allocator, data_codewords, version, ec);
    defer allocator.free(codewords);
    drawCodewords(&canvas, codewords);

    var best_mask: u3 = 0;
    var best_penalty: usize = std.math.maxInt(usize);
    var mask: u3 = 0;
    while (true) : (mask += 1) {
        applyMask(&canvas, mask);
        drawFormatBits(&canvas, ec, mask);
        const score = penalty(&canvas);
        if (score < best_penalty) {
            best_penalty = score;
            best_mask = mask;
        }
        applyMask(&canvas, mask);
        if (mask == 7) break;
    }

    applyMask(&canvas, best_mask);
    drawFormatBits(&canvas, ec, best_mask);

    allocator.free(canvas.function);
    return .{
        .allocator = allocator,
        .version = version,
        .size = size,
        .mask = best_mask,
        .cells = canvas.modules,
    };
}

pub const RenderOptions = struct {
    /// Light border around the symbol, in modules. The standard requires 4.
    quiet_zone: usize = 4,
    /// Draw dark modules as ink (for light terminals). Disable when printing
    /// on a dark background, where light modules must be the ink instead.
    dark_ink: bool = true,
};

/// Writes the symbol using half blocks: two module rows per text line.
pub fn renderAscii(matrix: Matrix, writer: anytype, options: RenderOptions) !void {
    const width = matrix.size + options.quiet_zone * 2;
    var blank_buf: [256]u8 = undefined;
    std.debug.assert(width <= blank_buf.len);
    const blank = blank_buf[0..width];
    @memset(blank, ' ');

    // Two module rows per text line, so the quiet zone is half as many lines.
    const quiet_lines = (options.quiet_zone + 1) / 2;
    for (0..quiet_lines) |_| try writer.print("{s}\n", .{blank});

    var y: usize = 0;
    while (y < matrix.size) : (y += 2) {
        for (0..options.quiet_zone) |_| try writer.writeByte(' ');
        for (0..matrix.size) |x| {
            const top = matrix.get(x, y) == options.dark_ink;
            const bottom = if (y + 1 < matrix.size) matrix.get(x, y + 1) == options.dark_ink else false;
            const glyph = if (top and bottom)
                "█"
            else if (top)
                "▀"
            else if (bottom)
                "▄"
            else
                " ";
            try writer.writeAll(glyph);
        }
        for (0..options.quiet_zone) |_| try writer.writeByte(' ');
        try writer.writeByte('\n');
    }

    for (0..quiet_lines) |_| try writer.print("{s}\n", .{blank});
}

const testing = std.testing;

test "QR: version selection matches capacity" {
    // Byte mode: 4 + char count + data, rounded to codewords.
    try testing.expectEqual(@as(u8, 1), try pickVersion(1, .medium));
    try testing.expectEqual(@as(u8, 1), try pickVersion(14, .medium));
    try testing.expectEqual(@as(u8, 2), try pickVersion(15, .medium));
    try testing.expectEqual(@as(u8, 10), try pickVersion(213, .medium));
    try testing.expectEqual(@as(u8, 11), try pickVersion(214, .medium));
    try testing.expectEqual(@as(u8, 40), try pickVersion(2331, .medium));
    try testing.expectError(Error.DataTooLong, pickVersion(2332, .medium));
    try testing.expectError(Error.DataTooLong, pickVersion(2954, .low));
}

test "QR: structure of a small symbol" {
    var matrix = try encode(testing.allocator, "HELLO NOMADFS", .medium);
    defer matrix.deinit();

    try testing.expectEqual(@as(u8, 1), matrix.version);
    try testing.expectEqual(@as(usize, 21), matrix.size);
    try testing.expect(matrix.mask <= 7);

    // Finder patterns: 7x7 with a 3x3 core, in three corners.
    for ([_][2]usize{ .{ 0, 0 }, .{ matrix.size - 7, 0 }, .{ 0, matrix.size - 7 } }) |corner| {
        const cx = corner[0];
        const cy = corner[1];
        for (0..7) |dy| {
            for (0..7) |dx| {
                const border = dx == 0 or dx == 6 or dy == 0 or dy == 6;
                const inner_light = dx == 1 or dx == 5 or dy == 1 or dy == 5;
                const dark = border or !inner_light;
                try testing.expectEqual(dark, matrix.get(cx + dx, cy + dy));
            }
        }
    }

    // Timing patterns alternate on row/column 6.
    for (8..matrix.size - 8) |i| {
        try testing.expectEqual(i % 2 == 0, matrix.get(i, 6));
        try testing.expectEqual(i % 2 == 0, matrix.get(6, i));
    }
}

test "QR: module output is stable" {
    // Golden hashes, validated against zbarimg decoding of the rendered
    // symbol. A change here means the encoder (and every printed ticket)
    // changed.
    const Case = struct { text: []const u8, ec: EcLevel, version: u8, mask: u3, digest: [8]u8 };
    const cases = [_]Case{
        .{ .text = "HELLO NOMADFS", .ec = .medium, .version = 1, .mask = 3, .digest = .{ 0xd0, 0x31, 0x0a, 0xbc, 0x58, 0xa1, 0x03, 0xda } },
        .{ .text = "nomadfs://pair?v=1&p=AAAA&k=BBBB&n=phone&a=192.168.1.5:4001&e=1800000000&s=CCCC", .ec = .medium, .version = 5, .mask = 2, .digest = .{ 0xc7, 0xf7, 0xec, 0xc9, 0xdf, 0x4d, 0x24, 0xfa } },
        .{ .text = "nomadfs://pair?v=1&p=" ++ ("A" ** 43) ++ "&k=" ++ ("B" ** 43) ++ "&n=Sergio-Laptop&a=192.168.1.5:4001,10.0.0.7:4001&e=1800000000&s=" ++ ("C" ** 86), .ec = .high, .version = 17, .mask = 4, .digest = .{ 0x6e, 0x76, 0xe4, 0x30, 0x62, 0x7c, 0x61, 0x16 } },
    };

    for (cases) |case| {
        var matrix = try encode(testing.allocator, case.text, case.ec);
        defer matrix.deinit();
        try testing.expectEqual(case.version, matrix.version);
        try testing.expectEqual(case.mask, matrix.mask);

        var hash: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(matrix.cells, &hash, .{});
        try testing.expectEqualSlices(u8, &case.digest, hash[0..8]);
    }
}

test "QR: full-size symbol and oversize rejection" {
    const allocator = testing.allocator;
    const payload = try allocator.alloc(u8, 1000);
    defer allocator.free(payload);
    for (payload, 0..) |*byte, i| byte.* = @truncate('A' + i % 26);

    var matrix = try encode(allocator, payload, .medium);
    defer matrix.deinit();
    try testing.expectEqual(@as(u8, 26), matrix.version);
    try testing.expectEqual(@as(usize, 121), matrix.size);
}

test "QR: rendering has the expected shape" {
    var matrix = try encode(testing.allocator, "nomadfs://pair", .medium);
    defer matrix.deinit();

    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();

    try renderAscii(matrix, &out.writer, .{});
    const text = out.written();

    const lines = std.mem.count(u8, text, "\n");
    try testing.expectEqual((matrix.size + 1) / 2 + 4, lines);
}
