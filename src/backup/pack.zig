//! Pack format for bundling many content blocks into a single S3 object.
//!
//! A pack starts with a 30-byte header followed by independently sealed block
//! records up to a configurable target size (default 32 MiB):
//!
//!   Header (30 bytes):
//!     [4 magic "NBPK"][1 version][1 mode][8 key_id][16 nonce_prefix]
//!
//!   Encrypted block record (`mode = 1`, 76 bytes overhead):
//!     [24 nonce = nonce_prefix || u64_le(block_index)]
//!     [4 u32_le plaintext_len]
//!     [32 + plaintext_len ciphertext of (block_id || plaintext)]
//!     [16 Poly1305 tag over (nonce || plaintext_len) as AD]
//!
//!   Unencrypted block record (`mode = 0`, 72 bytes overhead):
//!     [32 block_id]
//!     [4 u32_le plaintext_len]
//!     [4 u32_le crc32(block_id || plaintext)]
//!     [32 sha256(block_id || plaintext)]
//!     [plaintext_len plaintext]
//!
//! Sealing each block with its own 24-byte nonce lets a single HTTP Range GET
//! (`bytes=offset-(offset+length-1)`) fetch and authenticate one block without
//! downloading the rest of the pack. Encrypting `block_id` inside the AEAD
//! payload guarantees that no plaintext CID ever appears in encrypted packs.

const std = @import("std");
const keys = @import("keys.zig");

const Sha256 = std.crypto.hash.sha2.Sha256;
const Crc32 = std.hash.Crc32;
const XChaCha20Poly1305 = std.crypto.aead.chacha_poly.XChaCha20Poly1305;

pub const pack_magic = "NBPK".*;
pub const pack_version: u8 = 1;
pub const nonce_prefix_len = 16;
pub const header_len = 4 + 1 + 1 + keys.key_id_len + nonce_prefix_len;

/// Default target size for a pack (32 MiB).
pub const default_target_size: usize = 32 * 1024 * 1024;

/// Upper bound on a single block's plaintext size (64 MiB).
pub const max_block_size: usize = 64 * 1024 * 1024;

pub const block_id_len = 32;
pub const BlockId = [block_id_len]u8;

const encrypted_record_header_len = XChaCha20Poly1305.nonce_length + 4;
pub const encrypted_record_overhead = encrypted_record_header_len + block_id_len + XChaCha20Poly1305.tag_length;

const unencrypted_record_header_len = block_id_len + 4 + 4 + Sha256.digest_length;
pub const unencrypted_record_overhead = unencrypted_record_header_len;

pub const Mode = enum(u8) {
    unencrypted = 0,
    encrypted = 1,
};

pub const Error = error{
    InvalidPackMagic,
    UnsupportedPackVersion,
    InvalidPackMode,
    InvalidPackHeader,
    TargetSizeTooSmall,
    BlockTooLarge,
    PackFull,
    OutOfBounds,
    CorruptRecord,
    KeyRequired,
    UnexpectedKey,
    WrongKey,
    AuthenticationFailed,
    ChecksumMismatch,
};

pub const Header = struct {
    version: u8,
    mode: Mode,
    key_id: keys.KeyId,
    nonce_prefix: [nonce_prefix_len]u8,

    pub fn encode(self: Header) [header_len]u8 {
        var out: [header_len]u8 = undefined;
        @memcpy(out[0..4], &pack_magic);
        out[4] = self.version;
        out[5] = @intFromEnum(self.mode);
        @memcpy(out[6 .. 6 + keys.key_id_len], &self.key_id);
        @memcpy(out[6 + keys.key_id_len .. header_len], &self.nonce_prefix);
        return out;
    }

    pub fn decode(bytes: []const u8) Error!Header {
        if (bytes.len < header_len) return Error.InvalidPackHeader;
        if (!std.mem.eql(u8, bytes[0..4], &pack_magic)) return Error.InvalidPackMagic;
        if (bytes[4] != pack_version) return Error.UnsupportedPackVersion;
        const mode: Mode = switch (bytes[5]) {
            0 => .unencrypted,
            1 => .encrypted,
            else => return Error.InvalidPackMode,
        };
        return .{
            .version = bytes[4],
            .mode = mode,
            .key_id = bytes[6 .. 6 + keys.key_id_len].*,
            .nonce_prefix = bytes[6 + keys.key_id_len .. header_len].*,
        };
    }
};

