//! A WebDAV server on 127.0.0.1 showing what the FUSE mount shows, for
//! the systems without FUSE (macOS, Windows): Finder ("Connect to Server")
//! and Explorer ("Map network drive") mount WebDAV with no driver.
//!
//!   /<token>/Swarm/<path...>             the swarm folder: read and write
//!   /<token>/<device>/<share>/<path...>  every reachable device's shares: read only
//!
//! The token is random for each start and is in the URL the mount uses.
//! Other accounts on the machine can reach 127.0.0.1 too, and on macOS
//! they can read the URL (the mount table shows it): where the system can
//! tell (Linux, macOS), a connection from another user's process is closed
//! unanswered (webdav/peer.zig).
//!
//! Devices come from devices.Directory, the same list and names as the FUSE
//! mount. Writes go through the swarm folder's own edits (addFileAt,
//! makeDir, remove, move), so they spread like any other change. A PUT is
//! written to a staging file first and added once complete.
//!
//! LOCK and PROPPATCH are answered without doing anything (clients mount
//! read-only without them); the metadata files desktops write next to
//! everything (`._*`, `.DS_Store`, `Thumbs.db`, `desktop.ini`) stay in
//! memory (a bounded number of them) and never reach the swarm. The Host
//! header must be the loopback address, so a web page can't reach the
//! server through DNS rebinding.

const std = @import("std");
const cluster = @import("cluster/mod.zig");
const compat = @import("net/compat.zig");
const sync = @import("sync.zig");
const tree = @import("fs/tree.zig");
const remote_mod = @import("fs/remote.zig");
const swarm_mod = @import("fs/swarm.zig");
const devices_mod = @import("fs/devices.zig");
const ReadAhead = @import("fs/readahead.zig").ReadAhead;
const env = @import("env.zig");
const http = @import("webdav/http.zig");
const xml = @import("webdav/xml.zig");
const peer = @import("webdav/peer.zig");
const Conn = http.Conn;
const Request = http.Request;

const swarm_name = "Swarm";
/// PROPFIND, LOCK and PROPPATCH bodies are read and ignored past this.
const max_small_body = 64 * 1024;
/// A desktop metadata file kept in memory, and all of them together: past
/// these, older ones are dropped (they only hold Finder's and Explorer's
/// own metadata).
const max_scratch = 1024 * 1024;
const max_scratch_files = 4096;
const max_scratch_bytes = 16 * 1024 * 1024;
/// Connections served at once; more are closed when accepted.
const max_connections = 64;
const chunk_len = 256 * 1024;
const idle_timeout_ms = 60_000;

