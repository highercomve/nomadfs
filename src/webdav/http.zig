//! The HTTP/1.1 the WebDAV server speaks: request heads, bodies (sized or
//! chunked), responses, and the paths and ranges in them. std.http.Server
//! accepts only the standard methods, not WebDAV's.

const std = @import("std");
const compat = @import("../net/compat.zig");

/// Request line and headers.
pub const max_head = 16 * 1024;

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

/// The Host header names this machine's loopback (any port), or is absent
/// (HTTP/1.0).
pub fn localHost(host: ?[]const u8) bool {
    const h = host orelse return true;
    const name = if (std.mem.startsWith(u8, h, "[")) h[0 .. (std.mem.indexOfScalar(u8, h, ']') orelse h.len - 1) + 1] else if (std.mem.lastIndexOfScalar(u8, h, ':')) |c| h[0..c] else h;
    return eql(name, "127.0.0.1") or std.ascii.eqlIgnoreCase(name, "localhost") or eql(name, "[::1]");
}

pub const Request = struct {
    method: []const u8,
    /// Decoded path segments (no empty ones).
    segments: []const []const u8,
    head: []const u8,
    content_length: ?u64 = null,
    chunked: bool = false,
    body_done: bool = false,

    pub fn parse(arena: std.mem.Allocator, head: []const u8) !Request {
        const line_end = std.mem.indexOf(u8, head, "\r\n") orelse return error.BadRequest;
        var parts = std.mem.splitScalar(u8, head[0..line_end], ' ');
        const method = parts.next() orelse return error.BadRequest;
        const target = parts.next() orelse return error.BadRequest;
        var req = Request{
            .method = try arena.dupe(u8, method),
            .segments = try splitPath(arena, targetPath(target)) orelse return error.BadRequest,
            // A copy: reading a chunked body reuses the connection's buffer.
            .head = try arena.dupe(u8, head),
        };
        if (req.header("content-length")) |v| req.content_length = std.fmt.parseInt(u64, std.mem.trim(u8, v, " "), 10) catch return error.BadRequest;
        if (req.header("transfer-encoding")) |v| req.chunked = std.ascii.indexOfIgnoreCase(v, "chunked") != null;
        if (!req.chunked and (req.content_length orelse 0) == 0) req.body_done = true;
        return req;
    }

    /// A header's value (case-insensitive name), trimmed.
    pub fn header(self: *const Request, name: []const u8) ?[]const u8 {
        var lines = std.mem.splitSequence(u8, self.head, "\r\n");
        _ = lines.next();
        while (lines.next()) |line| {
            const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
            if (std.ascii.eqlIgnoreCase(std.mem.trim(u8, line[0..colon], " "), name)) return std.mem.trim(u8, line[colon + 1 ..], " \t");
        }
        return null;
    }
};

/// The path of a request target or Destination header: an absolute URL's
/// path, without a query.
pub fn targetPath(target: []const u8) []const u8 {
    var t = target;
    if (std.mem.indexOf(u8, t, "://")) |i| {
        const after = t[i + 3 ..];
        t = if (std.mem.indexOfScalar(u8, after, '/')) |s| after[s..] else "/";
    }
    if (std.mem.indexOfScalar(u8, t, '?')) |q| t = t[0..q];
    return t;
}

/// Decoded, non-empty segments; null for `.`/`..` or a bad escape.
pub fn splitPath(arena: std.mem.Allocator, path: []const u8) !?[]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, path, '/');
    while (it.next()) |raw| {
        if (raw.len == 0) continue;
        const seg = try arena.alloc(u8, raw.len);
        var n: usize = 0;
        var i: usize = 0;
        while (i < raw.len) : (i += 1) {
            if (raw[i] == '%') {
                if (i + 2 >= raw.len) return null;
                seg[n] = std.fmt.parseInt(u8, raw[i + 1 .. i + 3], 16) catch return null;
                i += 2;
            } else seg[n] = raw[i];
            n += 1;
        }
        const s = seg[0..n];
        if (eql(s, ".") or eql(s, "..") or std.mem.indexOfScalar(u8, s, 0) != null or std.mem.indexOfScalar(u8, s, '/') != null) return null;
        try out.append(arena, s);
    }
    return out.items;
}

