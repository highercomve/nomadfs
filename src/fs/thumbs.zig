//! Thumbnails of the swarm folder's pictures: a small JPEG per file, by
//! its content ID. `get` is the one way to one: what is stored already
//! (thumb_store.zig), else made here when every block of the file is on
//! this device, else asked of another device (`remote`), else not to be
//! had now. A file's blocks are never fetched to make its thumbnail: that
//! would pull whole photo libraries onto a phone for a page of small
//! pictures.
//!
//! A film's thumbnail is a frame ffmpeg takes (codec/video.zig), on a
//! device that has ffmpeg and all of the film. ffmpeg reads the film from
//! wherever the node says (`VideoInput`); a device without it asks the
//! others, those that announce they take frames first.
//!
//! Every front end goes through the node's `thumbnail` and `thumbRead`,
//! which are `get` and `read` here.
//!
//! Other devices ask this one the same way (`answer`, behind the cluster's
//! GET_DERIVED): what is stored is given to any device of the swarm; one
//! is made on the spot only for a trusted device and only with a decode
//! slot free, and otherwise noted in `wanted` for later.

const std = @import("std");
const builtin = @import("builtin");
const sync = @import("../sync.zig");
const storage = @import("../storage/mod.zig");
const codec = @import("../codec/mod.zig");
const media = @import("media.zig");
const photos = @import("photos.zig");
const tree = @import("tree.zig");
const swarm_mod = @import("swarm.zig");
const thumb_store = @import("thumb_store.zig");
const cluster = @import("../cluster/mod.zig");
const remote_mod = @import("remote.zig");

const SwarmFolder = swarm_mod.SwarmFolder;
const StorageEngine = storage.engine.StorageEngine;
const dag = storage.dag.codec;

pub const Reason = thumb_store.Reason;

/// What this build's decoders read: raised when one is added, so files an
/// older build marked as having no thumbnail are tried again.
pub const codec_version: u8 = 4;
/// A file larger than this is not read to make a thumbnail.
pub const max_source_len = 64 * 1024 * 1024;
/// What other devices are asked for (GET_DERIVED's `kind`): a JPEG whose
/// long edge is 320 pixels. The number means nothing below this layer.
pub const kind_jpeg_320: u8 = 1;
/// The long edge of a thumbnail, in pixels (what `kind_jpeg_320` names).
const thumb_edge = 320;
/// The longest URL a `VideoInput` gives.
pub const max_input_url = 256;
/// How long ffmpeg has for a frame another device waits for: well inside
/// that device's ten seconds for the answer.
const answer_frame_timeout_ms: u32 = 7_000;
/// Files other devices asked for that were not made on the spot.
pub const max_wanted = 256;
/// Generations asked for at once, running or waiting for a slot.
const max_in_flight = 32;
/// Blocks one "is it all here" walk looks at (a file of this many chunks
/// is a film of tens of gigabytes).
const max_walk_blocks = 1 << 20;
const max_tree_depth = 64;

pub const Options = struct {
    /// Most bytes of thumbnails got from other devices; 0: no limit.
    cache_limit: u64 = 512 * 1024 * 1024,
    /// Make a thumbnail here when the file is here, before asking anyone.
    /// Off on a phone: a device that already made it answers for less
    /// battery than a decode.
    prefer_local: bool = true,
    /// Pictures with more pixels are not decoded.
    max_pixels: u64 = if (builtin.abi.isAndroid()) 24_000_000 else 120_000_000,
};

/// What `get` found.
pub const Result = union(enum) {
    /// A thumbnail of this many bytes: `read` gives them.
    jpeg_len: u32,
    /// None can be made of this file.
    none: Reason,
    /// One is being made (here or on the device asked): ask again shortly.
    pending,
    /// The file is not here and nobody reachable has its thumbnail.
    unavailable,
};

/// Asking other devices for a thumbnail: the step between "stored" and
/// "made here" that the layer below fills in (who holds the file, in what
/// order, over which message). Null: nobody is asked.
pub const Remote = struct {
    ctx: *anyopaque,
    askFn: *const fn (ctx: *anyopaque, allocator: std.mem.Allocator, ask: Ask) Answer,

    pub const Ask = struct {
        cid: [32]u8,
        /// The device that wrote the file: the first to ask.
        author: [32]u8,
        /// What the file's name says it is (a film is asked of devices
        /// that can take a frame).
        kind: media.Kind,
        deadline_ms: u32,
    };

    pub const Answer = union(enum) {
        /// The JPEG, caller-owned (allocated with `allocator`). Unchecked:
        /// `get` validates it before it is stored.
        found: []u8,
        /// A device that has the file says none can be made.
        none: Reason,
        /// A device is making it.
        busy,
        /// Nobody reachable has the file.
        nobody,
    };
};

/// Where ffmpeg reads a film's bytes from: what the node fills in, so
/// nothing here knows how they are served. Null: no frames are taken.
pub const VideoInput = struct {
    ctx: *anyopaque,
    /// A URL (or path) into `buf` (`max_input_url` bytes) that gives the
    /// file `cid` from this device's blocks, with seeking; null when it
    /// cannot be served now.
    urlFn: *const fn (ctx: *anyopaque, cid: *const [32]u8, buf: []u8) ?[]const u8,
};

