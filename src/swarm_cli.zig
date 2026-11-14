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
//!     nomadfs swarm photos [--folder <dir>] [--limit <n>] [--videos | --photos]
//!                                                pictures and films, newest first
//!     nomadfs swarm thumb <path> > t.jpg         a small JPEG of a picture
//! @atlas layer: frontend

const std = @import("std");
const builtin = @import("builtin");
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
        const base = rest[slash..];
        // It goes into the request line as is: no spaces or control bytes
        // that could add headers or a second request.
        if (!std.mem.endsWith(u8, base, "/")) return error.BadApiFile;
        for (base) |c| if (c <= ' ' or c >= 0x7f) return error.BadApiFile;
        return .{
            .port = std.fmt.parseInt(u16, rest[0..slash], 10) catch return error.BadApiFile,
            .base = base,
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
    // The node writes it 0600: one another user could read or plant isn't
    // trusted (it would get the files sent to it).
    const st = std.Io.Dir.cwd().statFile(io, file, .{ .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound => return error.NodeNotRunning,
        else => return err,
    };
    if (st.kind != .file) return error.InsecureApiFile;
    if (comptime builtin.os.tag != .windows) {
        if (st.permissions.toMode() & 0o077 != 0) return error.InsecureApiFile;
    }
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
    return send(arena, ep, method, path, "", headers, body);
}

/// `request` with a query: `query` is what follows the `?`, its values
/// already encoded (`writeEncoded`); "" for none.
fn send(arena: std.mem.Allocator, ep: Endpoint, method: []const u8, path: []const u8, query: []const u8, headers: []const [2][]const u8, body: []const u8) !Response {
    const addr = try std.Io.net.IpAddress.parse("127.0.0.1", ep.port);
    const stream = compat.tcpConnectToAddress(.{ .ip = addr }) catch return error.NodeNotRunning;
    defer stream.close();
    stream.setTimeout(120_000) catch {};

    var head: std.Io.Writer.Allocating = .init(arena);
    const w = &head.writer;
    try w.print("{s} {s}", .{ method, ep.base });
    try writeEncoded(w, path);
    if (query.len > 0) try w.print("?{s}", .{query});
    try w.print(" HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\nContent-Length: {d}\r\n", .{body.len});
    for (headers) |h| try w.print("{s}: {s}\r\n", .{ h[0], h[1] });
    try w.writeAll("\r\n");
    try stream.writeAll(head.written());
    if (body.len > 0) try stream.writeAll(body);

    var raw: std.ArrayList(u8) = .empty;
    var buf: [64 * 1024]u8 = undefined;
    while (true) {
        // A failed read (the timeout, the node stopping) is an error, not
        // the end of the answer.
        const n = stream.read(&buf) catch return error.ReadFailed;
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
        if (std.ascii.eqlIgnoreCase(name, "content-length")) {
            // Shorter than announced: the node stopped mid-answer.
            const want = std.fmt.parseInt(usize, value, 10) catch return error.BadResponse;
            if (want != r.body.len) return error.TruncatedResponse;
        }
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
        return printBody(io, r, true);
    }
    if (eql(u8, cmd, "ls")) {
        const dir = if (args.len > 1) args[1] else "";
        const r = request(arena, ep, "GET", try std.fmt.allocPrint(arena, "list/{s}", .{dir}), &.{}, "") catch |err| return fail(err);
        return printBody(io, r, true);
    }
    if (eql(u8, cmd, "photos")) return photos(io, arena, ep, args[1..]);
    if (args.len < 2) return usage();
    const path = args[1];
    const files = try std.fmt.allocPrint(arena, "files/{s}", .{path});
    if (eql(u8, cmd, "thumb")) {
        if (args.len != 2) return usage();
        const r = request(arena, ep, "GET", try std.fmt.allocPrint(arena, "thumb/{s}", .{path}), &.{}, "") catch |err| return fail(err);
        return printBody(io, r, false);
    }
    if (eql(u8, cmd, "get")) {
        const r = request(arena, ep, "GET", files, &.{}, "") catch |err| return fail(err);
        return printBody(io, r, false);
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
        if (r.code >= 300) return printBody(io, r, false);
        if (r.etag) |e| std.debug.print("{s}\n", .{e});
        return 0;
    }
    return usage();
}

/// What `photos` reads of a page (the API's JSON, swarm_api.zig).
const PhotosPage = struct {
    generation: u64,
    total: u32,
    items: []const struct { path: []const u8, size: u64, mtime: u64, kind: []const u8 },
};

/// How many `photos` lists without `--limit`.
const default_photos = 100;
/// The pages one `photos` asks for at most (a million items).
const max_photo_pages = 2000;

/// `nomadfs swarm photos`: the timeline's first `--limit` items, one a
/// line, asked for a page at a time as of the first page's generation.
fn photos(io: std.Io, arena: std.mem.Allocator, ep: Endpoint, args: []const []const u8) !u8 {
    const eql = std.mem.eql;
    var folder: []const u8 = "";
    var kinds: []const u8 = "all";
    var limit: u32 = default_photos;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (eql(u8, args[i], "--folder") and i + 1 < args.len) {
            i += 1;
            folder = args[i];
        } else if (eql(u8, args[i], "--limit") and i + 1 < args.len) {
            i += 1;
            limit = std.fmt.parseInt(u32, args[i], 10) catch return usage();
        } else if (eql(u8, args[i], "--videos")) {
            kinds = "videos";
        } else if (eql(u8, args[i], "--photos")) {
            kinds = "photos";
        } else return usage();
    }
    var buf: [4096]u8 = undefined;
    var out = std.Io.File.stdout().writerStreaming(io, &buf);
    const w = &out.interface;
    var generation: u64 = 0;
    var listed: u32 = 0;
    var pages: usize = 0;
    while (listed < limit and pages < max_photo_pages) : (pages += 1) {
        var query: std.Io.Writer.Allocating = .init(arena);
        try query.writer.writeAll("folder=");
        try writeEncoded(&query.writer, folder);
        try query.writer.print("&kinds={s}&generation={d}&start={d}&count={d}", .{ kinds, generation, listed, limit - listed });
        const r = send(arena, ep, "GET", "photos", query.written(), &.{}, "") catch |err| return fail(err);
        if (r.code >= 300) {
            w.flush() catch {};
            return printBody(io, r, false);
        }
        const page = std.json.parseFromSliceLeaky(PhotosPage, arena, r.body, .{ .ignore_unknown_fields = true }) catch return fail(error.BadResponse);
        generation = page.generation;
        if (page.items.len == 0) break;
        for (page.items) |item| {
            var when: [16]u8 = undefined;
            w.print("{s}  {s: <5}  {d: >12}  {s}\n", .{ minuteOf(&when, item.mtime), item.kind, item.size, item.path }) catch {};
        }
        listed += @intCast(page.items.len); // a page has at most `count` items
    }
    w.flush() catch {};
    return 0;
}

