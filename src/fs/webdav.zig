//! A WebDAV server on 127.0.0.1 showing what the FUSE mount shows, for
//! the systems without FUSE (macOS, Windows): Finder ("Connect to Server")
//! and Explorer ("Map network drive") mount WebDAV with no driver.
//!
//!   /Swarm/<path...>             the swarm folder: read and write
//!   /<device>/<share>/<path...>  every reachable device's shares: read only
//!
//! Devices come from devices.Directory, the same list and names as the FUSE
//! mount. Writes go through the swarm folder's own edits (addFileAt,
//! makeDir, remove, move), so they spread like any other change. A PUT is
//! written to a staging file first and added once complete.
//!
//! LOCK and PROPPATCH are answered without doing anything (clients mount
//! read-only without them); the metadata files desktops write next to
//! everything (`._*`, `.DS_Store`, `Thumbs.db`, `desktop.ini`) stay in
//! memory and never reach the swarm. The Host header must be the loopback
//! address, so a web page can't reach the server through DNS rebinding.

const std = @import("std");
const cluster = @import("../cluster/mod.zig");
const compat = @import("../net/compat.zig");
const sync = @import("../sync.zig");
const tree = @import("tree.zig");
const remote_mod = @import("remote.zig");
const swarm_mod = @import("swarm.zig");
const devices_mod = @import("devices.zig");
const ReadAhead = @import("readahead.zig").ReadAhead;