pub const Thumbs = struct {
    allocator: std.mem.Allocator,
    /// The blocks the files are made of; outlives this.
    blocks: *StorageEngine,
    /// The folder whose files these are thumbnails of; outlives this.
    folder: *SwarmFolder,
    store: thumb_store.ThumbStore,
    prefer_local: bool,
    max_pixels: u64,
    /// Set once, before the first `get` from another thread.
    remote: ?Remote = null,
    video: struct {
        /// Guards `input`: the node takes it back while requests of other
        /// devices may still be answered.
        mutex: sync.Mutex = .{},
        input: ?VideoInput = null,
    } = .{},
    /// Files other devices asked for and this one has but did not make a
    /// thumbnail of then (no slot free, or the asker not trusted): what a
    /// worker makes first. The oldest gives way when it is full.
    wanted: struct {
        /// Guards the fields below.
        mutex: sync.Mutex = .{},
        cids: [max_wanted][32]u8 = undefined,
        len: usize = 0,
        /// Where the next one goes once `cids` is full.
        next: usize = 0,
    } = .{},
    /// Thumbnails made here since the start.
    generated: std.atomic.Value(u64) = .init(0),
    gen: struct {
        /// Guards the fields below.
        mutex: sync.Mutex = .{},
        /// A generation ended (or gave up its place).
        done: sync.Condition = .{},
        /// The files being made, or waiting for a slot.
        cids: [max_in_flight][32]u8 = undefined,
        len: usize = 0,
        /// Decodes running now: `slots()` at most.
        running: u8 = 0,
    } = .{},

    /// Thumbnails of `folder`'s files, kept in the folder `dir`
    /// (`<storage_path>.thumbs`). `blocks` is the store `folder` is on.
    pub fn create(allocator: std.mem.Allocator, io: std.Io, blocks: *StorageEngine, folder: *SwarmFolder, dir: []const u8, opts: Options) !*Thumbs {
        const self = try allocator.create(Thumbs);
        errdefer allocator.destroy(self);
        self.* = .{
            .allocator = allocator,
            .blocks = blocks,
            .folder = folder,
            .store = try thumb_store.ThumbStore.open(allocator, io, dir, .{ .cache_limit = opts.cache_limit, .codec_ver = codec_version }),
            .prefer_local = opts.prefer_local,
            .max_pixels = opts.max_pixels,
        };
        return self;
    }

    /// Callers of `get` are gone by now.
    pub fn destroy(self: *Thumbs) void {
        self.store.close();
        self.allocator.destroy(self);
    }

    /// The thumbnail of the file `cid`, which `author` wrote and whose name
    /// says it is a `name_kind` (`.other` when the caller has no name).
    /// Waits `deadline_ms` at most for a decode slot or another caller's
    /// generation of the same file, then answers `.pending`.
    pub fn get(self: *Thumbs, allocator: std.mem.Allocator, cid: [32]u8, author: [32]u8, name_kind: media.Kind, deadline_ms: u32) !Result {
        if (self.stored(&cid)) |found| return found;
        const until = sync.monotonicMillis() +| deadline_ms;
        const size = self.localSize(&cid);
        // A film that is here on a device that takes no frames: as if it
        // were not, until nobody else has its thumbnail either.
        const here_first = self.prefer_local and (self.canTakeFrames() or !self.isFilm(allocator, &cid, name_kind, size));
        if (here_first) if (size) |n| return self.generate(allocator, &cid, name_kind, n, until, codec.video.default_timeout_ms);

        if (self.remote) |remote| {
            const reply = remote.askFn(remote.ctx, allocator, .{ .cid = cid, .author = author, .kind = name_kind, .deadline_ms = deadline_ms });
            switch (reply) {
                .found => |jpeg| {
                    defer allocator.free(jpeg);
                    // Not a thumbnail: as if nobody had answered.
                    if (self.store.put(&cid, .cache, jpeg)) |_| {
                        return .{ .jpeg_len = @intCast(jpeg.len) }; // validated: <= max_jpeg_len
                    } else |err| if (err != error.InvalidThumbnail) return err;
                },
                .none => |reason| {
                    // Without the marker it is only asked again.
                    self.store.putNone(&cid, reason, .remote) catch {};
                    return .{ .none = reason };
                },
                .busy => return .pending,
                .nobody => {},
            }
        }
        if (size) |n| return self.generate(allocator, &cid, name_kind, n, until, codec.video.default_timeout_ms);
        return .unavailable;
    }

    /// Where ffmpeg reads films from (the node's local API), or null to
    /// take it back: after this returns the old one is not called again.
    pub fn setVideoInput(self: *Thumbs, input: ?VideoInput) void {
        self.video.mutex.lock();
        defer self.video.mutex.unlock();
        self.video.input = input;
    }

    /// Whether this device takes frames of films now: it has ffmpeg, and
    /// somewhere for it to read them from.
    pub fn canTakeFrames(self: *Thumbs) bool {
        self.video.mutex.lock();
        const wired = self.video.input != null;
        self.video.mutex.unlock();
        return wired and codec.video.available();
    }

    /// The URL ffmpeg reads `cid` from, into `buf`; null with no input.
    fn videoUrl(self: *Thumbs, cid: *const [32]u8, buf: *[max_input_url]u8) ?[]const u8 {
        self.video.mutex.lock();
        defer self.video.mutex.unlock();
        const input = self.video.input orelse return null;
        return input.urlFn(input.ctx, cid, buf);
    }

    /// Whether the file is a film: by its name, or, for a caller that has
    /// no name (`.other`), by its first bytes when it is here.
    fn isFilm(self: *Thumbs, allocator: std.mem.Allocator, cid: *const [32]u8, name_kind: media.Kind, size: ?u64) bool {
        if (name_kind != .other) return name_kind == .video;
        if (size == null) return false;
        var head: [media.sniff_len]u8 = undefined;
        const n = (self.readLocal(allocator, cid, &head) catch return false) orelse return false;
        return media.sniff(head[0..n]) == .video;
    }

    /// Asking the other devices of the swarm, through the folder's block
    /// manager: what the node sets as `remote`. Nobody is asked while the
    /// folder is not started.
    pub fn clusterRemote(self: *Thumbs) Remote {
        return .{ .ctx = self, .askFn = askHolders };
    }

    /// The file's likely holders (the folder's hints: its author, the
    /// swarm backups, placement replicas, the rest) are asked for its
    /// thumbnail, a film's of those that can take a frame first.
    fn askHolders(ctx: *anyopaque, allocator: std.mem.Allocator, ask: Remote.Ask) Remote.Answer {
        const self: *Thumbs = @ptrCast(@alignCast(ctx));
        const bm = self.folder.block_manager orelse return .nobody;
        var buffer = remote_mod.holdersBuffer();
        const holders = self.folder.holdersOf(allocator, &ask.cid, .{ .bytes = ask.author }, &buffer);
        const derived = bm.askDerived(allocator, ask.cid, kind_jpeg_320, holders, .{
            .prefer_role = if (ask.kind == .video) cluster.Roles.video_thumbs else 0,
            .deadline_ms = ask.deadline_ms,
        }) catch return .nobody; // out of memory: as if nobody had it
        return switch (derived) {
            .found => |jpeg| .{ .found = jpeg },
            // A reason a newer build gives: no thumbnail, whatever it is.
            .none => |reason| .{ .none = std.enums.fromInt(Reason, reason) orelse .unsupported_format },
            .busy => .busy,
            .unavailable => .nobody,
        };
    }

    /// What this device tells another that asks for the file's `kind`
    /// (GET_DERIVED). A stored thumbnail is given to anyone in the swarm.
    /// One is made now only for a `trusted` device, when the whole file is
    /// here and a decode slot is free; else the file is noted in `wanted`
    /// and the answer is busy. Found bytes are caller-owned (`allocator`).
    pub fn answer(self: *Thumbs, allocator: std.mem.Allocator, trusted: bool, cid: [32]u8, kind: u8) !cluster.DerivedAnswer {
        if (kind != kind_jpeg_320) return .unknown_kind;
        if (try self.storedAnswer(allocator, &cid)) |found| return found;
        const size = self.localSize(&cid) orelse return .not_held;
        if (trusted) {
            // No wait: with every slot taken the asker comes back. The
            // name is not known here; the file's first bytes say what it is.
            // A film's frame is made now too, with less time than at home:
            // the asker gives up after ten seconds, and nothing but this
            // makes what `wanted` holds yet. One that takes longer stays
            // wanted, for a worker with more patience.
            switch (try self.generate(allocator, &cid, .other, size, sync.monotonicMillis(), answer_frame_timeout_ms)) {
                .jpeg_len, .none => if (try self.storedAnswer(allocator, &cid)) |found| return found,
                .pending => {},
                // A block went since the walk.
                .unavailable => return .not_held,
            }
        }
        // Only swarm members may queue work for the pregeneration worker:
        // another peer never costs this device a decode.
        if (trusted) self.want(&cid);
        return .busy;
    }

    /// The answer the store has for `cid`: its thumbnail, or that none can
    /// be made; null when it has neither.
    fn storedAnswer(self: *Thumbs, allocator: std.mem.Allocator, cid: *const [32]u8) !?cluster.DerivedAnswer {
        switch (self.stored(cid) orelse return null) {
            .jpeg_len => |len| {
                const jpeg = self.readAll(allocator, cid.*, len) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    // Evicted or replaced since the look: as if not stored.
                    else => return null,
                };
                return .{ .found = jpeg };
            },
            // Only a "none" found out here: one another device answered
            // is hearsay and would spread a mistake (it expires here).
            .none => {
                const reason = self.store.localNoneReason(cid) orelse return null;
                return .{ .none = @intFromEnum(reason) };
            },
            .pending, .unavailable => return null,
        }
    }

    /// `answer`, for the discovery node (GET_DERIVED).
    pub fn source(self: *Thumbs) cluster.DerivedSource {
        return .{ .ctx = self, .answerFn = answerErased };
    }

    fn answerErased(ctx: *anyopaque, allocator: std.mem.Allocator, trusted: bool, cid: [32]u8, kind: u8) anyerror!cluster.DerivedAnswer {
        const self: *Thumbs = @ptrCast(@alignCast(ctx));
        return self.answer(allocator, trusted, cid, kind);
    }

    /// Notes that another device wants `cid`'s thumbnail.
    fn want(self: *Thumbs, cid: *const [32]u8) void {
        const w = &self.wanted;
        w.mutex.lock();
        defer w.mutex.unlock();
        for (w.cids[0..w.len]) |*c| if (std.mem.eql(u8, c, cid)) return;
        if (w.len < max_wanted) {
            w.cids[w.len] = cid.*;
            w.len += 1;
            return;
        }
        w.cids[w.next] = cid.*;
        w.next = (w.next + 1) % max_wanted;
    }

    /// Takes one of the files other devices asked for (the latest, while
    /// fewer than `max_wanted` wait); null when there is none.
    pub fn takeWanted(self: *Thumbs) ?[32]u8 {
        const w = &self.wanted;
        w.mutex.lock();
        defer w.mutex.unlock();
        if (w.len == 0) return null;
        w.len -= 1;
        // Not full any more: the next ones are appended.
        w.next = 0;
        return w.cids[w.len];
    }

    /// Copies the thumbnail's bytes from `offset` into `dest`; how many.
    /// error.FileNotFound when none is stored (`get` first).
    pub fn read(self: *Thumbs, cid: [32]u8, offset: u64, dest: []u8) !usize {
        return self.store.read(&cid, offset, dest);
    }

    /// The whole thumbnail `get` said has `len` bytes. Caller-owned.
    pub fn readAll(self: *Thumbs, allocator: std.mem.Allocator, cid: [32]u8, len: u32) ![]u8 {
        const bytes = try allocator.alloc(u8, len);
        errdefer allocator.free(bytes);
        // Evicted since, or another one: the caller asks again.
        if (try self.store.read(&cid, 0, bytes) != bytes.len) return error.FileNotFound;
        return bytes;
    }

    /// What is known of the thumbnail without making or asking for it: a
    /// few stats.
    pub fn hint(self: *Thumbs, cid: *const [32]u8) photos.ThumbHint {
        return switch (self.store.lookup(cid) orelse return .unknown) {
            .kept, .cache => .ready,
            .none => .none,
        };
    }

    /// `hint`, for the timeline (photos.zig).
    pub fn hints(self: *Thumbs) photos.ThumbHints {
        return .{ .ctx = self, .hintFn = hintErased };
    }

    fn hintErased(ctx: *anyopaque, cid: *const [32]u8) photos.ThumbHint {
        const self: *Thumbs = @ptrCast(@alignCast(ctx));
        return self.hint(cid);
    }

    /// Whether every block of the file is on this device. Loads its parent
    /// blocks and looks at one byte of each leaf; nothing is fetched.
    pub fn isAllLocal(self: *Thumbs, cid: *const [32]u8) bool {
        return self.localSize(cid) != null;
    }

    /// The file's size when every block of it is here; null when one is
    /// missing, or the tree is damaged or too large to walk.
    pub fn localSize(self: *Thumbs, cid: *const [32]u8) ?u64 {
        var budget: usize = max_walk_blocks;
        return self.walkLocal(cid.*, 0, &budget) catch null;
    }

    /// The bytes below block `cid`, `depth` levels under the file's root,
    /// every block being here. Recurses a level per tree level: at most
    /// `max_tree_depth`.
    fn walkLocal(self: *Thumbs, cid: [32]u8, depth: usize, budget: *usize) !u64 {
        if (depth > max_tree_depth) return error.DagTooDeep;
        const bytes = try tree.Loader.local(self.blocks).load(&cid, self.allocator);
        defer self.allocator.free(bytes);
        switch (try dag.decode(bytes)) {
            .leaf => |data| return data.len,
            .dir => return error.IsDirectory,
            .parent => |links| {
                var it = links;
                var total: u64 = 0;
                while (it.next()) |link| {
                    if (budget.* == 0) return error.DagTooLarge;
                    budget.* -= 1;
                    // A leaf that is here is not read; anything else is
                    // loaded: a parent to walk, or missing.
                    const below = if (self.blocks.heldLeaf(link.cid)) link.size else try self.walkLocal(link.cid.*, depth + 1, budget);
                    total = try std.math.add(u64, total, below);
                }
                return total;
            },
        }
    }

    /// The answer the store has for `cid`, if it has one.
    fn stored(self: *Thumbs, cid: *const [32]u8) ?Result {
        return switch (self.store.lookup(cid) orelse return null) {
            .kept, .cache => .{ .jpeg_len = self.store.sizeOf(cid) orelse return null },
            .none => .{ .none = self.store.noneReason(cid) orelse return null },
        };
    }

    /// How many decodes run at once: two on a device that backs the swarm
    /// up (it makes everyone's thumbnails), one elsewhere. A decode takes
    /// tens of megabytes.
    fn slots(self: *const Thumbs) u8 {
        return if (self.folder.backup_enabled.load(.acquire)) 2 else 1;
    }

    /// Makes the thumbnail of a file of `size` bytes that is all here,
    /// once whoever asks: a caller that finds it being made waits for
    /// that one, and all wait for a decode slot, until `until` (monotonic
    /// ms). A film's frame may take `frame_timeout_ms` once it has its
    /// slot.
    fn generate(self: *Thumbs, allocator: std.mem.Allocator, cid: *const [32]u8, name_kind: media.Kind, size: u64, until: i64, frame_timeout_ms: u32) !Result {
        const g = &self.gen;
        g.mutex.lock();
        // Someone is on it: its answer is ours.
        var waited = false;
        while (self.inFlightLocked(cid)) {
            waited = true;
            if (!self.waitLocked(until)) {
                g.mutex.unlock();
                return .pending;
            }
        }
        if (waited) {
            g.mutex.unlock();
            // Nothing stored: it failed (out of memory, a full disk).
            return self.stored(cid) orelse .unavailable;
        }
        if (g.len == max_in_flight) {
            g.mutex.unlock();
            return .pending;
        }
        g.cids[g.len] = cid.*;
        g.len += 1;
        while (g.running >= self.slots()) {
            if (!self.waitLocked(until)) {
                self.leaveLocked(cid);
                g.mutex.unlock();
                return .pending;
            }
        }
        g.running += 1;
        g.mutex.unlock();
        defer {
            g.mutex.lock();
            g.running -= 1;
            self.leaveLocked(cid);
            g.mutex.unlock();
        }
        // Made between this caller's look at the store and its turn.
        if (self.stored(cid)) |found| return found;
        return self.generateSized(allocator, cid, name_kind, size, frame_timeout_ms);
    }

    fn inFlightLocked(self: *Thumbs, cid: *const [32]u8) bool {
        for (self.gen.cids[0..self.gen.len]) |*c| if (std.mem.eql(u8, c, cid)) return true;
        return false;
    }

    /// Takes `cid` out of the table and wakes the waiters. Caller holds
    /// `gen.mutex`.
    fn leaveLocked(self: *Thumbs, cid: *const [32]u8) void {
        const g = &self.gen;
        for (g.cids[0..g.len], 0..) |*c, i| {
            if (!std.mem.eql(u8, c, cid)) continue;
            g.len -= 1;
            g.cids[i] = g.cids[g.len];
            break;
        }
        g.done.broadcast();
    }

    /// Waits for `gen.done`; false once `until` has passed. Caller holds
    /// `gen.mutex`, and checks its condition again (wakeups can be
    /// spurious; each wait ends by `until`).
    fn waitLocked(self: *Thumbs, until: i64) bool {
        const left = until - sync.monotonicMillis();
        if (left <= 0) return false;
        self.gen.done.timedWait(&self.gen.mutex, @as(u64, @intCast(left)) * std.time.ns_per_ms);
        return true;
    }

    /// Makes and keeps the thumbnail of a file whose blocks are all here,
    /// or marks why none can be made. No slot is taken and nobody is
    /// asked: `get` is what callers want. `.unavailable` when a block is
    /// missing.
    pub fn generateLocal(self: *Thumbs, allocator: std.mem.Allocator, cid: *const [32]u8, name_kind: media.Kind) !Result {
        const size = self.localSize(cid) orelse return .unavailable;
        return self.generateSized(allocator, cid, name_kind, size, codec.video.default_timeout_ms);
    }

    fn generateSized(self: *Thumbs, allocator: std.mem.Allocator, cid: *const [32]u8, name_kind: media.Kind, size: u64, frame_timeout_ms: u32) !Result {
        var head_buf: [media.sniff_len]u8 = undefined;
        const head = head_buf[0 .. try self.readLocal(allocator, cid, &head_buf) orelse return .unavailable];
        // The bytes say what it is; the name only what to call a file
        // that is nothing known.
        const is_raw = name_kind == .raw or std.mem.startsWith(u8, head, "II*\x00") or std.mem.startsWith(u8, head, "MM\x00*") or media.sniff(head) == .raw;
        if (!is_raw) {
            switch (media.sniff(head)) {
                .photo => {},
                .video => return self.videoFrame(allocator, cid, frame_timeout_ms),
                // No decoder here reads it.
                .heic => return self.markNone(cid, .unsupported_format),
                .raw => {},
                // A film by its name in a container the first bytes don't
                // tell (MPEG streams): ffmpeg says whether it is one.
                .other => if (name_kind == .video) return self.videoFrame(allocator, cid, frame_timeout_ms) else {
                    return self.markNone(cid, if (name_kind == .photo) .decode_failed else .unsupported_format);
                },
            }
        }
        if (size > max_source_len) return self.markNone(cid, .too_large);

        const bytes = try allocator.alloc(u8, @intCast(size)); // <= max_source_len
        defer allocator.free(bytes);
        const n = try self.readLocal(allocator, cid, bytes) orelse return .unavailable;
        if (n != bytes.len) return .unavailable;
        const jpeg = codec.image.thumbnail(allocator, bytes, .{ .max_pixels = self.max_pixels }) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.TooLarge => return self.markNone(cid, .too_large),
            // A picture by its first bytes that no decoder takes (WebP,
            // AVIF) or that is damaged.
            error.DecodeFailed, error.UnknownFormat => return self.markNone(cid, .decode_failed),
        };
        defer allocator.free(jpeg);
        self.store.put(cid, .kept, jpeg) catch |err| switch (err) {
            error.InvalidThumbnail => return self.markNone(cid, .decode_failed),
            else => return err,
        };
        _ = self.generated.fetchAdd(1, .monotonic);
        return .{ .jpeg_len = @intCast(jpeg.len) }; // stored: <= max_jpeg_len
    }

    /// Takes, keeps and answers a frame of the film `cid`, whose blocks are
    /// all here; or marks why there is none. The caller holds a decode
    /// slot: one ffmpeg at a time (two on a swarm backup).
    fn videoFrame(self: *Thumbs, allocator: std.mem.Allocator, cid: *const [32]u8, timeout_ms: u32) !Result {
        var url_buf: [max_input_url]u8 = undefined;
        const url = self.videoUrl(cid, &url_buf) orelse return self.markNone(cid, .no_video_tool);
        const frame = codec.video.frame(allocator, url, thumb_edge, timeout_ms) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.NoTool => return self.markNone(cid, .no_video_tool),
            // Out of the time another device waits: it asks again, and
            // the file is not marked for being slow once. With all the
            // time there is, it is a film no frame comes of.
            // With all the time there is, still no frame: a slow device or a
            // heavy film, not a broken one. Tried again a day later.
            error.Timeout => return if (timeout_ms < codec.video.default_timeout_ms) .pending else self.markNone(cid, .too_slow),
        };
        const jpeg = frame orelse {
            // The input went away under ffmpeg (the node is stopping):
            // that says nothing of the film.
            if (self.videoUrl(cid, &url_buf) == null) return .unavailable;
            return self.markNone(cid, .decode_failed);
        };
        defer allocator.free(jpeg);
        self.store.put(cid, .kept, jpeg) catch |err| switch (err) {
            error.InvalidThumbnail => return self.markNone(cid, .decode_failed),
            else => return err,
        };
        _ = self.generated.fetchAdd(1, .monotonic);
        return .{ .jpeg_len = @intCast(jpeg.len) }; // stored: <= max_jpeg_len
    }

    /// The file's first `dest.len` bytes from this device's blocks; null
    /// when one is not here (evicted since the walk).
    fn readLocal(self: *Thumbs, allocator: std.mem.Allocator, cid: *const [32]u8, dest: []u8) !?usize {
        return self.folder.readLocal(allocator, cid.*, 0, dest) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return null,
        };
    }

    fn markNone(self: *Thumbs, cid: *const [32]u8, reason: Reason) Result {
        // Without the marker the file is only looked at again.
        self.store.putNone(cid, reason, .local) catch {};
        return .{ .none = reason };
    }
};

