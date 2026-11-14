//! Encrypted, append-only index segments mapping keyed block IDs to pack locations.
//!
//! Each block's content identifier (CID) is mapped to a 32-byte keyed block ID
//! using `HMAC-SHA256(backup_key, cid)`, so the storage provider cannot test
//! whether the bucket holds a known plaintext CID.
//!
//!   Entry wire layout (60 bytes):
//!     [32 block_id][16 pack_id][8 u64_le offset][4 u32_le length]
//!
//!   Segment header (18 bytes):
//!     [4 magic "NBIX"][1 version][1 mode][8 key_id][4 u32_le entry_count]
//!
//!   Encrypted segment body (`mode = 1`):
//!     [24 nonce][entry_count * 60 ciphertext][16 Poly1305 tag over (header || nonce)]
//!
//!   Unencrypted segment body (`mode = 0`):
//!     [4 u32_le crc32][32 sha256][entry_count * 60 entries]

const std = @import("std");
const keys = @import("keys.zig");
const pack = @import("pack.zig");

const HmacSha256 = std.crypto.auth.hmac.sha2.HmacSha256;
const Sha256 = std.crypto.hash.sha2.Sha256;
const Crc32 = std.hash.Crc32;
const XChaCha20Poly1305 = std.crypto.aead.chacha_poly.XChaCha20Poly1305;

pub const cid_len = 32;
pub const block_id_len = 32;
pub const pack_id_len = 16;

pub const Cid = [cid_len]u8;
pub const BlockId = [block_id_len]u8;
pub const PackId = [pack_id_len]u8;

pub const segment_magic = "NBIX".*;
pub const segment_version: u8 = 1;
pub const header_len = 4 + 1 + 1 + keys.key_id_len + 4;
pub const entry_wire_len = block_id_len + pack_id_len + 8 + 4;

const encrypted_preamble_len = header_len + XChaCha20Poly1305.nonce_length;
const unencrypted_preamble_len = header_len + 4 + Sha256.digest_length;

/// Upper bound on entries in a single index segment (prevents unbounded
/// allocation from untrusted input).
pub const max_segment_entries: u32 = 1_000_000;

pub const Mode = pack.Mode;

pub const Error = error{
    InvalidSegmentMagic,
    UnsupportedSegmentVersion,
    InvalidSegmentMode,
    InvalidSegmentHeader,
    TooManyEntries,
    CorruptSegment,
    KeyRequired,
    UnexpectedKey,
    WrongKey,
    AuthenticationFailed,
    ChecksumMismatch,
    InvalidPackIdHex,
};

/// Generates a fresh 128-bit random pack identifier.
pub fn generatePackId() !PackId {
    var id: PackId = undefined;
    try std.Io.Threaded.global_single_threaded.io().randomSecure(&id);
    return id;
}

/// Formats a 16-byte `PackId` as 32 lowercase hex characters.
pub fn formatPackId(pack_id: PackId) [pack_id_len * 2]u8 {
    return std.fmt.bytesToHex(pack_id, .lower);
}

/// Parses a 32-character hex string into a 16-byte `PackId`.
pub fn parsePackId(hex: []const u8) Error!PackId {
    if (hex.len != pack_id_len * 2) return Error.InvalidPackIdHex;
    var out: PackId = undefined;
    _ = std.fmt.hexToBytes(&out, hex) catch return Error.InvalidPackIdHex;
    return out;
}

/// Computes `HMAC-SHA256(backup_key, cid)` (32 bytes), hiding the plaintext CID
/// in encrypted packs and index segments.
pub fn keyedBlockId(backup_key: keys.Key, cid: Cid) BlockId {
    var out: BlockId = undefined;
    HmacSha256.create(&out, &cid, &backup_key);
    return out;
}

/// Returns `HMAC-SHA256(key, cid)` when encrypted (`key != null`), or the raw
/// `cid` when unencrypted (`key == null`).
pub fn blockIdForCid(backup_key: ?keys.Key, cid: Cid) BlockId {
    return if (backup_key) |k| keyedBlockId(k, cid) else cid;
}

/// Where a block lives in the bucket: which pack, byte offset, and byte length.
pub const Location = struct {
    pack_id: PackId,
    offset: u64,
    length: u32,
};

