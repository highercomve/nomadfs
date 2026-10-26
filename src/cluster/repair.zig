const std = @import("std");
const network = @import("../net/transport/mod.zig");
const dht = @import("../net/discovery/mod.zig");
const storage = @import("../storage/mod.zig");
const codec = storage.dag.codec;
const walk = storage.dag.walk;

pub const RepairManager = struct {
    /// Upper bound on distinct blocks visited in one sync. A peer can only
    /// serve blocks matching their CIDs, but a valid DAG can still be huge.
    pub const max_blocks = 1 << 20;

    /// Fetches every block of the DAG rooted at `root_cid` that is missing
    /// locally from `peer`, verifying each against its CID before storing it.
    /// Blocks already present are not re-fetched (their children are still
    /// checked). Returns the number of blocks fetched.
    pub fn sync(
        allocator: std.mem.Allocator,
        node: *dht.Node,
        store: *storage.engine.StorageEngine,
        peer: network.Connection,
        root_cid: []const u8,
    ) !usize {
        std.debug.assert(peer.ptr != null);

        var stack: std.ArrayList(codec.Cid) = .empty;
        defer stack.deinit(allocator);
        var visited: walk.CidSet = .empty;
        defer visited.deinit(allocator);
        try stack.append(allocator, try walk.cidFromSlice(root_cid));

        var fetched: usize = 0;
        while (stack.pop()) |cid| {
            if ((try visited.getOrPut(allocator, cid)).found_existing) continue;
            if (visited.count() > max_blocks) return error.DagTooLarge;

            const data = try loadOrFetch(allocator, node, store, peer, cid, &fetched);
            defer allocator.free(data);
            switch (try codec.decode(data)) {
                .leaf => {},
                .parent => |links| try walk.pushChildren(allocator, &stack, links),
            }
        }
        return fetched;
    }

    /// Sends every locally held block of the DAG rooted at `root_cid` to
    /// `peer`, which verifies each block against its CID before storing it.
    /// Blocks the receiver already has are simply acknowledged. A locally
    /// incomplete DAG aborts the push instead of replicating partial content.
    /// Returns the number of blocks transferred.
    pub fn push(
        allocator: std.mem.Allocator,
        node: *dht.Node,
        store: *storage.engine.StorageEngine,
        peer: network.Connection,
        root_cid: []const u8,
    ) !usize {
        std.debug.assert(peer.ptr != null);

        var cids = try walk.collectReachable(allocator, store, root_cid);
        defer cids.deinit(allocator);

        var sent: usize = 0;
        var it = cids.keyIterator();
        while (it.next()) |cid| {
            const block = (try store.get(cid, allocator)) orelse return error.IncompleteDag;
            defer allocator.free(block.data);
            const stored = try node.putBlock(peer, block.cid, block.data);
            if (stored) sent += 1;
        }
        return sent;
    }

    /// Returns the block's bytes (caller-owned), fetching and storing it
    /// first if it is not held locally.
    fn loadOrFetch(
        allocator: std.mem.Allocator,
        node: *dht.Node,
        store: *storage.engine.StorageEngine,
        peer: network.Connection,
        cid: codec.Cid,
        fetched: *usize,
    ) ![]u8 {
        if (try store.get(&cid, allocator)) |block| return @constCast(block.data);

        // fetchBlock allocates with the node's allocator.
        const remote = (try node.fetchBlock(peer, cid)) orelse return error.BlockNotFound;
        defer node.allocator.free(remote);

        // put() rejects bytes that do not hash to `cid`.
        try store.put(.{ .cid = cid, .data = remote });
        fetched.* += 1;
        return allocator.dupe(u8, remote);
    }
};