pub const Server = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    block_manager: ?*cluster.BlockManager,
    directory: devices_mod.Directory,
    swarm: ?*swarm_mod.SwarmFolder = null,
    read_ahead: ?*ReadAhead = null,

    listener: ?compat.Server = null,
    port: u16 = 0,
    /// The URL's first path segment (hex of 16 random bytes).
    token: [32]u8 = undefined,
    /// `/<token>`, the root of every href.
    root: [33]u8 = undefined,
    accept_thread: ?std.Thread = null,
    running: std.atomic.Value(bool) = .init(false),
    /// Open connections, so stop() can end them.
    conns: struct {
        mutex: sync.Mutex = .{},
        list: std.ArrayList(compat.Stream) = .empty,
        active: u32 = 0,
        done: sync.Condition = .{},
    } = .{},
    /// Desktop metadata files, by path.
    scratch: struct {
        mutex: sync.Mutex = .{},
        files: std.StringHashMapUnmanaged([]u8) = .empty,
        bytes: usize = 0,
    } = .{},
    next_lock: std.atomic.Value(u64) = .init(1),
    /// NOMADFS_WEBDAV_LOG set: each request and its status on stderr.
    log_requests: bool = false,
    next_staging: std.atomic.Value(u64) = .init(1),

    pub fn init(allocator: std.mem.Allocator, block_manager: ?*cluster.BlockManager) Server {
        const io = std.Io.Threaded.global_single_threaded.io();
        return .{
            .allocator = allocator,
            .io = io,
            .block_manager = block_manager,
            .directory = devices_mod.Directory.init(allocator, block_manager),
            .log_requests = logRequested(),
        };
    }

    pub fn deinit(self: *Server) void {
        self.stop();
        self.directory.deinit();
        var it = self.scratch.files.iterator();
        while (it.next()) |e| {
            self.allocator.free(e.key_ptr.*);
            self.allocator.free(e.value_ptr.*);
        }
        self.scratch.files.deinit(self.allocator);
        self.conns.list.deinit(self.allocator);
    }

    /// Listens on 127.0.0.1:`port` (0: any free port; see `port`), under
    /// a new random token.
    pub fn start(self: *Server, port: u16) !void {
        if (self.listener != null) return;
        var secret: [16]u8 = undefined;
        try self.io.randomSecure(&secret);
        self.token = std.fmt.bytesToHex(secret, .lower);
        self.root[0] = '/';
        @memcpy(self.root[1..], &self.token);
        var listener = try compat.listenLoopback(port);
        errdefer listener.deinit();
        self.port = listener.inner.socket.address.getPort();
        self.listener = listener;
        errdefer self.listener = null;
        self.running.store(true, .release);
        errdefer self.running.store(false, .release);
        if (self.swarm) |s| s.cleanStaging();
        try self.directory.start();
        errdefer self.directory.stop();
        self.accept_thread = try std.Thread.spawn(.{}, acceptLoop, .{self});
    }

    /// Stops listening, ends every connection and waits for them.
    pub fn stop(self: *Server) void {
        if (!self.running.swap(false, .acq_rel)) return;
        if (self.listener) |*l| l.deinit();
        if (self.accept_thread) |t| t.join();
        self.accept_thread = null;
        self.listener = null;
        {
            self.conns.mutex.lock();
            defer self.conns.mutex.unlock();
            for (self.conns.list.items) |c| c.shutdown();
            while (self.conns.active > 0) self.conns.done.wait(&self.conns.mutex);
        }
        // Last: a request still running may list the devices.
        self.directory.stop();
    }

    /// `http://127.0.0.1:<port>/<token>/`, into `buf`.
    pub fn url(self: *const Server, buf: []u8) ![]const u8 {
        return std.fmt.bufPrint(buf, "http://127.0.0.1:{d}/{s}/", .{ self.port, &self.token });
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

    fn serveConnection(self: *Server, stream: compat.Stream, client_port: u16) void {
        defer {
            self.forget(stream);
            stream.close();
        }
        // Another account's process: closed unanswered (see peer.zig).
        if (peer.supported and !peer.sameUser(self.allocator, self.port, client_port)) {
            if (self.log_requests) std.debug.print("webdav: refused a connection from another user (port {d})\n", .{client_port});
            return;
        }
        stream.setTimeout(idle_timeout_ms) catch {};
        var conn = Conn{ .stream = stream };
        while (self.running.load(.acquire)) {
            var arena_state = std.heap.ArenaAllocator.init(self.allocator);
            defer arena_state.deinit();
            const keep = self.handleOne(arena_state.allocator(), &conn) catch return;
            if (!keep) return;
        }
    }

    /// One request; false when the connection should close.
    fn handleOne(self: *Server, arena: std.mem.Allocator, conn: *Conn) !bool {
        const head = try conn.readHead() orelse return false;
        var req = Request.parse(arena, head) catch {
            try conn.respond(400, "Bad Request", &.{}, "");
            return false;
        };
        if (!http.localHost(req.header("host"))) {
            try conn.discardBody(&req);
            try conn.respond(403, "Forbidden", &.{}, "");
            return false;
        }
        const keep = !std.ascii.eqlIgnoreCase(req.header("connection") orelse "", "close");
        // Without the token only OPTIONS is answered: it says nothing of
        // what is served.
        req.segments = self.underRoot(req.segments) orelse {
            try conn.discardBody(&req);
            if (eql(req.method, "OPTIONS")) return self.options(conn, keep);
            try conn.respond(404, "Not Found", &.{}, "");
            return keep;
        };
        if (self.log_requests) std.debug.print("webdav: {s} /{s} depth={s}\n", .{ req.method, try std.mem.join(arena, "/", req.segments), req.header("depth") orelse "-" });
        conn.head_sent = false;
        self.dispatch(arena, conn, &req) catch |err| {
            // The body may be unread: the connection can't be reused.
            const status = statusOf(err);
            if (self.log_requests) std.debug.print("webdav: -> {d} ({s})\n", .{ status.code, @errorName(err) });
            // Once a response has begun, closing is the only way to say it
            // failed: a status line now would land inside the body.
            if (!conn.head_sent) conn.respond(status.code, status.text, &.{}, "") catch {};
            return false;
        };
        return keep;
    }

    fn dispatch(self: *Server, arena: std.mem.Allocator, conn: *Conn, req: *Request) !void {
        const m = req.method;
        if (eql(m, "OPTIONS")) {
            try conn.discardBody(req);
            _ = try self.options(conn, true);
            return;
        }
        if (eql(m, "PROPFIND")) return self.propfind(arena, conn, req);
        if (eql(m, "GET") or eql(m, "HEAD")) return self.get(arena, conn, req, eql(m, "HEAD"));
        if (eql(m, "PUT")) return self.put(arena, conn, req);
        if (eql(m, "MKCOL")) return self.mkcol(arena, conn, req);
        if (eql(m, "DELETE")) return self.delete(arena, conn, req);
        if (eql(m, "MOVE") or eql(m, "COPY")) return self.moveOrCopy(arena, conn, req, eql(m, "COPY"));
        if (eql(m, "LOCK")) return self.lock(arena, conn, req);
        if (eql(m, "UNLOCK")) {
            try conn.discardBody(req);
            return conn.respond(204, "No Content", &.{}, "");
        }
        if (eql(m, "PROPPATCH")) return self.proppatch(arena, conn, req);
        try conn.discardBody(req);
        return conn.respond(405, "Method Not Allowed", &.{}, "");
    }

    fn options(_: *Server, conn: *Conn, keep: bool) !bool {
        try conn.respond(200, "OK", &.{
            .{ "DAV", "1, 2" },
            .{ "MS-Author-Via", "DAV" },
            .{ "Allow", "OPTIONS, GET, HEAD, PUT, DELETE, MKCOL, MOVE, COPY, PROPFIND, PROPPATCH, LOCK, UNLOCK" },
        }, "");
        return keep;
    }

    /// `segments` without the token in front, or null when it isn't there.
    fn underRoot(self: *const Server, segments: []const []const u8) ?[]const []const u8 {
        if (segments.len == 0 or segments[0].len != self.token.len) return null;
        if (!std.crypto.timing_safe.eql([32]u8, segments[0][0..32].*, self.token)) return null;
        return segments[1..];
    }

    // ---- The namespace ----

    const Node = union(enum) {
        root,
        device: u32,
        /// A share's folder (its root or one inside it).
        share_dir: struct { device: u32, cid: tree.Cid, mtime: u64 },
        share_file: struct { device: u32, cid: tree.Cid, size: u64, mtime: u64 },
        /// "" is the swarm folder itself.
        swarm_dir: struct { path: []const u8, mtime: u64 },
        swarm_file: struct { path: []const u8, info: swarm_mod.SwarmFolder.Info },
        scratch: struct { path: []const u8, size: u64 },

        /// A file's size (0 for anything else).
        fn size(n: Node) u64 {
            return switch (n) {
                .share_file => |f| f.size,
                .swarm_file => |f| f.info.size,
                .scratch => |f| f.size,
                else => 0,
            };
        }

        fn isDir(n: Node) bool {
            return switch (n) {
                .root, .device, .share_dir, .swarm_dir => true,
                else => false,
            };
        }
    };

    /// What `segments` names, or null.
    fn resolve(self: *Server, arena: std.mem.Allocator, segments: []const []const u8) !?Node {
        if (segments.len == 0) return .root;
        if (eql(segments[0], swarm_name)) {
            const folder = self.swarm orelse return null;
            const path = try std.mem.join(arena, "/", segments[1..]);
            if (path.len == 0) return .{ .swarm_dir = .{ .path = "", .mtime = 0 } };
            if (isScratchName(segments[segments.len - 1])) {
                const size = self.scratchSize(path) orelse return null;
                return .{ .scratch = .{ .path = path, .size = size } };
            }
            if (folder.fileInfo(path)) |info| return .{ .swarm_file = .{ .path = path, .info = info } };
            // A folder: listed in its parent.
            const slash = std.mem.lastIndexOfScalar(u8, path, '/');
            const parent = if (slash) |s| path[0..s] else "";
            const name = if (slash) |s| path[s + 1 ..] else path;
            for (try folder.list(arena, parent)) |it| {
                if (it.dir and eql(it.name, name)) return .{ .swarm_dir = .{ .path = path, .mtime = it.mtime } };
            }
            return null;
        }
        self.directory.ensureFresh();
        const device = self.directory.find(segments[0]) orelse return null;
        if (segments.len == 1) return .{ .device = device };
        const share = for (try self.directory.shares(arena, device)) |s| {
            if (eql(s.name, segments[1])) break s;
        } else return null;
        var node: Node = .{ .share_dir = .{ .device = device, .cid = share.cid, .mtime = share.mtime } };
        const remote = self.directory.remote(device) orelse return null;
        for (segments[2..]) |name| {
            const dir = switch (node) {
                .share_dir => |d| d,
                else => return null,
            };
            const listing = try tree.listDir(arena, remote.loader(), &dir.cid);
            node = for (listing.entries) |e| {
                if (!eql(e.name, name)) continue;
                break if (e.kind == .dir)
                    .{ .share_dir = .{ .device = device, .cid = e.cid, .mtime = e.mtime } }
                else
                    .{ .share_file = .{ .device = device, .cid = e.cid, .size = e.size, .mtime = e.mtime } };
            } else return null;
        }
        return node;
    }

    const Child = struct { name: []const u8, node: Node };

    fn children(self: *Server, arena: std.mem.Allocator, node: Node) ![]Child {
        var out: std.ArrayList(Child) = .empty;
        switch (node) {
            .root => {
                if (self.swarm != null) try out.append(arena, .{ .name = swarm_name, .node = .{ .swarm_dir = .{ .path = "", .mtime = 0 } } });
                self.directory.ensureFresh();
                for (try self.directory.online(arena)) |d| try out.append(arena, .{ .name = d.name, .node = .{ .device = d.index } });
            },
            .device => |index| for (try self.directory.shares(arena, index)) |s| {
                try out.append(arena, .{ .name = s.name, .node = .{ .share_dir = .{ .device = index, .cid = s.cid, .mtime = s.mtime } } });
            },
            .share_dir => |d| {
                const remote = self.directory.remote(d.device) orelse return out.items;
                const listing = try tree.listDir(arena, remote.loader(), &d.cid);
                for (listing.entries) |e| try out.append(arena, .{ .name = e.name, .node = if (e.kind == .dir)
                    .{ .share_dir = .{ .device = d.device, .cid = e.cid, .mtime = e.mtime } }
                else
                    .{ .share_file = .{ .device = d.device, .cid = e.cid, .size = e.size, .mtime = e.mtime } } });
            },
            .swarm_dir => |d| {
                const folder = self.swarm orelse return out.items;
                for (try folder.list(arena, d.path)) |it| try out.append(arena, .{ .name = it.name, .node = if (it.dir)
                    .{ .swarm_dir = .{ .path = it.path, .mtime = it.mtime } }
                else
                    .{ .swarm_file = .{ .path = it.path, .info = .{ .cid = it.cid orelse [_]u8{0} ** 32, .size = it.size, .mtime = it.mtime, .author = it.author_id orelse [_]u8{0} ** 32 } } } });
            },
            else => {},
        }
        return out.items;
    }

    /// The swarm folder path a request writes (`/Swarm/<path>`), or null
    /// for anything else (read only).
    fn swarmPath(arena: std.mem.Allocator, segments: []const []const u8) !?[]const u8 {
        if (segments.len < 2 or !eql(segments[0], swarm_name)) return null;
        return try std.mem.join(arena, "/", segments[1..]);
    }

    // ---- Methods ----

    fn propfind(self: *Server, arena: std.mem.Allocator, conn: *Conn, req: *Request) !void {
        try conn.discardBody(req);
        const node = try self.resolve(arena, req.segments) orelse return conn.respond(404, "Not Found", &.{}, "");
        const depth = req.header("depth") orelse "1";
        var body: std.Io.Writer.Allocating = .init(arena);
        const w = &body.writer;
        try w.writeAll("<?xml version=\"1.0\" encoding=\"utf-8\"?>\n<D:multistatus xmlns:D=\"DAV:\">\n");
        const name = if (req.segments.len > 0) req.segments[req.segments.len - 1] else "NomadFS";
        try writeResponse(w, &self.root, req.segments, null, name, node);
        if (!eql(depth, "0") and node.isDir()) {
            for (try self.children(arena, node)) |c| try writeResponse(w, &self.root, req.segments, c.name, c.name, c.node);
        }
        try w.writeAll("</D:multistatus>\n");
        try conn.respond(207, "Multi-Status", &.{.{ "Content-Type", "application/xml; charset=utf-8" }}, body.written());
    }

    fn get(self: *Server, arena: std.mem.Allocator, conn: *Conn, req: *Request, head_only: bool) !void {
        try conn.discardBody(req);
        const node = try self.resolve(arena, req.segments) orelse return conn.respond(404, "Not Found", &.{}, "");
        if (node.isDir()) return conn.respond(200, "OK", &.{.{ "Content-Type", "text/plain" }}, if (head_only) "" else "A folder: mount it with WebDAV.\n");
        if (node == .scratch) {
            const bytes = try self.scratchCopy(arena, node.scratch.path) orelse return conn.respond(404, "Not Found", &.{}, "");
            return conn.respond(200, "OK", &.{.{ "Content-Type", "application/octet-stream" }}, if (head_only) "" else bytes);
        }
        const size = node.size();
        const mtime: u64 = switch (node) {
            .share_file => |f| f.mtime,
            .swarm_file => |f| f.info.mtime,
            else => unreachable,
        };
        var first: u64 = 0;
        var end: u64 = size; // exclusive
        var partial = false;
        if (req.header("range")) |r| if (http.parseRange(r, size)) |range| {
            first = range[0];
            end = range[1];
            partial = true;
        } else {
            var cr_buf: [64]u8 = undefined;
            return conn.respond(416, "Range Not Satisfiable", &.{.{ "Content-Range", try std.fmt.bufPrint(&cr_buf, "bytes */{d}", .{size}) }}, "");
        };
        var date_buf: [40]u8 = undefined;
        var len_buf: [24]u8 = undefined;
        var cr_buf: [80]u8 = undefined;
        var headers: [5][2][]const u8 = undefined;
        var n: usize = 0;
        headers[n] = .{ "Content-Type", xml.contentType(req.segments[req.segments.len - 1]) };
        n += 1;
        headers[n] = .{ "Content-Length", try std.fmt.bufPrint(&len_buf, "{d}", .{end - first}) };
        n += 1;
        headers[n] = .{ "Last-Modified", xml.httpDate(&date_buf, mtime) };
        n += 1;
        headers[n] = .{ "Accept-Ranges", "bytes" };
        n += 1;
        if (partial) {
            headers[n] = .{ "Content-Range", try std.fmt.bufPrint(&cr_buf, "bytes {d}-{d}/{d}", .{ first, end -| 1, size }) };
            n += 1;
        }
        try conn.writeHead(if (partial) 206 else 200, if (partial) "Partial Content" else "OK", headers[0..n]);
        if (head_only) return;
        const buf = try arena.alloc(u8, chunk_len);
        var at = first;
        while (at < end) {
            const want = buf[0..@intCast(@min(buf.len, end - at))];
            const got = try self.readNode(node, at, want);
            if (got == 0) return error.EndOfStream;
            try conn.stream.writeAll(want[0..got]);
            at += got;
        }
    }

    fn readNode(self: *Server, node: Node, offset: u64, dest: []u8) !usize {
        switch (node) {
            .swarm_file => |f| {
                const folder = self.swarm orelse return error.FileNotFound;
                return folder.readAt(self.allocator, f.info.cid, f.info.author, offset, dest);
            },
            .share_file => |f| {
                const remote = self.directory.remote(f.device) orelse return error.FileNotFound;
                const bm = remote.block_manager orelse return error.PeerDown;
                return remote_mod.readShareAt(self.allocator, bm, self.read_ahead, remote.peer, f.cid, offset, dest);
            },
            else => return error.IsDir,
        }
    }

    fn put(self: *Server, arena: std.mem.Allocator, conn: *Conn, req: *Request) !void {
        const path = try swarmPath(arena, req.segments) orelse {
            try conn.discardBody(req);
            return conn.respond(403, "Forbidden", &.{}, "");
        };
        const folder = self.swarm orelse return error.FileNotFound;
        const name = req.segments[req.segments.len - 1];
        if (isScratchName(name)) {
            try conn.continueIfExpected(req);
            const bytes = try conn.readSmallBody(arena, req, max_scratch);
            try self.scratchPut(path, bytes);
            return conn.respond(201, "Created", &.{}, "");
        }
        const target = try self.resolve(arena, req.segments);
        if (target != null and target.?.isDir()) {
            // A file never replaces a folder (RFC 4918: PUT on a collection).
            try conn.discardBody(req);
            return conn.respond(405, "Method Not Allowed", &.{}, "");
        }
        try conn.continueIfExpected(req);
        var body = conn.bodyReader(req);
        const staging = try self.stage(arena, folder, .{ .body = &body });
        defer self.unstage(staging);
        const at = swarm_mod.SwarmFolder.splitParent(path);
        try folder.addFileAt(at.dir, at.name, staging, null);
        return respondWritten(conn, target != null);
    }

    fn mkcol(self: *Server, arena: std.mem.Allocator, conn: *Conn, req: *Request) !void {
        try conn.discardBody(req);
        const path = try swarmPath(arena, req.segments) orelse return conn.respond(403, "Forbidden", &.{}, "");
        const folder = self.swarm orelse return error.FileNotFound;
        if (try self.resolve(arena, req.segments) != null) return conn.respond(405, "Method Not Allowed", &.{}, "");
        const at = swarm_mod.SwarmFolder.splitParent(path);
        try folder.makeDir(at.dir, at.name);
        return conn.respond(201, "Created", &.{}, "");
    }

    fn delete(self: *Server, arena: std.mem.Allocator, conn: *Conn, req: *Request) !void {
        try conn.discardBody(req);
        const path = try swarmPath(arena, req.segments) orelse return conn.respond(403, "Forbidden", &.{}, "");
        const folder = self.swarm orelse return error.FileNotFound;
        if (isScratchName(req.segments[req.segments.len - 1])) {
            self.scratchDelete(path);
            return conn.respond(204, "No Content", &.{}, "");
        }
        try folder.remove(path);
        self.scratchDeleteUnder(path);
        return conn.respond(204, "No Content", &.{}, "");
    }

    fn moveOrCopy(self: *Server, arena: std.mem.Allocator, conn: *Conn, req: *Request, copy: bool) !void {
        try conn.discardBody(req);
        const dest_header = req.header("destination") orelse return conn.respond(400, "Bad Request", &.{}, "");
        const dest_all = try http.splitPath(arena, http.targetPath(dest_header)) orelse return conn.respond(400, "Bad Request", &.{}, "");
        const dest_segments = self.underRoot(dest_all) orelse return conn.respond(403, "Forbidden", &.{}, "");
        const to = try swarmPath(arena, dest_segments) orelse return conn.respond(403, "Forbidden", &.{}, "");
        const folder = self.swarm orelse return error.FileNotFound;
        const overwrite = !eql(req.header("overwrite") orelse "T", "F");
        const source = try self.resolve(arena, req.segments) orelse return conn.respond(404, "Not Found", &.{}, "");
        if (samePath(req.segments, dest_segments)) return conn.respond(403, "Forbidden", &.{}, "");
        const dest = try self.resolve(arena, dest_segments);
        const existed = dest != null;
        if (existed and !overwrite) return conn.respond(412, "Precondition Failed", &.{}, "");
        // Metadata stays metadata and files stay files: a file renamed to
        // `._x` would leave the swarm, and `._x` renamed to a file would
        // vanish from both.
        if ((source == .scratch) != isScratchName(dest_segments[dest_segments.len - 1])) return conn.respond(403, "Forbidden", &.{}, "");
        if (source == .scratch) {
            const bytes = try self.scratchCopy(arena, source.scratch.path) orelse return conn.respond(404, "Not Found", &.{}, "");
            try self.scratchPut(to, bytes);
            if (!copy) self.scratchDelete(source.scratch.path);
            return conn.respond(201, "Created", &.{}, "");
        }
        if (!copy) {
            const from = try swarmPath(arena, req.segments) orelse return conn.respond(403, "Forbidden", &.{}, "");
            try folder.move(from, to, .{ .replace = overwrite });
            self.scratchDeleteUnder(from);
            return respondWritten(conn, existed);
        }
        // COPY: a file's bytes into a new swarm file (from the swarm or a share).
        if (source.isDir()) return conn.respond(403, "Forbidden", &.{}, "");
        // The bytes first: the destination stays as it was if reading fails.
        const staging = try self.stage(arena, folder, .{ .node = source });
        defer self.unstage(staging);
        // A file replaces a file in place; a folder in the way goes first
        // (RFC 4918: the destination is deleted before the copy).
        if (dest != null and dest.?.isDir()) try folder.remove(to);
        const at = swarm_mod.SwarmFolder.splitParent(to);
        try folder.addFileAt(at.dir, at.name, staging, null);
        return respondWritten(conn, existed);
    }

    const StageSource = union(enum) {
        /// A request's body.
        body: *Conn.BodyReader,
        /// A file served here (the swarm folder's or a share's).
        node: Node,
    };

    /// Writes `source` to a new staging file of the swarm folder; returns
    /// its path. Remove it with `unstage` once added (or on failure).
    fn stage(self: *Server, arena: std.mem.Allocator, folder: *swarm_mod.SwarmFolder, source: StageSource) ![]const u8 {
        const staging_dir = try folder.stagingDir(arena);
        const staging = try std.fmt.allocPrint(arena, "{s}/webdav-{d}.part", .{ staging_dir, self.next_staging.fetchAdd(1, .monotonic) });
        errdefer self.unstage(staging);
        var file = try std.Io.Dir.cwd().createFile(self.io, staging, .{ .truncate = true });
        defer file.close(self.io);
        const buf = try arena.alloc(u8, chunk_len);
        var at: u64 = 0;
        while (true) {
            const got = switch (source) {
                .body => |body| try body.read(buf),
                .node => |node| try self.readNode(node, at, buf),
            };
            if (got == 0) break;
            try file.writePositionalAll(self.io, buf[0..got], at);
            at += got;
        }
        // A file that ends early (its device gone) is no copy.
        if (source == .node and at != source.node.size()) return error.EndOfStream;
        return staging;
    }

    fn unstage(self: *Server, staging: []const u8) void {
        // Already gone is fine; anything left is cleared by cleanStaging.
        std.Io.Dir.cwd().deleteFile(self.io, staging) catch {};
    }

    fn lock(self: *Server, arena: std.mem.Allocator, conn: *Conn, req: *Request) !void {
        try conn.discardBody(req);
        if (try swarmPath(arena, req.segments) == null) return conn.respond(403, "Forbidden", &.{}, "");
        const token = try std.fmt.allocPrint(arena, "opaquelocktoken:nomadfs-{d}-{d}", .{ self.port, self.next_lock.fetchAdd(1, .monotonic) });
        var body: std.Io.Writer.Allocating = .init(arena);
        const w = &body.writer;
        try w.writeAll("<?xml version=\"1.0\" encoding=\"utf-8\"?>\n<D:prop xmlns:D=\"DAV:\"><D:lockdiscovery><D:activelock>" ++
            "<D:locktype><D:write/></D:locktype><D:lockscope><D:exclusive/></D:lockscope><D:depth>0</D:depth>" ++
            "<D:timeout>Second-3600</D:timeout><D:locktoken><D:href>");
        try w.writeAll(token);
        try w.writeAll("</D:href></D:locktoken><D:lockroot><D:href>");
        try xml.writeHref(w, &self.root, req.segments, null);
        try w.writeAll("</D:href></D:lockroot></D:activelock></D:lockdiscovery></D:prop>\n");
        const header = try std.fmt.allocPrint(arena, "<{s}>", .{token});
        try conn.respond(200, "OK", &.{ .{ "Content-Type", "application/xml; charset=utf-8" }, .{ "Lock-Token", header } }, body.written());
    }

    /// Clients set times and Windows attributes after a copy; each property
    /// is reported as set.
    fn proppatch(self: *Server, arena: std.mem.Allocator, conn: *Conn, req: *Request) !void {
        const body_in = try conn.readSmallBody(arena, req, max_small_body);
        var body: std.Io.Writer.Allocating = .init(arena);
        const w = &body.writer;
        try w.writeAll("<?xml version=\"1.0\" encoding=\"utf-8\"?>\n<D:multistatus xmlns:D=\"DAV:\"><D:response><D:href>");
        try xml.writeHref(w, &self.root, req.segments, null);
        try w.writeAll("</D:href><D:propstat><D:prop>");
        // Echo each property element named inside <prop> as an empty one.
        var it = std.mem.splitSequence(u8, body_in, "<");
        var depth_in_prop = false;
        while (it.next()) |piece| {
            const tag_end = std.mem.indexOfAny(u8, piece, " />") orelse continue;
            const tag = piece[0..tag_end];
            if (std.mem.endsWith(u8, tag, ":prop") or eql(tag, "prop")) {
                depth_in_prop = true;
                continue;
            }
            if (std.mem.endsWith(u8, tag, "/prop") or eql(tag, "/prop")) depth_in_prop = false;
            if (!depth_in_prop or tag.len == 0 or tag[0] == '/' or tag[0] == '?' or tag[0] == '!') continue;
            const local = if (std.mem.lastIndexOfScalar(u8, tag, ':')) |c| tag[c + 1 ..] else tag;
            if (!xml.validXmlName(local)) continue;
            try w.print("<{s}/>", .{local});
        }
        try w.writeAll("</D:prop><D:status>HTTP/1.1 200 OK</D:status></D:propstat></D:response></D:multistatus>\n");
        try conn.respond(207, "Multi-Status", &.{.{ "Content-Type", "application/xml; charset=utf-8" }}, body.written());
    }

    // ---- Desktop metadata files ----

    fn scratchSize(self: *Server, path: []const u8) ?u64 {
        self.scratch.mutex.lock();
        defer self.scratch.mutex.unlock();
        const bytes = self.scratch.files.get(path) orelse return null;
        return bytes.len;
    }

    fn scratchCopy(self: *Server, arena: std.mem.Allocator, path: []const u8) !?[]u8 {
        self.scratch.mutex.lock();
        defer self.scratch.mutex.unlock();
        const bytes = self.scratch.files.get(path) orelse return null;
        return try arena.dupe(u8, bytes);
    }

    fn scratchPut(self: *Server, path: []const u8, bytes: []const u8) !void {
        const copy = try self.allocator.dupe(u8, bytes);
        errdefer self.allocator.free(copy);
        self.scratch.mutex.lock();
        defer self.scratch.mutex.unlock();
        // A replaced file counts anew: out first, then room for the new one.
        if (self.scratch.files.getPtr(path)) |old| {
            self.scratch.bytes -= old.len;
            self.allocator.free(old.*);
            old.* = &.{};
        }
        self.scratchMakeRoomLocked(path, bytes.len);
        const gop = try self.scratch.files.getOrPut(self.allocator, path);
        if (!gop.found_existing) {
            gop.key_ptr.* = self.allocator.dupe(u8, path) catch |err| {
                _ = self.scratch.files.remove(path);
                return err;
            };
        }
        gop.value_ptr.* = copy;
        self.scratch.bytes += copy.len;
    }

    /// Drops entries until one more of `len` bytes fits the caps. Which
    /// ones go doesn't matter much: a lost one is only metadata.
    fn scratchMakeRoomLocked(self: *Server, keep: []const u8, len: usize) void {
        while (true) {
            // `keep` (being replaced) stays: it holds no bytes now.
            const others = self.scratch.files.count() - @intFromBool(self.scratch.files.contains(keep));
            if (others == 0) return;
            if (others < max_scratch_files and self.scratch.bytes + len <= max_scratch_bytes) return;
            var it = self.scratch.files.iterator();
            const victim = while (it.next()) |e| {
                if (!eql(e.key_ptr.*, keep)) break e;
            } else return;
            const key = victim.key_ptr.*;
            const value = victim.value_ptr.*;
            self.scratch.files.removeByPtr(victim.key_ptr);
            self.scratch.bytes -= value.len;
            self.allocator.free(key);
            self.allocator.free(value);
        }
    }

    fn scratchDelete(self: *Server, path: []const u8) void {
        self.scratch.mutex.lock();
        defer self.scratch.mutex.unlock();
        if (self.scratch.files.fetchRemove(path)) |kv| {
            self.scratch.bytes -= kv.value.len;
            self.allocator.free(kv.key);
            self.allocator.free(kv.value);
        }
    }

    /// Drops the metadata kept for `path` and everything under it (a folder
    /// deleted or moved away).
    fn scratchDeleteUnder(self: *Server, path: []const u8) void {
        self.scratch.mutex.lock();
        defer self.scratch.mutex.unlock();
        var it = self.scratch.files.iterator();
        while (it.next()) |e| {
            const key = e.key_ptr.*;
            const under = eql(key, path) or (key.len > path.len and key[path.len] == '/' and std.mem.startsWith(u8, key, path));
            if (!under) continue;
            const value = e.value_ptr.*;
            self.scratch.files.removeByPtr(e.key_ptr);
            self.scratch.bytes -= value.len;
            self.allocator.free(key);
            self.allocator.free(value);
            // Removing invalidates the iterator: start over.
            it = self.scratch.files.iterator();
        }
    }
};