/// Single index mapping: `block_id -> (pack_id, offset, length)`.
pub const Entry = struct {
    block_id: BlockId,
    pack_id: PackId,
    offset: u64,
    length: u32,

    pub fn fromCid(
        backup_key: keys.Key,
        cid: Cid,
        pack_id: PackId,
        offset: u64,
        length: u32,
    ) Entry {
        return .{
            .block_id = keyedBlockId(backup_key, cid),
            .pack_id = pack_id,
            .offset = offset,
            .length = length,
        };
    }

    pub fn location(self: Entry) Location {
        return .{
            .pack_id = self.pack_id,
            .offset = self.offset,
            .length = self.length,
        };
    }

    pub fn encode(self: Entry, out: *[entry_wire_len]u8) void {
        @memcpy(out[0..block_id_len], &self.block_id);
        @memcpy(out[block_id_len .. block_id_len + pack_id_len], &self.pack_id);
        std.mem.writeInt(u64, out[48..56], self.offset, .little);
        std.mem.writeInt(u32, out[56..60], self.length, .little);
    }

    pub fn decode(bytes: *const [entry_wire_len]u8) Entry {
        return .{
            .block_id = bytes[0..block_id_len].*,
            .pack_id = bytes[block_id_len .. block_id_len + pack_id_len].*,
            .offset = std.mem.readInt(u64, bytes[48..56], .little),
            .length = std.mem.readInt(u32, bytes[56..60], .little),
        };
    }
};

/// Serializes a batch of index entries into an encrypted (or unencrypted when
/// `key == null`) append-only index segment. Returns a caller-owned slice.
pub fn encodeSegment(
    allocator: std.mem.Allocator,
    entries: []const Entry,
    key: ?keys.Key,
) ![]u8 {
    if (key) |k| {
        var nonce: [XChaCha20Poly1305.nonce_length]u8 = undefined;
        try std.Io.Threaded.global_single_threaded.io().randomSecure(&nonce);
        return encodeSegmentDeterministic(allocator, entries, k, nonce);
    } else {
        return encodeUnencryptedSegment(allocator, entries);
    }
}

/// Deterministic variant of `encodeSegment` for encrypted segments with an
/// explicit 24-byte nonce.
pub fn encodeSegmentDeterministic(
    allocator: std.mem.Allocator,
    entries: []const Entry,
    key: keys.Key,
    nonce: [XChaCha20Poly1305.nonce_length]u8,
) ![]u8 {
    if (entries.len > max_segment_entries) return Error.TooManyEntries;

    const payload_len = entries.len * entry_wire_len;
    const total_len = encrypted_preamble_len + payload_len + XChaCha20Poly1305.tag_length;

    const out = try allocator.alloc(u8, total_len);
    errdefer allocator.free(out);

    writeHeader(out[0..header_len], .encrypted, keys.keyId(key), @intCast(entries.len));
    @memcpy(out[header_len..encrypted_preamble_len], &nonce);

    const plaintext = try allocator.alloc(u8, payload_len);
    defer {
        std.crypto.secureZero(u8, plaintext);
        allocator.free(plaintext);
    }
    encodeEntriesSlice(entries, plaintext);

    const ad = out[0..encrypted_preamble_len];
    const ct = out[encrypted_preamble_len .. encrypted_preamble_len + payload_len];
    var tag: [XChaCha20Poly1305.tag_length]u8 = undefined;
    XChaCha20Poly1305.encrypt(ct, &tag, plaintext, ad, nonce, key);
    @memcpy(out[encrypted_preamble_len + payload_len .. total_len], &tag);

    return out;
}

fn encodeUnencryptedSegment(
    allocator: std.mem.Allocator,
    entries: []const Entry,
) ![]u8 {
    if (entries.len > max_segment_entries) return Error.TooManyEntries;

    const payload_len = entries.len * entry_wire_len;
    const total_len = unencrypted_preamble_len + payload_len;

    const out = try allocator.alloc(u8, total_len);
    errdefer allocator.free(out);

    writeHeader(out[0..header_len], .unencrypted, [_]u8{0} ** keys.key_id_len, @intCast(entries.len));
    const entries_dest = out[unencrypted_preamble_len..total_len];
    encodeEntriesSlice(entries, entries_dest);

    var crc = Crc32.init();
    crc.update(out[0..header_len]);
    crc.update(entries_dest);
    std.mem.writeInt(u32, out[header_len .. header_len + 4], crc.final(), .little);

    var sha = Sha256.init(.{});
    sha.update(out[0..header_len]);
    sha.update(entries_dest);
    var digest: [Sha256.digest_length]u8 = undefined;
    sha.final(&digest);
    @memcpy(out[header_len + 4 .. unencrypted_preamble_len], &digest);

    return out;
}