const testing = std.testing;
const TestFolder = @import("test_fixture.zig").Fixture(SwarmFolder);

/// A swarm folder on a temporary store and its thumbnails.
const Fixture = struct {
    t: TestFolder,
    thumbs: *Thumbs,

    fn open(self: *Fixture, device_byte: u8, opts: Options) !void {
        try self.t.open(device_byte, "Desk");
        errdefer self.t.close();
        const dir = try std.fs.path.join(testing.allocator, &.{ self.t.dir, "blocks.thumbs" });
        defer testing.allocator.free(dir);
        self.thumbs = try Thumbs.create(testing.allocator, testing.io, &self.t.store, self.t.folder, dir, opts);
    }

    fn close(self: *Fixture) void {
        self.thumbs.destroy();
        self.t.close();
    }

    /// `bytes` as the file `path`; its content ID.
    fn put(self: *Fixture, path: []const u8, bytes: []const u8) ![32]u8 {
        return (try self.t.folder.putBytes(path, bytes, null)).cid;
    }

    fn get(self: *Fixture, cid: [32]u8, kind: media.Kind) !Result {
        return self.thumbs.get(testing.allocator, cid, @splat(self.t.device_byte), kind, 5_000);
    }

    /// Deletes one of the file's leaves from the block store, as if it had
    /// never been fetched.
    fn dropLeaf(self: *Fixture, cid: [32]u8, size: u64) !void {
        var leaves: std.ArrayList([32]u8) = .empty;
        defer leaves.deinit(testing.allocator);
        try tree.leavesIn(testing.allocator, tree.Loader.local(&self.t.store), cid, 0, 0, size, &leaves, 64);
        try testing.expect(leaves.items.len >= 2);
        const hex = std.fmt.bytesToHex(leaves.items[leaves.items.len - 1], .lower);
        try self.t.tmp.dir.deleteFile(testing.io, "blocks/" ++ hex);
    }
};

