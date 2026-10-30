//! FastCDC (Xia et al., USENIX ATC 2016) content-defined chunking.
//!
//! Replaces fixed-size chunking so byte insertions and deletions only affect
//! local chunk boundaries, preserving downstream chunk CIDs across edits.

const std = @import("std");

/// Chunk size configuration.
pub const Params = struct {
    min_size: usize = 64 * 1024,
    avg_size: usize = 256 * 1024,
    max_size: usize = 1024 * 1024,

    /// Ensures parameters form a valid normalized FastCDC window. Averages
    /// below 16 bytes cannot express the two masks and are rejected.
    pub fn validate(self: Params) void {
        std.debug.assert(self.min_size < self.avg_size);
        std.debug.assert(self.avg_size < self.max_size);
        std.debug.assert(std.math.isPowerOfTwo(self.avg_size));
        std.debug.assert(self.avg_size >= 16);
    }
};

/// 4-line SplitMix64 generator used to initialize the gear table at comptime.
fn splitMix64(state: *u64) u64 {
    state.* +%= 0x9e3779b97f4a7c15;
    var z: u64 = (state.* ^ (state.* >> 30)) *% 0xbf58476d1ce4e5b9;
    z = (z ^ (z >> 27)) *% 0x94d049bb133111eb;
    return z ^ (z >> 31);
}

// The gear table and seed are part of the on-disk format — changing them changes every CID.
const gear: [256]u64 = blk: {
    @setEvalBranchQuota(10_000);
    var table: [256]u64 = undefined;
    var state: u64 = 0x123456789abcdef0;
    for (&table) |*entry| {
        entry.* = splitMix64(&state);
    }
    break :blk table;
};

/// Returns the length of the first FastCDC chunk in `data`.
pub fn cut(params: Params, data: []const u8) usize {
    params.validate();
    if (data.len <= params.min_size) return data.len;

    const n = @min(data.len, params.max_size);
    const normal = @min(params.avg_size, n);
    const bits: usize = std.math.log2(params.avg_size);
    const mask_s: u64 = ~@as(u64, 0) << @as(u6, @intCast(64 - (bits + 2)));
    const mask_l: u64 = ~@as(u64, 0) << @as(u6, @intCast(64 - (bits - 2)));

    var hash: u64 = 0;
    var i: usize = params.min_size;
    while (i < normal) : (i += 1) {
        hash = (hash << 1) +% gear[data[i]];
        if (hash & mask_s == 0) return i + 1;
    }
    while (i < n) : (i += 1) {
        hash = (hash << 1) +% gear[data[i]];
        if (hash & mask_l == 0) return i + 1;
    }
    return n;
}

/// Streaming content-defined chunker over any reader with `read([]u8) !usize`.
pub const Chunker = struct {
    allocator: std.mem.Allocator,
    params: Params,
    buffer: []u8,
    start: usize = 0,
    end: usize = 0,
    eof: bool = false,
    /// False when the buffer was lent by the caller (initBuffer).
    owns_buffer: bool = true,

    pub fn init(allocator: std.mem.Allocator, params: Params) !Chunker {
        params.validate();
        const buffer = try allocator.alloc(u8, params.max_size);
        return .{
            .allocator = allocator,
            .params = params,
            .buffer = buffer,
            .start = 0,
            .end = 0,
            .eof = false,
        };
    }

    /// A chunker over `buffer` (at least `params.max_size` bytes), which
    /// stays the caller's: callers chunking many files reuse one buffer.
    pub fn initBuffer(allocator: std.mem.Allocator, params: Params, buffer: []u8) Chunker {
        params.validate();
        std.debug.assert(buffer.len >= params.max_size);
        return .{
            .allocator = allocator,
            .params = params,
            .buffer = buffer[0..params.max_size],
            .owns_buffer = false,
        };
    }

    pub fn deinit(self: *Chunker) void {
        if (self.owns_buffer) self.allocator.free(self.buffer);
    }

    /// Returns the next chunk as a slice into the internal buffer,
    /// valid until the next call to `next`, or null at EOF.
    pub fn next(self: *Chunker, reader: anytype) !?[]const u8 {
        // Compact unconsumed bytes to the front before refilling.
        if (self.start > 0) {
            const remaining = self.end - self.start;
            if (remaining > 0) {
                std.mem.copyForwards(u8, self.buffer[0..remaining], self.buffer[self.start..self.end]);
            }
            self.start = 0;
            self.end = remaining;
        }

        // Fill the buffer until full or EOF is reached.
        while (!self.eof and self.end < self.buffer.len) {
            const bytes_read = try reader.read(self.buffer[self.end..]);
            if (bytes_read == 0) {
                self.eof = true;
                break;
            }
            self.end += bytes_read;
        }

        if (self.end == 0) return null;

        const chunk_len = cut(self.params, self.buffer[0..self.end]);
        const chunk = self.buffer[0..chunk_len];
        self.start = chunk_len;
        return chunk;
    }
};