/// `YYYY-MM-DD HH:MM` (UTC) of a time in seconds.
fn minuteOf(buf: *[16]u8, seconds: u64) []const u8 {
    // A time past the year 9999 (a damaged entry) has no such form.
    if (seconds > 253_402_300_799) return "????-??-?? ??:??";
    const es = std.time.epoch.EpochSeconds{ .secs = seconds };
    const day = es.getEpochDay().calculateYearDay();
    const month = day.calculateMonthDay();
    const clock = es.getDaySeconds();
    return std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}", .{
        day.year,                month.month.numeric(),      @as(u8, month.day_index) + 1,
        clock.getHoursIntoDay(), clock.getMinutesIntoHour(),
    }) catch "????-??-?? ??:??";
}

fn readSource(io: std.Io, arena: std.mem.Allocator, source: ?[]const u8) ![]u8 {
    if (source) |p| return std.Io.Dir.cwd().readFileAlloc(io, p, arena, .limited(swarm_api.max_file + 1));
    var buf: [4096]u8 = undefined;
    var stdin = std.Io.File.stdin().readerStreaming(io, &buf);
    return stdin.interface.allocRemaining(arena, .limited(swarm_api.max_file + 1));
}

/// The answer on stdout; `newline`: end JSON with one (status, ls). A
/// file (`get`) is written exactly as it is.
fn printBody(io: std.Io, r: Response, newline: bool) u8 {
    if (r.code >= 300) {
        std.debug.print("nomadfs swarm: {d} {s}\n", .{ r.code, explain(r) });
        return 1;
    }
    var buf: [4096]u8 = undefined;
    var out = std.Io.File.stdout().writerStreaming(io, &buf);
    out.interface.writeAll(r.body) catch {};
    if (newline and r.body.len > 0 and r.body[r.body.len - 1] != '\n') out.interface.writeAll("\n") catch {};
    out.interface.flush() catch {};
    return 0;
}