fn writeHeader(
    dest: *[header_len]u8,
    mode: Mode,
    key_id: keys.KeyId,
    count: u32,
) void {
    @memcpy(dest[0..4], &segment_magic);
    dest[4] = segment_version;
    dest[5] = @intFromEnum(mode);
    @memcpy(dest[6 .. 6 + keys.key_id_len], &key_id);
    std.mem.writeInt(u32, dest[14..18], count, .little);
}

fn encodeEntriesSlice(entries: []const Entry, dest: []u8) void {
    for (entries, 0..) |entry, i| {
        const start = i * entry_wire_len;
        entry.encode(dest[start .. start + entry_wire_len][0..entry_wire_len]);
    }
}

/// Parses and authenticates an index segment back into a caller-owned slice of
/// `Entry`.
pub fn decodeSegment(
    allocator: std.mem.Allocator,
    segment_bytes: []const u8,
    key: ?keys.Key,
) ![]Entry {
    if (segment_bytes.len < header_len) return Error.InvalidSegmentHeader;
    if (!std.mem.eql(u8, segment_bytes[0..4], &segment_magic)) return Error.InvalidSegmentMagic;
    if (segment_bytes[4] != segment_version) return Error.UnsupportedSegmentVersion;

    const mode: Mode = switch (segment_bytes[5]) {
        0 => .unencrypted,
        1 => .encrypted,
        else => return Error.InvalidSegmentMode,
    };
    const header_key_id = segment_bytes[6 .. 6 + keys.key_id_len].*;
    const count = std.mem.readInt(u32, segment_bytes[14..18], .little);
    if (count > max_segment_entries) return Error.TooManyEntries;

    const payload_len = @as(usize, count) * entry_wire_len;

    switch (mode) {
        .encrypted => {
            const k = key orelse return Error.KeyRequired;
            if (!std.crypto.timing_safe.eql(keys.KeyId, keys.keyId(k), header_key_id)) {
                return Error.WrongKey;
            }
            const expected_len = encrypted_preamble_len + payload_len + XChaCha20Poly1305.tag_length;
            if (segment_bytes.len != expected_len) return Error.CorruptSegment;

            const nonce = segment_bytes[header_len..encrypted_preamble_len].*;
            const ad = segment_bytes[0..encrypted_preamble_len];
            const ct = segment_bytes[encrypted_preamble_len .. encrypted_preamble_len + payload_len];
            const tag = segment_bytes[encrypted_preamble_len + payload_len .. expected_len][0..XChaCha20Poly1305.tag_length].*;

            const plaintext = try allocator.alloc(u8, payload_len);
            defer {
                std.crypto.secureZero(u8, plaintext);
                allocator.free(plaintext);
            }

            XChaCha20Poly1305.decrypt(plaintext, ct, tag, ad, nonce, k) catch return Error.AuthenticationFailed;
            return decodeEntriesSlice(allocator, plaintext, count);
        },
        .unencrypted => {
            if (key != null) return Error.UnexpectedKey;
            if (!std.mem.allEqual(u8, &header_key_id, 0)) return Error.InvalidSegmentHeader;
            const expected_len = unencrypted_preamble_len + payload_len;
            if (segment_bytes.len != expected_len) return Error.CorruptSegment;

            const expected_crc = std.mem.readInt(u32, segment_bytes[header_len .. header_len + 4], .little);
            const expected_sha = segment_bytes[header_len + 4 .. unencrypted_preamble_len].*;
            const entries_bytes = segment_bytes[unencrypted_preamble_len..expected_len];

            var crc = Crc32.init();
            crc.update(segment_bytes[0..header_len]);
            crc.update(entries_bytes);
            if (crc.final() != expected_crc) return Error.ChecksumMismatch;

            var sha = Sha256.init(.{});
            sha.update(segment_bytes[0..header_len]);
            sha.update(entries_bytes);
            var actual_sha: [Sha256.digest_length]u8 = undefined;
            sha.final(&actual_sha);
            if (!std.crypto.timing_safe.eql([32]u8, actual_sha, expected_sha)) {
                return Error.ChecksumMismatch;
            }

            return decodeEntriesSlice(allocator, entries_bytes, count);
        },
    }
}

fn decodeEntriesSlice(
    allocator: std.mem.Allocator,
    raw: []const u8,
    count: u32,
) ![]Entry {
    const entries = try allocator.alloc(Entry, count);
    for (0..count) |i| {
        const start = i * entry_wire_len;
        entries[i] = Entry.decode(raw[start .. start + entry_wire_len][0..entry_wire_len]);
    }
    return entries;
}

