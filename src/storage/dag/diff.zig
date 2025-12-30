const std = @import("std");
const dag_node = @import("node.zig");
const StorageEngine = @import("../engine.zig").StorageEngine;

pub const DiffService = struct {
    store: *StorageEngine,
    allocator: std.mem.Allocator,

    /// Returns a list of CIDs that 'new_root' has but 'old_root' does not.
    pub fn calculateDiff(
        self: *DiffService, 
        old_root: []const u8, 
        new_root: []const u8
    ) !std.ArrayList([]const u8) {
        _ = self;
        _ = old_root;
        _ = new_root;
        return error.NotImplemented;
    }
    
    // Internal helper (stub)
    fn diffRecursive(
        self: *DiffService, 
        old_node: dag_node.MerkleNode, 
        new_node: dag_node.MerkleNode, 
        list: *std.ArrayList([]const u8)
    ) !void {
        _ = self;
        _ = old_node;
        _ = new_node;
        _ = list;
    }
};

test "DiffService: calculateDiff detects changes" {
    const testing = std.testing;
    const allocator = testing.allocator;
    
    // 1. Setup Storage
    const test_path = "test_storage_diff";
    std.fs.cwd().deleteTree(test_path) catch {};
    defer std.fs.cwd().deleteTree(test_path) catch {};
    
    var engine = try StorageEngine.init(allocator, test_path);
    defer engine.deinit();
    
    var diff_service = DiffService{
        .store = &engine,
        .allocator = allocator,
    };
    
    // 2. Define fake CIDs (32 bytes hex)
    // We are mocking the "content" by using CIDs directly in this test 
    // without actually writing blocks to disk because the stub implementation 
    // won't read them anyway.
    
    // Roots
    const root_a_cid = "11111111111111111111111111111111"; // 32 chars
    const root_b_cid = "22222222222222222222222222222222"; 
    
    // Case 1: Identical roots (Optimization)
    var diff = try diff_service.calculateDiff(root_a_cid, root_a_cid);
    defer diff.deinit();
    try testing.expectEqual(@as(usize, 0), diff.items.len);
    
    // Case 2: Different roots (Should return something or fail with NotImplemented)
    // This expects error.NotImplemented initially.
    _ = diff_service.calculateDiff(root_a_cid, root_b_cid) catch |err| {
        try testing.expectEqual(error.NotImplemented, err);
        return;
    };
    
    // If we implemented it, we would expect diffs.
    // try testing.expect(diff.items.len > 0);
}
