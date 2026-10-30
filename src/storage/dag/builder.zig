const std = @import("std");
const node_mod = @import("node.zig");
const MerkleNode = node_mod.MerkleNode;
const DagLink = node_mod.DagLink;
const StorageEngine = @import("../engine.zig").StorageEngine;
const block_mod = @import("../block.zig");
const Block = block_mod.Block;
const codec = @import("codec.zig");
const chunker = @import("../chunker.zig");

pub const chunk_params = chunker.Params{};
const MAX_LINKS = 174;

pub const Layout = enum {
    Balanced, // B-Tree
    Linear, // Linked List
};

pub const DagBuilder = struct {
    allocator: std.mem.Allocator,
    store: *StorageEngine,
    layout: Layout,
    /// When set, leaf blocks are not written to `store`: the sink is told
    /// where each leaf's bytes sit in the input instead (shared folders keep
    /// file bytes in the files themselves). Parents are always stored.
    leaf_sink: ?LeafSink = null,
    /// Buffers reused across builds. Without it each build allocates two
    /// chunk-sized buffers, which dominates the cost of small files.
    scratch: ?*Scratch = null,

    pub const Scratch = struct {
        chunk: []u8,
        /// The leaf encoding: tag byte, then the chunk.
        leaf: []u8,

        pub fn init(allocator: std.mem.Allocator) !Scratch {
            const chunk = try allocator.alloc(u8, chunk_params.max_size);
            errdefer allocator.free(chunk);
            return .{ .chunk = chunk, .leaf = try allocator.alloc(u8, 1 + chunk_params.max_size) };
        }

        pub fn deinit(self: *Scratch, allocator: std.mem.Allocator) void {
            allocator.free(self.chunk);
            allocator.free(self.leaf);
        }
    };

    pub const LeafSink = struct {
        ctx: *anyopaque,
        /// `offset` and `len` locate the leaf's data in the input stream.
        recordFn: *const fn (ctx: *anyopaque, cid: *const [32]u8, offset: u64, len: u32) anyerror!void,
    };

    /// Main entry point: Turns a file reader into a Root CID owned by the caller.
    pub fn build(self: *DagBuilder, reader: anytype) ![]const u8 {
        // We accumulate the leaf nodes' metadata (CIDs and sizes), not their data.
        // This keeps memory usage low even for large files.
        var leaf_metadata: std.ArrayList(DagLink) = .empty;
        defer self.freeLinks(&leaf_metadata);

        var chk = if (self.scratch) |sc|
            chunker.Chunker.initBuffer(self.allocator, chunk_params, sc.chunk)
        else
            try chunker.Chunker.init(self.allocator, chunk_params);
        defer chk.deinit();

        // Reused encoding buffer: byte 0 holds the leaf tag, so a chunk is
        // copied once into place and persisted straight from there. Chunk
        // slices returned by the chunker alias its own buffer, which is why
        // the copy is needed.
        const leaf_buf = if (self.scratch) |sc| sc.leaf else try self.allocator.alloc(u8, 1 + chunk_params.max_size);
        defer if (self.scratch == null) self.allocator.free(leaf_buf);
        leaf_buf[0] = @intFromEnum(codec.Tag.leaf);

        var offset: u64 = 0;
        while (try chk.next(reader)) |chunk| {
            @memcpy(leaf_buf[1 .. 1 + chunk.len], chunk);
            const leaf_cid = if (self.leaf_sink) |sink| blk: {
                const block = Block.new(leaf_buf[0 .. 1 + chunk.len]);
                try sink.recordFn(sink.ctx, &block.cid, offset, @intCast(chunk.len));
                break :blk try self.allocator.dupe(u8, &block.cid);
            } else try self.persistBytes(leaf_buf[0 .. 1 + chunk.len]);
            defer self.allocator.free(leaf_cid);
            offset += chunk.len;

            // Empty name for leaves in list
            try self.appendLink(&leaf_metadata, "", leaf_cid, chunk.len);
        }

        // Step B & C: Linking
        return switch (self.layout) {
            .Balanced => try self.buildBalanced(leaf_metadata.items),
            .Linear => try self.buildLinear(leaf_metadata.items),
        };
    }

    // Helpers

    /// Appends a link holding its own copies of `name` and `cid`. On error
    /// nothing is appended and nothing leaks.
    fn appendLink(self: *DagBuilder, links: *std.ArrayList(DagLink), name: []const u8, cid: []const u8, size: u64) !void {
        try links.ensureUnusedCapacity(self.allocator, 1);
        const name_copy = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(name_copy);
        const cid_copy = try self.allocator.dupe(u8, cid);
        links.appendAssumeCapacity(.{ .name = name_copy, .cid = cid_copy, .size = size });
    }

    fn freeLinks(self: *DagBuilder, links: *std.ArrayList(DagLink)) void {
        for (links.items) |link| {
            self.allocator.free(link.name);
            self.allocator.free(link.cid);
        }
        links.deinit(self.allocator);
    }

    fn persistEmpty(self: *DagBuilder) ![]const u8 {
        // Edge case: Empty file. The root is a leaf with no data.
        return self.persistBytes(&.{@intFromEnum(codec.Tag.leaf)});
    }

    /// Implements a Balanced Tree (wide, shallow). Builds one parent layer
    /// per iteration until a single root remains.
    fn buildBalanced(self: *DagBuilder, links: []const DagLink) ![]const u8 {
        if (links.len == 0) return self.persistEmpty();

        // `links` belongs to the caller; layers built here are owned by `layer`.
        var layer: std.ArrayList(DagLink) = .empty;
        defer self.freeLinks(&layer);

        var children: []const DagLink = links;
        while (children.len > 1) {
            var parents: std.ArrayList(DagLink) = .empty;
            errdefer self.freeLinks(&parents);

            var i: usize = 0;
            while (i < children.len) {
                const end = @min(i + MAX_LINKS, children.len);
                try self.appendParent(&parents, children[i..end]);
                i = end;
            }
            std.debug.assert(parents.items.len < children.len);

            self.freeLinks(&layer);
            layer = parents;
            children = layer.items;
        }

        // A single chunk (or the converged top layer) is the root.
        return self.allocator.dupe(u8, children[0].cid);
    }

    /// Persists one parent node over `batch` and appends a link to it.
    fn appendParent(self: *DagBuilder, parents: *std.ArrayList(DagLink), batch: []const DagLink) !void {
        std.debug.assert(batch.len > 0 and batch.len <= MAX_LINKS);

        // Level is mostly debug/metadata; parents are always level 1.
        var parent = MerkleNode.init(self.allocator, try self.allocator.dupe(u8, ""), 1);
        defer parent.deinit();

        var name_buf: [32]u8 = undefined;
        for (batch, 0..) |child_link, idx| {
            const name = std.fmt.bufPrint(&name_buf, "link-{d}", .{idx}) catch unreachable;
            try self.appendLink(&parent.links, name, child_link.cid, child_link.size);
        }

        const parent_cid = try self.persist(parent);
        defer self.allocator.free(parent_cid);

        // parent.totalSize() includes its own data (0) + sum of links
        const name = std.fmt.bufPrint(&name_buf, "link-{d}", .{parents.items.len}) catch unreachable;
        try self.appendLink(parents, name, parent_cid, parent.totalSize());
    }

    /// Implements a Linear Layout (Linked List)
    fn buildLinear(self: *DagBuilder, leaf_links: []const DagLink) ![]const u8 {
        if (leaf_links.len == 0) return self.persistEmpty();

        // We iterate backwards: SpineNode[i] -> [Leaf[i], SpineNode[i+1]].
        // The leaves are already persisted, so we only build the spine.
        var next_cid: ?[]const u8 = null; // Owned.
        defer if (next_cid) |c| self.allocator.free(c);
        var next_size: u64 = 0;

        var i: usize = leaf_links.len;
        while (i > 0) {
            i -= 1;
            const current_leaf = leaf_links[i];

            var spine = MerkleNode.init(self.allocator, try self.allocator.dupe(u8, ""), 1); // Internal
            defer spine.deinit();

            // Link 1: The Data Chunk (Leaf)
            try self.appendLink(&spine.links, "data", current_leaf.cid, current_leaf.size);

            // Link 2: The Next Node (if exists)
            if (next_cid) |ncid| {
                try self.appendLink(&spine.links, "next", ncid, next_size);
            }

            const spine_cid = try self.persist(spine);
            if (next_cid) |c| self.allocator.free(c);
            next_cid = spine_cid;
            next_size = spine.totalSize();
        }

        // Transfer ownership of the root (index 0) to the caller.
        const root = next_cid.?;
        next_cid = null;
        return root;
    }

    /// Encodes and stores a parent node, returning its CID (caller-owned).
    fn persist(self: *DagBuilder, node: MerkleNode) ![]const u8 {
        std.debug.assert(node.level > 0);
        const bytes = try codec.encodeParent(self.allocator, node.links.items);
        defer self.allocator.free(bytes);
        return self.persistBytes(bytes);
    }

    /// Stores encoded block bytes and returns the raw CID bytes (caller-owned).
    fn persistBytes(self: *DagBuilder, bytes: []const u8) ![]const u8 {
        const block = Block.new(bytes);
        try self.store.put(block);
        return self.allocator.dupe(u8, &block.cid);
    }
};

