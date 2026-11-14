//! Offsite backup pack format, envelope key wrapping, recovery words, and block index.

const std = @import("std");

pub const keys = @import("keys.zig");
pub const recovery_words = @import("recovery_words.zig");
pub const pack = @import("pack.zig");
pub const index = @import("index.zig");

test {
    _ = keys;
    _ = recovery_words;
    _ = pack;
    _ = index;
}

test "backup: end-to-end key wrap, pack write, index segment, and range read" {
    const allocator = std.testing.allocator;
    const Sha256 = std.crypto.hash.sha2.Sha256;

    // 1. Generate a backup key and a 24-word recovery phrase.
    var backup_key = try keys.BackupKey.generate();
    defer backup_key.deinit();

    var recovery_entropy = try keys.generateKey();
    defer std.crypto.secureZero(u8, &recovery_entropy);

    var phrase_buf: [recovery_words.max_phrase_len]u8 = undefined;
    const phrase = recovery_words.formatPhrase(recovery_entropy, &phrase_buf);

    const recovery_blob = try keys.wrapWithRecovery(allocator, backup_key.bytes, phrase);

    // 2. Pack two content blocks under their HMAC-SHA256 keyed block IDs.
    const pack_id = try index.generatePackId();
    var writer = try pack.Writer.init(allocator, .{ .key = backup_key.bytes });
    defer writer.deinit();

    const block_a = "First content block in NomadFS backup";
    const block_b = "Second content block in NomadFS backup";
    var cid_a: index.Cid = undefined;
    var cid_b: index.Cid = undefined;
    Sha256.hash(block_a, &cid_a, .{});
    Sha256.hash(block_b, &cid_b, .{});

    const span_a = try writer.append(index.keyedBlockId(backup_key.bytes, cid_a), block_a);
    const span_b = try writer.append(index.keyedBlockId(backup_key.bytes, cid_b), block_b);

    var packed_result = try writer.finish();
    defer packed_result.deinit(allocator);

    // 3. Serialize an encrypted index segment for the pack.
    const entries = [_]index.Entry{
        index.Entry.fromCid(backup_key.bytes, cid_a, pack_id, span_a.offset, span_a.length),
        index.Entry.fromCid(backup_key.bytes, cid_b, pack_id, span_b.offset, span_b.length),
    };
    const segment_bytes = try index.encodeSegment(allocator, &entries, backup_key.bytes);
    defer allocator.free(segment_bytes);

    // 4. Unwrap the backup key from the 24 recovery words, load the index, and read block_b.
    var restored_key = try keys.unwrapWithRecovery(allocator, &recovery_blob, phrase);
    defer std.crypto.secureZero(u8, &restored_key);

    var idx = index.Index.init(allocator);
    defer idx.deinit();
    try idx.mergeSegment(segment_bytes, restored_key);

    const loc_b = idx.getByCid(restored_key, cid_b).?;
    try std.testing.expectEqual(pack_id, loc_b.pack_id);

    const restored_block_b = try pack.readBlock(
        allocator,
        packed_result.bytes,
        loc_b.offset,
        loc_b.length,
        restored_key,
    );
    defer allocator.free(restored_block_b);
    try std.testing.expectEqualStrings(block_b, restored_block_b);
}
