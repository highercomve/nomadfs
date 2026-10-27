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
                inline .parent, .dir => |links| try walk.pushChildren(allocator, &stack, links),
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

    const data_size = 3 * 1024 * 1024;
    const old_data = try allocator.alloc(u8, data_size);
    defer allocator.free(old_data);
    var prng = std.Random.DefaultPrng.init(0x11223344);
    prng.random().bytes(old_data);

    const new_data = try allocator.dupe(u8, old_data);
    defer allocator.free(new_data);
    new_data[data_size / 2] ^= 0xff;

    const old_root = try buildFile(&engine, old_data);
    defer allocator.free(old_root);
    const new_root = try buildFile(&engine, new_data);
    defer allocator.free(new_root);

    // Identical roots: nothing to fetch.
    var same = try diff_service.calculateDiff(old_root, old_root);
    defer freeDiff(allocator, &same);
    try testing.expectEqual(@as(usize, 0), same.items.len);

    // Changed middle chunk: CDC limits the diff to the changed leaf,
    // possibly a neighbor, plus parent/root.
    var diff = try diff_service.calculateDiff(old_root, new_root);
    defer freeDiff(allocator, &diff);
    try testing.expect(diff.items.len >= 2 and diff.items.len <= 4);
    try testing.expect(containsCid(diff.items, new_root));
    try testing.expect(!containsCid(diff.items, old_root));

    // A missing block is reported, not skipped.
    const unknown = [_]u8{0x42} ** codec.cid_len;
    try testing.expectError(error.BlockNotFound, diff_service.calculateDiff(&unknown, new_root));
}

test "DiffService: shift resistance with FastCDC" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const test_path = "test_storage_diff_shift";
    const io = std.Io.Threaded.global_single_threaded.io();
    std.Io.Dir.cwd().deleteTree(io, test_path) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, test_path) catch {};

    var engine = try StorageEngine.init(allocator, test_path);
    defer engine.deinit();
    var diff_service = DiffService{ .store = &engine, .allocator = allocator };

    const data_len = 4 * 1024 * 1024;
    const data_a = try allocator.alloc(u8, data_len);
    defer allocator.free(data_a);
    var prng = std.Random.DefaultPrng.init(0x55667788);
    prng.random().bytes(data_a);

    // Insert one byte at offset 100
    const data_b = try allocator.alloc(u8, data_len + 1);
    defer allocator.free(data_b);
    @memcpy(data_b[0..100], data_a[0..100]);
    data_b[100] = 0xAA;
    @memcpy(data_b[101..], data_a[100..]);

    const root_a = try buildFile(&engine, data_a);
    defer allocator.free(root_a);
    const root_b = try buildFile(&engine, data_b);
    defer allocator.free(root_b);

    var diff = try diff_service.calculateDiff(root_a, root_b);
    defer freeDiff(allocator, &diff);

    // CDC preserves boundaries: diff must be small (<= 4 blocks)
    try testing.expect(diff.items.len <= 4);

    // Count leaves in DAG A and check how many are shared with DAG B
    var reachable_a = try walk.collectReachable(allocator, &engine, root_a);
    defer reachable_a.deinit(allocator);
    var reachable_b = try walk.collectReachable(allocator, &engine, root_b);
    defer reachable_b.deinit(allocator);

    var leaf_count_a: usize = 0;
    var shared_leaves: usize = 0;
    var it = reachable_a.keyIterator();
    while (it.next()) |cid| {
        {
            const block = (try engine.get(cid, allocator)).?;
            defer allocator.free(block.data);
            switch (try codec.decode(block.data)) {
                .leaf => {
                    leaf_count_a += 1;
                    if (reachable_b.contains(cid.*)) shared_leaves += 1;
                },
                .parent, .dir => {},
            }
        }
    }

    std.debug.print("\nShift resistance: diff size = {d}, shared leaves = {d}/{d}\n", .{
        diff.items.len,
        shared_leaves,
        leaf_count_a,
    });

    try testing.expect(shared_leaves >= leaf_count_a - 2);
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
