const std = @import("std");
const StorageEngine = @import("../engine.zig").StorageEngine;
const codec = @import("codec.zig");
const walk = @import("walk.zig");

pub const DiffService = struct {
    store: *StorageEngine,
    allocator: std.mem.Allocator,

    /// Returns the CIDs reachable from `new_root` but not from `old_root`:
    /// exactly the blocks a holder of the old version must fetch. Subtrees
    /// shared with the old version are skipped without being read (identical
    /// CID means identical content). Each CID appears once. Free the result
    /// with freeDiff. Both DAGs must be stored locally (error.BlockNotFound).
    pub fn calculateDiff(self: *DiffService, old_root: []const u8, new_root: []const u8) !std.ArrayList([]const u8) {
        const allocator = self.allocator;
        if (std.mem.eql(u8, old_root, new_root)) {
            _ = try walk.cidFromSlice(new_root);
            return .empty;
        }

        var old_set = try walk.collectReachable(allocator, self.store, old_root);
        defer old_set.deinit(allocator);

        var result: std.ArrayList([]const u8) = .empty;
        errdefer freeDiff(allocator, &result);
        var visited: walk.CidSet = .empty;
        defer visited.deinit(allocator);
        var stack: std.ArrayList(codec.Cid) = .empty;
        defer stack.deinit(allocator);
        try stack.append(allocator, try walk.cidFromSlice(new_root));

        while (stack.pop()) |cid| {
            if (old_set.contains(cid)) continue;
            if ((try visited.getOrPut(allocator, cid)).found_existing) continue;

            try result.ensureUnusedCapacity(allocator, 1);
            result.appendAssumeCapacity(try allocator.dupe(u8, &cid));

            const block = (try self.store.get(&cid, allocator)) orelse return error.BlockNotFound;
            defer allocator.free(block.data);
            switch (try codec.decode(block.data)) {
                .leaf => {},
                .parent => |links| try walk.pushChildren(allocator, &stack, links),
            }
        }
        return result;
    }
};

pub fn freeDiff(allocator: std.mem.Allocator, list: *std.ArrayList([]const u8)) void {
    for (list.items) |cid| allocator.free(cid);
    list.deinit(allocator);
}

const DagBuilder = @import("builder.zig").DagBuilder;
const CHUNK_SIZE = @import("builder.zig").CHUNK_SIZE;

const SliceReader = struct {
    buffer: []const u8,
    pos: usize = 0,

    pub fn read(self: *@This(), dest: []u8) !usize {
        const n = @min(dest.len, self.buffer.len - self.pos);
        @memcpy(dest[0..n], self.buffer[self.pos..][0..n]);
        self.pos += n;
        return n;
    }
};

fn buildFile(engine: *StorageEngine, data: []const u8) ![]const u8 {
    var builder = DagBuilder{ .allocator = std.testing.allocator, .store = engine, .layout = .Balanced };
    var reader = SliceReader{ .buffer = data };
    return builder.build(&reader);
}

fn containsCid(list: []const []const u8, cid: []const u8) bool {
    for (list) |c| {
        if (std.mem.eql(u8, c, cid)) return true;
    }
    return false;
}

test "DiffService: calculateDiff detects changes" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const test_path = "test_storage_diff";
    const io = std.Io.Threaded.global_single_threaded.io();
    std.Io.Dir.cwd().deleteTree(io, test_path) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, test_path) catch {};

    var engine = try StorageEngine.init(allocator, test_path);
    defer engine.deinit();
    var diff_service = DiffService{ .store = &engine, .allocator = allocator };

    // Two three-chunk files that differ only in the middle chunk.
    const old_data = try allocator.alloc(u8, CHUNK_SIZE * 3);
    defer allocator.free(old_data);
    @memset(old_data, 'a');
    const new_data = try allocator.dupe(u8, old_data);
    defer allocator.free(new_data);
    new_data[CHUNK_SIZE + 5] = 'b';

    const old_root = try buildFile(&engine, old_data);
    defer allocator.free(old_root);
    const new_root = try buildFile(&engine, new_data);
    defer allocator.free(new_root);

    // Identical roots: nothing to fetch.
    var same = try diff_service.calculateDiff(old_root, old_root);
    defer freeDiff(allocator, &same);
    try testing.expectEqual(@as(usize, 0), same.items.len);

    // Changed middle chunk: only the new root and the new leaf differ. The
    // unchanged first/last chunks ('a' * CHUNK_SIZE) are shared.
    var diff = try diff_service.calculateDiff(old_root, new_root);
    defer freeDiff(allocator, &diff);
    try testing.expectEqual(@as(usize, 2), diff.items.len);
    try testing.expect(containsCid(diff.items, new_root));
    try testing.expect(!containsCid(diff.items, old_root));

    // A missing block is reported, not skipped.
    const unknown = [_]u8{0x42} ** codec.cid_len;
    try testing.expectError(error.BlockNotFound, diff_service.calculateDiff(&unknown, new_root));
}

test "DiffService: no leaks when allocation fails" {
    const testing = std.testing;
    const test_path = "test_storage_diff_oom";
    const io = std.Io.Threaded.global_single_threaded.io();
    std.Io.Dir.cwd().deleteTree(io, test_path) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, test_path) catch {};

    var engine = try StorageEngine.init(testing.allocator, test_path);
    defer engine.deinit();

    const old_root = try buildFile(&engine, "first version of the file");
    defer testing.allocator.free(old_root);
    const new_root = try buildFile(&engine, "second version of the file");
    defer testing.allocator.free(new_root);

    try testing.checkAllAllocationFailures(testing.allocator, struct {
        fn run(allocator: std.mem.Allocator, store: *StorageEngine, a: []const u8, b: []const u8) !void {
            var service = DiffService{ .store = store, .allocator = allocator };
            var list = try service.calculateDiff(a, b);
            freeDiff(allocator, &list);
        }
    }.run, .{ &engine, old_root, new_root });
}