/// A JPEG of `width` x `height` followed by `extra` bytes of noise (which
/// decoders ignore), so the file takes several blocks. Caller-owned.
fn bigJpeg(width: u32, height: u32, extra: usize, seed: u64) ![]u8 {
    const jpeg = try codec.image.testing.gradientJpeg(testing.allocator, width, height, @truncate(seed));
    defer testing.allocator.free(jpeg);
    const out = try testing.allocator.alloc(u8, jpeg.len + extra);
    @memcpy(out[0..jpeg.len], jpeg);
    var prng = std.Random.DefaultPrng.init(seed);
    prng.random().bytes(out[jpeg.len..]);
    return out;
}

test "thumbs: a picture that is here gets a thumbnail, made once" {
    var f: Fixture = undefined;
    try f.open(0x71, .{});
    defer f.close();
    const allocator = testing.allocator;
    const picture = try bigJpeg(1600, 1200, 3 * 1024 * 1024, 1);
    defer allocator.free(picture);
    const cid = try f.put("Camera/a.jpg", picture);

    try testing.expectEqual(photos.ThumbHint.unknown, f.thumbs.hint(&cid));
    try testing.expect(f.thumbs.isAllLocal(&cid));
    const first = try f.get(cid, .photo);
    const len = first.jpeg_len;
    try testing.expectEqual(@as(u64, 1), f.thumbs.generated.load(.monotonic));
    try testing.expectEqual(photos.ThumbHint.ready, f.thumbs.hint(&cid));

    // A 320 pixel JPEG of the same shape, read in two parts.
    const jpeg = try f.thumbs.readAll(allocator, cid, len);
    defer allocator.free(jpeg);
    const dims = try codec.image.info(jpeg);
    try testing.expectEqual(@as(u32, 320), dims.width);
    try testing.expectEqual(@as(u32, 240), dims.height);
    var part: [64]u8 = undefined;
    try testing.expectEqual(part.len, try f.thumbs.read(cid, 100, &part));
    try testing.expectEqualSlices(u8, jpeg[100..][0..part.len], &part);
    try testing.expectEqual(thumb_store.Where.kept, f.thumbs.store.lookup(&cid).?);

    // Asked again: the stored one, nothing decoded.
    try testing.expectEqual(len, (try f.get(cid, .photo)).jpeg_len);
    try testing.expectEqual(len, (try f.get(cid, .other)).jpeg_len);
    try testing.expectEqual(@as(u64, 1), f.thumbs.generated.load(.monotonic));
}

