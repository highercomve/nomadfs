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
//!   GET    /<token>/v1/photos/index    the photos timeline: how many, their times, folders
//!   GET    /<token>/v1/photos          a page of its items
//!   GET    /<token>/v1/thumb/<path>    a small JPEG of the picture at <path>
//!   GET    /<token>/v1/content/<cid>   a file's bytes by content ID, with Range
//!   GET    /<token>/v1/backup                          the offsite targets and how their uploads go
//!   POST   /<token>/v1/backup/reload                   read the targets of the configuration file again
//!   GET    /<token>/v1/backup/<target>                 one target's bucket: snapshots, blocks, packs to remove
//!   POST   /<token>/v1/backup/<target>/run             upload now: 202 {"name", "manual_runs"}
//!   POST   /<token>/v1/backup/<target>/forget?path=    purge a path from the backup: 204
//!   GET    /<token>/v1/backup/<target>/history[?path=] every file version the backup holds
//!
//! The photos timeline (fs/photos.zig) is every picture and film in the
//! folder, newest first. Both requests take `folder=` (only below it),
//! `kinds=all|photos|videos` and `dedupe=0` (show the same content at each
//! of its paths); a page takes `start=`, `count=` (500 at most) and the
//! index's `generation=`, and answers 409 once the folder changed since
//! (ask for the index again). Without `generation` it is the page as of now.
//!
//! A thumbnail (fs/thumbs.zig) is made from the file when all of it is on
//! this device, and kept. 404 with `X-NomadFS-Error: NoThumbnail` when none
//! can be made of the file (a format no decoder here reads, a damaged
//! picture), 503 when one is being made (`Pending`: ask again shortly) or
//! the file isn't here (`Unavailable`).
//!
//! `content` is what ffmpeg reads a film through to take its frame
//! (`videoInput`): only files whose blocks are all on this device (404
//! `NotLocal` otherwise; nothing is ever fetched for it), `Range` honoured
//! (206, or 416) since a phone's films keep their index at the end. ffmpeg
//! gets the URL as an argument, which other accounts can read from the
//! process list, so that URL is under a second token that opens `content`
//! and nothing else.
//!
//! The backup routes are `nomadfs backup` (backup_cli.zig) on a device
//! whose node runs: the operations of backup/service.zig on the node's
//! uploader (cluster/offsite_worker.zig) and its live swarm folder.
//! `<target>` is a `[backup.<target>]` section (`s3`: the first). The list
//! asks no bucket: per target its `gate` (and `not_uploading`, the reason
//! in words), `running`, `requested`, `manual_runs`, the last upload
//! (`last_upload`, `snapshot`, `uploaded_blocks`, `uploaded_bytes`,
//! `waiting_files`, `new_key`), `failure` and the `deferred_packs` that
//! upload found. One target's status, its history and a purge ask the
//! bucket and take as long as it answers. `run` only starts the upload: it
//! is over, well or with a `failure`, once the list's `manual_runs` passed
//! the number `run` answered. 404 `BackupNotConfigured` when this node
//! uploads nowhere, 404 `UnknownBackupTarget`, 409 `DeepBackupOff` (an
//! archive target on a device without deep backup), 409 `LeaseHeld` (an
//! upload holds the bucket: purge after it).
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
const photos_mod = @import("fs/photos.zig");
const thumbs_mod = @import("fs/thumbs.zig");
const media = @import("fs/media.zig");
const http = @import("webdav/http.zig");
const peer = @import("webdav/peer.zig");
const backup = @import("backup/service.zig");
const offsite_worker = @import("cluster/offsite_worker.zig");

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
/// How long a thumbnail request waits for its decode.
const thumb_deadline_ms = 20_000;
/// How much of a file `content` reads and sends at a time.
const content_chunk = 256 * 1024;

/// What `GET backup/<target>` answers: the bucket's committed state, and
/// whether this device uploads to it.
pub const BackupStatus = struct {
    storage_class: backup.StorageClass,
    schedule: backup.Schedule,
    indexed_blocks: usize,
    snapshots: []const []const u8,
    /// Packs a purge left behind until their minimum storage time ends,
    /// and when the first and the last may go (Unix seconds).
    deferred_packs: usize,
    deferred_first: u64,
    deferred_last: u64,
    gate: backup.Gate,
    /// Deep backup is on and no target is cold.
    archive_missing: bool,
};
/// One item of `GET backup/<target>/history`. `cid`: 64 hex digits.
pub const BackupVersion = struct { path: []const u8, cid: []const u8, size: u64, mtime: u64, first_seen: u64, last_seen: u64 };
/// What `POST backup/<target>/run` answers: the target as the list names
/// it, and its `manual_runs` at that moment.
pub const BackupRun = struct { name: []const u8, manual_runs: u64 };

/// What `api.json` holds.
pub const Info = struct {
    version: u32 = 1,
    /// `http://127.0.0.1:<port>/<token>/v1/`.
    url: []const u8,
};

/// The node's side of `POST backup/reload`.
pub const Reload = struct {
    ctx: *anyopaque,
    reloadFn: *const fn (ctx: *anyopaque) anyerror!void,
};