/// Byte range of a single block inside a pack.
pub const BlockSpan = struct {
    block_id: BlockId,
    offset: u64,
    length: u32,
};

/// Decoded block returned by `readBlockWithId` or `decodeRangeChunk`.
pub const DecodedBlock = struct {
    block_id: BlockId,
    data: []u8,

    pub fn deinit(self: *DecodedBlock, allocator: std.mem.Allocator) void {
        allocator.free(self.data);
    }
};

/// Completed pack buffer and its block offsets, owned by the caller.
pub const PackResult = struct {
    bytes: []u8,
    blocks: []BlockSpan,

    pub fn deinit(self: *PackResult, allocator: std.mem.Allocator) void {
        allocator.free(self.bytes);
        allocator.free(self.blocks);
    }
};

pub const WriterOptions = struct {
    /// Encryption key; `null` writes an unencrypted pack with CRC32 + SHA-256
    /// integrity checks.
    key: ?keys.Key = null,
    /// Maximum byte size of the pack (default 32 MiB).
    target_size: usize = default_target_size,
    /// Optional fixed nonce prefix for deterministic tests; generated from OS
    /// CSPRNG when `null`.
    nonce_prefix: ?[nonce_prefix_len]u8 = null,
};

/// Appends blocks into a single pack up to `target_size`.
pub const Writer = struct {
    allocator: std.mem.Allocator,
    key: ?keys.Key,
    target_size: usize,
    header: Header,
    buf: std.ArrayList(u8),
    entries: std.ArrayList(BlockSpan),

    pub fn init(allocator: std.mem.Allocator, options: WriterOptions) !Writer {
        if (options.target_size < header_len) return Error.TargetSizeTooSmall;

        var nonce_prefix = [_]u8{0} ** nonce_prefix_len;
        var key_id = [_]u8{0} ** keys.key_id_len;
        const mode: Mode = if (options.key) |k| blk: {
            key_id = keys.keyId(k);
            if (options.nonce_prefix) |np| {
                nonce_prefix = np;
            } else {
                try std.Io.Threaded.global_single_threaded.io().randomSecure(&nonce_prefix);
            }
            break :blk .encrypted;
        } else .unencrypted;

        const header = Header{
            .version = pack_version,
            .mode = mode,
            .key_id = key_id,
            .nonce_prefix = nonce_prefix,
        };

        var buf: std.ArrayList(u8) = .empty;
        errdefer buf.deinit(allocator);
        const header_bytes = header.encode();
        try buf.appendSlice(allocator, &header_bytes);

        return .{
            .allocator = allocator,
            .key = options.key,
            .target_size = options.target_size,
            .header = header,
            .buf = buf,
            .entries = .empty,
        };
    }

    pub fn deinit(self: *Writer) void {
        if (self.key) |*k| std.crypto.secureZero(u8, k);
        self.buf.deinit(self.allocator);
        self.entries.deinit(self.allocator);
    }

    /// Encoded byte length of a block with `plaintext_len` payload bytes.
    pub fn recordSize(self: *const Writer, plaintext_len: usize) usize {
        const overhead: usize = switch (self.header.mode) {
            .encrypted => encrypted_record_overhead,
            .unencrypted => unencrypted_record_overhead,
        };
        return overhead + plaintext_len;
    }

    /// Returns true if a block of `plaintext_len` bytes fits within `target_size`.
    pub fn wouldFit(self: *const Writer, plaintext_len: usize) bool {
        if (plaintext_len > max_block_size) return false;
        return self.buf.items.len + self.recordSize(plaintext_len) <= self.target_size;
    }

    pub fn currentSize(self: *const Writer) usize {
        return self.buf.items.len;
    }

    pub fn blockCount(self: *const Writer) usize {
        return self.entries.items.len;
    }

    pub fn bytes(self: *const Writer) []const u8 {
        return self.buf.items;
    }

    pub fn spans(self: *const Writer) []const BlockSpan {
        return self.entries.items;
    }

    /// Seals and appends one block to the pack, returning its `(offset, length)`.
    /// Returns `Error.PackFull` if appending the block would exceed `target_size`.
    pub fn append(self: *Writer, block_id: BlockId, plaintext: []const u8) !BlockSpan {
        if (plaintext.len > max_block_size) return Error.BlockTooLarge;
        const rec_len = self.recordSize(plaintext.len);
        if (self.buf.items.len + rec_len > self.target_size) return Error.PackFull;

        const offset: u64 = @intCast(self.buf.items.len);
        const length: u32 = @intCast(rec_len);
        const block_idx: u64 = @intCast(self.entries.items.len);

        try self.buf.ensureUnusedCapacity(self.allocator, rec_len);
        const start = self.buf.items.len;
        self.buf.items.len += rec_len;
        errdefer self.buf.items.len = start;

        const dest = self.buf.items[start .. start + rec_len];
        switch (self.header.mode) {
            .encrypted => try self.writeEncryptedRecord(dest, block_idx, block_id, plaintext),
            .unencrypted => writeUnencryptedRecord(dest, block_id, plaintext),
        }

        const span = BlockSpan{
            .block_id = block_id,
            .offset = offset,
            .length = length,
        };
        try self.entries.append(self.allocator, span);
        return span;
    }

    fn writeEncryptedRecord(
        self: *const Writer,
        dest: []u8,
        block_idx: u64,
        block_id: BlockId,
        plaintext: []const u8,
    ) !void {
        var nonce: [XChaCha20Poly1305.nonce_length]u8 = undefined;
        @memcpy(nonce[0..nonce_prefix_len], &self.header.nonce_prefix);
        std.mem.writeInt(u64, nonce[nonce_prefix_len..24], block_idx, .little);

        @memcpy(dest[0..24], &nonce);
        std.mem.writeInt(u32, dest[24..28], @intCast(plaintext.len), .little);

        const combined_len = block_id_len + plaintext.len;
        const combined = try self.allocator.alloc(u8, combined_len);
        defer {
            std.crypto.secureZero(u8, combined);
            self.allocator.free(combined);
        }
        @memcpy(combined[0..block_id_len], &block_id);
        @memcpy(combined[block_id_len..combined_len], plaintext);

        const ad = dest[0..encrypted_record_header_len];
        const ct_slice = dest[encrypted_record_header_len .. encrypted_record_header_len + combined_len];
        var tag: [XChaCha20Poly1305.tag_length]u8 = undefined;
        XChaCha20Poly1305.encrypt(ct_slice, &tag, combined, ad, nonce, self.key.?);
        @memcpy(dest[encrypted_record_header_len + combined_len ..], &tag);
    }

    fn writeUnencryptedRecord(dest: []u8, block_id: BlockId, plaintext: []const u8) void {
        @memcpy(dest[0..block_id_len], &block_id);
        std.mem.writeInt(u32, dest[32..36], @intCast(plaintext.len), .little);

        var crc = Crc32.init();
        crc.update(&block_id);
        crc.update(plaintext);
        std.mem.writeInt(u32, dest[36..40], crc.final(), .little);

        var sha = Sha256.init(.{});
        sha.update(&block_id);
        sha.update(plaintext);
        var digest: [Sha256.digest_length]u8 = undefined;
        sha.final(&digest);
        @memcpy(dest[40..72], &digest);
        @memcpy(dest[72 .. 72 + plaintext.len], plaintext);
    }

    /// Finalizes the pack and returns caller-owned `bytes` and `blocks` slices.
    pub fn finish(self: *Writer) !PackResult {
        const pack_bytes = try self.buf.toOwnedSlice(self.allocator);
        errdefer self.allocator.free(pack_bytes);
        const block_spans = try self.entries.toOwnedSlice(self.allocator);
        return .{
            .bytes = pack_bytes,
            .blocks = block_spans,
        };
    }
};