fn logRequested() bool {
    const value = env.getEnv(std.heap.page_allocator, "NOMADFS_WEBDAV_LOG") orelse return false;
    defer std.heap.page_allocator.free(value);
    return value.len > 0 and !eql(value, "0");
}

/// Files desktops write beside others: kept in memory, never in the swarm.
fn isScratchName(name: []const u8) bool {
    return std.mem.startsWith(u8, name, "._") or eql(name, ".DS_Store") or
        std.ascii.eqlIgnoreCase(name, "Thumbs.db") or std.ascii.eqlIgnoreCase(name, "desktop.ini");
}

const Status = struct { code: u16, text: []const u8 };

fn statusOf(err: anyerror) Status {
    return switch (err) {
        error.FileNotFound, error.BlockNotFound => .{ .code = 404, .text = "Not Found" },
        error.PathAlreadyExists => .{ .code = 412, .text = "Precondition Failed" },
        error.InvalidPath, error.InvalidName => .{ .code = 400, .text = "Bad Request" },
        error.IsDirectory, error.NotADirectory, error.DirNotEmpty => .{ .code = 409, .text = "Conflict" },
        error.BodyTooLarge => .{ .code = 413, .text = "Content Too Large" },
        error.PeerDown, error.AllAddressesFailed, error.NotRunning => .{ .code = 503, .text = "Service Unavailable" },
        error.NoSpaceLeft => .{ .code = 507, .text = "Insufficient Storage" },
        else => .{ .code = 500, .text = "Internal Server Error" },
    };
}

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