test "DagBuilder build (Balanced) functionality" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const test_path = "test_storage_dag_builder_balanced";
    std.Io.Dir.cwd().deleteTree(std.Io.Threaded.global_single_threaded.io(), test_path) catch {};
    defer std.Io.Dir.cwd().deleteTree(std.Io.Threaded.global_single_threaded.io(), test_path) catch {};

    var engine = try StorageEngine.init(allocator, test_path);
    defer engine.deinit();

    var builder = DagBuilder{
        .allocator = allocator,
        .store = &engine,
        .layout = .Balanced,
    };

    const data = "This is a test string to be chunked and DAG-ified.";
    var reader = chunker.SliceReader{ .buffer = data };

    const cid = try builder.build(&reader);
    defer allocator.free(cid);

    try testing.expect(cid.len > 0);
}

test "DagBuilder build (Linear) functionality" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const test_path = "test_storage_dag_builder_linear";
    std.Io.Dir.cwd().deleteTree(std.Io.Threaded.global_single_threaded.io(), test_path) catch {};
    defer std.Io.Dir.cwd().deleteTree(std.Io.Threaded.global_single_threaded.io(), test_path) catch {};

    var engine = try StorageEngine.init(allocator, test_path);
    defer engine.deinit();

    var builder = DagBuilder{
        .allocator = allocator,
        .store = &engine,
        .layout = .Linear,
    };

    const data = "This is a test string to be chunked and DAG-ified.";
    var reader = chunker.SliceReader{ .buffer = data };

    const cid = try builder.build(&reader);
    defer allocator.free(cid);

    try testing.expect(cid.len > 0);
}