fn explain(r: Response) []const u8 {
    const err = r.err orelse "";
    return switch (r.code) {
        404 => if (std.mem.eql(u8, err, "NoThumbnail")) "no thumbnail can be made of this file (a format NomadFS doesn't decode, or a damaged picture)" else "not found",
        409 => "the folder changed while it was listed: run it again",
        412 => "the file changed (or exists) since that version",
        413 => "too large (8 MiB at most)",
        503 => if (std.mem.eql(u8, err, "NotSynced"))
            "the node hasn't synced the swarm folder yet: try again shortly"
        else if (std.mem.eql(u8, err, "Pending"))
            "the thumbnail is being made: try again shortly"
        else
            "the file's data isn't reachable right now",
        else => r.err orelse "failed",
    };
}

fn fail(err: anyerror) u8 {
    std.debug.print("nomadfs swarm: {s}\n", .{switch (err) {
        error.NodeNotRunning => "no NomadFS node is running (start the app, or `nomadfs` as a service)",
        error.BadApiFile => "the running node's api.json is damaged",
        error.InsecureApiFile => "api.json is readable by other users or isn't a plain file: not trusted (restart the node)",
        error.TruncatedResponse, error.ReadFailed => "the node's answer was cut short (it stopped, or timed out): try again",
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
        \\  nomadfs swarm photos [--folder <dir>] [--limit <n>] [--videos | --photos]
        \\  nomadfs swarm thumb <path> > thumb.jpg
        \\
    , .{});
    return 2;
}

test explain {
    try std.testing.expectEqualStrings("not found", explain(.{ .code = 404, .err = "FileNotFound" }));
    try std.testing.expect(std.mem.startsWith(u8, explain(.{ .code = 404, .err = "NoThumbnail" }), "no thumbnail"));
    try std.testing.expect(std.mem.startsWith(u8, explain(.{ .code = 503, .err = "Pending" }), "the thumbnail is being made"));
    try std.testing.expect(std.mem.startsWith(u8, explain(.{ .code = 503 }), "the file's data"));
    try std.testing.expectEqualStrings("Boom", explain(.{ .code = 500, .err = "Boom" }));
}

test "Endpoint.parse" {
    const ep = try Endpoint.parse("http://127.0.0.1:41234/abcd/v1/");
    try std.testing.expectEqual(@as(u16, 41234), ep.port);
    try std.testing.expectEqualStrings("/abcd/v1/", ep.base);
    try std.testing.expectError(error.BadApiFile, Endpoint.parse("http://example.com:1/x/"));
    try std.testing.expectError(error.BadApiFile, Endpoint.parse("http://127.0.0.1:1/x/v1/ HTTP/1.1\r\nX: y\r\n/"));
    try std.testing.expectError(error.BadApiFile, Endpoint.parse("http://127.0.0.1:1/x/v1"));
}

test minuteOf {
    var buf: [16]u8 = undefined;
    try std.testing.expectEqualStrings("1970-01-01 00:00", minuteOf(&buf, 0));
    try std.testing.expectEqualStrings("2023-11-14 22:13", minuteOf(&buf, 1_700_000_000));
    try std.testing.expectEqualStrings("2024-02-29 23:59", minuteOf(&buf, 1_709_251_199));
    try std.testing.expectEqualStrings("9999-12-31 23:59", minuteOf(&buf, 253_402_300_799));
    try std.testing.expectEqualStrings("????-??-?? ??:??", minuteOf(&buf, std.math.maxInt(u64)));
}

test parseResponse {
    const r = try parseResponse("HTTP/1.1 412 Precondition Failed\r\nETag: \"ab\"\r\nX-NomadFS-Error: Changed\r\n\r\nbody");
    try std.testing.expectEqual(@as(u16, 412), r.code);
    try std.testing.expectEqualStrings("\"ab\"", r.etag.?);
    try std.testing.expectEqualStrings("Changed", r.err.?);
    try std.testing.expectEqualStrings("body", r.body);
    try std.testing.expectError(error.TruncatedResponse, parseResponse("HTTP/1.1 200 OK\r\nContent-Length: 10\r\n\r\nbody"));
    try std.testing.expectEqualStrings("body", (try parseResponse("HTTP/1.1 200 OK\r\nContent-Length: 4\r\n\r\nbody")).body);
}
