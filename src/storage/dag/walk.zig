//! Traversals over a DAG held in a StorageEngine. All walks use an explicit
//! stack (no recursion) and decode blocks with `codec`, so they work the same
//! for DAGs built locally and DAGs fetched from peers.

const std = @import("std");
const codec = @import("codec.zig");
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

/// Writes the file rooted at `root` to `writer` (anything with writeAll) and
/// returns its size. Every block must be present locally: check with
/// isComplete first if partial output on error is unacceptable.
pub fn readFile(allocator: std.mem.Allocator, store: *StorageEngine, root: []const u8, writer: anytype, options: ReadOptions) !u64 {
    var stack: std.ArrayList(Cid) = .empty;
    defer stack.deinit(allocator);
    try stack.append(allocator, try cidFromSlice(root));

    var total: u64 = 0;
    while (stack.pop()) |cid| {
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