fn samePath(a: []const []const u8, b: []const []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| if (!eql(x, y)) return false;
    return true;
}

fn respondWritten(conn: *Conn, replaced: bool) !void {
    return if (replaced) conn.respond(204, "No Content", &.{}, "") else conn.respond(201, "Created", &.{}, "");
}

/// One PROPFIND <response>: `segments` is the requested resource, `child`
/// one of its entries (Depth: 1) or null for itself.
fn writeResponse(w: *std.Io.Writer, root: []const u8, segments: []const []const u8, child: ?[]const u8, name: []const u8, node: Server.Node) !void {
    try w.writeAll("<D:response><D:href>");
    try xml.writeHref(w, root, segments, child);
    if (node.isDir()) try w.writeAll("/");
    try w.writeAll("</D:href><D:propstat><D:prop><D:displayname>");
    try xml.writeEscaped(w, name);
    try w.writeAll("</D:displayname>");
    var date_buf: [40]u8 = undefined;
    switch (node) {
        .root, .device => try w.writeAll("<D:resourcetype><D:collection/></D:resourcetype>"),
        .share_dir => |d| try w.print("<D:resourcetype><D:collection/></D:resourcetype><D:getlastmodified>{s}</D:getlastmodified>", .{xml.httpDate(&date_buf, d.mtime)}),
        .swarm_dir => |d| try w.print("<D:resourcetype><D:collection/></D:resourcetype><D:getlastmodified>{s}</D:getlastmodified>", .{xml.httpDate(&date_buf, d.mtime)}),
        .share_file => |f| try xml.writeFileProps(w, name, f.size, f.mtime, f.cid),
        .swarm_file => |f| try xml.writeFileProps(w, name, f.info.size, f.info.mtime, f.info.cid),
        .scratch => |s| try xml.writeFileProps(w, name, s.size, 0, [_]u8{0} ** 32),
    }
    try w.writeAll("<D:supportedlock><D:lockentry><D:lockscope><D:exclusive/></D:lockscope><D:locktype><D:write/></D:locktype></D:lockentry></D:supportedlock>");
    try w.writeAll("</D:prop><D:status>HTTP/1.1 200 OK</D:status></D:propstat></D:response>\n");
}