const swarm_name = "Swarm";
/// Request line and headers.
const max_head = 16 * 1024;
/// PROPFIND, LOCK and PROPPATCH bodies are read and ignored past this.
const max_small_body = 64 * 1024;
/// A desktop metadata file kept in memory.
const max_scratch = 1024 * 1024;
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
    } = .{},
    next_lock: std.atomic.Value(u64) = .init(1),
    next_staging: std.atomic.Value(u64) = .init(1),

    pub fn init(allocator: std.mem.Allocator, block_manager: ?*cluster.BlockManager) Server {
        return .{
            .allocator = allocator,
            .io = std.Io.Threaded.global_single_threaded.io(),
            .block_manager = block_manager,
            .directory = devices_mod.Directory.init(allocator, block_manager),
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

    /// Listens on 127.0.0.1:`port` (0: any free port; see `port`).
    pub fn start(self: *Server, port: u16) !void {
        if (self.listener != null) return;
        var listener = try compat.listenLoopback(port);
        errdefer listener.deinit();
        self.port = listener.inner.socket.address.getPort();
        self.listener = listener;
        self.running.store(true, .release);
        errdefer self.running.store(false, .release);
        if (self.swarm) |s| s.cleanStaging();
        try self.directory.start();
        self.accept_thread = try std.Thread.spawn(.{}, acceptLoop, .{self});
    }

    /// Stops listening, ends every connection and waits for them.
    pub fn stop(self: *Server) void {
        if (!self.running.swap(false, .acq_rel)) return;
        if (self.listener) |*l| l.deinit();
        if (self.accept_thread) |t| t.join();
        self.accept_thread = null;
        self.listener = null;
        self.directory.stop();
        self.conns.mutex.lock();
        defer self.conns.mutex.unlock();
        for (self.conns.list.items) |c| c.shutdown();
        while (self.conns.active > 0) self.conns.done.wait(&self.conns.mutex);
    }

    /// `http://127.0.0.1:<port>/`, into `buf`.
    pub fn url(self: *const Server, buf: []u8) ![]const u8 {
        return std.fmt.bufPrint(buf, "http://127.0.0.1:{d}/", .{self.port});
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
            const added = if (self.conns.list.append(self.allocator, conn.stream)) true else |_| false;
            if (added) self.conns.active += 1;
            self.conns.mutex.unlock();
            if (!added) {
                conn.stream.close();
                continue;
            }
            const t = std.Thread.spawn(.{}, serveConnection, .{ self, conn.stream }) catch {
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

    fn serveConnection(self: *Server, stream: compat.Stream) void {
        defer {
            self.forget(stream);
            stream.close();
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
        if (!localHost(req.header("host"))) {
            try conn.discardBody(&req);
            try conn.respond(403, "Forbidden", &.{}, "");
            return false;
        }
        const keep = !std.ascii.eqlIgnoreCase(req.header("connection") orelse "", "close");
        self.dispatch(arena, conn, &req) catch |err| {
            // The body may be unread: the connection can't be reused.
            const status = statusOf(err);
            conn.respond(status.code, status.text, &.{}, "") catch {};
            return false;
        };
        return keep;
    }

    fn dispatch(self: *Server, arena: std.mem.Allocator, conn: *Conn, req: *Request) !void {
        const m = req.method;
        if (eql(m, "OPTIONS")) {
            try conn.discardBody(req);
            return conn.respond(200, "OK", &.{
                .{ "DAV", "1, 2" },
                .{ "MS-Author-Via", "DAV" },
                .{ "Allow", "OPTIONS, GET, HEAD, PUT, DELETE, MKCOL, MOVE, COPY, PROPFIND, PROPPATCH, LOCK, UNLOCK" },
            }, "");
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
        try writeResponse(w, req.segments, null, name, node);
        if (!eql(depth, "0") and node.isDir()) {
            for (try self.children(arena, node)) |c| try writeResponse(w, req.segments, c.name, c.name, c.node);
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
        const size: u64 = switch (node) {
            .share_file => |f| f.size,
            .swarm_file => |f| f.info.size,
            else => unreachable,
        };
        const mtime: u64 = switch (node) {
            .share_file => |f| f.mtime,
            .swarm_file => |f| f.info.mtime,
            else => unreachable,
        };
        var first: u64 = 0;
        var end: u64 = size; // exclusive
        var partial = false;
        if (req.header("range")) |r| if (parseRange(r, size)) |range| {
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
        headers[n] = .{ "Content-Type", contentType(req.segments[req.segments.len - 1]) };
        n += 1;
        headers[n] = .{ "Content-Length", try std.fmt.bufPrint(&len_buf, "{d}", .{end - first}) };
        n += 1;
        headers[n] = .{ "Last-Modified", httpDate(&date_buf, mtime) };
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
            const bytes = try conn.readSmallBody(arena, req, max_scratch);
            try self.scratchPut(path, bytes);
            return conn.respond(201, "Created", &.{}, "");
        }
        const existed = folder.fileInfo(path) != null;
        const staging_dir = try folder.stagingDir(arena);
        const staging = try std.fmt.allocPrint(arena, "{s}/webdav-{d}.part", .{ staging_dir, self.next_staging.fetchAdd(1, .monotonic) });
        defer std.Io.Dir.cwd().deleteFile(self.io, staging) catch {};
        {
            var file = try std.Io.Dir.cwd().createFile(self.io, staging, .{ .truncate = true });
            defer file.close(self.io);
            var offset: u64 = 0;
            var buf: [chunk_len]u8 = undefined;
            var body = conn.bodyReader(req);
            while (true) {
                const got = try body.read(&buf);
                if (got == 0) break;
                try file.writePositionalAll(self.io, buf[0..got], offset);
                offset += got;
            }
        }
        const slash = std.mem.lastIndexOfScalar(u8, path, '/');
        try folder.addFileAt(if (slash) |s| path[0..s] else "", name, staging, null);
        return conn.respond(if (existed) 204 else 201, if (existed) "No Content" else "Created", &.{}, "");
    }

    fn mkcol(self: *Server, arena: std.mem.Allocator, conn: *Conn, req: *Request) !void {
        try conn.discardBody(req);
        const path = try swarmPath(arena, req.segments) orelse return conn.respond(403, "Forbidden", &.{}, "");
        const folder = self.swarm orelse return error.FileNotFound;
        if (try self.resolve(arena, req.segments) != null) return conn.respond(405, "Method Not Allowed", &.{}, "");
        const slash = std.mem.lastIndexOfScalar(u8, path, '/');
        try folder.makeDir(if (slash) |s| path[0..s] else "", req.segments[req.segments.len - 1]);
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
        return conn.respond(204, "No Content", &.{}, "");
    }

    fn moveOrCopy(self: *Server, arena: std.mem.Allocator, conn: *Conn, req: *Request, copy: bool) !void {
        try conn.discardBody(req);
        const dest_header = req.header("destination") orelse return conn.respond(400, "Bad Request", &.{}, "");
        const dest_segments = try splitPath(arena, targetPath(dest_header)) orelse return conn.respond(400, "Bad Request", &.{}, "");
        const to = try swarmPath(arena, dest_segments) orelse return conn.respond(403, "Forbidden", &.{}, "");
        const folder = self.swarm orelse return error.FileNotFound;
        const overwrite = !eql(req.header("overwrite") orelse "T", "F");
        const source = try self.resolve(arena, req.segments) orelse return conn.respond(404, "Not Found", &.{}, "");
        const existed = try self.resolve(arena, dest_segments) != null;
        if (existed and !overwrite) return conn.respond(412, "Precondition Failed", &.{}, "");
        if (source == .scratch) {
            const bytes = try self.scratchCopy(arena, source.scratch.path) orelse return conn.respond(404, "Not Found", &.{}, "");
            try self.scratchPut(to, bytes);
            if (!copy) self.scratchDelete(source.scratch.path);
            return conn.respond(201, "Created", &.{}, "");
        }
        if (!copy) {
            const from = try swarmPath(arena, req.segments) orelse return conn.respond(403, "Forbidden", &.{}, "");
            try folder.move(from, to, .{ .replace = overwrite });
            return conn.respond(if (existed) 204 else 201, if (existed) "No Content" else "Created", &.{}, "");
        }
        // COPY: a file's bytes into a new swarm file (from the swarm or a share).
        if (source.isDir()) return conn.respond(403, "Forbidden", &.{}, "");
        if (existed) try folder.remove(to);
        const staging_dir = try folder.stagingDir(arena);
        const staging = try std.fmt.allocPrint(arena, "{s}/webdav-{d}.part", .{ staging_dir, self.next_staging.fetchAdd(1, .monotonic) });
        defer std.Io.Dir.cwd().deleteFile(self.io, staging) catch {};
        {
            var file = try std.Io.Dir.cwd().createFile(self.io, staging, .{ .truncate = true });
            defer file.close(self.io);
            const buf = try arena.alloc(u8, chunk_len);
            var at: u64 = 0;
            while (true) {
                const got = try self.readNode(source, at, buf);
                if (got == 0) break;
                try file.writePositionalAll(self.io, buf[0..got], at);
                at += got;
            }
        }
        const slash = std.mem.lastIndexOfScalar(u8, to, '/');
        try folder.addFileAt(if (slash) |s| to[0..s] else "", dest_segments[dest_segments.len - 1], staging, null);
        return conn.respond(if (existed) 204 else 201, if (existed) "No Content" else "Created", &.{}, "");
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
        try writeHref(w, req.segments, null);
        try w.writeAll("</D:href></D:lockroot></D:activelock></D:lockdiscovery></D:prop>\n");
        const header = try std.fmt.allocPrint(arena, "<{s}>", .{token});
        try conn.respond(200, "OK", &.{ .{ "Content-Type", "application/xml; charset=utf-8" }, .{ "Lock-Token", header } }, body.written());
    }

    /// Clients set times and Windows attributes after a copy; each property
    /// is reported as set.
    fn proppatch(self: *Server, arena: std.mem.Allocator, conn: *Conn, req: *Request) !void {
        const body_in = try conn.readSmallBody(arena, req, max_small_body);
        _ = self;
        var body: std.Io.Writer.Allocating = .init(arena);
        const w = &body.writer;
        try w.writeAll("<?xml version=\"1.0\" encoding=\"utf-8\"?>\n<D:multistatus xmlns:D=\"DAV:\"><D:response><D:href>");
        try writeHref(w, req.segments, null);
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
            if (!validXmlName(local)) continue;
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
        const gop = try self.scratch.files.getOrPut(self.allocator, path);
        if (gop.found_existing) {
            self.allocator.free(gop.value_ptr.*);
        } else {
            gop.key_ptr.* = self.allocator.dupe(u8, path) catch |err| {
                _ = self.scratch.files.remove(path);
                return err;
            };
        }
        gop.value_ptr.* = copy;
    }

    fn scratchDelete(self: *Server, path: []const u8) void {
        self.scratch.mutex.lock();
        defer self.scratch.mutex.unlock();
        if (self.scratch.files.fetchRemove(path)) |kv| {
            self.allocator.free(kv.key);
            self.allocator.free(kv.value);
        }
    }
};

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

/// The Host header names this machine's loopback (any port), or is absent
/// (HTTP/1.0).
fn localHost(host: ?[]const u8) bool {
    const h = host orelse return true;
    const name = if (std.mem.startsWith(u8, h, "[")) h[0 .. (std.mem.indexOfScalar(u8, h, ']') orelse h.len - 1) + 1] else if (std.mem.lastIndexOfScalar(u8, h, ':')) |c| h[0..c] else h;
    return eql(name, "127.0.0.1") or std.ascii.eqlIgnoreCase(name, "localhost") or eql(name, "[::1]");
}

// ---- HTTP ----

const Request = struct {
    method: []const u8,
    /// Decoded path segments (no empty ones).
    segments: []const []const u8,
    head: []const u8,
    content_length: ?u64 = null,
    chunked: bool = false,
    body_done: bool = false,

    fn parse(arena: std.mem.Allocator, head: []const u8) !Request {
        const line_end = std.mem.indexOf(u8, head, "\r\n") orelse return error.BadRequest;
        var parts = std.mem.splitScalar(u8, head[0..line_end], ' ');
        const method = parts.next() orelse return error.BadRequest;
        const target = parts.next() orelse return error.BadRequest;
        var req = Request{
            .method = try arena.dupe(u8, method),
            .segments = try splitPath(arena, targetPath(target)) orelse return error.BadRequest,
            .head = head,
        };
        if (req.header("content-length")) |v| req.content_length = std.fmt.parseInt(u64, std.mem.trim(u8, v, " "), 10) catch return error.BadRequest;
        if (req.header("transfer-encoding")) |v| req.chunked = std.ascii.indexOfIgnoreCase(v, "chunked") != null;
        if (!req.chunked and (req.content_length orelse 0) == 0) req.body_done = true;
        return req;
    }

    /// A header's value (case-insensitive name), trimmed.
    fn header(self: *const Request, name: []const u8) ?[]const u8 {
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
fn targetPath(target: []const u8) []const u8 {
    var t = target;
    if (std.mem.indexOf(u8, t, "://")) |i| {
        const after = t[i + 3 ..];
        t = if (std.mem.indexOfScalar(u8, after, '/')) |s| after[s..] else "/";
    }
    if (std.mem.indexOfScalar(u8, t, '?')) |q| t = t[0..q];
    return t;
}

/// Decoded, non-empty segments; null for `.`/`..` or a bad escape.
fn splitPath(arena: std.mem.Allocator, path: []const u8) !?[]const []const u8 {
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
fn parseRange(value: []const u8, size: u64) ?[2]u64 {
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

const Conn = struct {
    stream: compat.Stream,
    buf: [max_head]u8 = undefined,
    start: usize = 0,
    end: usize = 0,
    /// Bytes left in the current chunk (chunked bodies).
    chunk_left: u64 = 0,
    body_left: u64 = 0,

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
    fn readHead(self: *Conn) !?[]const u8 {
        while (true) {
            if (std.mem.indexOf(u8, self.buf[self.start..self.end], "\r\n\r\n")) |i| {
                const head = self.buf[self.start .. self.start + i + 4];
                self.start += i + 4;
                return head;
            }
            if (!try self.fill()) return null;
        }
    }

    const BodyReader = struct {
        conn: *Conn,
        req: *Request,

        /// Up to `dest.len` body bytes; 0 at its end.
        fn read(self: *BodyReader, dest: []u8) !usize {
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

    fn bodyReader(self: *Conn, req: *Request) BodyReader {
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

    fn discardBody(self: *Conn, req: *Request) !void {
        var reader = self.bodyReader(req);
        var scratch: [4096]u8 = undefined;
        while (try reader.read(&scratch) > 0) {}
    }

    fn readSmallBody(self: *Conn, arena: std.mem.Allocator, req: *Request, limit: usize) ![]u8 {
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

    fn writeHead(self: *Conn, code: u16, text: []const u8, headers: []const [2][]const u8) !void {
        var buf: [2048]u8 = undefined;
        var w: std.Io.Writer = .fixed(&buf);
        try w.print("HTTP/1.1 {d} {s}\r\n", .{ code, text });
        for (headers) |h| try w.print("{s}: {s}\r\n", .{ h[0], h[1] });
        try w.writeAll("\r\n");
        try self.stream.writeAll(w.buffered());
    }

    fn respond(self: *Conn, code: u16, text: []const u8, headers: []const [2][]const u8, body: []const u8) !void {
        var len_buf: [24]u8 = undefined;
        var all: [8][2][]const u8 = undefined;
        @memcpy(all[0..headers.len], headers);
        all[headers.len] = .{ "Content-Length", try std.fmt.bufPrint(&len_buf, "{d}", .{body.len}) };
        try self.writeHead(code, text, all[0 .. headers.len + 1]);
        if (body.len > 0) try self.stream.writeAll(body);
    }
};

// ---- XML and formats ----

/// One PROPFIND <response>: `segments` is the requested resource, `child`
/// one of its entries (Depth: 1) or null for itself.
fn writeResponse(w: *std.Io.Writer, segments: []const []const u8, child: ?[]const u8, name: []const u8, node: Server.Node) !void {
    try w.writeAll("<D:response><D:href>");
    try writeHref(w, segments, child);
    if (node.isDir()) try w.writeAll("/");
    try w.writeAll("</D:href><D:propstat><D:prop><D:displayname>");
    try writeEscaped(w, name);
    try w.writeAll("</D:displayname>");
    var date_buf: [40]u8 = undefined;
    switch (node) {
        .root, .device => try w.writeAll("<D:resourcetype><D:collection/></D:resourcetype>"),
        .share_dir => |d| try w.print("<D:resourcetype><D:collection/></D:resourcetype><D:getlastmodified>{s}</D:getlastmodified>", .{httpDate(&date_buf, d.mtime)}),
        .swarm_dir => |d| try w.print("<D:resourcetype><D:collection/></D:resourcetype><D:getlastmodified>{s}</D:getlastmodified>", .{httpDate(&date_buf, d.mtime)}),
        .share_file => |f| try writeFileProps(w, name, f.size, f.mtime, f.cid),
        .swarm_file => |f| try writeFileProps(w, name, f.info.size, f.info.mtime, f.info.cid),
        .scratch => |s| try writeFileProps(w, name, s.size, 0, [_]u8{0} ** 32),
    }
    try w.writeAll("<D:supportedlock><D:lockentry><D:lockscope><D:exclusive/></D:lockscope><D:locktype><D:write/></D:locktype></D:lockentry></D:supportedlock>");
    try w.writeAll("</D:prop><D:status>HTTP/1.1 200 OK</D:status></D:propstat></D:response>\n");
}

fn writeFileProps(w: *std.Io.Writer, name: []const u8, size: u64, mtime: u64, cid: [32]u8) !void {
    var date_buf: [40]u8 = undefined;
    const etag = std.fmt.bytesToHex(cid[0..8].*, .lower);
    try w.print("<D:resourcetype/><D:getcontentlength>{d}</D:getcontentlength><D:getlastmodified>{s}</D:getlastmodified>" ++
        "<D:getcontenttype>{s}</D:getcontenttype><D:getetag>\"{s}\"</D:getetag>", .{ size, httpDate(&date_buf, mtime), contentType(name), etag });
}

/// `/seg/seg[/child]`, each segment percent-encoded.
fn writeHref(w: *std.Io.Writer, segments: []const []const u8, child: ?[]const u8) !void {
    if (segments.len == 0 and child == null) return w.writeAll("/");
    for (segments) |s| {
        try w.writeAll("/");
        try writeEncoded(w, s);
    }
    if (child) |c| {
        try w.writeAll("/");
        try writeEncoded(w, c);
    }
}

fn writeEncoded(w: *std.Io.Writer, s: []const u8) !void {
    for (s) |c| {
        if (std.ascii.isAlphanumeric(c) or c == '-' or c == '.' or c == '_' or c == '~') {
            try w.writeByte(c);
        } else try w.print("%{X:0>2}", .{c});
    }
}

fn writeEscaped(w: *std.Io.Writer, s: []const u8) !void {
    for (s) |c| switch (c) {
        '&' => try w.writeAll("&amp;"),
        '<' => try w.writeAll("&lt;"),
        '>' => try w.writeAll("&gt;"),
        '"' => try w.writeAll("&quot;"),
        else => try w.writeByte(c),
    };
}

fn validXmlName(s: []const u8) bool {
    if (s.len == 0 or s.len > 64) return false;
    for (s) |c| if (!(std.ascii.isAlphanumeric(c) or c == '_' or c == '-' or c == '.')) return false;
    return std.ascii.isAlphabetic(s[0]) or s[0] == '_';
}

/// RFC 1123: `Sat, 31 Oct 2026 12:00:00 GMT`.
fn httpDate(buf: *[40]u8, seconds: u64) []const u8 {
    const es = std.time.epoch.EpochSeconds{ .secs = seconds };
    const day = es.getEpochDay();
    const yd = day.calculateYearDay();
    const md = yd.calculateMonthDay();
    const ds = es.getDaySeconds();
    const weekdays = [_][]const u8{ "Thu", "Fri", "Sat", "Sun", "Mon", "Tue", "Wed" };
    const months = [_][]const u8{ "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" };
    return std.fmt.bufPrint(buf, "{s}, {d:0>2} {s} {d} {d:0>2}:{d:0>2}:{d:0>2} GMT", .{
        weekdays[@intCast(day.day % 7)], md.day_index + 1,        months[@intFromEnum(md.month) - 1], yd.year,
        ds.getHoursIntoDay(),            ds.getMinutesIntoHour(), ds.getSecondsIntoMinute(),
    }) catch "Thu, 01 Jan 1970 00:00:00 GMT";
}

fn contentType(name: []const u8) []const u8 {
    const ext = std.fs.path.extension(name);
    const map = [_][2][]const u8{
        .{ ".txt", "text/plain" },        .{ ".md", "text/markdown" }, .{ ".html", "text/html" },
        .{ ".pdf", "application/pdf" },   .{ ".jpg", "image/jpeg" },   .{ ".jpeg", "image/jpeg" },
        .{ ".png", "image/png" },         .{ ".gif", "image/gif" },    .{ ".webp", "image/webp" },
        .{ ".heic", "image/heic" },       .{ ".mp4", "video/mp4" },    .{ ".mov", "video/quicktime" },
        .{ ".mkv", "video/x-matroska" },  .{ ".webm", "video/webm" },  .{ ".mp3", "audio/mpeg" },
        .{ ".m4a", "audio/mp4" },         .{ ".flac", "audio/flac" },  .{ ".zip", "application/zip" },
        .{ ".json", "application/json" }, .{ ".csv", "text/csv" },
    };
    for (map) |m| if (std.ascii.eqlIgnoreCase(ext, m[0])) return m[1];
    return "application/octet-stream";
}

test httpDate {
    var buf: [40]u8 = undefined;
    try std.testing.expectEqualStrings("Thu, 01 Jan 1970 00:00:00 GMT", httpDate(&buf, 0));
    try std.testing.expectEqualStrings("Sat, 31 Oct 2026 12:34:56 GMT", httpDate(&buf, 1793450096));
}

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
