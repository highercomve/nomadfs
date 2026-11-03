//! The local swarm API: other programs of this user read and write the
//! swarm folder through the node that is running, with no mount. Locket
//! keeps its shared vault there this way; `nomadfs swarm` (swarm_cli.zig)
//! is its command line.
//!
//! HTTP on 127.0.0.1, under a random token, like the WebDAV server:
//!
//!   GET    /<token>/v1/status          {"synced", "entries", "peers_synced", "last_sync"}
//!   GET    /<token>/v1/list/<dir>      [{"name", "dir", "size", "mtime", "etag"}]
//!   GET    /<token>/v1/files/<path>    the file; ETag: "<content id>"
//!   PUT    /<token>/v1/files/<path>    the body becomes the file (8 MiB at most)
//!   DELETE /<token>/v1/files/<path>
//!
//! A PUT with `If-Match: "<etag>"` writes only while the file is still that
//! version, and with `If-None-Match: *` only while nothing is there (412
//! Precondition Failed otherwise): a writer that read the file never
//! overwrites an edit it didn't see. Until the node has synced the folder
//! with its peers once, writes answer 503 (an empty folder on a device
//! that just started isn't the swarm's). DELETE honours If-Match too.
//!
//! The running node writes `<device dir>/api.json` (owner-only) with the
//! URL and removes it when it stops; a client reads it to find the API.
//! The token is that file's secret; a connection from another account's
//! process is closed unanswered where the system can tell (webdav/peer).
//! @atlas layer: node

const std = @import("std");
const builtin = @import("builtin");
const compat = @import("net/compat.zig");
const sync = @import("sync.zig");
const swarm_mod = @import("fs/swarm.zig");
const http = @import("webdav/http.zig");
const peer = @import("webdav/peer.zig");

const SwarmFolder = swarm_mod.SwarmFolder;
const Conn = http.Conn;
const Request = http.Request;

pub const api_file = "api.json";
/// The largest file a PUT takes (the swarm folder's own limit).
pub const max_file = 8 * 1024 * 1024;
const max_connections = 16;
const idle_timeout_ms = 30_000;
/// A listing answers at most this many entries.
const max_list = 10_000;

/// What `api.json` holds.
pub const Info = struct {
    version: u32 = 1,
    /// `http://127.0.0.1:<port>/<token>/v1/`.
    url: []const u8,
};