/// `bytes=a-b`, `bytes=a-` or `bytes=-n` against `size`: [start, end).
pub fn parseRange(value: []const u8, size: u64) ?[2]u64 {
    if (!std.mem.startsWith(u8, value, "bytes=")) return null;
    const spec = value["bytes=".len..];
    if (std.mem.indexOfScalar(u8, spec, ',') != null) return null;
    const dash = std.mem.indexOfScalar(u8, spec, '-') orelse return null;
    const a = std.mem.trim(u8, spec[0..dash], " ");
    const b = std.mem.trim(u8, spec[dash + 1 ..], " ");
    if (a.len == 0) {
        const n = std.fmt.parseInt(u64, b, 10) catch return null;
        if (n == 0 or size == 0) return null;
        return .{ size - @min(n, size), size };
    }
    const start = std.fmt.parseInt(u64, a, 10) catch return null;
    if (start >= size) return null;
    const end = if (b.len == 0) size else (std.fmt.parseInt(u64, b, 10) catch return null) +| 1;
    if (end <= start) return null;
    return .{ start, @min(end, size) };
}

pub const Conn = struct {
    stream: compat.Stream,
    buf: [max_head]u8 = undefined,
    start: usize = 0,
    end: usize = 0,
    /// Bytes left in the current chunk (chunked bodies).
    chunk_left: u64 = 0,
    body_left: u64 = 0,
    /// A response head went out for the current request.
    head_sent: bool = false,

    fn fill(self: *Conn) !bool {
        if (self.start > 0) {
            std.mem.copyForwards(u8, self.buf[0 .. self.end - self.start], self.buf[self.start..self.end]);
            self.end -= self.start;
            self.start = 0;
        }
        if (self.end == self.buf.len) return error.HeadTooLarge;
        const n = self.stream.read(self.buf[self.end..]) catch return false;
        if (n == 0) return false;
        self.end += n;
        return true;
    }

    /// The next request's head (up to and with the blank line), or null at
    /// the end of the connection. Valid until the next read.
    pub fn readHead(self: *Conn) !?[]const u8 {
        while (true) {
            if (std.mem.indexOf(u8, self.buf[self.start..self.end], "\r\n\r\n")) |i| {
                const head = self.buf[self.start .. self.start + i + 4];
                self.start += i + 4;
                return head;
            }
            if (!try self.fill()) return null;
        }
    }

    pub const BodyReader = struct {
        conn: *Conn,
        req: *Request,

        /// Up to `dest.len` body bytes; 0 at its end.
        pub fn read(self: *BodyReader, dest: []u8) !usize {
            const c = self.conn;
            if (self.req.body_done) return 0;
            if (self.req.chunked) {
                if (c.chunk_left == 0) {
                    const size_line = try c.line();
                    const hex_end = std.mem.indexOfAny(u8, size_line, "; ") orelse size_line.len;
                    c.chunk_left = std.fmt.parseInt(u64, size_line[0..hex_end], 16) catch return error.BadRequest;
                    if (c.chunk_left == 0) {
                        // Trailers, then the blank line.
                        while ((try c.line()).len > 0) {}
                        self.req.body_done = true;
                        return 0;
                    }
                }
                const n = try c.take(dest[0..@intCast(@min(dest.len, c.chunk_left))]);
                c.chunk_left -= n;
                if (c.chunk_left == 0) _ = try c.line(); // the chunk's CRLF
                return n;
            }
            if (c.body_left == 0) c.body_left = self.req.content_length orelse 0;
            const n = try c.take(dest[0..@intCast(@min(dest.len, c.body_left))]);
            c.body_left -= n;
            if (c.body_left == 0) self.req.body_done = true;
            return n;
        }
    };

    pub fn bodyReader(self: *Conn, req: *Request) BodyReader {
        self.body_left = 0;
        self.chunk_left = 0;
        return .{ .conn = self, .req = req };
    }

    /// Buffered bytes first, then the socket; at least one byte.
    fn take(self: *Conn, dest: []u8) !usize {
        if (dest.len == 0) return 0;
        if (self.start == self.end) {
            const n = try self.stream.read(dest);
            if (n == 0) return error.EndOfStream;
            return n;
        }
        const n = @min(dest.len, self.end - self.start);
        @memcpy(dest[0..n], self.buf[self.start .. self.start + n]);
        self.start += n;
        return n;
    }

    /// One CRLF-terminated line, without the CRLF.
    fn line(self: *Conn) ![]const u8 {
        while (true) {
            if (std.mem.indexOf(u8, self.buf[self.start..self.end], "\r\n")) |i| {
                const l = self.buf[self.start .. self.start + i];
                self.start += i + 2;
                return l;
            }
            if (!try self.fill()) return error.EndOfStream;
        }
    }

    pub fn discardBody(self: *Conn, req: *Request) !void {
        var reader = self.bodyReader(req);
        var scratch: [4096]u8 = undefined;
        while (try reader.read(&scratch) > 0) {}
    }

    pub fn readSmallBody(self: *Conn, arena: std.mem.Allocator, req: *Request, limit: usize) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        var reader = self.bodyReader(req);
        var scratch: [4096]u8 = undefined;
        while (true) {
            const n = try reader.read(&scratch);
            if (n == 0) break;
            if (out.items.len + n > limit) return error.BodyTooLarge;
            try out.appendSlice(arena, scratch[0..n]);
        }
        return out.items;
    }

    /// `Expect: 100-continue`: tells the client to send the body now
    /// rather than after its own wait (a second, for curl).
    pub fn continueIfExpected(self: *Conn, req: *const Request) !void {
        if (req.body_done) return;
        const expect = req.header("expect") orelse return;
        if (!std.ascii.eqlIgnoreCase(expect, "100-continue")) return;
        try self.stream.writeAll("HTTP/1.1 100 Continue\r\n\r\n");
    }

    pub fn writeHead(self: *Conn, code: u16, text: []const u8, headers: []const [2][]const u8) !void {
        self.head_sent = true;
        var buf: [2048]u8 = undefined;
        var w: std.Io.Writer = .fixed(&buf);
        try w.print("HTTP/1.1 {d} {s}\r\n", .{ code, text });
        for (headers) |h| try w.print("{s}: {s}\r\n", .{ h[0], h[1] });
        try w.writeAll("\r\n");
        try self.stream.writeAll(w.buffered());
    }

    pub fn respond(self: *Conn, code: u16, text: []const u8, headers: []const [2][]const u8, body: []const u8) !void {
        var len_buf: [24]u8 = undefined;
        var all: [8][2][]const u8 = undefined;
        @memcpy(all[0..headers.len], headers);
        all[headers.len] = .{ "Content-Length", try std.fmt.bufPrint(&len_buf, "{d}", .{body.len}) };
        try self.writeHead(code, text, all[0 .. headers.len + 1]);
        if (body.len > 0) try self.stream.writeAll(body);
    }
};

