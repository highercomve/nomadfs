const std = @import("std");
const nomadfs = @import("nomadfs");
const TestPeer = @import("test_helpers").TestPeer;
const DhtNode = nomadfs.net.discovery.Node;
const StorageEngine = nomadfs.storage.engine.StorageEngine;
const BlockManager = nomadfs.cluster.BlockManager;
const SwarmFolder = nomadfs.fs.SwarmFolder;
const compat = nomadfs.net.compat;

const Response = struct {
    status: u16,
    head: []const u8,
    body: []const u8,

    fn header(self: Response, name: []const u8) ?[]const u8 {
        var lines = std.mem.splitSequence(u8, self.head, "\r\n");
        while (lines.next()) |line| {
            const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
            if (std.ascii.eqlIgnoreCase(line[0..colon], name)) return std.mem.trim(u8, line[colon + 1 ..], " ");
        }
        return null;
    }
};

/// One request on its own connection (`Connection: close`): the whole
/// response, read to the end.
fn request(arena: std.mem.Allocator, port: u16, method: []const u8, path: []const u8, extra: []const u8, body: []const u8) !Response {
    const stream = try compat.tcpConnectToAddress(compat.Address.initIp4(.{ 127, 0, 0, 1 }, port));
    defer stream.close();
    const head = try std.fmt.allocPrint(arena, "{s} {s} HTTP/1.1\r\nHost: 127.0.0.1:{d}\r\nConnection: close\r\n{s}Content-Length: {d}\r\n\r\n", .{ method, path, port, extra, body.len });
    try stream.writeAll(head);
    try stream.writeAll(body);
    return readResponse(arena, stream);
}

fn readResponse(arena: std.mem.Allocator, stream: compat.Stream) !Response {
    var all: std.ArrayList(u8) = .empty;
    var buf: [8192]u8 = undefined;
    while (true) {
        const n = try stream.read(&buf);
        if (n == 0) break;
        try all.appendSlice(arena, buf[0..n]);
    }
    const split = std.mem.indexOf(u8, all.items, "\r\n\r\n") orelse return error.BadResponse;
    const status = try std.fmt.parseInt(u16, all.items[9..12], 10);
    return .{ .status = status, .head = all.items[0..split], .body = all.items[split + 4 ..] };
}

