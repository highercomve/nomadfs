//! `nomadfs swarm`: the swarm folder from the command line, through the
//! node that is running (the app or a service), with no mount. A client
//! of the local swarm API (swarm_api.zig), which the running node
//! publishes in `<device dir>/api.json`.
//!
//!     nomadfs swarm status
//!     nomadfs swarm ls [dir]
//!     nomadfs swarm get <path>                   the file on stdout
//!     nomadfs swarm put <path> [file]            from the file, or stdin
//!         --if-match <etag>   only over that version (what `ls` shows)
//!         --create            only where nothing is yet
//!     nomadfs swarm rm <path> [--if-match <etag>]
//! @atlas layer: frontend

const std = @import("std");
const nomadfs = @import("nomadfs");
const compat = nomadfs.net.compat;
const swarm_api = nomadfs.swarm_api;
const device = nomadfs.device;

const max_response = swarm_api.max_file + 64 * 1024;

/// The API's address, from api.json.
pub const Endpoint = struct {
    port: u16,
    /// `/<token>/v1/`.
    base: []const u8,

    /// From api.json's `url` (`http://127.0.0.1:<port>/<token>/v1/`).
    pub fn parse(url: []const u8) !Endpoint {
        const prefix = "http://127.0.0.1:";
        if (!std.mem.startsWith(u8, url, prefix)) return error.BadApiFile;
        const rest = url[prefix.len..];
        const slash = std.mem.indexOfScalar(u8, rest, '/') orelse return error.BadApiFile;
        return .{
            .port = std.fmt.parseInt(u16, rest[0..slash], 10) catch return error.BadApiFile,
            .base = rest[slash..],
        };
    }
};

/// Finds the running node's API from the device files (`key_path`: the
/// config's, or null for the default `~/.nomadfs`). `arena` owns it.
pub fn findEndpoint(arena: std.mem.Allocator, io: std.Io, key_path: ?[]const u8) !Endpoint {
    var paths = try device.paths.Paths.resolve(arena, key_path);
    const dir = std.fs.path.dirname(paths.identity) orelse ".";
    const file = try std.fs.path.join(arena, &.{ dir, swarm_api.api_file });
    paths.deinit(arena);
    const text = std.Io.Dir.cwd().readFileAlloc(io, file, arena, .limited(4096)) catch |err| switch (err) {
        error.FileNotFound => return error.NodeNotRunning,
        else => return err,
    };
    const info = std.json.parseFromSliceLeaky(swarm_api.Info, arena, text, .{ .ignore_unknown_fields = true }) catch return error.BadApiFile;
    return Endpoint.parse(info.url);
}

pub const Response = struct {
    code: u16,
    etag: ?[]const u8 = null,
    /// X-NomadFS-Error: the node's error name on a failure.
    err: ?[]const u8 = null,
    body: []const u8 = "",
};

/// One request: `method` on `<base><path>` with `headers` and `body`.
pub fn request(arena: std.mem.Allocator, ep: Endpoint, method: []const u8, path: []const u8, headers: []const [2][]const u8, body: []const u8) !Response {
    const addr = try std.Io.net.IpAddress.parse("127.0.0.1", ep.port);
    const stream = compat.tcpConnectToAddress(.{ .ip = addr }) catch return error.NodeNotRunning;
    defer stream.close();
    stream.setTimeout(120_000) catch {};

    var head: std.Io.Writer.Allocating = .init(arena);
    const w = &head.writer;
    try w.print("{s} {s}", .{ method, ep.base });
    try writeEncoded(w, path);
    try w.print(" HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\nContent-Length: {d}\r\n", .{body.len});
    for (headers) |h| try w.print("{s}: {s}\r\n", .{ h[0], h[1] });
    try w.writeAll("\r\n");
    try stream.writeAll(head.written());
    if (body.len > 0) try stream.writeAll(body);

    var raw: std.ArrayList(u8) = .empty;
    var buf: [64 * 1024]u8 = undefined;
    while (true) {
        const n = stream.read(&buf) catch break;
        if (n == 0) break;
        if (raw.items.len + n > max_response) return error.ResponseTooLarge;
        try raw.appendSlice(arena, buf[0..n]);
    }
    return parseResponse(raw.items);
}

/// A path's segments percent-encoded (anything but unreserved bytes).
fn writeEncoded(w: *std.Io.Writer, path: []const u8) !void {
    for (path) |c| switch (c) {
        'a'...'z', 'A'...'Z', '0'...'9', '-', '.', '_', '~', '/' => try w.writeByte(c),
        else => try w.print("%{X:0>2}", .{c}),
    };
}

fn parseResponse(raw: []const u8) !Response {
    const end = std.mem.indexOf(u8, raw, "\r\n\r\n") orelse return error.BadResponse;
    const head = raw[0..end];
    var lines = std.mem.splitSequence(u8, head, "\r\n");
    const status = lines.next() orelse return error.BadResponse;
    if (status.len < 12 or !std.mem.startsWith(u8, status, "HTTP/1.1 ")) return error.BadResponse;
    var r: Response = .{ .code = std.fmt.parseInt(u16, status[9..12], 10) catch return error.BadResponse, .body = raw[end + 4 ..] };
    while (lines.next()) |line| {
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const name = line[0..colon];
        const value = std.mem.trim(u8, line[colon + 1 ..], " ");
        if (std.ascii.eqlIgnoreCase(name, "etag")) r.etag = value;
        if (std.ascii.eqlIgnoreCase(name, "x-nomadfs-error")) r.err = value;
    }
    return r;
}