test "thumbs: files no decoder reads are marked, and not looked at again" {
    var f: Fixture = undefined;
    try f.open(0x72, .{});
    defer f.close();
    const heic = try f.put("Camera/a.heic", "\x00\x00\x00\x18ftypheic\x00\x00\x00\x00mif1heic and the picture");
    const film = try f.put("Camera/clip.mp4", "\x00\x00\x00\x20ftypisom\x00\x00\x02\x00isomiso2 and the film");
    // Called a picture, and nothing known.
    const text = try f.put("Camera/broken.jpg", "this is no picture at all");
    const raw = try f.put("Camera/shot.dng", "II*\x00\x08\x00\x00\x00 a TIFF, as camera RAW is");
    // A picture by its first bytes, cut off after them.
    const cut = try f.put("Camera/cut.jpg", "\xFF\xD8\xFF\xE0\x00\x10JFIF\x00\x01");

    try testing.expectEqual(Reason.unsupported_format, (try f.get(heic, .heic)).none);
    // A film, on a device that takes no frames (the fixture has nowhere
    // for ffmpeg to read from).
    try testing.expectEqual(Reason.no_video_tool, (try f.get(film, .video)).none);
    try testing.expectEqual(Reason.decode_failed, (try f.get(text, .photo)).none);
    try testing.expectEqual(Reason.decode_failed, (try f.get(raw, .raw)).none);
    try testing.expectEqual(Reason.decode_failed, (try f.get(cut, .photo)).none);
    try testing.expectEqual(photos.ThumbHint.none, f.thumbs.hint(&heic));
    try testing.expectEqual(thumb_store.Where.none, f.thumbs.store.lookup(&cut).?);

    // The marker answers from now on, whatever the caller calls the file.
    try testing.expectEqual(Reason.unsupported_format, (try f.get(heic, .photo)).none);
    try testing.expectEqual(@as(u64, 0), f.thumbs.generated.load(.monotonic));
}

test "thumbs: more pixels than the limit is too large" {
    var f: Fixture = undefined;
    try f.open(0x73, .{ .max_pixels = 100 * 100 });
    defer f.close();
    const picture = try codec.image.testing.gradientJpeg(testing.allocator, 200, 100, 3);
    defer testing.allocator.free(picture);
    const cid = try f.put("big.jpg", picture);
    try testing.expectEqual(Reason.too_large, (try f.get(cid, .photo)).none);
}