pub const Server = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    folder: *SwarmFolder,
    /// The file the URL is published in; removed by `stop`.
    info_path: []u8,
    token: [64]u8 = undefined,
    port: u16 = 0,
    listener: ?compat.Server = null,
    running: std.atomic.Value(bool) = .init(false),
    accept_thread: ?std.Thread = null,
    /// The connections being served (closed by `stop`, which waits for them).
    conns: struct {
        mutex: sync.Mutex = .{},
        done: sync.Condition = .{},
        list: std.ArrayList(compat.Stream) = .empty,
        active: usize = 0,
    } = .{},

    /// Serves `folder` and publishes the URL in `<device_dir>/api.json`.
    pub fn start(allocator: std.mem.Allocator, folder: *SwarmFolder, device_dir: []const u8) !*Server {
        const io = std.Io.Threaded.global_single_threaded.io();
        const self = try allocator.create(Server);
        errdefer allocator.destroy(self);
        self.* = .{
            .allocator = allocator,
            .io = io,
            .folder = folder,
            .info_path = try std.fs.path.join(allocator, &.{ device_dir, api_file }),
        };
        errdefer allocator.free(self.info_path);
        var secret: [32]u8 = undefined;
        try io.randomSecure(&secret);
        self.token = std.fmt.bytesToHex(secret, .lower);
        std.crypto.secureZero(u8, &secret);

        var listener = try compat.listenLoopback(0);
        errdefer listener.deinit();
        self.port = listener.inner.socket.address.getPort();
        self.listener = listener;
        self.running.store(true, .release);
        errdefer self.running.store(false, .release);
        try self.publish();
        errdefer std.Io.Dir.cwd().deleteFile(io, self.info_path) catch {};
        self.accept_thread = try std.Thread.spawn(.{}, acceptLoop, .{self});
        return self;
    }

    /// Stops listening, ends every connection, waits for them, removes
    /// api.json and frees the server.
    pub fn stop(self: *Server) void {
        if (self.running.swap(false, .acq_rel)) {
            if (self.listener) |*l| l.deinit();
            if (self.accept_thread) |t| t.join();
            self.listener = null;
            self.conns.mutex.lock();
            for (self.conns.list.items) |c| c.shutdown();
            while (self.conns.active > 0) self.conns.done.wait(&self.conns.mutex);
            self.conns.mutex.unlock();
            self.unpublish();
        }
        self.conns.list.deinit(self.allocator);
        self.allocator.free(self.info_path);
        std.crypto.secureZero(u8, &self.token);
        self.allocator.destroy(self);
    }

    /// `http://127.0.0.1:<port>/<token>/v1/` into `buf`.
    pub fn url(self: *const Server, buf: []u8) ![]const u8 {
        return std.fmt.bufPrint(buf, "http://127.0.0.1:{d}/{s}/v1/", .{ self.port, &self.token });
    }

    /// api.json, owner-only, through a temp file and a rename.
    fn publish(self: *Server) !void {
        var url_buf: [128]u8 = undefined;
        const json = try std.json.Stringify.valueAlloc(self.allocator, Info{ .url = try self.url(&url_buf) }, .{});
        defer {
            std.crypto.secureZero(u8, json);
            self.allocator.free(json);
        }
        const tmp = try std.fmt.allocPrint(self.allocator, "{s}.tmp", .{self.info_path});
        defer self.allocator.free(tmp);
        const cwd = std.Io.Dir.cwd();
        // A leftover temp file (or a link planted in its place) is removed,
        // and the new one created afresh: it can only be 0600 and ours.
        cwd.deleteFile(self.io, tmp) catch |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        };
        {
            const f = try cwd.createFile(self.io, tmp, .{ .exclusive = true, .permissions = if (builtin.os.tag == .windows) .default_file else .fromMode(0o600) });
            errdefer cwd.deleteFile(self.io, tmp) catch {};
            defer f.close(self.io);
            try f.writeStreamingAll(self.io, json);
        }
        errdefer cwd.deleteFile(self.io, tmp) catch {};
        try cwd.rename(tmp, cwd, self.info_path, self.io);
    }

    /// Removes api.json if it is still this server's (a newer node on the
    /// same files may have replaced it).
    fn unpublish(self: *Server) void {
        const text = std.Io.Dir.cwd().readFileAlloc(self.io, self.info_path, self.allocator, .limited(4096)) catch return;
        defer {
            std.crypto.secureZero(u8, text); // it holds the token
            self.allocator.free(text);
        }
        if (std.mem.indexOf(u8, text, &self.token) == null) return;
        std.Io.Dir.cwd().deleteFile(self.io, self.info_path) catch {};
    }

    fn acceptLoop(self: *Server) void {
        while (self.running.load(.acquire)) {
            var listener = self.listener orelse return;
            const conn = listener.accept() catch |err| {
                if (!self.running.load(.acquire)) return;
                if (err == error.FileDescriptorClosed or err == error.SocketNotBound) return;
                sync.sleep(50 * std.time.ns_per_ms);
                continue;
            };
            if (!self.running.load(.acquire)) {
                conn.stream.close();
                return;
            }
            self.conns.mutex.lock();
            const room = self.conns.active < max_connections;
            const added = room and if (self.conns.list.append(self.allocator, conn.stream)) true else |_| false;
            if (added) self.conns.active += 1;
            self.conns.mutex.unlock();
            if (!added) {
                conn.stream.close();
                continue;
            }
            const t = std.Thread.spawn(.{}, serveConnection, .{ self, conn.stream, conn.address.getPort() }) catch {
                self.forget(conn.stream);
                conn.stream.close();
                continue;
            };
            t.detach();
        }
    }

    fn forget(self: *Server, stream: compat.Stream) void {
        self.conns.mutex.lock();
        defer self.conns.mutex.unlock();
        for (self.conns.list.items, 0..) |c, i| {
            if (c.inner.socket.handle == stream.inner.socket.handle) {
                _ = self.conns.list.swapRemove(i);
                break;
            }
        }
        self.conns.active -= 1;
        self.conns.done.broadcast();
    }

    /// One request per connection (the answers close it).
    fn serveConnection(self: *Server, stream: compat.Stream, client_port: u16) void {
        defer {
            self.forget(stream);
            stream.close();
        }
        // Another account's process: closed unanswered (webdav/peer.zig).
        if (peer.supported and !peer.sameUser(self.allocator, self.port, client_port)) return;
        stream.setTimeout(idle_timeout_ms) catch {};
        var arena_state = std.heap.ArenaAllocator.init(self.allocator);
        defer arena_state.deinit();
        var conn = Conn{ .stream = stream };
        self.handle(arena_state.allocator(), &conn) catch |err| {
            if (!conn.head_sent) answerError(&conn, err) catch {};
        };
    }

    fn handle(self: *Server, arena: std.mem.Allocator, conn: *Conn) !void {
        const head = try conn.readHead() orelse return;
        var req = Request.parse(arena, head) catch return conn.respond(400, "Bad Request", &close, "");
        // A web page can't reach the API through DNS rebinding.
        if (!http.localHost(req.header("host"))) return conn.respond(403, "Forbidden", &close, "");
        const segments = req.segments; // decoded and checked (no "..") by Request.parse
        if (segments.len < 3 or !tokenMatches(segments[0], &self.token) or !std.mem.eql(u8, segments[1], "v1")) {
            return conn.respond(404, "Not Found", &close, "");
        }
        const what = segments[2];
        const rest = segments[3..];
        const method = req.method;
        if (std.mem.eql(u8, what, "status") and rest.len == 0 and eql(method, "GET")) return self.status(arena, conn);
        if (std.mem.eql(u8, what, "list") and eql(method, "GET")) return self.list(arena, conn, try joinPath(arena, rest));
        if (std.mem.eql(u8, what, "files") and rest.len > 0) {
            const path = try joinPath(arena, rest);
            if (eql(method, "GET")) return self.get(arena, conn, path);
            if (eql(method, "PUT")) return self.put(arena, conn, &req, path);
            if (eql(method, "DELETE")) return self.delete(conn, &req, path);
            return conn.respond(405, "Method Not Allowed", &close, "");
        }
        return conn.respond(404, "Not Found", &close, "");
    }

    fn status(self: *Server, arena: std.mem.Allocator, conn: *Conn) !void {
        const s = self.folder.status();
        const body = try std.json.Stringify.valueAlloc(arena, .{
            .synced = !self.folder.awaitingFirstSync(),
            .entries = s.entries,
            .peers_synced = s.peers_synced,
            .last_sync = s.last_sync,
        }, .{});
        return conn.respond(200, "OK", &json_close, body);
    }

    fn list(self: *Server, arena: std.mem.Allocator, conn: *Conn, dir: []const u8) !void {
        const items = self.folder.list(arena, dir) catch |err| return answerError(conn, err);
        const Entry = struct { name: []const u8, dir: bool, size: u64, mtime: u64, etag: ?[]const u8 };
        const n = @min(items.len, max_list);
        const out = try arena.alloc(Entry, n);
        for (items[0..n], out) |it, *e| {
            // The bare content id: what If-Match takes, quoted or not.
            e.* = .{ .name = it.name, .dir = it.dir, .size = it.size, .mtime = it.mtime, .etag = if (it.cid) |c| try arena.dupe(u8, &std.fmt.bytesToHex(c, .lower)) else null };
        }
        return conn.respond(200, "OK", &json_close, try std.json.Stringify.valueAlloc(arena, out, .{}));
    }

    fn get(self: *Server, arena: std.mem.Allocator, conn: *Conn, path: []const u8) !void {
        const info = self.folder.fileInfo(path) orelse return conn.respond(404, "Not Found", &close, "");
        if (info.size > max_file) return conn.respond(413, "Content Too Large", &close, "");
        const data = try arena.alloc(u8, @intCast(info.size));
        var filled: usize = 0;
        var rounds: usize = 0;
        // readAt returns what one block covers: read until the file is whole.
        while (filled < data.len and rounds < 1 << 16) : (rounds += 1) {
            const n = try self.folder.readAt(arena, info.cid, info.author, filled, data[filled..]);
            if (n == 0) return error.Unavailable;
            filled += n;
        }
        if (filled != data.len) return error.Unavailable;
        const etag = try etagOf(arena, info.cid);
        return conn.respond(200, "OK", &.{ .{ "ETag", etag }, .{ "Content-Type", "application/octet-stream" }, .{ "Connection", "close" } }, data);
    }

    fn put(self: *Server, arena: std.mem.Allocator, conn: *Conn, req: *Request, path: []const u8) !void {
        if ((req.content_length orelse 0) > max_file) return conn.respond(413, "Content Too Large", &close, "");
        const base = baseOf(req, self.folder, path) catch return conn.respond(400, "Bad Request", &close, "");
        try conn.continueIfExpected(req);
        const body = conn.readSmallBody(arena, req, max_file) catch |err| switch (err) {
            error.BodyTooLarge => return conn.respond(413, "Content Too Large", &close, ""),
            else => return err,
        };
        const result = self.folder.putBytes(path, body, base) catch |err| return answerError(conn, err);
        const etag = try etagOf(arena, result.cid);
        return conn.respond(200, "OK", &.{ .{ "ETag", etag }, .{ "Connection", "close" } }, "");
    }

    /// Removes one file (never a folder), with `If-Match` checked under the
    /// same lock as the removal.
    fn delete(self: *Server, conn: *Conn, req: *Request, path: []const u8) !void {
        var base: ?[32]u8 = null;
        if (req.header("if-match")) |want| {
            const hex = unquote(want);
            var cid: [32]u8 = undefined;
            if (hex.len != 64) return conn.respond(400, "Bad Request", &close, "");
            _ = std.fmt.hexToBytes(&cid, hex) catch return conn.respond(400, "Bad Request", &close, "");
            base = cid;
        }
        self.folder.removeFile(path, base) catch |err| return switch (err) {
            // Nothing there for the version asked: it changed meanwhile.
            error.FileNotFound => if (base != null) conn.respond(412, "Precondition Failed", &close, "") else answerError(conn, err),
            else => answerError(conn, err),
        };
        return conn.respond(204, "No Content", &close, "");
    }
};