/// In-memory lookup map built by merging one or more index segments.
pub const Index = struct {
    allocator: std.mem.Allocator,
    map: std.AutoHashMapUnmanaged(BlockId, Location) = .empty,

    pub fn init(allocator: std.mem.Allocator) Index {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Index) void {
        self.map.deinit(self.allocator);
    }

    pub fn count(self: *const Index) usize {
        return self.map.count();
    }

    /// Inserts or updates a single entry (later segments override earlier ones).
    pub fn put(self: *Index, entry: Entry) !void {
        try self.map.put(self.allocator, entry.block_id, entry.location());
    }

    /// Looks up a block location by its keyed `block_id`.
    pub fn get(self: *const Index, block_id: BlockId) ?Location {
        return self.map.get(block_id);
    }

    /// Computes `HMAC-SHA256(backup_key, cid)` and looks up its location.
    pub fn getByCid(self: *const Index, backup_key: keys.Key, cid: Cid) ?Location {
        return self.map.get(keyedBlockId(backup_key, cid));
    }

    pub fn contains(self: *const Index, block_id: BlockId) bool {
        return self.map.contains(block_id);
    }

    pub fn containsCid(self: *const Index, backup_key: keys.Key, cid: Cid) bool {
        return self.map.contains(keyedBlockId(backup_key, cid));
    }

    /// Merges a slice of entries into the lookup map.
    pub fn mergeEntries(self: *Index, entries: []const Entry) !void {
        try self.map.ensureUnusedCapacity(self.allocator, @intCast(entries.len));
        for (entries) |entry| {
            self.map.putAssumeCapacity(entry.block_id, entry.location());
        }
    }

    /// Decodes a serialized index segment and merges its entries into the map.
    pub fn mergeSegment(self: *Index, segment_bytes: []const u8, key: ?keys.Key) !void {
        const entries = try decodeSegment(self.allocator, segment_bytes, key);
        defer self.allocator.free(entries);
        try self.mergeEntries(entries);
    }

    /// Exports all entries currently in the map as a caller-owned slice.
    pub fn toEntriesAlloc(self: *const Index, allocator: std.mem.Allocator) ![]Entry {
        const list = try allocator.alloc(Entry, self.map.count());
        var i: usize = 0;
        var it = self.map.iterator();
        while (it.next()) |kv| {
            list[i] = .{
                .block_id = kv.key_ptr.*,
                .pack_id = kv.value_ptr.pack_id,
                .offset = kv.value_ptr.offset,
                .length = kv.value_ptr.length,
            };
            i += 1;
        }
        return list;
    }
};

test "index: keyedBlockId hides plaintext CID and is deterministic" {
    const key_a = [_]u8{0x42} ** 32;
    const key_b = [_]u8{0x43} ** 32;
    const cid = [_]u8{0x99} ** 32;

    const id1 = keyedBlockId(key_a, cid);
    const id2 = keyedBlockId(key_a, cid);
    const id_other_key = keyedBlockId(key_b, cid);

    try std.testing.expectEqualSlices(u8, &id1, &id2);
    try std.testing.expect(!std.mem.eql(u8, &id1, &cid));
    try std.testing.expect(!std.mem.eql(u8, &id1, &id_other_key));
}