/// Reads and authenticates individual blocks from a pack given `(offset, length)`.
pub const Reader = struct {
    pack_bytes: []const u8,
    header: Header,
    key: ?keys.Key,

    pub fn init(pack_bytes: []const u8, key: ?keys.Key) Error!Reader {
        const header = try Header.decode(pack_bytes);
        switch (header.mode) {
            .encrypted => {
                const k = key orelse return Error.KeyRequired;
                if (!std.crypto.timing_safe.eql(keys.KeyId, keys.keyId(k), header.key_id)) {
                    return Error.WrongKey;
                }
            },
            .unencrypted => {
                if (key != null) return Error.UnexpectedKey;
                if (!std.mem.allEqual(u8, &header.key_id, 0) or !std.mem.allEqual(u8, &header.nonce_prefix, 0)) {
                    return Error.InvalidPackHeader;
                }
            },
        }
        return .{
            .pack_bytes = pack_bytes,
            .header = header,
            .key = key,
        };
    }

    /// Decrypts (or verifies in unencrypted mode) the block at `(offset, length)`
    /// and returns caller-owned plaintext bytes.
    pub fn readBlock(self: Reader, allocator: std.mem.Allocator, offset: u64, length: u32) ![]u8 {
        const decoded = try self.readBlockWithId(allocator, offset, length);
        return decoded.data;
    }

    /// Decrypts (or verifies in unencrypted mode) the block at `(offset, length)`
    /// and returns both its `block_id` and caller-owned plaintext bytes.
    pub fn readBlockWithId(self: Reader, allocator: std.mem.Allocator, offset: u64, length: u32) !DecodedBlock {
        if (offset < header_len) return Error.OutOfBounds;
        const start = std.math.cast(usize, offset) orelse return Error.OutOfBounds;
        const len: usize = length;
        const end = std.math.add(usize, start, len) catch return Error.OutOfBounds;
        if (end > self.pack_bytes.len) return Error.OutOfBounds;

        const chunk = self.pack_bytes[start..end];
        if (self.header.mode == .encrypted) {
            if (chunk.len < encrypted_record_overhead) return Error.CorruptRecord;
            if (!std.crypto.timing_safe.eql(
                [nonce_prefix_len]u8,
                chunk[0..nonce_prefix_len].*,
                self.header.nonce_prefix,
            )) {
                return Error.AuthenticationFailed;
            }
        }
        return decodeRangeChunk(allocator, chunk, self.key);
    }
};