test parseRange {
    try std.testing.expectEqual([2]u64{ 0, 100 }, parseRange("bytes=0-", 100).?);
    try std.testing.expectEqual([2]u64{ 10, 20 }, parseRange("bytes=10-19", 100).?);
    try std.testing.expectEqual([2]u64{ 90, 100 }, parseRange("bytes=-10", 100).?);
    try std.testing.expectEqual([2]u64{ 50, 100 }, parseRange("bytes=50-500", 100).?);
    try std.testing.expect(parseRange("bytes=100-", 100) == null);
    try std.testing.expect(parseRange("bytes=0-1,5-6", 100) == null);
}

test splitPath {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const s = (try splitPath(a, "/Swarm/a%20b/c.txt")).?;
    try std.testing.expectEqual(@as(usize, 3), s.len);
    try std.testing.expectEqualStrings("a b", s[1]);
    try std.testing.expect(try splitPath(a, "/Swarm/../x") == null);
    try std.testing.expect(try splitPath(a, "/Swarm/a%2Fb") == null);
    try std.testing.expectEqualStrings("/Swarm/x", targetPath("http://127.0.0.1:8080/Swarm/x?y=1"));
}

test localHost {
    try std.testing.expect(localHost("127.0.0.1:4918"));
    try std.testing.expect(localHost("localhost"));
    try std.testing.expect(localHost(null));
    try std.testing.expect(!localHost("evil.example:4918"));
    try std.testing.expect(!localHost("127.0.0.1.evil.example"));
}