test "index: encrypted segment round trip, no plaintext CID, wrong key, and tamper detection" {
    const allocator = std.testing.allocator;
    var key_a = try keys.BackupKey.generate();
    defer key_a.deinit();
    var key_b = try keys.BackupKey.generate();
    defer key_b.deinit();

    const pack1 = try generatePackId();
    const pack2 = try generatePackId();

    var cid1: Cid = undefined;
    var cid2: Cid = undefined;
    var cid3: Cid = undefined;
    Sha256.hash("block one", &cid1, .{});
    Sha256.hash("block two", &cid2, .{});
    Sha256.hash("block three", &cid3, .{});

    const entries = [_]Entry{
        Entry.fromCid(key_a.bytes, cid1, pack1, 30, 1024),
        Entry.fromCid(key_a.bytes, cid2, pack1, 1054, 2048),
        Entry.fromCid(key_a.bytes, cid3, pack2, 30, 512),
    };

    const segment = try encodeSegment(allocator, &entries, key_a.bytes);
    defer allocator.free(segment);

    // Neither plaintext CIDs nor keyed block_ids nor pack_ids appear in the encrypted segment.
    try std.testing.expectEqual(@as(?usize, null), std.mem.indexOf(u8, segment, &cid1));
    try std.testing.expectEqual(@as(?usize, null), std.mem.indexOf(u8, segment, &cid2));
    try std.testing.expectEqual(@as(?usize, null), std.mem.indexOf(u8, segment, &cid3));
    try std.testing.expectEqual(@as(?usize, null), std.mem.indexOf(u8, segment, &entries[0].block_id));
    try std.testing.expectEqual(@as(?usize, null), std.mem.indexOf(u8, segment, &pack1));

    // Round trip decode.
    const decoded = try decodeSegment(allocator, segment, key_a.bytes);
    defer allocator.free(decoded);
    try std.testing.expectEqual(entries.len, decoded.len);
    for (entries, decoded) |expected, actual| {
        try std.testing.expectEqual(expected, actual);
    }

    // Wrong key fails with Error.WrongKey; missing key fails with Error.KeyRequired.
    try std.testing.expectError(Error.WrongKey, decodeSegment(allocator, segment, key_b.bytes));
    try std.testing.expectError(Error.KeyRequired, decodeSegment(allocator, segment, null));

    // Flipping any byte in the segment fails authentication or validation.
    for (0..segment.len) |i| {
        var tampered = try allocator.dupe(u8, segment);
        defer allocator.free(tampered);
        tampered[i] ^= 0x01;
        try std.testing.expect(
            if (decodeSegment(allocator, tampered, key_a.bytes)) |d| blk: {
                allocator.free(d);
                break :blk false;
            } else |_| true,
        );
    }
}

test "index: merging multiple segments in memory and unencrypted mode" {
    const allocator = std.testing.allocator;
    var key = try keys.BackupKey.generate();
    defer key.deinit();

    const cid1 = [_]u8{0x01} ** 32;
    const cid2 = [_]u8{0x02} ** 32;
    const cid3 = [_]u8{0x03} ** 32;

    const pack_old = [_]u8{0xaa} ** 16;
    const pack_new = [_]u8{0xbb} ** 16;

    const seg1_entries = [_]Entry{
        Entry.fromCid(key.bytes, cid1, pack_old, 30, 100),
        Entry.fromCid(key.bytes, cid2, pack_old, 130, 200),
    };
    // Segment 2 repacks cid2 into pack_new and adds cid3.
    const seg2_entries = [_]Entry{
        Entry.fromCid(key.bytes, cid2, pack_new, 30, 200),
        Entry.fromCid(key.bytes, cid3, pack_new, 230, 300),
    };

    const seg1 = try encodeSegment(allocator, &seg1_entries, key.bytes);
    defer allocator.free(seg1);
    const seg2 = try encodeSegment(allocator, &seg2_entries, key.bytes);
    defer allocator.free(seg2);

    var index = Index.init(allocator);
    defer index.deinit();

    try index.mergeSegment(seg1, key.bytes);
    try index.mergeSegment(seg2, key.bytes);

    try std.testing.expectEqual(@as(usize, 3), index.count());
    try std.testing.expect(index.containsCid(key.bytes, cid1));
    try std.testing.expect(index.containsCid(key.bytes, cid2));
    try std.testing.expect(index.containsCid(key.bytes, cid3));

    const loc1 = index.getByCid(key.bytes, cid1).?;
    try std.testing.expectEqual(pack_old, loc1.pack_id);
    try std.testing.expectEqual(@as(u64, 30), loc1.offset);

    const loc2 = index.getByCid(key.bytes, cid2).?;
    try std.testing.expectEqual(pack_new, loc2.pack_id);
    try std.testing.expectEqual(@as(u64, 30), loc2.offset);

    const loc3 = index.getByCid(key.bytes, cid3).?;
    try std.testing.expectEqual(pack_new, loc3.pack_id);
    try std.testing.expectEqual(@as(u64, 230), loc3.offset);
    try std.testing.expectEqual(@as(u32, 300), loc3.length);

    // Unencrypted segment round trip and tamper detection.
    const clear_seg = try encodeSegment(allocator, &seg1_entries, null);
    defer allocator.free(clear_seg);
    const clear_decoded = try decodeSegment(allocator, clear_seg, null);
    defer allocator.free(clear_decoded);
    try std.testing.expectEqual(seg1_entries.len, clear_decoded.len);

    var tampered_clear = try allocator.dupe(u8, clear_seg);
    defer allocator.free(tampered_clear);
    tampered_clear[tampered_clear.len - 1] ^= 0x01;
    try std.testing.expectError(Error.ChecksumMismatch, decodeSegment(allocator, tampered_clear, null));
}