fn buildOnce(allocator: std.mem.Allocator, engine: *StorageEngine, layout: Layout, data: []const u8) !void {
    var builder = DagBuilder{ .allocator = allocator, .store = engine, .layout = layout };
    var reader = chunker.SliceReader{ .buffer = data };
    const cid = try builder.build(&reader);
    allocator.free(cid);
}

test "DagBuilder does not leak when allocation fails" {
    const testing = std.testing;
    const io = std.Io.Threaded.global_single_threaded.io();

    const test_path = "test_storage_dag_builder_oom";
    std.Io.Dir.cwd().deleteTree(io, test_path) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, test_path) catch {};

    var engine = try StorageEngine.init(testing.allocator, test_path);
    defer engine.deinit();

    // Sized to produce several leaves so both layouts build at least one internal node.
    const data = try testing.allocator.alloc(u8, chunk_params.max_size * 3);
    defer testing.allocator.free(data);
    var prng = std.Random.DefaultPrng.init(0x1234abcd);
    prng.random().bytes(data);

    for ([_]Layout{ .Balanced, .Linear }) |layout| {
        try testing.checkAllAllocationFailures(testing.allocator, buildOnce, .{ &engine, layout, data });
    }
}

test "DagBuilder balanced layout converges over multiple levels" {
    const testing = std.testing;
    const io = std.Io.Threaded.global_single_threaded.io();

    const test_path = "test_storage_dag_builder_levels";
    std.Io.Dir.cwd().deleteTree(io, test_path) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, test_path) catch {};

    var engine = try StorageEngine.init(testing.allocator, test_path);
    defer engine.deinit();

    // More than MAX_LINKS leaves forces a second parent layer.
    var cids: [MAX_LINKS + 26][32]u8 = undefined;
    var links: [MAX_LINKS + 26]DagLink = undefined;
    for (&cids, &links, 0..) |*cid, *link, i| {
        @memset(cid, @truncate(i));
        link.* = .{ .name = "", .cid = cid, .size = 1 };
    }

    const Run = struct {
        fn run(allocator: std.mem.Allocator, store: *StorageEngine, leaf_links: []const DagLink) !void {
            var builder = DagBuilder{ .allocator = allocator, .store = store, .layout = .Balanced };
            const root = try builder.buildBalanced(leaf_links);
            defer allocator.free(root);
            try testing.expectEqual(@as(usize, 32), root.len);
        }
    };
    try testing.checkAllAllocationFailures(testing.allocator, Run.run, .{ &engine, @as([]const DagLink, &links) });
}

test "DagBuilder handles an empty file" {
    const testing = std.testing;
    const io = std.Io.Threaded.global_single_threaded.io();

    const test_path = "test_storage_dag_builder_empty";
    std.Io.Dir.cwd().deleteTree(io, test_path) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, test_path) catch {};

    var engine = try StorageEngine.init(testing.allocator, test_path);
    defer engine.deinit();

    for ([_]Layout{ .Balanced, .Linear }) |layout| {
        var builder = DagBuilder{ .allocator = testing.allocator, .store = &engine, .layout = layout };
        var reader = chunker.SliceReader{ .buffer = "" };
        const cid = try builder.build(&reader);
        defer testing.allocator.free(cid);

        const block = (try engine.get(cid, testing.allocator)).?;
        defer testing.allocator.free(block.data);
        try testing.expectEqualStrings("", (try codec.decode(block.data)).leaf);
    }
}