test "webdav: desktop metadata files are bounded" {
    var server = Server.init(std.testing.allocator, null);
    defer server.deinit();
    var name_buf: [32]u8 = undefined;
    for (0..max_scratch_files + 10) |i| try server.scratchPut(try std.fmt.bufPrint(&name_buf, "d/._{d}", .{i}), "x");
    try std.testing.expectEqual(@as(usize, max_scratch_files), server.scratch.files.count());
    const big = try std.testing.allocator.alloc(u8, max_scratch);
    defer std.testing.allocator.free(big);
    for (0..20) |i| try server.scratchPut(try std.fmt.bufPrint(&name_buf, "big/._{d}", .{i}), big);
    try std.testing.expect(server.scratch.bytes <= max_scratch_bytes);
    // Replacing small files with big ones counts too.
    server.scratchDeleteUnder("big");
    for (0..20) |i| try server.scratchPut(try std.fmt.bufPrint(&name_buf, "d/._{d}", .{i}), big);
    try std.testing.expect(server.scratch.bytes <= max_scratch_bytes);
    try std.testing.expect(server.scratch.files.count() <= max_scratch_files);
    server.scratchDeleteUnder("big");
    server.scratchDeleteUnder("d");
    try std.testing.expectEqual(@as(usize, 0), server.scratch.files.count());
    try std.testing.expectEqual(@as(usize, 0), server.scratch.bytes);
}