const close = [_][2][]const u8{.{ "Connection", "close" }};
const json_close = [_][2][]const u8{ .{ "Content-Type", "application/json" }, .{ "Connection", "close" } };

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

/// The URL's token, compared in constant time.
fn tokenMatches(given: []const u8, token: *const [64]u8) bool {
    if (given.len != token.len) return false;
    return std.crypto.timing_safe.eql([64]u8, given[0..64].*, token.*);
}

/// "a/b/c" from the URL's segments (each already checked by splitPath).
fn joinPath(arena: std.mem.Allocator, segments: []const []const u8) ![]const u8 {
    return std.mem.join(arena, "/", segments);
}

/// `"<hex cid>"`, the ETag a GET sends and a PUT's If-Match takes.
fn etagOf(arena: std.mem.Allocator, cid: [32]u8) ![]const u8 {
    const hex = std.fmt.bytesToHex(cid, .lower);
    return std.fmt.allocPrint(arena, "\"{s}\"", .{&hex});
}

fn unquote(v: []const u8) []const u8 {
    const t = std.mem.trim(u8, v, " \t");
    if (t.len >= 2 and t[0] == '"' and t[t.len - 1] == '"') return t[1 .. t.len - 1];
    return t;
}

/// The version a PUT may replace: If-Match's, nothing (If-None-Match: *),
/// or, unconditional, whatever is there now.
fn baseOf(req: *const Request, folder: *SwarmFolder, path: []const u8) !?[32]u8 {
    if (req.header("if-match")) |want| {
        const hex = unquote(want);
        if (hex.len != 64) return error.BadPrecondition;
        var cid: [32]u8 = undefined;
        _ = std.fmt.hexToBytes(&cid, hex) catch return error.BadPrecondition;
        return cid;
    }
    if (req.header("if-none-match")) |v| {
        if (!eql(std.mem.trim(u8, v, " \t"), "*")) return error.BadPrecondition;
        return null;
    }
    return if (folder.fileInfo(path)) |info| info.cid else null;
}

