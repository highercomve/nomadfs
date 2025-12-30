const std = @import("std");
const Allocator = std.mem.Allocator;

/// A link to another node in the graph.
/// Corresponds to the IPFS Link structure.
pub const DagLink = struct {
    name: []const u8,    // Local name (e.g., "link-0")
    cid: []const u8,     // The Content Identifier (Hash)
    size: u64,           // Cumulative size of target + all its children
};

/// The internal representation of a Merkle Node.
pub const MerkleNode = struct {
    links: std.ArrayListUnmanaged(DagLink),
    data: []const u8,    // Raw data for Leaves, metadata for Parents
    level: u8,           // 0 = Leaf, 1+ = Parent/Branch
    allocator: Allocator,

    pub fn init(allocator: Allocator, data: []const u8, level: u8) MerkleNode {
        return .{
            .links = std.ArrayListUnmanaged(DagLink){},
            .data = data, 
            .level = level,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *MerkleNode) void {
        for (self.links.items) |link| {
            self.allocator.free(link.name);
            self.allocator.free(link.cid);
        }
        self.links.deinit(self.allocator);
        self.allocator.free(self.data);
    }

    pub fn totalSize(self: MerkleNode) u64 {
        var sum: u64 = self.data.len;
        for (self.links.items) |link| {
            sum += link.size;
        }
        return sum;
    }
};

test "MerkleNode totalSize calculation" {
    const testing = std.testing;
    const allocator = testing.allocator;
    
    // Create a leaf node (Blob)
    const data = try allocator.dupe(u8, "Hello World");
    var leaf = MerkleNode.init(allocator, data, 0);
    defer leaf.deinit();
    
    // Check leaf size
    try testing.expectEqual(@as(u64, 11), leaf.totalSize());
    
    // Create a parent node (List)
    var parent = MerkleNode.init(allocator, try allocator.dupe(u8, ""), 1);
    defer parent.deinit();
    
    // Add link to leaf
    try parent.links.append(allocator, DagLink{
        .name = try allocator.dupe(u8, "leaf"),
        .cid = try allocator.dupe(u8, "QmHash"),
        .size = leaf.totalSize(),
    });
    
    // Parent size should be sum of children sizes (plus its own data, which is 0)
    try testing.expectEqual(@as(u64, 11), parent.totalSize());
}
