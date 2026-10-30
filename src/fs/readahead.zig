//! Read-ahead for files on other devices. A read fetches the blocks it needs
//! one round trip at a time; over Wi-Fi that round trip, not bandwidth, is
//! what makes a video slow to start and to seek. After each read this queues
//! the blocks of the next `window` bytes, and a few worker threads fetch them
//! in parallel (each on its own Yamux stream over the same connection), so
//! the following reads find their blocks in the local store. A read that
//! needs a block a worker is already fetching waits for it instead of
//! fetching it twice.

const std = @import("std");
const sync = @import("../sync.zig");
const cluster = @import("../cluster/mod.zig");
const storage = @import("../storage/mod.zig");
const NodeID = @import("../net/id.zig").NodeID;
const tree = @import("tree.zig");

const Cid = tree.Cid;

pub const ReadAhead = struct {
    allocator: std.mem.Allocator,
    block_manager: *cluster.BlockManager,
    store: *storage.engine.StorageEngine,

    /// Guards everything below.
    mutex: sync.Mutex = .{},
    /// Work arrived, or the fetcher is stopping.
    work: sync.Condition = .{},
    /// A fetch finished (readers waiting for an in-flight block).
    done: sync.Condition = .{},
    queue: std.ArrayList(Job) = .empty,
    /// Blocks being fetched right now, by a worker or a reader.
    in_flight: std.AutoHashMapUnmanaged(Cid, void) = .empty,
    /// Per file root: where its readers are and how far ahead to fetch.
    streams: std.AutoHashMapUnmanaged(Cid, Stream) = .empty,
    next_cursor: u32 = 1,
    running: bool = true,
    threads: [workers]?std.Thread = .{null} ** workers,

    pub const workers = 6;
    /// Read-ahead grows like the kernel's: a file's first read (or a seek)
    /// fetches a little ahead, each read that continues where the last one
    /// ended doubles it, up to a few seconds of high-bitrate video. A player
    /// probing a file (the start, then the index at the end) so doesn't
    /// spend the link on bytes it won't read.
    pub const min_window: u64 = 512 << 10;
    pub const max_window: u64 = 8 << 20;

    /// A file can have several readers at once: a video player reads its
    /// audio and video, or the index and the frames, from different places.
    /// Each gets a cursor (like the kernel's per-open-file read-ahead), so
    /// one doesn't look like a seek to the other.
    const max_cursors = 4;
    /// A read this close to a cursor continues it (players skip small
    /// boxes forward and re-read a little backward).
    const near_back: u64 = 512 << 10;
    const near_forward: u64 = 2 << 20;
    /// Work for a cursor nobody read from for this long is dropped: the
    /// reader seeked away or closed the file.
    const stale_ms = 5 * std.time.ms_per_s;

    const Cursor = struct {
        id: u32,
        /// Where the next sequential read would start.
        next: u64,
        window: u64,
        /// Queued up to here.
        queued_until: u64,
        /// sync.monotonicMillis of its last read.
        used_at: i64,
    };

    const Stream = struct {
        cursors: [max_cursors]?Cursor = .{null} ** max_cursors,
    };
    /// Bound on queued blocks; reads far apart replace stale work.
    const max_queue = 256;
    /// Devices one block may come from (shares: one; swarm: author + peers).
    pub const max_peers = 8;
    /// How long a reader waits for a block a worker is fetching.
    const wait_ms = 30 * std.time.ms_per_s;

    const Job = struct {
        root: Cid,
        /// The cursor it reads ahead of (its activity orders the work).
        cursor: u32,
        cid: Cid,
        peers: [max_peers]NodeID,
        peer_count: u8,
    };

    pub fn create(allocator: std.mem.Allocator, block_manager: *cluster.BlockManager, store: *storage.engine.StorageEngine) !*ReadAhead {
        const self = try allocator.create(ReadAhead);
        self.* = .{ .allocator = allocator, .block_manager = block_manager, .store = store };
        errdefer self.destroy();
        for (&self.threads) |*t| t.* = try std.Thread.spawn(.{}, worker, .{self});
        return self;
    }

    pub fn destroy(self: *ReadAhead) void {
        {
            self.mutex.lock();
            defer self.mutex.unlock();
            self.running = false;
            self.work.broadcast();
            self.done.broadcast();
        }
        for (self.threads) |t| if (t) |th| th.join();
        self.queue.deinit(self.allocator);
        self.in_flight.deinit(self.allocator);
        self.streams.deinit(self.allocator);
        self.allocator.destroy(self);
    }

    /// Reads like tree.readAt from `peers` (tried in order), then queues the
    /// blocks ahead of it.
    pub fn readAt(self: *ReadAhead, allocator: std.mem.Allocator, peers: []const NodeID, root: Cid, offset: u64, dest: []u8) !usize {
        var source = Source{ .ra = self, .root = root, .peers = peers[0..@min(peers.len, max_peers)] };
        const span = self.track(root, offset, dest.len);
        const n = try tree.readAt(allocator, source.loader(), root, offset, dest);
        if (n > 0 and span.len > 0) self.ahead(allocator, &source, root, offset, span) catch {};
        return n;
    }

    const Span = struct { from: u64, len: u64, cursor: u32 };

    /// Finds the read's cursor (or starts one) and returns what to queue
    /// ahead of it (len 0: enough is queued already).
    fn track(self: *ReadAhead, root: Cid, offset: u64, len: usize) Span {
        self.mutex.lock();
        defer self.mutex.unlock();
        const end = offset +| len;
        const now = sync.monotonicMillis();
        self.pruneStaleStreamsLocked(now);
        const entry = self.streams.getOrPut(self.allocator, root) catch return .{ .from = end, .len = 0, .cursor = 0 };
        if (!entry.found_existing) entry.value_ptr.* = .{};
        const st = entry.value_ptr;

        var cur: *Cursor = for (&st.cursors) |*slot| {
            if (slot.*) |*c| if (offset +| near_back >= c.next and offset <= c.next +| near_forward) break c;
        } else blk: {
            // A new reader, or a seek: start small in a free slot, else in
            // the one read least recently (its queued work goes with it).
            var pick: *?Cursor = &st.cursors[0];
            for (&st.cursors) |*slot| {
                const c = slot.* orelse {
                    pick = slot;
                    break;
                };
                if (pick.* != null and c.used_at < pick.*.?.used_at) pick = slot;
            }
            if (pick.*) |old| self.dropCursor(old.id);
            // A new position usually means the player moved on (a seek, or
            // the probe of a file's start ending): stop spending the link
            // on the others' queued blocks. A reader that is still there
            // queues them again on its next read.
            for (&st.cursors) |*slot| if (slot.*) |*c| {
                self.dropCursor(c.id);
                c.queued_until = c.next;
            };
            pick.* = .{ .id = self.next_cursor, .next = offset, .window = min_window, .queued_until = end, .used_at = now };
            self.next_cursor +%= 1;
            break :blk &pick.*.?;
        };
        // Reading on from where it stopped: fetch further ahead.
        if (offset >= cur.next and cur.used_at != now) cur.window = @min(cur.window * 2, max_window);
        cur.used_at = now;
        cur.next = @max(cur.next, end);
        const want = cur.next +| cur.window;
        if (cur.queued_until >= want) return .{ .from = end, .len = 0, .cursor = cur.id };
        const from = @max(cur.queued_until, cur.next);
        cur.queued_until = want;
        return .{ .from = from, .len = want - from, .cursor = cur.id };
    }

    /// Evicts streams whose cursors have not been read from for longer than stale_ms.
    /// Caller holds mutex.
    fn pruneStaleStreamsLocked(self: *ReadAhead, now: i64) void {
        while (true) {
            var to_remove: [16]Cid = undefined;
            var remove_count: usize = 0;
            var it = self.streams.iterator();
            while (it.next()) |entry| {
                const st = entry.value_ptr;
                var active = false;
                for (&st.cursors) |*slot| {
                    if (slot.*) |c| {
                        if (now - c.used_at > stale_ms) {
                            self.dropCursor(c.id);
                            slot.* = null;
                        } else {
                            active = true;
                        }
                    }
                }
                if (!active) {
                    to_remove[remove_count] = entry.key_ptr.*;
                    remove_count += 1;
                    if (remove_count == to_remove.len) break;
                }
            }
            for (to_remove[0..remove_count]) |root| {
                _ = self.streams.remove(root);
            }
            if (remove_count < to_remove.len) break;
        }
    }

    /// Caller holds mutex.
    fn dropCursor(self: *ReadAhead, id: u32) void {
        var i: usize = 0;
        while (i < self.queue.items.len) {
            if (self.queue.items[i].cursor == id) {
                _ = self.queue.orderedRemove(i);
            } else i += 1;
        }
    }

    /// When `cursor` of `root` last read; null once it's gone. Caller holds mutex.
    fn cursorUsedAt(self: *ReadAhead, root: Cid, cursor: u32) ?i64 {
        const st = self.streams.getPtr(root) orelse return null;
        for (st.cursors) |slot| if (slot) |c| if (c.id == cursor) return c.used_at;
        return null;
    }

    /// The next job: work for the most recently read cursor first, in file
    /// order; work nobody is reading toward any more is dropped. Caller
    /// holds mutex.
    fn takeJob(self: *ReadAhead) ?Job {
        const now = sync.monotonicMillis();
        var best: ?usize = null;
        var best_used: i64 = 0;
        var i: usize = 0;
        while (i < self.queue.items.len) {
            const job = self.queue.items[i];
            const used = self.cursorUsedAt(job.root, job.cursor) orelse {
                _ = self.queue.orderedRemove(i);
                continue;
            };
            if (now - used > stale_ms) {
                _ = self.queue.orderedRemove(i);
                continue;
            }
            if (best == null or used > best_used) {
                best = i;
                best_used = used;
            }
            i += 1;
        }
        return if (best) |b| self.queue.orderedRemove(b) else null;
    }

    /// Queues the missing leaves of `span`.
    fn ahead(self: *ReadAhead, allocator: std.mem.Allocator, source: *Source, root: Cid, known: u64, span: Span) !void {
        var leaves: std.ArrayList(Cid) = .empty;
        defer leaves.deinit(allocator);
        try tree.leavesIn(allocator, source.loader(), root, known, span.from, span.len, &leaves, max_queue);

        self.mutex.lock();
        defer self.mutex.unlock();
        for (leaves.items) |cid| {
            if (self.in_flight.contains(cid) or self.isQueued(cid)) continue;
            if (self.store.has(&cid)) continue;
            // Full: drop the oldest work (takeJob also skips stale work).
            if (self.queue.items.len >= max_queue) _ = self.queue.orderedRemove(0);
            var job = Job{ .root = root, .cursor = span.cursor, .cid = cid, .peers = undefined, .peer_count = @intCast(source.peers.len) };
            @memcpy(job.peers[0..source.peers.len], source.peers);
            try self.queue.append(self.allocator, job);
            self.work.signal();
        }
    }

    /// Caller holds mutex.
    fn isQueued(self: *ReadAhead, cid: Cid) bool {
        for (self.queue.items) |job| if (std.mem.eql(u8, &job.cid, &cid)) return true;
        return false;
    }

    fn worker(self: *ReadAhead) void {
        while (true) {
            const job = blk: {
                self.mutex.lock();
                defer self.mutex.unlock();
                while (self.running and self.queue.items.len == 0) self.work.wait(&self.mutex);
                if (!self.running) return;
                const job = self.takeJob() orelse continue;
                if (self.in_flight.contains(job.cid)) continue;
                self.in_flight.put(self.allocator, job.cid, {}) catch continue;
                break :blk job;
            };
            if (!self.store.has(&job.cid)) {
                const bytes = fetch(self, job.root, job.cid, job.peers[0..job.peer_count], self.allocator) catch null;
                if (bytes) |b| self.allocator.free(b);
            }
            self.finish(job.cid);
        }
    }

    fn finish(self: *ReadAhead, cid: Cid) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        _ = self.in_flight.remove(cid);
        self.done.broadcast();
    }

    /// Fetches `cid` of the file `root` through the fetcher, which picks
    /// among `peers` by speed and load: the workers so spread across holders.
    fn fetch(self: *ReadAhead, root: Cid, cid: Cid, peers: []const NodeID, allocator: std.mem.Allocator) ![]u8 {
        const fetcher = &(self.block_manager.fetcher orelse return error.StorageDisabled);
        return fetcher.fetch(&root, &cid, peers, allocator);
    }

    /// The loader reads use: the local store, else wait for a worker that is
    /// fetching the block, else fetch it here.
    const Source = struct {
        ra: *ReadAhead,
        root: Cid,
        peers: []const NodeID,

        fn loader(self: *Source) tree.Loader {
            return .{ .ctx = self, .loadFn = load };
        }

        fn load(ctx: *anyopaque, cid: *const Cid, allocator: std.mem.Allocator) anyerror![]u8 {
            const self: *Source = @ptrCast(@alignCast(ctx));
            const ra = self.ra;
            if (try ra.store.get(cid, allocator)) |block| return @constCast(block.data);
            var claimed = false;
            {
                ra.mutex.lock();
                defer ra.mutex.unlock();
                if (ra.in_flight.contains(cid.*)) {
                    const deadline = sync.monotonicMillis() + wait_ms;
                    while (ra.running and ra.in_flight.contains(cid.*)) {
                        const now = sync.monotonicMillis();
                        if (now >= deadline) break;
                        ra.done.timedWait(&ra.mutex, @as(u64, @intCast(deadline - now)) * std.time.ns_per_ms);
                    }
                }
                // Nobody is fetching it: claim it so workers skip it.
                if (!ra.in_flight.contains(cid.*)) {
                    try ra.in_flight.put(ra.allocator, cid.*, {});
                    claimed = true;
                }
            }
            defer if (claimed) ra.finish(cid.*);
            if (try ra.store.get(cid, allocator)) |block| return @constCast(block.data);
            return ra.fetch(self.root, cid.*, self.peers, allocator);
        }
    };
};

test "ReadAhead prunes stale streams and drops cursors" {
    const allocator = std.testing.allocator;
    var ra = ReadAhead{
        .allocator = allocator,
        .block_manager = undefined,
        .store = undefined,
    };
    defer {
        ra.queue.deinit(allocator);
        ra.in_flight.deinit(allocator);
        ra.streams.deinit(allocator);
    }

    const root1: Cid = [_]u8{1} ** 32;
    const root2: Cid = [_]u8{2} ** 32;

    _ = ra.track(root1, 0, 1024);
    _ = ra.track(root2, 0, 1024);

    try std.testing.expectEqual(@as(usize, 2), ra.streams.count());

    // Artificially age root1's cursors beyond stale_ms
    const now = sync.monotonicMillis();
    const st1 = ra.streams.getPtr(root1).?;
    for (&st1.cursors) |*slot| {
        if (slot.*) |*c| {
            c.used_at = now - ReadAhead.stale_ms - 1000;
        }
    }

    // Next track call triggers pruning
    _ = ra.track(root2, 1024, 1024);

    try std.testing.expectEqual(@as(usize, 1), ra.streams.count());
    try std.testing.expect(!ra.streams.contains(root1));
    try std.testing.expect(ra.streams.contains(root2));
}