/// Convenience helper: validates the pack header and reads a single block at
/// `(offset, length)`.
pub fn readBlock(
    allocator: std.mem.Allocator,
    pack_bytes: []const u8,
    offset: u64,
    length: u32,
    key: ?keys.Key,
) ![]u8 {
    const reader = try Reader.init(pack_bytes, key);
    return reader.readBlock(allocator, offset, length);
}

/// Decodes and authenticates a single block record fetched via an S3 Range GET
/// (`bytes=offset-(offset+length-1)`), without requiring the pack header.
pub fn decodeRangeChunk(
    allocator: std.mem.Allocator,
    chunk: []const u8,
    key: ?keys.Key,
) !DecodedBlock {
    if (key) |k| {
        if (chunk.len < encrypted_record_overhead) return Error.CorruptRecord;
        const nonce = chunk[0..24].*;
        const plaintext_len = std.mem.readInt(u32, chunk[24..28], .little);
        if (plaintext_len > max_block_size) return Error.BlockTooLarge;
        if (chunk.len != encrypted_record_overhead + @as(usize, plaintext_len)) {
            return Error.CorruptRecord;
        }

        const combined_len = block_id_len + @as(usize, plaintext_len);
        const ct = chunk[encrypted_record_header_len .. encrypted_record_header_len + combined_len];
        const tag = chunk[encrypted_record_header_len + combined_len ..][0..XChaCha20Poly1305.tag_length].*;
        const ad = chunk[0..encrypted_record_header_len];

        const combined = try allocator.alloc(u8, combined_len);
        defer {
            std.crypto.secureZero(u8, combined);
            allocator.free(combined);
        }

        XChaCha20Poly1305.decrypt(combined, ct, tag, ad, nonce, k) catch return Error.AuthenticationFailed;

        const block_id = combined[0..block_id_len].*;
        const data = try allocator.dupe(u8, combined[block_id_len..combined_len]);
        return .{
            .block_id = block_id,
            .data = data,
        };
    } else {
        if (chunk.len < unencrypted_record_overhead) return Error.CorruptRecord;
        const block_id = chunk[0..block_id_len].*;
        const plaintext_len = std.mem.readInt(u32, chunk[32..36], .little);
        if (plaintext_len > max_block_size) return Error.BlockTooLarge;
        if (chunk.len != unencrypted_record_overhead + @as(usize, plaintext_len)) {
            return Error.CorruptRecord;
        }

        const expected_crc = std.mem.readInt(u32, chunk[36..40], .little);
        const expected_sha = chunk[40..72].*;
        const payload = chunk[72..];

        var crc = Crc32.init();
        crc.update(&block_id);
        crc.update(payload);
        if (crc.final() != expected_crc) return Error.ChecksumMismatch;

        var sha = Sha256.init(.{});
        sha.update(&block_id);
        sha.update(payload);
        var actual_sha: [Sha256.digest_length]u8 = undefined;
        sha.final(&actual_sha);
        if (!std.crypto.timing_safe.eql([32]u8, actual_sha, expected_sha)) {
            return Error.ChecksumMismatch;
        }

        const data = try allocator.dupe(u8, payload);
        return .{
            .block_id = block_id,
            .data = data,
        };
    }
}

