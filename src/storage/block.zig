const std = @import("std");

/// A block of data in the content-addressable storage.
pub const Block = struct {
    cid: [32]u8, // SHA-256 hash
    data: []const u8,

    /// Create a new block by hashing the data.
    /// The data slice is owned by the caller, but this struct holds a reference.
    pub fn new(data: []const u8) Block {
        var hash: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(data, &hash);
        return Block{
            .cid = hash,
            .data = data,
        };
    }
};

/// Interface for chunking a stream of bytes into Blocks.
pub const Chunker = struct {
    // specific chunking state (e.g. Rabin fingerprinting) would go here

    pub fn chunk(data: []const u8, chunk_size: usize, allocator: std.mem.Allocator) ![]Block {
        var blocks = std.ArrayList(Block).init(allocator);
        var i: usize = 0;
        while (i < data.len) {
            const end = @min(i + chunk_size, data.len);
            const slice = data[i..end];
            try blocks.append(Block.new(slice));
            i = end;
        }
        return blocks.toOwnedSlice();
    }
};

test "Block: creation and integrity" {
    const data = "Hello NomadFS";
    const block = Block.new(data);
    
    // SHA256 of "Hello NomadFS"
    // echo -n "Hello NomadFS" | sha256sum
    // 6176d5c6437299557404457e5564855422894f1079d8c47b53945c58971597f5
    const expected_hex = "6176d5c6437299557404457e5564855422894f1079d8c47b53945c58971597f5";
    var actual_hex: [64]u8 = undefined;
    _ = std.fmt.bufPrint(&actual_hex, "{s}", .{std.fmt.fmtSliceHexLower(&block.cid)}) catch unreachable;
    
    try std.testing.expectEqualStrings(expected_hex, &actual_hex);
    try std.testing.expectEqualStrings(data, block.data);
}

test "Chunker: fixed size splitting" {
    const allocator = std.testing.allocator;
    const data = "1234567890"; // 10 bytes
    
    // Chunk size 3 -> [123, 456, 789, 0]
    const blocks = try Chunker.chunk(data, 3, allocator);
    defer allocator.free(blocks);
    
    try std.testing.expectEqual(@as(usize, 4), blocks.len);
    try std.testing.expectEqualStrings("123", blocks[0].data);
    try std.testing.expectEqualStrings("456", blocks[1].data);
    try std.testing.expectEqualStrings("789", blocks[2].data);
    try std.testing.expectEqualStrings("0", blocks[3].data);
}