test "thumbs: a file with a block missing is unavailable, and nothing is fetched or marked" {
    var f: Fixture = undefined;
    try f.open(0x74, .{});
    defer f.close();
    const picture = try bigJpeg(800, 600, 3 * 1024 * 1024, 4);
    defer testing.allocator.free(picture);
    const cid = try f.put("Camera/far.jpg", picture);
    try f.dropLeaf(cid, picture.len);

    try testing.expect(!f.thumbs.isAllLocal(&cid));
    // The fixture's folder has no network: a fetch would be an error.
    try testing.expectEqual(Result.unavailable, try f.get(cid, .photo));
    try testing.expectEqual(Result.unavailable, try f.thumbs.generateLocal(testing.allocator, &cid, .photo));
    try testing.expect(f.thumbs.store.lookup(&cid) == null);
    try testing.expectEqual(photos.ThumbHint.unknown, f.thumbs.hint(&cid));
    // A file this device never heard of.
    try testing.expectEqual(Result.unavailable, try f.get(@splat(0xEE), .photo));
}

test "thumbs: callers asking for the same picture at once make it once" {
    var f: Fixture = undefined;
    try f.open(0x75, .{});
    defer f.close();
    const picture = try bigJpeg(2400, 1800, 0, 5);
    defer testing.allocator.free(picture);
    const cid = try f.put("Camera/a.jpg", picture);

    const Ask = struct {
        fn run(fixture: *Fixture, id: [32]u8, out: *?u32) void {
            const got = fixture.get(id, .photo) catch return;
            if (got == .jpeg_len) out.* = got.jpeg_len;
        }
    };
    var lens: [6]?u32 = @splat(null);
    var threads: [6]std.Thread = undefined;
    for (&threads, &lens) |*t, *len| t.* = try std.Thread.spawn(.{}, Ask.run, .{ &f, cid, len });
    for (threads) |t| t.join();
    for (lens) |len| try testing.expectEqual(lens[0].?, len.?);
    try testing.expectEqual(@as(u64, 1), f.thumbs.generated.load(.monotonic));
    try testing.expectEqual(@as(usize, 0), f.thumbs.gen.len);
    try testing.expectEqual(@as(u8, 0), f.thumbs.gen.running);
}

test "thumbs: with every decode slot taken a caller is told to come back" {
    var f: Fixture = undefined;
    try f.open(0x76, .{});
    defer f.close();
    const picture = try codec.image.testing.gradientJpeg(testing.allocator, 400, 300, 6);
    defer testing.allocator.free(picture);
    const cid = try f.put("a.jpg", picture);

    // One slot without the swarm backup, two with it.
    try testing.expectEqual(@as(u8, 1), f.thumbs.slots());
    f.thumbs.gen.running = 1;
    try testing.expectEqual(Result.pending, try f.thumbs.get(testing.allocator, cid, @splat(0), .photo, 30));
    try testing.expectEqual(@as(usize, 0), f.thumbs.gen.len);
    try f.t.folder.setBackup(true);
    try testing.expectEqual(@as(u8, 2), f.thumbs.slots());
    try testing.expect((try f.thumbs.get(testing.allocator, cid, @splat(0), .photo, 30)) == .jpeg_len);
    f.thumbs.gen.running = 0;
}

/// A device asked for thumbnails: answers what the test set.
const FakeRemote = struct {
    answer: enum { found, junk, none, busy, nobody } = .nobody,
    jpeg: []const u8 = "",
    asked: u32 = 0,

    fn remote(self: *FakeRemote) Remote {
        return .{ .ctx = self, .askFn = ask };
    }

    fn ask(ctx: *anyopaque, allocator: std.mem.Allocator, _: Remote.Ask) Remote.Answer {
        const self: *FakeRemote = @ptrCast(@alignCast(ctx));
        self.asked += 1;
        return switch (self.answer) {
            .found => .{ .found = allocator.dupe(u8, self.jpeg) catch return .nobody },
            .junk => .{ .found = allocator.dupe(u8, "not a thumbnail") catch return .nobody },
            .none => .{ .none = .no_video_tool },
            .busy => .busy,
            .nobody => .nobody,
        };
    }
};

test "thumbs: what another device answers for a file that is not here" {
    var f: Fixture = undefined;
    try f.open(0x77, .{});
    defer f.close();
    const thumb = try codec.image.testing.gradientJpeg(testing.allocator, 320, 240, 7);
    defer testing.allocator.free(thumb);
    var fake = FakeRemote{ .jpeg = thumb };
    f.thumbs.remote = fake.remote();
    const far: [32]u8 = @splat(0xF1);

    try testing.expectEqual(Result.unavailable, try f.get(far, .photo));
    fake.answer = .busy;
    try testing.expectEqual(Result.pending, try f.get(far, .photo));
    // Bytes that are no thumbnail are not stored.
    fake.answer = .junk;
    try testing.expectEqual(Result.unavailable, try f.get(far, .photo));
    try testing.expect(f.thumbs.store.lookup(&far) == null);

    fake.answer = .found;
    try testing.expectEqual(@as(u32, @intCast(thumb.len)), (try f.get(far, .photo)).jpeg_len);
    try testing.expectEqual(thumb_store.Where.cache, f.thumbs.store.lookup(&far).?);
    // Cached: nobody is asked again.
    const asked = fake.asked;
    _ = try f.get(far, .photo);
    try testing.expectEqual(asked, fake.asked);

    const film: [32]u8 = @splat(0xF2);
    fake.answer = .none;
    try testing.expectEqual(Reason.no_video_tool, (try f.get(film, .video)).none);
    fake.answer = .found;
    try testing.expectEqual(Reason.no_video_tool, (try f.get(film, .video)).none);
}

test "thumbs: a picture that is here is made here first, or asked for first on a phone" {
    const picture = try codec.image.testing.gradientJpeg(testing.allocator, 640, 480, 8);
    defer testing.allocator.free(picture);
    const thumb = try codec.image.testing.gradientJpeg(testing.allocator, 320, 240, 8);
    defer testing.allocator.free(thumb);
    var fake = FakeRemote{ .jpeg = thumb, .answer = .found };

    var desk: Fixture = undefined;
    try desk.open(0x78, .{ .prefer_local = true });
    defer desk.close();
    desk.thumbs.remote = fake.remote();
    const here = try desk.put("a.jpg", picture);
    try testing.expect((try desk.get(here, .photo)) == .jpeg_len);
    try testing.expectEqual(@as(u32, 0), fake.asked);
    try testing.expectEqual(thumb_store.Where.kept, desk.thumbs.store.lookup(&here).?);

    var phone: Fixture = undefined;
    try phone.open(0x79, .{ .prefer_local = false });
    defer phone.close();
    phone.thumbs.remote = fake.remote();
    const cid = try phone.put("a.jpg", picture);
    try testing.expect((try phone.get(cid, .photo)) == .jpeg_len);
    try testing.expectEqual(@as(u32, 1), fake.asked);
    try testing.expectEqual(thumb_store.Where.cache, phone.thumbs.store.lookup(&cid).?);
    // Nobody has it: made here after all.
    fake.answer = .nobody;
    const other = try codec.image.testing.gradientJpeg(testing.allocator, 640, 480, 9);
    defer testing.allocator.free(other);
    const second = try phone.put("b.jpg", other);
    try testing.expect((try phone.get(second, .photo)) == .jpeg_len);
    try testing.expectEqual(thumb_store.Where.kept, phone.thumbs.store.lookup(&second).?);
}