test "pack: encrypted write/read of many blocks including empty and 1 MiB blocks" {
    const allocator = std.testing.allocator;
    var backup_key = try keys.BackupKey.generate();
    defer backup_key.deinit();

    var writer = try Writer.init(allocator, .{ .key = backup_key.bytes });
    defer writer.deinit();

    const empty_data = "";
    const small_data = "NomadFS small block payload";
    const medium_data = "0123456789abcdef" ** 256; // 4 KiB
    const one_mib = try allocator.alloc(u8, 1024 * 1024);
    defer allocator.free(one_mib);
    for (one_mib, 0..) |*b, i| b.* = @truncate(i *% 31 +% 7);

    const payloads = [_][]const u8{
        empty_data,
        small_data,
        medium_data,
        one_mib,
        empty_data,
        "trailing block after 1 MiB",
    };

    var cids: [payloads.len]BlockId = undefined;
    for (payloads, 0..) |p, i| {
        Sha256.hash(p, &cids[i], .{});
        // Even if a caller passes a raw CID as block_id, it is encrypted inside the pack.
        const span = try writer.append(cids[i], p);
        try std.testing.expectEqual(cids[i], span.block_id);
    }

    var result = try writer.finish();
    defer result.deinit(allocator);

    try std.testing.expectEqual(payloads.len, result.blocks.len);

    // Verify no plaintext CID or non-empty payload appears in the encrypted pack.
    for (cids) |cid| {
        try std.testing.expectEqual(@as(?usize, null), std.mem.indexOf(u8, result.bytes, &cid));
    }
    try std.testing.expectEqual(@as(?usize, null), std.mem.indexOf(u8, result.bytes, small_data));
    try std.testing.expectEqual(@as(?usize, null), std.mem.indexOf(u8, result.bytes, medium_data));

    // Read every block via Reader and via standalone Range GET chunk decoding.
    const reader = try Reader.init(result.bytes, backup_key.bytes);
    for (result.blocks, 0..) |span, i| {
        var decoded = try reader.readBlockWithId(allocator, span.offset, span.length);
        defer decoded.deinit(allocator);
        try std.testing.expectEqualSlices(u8, &cids[i], &decoded.block_id);
        try std.testing.expectEqualSlices(u8, payloads[i], decoded.data);

        // Simulate a single S3 Range GET of `result.bytes[offset .. offset + length]`.
        const range_slice = result.bytes[span.offset .. span.offset + span.length];
        var range_decoded = try decodeRangeChunk(allocator, range_slice, backup_key.bytes);
        defer range_decoded.deinit(allocator);
        try std.testing.expectEqualSlices(u8, &cids[i], &range_decoded.block_id);
        try std.testing.expectEqualSlices(u8, payloads[i], range_decoded.data);
    }
}

