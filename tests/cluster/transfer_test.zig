const std = @import("std");
const nomadfs = @import("nomadfs");
const TestPeer = @import("test_helpers").TestPeer;
const DhtNode = nomadfs.net.discovery.Node;
const StorageEngine = nomadfs.storage.engine.StorageEngine;
const BlockManager = nomadfs.cluster.BlockManager;
const RepairManager = nomadfs.cluster.repair.RepairManager;

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

const ListWriter = struct {
    list: std.ArrayList(u8) = .empty,
    allocator: std.mem.Allocator,

    pub fn writeAll(self: *@This(), bytes: []const u8) !void {
        try self.list.appendSlice(self.allocator, bytes);
    }
};

test "cluster: put on one node, get from another, then sync only the diff" {
    std.debug.print("\n=== Running Test: cluster: put/get across nodes ===\n", .{});
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();

    const dir1 = "test_transfer_store_1";
    const dir2 = "test_transfer_store_2";
    std.Io.Dir.cwd().deleteTree(io, dir1) catch {};
    std.Io.Dir.cwd().deleteTree(io, dir2) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, dir1) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, dir2) catch {};
    var engine1 = try StorageEngine.init(allocator, dir1);
    defer engine1.deinit();
    var engine2 = try StorageEngine.init(allocator, dir2);
    defer engine2.deinit();

    var peer1 = try TestPeer.init(allocator, 13100);
    defer peer1.deinit();
    var peer2 = try TestPeer.init(allocator, 13101);
    defer peer2.deinit();

    var dht1 = DhtNode.init(allocator, peer1.manager, peer1.config.node.swarm_key);
    defer dht1.deinit();
    var dht2 = DhtNode.init(allocator, peer2.manager, peer2.config.node.swarm_key);
    defer dht2.deinit();
    dht1.block_store = &engine1;
    dht2.block_store = &engine2;
    peer1.manager.setConnectionHandler(&dht1, DhtNode.serve);
    peer2.manager.setConnectionHandler(&dht2, DhtNode.serve);
    // Stop networking before the DHT nodes are torn down.
    defer peer1.stop();
    defer peer2.stop();

    try peer1.start();
    try peer2.start();
    nomadfs.sync.sleep(100 * std.time.ns_per_ms);

    // One PING makes each node know the other (authenticated, correct port).
    {
        const conn = try peer1.manager.connectToPeer(peer2.listen_addr, peer1.config.node.swarm_key, peer2.manager.node_id);
        defer conn.deinit();
        try dht1.ping(conn);
    }
    nomadfs.sync.sleep(200 * std.time.ns_per_ms);

    const bm1 = try BlockManager.init(allocator, .{ .network = peer1.manager, .dht = &dht1, .storage = &engine1 });
    defer bm1.deinit();
    const bm2 = try BlockManager.init(allocator, .{ .network = peer2.manager, .dht = &dht2, .storage = &engine2 });
    defer bm2.deinit();

    // 1. Put a multi-chunk file on node 1 (announces node 1 as provider).
    const data_len = 3500 * 1024;
    const data = try allocator.alloc(u8, data_len);
    defer allocator.free(data);
    var prng = std.Random.DefaultPrng.init(0x99887766);
    prng.random().bytes(data);
    var reader = SliceReader{ .buffer = data };
    const root = try bm1.put(&reader);
    defer allocator.free(root);

    // 2. Node 2 has none of it; get resolves the provider and repairs.
    try std.testing.expect(!try nomadfs.storage.dag.walk.isComplete(allocator, &engine2, root));
    var out = ListWriter{ .allocator = allocator };
    defer out.list.deinit(allocator);
    const size = try bm2.get(root, &out, .{});
    try std.testing.expectEqual(@as(u64, data.len), size);
    try std.testing.expectEqualSlices(u8, data, out.list.items);
    try std.testing.expect(try nomadfs.storage.dag.walk.isComplete(allocator, &engine2, root));

    // 3. A one-byte change: syncing the new version fetches only the new
    // root and the changed leaf; the other chunks are already local.
    data[data_len / 2] +%= 1;
    var reader2 = SliceReader{ .buffer = data };
    const root2 = try bm1.put(&reader2);
    defer allocator.free(root2);

    const conn = try peer2.manager.connectToPeer(peer1.listen_addr, peer2.config.node.swarm_key, peer1.manager.node_id);
    defer conn.deinit();
    const fetched = try RepairManager.sync(allocator, &dht2, &engine2, conn, root2);
    try std.testing.expect(fetched >= 2 and fetched <= 4);

    // 4. Reads honour the size cap.
    var capped = ListWriter{ .allocator = allocator };
    defer capped.list.deinit(allocator);
    try std.testing.expectError(error.FileTooLarge, bm2.get(root2, &capped, .{ .max_bytes = 10 }));
}

