//! How a file is stored, for the app's Details view: its DAG's depth, its
//! chunks (offset, size, CID, in file order) and where this device holds
//! each one. Only parent blocks are loaded, plus one chunk to learn the
//! depth, so inspecting a large file on another device doesn't download it.

const std = @import("std");
const storage = @import("../storage/mod.zig");
const codec = storage.dag.codec;
const Cid = codec.Cid;
const tree = @import("tree.zig");

pub const Chunk = struct {
    offset: u64,
    size: u64,
    cid: Cid,
};

pub const Inspection = struct {
    /// Levels of parent blocks above the chunks (0: the file is one chunk).
    depth: u32,
    parents: u32,
    chunks: []Chunk,

    pub fn deinit(self: Inspection, allocator: std.mem.Allocator) void {
        allocator.free(self.chunks);
    }
};

/// Most chunks listed (a 64 GB file at the average chunk size).
pub const max_chunks = 1 << 18;

/// Walks the file rooted at `root`: the DAG is balanced (every chunk at one
/// depth), so the first child chain tells the depth, and the parent blocks
/// above that depth list every chunk with its size.
pub fn inspect(allocator: std.mem.Allocator, loader: tree.Loader, root: Cid) !Inspection {
    // The depth: follow the first link down to a chunk.
    var depth: u32 = 0;
    {
        var cid = root;
        while (true) {
            const bytes = try loader.load(&cid, allocator);
            defer allocator.free(bytes);
            switch (try codec.decode(bytes)) {
                .leaf => |data| {
                    if (depth == 0) {
                        const chunks = try allocator.alloc(Chunk, 1);
                        chunks[0] = .{ .offset = 0, .size = data.len, .cid = root };
                        return .{ .depth = 0, .parents = 0, .chunks = chunks };
                    }
                    break;
                },
                .parent => |links| {
                    var it = links;
                    const first = it.next() orelse return error.EmptyParent;
                    cid = first.cid.*;
                    depth += 1;
                    if (depth > 64) return error.TooDeep;
                },
                .dir => return error.NotAFile,
            }
        }
    }

    var chunks: std.ArrayList(Chunk) = .empty;
    errdefer chunks.deinit(allocator);
    var parents: u32 = 0;
    var offset: u64 = 0;
    try walk(allocator, loader, root, depth, &chunks, &parents, &offset);
    return .{ .depth = depth, .parents = parents, .chunks = try chunks.toOwnedSlice(allocator) };
}

fn walk(allocator: std.mem.Allocator, loader: tree.Loader, cid: Cid, level: u32, chunks: *std.ArrayList(Chunk), parents: *u32, offset: *u64) !void {
    const bytes = try loader.load(&cid, allocator);
    defer allocator.free(bytes);
    var links = switch (try codec.decode(bytes)) {
        .parent => |l| l,
        else => return error.UnbalancedDag,
    };
    // Every parent links at least one chunk in a real file: more parents
    // than chunks allowed is a peer's tree of empty parents.
    if (parents.* >= max_chunks) return error.DagTooLarge;
    parents.* += 1;
    while (links.next()) |link| {
        if (level == 1) {
            if (chunks.items.len >= max_chunks) return error.TooManyChunks;
            try chunks.append(allocator, .{ .offset = offset.*, .size = link.size, .cid = link.cid.* });
            offset.* +|= link.size;
        } else {
            try walk(allocator, loader, link.cid.*, level - 1, chunks, parents, offset);
        }
    }
}

test "inspect: lists the chunks of a stored file in order" {
    const a = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const path = "test_inspect_store";
    std.Io.Dir.cwd().deleteTree(io, path) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, path) catch {};
    var store = try storage.engine.StorageEngine.init(a, path);
    defer store.deinit();

    const data = try a.alloc(u8, 3 * 1024 * 1024 + 17);
    defer a.free(data);
    var prng = std.Random.DefaultPrng.init(7);
    prng.random().bytes(data);
    var builder = storage.dag.DagBuilder{ .allocator = a, .store = &store, .layout = .Balanced };
    const Slice = struct {
        bytes: []const u8,
        pos: usize = 0,
        pub fn read(self: *@This(), buf: []u8) !usize {
            const n = @min(buf.len, self.bytes.len - self.pos);
            @memcpy(buf[0..n], self.bytes[self.pos..][0..n]);
            self.pos += n;
            return n;
        }
    };
    var reader = Slice{ .bytes = data };
    const root_bytes = try builder.build(&reader);
    defer a.free(root_bytes);

    const info = try inspect(a, tree.Loader.local(&store), root_bytes[0..32].*);
    defer info.deinit(a);
    try std.testing.expect(info.depth >= 1);
    try std.testing.expect(info.chunks.len > 3);
    var total: u64 = 0;
    for (info.chunks) |c| {
        try std.testing.expectEqual(total, c.offset);
        total += c.size;
    }
    try std.testing.expectEqual(@as(u64, data.len), total);
}