test "thumbs: the timeline's items say what is known of their thumbnails" {
    var f: Fixture = undefined;
    try f.open(0x7a, .{});
    defer f.close();
    const picture = try codec.image.testing.gradientJpeg(testing.allocator, 640, 480, 10);
    defer testing.allocator.free(picture);
    const made = try f.put("a.jpg", picture);
    try f.t.folder.setMtime("a.jpg", 300);
    const heic = try f.put("b.heic", "\x00\x00\x00\x18ftypheic\x00\x00\x00\x00");
    try f.t.folder.setMtime("b.heic", 200);
    _ = try f.put("c.jpg", "\xFF\xD8\xFF not asked for yet");
    try f.t.folder.setMtime("c.jpg", 100);
    _ = try f.get(made, .photo);
    _ = try f.get(heic, .heic);

    const timeline = try photos.Timeline.create(testing.allocator, f.t.folder);
    defer timeline.destroy();
    timeline.thumb_hints = f.thumbs.hints();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const page = try timeline.page(arena.allocator(), 0, .{}, 0, 10);
    try testing.expectEqual(@as(usize, 3), page.items.len);
    try testing.expectEqual(photos.ThumbHint.ready, page.items[0].thumb);
    try testing.expectEqual(photos.ThumbHint.none, page.items[1].thumb);
    try testing.expectEqual(photos.ThumbHint.unknown, page.items[2].thumb);
}

test "thumbs: a synthetic DNG in the swarm fixture gets a thumbnail" {
    var f: Fixture = undefined;
    try f.open(0x7b, .{});
    defer f.close();

    const allocator = testing.allocator;
    var b = codec.raw.testing.Builder.init(allocator, .little);
    defer b.deinit();

    const jpeg = try codec.image.testing.gradientJpeg(allocator, 160, 120, 42);
    defer allocator.free(jpeg);

    try b.writeHeader(8);
    const ifd_entries: u16 = 5;
    const jpeg_offset: u32 = 8 + 2 + ifd_entries * 12 + 4;
    try b.writeU16(ifd_entries);
    try b.writeEntry(0x0100, 3, 1, 160); // width
    try b.writeEntry(0x0101, 3, 1, 120); // height
    try b.writeEntry(0x0103, 3, 1, 7); // compression JPEG
    try b.writeEntry(0x0111, 4, 1, jpeg_offset); // strip offsets
    try b.writeEntry(0x0117, 4, 1, @intCast(jpeg.len)); // strip byte counts
    try b.writeU32(0);
    _ = try b.appendBytes(jpeg);

    const cid = try f.put("Camera/shot.dng", b.bytes.items);
    try testing.expectEqual(photos.ThumbHint.unknown, f.thumbs.hint(&cid));

    const res = try f.get(cid, .raw);
    try testing.expect(res == .jpeg_len);
    try testing.expectEqual(photos.ThumbHint.ready, f.thumbs.hint(&cid));

    const thumb = try f.thumbs.readAll(allocator, cid, res.jpeg_len);
    defer allocator.free(thumb);
    const dims = try codec.image.info(thumb);
    try testing.expect(dims.longEdge() <= 320);
    try testing.expectEqual(thumb_store.Where.kept, f.thumbs.store.lookup(&cid).?);
}

/// Films read by ffmpeg straight from a file on disk: what the node's
/// local API is to the real thing.
const PathInput = struct {
    path: []const u8,
    asked: u32 = 0,

    fn input(self: *PathInput) VideoInput {
        return .{ .ctx = self, .urlFn = url };
    }

    fn url(ctx: *anyopaque, _: *const [32]u8, buf: []u8) ?[]const u8 {
        const self: *PathInput = @ptrCast(@alignCast(ctx));
        self.asked += 1;
        if (self.path.len > buf.len) return null;
        @memcpy(buf[0..self.path.len], self.path);
        return buf[0..self.path.len];
    }
};

test "thumbs: a film that is here gets a frame as its thumbnail, here and for another device" {
    var f: Fixture = undefined;
    try f.open(0x7f, .{});
    defer f.close();
    const allocator = testing.allocator;
    // Skips without ffmpeg.
    const path = try codec.video.testing.clip(allocator, f.t.tmp.dir, "clip.mp4", "2");
    defer allocator.free(path);
    const film = try f.t.tmp.dir.readFileAlloc(testing.io, "clip.mp4", allocator, .limited(4 * 1024 * 1024));
    defer allocator.free(film);
    const cid = try f.put("Camera/clip.mp4", film);
    var disk = PathInput{ .path = path };
    try testing.expect(!f.thumbs.canTakeFrames());
    f.thumbs.setVideoInput(disk.input());
    try testing.expect(f.thumbs.canTakeFrames());

    // Whatever the caller calls it: the first bytes say it is a film.
    const len = (try f.get(cid, .other)).jpeg_len;
    try testing.expectEqual(@as(u64, 1), f.thumbs.generated.load(.monotonic));
    try testing.expectEqual(thumb_store.Where.kept, f.thumbs.store.lookup(&cid).?);
    const jpeg = try f.thumbs.readAll(allocator, cid, len);
    defer allocator.free(jpeg);
    const dims = try codec.image.info(jpeg);
    try testing.expectEqual(@as(u32, 320), dims.width);
    try testing.expectEqual(@as(u32, 180), dims.height);
    try testing.expectEqual(len, (try f.get(cid, .video)).jpeg_len);
    try testing.expectEqual(@as(u32, 1), disk.asked);

    // Another device asks for one not made yet: made now, for a trusted
    // one only.
    const short_path = try codec.video.testing.clip(allocator, f.t.tmp.dir, "short.mp4", "0.5");
    defer allocator.free(short_path);
    const short = try f.t.tmp.dir.readFileAlloc(testing.io, "short.mp4", allocator, .limited(4 * 1024 * 1024));
    defer allocator.free(short);
    const second = try f.put("Camera/short.mp4", short);
    disk.path = short_path;
    try testing.expect(try f.thumbs.answer(allocator, false, second, kind_jpeg_320) == .busy);
    const made = try f.thumbs.answer(allocator, true, second, kind_jpeg_320);
    defer allocator.free(made.found);
    try thumb_store.validate(made.found);
    try testing.expectEqual(@as(u64, 2), f.thumbs.generated.load(.monotonic));

    // Called a film and not one: ffmpeg makes nothing of it.
    const fake = try f.put("Camera/fake.mpg", "called a film, and only text");
    disk.path = "/nonexistent/fake.mpg";
    try testing.expectEqual(Reason.decode_failed, (try f.get(fake, .video)).none);

    // The input taken back (the node stopping): no frame, for now.
    f.thumbs.setVideoInput(null);
    const third = try f.put("Camera/third.mp4", film[0 .. film.len - 1]);
    try testing.expectEqual(Reason.no_video_tool, (try f.get(third, .video)).none);
    try testing.expectEqual(@intFromEnum(Reason.no_video_tool), (try f.thumbs.answer(allocator, true, third, kind_jpeg_320)).none);
}

