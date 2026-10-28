//! Traversals over a DAG held in a StorageEngine. All walks use an explicit
//! stack (no recursion) and decode blocks with `codec`, so they work the same
//! for DAGs built locally and DAGs fetched from peers.

const std = @import("std");
const codec = @import("codec.zig");
const node = @import("node.zig");
const chunker = @import("../chunker.zig");
const Block = @import("../block.zig").Block;
const StorageEngine = @import("../engine.zig").StorageEngine;
const Cid = codec.Cid;

pub const CidSet = std.AutoHashMapUnmanaged(Cid, void);

pub fn cidFromSlice(cid: []const u8) !Cid {
    if (cid.len != codec.cid_len) return error.InvalidCid;
    return cid[0..codec.cid_len].*;
}

/// Pushes a parent's or dir's children so that popping yields them in link
/// order. `links` is a codec.LinkIterator or codec.EntryIterator.
pub fn pushChildren(allocator: std.mem.Allocator, stack: *std.ArrayList(Cid), links: anytype) !void {
    var it = links;
    try stack.ensureUnusedCapacity(allocator, it.count);
    const start = stack.items.len;
    while (it.next()) |link| stack.appendAssumeCapacity(link.cid.*);
    std.mem.reverse(Cid, stack.items[start..]);
}

pub const ReadOptions = struct {
    /// Upper bound on bytes written. A DAG may reference the same subtree many
    /// times, so a small DAG from a peer can describe an enormous file.
    max_bytes: u64 = std.math.maxInt(u64),
};

/// Most blocks one read may visit, repeats included. Empty leaves add no
/// bytes, so `max_bytes` alone cannot stop a DAG that references one subtree
/// many times over. Matches RepairManager.max_blocks.
pub const default_max_blocks = 1 << 20;

/// Fewest blocks any read may visit, so a small `max_bytes` still allows a
/// few parent levels.
const min_blocks = 64;

const min_leaf_bytes: u64 = (chunker.Params{}).min_size;

/// The visit budget for a read capped at `max_bytes`. Chunks are at least
/// `min_size` bytes except the last, so an honest DAG has at most `leaves`
/// leaves, and each leaf plus at most one parent or spine node per leaf gives
/// 2 * leaves visits. The result is clamped to [min_blocks, default_max_blocks],
/// so an unlimited read (`maxInt`) gets the default.
pub fn blockBudget(max_bytes: u64) u64 {
    const leaves = max_bytes / min_leaf_bytes + 1;
    return std.math.clamp(leaves *| 2 +| 1, min_blocks, default_max_blocks);
}

/// Writes the file rooted at `root` to `writer` (anything with writeAll) and
/// returns its size. Every block must be present locally: check with
/// isComplete first if partial output on error is unacceptable. Returns
/// error.DagTooLarge once the walk has visited more blocks than blockBudget
/// allows for `options.max_bytes`.
pub fn readFile(allocator: std.mem.Allocator, store: *StorageEngine, root: []const u8, writer: anytype, options: ReadOptions) !u64 {
    var stack: std.ArrayList(Cid) = .empty;
    defer stack.deinit(allocator);
    try stack.append(allocator, try cidFromSlice(root));

    const budget = blockBudget(options.max_bytes);
    var visited: u64 = 0;
    var total: u64 = 0;
    while (stack.pop()) |cid| {
        visited += 1;
        if (visited > budget) return error.DagTooLarge;
        const block = (try store.get(&cid, allocator)) orelse return error.BlockNotFound;
        defer allocator.free(block.data);

        switch (try codec.decode(block.data)) {
            .leaf => |data| {
                if (data.len > options.max_bytes - total) return error.FileTooLarge;
                try writer.writeAll(data);
                total += data.len;
            },
            .parent => |links| try pushChildren(allocator, &stack, links),
            .dir => return error.IsDirectory,
        }
    }
    return total;
}

/// Whether every block of the DAG rooted at `root` is stored locally.
pub fn isComplete(allocator: std.mem.Allocator, store: *StorageEngine, root: []const u8) !bool {
    var stack: std.ArrayList(Cid) = .empty;
    defer stack.deinit(allocator);
    var visited: CidSet = .empty;
    defer visited.deinit(allocator);
    try stack.append(allocator, try cidFromSlice(root));

    while (stack.pop()) |cid| {
        if ((try visited.getOrPut(allocator, cid)).found_existing) continue;
        const block = (try store.get(&cid, allocator)) orelse return false;
        defer allocator.free(block.data);
        switch (try codec.decode(block.data)) {
            .leaf => {},
            inline .parent, .dir => |links| try pushChildren(allocator, &stack, links),
        }
    }
    return true;
}

/// Collects every CID reachable from `root` (inclusive). Caller deinits.
pub fn collectReachable(allocator: std.mem.Allocator, store: *StorageEngine, root: []const u8) !CidSet {
    var stack: std.ArrayList(Cid) = .empty;
    defer stack.deinit(allocator);
    var reached: CidSet = .empty;
    errdefer reached.deinit(allocator);
    try stack.append(allocator, try cidFromSlice(root));

    while (stack.pop()) |cid| {
        if ((try reached.getOrPut(allocator, cid)).found_existing) continue;
        const block = (try store.get(&cid, allocator)) orelse return error.BlockNotFound;
        defer allocator.free(block.data);
        switch (try codec.decode(block.data)) {
            .leaf => {},
            inline .parent, .dir => |links| try pushChildren(allocator, &stack, links),
        }
    }
    return reached;
}

test "readFile bounds repeated subtree expansion including empty leaves" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const path = "test_walk_repeated_subtree";
    std.Io.Dir.cwd().deleteTree(io, path) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, path) catch {};
    var store = try StorageEngine.init(allocator, path);
    defer store.deinit();

    var root = Block.new(&.{0}); // An encoded empty leaf.
    try store.put(root);
    for (0..8) |_| {
        const links = [_]node.DagLink{
            .{ .name = "a", .cid = &root.cid, .size = 0 },
            .{ .name = "b", .cid = &root.cid, .size = 0 },
        };
        const bytes = try codec.encodeParent(allocator, &links);
        defer allocator.free(bytes);
        root = Block.new(bytes);
        try store.put(root);
    }
    const Writer = struct {
        fn writeAll(_: @This(), data: []const u8) !void {
            try std.testing.expectEqual(@as(usize, 0), data.len);
        }
    };
    try std.testing.expectError(error.DagTooLarge, readFile(allocator, &store, &root.cid, Writer{}, .{ .max_bytes = 0 }));
    // Repeated links still reproduce valid file content under the budget.
    try std.testing.expectEqual(@as(u64, 0), try readFile(allocator, &store, &root.cid, Writer{}, .{}));
    try std.testing.expectEqual(@as(u64, default_max_blocks), blockBudget(std.math.maxInt(u64)));
}