test "pack: wrong key and tamper detection in encrypted mode" {
    const allocator = std.testing.allocator;
    var key_a = try keys.BackupKey.generate();
    defer key_a.deinit();
    var key_b = try keys.BackupKey.generate();
    defer key_b.deinit();

    var writer = try Writer.init(allocator, .{ .key = key_a.bytes });
    defer writer.deinit();

    const id1 = [_]u8{0x11} ** 32;
    const id2 = [_]u8{0x22} ** 32;
    _ = try writer.append(id1, "first block");
    _ = try writer.append(id2, "second block");

    var result = try writer.finish();
    defer result.deinit(allocator);

    // Wrong key rejected at Reader.init (key_id mismatch) and at decodeRangeChunk (AEAD tag mismatch).
    try std.testing.expectError(Error.WrongKey, Reader.init(result.bytes, key_b.bytes));
    try std.testing.expectError(Error.KeyRequired, Reader.init(result.bytes, null));

    const span0 = result.blocks[0];
    const chunk0 = result.bytes[span0.offset .. span0.offset + span0.length];
    try std.testing.expectError(
        Error.AuthenticationFailed,
        decodeRangeChunk(allocator, chunk0, key_b.bytes),
    );

    // Flipping any byte in a block record causes authentication or record corruption error.
    for (0..chunk0.len) |i| {
        var tampered = try allocator.dupe(u8, result.bytes);
        defer allocator.free(tampered);
        tampered[@as(usize, @intCast(span0.offset)) + i] ^= 0x01;
        try std.testing.expect(
            if (readBlock(allocator, tampered, span0.offset, span0.length, key_a.bytes)) |d| blk: {
                allocator.free(d);
                break :blk false;
            } else |_| true,
        );
    }

    // Flipping a byte in the pack header (magic, version, mode, key_id, nonce_prefix) is detected.
    for (0..header_len) |i| {
        var tampered = try allocator.dupe(u8, result.bytes);
        defer allocator.free(tampered);
        tampered[i] ^= 0x01;
        try std.testing.expect(
            if (readBlock(allocator, tampered, span0.offset, span0.length, key_a.bytes)) |d| blk: {
                allocator.free(d);
                break :blk false;
            } else |_| true,
        );
    }
}

test "pack: unencrypted mode round trip and CRC32/SHA-256 tamper detection" {
    const allocator = std.testing.allocator;

    var writer = try Writer.init(allocator, .{ .key = null });
    defer writer.deinit();

    const id1 = [_]u8{0xaa} ** 32;
    const id2 = [_]u8{0xbb} ** 32;
    _ = try writer.append(id1, "");
    _ = try writer.append(id2, "unencrypted block payload");

    var result = try writer.finish();
    defer result.deinit(allocator);

    const reader = try Reader.init(result.bytes, null);
    const data0 = try reader.readBlock(allocator, result.blocks[0].offset, result.blocks[0].length);
    defer allocator.free(data0);
    try std.testing.expectEqualStrings("", data0);

    const data1 = try reader.readBlock(allocator, result.blocks[1].offset, result.blocks[1].length);
    defer allocator.free(data1);
    try std.testing.expectEqualStrings("unencrypted block payload", data1);

    // Flipping any byte in the unencrypted block record fails CRC/SHA or length validation.
    const span1 = result.blocks[1];
    for (0..span1.length) |i| {
        var tampered = try allocator.dupe(u8, result.bytes);
        defer allocator.free(tampered);
        tampered[@as(usize, @intCast(span1.offset)) + i] ^= 0x04;
        try std.testing.expect(
            if (readBlock(allocator, tampered, span1.offset, span1.length, null)) |d| blk: {
                allocator.free(d);
                break :blk false;
            } else |_| true,
        );
    }
}

test "pack: enforces target_size limit" {
    const allocator = std.testing.allocator;
    var key = try keys.BackupKey.generate();
    defer key.deinit();

    // Target size just large enough for header + 1 block of 16 bytes.
    const max_size = header_len + encrypted_record_overhead + 16;
    var writer = try Writer.init(allocator, .{
        .key = key.bytes,
        .target_size = max_size,
    });
    defer writer.deinit();

    try std.testing.expect(writer.wouldFit(16));
    try std.testing.expect(!writer.wouldFit(17));

    _ = try writer.append([_]u8{1} ** 32, "0123456789abcdef");
    try std.testing.expect(!writer.wouldFit(0));
    try std.testing.expectError(Error.PackFull, writer.append([_]u8{2} ** 32, ""));
}