/// `nomadfs swarm <args>`; the exit code.
pub fn run(io: std.Io, arena: std.mem.Allocator, args: []const []const u8, key_path: ?[]const u8) !u8 {
    if (args.len == 0) return usage();
    const ep = findEndpoint(arena, io, key_path) catch |err| return fail(err);
    const cmd = args[0];
    const eql = std.mem.eql;
    if (eql(u8, cmd, "status")) {
        const r = request(arena, ep, "GET", "status", &.{}, "") catch |err| return fail(err);
        return printBody(io, r);
    }
    if (eql(u8, cmd, "ls")) {
        const dir = if (args.len > 1) args[1] else "";
        const r = request(arena, ep, "GET", try std.fmt.allocPrint(arena, "list/{s}", .{dir}), &.{}, "") catch |err| return fail(err);
        return printBody(io, r);
    }
    if (args.len < 2) return usage();
    const path = args[1];
    const files = try std.fmt.allocPrint(arena, "files/{s}", .{path});
    if (eql(u8, cmd, "get")) {
        const r = request(arena, ep, "GET", files, &.{}, "") catch |err| return fail(err);
        return printBody(io, r);
    }
    if (eql(u8, cmd, "put") or eql(u8, cmd, "rm")) {
        var headers: std.ArrayList([2][]const u8) = .empty;
        var source: ?[]const u8 = null;
        var i: usize = 2;
        while (i < args.len) : (i += 1) {
            if (eql(u8, args[i], "--if-match") and i + 1 < args.len) {
                i += 1;
                try headers.append(arena, .{ "If-Match", try std.fmt.allocPrint(arena, "\"{s}\"", .{std.mem.trim(u8, args[i], "\"")}) });
            } else if (eql(u8, args[i], "--create")) {
                try headers.append(arena, .{ "If-None-Match", "*" });
            } else if (source == null and eql(u8, cmd, "put")) {
                source = args[i];
            } else return usage();
        }
        const body = if (eql(u8, cmd, "rm")) "" else try readSource(io, arena, source);
        const r = request(arena, ep, if (eql(u8, cmd, "rm")) "DELETE" else "PUT", files, headers.items, body) catch |err| return fail(err);
        if (r.code >= 300) return printBody(io, r);
        if (r.etag) |e| std.debug.print("{s}\n", .{e});
        return 0;
    }
    return usage();
}

fn readSource(io: std.Io, arena: std.mem.Allocator, source: ?[]const u8) ![]u8 {
    if (source) |p| return std.Io.Dir.cwd().readFileAlloc(io, p, arena, .limited(swarm_api.max_file + 1));
    var buf: [4096]u8 = undefined;
    var stdin = std.Io.File.stdin().readerStreaming(io, &buf);
    return stdin.interface.allocRemaining(arena, .limited(swarm_api.max_file + 1));
}

fn printBody(io: std.Io, r: Response) u8 {
    if (r.code >= 300) {
        std.debug.print("nomadfs swarm: {d} {s}\n", .{ r.code, explain(r) });
        return 1;
    }
    var buf: [4096]u8 = undefined;
    var out = std.Io.File.stdout().writerStreaming(io, &buf);
    out.interface.writeAll(r.body) catch {};
    if (r.body.len > 0 and r.body[r.body.len - 1] != '\n' and std.mem.startsWith(u8, r.body, "{") or std.mem.startsWith(u8, r.body, "[")) out.interface.writeAll("\n") catch {};
    out.interface.flush() catch {};
    return 0;
}

fn explain(r: Response) []const u8 {
    return switch (r.code) {
        404 => "not found",
        412 => "the file changed (or exists) since that version",
        413 => "too large (8 MiB at most)",
        503 => if (r.err != null and std.mem.eql(u8, r.err.?, "NotSynced")) "the node hasn't synced the swarm folder yet: try again shortly" else "the file's data isn't reachable right now",
        else => r.err orelse "failed",
    };
}

fn fail(err: anyerror) u8 {
    std.debug.print("nomadfs swarm: {s}\n", .{switch (err) {
        error.NodeNotRunning => "no NomadFS node is running (start the app, or `nomadfs` as a service)",
        error.BadApiFile => "the running node's api.json is damaged",
        else => @errorName(err),
    }});
    return 1;
}

fn usage() u8 {
    std.debug.print(
        \\usage:
        \\  nomadfs swarm status
        \\  nomadfs swarm ls [dir]
        \\  nomadfs swarm get <path>
        \\  nomadfs swarm put <path> [file] [--if-match <etag> | --create]
        \\  nomadfs swarm rm <path> [--if-match <etag>]
        \\
    , .{});
    return 2;
}

test "Endpoint.parse" {
    const ep = try Endpoint.parse("http://127.0.0.1:41234/abcd/v1/");
    try std.testing.expectEqual(@as(u16, 41234), ep.port);
    try std.testing.expectEqualStrings("/abcd/v1/", ep.base);
    try std.testing.expectError(error.BadApiFile, Endpoint.parse("http://example.com:1/x/"));
}

test parseResponse {
    const r = try parseResponse("HTTP/1.1 412 Precondition Failed\r\nETag: \"ab\"\r\nX-NomadFS-Error: Changed\r\n\r\nbody");
    try std.testing.expectEqual(@as(u16, 412), r.code);
    try std.testing.expectEqualStrings("\"ab\"", r.etag.?);
    try std.testing.expectEqualStrings("Changed", r.err.?);
    try std.testing.expectEqualStrings("body", r.body);
}