/// An error as the API's answer.
fn answerError(conn: *Conn, err: anyerror) !void {
    const code: u16, const text: []const u8 = switch (err) {
        error.Changed => .{ 412, "Precondition Failed" },
        error.NotSynced => .{ 503, "Not Synced Yet" },
        error.FileNotFound => .{ 404, "Not Found" },
        error.InvalidPath, error.IsDirectory => .{ 400, "Bad Request" },
        error.FileTooLarge, error.BodyTooLarge => .{ 413, "Content Too Large" },
        error.Unavailable, error.BlockNotFound, error.NoHolders => .{ 503, "Unavailable" },
        else => .{ 500, "Internal Server Error" },
    };
    return conn.respond(code, text, &.{ .{ "Connection", "close" }, .{ "X-NomadFS-Error", @errorName(err) } }, "");
}

test tokenMatches {
    const token: [64]u8 = @splat('a');
    try std.testing.expect(tokenMatches(&token, &token));
    try std.testing.expect(!tokenMatches("aaaa", &token));
    var other = token;
    other[63] = 'b';
    try std.testing.expect(!tokenMatches(&other, &token));
}

test unquote {
    try std.testing.expectEqualStrings("abc", unquote("\"abc\""));
    try std.testing.expectEqualStrings("abc", unquote(" abc "));
}