pub const Server = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    folder: *SwarmFolder,
    /// The node's photos timeline (what its `photosIndex` and `photosPage`
    /// answer from); it outlives the server. Null: no photos routes.
    photos: ?*photos_mod.Timeline,
    /// The node's thumbnails (what its `thumbnail` answers from); they
    /// outlive the server. Null: no thumbnails.
    thumbs: ?*thumbs_mod.Thumbs,
    /// The file the URL is published in; removed by `stop`.
    info_path: []u8,
    token: [64]u8 = undefined,
    /// Opens `content` only: the token in the URL ffmpeg is given.
    content_token: [64]u8 = undefined,
    /// The node's offsite uploader, while it has one (`setBackup`), and
    /// the requests using it now.
    backup: struct {
        mutex: sync.Mutex = .{},
        idle: sync.Condition = .{},
        worker: ?*offsite_worker.Worker = null,
        users: usize = 0,
        /// False once the uploader is being taken away: a request talking
        /// to a bucket ends.
        open: std.atomic.Value(bool) = .init(false),
        /// How the node takes the backup targets of its configuration file
        /// again (`POST backup/reload`); null: it can't.
        reload: ?Reload = null,
    } = .{},
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

    /// Serves `folder`, its `photos` timeline and its `thumbs`, and
    /// publishes the URL in `<device_dir>/api.json`.
    pub fn start(allocator: std.mem.Allocator, folder: *SwarmFolder, photos: ?*photos_mod.Timeline, thumbs: ?*thumbs_mod.Thumbs, device_dir: []const u8) !*Server {
        const io = std.Io.Threaded.global_single_threaded.io();
        const self = try allocator.create(Server);
        errdefer allocator.destroy(self);
        self.* = .{
            .allocator = allocator,
            .io = io,
            .folder = folder,
            .photos = photos,
            .thumbs = thumbs,
            .info_path = try std.fs.path.join(allocator, &.{ device_dir, api_file }),
        };
        errdefer allocator.free(self.info_path);
        var secret: [32]u8 = undefined;
        try io.randomSecure(&secret);
        self.token = std.fmt.bytesToHex(secret, .lower);
        try io.randomSecure(&secret);
        self.content_token = std.fmt.bytesToHex(secret, .lower);
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
        std.crypto.secureZero(u8, &self.content_token);
        self.allocator.destroy(self);
    }

    /// The uploader the backup routes work on; null takes it away, and
    /// returns once no request uses it (before the node destroys it).
    pub fn setBackup(self: *Server, worker: ?*offsite_worker.Worker) void {
        self.backup.open.store(worker != null, .release);
        self.backup.mutex.lock();
        defer self.backup.mutex.unlock();
        while (self.backup.users > 0) self.backup.idle.wait(&self.backup.mutex);
        self.backup.worker = worker;
    }

    /// What `POST backup/reload` calls: the node reads its targets again.
    pub fn setReload(self: *Server, reload: ?Reload) void {
        self.backup.mutex.lock();
        defer self.backup.mutex.unlock();
        self.backup.reload = reload;
    }

    fn holdBackup(self: *Server) ?*offsite_worker.Worker {
        self.backup.mutex.lock();
        defer self.backup.mutex.unlock();
        if (!self.backup.open.load(.acquire)) return null;
        const worker = self.backup.worker orelse return null;
        self.backup.users += 1;
        return worker;
    }

    fn releaseBackup(self: *Server) void {
        self.backup.mutex.lock();
        defer self.backup.mutex.unlock();
        self.backup.users -= 1;
        self.backup.idle.broadcast();
    }

    /// `http://127.0.0.1:<port>/<token>/v1/` into `buf`.
    pub fn url(self: *const Server, buf: []u8) ![]const u8 {
        return std.fmt.bufPrint(buf, "http://127.0.0.1:{d}/{s}/v1/", .{ self.port, &self.token });
    }

    /// Where ffmpeg reads a film from: what the node gives the thumbnails
    /// (`Thumbs.setVideoInput`), and takes back before `stop`.
    pub fn videoInput(self: *Server) thumbs_mod.VideoInput {
        return .{ .ctx = self, .urlFn = contentUrl };
    }

    /// `http://127.0.0.1:<port>/<content token>/v1/content/<cidhex>` into
    /// `buf`; null once the server is stopping.
    fn contentUrl(ctx: *anyopaque, cid: *const [32]u8, buf: []u8) ?[]const u8 {
        const self: *Server = @ptrCast(@alignCast(ctx));
        if (!self.running.load(.acquire)) return null;
        const hex = std.fmt.bytesToHex(cid.*, .lower);
        return std.fmt.bufPrint(buf, "http://127.0.0.1:{d}/{s}/v1/content/{s}", .{ self.port, &self.content_token, &hex }) catch null;
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
        if (segments.len < 3 or !std.mem.eql(u8, segments[1], "v1")) return conn.respond(404, "Not Found", &close, "");
        const what = segments[2];
        const rest = segments[3..];
        const method = req.method;
        const full = tokenMatches(segments[0], &self.token);
        if ((full or tokenMatches(segments[0], &self.content_token)) and std.mem.eql(u8, what, "content") and rest.len == 1 and eql(method, "GET")) {
            return self.content(arena, conn, &req, rest[0]);
        }
        if (!full) return conn.respond(404, "Not Found", &close, "");
        if (std.mem.eql(u8, what, "status") and rest.len == 0 and eql(method, "GET")) return self.status(arena, conn);
        if (std.mem.eql(u8, what, "list") and eql(method, "GET")) return self.list(arena, conn, try joinPath(arena, rest));
        if (std.mem.eql(u8, what, "photos") and eql(method, "GET")) {
            if (rest.len == 0) return self.photosPage(arena, conn, &req);
            if (rest.len == 1 and eql(rest[0], "index")) return self.photosIndex(arena, conn, &req);
        }
        if (std.mem.eql(u8, what, "thumb") and rest.len > 0 and eql(method, "GET")) return self.thumb(arena, conn, try joinPath(arena, rest));
        if (std.mem.eql(u8, what, "backup")) return self.backupRoute(arena, conn, &req, rest);
        if (std.mem.eql(u8, what, "files") and rest.len > 0) {
            const path = try joinPath(arena, rest);
            if (eql(method, "GET")) return self.get(arena, conn, path);
            if (eql(method, "PUT")) return self.put(arena, conn, &req, path);
            if (eql(method, "DELETE")) return self.delete(conn, &req, path);
            return conn.respond(405, "Method Not Allowed", &close, "");
        }
        return conn.respond(404, "Not Found", &close, "");
    }

    /// The backup routes: which operation of backup/service.zig a request
    /// means, and its answer as JSON.
    fn backupRoute(self: *Server, arena: std.mem.Allocator, conn: *Conn, req: *const Request, rest: []const []const u8) !void {
        const read = eql(req.method, "GET");
        if (!read and !eql(req.method, "POST")) return conn.respond(405, "Method Not Allowed", &close, "");
        // The targets changed in the configuration file (`nomadfs backup
        // add|remove`): the node reads them again. Nothing secret travels:
        // the credentials are in their own file.
        if (rest.len == 1 and !read and eql(rest[0], "reload")) {
            self.backup.mutex.lock();
            const reload = self.backup.reload;
            self.backup.mutex.unlock();
            const hook = reload orelse return answerBackupError(conn, error.ReloadUnsupported);
            hook.reloadFn(hook.ctx) catch |err| return answerBackupError(conn, err);
            return conn.respond(204, "No Content", &close, "");
        }
        // Null: the list, of no one target.
        const action: ?backup.Action = if (rest.len == 0 and read)
            null
        else if (rest.len == 1 and read)
            .status
        else if (rest.len == 2 and read and eql(rest[1], "history"))
            .history
        else if (rest.len == 2 and !read and eql(rest[1], "run"))
            .run
        else if (rest.len == 2 and !read and eql(rest[1], "forget"))
            .forget
        else
            return conn.respond(404, "Not Found", &close, "");
        const worker = self.holdBackup() orelse return answerBackupError(conn, error.BackupNotConfigured);
        defer self.releaseBackup();
        const wanted = action orelse {
            const all = try backup.overview(arena, worker);
            return conn.respond(200, "OK", &json_close, try std.json.Stringify.valueAlloc(arena, all, .{}));
        };
        const path = req.param(arena, "path") catch return conn.respond(400, "Bad Request", &close, "");
        const result = backup.executeLive(arena, self.io, worker, .{ .action = wanted, .target = rest[0], .path = path }, &self.backup.open) catch |err| return answerBackupError(conn, err);
        switch (wanted) {
            .run => return conn.respond(202, "Accepted", &json_close, try std.json.Stringify.valueAlloc(arena, BackupRun{ .name = result.started.?.name, .manual_runs = result.started.?.manual_runs }, .{})),
            .forget => return conn.respond(204, "No Content", &close, ""),
            .history => {
                const versions = result.history.?;
                const out = try arena.alloc(BackupVersion, versions.len);
                for (versions, out) |*v, *o| o.* = .{ .path = v.path, .cid = &v.cid, .size = v.size, .mtime = v.mtime, .first_seen = v.first_seen, .last_seen = v.last_seen };
                return conn.respond(200, "OK", &json_close, try std.json.Stringify.valueAlloc(arena, out, .{}));
            },
            .status => {
                const s = result.status.?;
                const body = try std.json.Stringify.valueAlloc(arena, BackupStatus{
                    .storage_class = s.storage_class,
                    .schedule = s.schedule,
                    .indexed_blocks = s.indexed_blocks,
                    .snapshots = s.snapshots,
                    .deferred_packs = s.deferred_packs,
                    .deferred_first = s.deferred_first,
                    .deferred_last = s.deferred_last,
                    .gate = result.gate,
                    .archive_missing = result.archive_missing,
                }, .{});
                return conn.respond(200, "OK", &json_close, body);
            },
            else => unreachable,
        }
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

    fn photosIndex(self: *Server, arena: std.mem.Allocator, conn: *Conn, req: *const Request) !void {
        const timeline = self.photos orelse return conn.respond(404, "Not Found", &close, "");
        const filter = photosFilter(arena, req) catch return conn.respond(400, "Bad Request", &close, "");
        const index = try timeline.index(arena, filter);
        return conn.respond(200, "OK", &json_close, try photos_mod.indexJson(arena, index));
    }

    fn photosPage(self: *Server, arena: std.mem.Allocator, conn: *Conn, req: *const Request) !void {
        const timeline = self.photos orelse return conn.respond(404, "Not Found", &close, "");
        const filter = photosFilter(arena, req) catch return conn.respond(400, "Bad Request", &close, "");
        const generation = numberParam(u64, arena, req, "generation", 0) catch return conn.respond(400, "Bad Request", &close, "");
        const from = numberParam(u32, arena, req, "start", 0) catch return conn.respond(400, "Bad Request", &close, "");
        const count = numberParam(u32, arena, req, "count", photos_mod.max_page) catch return conn.respond(400, "Bad Request", &close, "");
        const page = timeline.page(arena, generation, filter, from, count) catch |err| return answerError(conn, err);
        return conn.respond(200, "OK", &json_close, try photos_mod.pageJson(arena, page));
    }

    /// The thumbnail of the file at `path`, as the node's `thumbnail`
    /// answers it.
    fn thumb(self: *Server, arena: std.mem.Allocator, conn: *Conn, path: []const u8) !void {
        const thumbs = self.thumbs orelse return conn.respond(404, "Not Found", &close, "");
        const info = self.folder.fileInfo(path) orelse return answerError(conn, error.FileNotFound);
        const found = try thumbs.get(arena, info.cid, info.author, media.kindOfName(path), thumb_deadline_ms);
        switch (found) {
            .jpeg_len => |len| {
                // Evicted between the two: as if it weren't here.
                const jpeg = thumbs.readAll(arena, info.cid, len) catch |err| switch (err) {
                    error.FileNotFound => return answerError(conn, error.Unavailable),
                    else => return err,
                };
                return conn.respond(200, "OK", &.{ .{ "Content-Type", "image/jpeg" }, .{ "ETag", try etagOf(arena, info.cid) }, .{ "Connection", "close" } }, jpeg);
            },
            .none => return conn.respond(404, "Not Found", &.{ .{ "Connection", "close" }, .{ "X-NomadFS-Error", "NoThumbnail" } }, ""),
            .pending => return conn.respond(503, "Unavailable", &.{ .{ "Connection", "close" }, .{ "X-NomadFS-Error", "Pending" }, .{ "Retry-After", "2" } }, ""),
            .unavailable => return answerError(conn, error.Unavailable),
        }
    }

    /// The bytes of the file `hex` names, from this device's blocks only:
    /// all of it, or the `Range` asked for.
    fn content(self: *Server, arena: std.mem.Allocator, conn: *Conn, req: *const Request, hex: []const u8) !void {
        const thumbs = self.thumbs orelse return conn.respond(404, "Not Found", &close, "");
        var cid: [32]u8 = undefined;
        if (hex.len != 64) return conn.respond(400, "Bad Request", &close, "");
        _ = std.fmt.hexToBytes(&cid, hex) catch return conn.respond(400, "Bad Request", &close, "");
        // A block missing (or no such file): not this endpoint's to fetch.
        const size = thumbs.localSize(&cid) orelse return conn.respond(404, "Not Found", &.{ .{ "Connection", "close" }, .{ "X-NomadFS-Error", "NotLocal" } }, "");
        var first: u64 = 0;
        var end: u64 = size; // exclusive
        var cr_buf: [80]u8 = undefined;
        const partial = if (req.header("range")) |r| blk: {
            const range = http.parseRange(r, size) orelse {
                return conn.respond(416, "Range Not Satisfiable", &.{ .{ "Connection", "close" }, .{ "Content-Range", try std.fmt.bufPrint(&cr_buf, "bytes */{d}", .{size}) } }, "");
            };
            first, end = range;
            break :blk true;
        } else false;
        var len_buf: [24]u8 = undefined;
        var headers: [5][2][]const u8 = undefined;
        headers[0..4].* = .{
            .{ "Content-Type", "application/octet-stream" },
            .{ "Content-Length", try std.fmt.bufPrint(&len_buf, "{d}", .{end - first}) },
            .{ "Accept-Ranges", "bytes" },
            .{ "Connection", "close" },
        };
        if (partial) headers[4] = .{ "Content-Range", try std.fmt.bufPrint(&cr_buf, "bytes {d}-{d}/{d}", .{ first, end - 1, size }) }; // end > first
        try conn.writeHead(if (partial) 206 else 200, if (partial) "Partial Content" else "OK", headers[0..if (partial) 5 else 4]);
        const buf = try arena.alloc(u8, content_chunk);
        var at = first;
        // Each round sends at least a byte: bounded by the range.
        while (at < end) {
            const want = buf[0..@intCast(@min(buf.len, end - at))];
            const got = try self.folder.readLocal(self.allocator, cid, at, want);
            // A block evicted since the walk: the answer is cut short.
            if (got == 0) return error.EndOfStream;
            try conn.stream.writeAll(want[0..got]);
            at += got;
        }
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

/// The photos filter a request's query asks for (`folder`, `kinds`,
/// `dedupe`); error.BadRequest for a value that isn't one.
fn photosFilter(arena: std.mem.Allocator, req: *const Request) !photos_mod.Filter {
    var filter: photos_mod.Filter = .{};
    if (try req.param(arena, "folder")) |folder| filter.folder = folder;
    if (try req.param(arena, "kinds")) |kinds| filter.kinds = photos_mod.KindSet.parse(kinds) orelse return error.BadRequest;
    if (try req.param(arena, "dedupe")) |v| {
        if (!eql(v, "0") and !eql(v, "1")) return error.BadRequest;
        filter.dedupe = eql(v, "1");
    }
    return filter;
}

/// A decimal query parameter, or `default` when it isn't there (or is
/// empty); error.BadRequest when it isn't a number of that size.
fn numberParam(comptime T: type, arena: std.mem.Allocator, req: *const Request, name: []const u8, default: T) !T {
    const text = try req.param(arena, name) orelse return default;
    if (text.len == 0) return default;
    return std.fmt.parseInt(T, text, 10) catch error.BadRequest;
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
        error.Stale => .{ 409, "Conflict" },
        error.NotSynced => .{ 503, "Not Synced Yet" },
        error.FileNotFound => .{ 404, "Not Found" },
        error.InvalidPath, error.IsDirectory => .{ 400, "Bad Request" },
        error.FileTooLarge, error.BodyTooLarge => .{ 413, "Content Too Large" },
        error.Unavailable, error.BlockNotFound, error.NoHolders, error.NoHolderAskable, error.HoldersUnreachable, error.PeerUnreachable, error.AllAddressesFailed => .{ 503, "Unavailable" },
        else => .{ 500, "Internal Server Error" },
    };
    return conn.respond(code, text, &.{ .{ "Connection", "close" }, .{ "X-NomadFS-Error", @errorName(err) } }, "");
}

/// A backup operation's error as the API's answer.
fn answerBackupError(conn: *Conn, err: anyerror) !void {
    const code: u16, const text: []const u8 = switch (err) {
        error.BackupNotConfigured, error.UnknownBackupTarget => .{ 404, "Not Found" },
        error.InvalidPath, error.PathRequired => .{ 400, "Bad Request" },
        error.DeepBackupOff, error.LeaseHeld, error.Locked, error.BucketVersioningEnabled => .{ 409, "Conflict" },
        error.Cancelled => .{ 503, "Unavailable" },
        else => .{ 500, "Internal Server Error" },
    };
    return conn.respond(code, text, &.{ .{ "Connection", "close" }, .{ "X-NomadFS-Error", @errorName(err) } }, "");
}

const TestFolder = @import("fs/test_fixture.zig").Fixture(SwarmFolder);

/// One GET of `target` (after `/<token>/v1/`) on a test server: the status
/// code, the head and the body, in `arena`.
fn testGet(arena: std.mem.Allocator, server: *Server, target: []const u8) !TestAnswer {
    return testGetWith(arena, server, &server.token, target, "");
}

const TestAnswer = struct { code: u16, head: []const u8, body: []const u8 };

/// `testGet` under `token`, with `headers` (whole lines, each ending in
/// CRLF) added to the request.
fn testGetWith(arena: std.mem.Allocator, server: *Server, token: []const u8, target: []const u8, headers: []const u8) !TestAnswer {
    return testSend(arena, server, "GET", token, target, headers);
}

/// One request with no body.
fn testSend(arena: std.mem.Allocator, server: *Server, method: []const u8, token: []const u8, target: []const u8, headers: []const u8) !TestAnswer {
    const addr = try std.Io.net.IpAddress.parse("127.0.0.1", server.port);
    const stream = try compat.tcpConnectToAddress(.{ .ip = addr });
    defer stream.close();
    try stream.setTimeout(10_000);
    try stream.writeAll(try std.fmt.allocPrint(arena, "{s} /{s}/v1/{s} HTTP/1.1\r\nHost: 127.0.0.1\r\n{s}Content-Length: 0\r\nConnection: close\r\n\r\n", .{ method, token, target, headers }));
    var raw: std.ArrayList(u8) = .empty;
    var buf: [4096]u8 = undefined;
    while (raw.items.len < 8 << 20) {
        const n = try stream.read(&buf);
        if (n == 0) break;
        try raw.appendSlice(arena, buf[0..n]);
    }
    const end = std.mem.indexOf(u8, raw.items, "\r\n\r\n") orelse return error.BadResponse;
    if (end < 12) return error.BadResponse;
    return .{ .code = try std.fmt.parseInt(u16, raw.items[9..12], 10), .head = raw.items[0..end], .body = raw.items[end + 4 ..] };
}

test "swarm api: the photos index and pages, and 409 once the folder changed" {
    const testing = std.testing;
    var t: TestFolder = undefined;
    try t.open(0x61, "Desk");
    defer t.close();
    _ = try t.folder.putBytes("Pixel 8/Camera/a.jpg", "a", null);
    try t.folder.setMtime("Pixel 8/Camera/a.jpg", 200);
    _ = try t.folder.putBytes("Pixel 8/Camera/clip.mp4", "clip", null);
    try t.folder.setMtime("Pixel 8/Camera/clip.mp4", 300);
    _ = try t.folder.putBytes("notes.md", "text", null);
    const timeline = try photos_mod.Timeline.create(testing.allocator, t.folder);
    defer timeline.destroy();
    const server = try Server.start(testing.allocator, t.folder, timeline, null, t.dir);
    defer server.stop();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const Index = struct { generation: u64, total: u32, photos: u32, videos: u32, mtimes: []const u64, folders: []const struct { path: []const u8, count: u32 } };
    const index_answer = try testGet(arena, server, "photos/index?folder=Pixel%208");
    try testing.expectEqual(@as(u16, 200), index_answer.code);
    const index = try std.json.parseFromSliceLeaky(Index, arena, index_answer.body, .{});
    try testing.expectEqual(@as(u32, 2), index.total);
    try testing.expectEqual(@as(u32, 1), index.photos);
    try testing.expectEqual(@as(u32, 1), index.videos);
    try testing.expectEqualSlices(u64, &.{ 300, 200 }, index.mtimes);
    try testing.expectEqualStrings("Pixel 8/Camera", index.folders[1].path);

    const Page = struct { generation: u64, total: u32, items: []const struct { index: u32, path: []const u8, name: []const u8, cid: []const u8, author: []const u8, size: u64, mtime: u64, kind: []const u8, thumb: []const u8 } };
    const page_answer = try testGet(arena, server, try std.fmt.allocPrint(arena, "photos?folder=Pixel+8&generation={d}&start=1&count=5", .{index.generation}));
    try testing.expectEqual(@as(u16, 200), page_answer.code);
    const page = try std.json.parseFromSliceLeaky(Page, arena, page_answer.body, .{});
    try testing.expectEqual(index.generation, page.generation);
    try testing.expectEqual(@as(u32, 2), page.total);
    try testing.expectEqual(@as(usize, 1), page.items.len);
    try testing.expectEqual(@as(u32, 1), page.items[0].index);
    try testing.expectEqualStrings("Pixel 8/Camera/a.jpg", page.items[0].path);
    try testing.expectEqualStrings("a.jpg", page.items[0].name);
    try testing.expectEqualStrings("photo", page.items[0].kind);
    try testing.expectEqualStrings("unknown", page.items[0].thumb);
    try testing.expectEqualStrings(&std.fmt.bytesToHex(t.folder.fileInfo("Pixel 8/Camera/a.jpg").?.cid, .lower), page.items[0].cid);
    try testing.expectEqualStrings("61" ** 32, page.items[0].author);

    // Only films; no generation: the page as of now.
    const films = try std.json.parseFromSliceLeaky(Page, arena, (try testGet(arena, server, "photos?kinds=videos")).body, .{});
    try testing.expectEqual(@as(usize, 1), films.items.len);
    try testing.expectEqualStrings("video", films.items[0].kind);

    try testing.expectEqual(@as(u16, 400), (try testGet(arena, server, "photos?start=x")).code);
    try testing.expectEqual(@as(u16, 400), (try testGet(arena, server, "photos/index?kinds=films")).code);
    try testing.expectEqual(@as(u16, 404), (try testGet(arena, server, "photos/other")).code);
    // This server has no thumbnails.
    try testing.expectEqual(@as(u16, 404), (try testGet(arena, server, "thumb/Pixel%208/Camera/a.jpg")).code);

    // The folder changed: a page of the old index is refused.
    _ = try t.folder.putBytes("new.png", "new", null);
    try testing.expectEqual(@as(u16, 409), (try testGet(arena, server, try std.fmt.allocPrint(arena, "photos?generation={d}", .{index.generation}))).code);
}

test "swarm api: a thumbnail, none for a format no decoder reads, 404 for no file" {
    const testing = std.testing;
    const image = @import("codec/mod.zig").image;
    var t: TestFolder = undefined;
    try t.open(0x62, "Desk");
    defer t.close();
    const picture = try image.testing.gradientJpeg(testing.allocator, 800, 400, 1);
    defer testing.allocator.free(picture);
    _ = try t.folder.putBytes("Pixel 8/Camera/a.jpg", picture, null);
    _ = try t.folder.putBytes("Pixel 8/Camera/b.heic", "\x00\x00\x00\x18ftypheic\x00\x00\x00\x00", null);
    const thumbs_dir = try std.fs.path.join(testing.allocator, &.{ t.dir, "blocks.thumbs" });
    defer testing.allocator.free(thumbs_dir);
    const thumbs = try thumbs_mod.Thumbs.create(testing.allocator, testing.io, &t.store, t.folder, thumbs_dir, .{});
    defer thumbs.destroy();
    const server = try Server.start(testing.allocator, t.folder, null, thumbs, t.dir);
    defer server.stop();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const made = try testGet(arena, server, "thumb/Pixel%208/Camera/a.jpg");
    try testing.expectEqual(@as(u16, 200), made.code);
    try testing.expect(std.mem.indexOf(u8, made.head, "Content-Type: image/jpeg") != null);
    const dims = try image.info(made.body);
    try testing.expectEqual(@as(u32, 320), dims.width);
    try testing.expectEqual(@as(u32, 160), dims.height);
    // The same bytes again, from the store.
    try testing.expectEqualSlices(u8, made.body, (try testGet(arena, server, "thumb/Pixel%208/Camera/a.jpg")).body);
    try testing.expectEqual(@as(u64, 1), thumbs.generated.load(.monotonic));

    const none = try testGet(arena, server, "thumb/Pixel%208/Camera/b.heic");
    try testing.expectEqual(@as(u16, 404), none.code);
    try testing.expect(std.mem.indexOf(u8, none.head, "X-NomadFS-Error: NoThumbnail") != null);
    const missing = try testGet(arena, server, "thumb/Pixel%208/Camera/nope.jpg");
    try testing.expectEqual(@as(u16, 404), missing.code);
    try testing.expect(std.mem.indexOf(u8, missing.head, "X-NomadFS-Error: FileNotFound") != null);
    try testing.expectEqual(@as(u16, 404), (try testGet(arena, server, "thumb")).code);
}

test "swarm api: a file's bytes by content ID, in ranges, only when all of it is here" {
    const testing = std.testing;
    var t: TestFolder = undefined;
    try t.open(0x63, "Desk");
    defer t.close();
    // Several blocks, so a range crosses them.
    const bytes = try testing.allocator.alloc(u8, 3 * 1024 * 1024 + 123);
    defer testing.allocator.free(bytes);
    var prng = std.Random.DefaultPrng.init(63);
    prng.random().bytes(bytes);
    const cid = (try t.folder.putBytes("Camera/clip.mp4", bytes, null)).cid;
    const far_bytes = try testing.allocator.dupe(u8, bytes[1..]);
    defer testing.allocator.free(far_bytes);
    const far = (try t.folder.putBytes("Camera/far.mp4", far_bytes, null)).cid;
    const thumbs_dir = try std.fs.path.join(testing.allocator, &.{ t.dir, "blocks.thumbs" });
    defer testing.allocator.free(thumbs_dir);
    const thumbs = try thumbs_mod.Thumbs.create(testing.allocator, testing.io, &t.store, t.folder, thumbs_dir, .{});
    defer thumbs.destroy();
    const server = try Server.start(testing.allocator, t.folder, null, thumbs, t.dir);
    defer server.stop();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const target = try std.fmt.allocPrint(arena, "content/{s}", .{&std.fmt.bytesToHex(cid, .lower)});

    const whole = try testGet(arena, server, target);
    try testing.expectEqual(@as(u16, 200), whole.code);
    try testing.expect(std.mem.indexOf(u8, whole.head, "Accept-Ranges: bytes") != null);
    try testing.expectEqualSlices(u8, bytes, whole.body);

    const first = try testGetWith(arena, server, &server.token, target, "Range: bytes=0-99\r\n");
    try testing.expectEqual(@as(u16, 206), first.code);
    try testing.expect(std.mem.indexOf(u8, first.head, try std.fmt.allocPrint(arena, "Content-Range: bytes 0-99/{d}", .{bytes.len})) != null);
    try testing.expect(std.mem.indexOf(u8, first.head, "Content-Length: 100\r\n") != null);
    try testing.expectEqualSlices(u8, bytes[0..100], first.body);

    const rest = try testGetWith(arena, server, &server.token, target, "Range: bytes=100-\r\n");
    try testing.expectEqual(@as(u16, 206), rest.code);
    try testing.expect(std.mem.indexOf(u8, rest.head, try std.fmt.allocPrint(arena, "Content-Range: bytes 100-{d}/{d}", .{ bytes.len - 1, bytes.len })) != null);
    try testing.expectEqualSlices(u8, bytes[100..], rest.body);

    // Across a block's end, and the last bytes (where a film's index is).
    const middle = try testGetWith(arena, server, &server.token, target, "Range: bytes=1048000-1049999\r\n");
    try testing.expectEqualSlices(u8, bytes[1048000..1050000], middle.body);
    const tail = try testGetWith(arena, server, &server.token, target, "Range: bytes=-16\r\n");
    try testing.expectEqual(@as(u16, 206), tail.code);
    try testing.expectEqualSlices(u8, bytes[bytes.len - 16 ..], tail.body);

    const past = try testGetWith(arena, server, &server.token, target, try std.fmt.allocPrint(arena, "Range: bytes={d}-\r\n", .{bytes.len}));
    try testing.expectEqual(@as(u16, 416), past.code);
    try testing.expect(std.mem.indexOf(u8, past.head, try std.fmt.allocPrint(arena, "Content-Range: bytes */{d}", .{bytes.len})) != null);

    // The token ffmpeg's URL carries opens this and nothing else.
    var url_buf: [thumbs_mod.max_input_url]u8 = undefined;
    const input = server.videoInput();
    const url = input.urlFn(input.ctx, &cid, &url_buf).?;
    try testing.expect(std.mem.indexOf(u8, url, &server.token) == null);
    try testing.expect(std.mem.endsWith(u8, url, target));
    const by_url = try testGetWith(arena, server, &server.content_token, target, "Range: bytes=0-9\r\n");
    try testing.expectEqualSlices(u8, bytes[0..10], by_url.body);
    try testing.expectEqual(@as(u16, 404), (try testGetWith(arena, server, &server.content_token, "status", "")).code);
    try testing.expectEqual(@as(u16, 404), (try testGetWith(arena, server, &server.content_token, "files/Camera/clip.mp4", "")).code);
    try testing.expectEqual(@as(u16, 404), (try testGetWith(arena, server, "0" ** 64, target, "")).code);

    // A block of it missing: not served, and nothing is fetched for it.
    var leaves: std.ArrayList([32]u8) = .empty;
    defer leaves.deinit(testing.allocator);
    const tree = @import("fs/tree.zig");
    try tree.leavesIn(testing.allocator, tree.Loader.local(&t.store), far, 0, 0, far_bytes.len, &leaves, 64);
    try t.tmp.dir.deleteFile(testing.io, "blocks/" ++ std.fmt.bytesToHex(leaves.items[leaves.items.len - 1], .lower));
    const missing = try testGet(arena, server, try std.fmt.allocPrint(arena, "content/{s}", .{&std.fmt.bytesToHex(far, .lower)}));
    try testing.expectEqual(@as(u16, 404), missing.code);
    try testing.expect(std.mem.indexOf(u8, missing.head, "X-NomadFS-Error: NotLocal") != null);
    // A content ID nothing here has, and what is no content ID.
    try testing.expectEqual(@as(u16, 404), (try testGet(arena, server, "content/" ++ "ee" ** 32)).code);
    try testing.expectEqual(@as(u16, 400), (try testGet(arena, server, "content/abc")).code);
}

test "swarm api: ffmpeg takes a film's frame through the content endpoint" {
    const testing = std.testing;
    const codec = @import("codec/mod.zig");
    var t: TestFolder = undefined;
    try t.open(0x64, "Desk");
    defer t.close();
    // Skips without ffmpeg.
    const path = try codec.video.testing.clip(testing.allocator, t.tmp.dir, "clip.mp4", "2");
    defer testing.allocator.free(path);
    const film = try t.tmp.dir.readFileAlloc(testing.io, "clip.mp4", testing.allocator, .limited(4 * 1024 * 1024));
    defer testing.allocator.free(film);
    _ = try t.folder.putBytes("Pixel 8/Camera/clip.mp4", film, null);
    const thumbs_dir = try std.fs.path.join(testing.allocator, &.{ t.dir, "blocks.thumbs" });
    defer testing.allocator.free(thumbs_dir);
    const thumbs = try thumbs_mod.Thumbs.create(testing.allocator, testing.io, &t.store, t.folder, thumbs_dir, .{});
    defer thumbs.destroy();
    const server = try Server.start(testing.allocator, t.folder, null, thumbs, t.dir);
    defer server.stop();
    thumbs.setVideoInput(server.videoInput());
    defer thumbs.setVideoInput(null);
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const made = try testGet(arena, server, "thumb/Pixel%208/Camera/clip.mp4");
    try testing.expectEqual(@as(u16, 200), made.code);
    const dims = try codec.image.info(made.body);
    try testing.expectEqual(@as(u32, 320), dims.width);
    try testing.expectEqual(@as(u32, 180), dims.height);
    try testing.expectEqual(@as(u64, 1), thumbs.generated.load(.monotonic));
}

/// The list's state of target `name`, once its runs by hand passed `after`.
fn testBackupRun(arena: std.mem.Allocator, server: *Server, name: []const u8, after: u64) !backup.TargetState {
    var tries: usize = 0;
    while (tries < 600) : (tries += 1) {
        const all = try std.json.parseFromSliceLeaky(backup.Overview, arena, (try testGet(arena, server, "backup")).body, .{});
        for (all.targets) |t| if (eql(t.name, name) and t.manual_runs > after) return t;
        sync.sleep(50 * std.time.ns_per_ms);
    }
    return error.RunNeverEnded;
}

test "swarm api: backup lists the targets, runs one, and a purge names the versions of the live folder" {
    const testing = std.testing;
    const device = @import("device/mod.zig");
    var t: TestFolder = undefined;
    try t.open(0x65, "Desk");
    defer t.close();
    _ = try t.folder.putBytes("keep.txt", "keep", null);
    _ = try t.folder.putBytes("Photos/old.jpg", "old", null);
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // The node's uploader on a bucket in memory: two targets, the second
    // an archive this device (swarm backup only) doesn't upload to.
    var fake: @import("cluster/offsite_test.zig").Fake = .{};
    defer fake.deinit();
    const credentials = try std.fs.path.join(arena, &.{ t.dir, "credentials" });
    {
        const f = try t.tmp.dir.createFile(testing.io, "credentials", .{ .permissions = .fromMode(0o600) });
        defer f.close(testing.io);
        try f.writeStreamingAll(testing.io, "access_key_id = id\nsecret_access_key = secret\n");
    }
    var trust = try device.trust.Store.load(testing.allocator, try std.fs.path.join(arena, &.{ t.dir, "trusted" }), null);
    defer trust.deinit();
    var source: @import("fs/offsite.zig").Source = .{ .folder = t.folder, .store = &t.store };
    const worker = try offsite_worker.Worker.create(testing.allocator, &.{
        .{ .name = "main", .endpoint = "https://endpoint", .bucket = "bucket", .credentials = credentials, .prefix = "swarm", .pack_mb = 1 },
        .{ .name = "archive", .endpoint = "https://endpoint", .bucket = "bucket", .credentials = credentials, .prefix = "cold", .pack_mb = 1, .storage_class = .DEEP_ARCHIVE },
    }, try device.identity.Identity.fromSeed([_]u8{5} ** 32), &trust, source.source(), &t.store);
    defer worker.destroy();
    worker.transport = fake.transport();
    worker.setRoles(.{ .swarm_backup = true });

    const server = try Server.start(testing.allocator, t.folder, null, null, t.dir);
    defer server.stop();
    // A node that uploads nowhere.
    const none = try testGet(arena, server, "backup");
    try testing.expectEqual(@as(u16, 404), none.code);
    try testing.expect(std.mem.indexOf(u8, none.head, "X-NomadFS-Error: BackupNotConfigured") != null);
    server.setBackup(worker);
    defer server.setBackup(null);
    try worker.start();

    // The list: every target, why one doesn't upload, nothing run yet.
    const listed = try testGet(arena, server, "backup");
    try testing.expectEqual(@as(u16, 200), listed.code);
    const all = try std.json.parseFromSliceLeaky(backup.Overview, arena, listed.body, .{});
    try testing.expect(all.swarm_backup and !all.deep_backup and !all.archive_missing);
    try testing.expectEqual(@as(usize, 2), all.targets.len);
    try testing.expectEqualStrings("main", all.targets[0].name);
    try testing.expectEqual(backup.Gate.uploading, all.targets[0].gate);
    try testing.expectEqualStrings("", all.targets[0].not_uploading);
    try testing.expectEqual(@as(u64, 0), all.targets[0].last_upload);
    try testing.expect(!all.targets[0].running and all.targets[0].failure == null);
    try testing.expect(all.targets[1].cold);
    try testing.expectEqual(backup.Gate.needs_deep_backup, all.targets[1].gate);
    try testing.expect(std.mem.indexOf(u8, all.targets[1].not_uploading, "deep backup") != null);

    // No such target, no such route; an archive without deep backup.
    for ([_][2][]const u8{ .{ "GET", "backup/nope" }, .{ "POST", "backup/nope/run" }, .{ "POST", "backup/nope/forget?path=a" }, .{ "GET", "backup/nope/history" } }) |q| {
        const unknown = try testSend(arena, server, q[0], &server.token, q[1], "");
        try testing.expectEqual(@as(u16, 404), unknown.code);
        try testing.expect(std.mem.indexOf(u8, unknown.head, "X-NomadFS-Error: UnknownBackupTarget") != null);
    }
    try testing.expectEqual(@as(u16, 404), (try testGet(arena, server, "backup/main/run")).code);
    try testing.expectEqual(@as(u16, 404), (try testSend(arena, server, "POST", &server.token, "backup/main", "")).code);
    try testing.expectEqual(@as(u16, 405), (try testSend(arena, server, "DELETE", &server.token, "backup/main", "")).code);
    const cold = try testSend(arena, server, "POST", &server.token, "backup/archive/run", "");
    try testing.expectEqual(@as(u16, 409), cold.code);
    try testing.expect(std.mem.indexOf(u8, cold.head, "X-NomadFS-Error: DeepBackupOff") != null);

    // `run` only starts the upload ("s3" is the first target); the list
    // tells when it ended and what it did.
    const accepted = try testSend(arena, server, "POST", &server.token, "backup/s3/run", "");
    try testing.expectEqual(@as(u16, 202), accepted.code);
    const started = try std.json.parseFromSliceLeaky(BackupRun, arena, accepted.body, .{});
    try testing.expectEqualStrings("main", started.name);
    try testing.expectEqual(@as(u64, 0), started.manual_runs);
    const first = try testBackupRun(arena, server, "main", 0);
    try testing.expect(first.failure == null and !first.running and !first.requested);
    try testing.expect(first.last_upload > 0 and first.uploaded_blocks > 0 and first.new_key);
    try testing.expect(std.mem.startsWith(u8, first.snapshot, "snapshots/"));
    try testing.expectEqual(@as(usize, 0), first.waiting_files);

    // One target's bucket.
    const detail = try testGet(arena, server, "backup/main");
    try testing.expectEqual(@as(u16, 200), detail.code);
    const status = try std.json.parseFromSliceLeaky(BackupStatus, arena, detail.body, .{});
    try testing.expectEqual(@as(usize, 1), status.snapshots.len);
    try testing.expectEqualStrings(first.snapshot, status.snapshots[0]);
    try testing.expect(status.indexed_blocks > 0);
    try testing.expectEqual(backup.Gate.uploading, status.gate);

    const History = []const BackupVersion;
    const before = try std.json.parseFromSliceLeaky(History, arena, (try testGet(arena, server, "backup/main/history")).body, .{});
    try testing.expectEqual(@as(usize, 2), before.len);
    try testing.expectEqualStrings("Photos/old.jpg", before[0].path);
    try testing.expectEqualStrings(&std.fmt.bytesToHex(t.folder.fileInfo("Photos/old.jpg").?.cid, .lower), before[0].cid);
    try testing.expectEqualStrings("keep.txt", before[1].path);
    const under = try std.json.parseFromSliceLeaky(History, arena, (try testGet(arena, server, "backup/main/history?path=Photos")).body, .{});
    try testing.expectEqual(@as(usize, 1), under.len);

    // A file the folder has and the backup has never seen: the purge is
    // recorded with its version, read from the node's live folder, so the
    // next upload leaves it out too.
    _ = try t.folder.putBytes("Photos/new.jpg", "new", null);
    const no_path = try testSend(arena, server, "POST", &server.token, "backup/main/forget", "");
    try testing.expectEqual(@as(u16, 400), no_path.code);
    try testing.expect(std.mem.indexOf(u8, no_path.head, "X-NomadFS-Error: PathRequired") != null);
    try testing.expectEqual(@as(u16, 400), (try testSend(arena, server, "POST", &server.token, "backup/main/forget?path=a%2F%2Fb", "")).code);
    try testing.expectEqual(@as(u16, 204), (try testSend(arena, server, "POST", &server.token, "backup/main/forget?path=Photos", "")).code);
    try testing.expectEqual(@as(u16, 202), (try testSend(arena, server, "POST", &server.token, "backup/main/run", "")).code);
    const second = try testBackupRun(arena, server, "main", 1);
    try testing.expect(second.failure == null and !second.new_key);
    const after = try std.json.parseFromSliceLeaky(History, arena, (try testGet(arena, server, "backup/main/history")).body, .{});
    try testing.expectEqual(@as(usize, 1), after.len);
    try testing.expectEqualStrings("keep.txt", after[0].path);
    // The folder still lists both pictures: only the backup forgot them.
    try testing.expect(t.folder.fileInfo("Photos/new.jpg") != null);

    // `nomadfs backup add|remove` changed the configuration: the node is
    // asked to read its targets again, when it said how.
    const no_reload = try testSend(arena, server, "POST", &server.token, "backup/reload", "");
    try testing.expectEqual(@as(u16, 500), no_reload.code);
    try testing.expect(std.mem.indexOf(u8, no_reload.head, "X-NomadFS-Error: ReloadUnsupported") != null);
    const Counter = struct {
        calls: usize = 0,
        fn reload(ctx: *anyopaque) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.calls += 1;
        }
    };
    var counter: Counter = .{};
    server.setReload(.{ .ctx = &counter, .reloadFn = Counter.reload });
    try testing.expectEqual(@as(u16, 204), (try testSend(arena, server, "POST", &server.token, "backup/reload", "")).code);
    try testing.expectEqual(@as(usize, 1), counter.calls);
    server.setReload(null);

    // The uploader taken away (the node stopping): the routes are gone.
    server.setBackup(null);
    try testing.expectEqual(@as(u16, 404), (try testGet(arena, server, "backup")).code);

    // The targets changed while the node runs: the new uploader keeps what
    // the old one knew about the target that stays, and starts the new
    // one from nothing.
    worker.stop();
    const next = try offsite_worker.Worker.create(testing.allocator, &.{
        .{ .name = "main", .endpoint = "https://endpoint", .bucket = "bucket", .credentials = credentials, .prefix = "swarm", .pack_mb = 1 },
        .{ .name = "extra", .endpoint = "https://endpoint", .bucket = "bucket", .credentials = credentials, .prefix = "extra", .pack_mb = 1 },
    }, try device.identity.Identity.fromSeed([_]u8{5} ** 32), &trust, source.source(), &t.store);
    defer next.destroy();
    next.setRoles(.{ .swarm_backup = true });
    // The words typed back while the old uploader ran stay confirmed.
    try testing.expect(worker.setWordsConfirmed("main") and !worker.setWordsConfirmed("nope"));
    next.inherit(worker);
    const kept = next.statusOf("main").?;
    try testing.expect(kept.words_confirmed and !next.statusOf("extra").?.words_confirmed);
    var listed_next = try backup.overview(testing.allocator, next);
    defer backup.deinitOverview(testing.allocator, &listed_next);
    try testing.expect(listed_next.targets[0].words_confirmed and !listed_next.targets[1].words_confirmed);
    try testing.expect(kept.last_upload > 0 and kept.failure == null and !kept.running);
    try testing.expectEqualStrings(worker.statusOf("main").?.snapshot(), kept.snapshot());
    try testing.expectEqualStrings("main", kept.name);
    try testing.expectEqual(@as(u64, 0), next.statusOf("extra").?.last_upload);
    try testing.expect(next.statusOf("archive") == null);
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
