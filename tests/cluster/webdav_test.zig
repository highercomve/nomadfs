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

/// The server's path prefix (`/<token>`), set once it starts.
var root: []const u8 = "";

/// One request on its own connection (`Connection: close`), to `path`
/// under the server's root: the whole response, read to the end.
fn request(arena: std.mem.Allocator, port: u16, method: []const u8, path: []const u8, extra: []const u8, body: []const u8) !Response {
    return requestAt(arena, port, method, try std.fmt.allocPrint(arena, "{s}{s}", .{ root, path }), extra, body);
}

/// Like `request`, with `target` as given (no root in front).
fn requestAt(arena: std.mem.Allocator, port: u16, method: []const u8, target: []const u8, extra: []const u8, body: []const u8) !Response {
    const stream = try compat.tcpConnectToAddress(compat.Address.initIp4(.{ 127, 0, 0, 1 }, port));
    defer stream.close();
    const head = try std.fmt.allocPrint(arena, "{s} {s} HTTP/1.1\r\nHost: 127.0.0.1:{d}\r\nConnection: close\r\n{s}Content-Length: {d}\r\n\r\n", .{ method, target, port, extra, body.len });
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
    root = &server.root;
    defer root = "";

    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    // Without the token nothing is served; OPTIONS still answers.
    try std.testing.expectEqual(@as(u16, 404), (try requestAt(a, port, "PROPFIND", "/", "Depth: 1\r\n", "")).status);
    try std.testing.expectEqual(@as(u16, 404), (try requestAt(a, port, "PUT", "/Swarm/x.txt", "", "x")).status);
    try std.testing.expectEqual(@as(u16, 200), (try requestAt(a, port, "OPTIONS", "/", "", "")).status);
    const wrong = try std.fmt.allocPrint(a, "/{s}/Swarm/", .{"0" ** 32});
    try std.testing.expectEqual(@as(u16, 404), (try requestAt(a, port, "PROPFIND", wrong, "Depth: 0\r\n", "")).status);

    // Discovery: it's a class 2 WebDAV server (lockable, so writable).
    const options = try request(a, port, "OPTIONS", "/", "", "");
    try std.testing.expectEqual(@as(u16, 200), options.status);
    try std.testing.expect(std.mem.indexOf(u8, options.header("DAV").?, "2") != null);

    // The root lists the swarm folder.
    const listed_root = try request(a, port, "PROPFIND", "/", "Depth: 1\r\n", "");
    try std.testing.expectEqual(@as(u16, 207), listed_root.status);
    try std.testing.expect(std.mem.indexOf(u8, listed_root.body, try std.fmt.allocPrint(a, "<D:href>{s}/Swarm/</D:href>", .{root})) != null);
    try std.testing.expect(std.mem.indexOf(u8, listed_root.body, try std.fmt.allocPrint(a, "<D:href>{s}/</D:href>", .{root})) != null);

    // Write a file, a folder, and a chunked upload into it.
    try std.testing.expectEqual(@as(u16, 201), (try request(a, port, "PUT", "/Swarm/hello%20world.txt", "", "hello webdav")).status);
    try std.testing.expectEqual(@as(u16, 201), (try request(a, port, "MKCOL", "/Swarm/docs", "", "")).status);
    {
        const stream = try compat.tcpConnectToAddress(compat.Address.initIp4(.{ 127, 0, 0, 1 }, port));
        defer stream.close();
        try stream.writeAll(try std.fmt.allocPrint(a, "PUT {s}/Swarm/docs/notes.txt HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\nTransfer-Encoding: chunked\r\n\r\n" ++
            "5\r\nfirst\r\n7\r\n second\r\n0\r\n\r\n", .{root}));
        try std.testing.expectEqual(@as(u16, 201), (try readResponse(a, stream)).status);
    }
    try std.testing.expectEqual(@as(u64, 12), folder.fileInfo("docs/notes.txt").?.size);
    // Headers read after a chunked body that arrives later than the head
    // (the connection's buffer is reused for it): Depth 0 is still seen.
    {
        const stream = try compat.tcpConnectToAddress(compat.Address.initIp4(.{ 127, 0, 0, 1 }, port));
        defer stream.close();
        try stream.writeAll(try std.fmt.allocPrint(a, "PROPFIND {s}/Swarm/ HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\nDepth: 0\r\nTransfer-Encoding: chunked\r\n\r\n", .{root}));
        nomadfs.sync.sleep(100 * std.time.ns_per_ms);
        // Longer than the head, so it would cover the Depth line.
        try stream.writeAll("400\r\n" ++ ("<!-- -->" ** 128) ++ "\r\n0\r\n\r\n");
        const listed = try readResponse(a, stream);
        try std.testing.expectEqual(@as(u16, 207), listed.status);
        try std.testing.expect(std.mem.indexOf(u8, listed.body, "notes") == null and std.mem.indexOf(u8, listed.body, "docs") == null);
    }
    // A file never replaces a folder.
    try std.testing.expectEqual(@as(u16, 405), (try request(a, port, "PUT", "/Swarm/docs", "", "not a folder")).status);
    try std.testing.expect(folder.fileInfo("docs") == null);
    try std.testing.expect(folder.fileInfo("docs/notes.txt") != null);

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
    // Metadata and files don't turn into each other.
    try std.testing.expectEqual(@as(u16, 403), (try request(a, port, "MOVE", "/Swarm/._hello%20world.txt", try std.fmt.allocPrint(a, "Destination: {s}/Swarm/meta.txt\r\n", .{root}), "")).status);
    try std.testing.expectEqual(@as(u16, 403), (try request(a, port, "MOVE", "/Swarm/hello%20world.txt", try std.fmt.allocPrint(a, "Destination: {s}/Swarm/desktop.ini\r\n", .{root}), "")).status);
    try std.testing.expect(folder.fileInfo("hello world.txt") != null);
    // A client waiting for 100 Continue gets it before sending the body.
    {
        const stream = try compat.tcpConnectToAddress(compat.Address.initIp4(.{ 127, 0, 0, 1 }, port));
        defer stream.close();
        try stream.writeAll(try std.fmt.allocPrint(a, "PUT {s}/Swarm/waited.txt HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\nExpect: 100-continue\r\nContent-Length: 4\r\n\r\n", .{root}));
        var interim: [25]u8 = undefined;
        var filled: usize = 0;
        while (filled < interim.len) filled += try stream.read(interim[filled..]);
        try std.testing.expectEqualStrings("HTTP/1.1 100 Continue\r\n\r\n", &interim);
        try stream.writeAll("wait");
        try std.testing.expectEqual(@as(u16, 201), (try readResponse(a, stream)).status);
    }

    // Move, copy, delete.
    try std.testing.expectEqual(@as(u16, 201), (try request(a, port, "MOVE", "/Swarm/hello%20world.txt", try std.fmt.allocPrint(a, "Destination: http://127.0.0.1{s}/Swarm/docs/moved.txt\r\n", .{root}), "")).status);
    try std.testing.expectEqual(@as(u16, 404), (try request(a, port, "GET", "/Swarm/hello%20world.txt", "", "")).status);
    const to_copy = try std.fmt.allocPrint(a, "Destination: {s}/Swarm/copy.txt\r\n", .{root});
    try std.testing.expectEqual(@as(u16, 201), (try request(a, port, "COPY", "/Swarm/docs/moved.txt", to_copy, "")).status);
    try std.testing.expectEqualStrings("hello webdav", (try request(a, port, "GET", "/Swarm/copy.txt", "", "")).body);
    // Over an existing file: replaced in place.
    try std.testing.expectEqual(@as(u16, 201), (try request(a, port, "PUT", "/Swarm/other.txt", "", "other")).status);
    try std.testing.expectEqual(@as(u16, 204), (try request(a, port, "COPY", "/Swarm/other.txt", to_copy, "")).status);
    try std.testing.expectEqualStrings("other", (try request(a, port, "GET", "/Swarm/copy.txt", "", "")).body);
    try std.testing.expectEqual(@as(u16, 403), (try request(a, port, "COPY", "/Swarm/copy.txt", to_copy, "")).status);
    // A destination outside the server's root is refused.
    try std.testing.expectEqual(@as(u16, 403), (try request(a, port, "COPY", "/Swarm/copy.txt", "Destination: /Swarm/stray.txt\r\n", "")).status);
    try std.testing.expectEqual(@as(u16, 412), (try request(a, port, "MOVE", "/Swarm/copy.txt", try std.fmt.allocPrint(a, "Destination: {s}/Swarm/docs/moved.txt\r\nOverwrite: F\r\n", .{root}), "")).status);
    try std.testing.expectEqual(@as(u16, 201), (try request(a, port, "PUT", "/Swarm/docs/._moved.txt", "", "meta")).status);
    try std.testing.expectEqual(@as(u16, 204), (try request(a, port, "DELETE", "/Swarm/docs", "", "")).status);
    // The folder's desktop metadata goes with it.
    try std.testing.expectEqual(@as(u16, 404), (try request(a, port, "GET", "/Swarm/docs/._moved.txt", "", "")).status);
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
    try stream.writeAll(try std.fmt.allocPrint(a, "GET {s}/Swarm/copy.txt HTTP/1.1\r\nHost: evil.example\r\nConnection: close\r\n\r\n", .{root}));
    try std.testing.expectEqual(@as(u16, 403), (try readResponse(a, stream)).status);
}