test "thumbs: a film on a device that takes no frames is asked of the others first" {
    var f: Fixture = undefined;
    try f.open(0x80, .{});
    defer f.close();
    const thumb = try codec.image.testing.gradientJpeg(testing.allocator, 320, 180, 12);
    defer testing.allocator.free(thumb);
    var fake = FakeRemote{ .jpeg = thumb, .answer = .found };
    f.thumbs.remote = fake.remote();
    const named = try f.put("Camera/a.mp4", "\x00\x00\x00\x20ftypisom\x00\x00\x02\x00isomiso2 one film");
    const unnamed = try f.put("Camera/b", "\x00\x00\x00\x20ftypisom\x00\x00\x02\x00isomiso2 another");
    const alone = try f.put("Camera/c.mp4", "\x00\x00\x00\x20ftypisom\x00\x00\x02\x00isomiso2 a third");

    // All of it is here, and prefer_local is on: still asked for, by its
    // name or by its first bytes.
    try testing.expect(f.thumbs.isAllLocal(&named));
    try testing.expectEqual(@as(u32, @intCast(thumb.len)), (try f.get(named, .video)).jpeg_len);
    try testing.expectEqual(@as(u32, 1), fake.asked);
    try testing.expectEqual(thumb_store.Where.cache, f.thumbs.store.lookup(&named).?);
    try testing.expect((try f.get(unnamed, .other)) == .jpeg_len);
    try testing.expectEqual(@as(u32, 2), fake.asked);

    // Nobody has it: no tool, for ten minutes (ffmpeg may be installed,
    // or a device that has it come by).
    fake.answer = .nobody;
    try testing.expectEqual(Reason.no_video_tool, (try f.get(alone, .video)).none);
    try testing.expectEqual(@as(u32, 3), fake.asked);
    try testing.expectEqual(Reason.no_video_tool, f.thumbs.store.localNoneReason(&alone).?);
    try testing.expectEqual(@as(u64, 0), f.thumbs.generated.load(.monotonic));
}

test "thumbs: what this device answers another that asks for a thumbnail" {
    var f: Fixture = undefined;
    try f.open(0x7c, .{});
    defer f.close();
    const allocator = testing.allocator;
    const picture = try bigJpeg(1200, 900, 2 * 1024 * 1024, 11);
    defer allocator.free(picture);
    const cid = try f.put("Camera/a.jpg", picture);
    const heic = try f.put("Camera/b.heic", "\x00\x00\x00\x18ftypheic\x00\x00\x00\x00mif1heic and the picture");

    // A kind this build does not know, and a file that is not here.
    try testing.expect(try f.thumbs.answer(allocator, true, cid, 9) == .unknown_kind);
    try testing.expect(try f.thumbs.answer(allocator, true, @splat(0xE1), kind_jpeg_320) == .not_held);

    // A device that is not trusted costs no decode, now or later: the
    // file is not even queued for the worker.
    try testing.expect(try f.thumbs.answer(allocator, false, cid, kind_jpeg_320) == .busy);
    try testing.expect(try f.thumbs.answer(allocator, false, cid, kind_jpeg_320) == .busy);
    try testing.expectEqual(@as(u64, 0), f.thumbs.generated.load(.monotonic));
    try testing.expectEqual(@as(usize, 0), f.thumbs.wanted.len);

    // A trusted one with every slot taken is told to come back.
    f.thumbs.gen.running = 1;
    try testing.expect(try f.thumbs.answer(allocator, true, cid, kind_jpeg_320) == .busy);
    f.thumbs.gen.running = 0;
    try testing.expectEqual(@as(u64, 0), f.thumbs.generated.load(.monotonic));
    try testing.expectEqual(@as(usize, 1), f.thumbs.wanted.len);
    try testing.expectEqual(cid, f.thumbs.takeWanted().?);
    try testing.expect(f.thumbs.takeWanted() == null);

    // With a slot it is made now, and kept.
    const made = try f.thumbs.answer(allocator, true, cid, kind_jpeg_320);
    defer allocator.free(made.found);
    try thumb_store.validate(made.found);
    try testing.expectEqual(@as(u32, 320), (try codec.image.info(made.found)).width);
    try testing.expectEqual(@as(u64, 1), f.thumbs.generated.load(.monotonic));
    try testing.expectEqual(thumb_store.Where.kept, f.thumbs.store.lookup(&cid).?);

    // Stored: given to anyone in the swarm, nothing decoded.
    const again = try f.thumbs.answer(allocator, false, cid, kind_jpeg_320);
    defer allocator.free(again.found);
    try testing.expectEqualSlices(u8, made.found, again.found);
    try testing.expectEqual(@as(u64, 1), f.thumbs.generated.load(.monotonic));

    // A file no decoder reads: none, and the reason, to trusted devices
    // first and then to all.
    try testing.expect(try f.thumbs.answer(allocator, false, heic, kind_jpeg_320) == .busy);
    try testing.expectEqual(@intFromEnum(Reason.unsupported_format), (try f.thumbs.answer(allocator, true, heic, kind_jpeg_320)).none);
    try testing.expectEqual(@intFromEnum(Reason.unsupported_format), (try f.thumbs.answer(allocator, false, heic, kind_jpeg_320)).none);

    // A "none" another device answered is not passed on: it may be wrong
    // (that device had no decoder), and it expires here.
    const heard: [32]u8 = @splat(0xA7);
    try f.thumbs.store.putNone(&heard, .decode_failed, .remote);
    try testing.expect(try f.thumbs.answer(allocator, true, heard, kind_jpeg_320) == .not_held);

    // A file with a block missing is not held, whoever asks.
    const far = try f.put("Camera/far.jpg", picture[0 .. picture.len - 1]);
    try f.dropLeaf(far, picture.len - 1);
    try testing.expect(try f.thumbs.answer(allocator, true, far, kind_jpeg_320) == .not_held);
    try testing.expect(try f.thumbs.answer(allocator, false, far, kind_jpeg_320) == .not_held);
}

test "thumbs: the files other devices want are bounded, the oldest giving way" {
    var f: Fixture = undefined;
    try f.open(0x7d, .{});
    defer f.close();
    for (0..max_wanted + 3) |i| {
        var cid: [32]u8 = @splat(0);
        std.mem.writeInt(u32, cid[0..4], @intCast(i), .little);
        f.thumbs.want(&cid);
    }
    try testing.expectEqual(@as(usize, max_wanted), f.thumbs.wanted.len);
    // The three oldest were replaced by the three latest.
    try testing.expectEqual(@as(u32, max_wanted + 2), std.mem.readInt(u32, f.thumbs.wanted.cids[2][0..4], .little));
    try testing.expectEqual(@as(u32, 3), std.mem.readInt(u32, f.thumbs.wanted.cids[3][0..4], .little));
    var taken: usize = 0;
    while (f.thumbs.takeWanted()) |_| taken += 1;
    try testing.expectEqual(@as(usize, max_wanted), taken);
}

test "thumbs: with the folder not started nobody is asked" {
    var f: Fixture = undefined;
    try f.open(0x7e, .{});
    defer f.close();
    f.thumbs.remote = f.thumbs.clusterRemote();
    try testing.expectEqual(Result.unavailable, try f.get(@splat(0xE2), .photo));
}