test "cluster: get without a provider fails cleanly" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const dir = "test_transfer_store_3";
    std.Io.Dir.cwd().deleteTree(io, dir) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};
    var engine = try StorageEngine.init(allocator, dir);
    defer engine.deinit();

    var peer = try TestPeer.init(allocator, 13102);
    defer peer.deinit();
    var dht = DhtNode.init(allocator, peer.manager, peer.config.node.swarm_key);
    defer dht.deinit();

    const bm = try BlockManager.init(allocator, .{ .network = peer.manager, .dht = &dht, .storage = &engine });
    defer bm.deinit();

    const unknown = [_]u8{0x5A} ** 32;
    var out = ListWriter{ .allocator = allocator };
    defer out.list.deinit(allocator);
    try std.testing.expectError(error.NoProvider, bm.get(&unknown, &out, .{}));
    try std.testing.expectEqual(@as(usize, 0), out.list.items.len);

    // With no peers, publishing cannot reach the default write quorum (W=1),
    // but the blocks are kept locally.
    var reader = SliceReader{ .buffer = "solo" };
    try std.testing.expectError(error.QuorumNotReached, bm.put(&reader));

    // W = 0 makes put local-only.
    bm.quorum.W = 0;
    var reader2 = SliceReader{ .buffer = "solo" };
    const root = try bm.put(&reader2);
    defer allocator.free(root);
    const size = try bm.get(root, &out, .{});
    try std.testing.expectEqual(@as(u64, 4), size);
    try std.testing.expectEqualStrings("solo", out.list.items);
}

test "cluster: get fails over to another provider when one is offline" {
    std.debug.print("\n=== Running Test: cluster: provider failover ===\n", .{});
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();

    const dirs = [_][]const u8{ "test_failover_store_1", "test_failover_store_2", "test_failover_store_3" };
    for (dirs) |d| std.Io.Dir.cwd().deleteTree(io, d) catch {};
    defer for (dirs) |d| std.Io.Dir.cwd().deleteTree(io, d) catch {};

    var engines: [3]StorageEngine = undefined;
    for (&engines, dirs) |*e, d| e.* = try StorageEngine.init(allocator, d);
    defer for (&engines) |*e| e.deinit();

    // Node 0 and node 2 provide the file; node 1 fetches it.
    var peers: [3]TestPeer = undefined;
    for (&peers, 0..) |*p, i| p.* = try TestPeer.init(allocator, @intCast(13110 + i));
    defer for (&peers) |*p| p.deinit();

    var dhts: [3]DhtNode = undefined;
    for (&dhts, &peers, &engines) |*d, *p, *e| {
        d.* = DhtNode.init(allocator, p.manager, p.config.node.swarm_key);
        d.block_store = e;
        p.manager.setConnectionHandler(d, DhtNode.serve);
    }
    defer for (&dhts) |*d| d.deinit();
    defer for (&peers) |*p| p.stop();

    for (&peers) |*p| try p.start();
    nomadfs.sync.sleep(100 * std.time.ns_per_ms);

    // Both providers introduce themselves to node 1.
    for ([_]usize{ 0, 2 }) |i| {
        const conn = try peers[i].manager.connectToPeer(peers[1].listen_addr, peers[i].config.node.swarm_key, peers[1].manager.node_id);
        defer conn.deinit();
        try dhts[i].ping(conn);
    }
    nomadfs.sync.sleep(200 * std.time.ns_per_ms);

    var managers: [3]*BlockManager = undefined;
    for (&managers, &peers, &dhts, &engines) |*m, *p, *d, *e| {
        m.* = try BlockManager.init(allocator, .{ .network = p.manager, .dht = d, .storage = e });
    }
    defer for (managers) |m| m.deinit();

    // Node 2 announces first, so node 1 lists it first.
    const data = "replicated content " ** 1000;
    var reader2 = SliceReader{ .buffer = data };
    const root = try managers[2].put(&reader2);
    defer allocator.free(root);
    var reader0 = SliceReader{ .buffer = data };
    const root0 = try managers[0].put(&reader0);
    defer allocator.free(root0);
    try std.testing.expectEqualSlices(u8, root, root0);

    // Node 1 now knows both providers.
    const providers = try dhts[1].findProviders(.{ .bytes = root[0..32].* });
    defer allocator.free(providers);
    try std.testing.expectEqual(@as(usize, 2), providers.len);

    // Take node 2 offline; node 1 must still get the file, from node 0.
    peers[2].stop();
    nomadfs.sync.sleep(200 * std.time.ns_per_ms);

    var out = ListWriter{ .allocator = allocator };
    defer out.list.deinit(allocator);
    const size = try managers[1].get(root, &out, .{});
    try std.testing.expectEqual(@as(u64, data.len), size);
    try std.testing.expectEqualStrings(data, out.list.items);
}
