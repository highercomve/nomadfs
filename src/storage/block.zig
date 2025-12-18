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