/// Reads from a byte slice; the reader the chunker takes for data already
/// in memory.
pub const SliceReader = struct {
    buffer: []const u8,
    pos: usize = 0,

    pub fn read(self: *@This(), dest: []u8) !usize {
        if (self.pos >= self.buffer.len) return 0;
        const n = @min(dest.len, self.buffer.len - self.pos);
        @memcpy(dest[0..n], self.buffer[self.pos .. self.pos + n]);
        self.pos += n;
        return n;
    }
};

const VariableReader = struct {
    buffer: []const u8,
    pos: usize = 0,
    step: usize = 0,

    pub fn read(self: *@This(), dest: []u8) !usize {
        if (self.pos >= self.buffer.len) return 0;
        const max_chunk = 1 + (self.step % 7);
        self.step += 1;
        const n = @min(@min(dest.len, max_chunk), self.buffer.len - self.pos);
        @memcpy(dest[0..n], self.buffer[self.pos .. self.pos + n]);
        self.pos += n;
        return n;
    }
};

test "Chunker handles empty input and input smaller than min_size" {
    const testing = std.testing;
    const allocator = testing.allocator;
    const params = Params{};

    // Empty input: no chunks produced.
    {
        var chk = try Chunker.init(allocator, params);
        defer chk.deinit();
        var reader = SliceReader{ .buffer = "" };
        const chunk = try chk.next(&reader);
        try testing.expect(chunk == null);
    }

    // Input smaller than min_size: exactly one chunk produced.
    {
        var chk = try Chunker.init(allocator, params);
        defer chk.deinit();
        const small_data = "hello world smaller than min_size";
        var reader = SliceReader{ .buffer = small_data };
        const chunk = try chk.next(&reader);
        try testing.expect(chunk != null);
        try testing.expectEqualStrings(small_data, chunk.?);
        try testing.expect((try chk.next(&reader)) == null);
    }
}

test "Chunker produces valid chunks and reconstructs original data" {
    const testing = std.testing;
    const allocator = testing.allocator;
    const params = Params{};

    const data_len = 2 * 1024 * 1024 + 54321;
    const data = try allocator.alloc(u8, data_len);
    defer allocator.free(data);

    var prng = std.Random.DefaultPrng.init(0xfeedface);
    prng.random().bytes(data);

    var chk = try Chunker.init(allocator, params);
    defer chk.deinit();

    var reader = SliceReader{ .buffer = data };
    var reconstructed: std.ArrayList(u8) = .empty;
    defer reconstructed.deinit(allocator);

    var chunk_count: usize = 0;
    var last_chunk_len: usize = 0;
    while (try chk.next(&reader)) |chunk| {
        chunk_count += 1;
        last_chunk_len = chunk.len;
        try reconstructed.appendSlice(allocator, chunk);
        try testing.expect(chunk.len <= params.max_size);
    }

    try testing.expect(chunk_count > 1);
    try testing.expectEqual(data.len, reconstructed.items.len);
    try testing.expectEqualSlices(u8, data, reconstructed.items);

    // Verify non-last chunk size bounds
    var chk2 = try Chunker.init(allocator, params);
    defer chk2.deinit();
    var reader2 = SliceReader{ .buffer = data };
    var idx: usize = 0;
    while (try chk2.next(&reader2)) |chunk| {
        idx += 1;
        if (idx < chunk_count) {
            try testing.expect(chunk.len >= params.min_size);
            try testing.expect(chunk.len <= params.max_size);
        }
    }
}

test "Chunker determinism across different read chunk sizes" {
    const testing = std.testing;
    const allocator = testing.allocator;
    const params = Params{};

    const data_len = 2 * 1024 * 1024 + 12345;
    const data = try allocator.alloc(u8, data_len);
    defer allocator.free(data);

    var prng = std.Random.DefaultPrng.init(0xdeadbeef);
    prng.random().bytes(data);

    var chk_bulk = try Chunker.init(allocator, params);
    defer chk_bulk.deinit();
    var bulk_reader = SliceReader{ .buffer = data };

    var bulk_chunks: std.ArrayList(usize) = .empty;
    defer bulk_chunks.deinit(allocator);
    while (try chk_bulk.next(&bulk_reader)) |chunk| {
        try bulk_chunks.append(allocator, chunk.len);
    }

    var chk_var = try Chunker.init(allocator, params);
    defer chk_var.deinit();
    var var_reader = VariableReader{ .buffer = data };

    var var_chunks: std.ArrayList(usize) = .empty;
    defer var_chunks.deinit(allocator);
    while (try chk_var.next(&var_reader)) |chunk| {
        try var_chunks.append(allocator, chunk.len);
    }

    try testing.expectEqual(bulk_chunks.items.len, var_chunks.items.len);
    for (bulk_chunks.items, var_chunks.items) |b_len, v_len| {
        try testing.expectEqual(b_len, v_len);
    }
}
