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
const remote_mod = @import("remote.zig");
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
    /// Per file root: where the reads are and how far ahead to fetch.
    streams: std.AutoHashMapUnmanaged(Cid, Stream) = .empty,
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

    const Stream = struct {
        /// Where the next sequential read would start.
        next: u64,
        window: u64,
        /// Queued up to here.
        queued_until: u64,
    };
    /// Bound on queued blocks; reads far apart replace stale work.
    const max_queue = 256;
    /// Devices one block may come from (shares: one; swarm: author + peers).
    pub const max_peers = 8;
    /// How long a reader waits for a block a worker is fetching.
    const wait_ms = 30 * std.time.ms_per_s;

    const Job = struct {
        root: Cid,
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
        var source = Source{ .ra = self, .peers = peers[0..@min(peers.len, max_peers)] };
        const span = self.track(root, offset, dest.len);
        const n = try tree.readAt(allocator, source.loader(), root, offset, dest);
        if (n > 0 and span.len > 0) self.ahead(allocator, &source, root, offset, span) catch {};
        return n;
    }

    const Span = struct { from: u64, len: u64 };

    /// Updates the file's read pattern; returns what to queue (len 0: enough
    /// is queued already).
    fn track(self: *ReadAhead, root: Cid, offset: u64, len: usize) Span {
        self.mutex.lock();
        defer self.mutex.unlock();
        const end = offset + len;
        const entry = self.streams.getOrPut(self.allocator, root) catch return .{ .from = end, .len = 0 };
        const st = entry.value_ptr;
        if (entry.found_existing and offset == st.next) {
            st.window = @min(st.window * 2, max_window);
        } else {
            // First read or a seek: start small, and forget what was queued
            // for the old position.
            st.* = .{ .next = offset, .window = min_window, .queued_until = end };
            if (entry.found_existing) self.dropQueued(root);
        }
        st.next = end;
        const want = end + st.window;
        if (st.queued_until >= want) return .{ .from = end, .len = 0 };
        const from = @max(st.queued_until, end);
        st.queued_until = want;
        return .{ .from = from, .len = want - from };
    }

    /// Caller holds mutex.
    fn dropQueued(self: *ReadAhead, root: Cid) void {
        var i: usize = 0;
        while (i < self.queue.items.len) {
            if (std.mem.eql(u8, &self.queue.items[i].root, &root)) {
                _ = self.queue.orderedRemove(i);
            } else i += 1;
        }
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
            // A new position (a seek) matters more than what's left from
            // the old one: drop the oldest work when full.
            if (self.queue.items.len >= max_queue) _ = self.queue.orderedRemove(0);
            var job = Job{ .root = root, .cid = cid, .peers = undefined, .peer_count = @intCast(source.peers.len) };
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
                const job = self.queue.orderedRemove(0);
                if (self.in_flight.contains(job.cid)) continue;
                self.in_flight.put(self.allocator, job.cid, {}) catch continue;
                break :blk job;
            };
            if (!self.store.has(&job.cid)) {
                const bytes = fetch(self, job.cid, job.peers[0..job.peer_count], self.allocator) catch null;
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

    /// Fetches `cid` from the first of `peers` that has it; the remote
    /// loader verifies it and keeps it in the store.
    fn fetch(self: *ReadAhead, cid: Cid, peers: []const NodeID, allocator: std.mem.Allocator) ![]u8 {
        var last: anyerror = error.BlockNotFound;
        for (peers) |peer| {
            var one = remote_mod.Remote{ .block_manager = self.block_manager, .store = self.store, .peer = peer };
            return one.loader().load(&cid, allocator) catch |err| {
                last = err;
                continue;
            };
        }
        return last;
    }

    /// The loader reads use: the local store, else wait for a worker that is
    /// fetching the block, else fetch it here.
    const Source = struct {
        ra: *ReadAhead,
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
            return ra.fetch(cid.*, self.peers, allocator);
        }
    };
};