test "webdav: the swarm folder is read-write over HTTP, the rest read-only" {
    std.debug.print("\n=== Running Test: webdav ===\n", .{});
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const cwd = std.Io.Dir.cwd();
    cwd.deleteTree(io, "test_webdav") catch {};
    defer cwd.deleteTree(io, "test_webdav") catch {};
    try cwd.createDirPath(io, "test_webdav");

    var store = try StorageEngine.init(allocator, "test_webdav");
    defer store.deinit();
    var peer = try TestPeer.init(allocator, 13197);
    defer peer.deinit();
    var dht = DhtNode.init(allocator, peer.manager, peer.config.node.swarm_key);
    defer dht.deinit();
    dht.block_store = &store;
    const folder = try SwarmFolder.create(allocator, io, &store, peer.manager.node_id, "Desk", "test_webdav/swarm.json");
    defer folder.destroy();
    dht.swarm_source = folder.source();
    peer.manager.setConnectionHandler(&dht, DhtNode.serve);
    defer peer.stop();
    try peer.start();
    const bm = try BlockManager.init(allocator, .{ .network = peer.manager, .dht = &dht, .storage = &store });
    defer bm.deinit();
    folder.block_manager = bm;

    var server = nomadfs.webdav.Server.init(allocator, bm);
    defer server.deinit();
    server.swarm = folder;
    try server.start(0);
    const port = server.port;

    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    // Discovery: it's a class 2 WebDAV server (lockable, so writable).
    const options = try request(a, port, "OPTIONS", "/", "", "");
    try std.testing.expectEqual(@as(u16, 200), options.status);
    try std.testing.expect(std.mem.indexOf(u8, options.header("DAV").?, "2") != null);

    // The root lists the swarm folder.
    const root = try request(a, port, "PROPFIND", "/", "Depth: 1\r\n", "");
    try std.testing.expectEqual(@as(u16, 207), root.status);
    try std.testing.expect(std.mem.indexOf(u8, root.body, "<D:href>/Swarm/</D:href>") != null);

    // Write a file, a folder, and a chunked upload into it.
    try std.testing.expectEqual(@as(u16, 201), (try request(a, port, "PUT", "/Swarm/hello%20world.txt", "", "hello webdav")).status);
    try std.testing.expectEqual(@as(u16, 201), (try request(a, port, "MKCOL", "/Swarm/docs", "", "")).status);
    {
        const stream = try compat.tcpConnectToAddress(compat.Address.initIp4(.{ 127, 0, 0, 1 }, port));
        defer stream.close();
        try stream.writeAll("PUT /Swarm/docs/notes.txt HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\nTransfer-Encoding: chunked\r\n\r\n" ++
            "5\r\nfirst\r\n7\r\n second\r\n0\r\n\r\n");
        try std.testing.expectEqual(@as(u16, 201), (try readResponse(a, stream)).status);
    }
    try std.testing.expectEqual(@as(u64, 12), folder.fileInfo("docs/notes.txt").?.size);

    // Read back, whole and a range.
    const got = try request(a, port, "GET", "/Swarm/hello%20world.txt", "", "");
    try std.testing.expectEqual(@as(u16, 200), got.status);
    try std.testing.expectEqualStrings("hello webdav", got.body);
    const part = try request(a, port, "GET", "/Swarm/hello%20world.txt", "Range: bytes=6-\r\n", "");
    try std.testing.expectEqual(@as(u16, 206), part.status);
    try std.testing.expectEqualStrings("webdav", part.body);

    // The listing shows sizes; desktop metadata stays out of the swarm.
    try std.testing.expectEqual(@as(u16, 201), (try request(a, port, "PUT", "/Swarm/._hello%20world.txt", "", "apple double")).status);
    try std.testing.expect(folder.fileInfo("._hello world.txt") == null);
    const listing = try request(a, port, "PROPFIND", "/Swarm", "Depth: 1\r\n", "");
    try std.testing.expect(std.mem.indexOf(u8, listing.body, "<D:getcontentlength>12</D:getcontentlength>") != null);
    try std.testing.expect(std.mem.indexOf(u8, listing.body, "/Swarm/docs/</D:href>") != null);
    try std.testing.expect(std.mem.indexOf(u8, listing.body, "._hello") == null);
    try std.testing.expectEqualStrings("apple double", (try request(a, port, "GET", "/Swarm/._hello%20world.txt", "", "")).body);

    // Move, copy, delete.
    try std.testing.expectEqual(@as(u16, 201), (try request(a, port, "MOVE", "/Swarm/hello%20world.txt", "Destination: http://127.0.0.1/Swarm/docs/moved.txt\r\n", "")).status);
    try std.testing.expectEqual(@as(u16, 404), (try request(a, port, "GET", "/Swarm/hello%20world.txt", "", "")).status);
    try std.testing.expectEqual(@as(u16, 201), (try request(a, port, "COPY", "/Swarm/docs/moved.txt", "Destination: /Swarm/copy.txt\r\n", "")).status);
    try std.testing.expectEqualStrings("hello webdav", (try request(a, port, "GET", "/Swarm/copy.txt", "", "")).body);
    try std.testing.expectEqual(@as(u16, 412), (try request(a, port, "MOVE", "/Swarm/copy.txt", "Destination: /Swarm/docs/moved.txt\r\nOverwrite: F\r\n", "")).status);
    try std.testing.expectEqual(@as(u16, 204), (try request(a, port, "DELETE", "/Swarm/docs", "", "")).status);
    try std.testing.expectEqual(@as(u16, 404), (try request(a, port, "PROPFIND", "/Swarm/docs", "Depth: 0\r\n", "")).status);
    try std.testing.expect(folder.fileInfo("docs/notes.txt") == null);

    // Locks for writers; nothing outside the swarm folder is writable.
    const locked = try request(a, port, "LOCK", "/Swarm/copy.txt", "", "<?xml version=\"1.0\"?><D:lockinfo xmlns:D=\"DAV:\"/>");
    try std.testing.expectEqual(@as(u16, 200), locked.status);
    try std.testing.expect(locked.header("Lock-Token") != null);
    try std.testing.expectEqual(@as(u16, 403), (try request(a, port, "PUT", "/Phone/Camera/x.jpg", "", "x")).status);
    try std.testing.expectEqual(@as(u16, 403), (try request(a, port, "MKCOL", "/NewDevice", "", "")).status);

    // A web page reaching it through another host name is refused.
    const stream = try compat.tcpConnectToAddress(compat.Address.initIp4(.{ 127, 0, 0, 1 }, port));
    defer stream.close();
    try stream.writeAll("GET /Swarm/copy.txt HTTP/1.1\r\nHost: evil.example\r\nConnection: close\r\n\r\n");
    try std.testing.expectEqual(@as(u16, 403), (try readResponse(a, stream)).status);
}
