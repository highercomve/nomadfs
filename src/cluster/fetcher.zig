//! Where each block comes from. A read hands the fetcher the block it needs,
//! the file's root and the devices that may hold it (hints from fs/, later
//! the holder registry); the fetcher picks the holder expected to answer
//! first: connected holders before the others, and within each group the
//! least `(requests in flight + 1) / measured rate` (one neither measured
//! nor connected last: a dead author, a relay-only peer between flaps).
//! Callers that fetch
//! several blocks at once (read-ahead's workers) so spread across holders
//! by speed, with no message the read didn't need anyway.
//!
//! Who is asked, in three rounds: every holder not skipped, best first;
//! then each one skipped only for its backoff, once, in the caller's order
//! (the connection manager's own dial backoff makes most of these instant);
//! then, before failing, each one skipped only for a recent miss that is
//! connected now (it may have the block by now). A connected holder is
//! asked despite its backoff, unless that backoff started with its link
//! failing under a request (a timeout, a broken stream): connected then
//! proves nothing until it serves again. A
//! failed read reports, whatever the order of the answers: the first real
//! failure of a holder that answered, else BlockNotFound if every holder
//! asked said "not found", else HoldersUnreachable; NoHolderAskable if
//! nobody could be asked. It logs one line with each holder's outcome.
//!
//! What it remembers, bounded:
//! - per device: its rate (leaf blocks only, EWMA), requests in flight, and
//!   when it may be tried again after failing to connect (backoff);
//! - misses: a device that answered "not found" for a block is skipped for
//!   that block for 30 s, and for the whole file after 3 misses in a row on
//!   it, for 60 s, so a device without the file costs a few round trips,
//!   not one per block.
//!
//! Devices in the routing table are dialed directly; one not met yet is
//! looked up through the DHT once, and backs off if it can't be reached.

const std = @import("std");
const sync = @import("../sync.zig");
const NodeID = @import("../net/id.zig").NodeID;
const storage = @import("../storage/mod.zig");

pub const Cid = [32]u8;
/// Most holders one read considers.
pub const max_holders = 8;
/// Most holders one fetch may try for a block: more than a holder list
/// (max_holders, what a swarm read hands over) for a caller that knows
/// more candidates, like the whole-file get (connected peers, providers,
/// the DHT's closest). Each is asked at most once per block, so a block is
/// never given up while one of them, left out by a smaller cap, has it.
pub const max_candidates = 32;
/// First byte of a leaf block (storage/dag/codec.zig Tag.leaf).
const leaf_tag: u8 = @intFromEnum(storage.dag.codec.Tag.leaf);

/// Dials a holder and fetches one block: the network side, supplied by the
/// BlockManager (and by tests). Returns null when the holder doesn't have it.
pub const Transport = struct {
    ctx: *anyopaque,
    /// Caller-owned bytes from `allocator`, or null for "not found".
    getFn: *const fn (ctx: *anyopaque, peer: NodeID, cid: *const Cid, allocator: std.mem.Allocator) anyerror!?[]u8,
    /// Whether a live connection to `peer` exists right now (direct or
    /// relayed). A connected device is asked even while backing off from a
    /// failed dial (that failure is over), but not after its link failed
    /// under a request (`PeerState.link_failed`). Null: never assumed.
    /// Called with the fetcher's mutex held; it must not call back.
    connectedFn: ?*const fn (ctx: *anyopaque, peer: NodeID) bool = null,
};

pub const Fetcher = struct {
    store: *storage.engine.StorageEngine,
    transport: Transport,

    mutex: sync.Mutex = .{},
    peers: [max_peers]PeerState = undefined,
    peer_count: usize = 0,
    block_misses: [max_block_misses]Miss = undefined,
    block_miss_next: usize = 0,
    block_miss_count: usize = 0,
    root_misses: [max_root_misses]RootMiss = undefined,
    root_miss_count: usize = 0,
    /// Totals since start, for measuring.
    stats: Stats = .{},
    /// A read cache failure was logged already: one line, not one per block.
    cache_fail_logged: bool = false,

    const max_peers = 64;
    const max_block_misses = 512;
    const max_root_misses = 128;
    pub const block_miss_ms: i64 = 30 * std.time.ms_per_s;
    pub const root_miss_ms: i64 = 60 * std.time.ms_per_s;
    /// Misses in a row on one file before the device is skipped for it.
    pub const root_miss_after: u8 = 3;
    /// Bytes per ms assumed for a device never measured: about 4 MB/s, so
    /// new holders get tried.
    const default_rate: u32 = 4096;
    const backoff_first_ms: i64 = 5 * std.time.ms_per_s;
    const backoff_max_ms: i64 = 60 * std.time.ms_per_s;

    pub const PeerState = struct {
        id: NodeID,
        /// EWMA of bytes per ms on leaf blocks; 0 = not measured yet.
        rate: u32 = 0,
        in_flight: u16 = 0,
        fails: u8 = 0,
        down_until: i64 = 0,
        last_used: i64 = 0,
        /// The last failure was the link breaking under a request (a
        /// timeout, a broken stream) rather than a failed dial: being
        /// connected then doesn't lift the backoff. Cleared when it serves.
        link_failed: bool = false,
        /// Blocks and bytes it served (for measuring).
        blocks: u64 = 0,
        bytes: u64 = 0,
    };

    const Miss = struct { peer: NodeID, cid: Cid, until: i64 };
    const RootMiss = struct { peer: NodeID, root: Cid, count: u8, until: i64 };

    pub const Stats = struct {
        local: u64 = 0,
        fetched: u64 = 0,
        fetched_bytes: u64 = 0,
        not_found: u64 = 0,
        failed: u64 = 0,
        /// Verified blocks the read cache couldn't keep (returned anyway).
        cache_failed: u64 = 0,
    };

    pub fn init(store: *storage.engine.StorageEngine, transport: Transport) Fetcher {
        return .{ .store = store, .transport = transport };
    }

    /// The bytes of `cid` (caller-owned), from the local store or the best
    /// of `holders`; a fetched block is verified and kept in the read
    /// cache. `root` is the file it belongs to (misses are remembered per
    /// file). Rates are measured on leaf blocks (file data) only.
    pub fn fetch(self: *Fetcher, root: *const Cid, cid: *const Cid, holders: []const NodeID, allocator: std.mem.Allocator) ![]u8 {
        return self.fetchVerdict(root, cid, holders, allocator, null, null);
    }

    /// Like `fetch`; when it fails, `lost` (if given) tells whether the block
    /// is on none of the devices that can be asked now: `author` answered
    /// "not found" (now, or a moment ago), and every other holder did too or
    /// can't be reached (offline, refusing, backing off). Unreachable devices
    /// don't count, so one that is away for days doesn't hold the verdict
    /// back; a reachable one that answers anything but "not found" does.
    pub fn fetchVerdict(self: *Fetcher, root: *const Cid, cid: *const Cid, holders: []const NodeID, allocator: std.mem.Allocator, author: ?NodeID, lost: ?*bool) ![]u8 {
        if (lost) |l| l.* = false;
        if (try self.store.get(cid, allocator)) |block| {
            self.count(.local, 0);
            return @constCast(block.data);
        }
        const list = holders[0..@min(holders.len, max_candidates)];
        if (list.len == 0) return error.NoHolders;
        var tried = [_]bool{false} ** max_candidates;
        var marks = [_]Mark{.untried} ** max_candidates;
        var tally: Tally = .{};
        var round: Round = .best;
        while (true) {
            const i = self.pick(root, cid, list, &tried, round) orelse {
                round = switch (round) {
                    .best => .backoff,
                    // Before failing, ask the holders connected now that
                    // said "not found" a moment ago (they may have it by
                    // now; the backup copies files as they come), whatever
                    // the others answered: an offline one mustn't hide a
                    // connected one that has it.
                    .backoff => .missed,
                    .missed => break,
                };
                continue;
            };
            tried[i] = true;
            const peer = list[i];
            // Asked only because its backoff was all that skipped it.
            const probe = round == .backoff;
            const started = sync.monotonicMillis();
            const result = self.transport.getFn(self.transport.ctx, peer, cid, allocator);
            const elapsed = sync.monotonicMillis() - started;
            const maybe = result catch |err| {
                self.done(peer, root, cid, .{ .failed = err });
                marks[i] = .{ .failed = err };
                tally.note(.{ .failed = err }, probe);
                continue;
            };
            const bytes = maybe orelse {
                self.done(peer, root, cid, .not_found);
                marks[i] = .not_found;
                tally.note(.not_found, probe);
                continue;
            };
            // putCached checks the bytes hash to `cid` before keeping them.
            self.store.putCached(.{ .cid = cid.*, .data = bytes }) catch |err| switch (err) {
                error.HashMismatch => {
                    allocator.free(bytes);
                    self.done(peer, root, cid, .{ .failed = err });
                    marks[i] = .{ .failed = err };
                    tally.note(.bad_answer, probe);
                    continue;
                },
                // The bytes are verified; only the cache failed. The read
                // works, uncached.
                else => self.cacheFailed(err),
            };
            self.done(peer, root, cid, .{ .served = .{ .len = bytes.len, .ms = elapsed, .leaf = bytes.len > 0 and bytes[0] == leaf_tag } });
            return bytes;
        }
        if (lost) |l| l.* = !tally.any_failed and author != null and self.authorMissed(root, cid, list, &tried, &marks, author.?);
        const verdict = tally.verdict();
        self.logFailure(root, cid, list, &marks, verdict);
        return verdict;
    }

    /// One failed attempt of a fetch.
    const Attempt = union(enum) {
        /// The transport failed (could not connect, or the holder answered
        /// with an error).
        failed: anyerror,
        /// The holder answered "not found".
        not_found,
        /// The holder answered with bytes that don't hash to the CID.
        bad_answer,
    };

    /// What each holder of one fetch did, for the log line.
    const Mark = union(enum) { untried, not_found, failed: anyerror };

    /// What the failed attempts of one fetch add up to: the lost verdict and
    /// the error the read reports. Every attempt goes through `note`, so
    /// they can't drift apart, and the error doesn't depend on the order
    /// the holders answered in.
    const Tally = struct {
        /// Attempts that failed (a fetch that succeeds returns before
        /// the tally is read).
        attempts: usize = 0,
        /// A reachable holder answered something other than "not found":
        /// holds the lost verdict back.
        any_failed: bool = false,
        /// The first real failure of a holder that answered: anything but
        /// "can't reach" and "not found". The read reports it first, so a
        /// holder that has the block and fails isn't hidden by a later
        /// "not found".
        failure: ?anyerror = null,
        /// Every holder asked answered "not found".
        all_not_found: bool = true,

        fn note(self: *Tally, attempt: Attempt, probe: bool) void {
            self.attempts += 1;
            switch (attempt) {
                .failed => |err| {
                    // A holder asked only because its backoff was all that
                    // skipped it (a probe) would have been skipped before:
                    // its failure, whatever the transport calls it, never
                    // holds the lost verdict back. It still means not every
                    // holder asked said "not found" (HoldersUnreachable,
                    // not BlockNotFound: it may have the block).
                    if (!unreachable_error(err) and !probe) self.any_failed = true;
                    if (!cant_reach(err) and self.failure == null) self.failure = err;
                    self.all_not_found = false;
                },
                .not_found => {},
                .bad_answer => {
                    self.any_failed = true;
                    if (self.failure == null) self.failure = error.HashMismatch;
                    self.all_not_found = false;
                },
            }
        }

        /// The error a fetch that nobody served reports.
        fn verdict(self: *const Tally) anyerror {
            if (self.attempts == 0) return error.NoHolderAskable;
            if (self.failure) |err| return err;
            if (self.all_not_found) return error.BlockNotFound;
            // Some holder that may have it couldn't be reached.
            return error.HoldersUnreachable;
        }
    };

    /// The author is among `holders` and said "not found": in this fetch, or
    /// a moment ago (skipped for it now).
    fn authorMissed(self: *Fetcher, root: *const Cid, cid: *const Cid, holders: []const NodeID, tried: *const [max_candidates]bool, marks: *const [max_candidates]Mark, author: NodeID) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        const now = sync.monotonicMillis();
        for (holders, 0..) |peer, i| {
            if (!peer.eql(author)) continue;
            if (tried[i]) return marks[i] == .not_found;
            return self.missedLocked(peer, root, cid, now);
        }
        return false;
    }

    /// Errors that mean the device couldn't be reached at all, as opposed
    /// to one that answered with a failure. The connection manager's "every
    /// address failed" is one: the device is offline. (Counted before only
    /// once it was backing off, so the verdict of a keeper round with
    /// parallel workers depended on which one asked it first.)
    fn unreachable_error(err: anyerror) bool {
        return switch (err) {
            error.ConnectionRefused, error.ConnectionTimedOut, error.NoRelay, error.PeerIdMismatch, error.NetworkUnreachable, error.HostUnreachable, error.PeerDown, error.ConnectionResetByPeer, error.BrokenPipe, error.Timeout, error.AllAddressesFailed => true,
            else => false,
        };
    }

    /// Errors that say no connection to the device could be had: what
    /// unreachable_error counts, the connection manager's "backing off",
    /// the DHT's "provider unreachable", and a session or stream that broke
    /// mid-request (link_error). Only names the error a read reports
    /// (HoldersUnreachable); the lost verdict keeps the narrower set, so a
    /// holder asked normally that fails that way still holds it back.
    fn cant_reach(err: anyerror) bool {
        return unreachable_error(err) or link_error(err) or switch (err) {
            error.PeerUnreachable, error.ProviderUnreachable => true,
            else => false,
        };
    }

    /// A session or stream that broke under a request: the link failed,
    /// not the holder's answer. Reported as "can't reach", and it keeps a
    /// connected holder's backoff in force (`link_failed`). Whether the
    /// session itself is gone is BlockManager's question (`sessionGone`).
    pub fn link_error(err: anyerror) bool {
        return switch (err) {
            error.SessionClosed, error.StreamClosed, error.StreamIdsExhausted, error.EndOfStream, error.ConnectionResetByPeer, error.BrokenPipe, error.NotOpenForReading, error.NotOpenForWriting, error.Timeout, error.ReadFailed, error.WriteFailed, error.ConnectionAborted => true,
            else => false,
        };
    }

    const Outcome = union(enum) {
        served: struct { len: usize, ms: i64, leaf: bool },
        not_found,
        failed: anyerror,
    };

    /// The rounds of one fetch, in order (see the file header).
    const Round = enum {
        /// Every holder not skipped, best first.
        best,
        /// Each holder skipped only for its backoff, once, in the caller's
        /// order (the author, the backups, connected peers first).
        backoff,
        /// Before failing: each holder skipped only for a recent miss that
        /// is connected now, in the caller's order.
        missed,
    };

    /// Why a holder isn't among the best: it said "not found" a moment ago
    /// (for this block or this file), or it is backing off and either not
    /// connected or its link failed under a request (a connected device
    /// whose dial failed is asked: that failure is over; one whose live
    /// link timed out may be silent and still look connected).
    const Skip = enum { none, miss, backoff };

    /// The holder to ask next in `round`, or null when none is left; counts
    /// the request in flight. In the best round, connected holders come
    /// before the others (a holder never measured is priced as the fastest
    /// one, so cost alone would put dead and relay-only devices first), and
    /// the least expected cost wins within each group. (The connection
    /// manager's own backoff keeps the backoff round from redialing a dead
    /// device for every block, and BlockManager skips the DHT lookup while
    /// it lasts.)
    fn pick(self: *Fetcher, root: *const Cid, cid: *const Cid, holders: []const NodeID, tried: *const [max_candidates]bool, round: Round) ?usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        const now = sync.monotonicMillis();
        const i = switch (round) {
            .best => self.bestLocked(root, cid, holders, tried, now),
            .backoff, .missed => self.firstSkippedLocked(root, cid, holders, tried, round, now),
        } orelse return null;
        const st = self.getOrAddLocked(holders[i], now);
        st.in_flight +|= 1;
        st.last_used = now;
        return i;
    }

    fn bestLocked(self: *Fetcher, root: *const Cid, cid: *const Cid, holders: []const NodeID, tried: *const [max_candidates]bool, now: i64) ?usize {
        const fallback = self.bestRateLocked();
        var best: ?usize = null;
        var best_group: u1 = 1;
        var best_cost: u64 = std.math.maxInt(u64);
        for (holders, 0..) |peer, i| {
            if (tried[i]) continue;
            const connected = self.connectedLocked(peer);
            if (self.skipLocked(peer, root, cid, connected, now) != .none) continue;
            const st = self.findLocked(peer);
            const measured = if (st) |s| s.rate > 0 else false;
            // Never measured: a connected one is priced as the best seen
            // (new holders get tried); one neither measured nor connected
            // (a dead author, a relay-only peer between flaps) last, so it
            // never goes before a measured backup.
            const rate: u64 = if (measured) st.?.rate else if (connected) fallback else 1;
            const in_flight: u64 = if (st) |s| s.in_flight else 0;
            // Expected wait for one more block, scaled to stay an integer.
            const c = (in_flight + 1) * 1_000_000 / @max(rate, 1);
            const group: u1 = if (connected) 0 else 1;
            // Ties keep the caller's order (the author, the backups, ...).
            if (best == null or group < best_group or (group == best_group and c < best_cost)) {
                best = i;
                best_group = group;
                best_cost = c;
            }
        }
        return best;
    }

    /// The first holder in the caller's order skipped only for the reason
    /// `round` stands for (and, for a miss, connected now).
    fn firstSkippedLocked(self: *Fetcher, root: *const Cid, cid: *const Cid, holders: []const NodeID, tried: *const [max_candidates]bool, round: Round, now: i64) ?usize {
        for (holders, 0..) |peer, i| {
            if (tried[i]) continue;
            const connected = self.connectedLocked(peer);
            const skip = self.skipLocked(peer, root, cid, connected, now);
            switch (round) {
                .backoff => if (skip == .backoff) return i,
                .missed => if (skip == .miss and connected) return i,
                .best => unreachable,
            }
        }
        return null;
    }

    /// Caller holds `mutex`.
    fn skipLocked(self: *Fetcher, peer: NodeID, root: *const Cid, cid: *const Cid, connected: bool, now: i64) Skip {
        if (self.missedLocked(peer, root, cid, now)) return .miss;
        if (self.findLocked(peer)) |s| if (now < s.down_until and (!connected or s.link_failed)) return .backoff;
        return .none;
    }

    /// The read cache couldn't keep a verified block: counted, and logged
    /// once (a full or broken disk would otherwise log every block).
    fn cacheFailed(self: *Fetcher, err: anyerror) void {
        self.mutex.lock();
        const first = !self.cache_fail_logged;
        self.cache_fail_logged = true;
        self.stats.cache_failed += 1;
        self.mutex.unlock();
        if (first) std.debug.print("fetcher: the read cache can't keep blocks ({any}); reading uncached\n", .{err});
    }

    /// One line for a fetch nobody served: the block, then each holder with
    /// what it did (not_found, the error, or why it was skipped), then the
    /// error the read reports. Bounded by max_candidates; no allocation.
    fn logFailure(self: *Fetcher, root: *const Cid, cid: *const Cid, holders: []const NodeID, marks: *const [max_candidates]Mark, verdict: anyerror) void {
        // max_candidates entries of a prefix and an outcome (an error name).
        var buf: [4096]u8 = undefined;
        var w: std.Io.Writer = .fixed(&buf);
        {
            self.mutex.lock();
            defer self.mutex.unlock();
            const now = sync.monotonicMillis();
            for (holders, 0..) |peer, i| {
                const what: []const u8 = switch (marks[i]) {
                    .not_found => "not_found",
                    .failed => |err| @errorName(err),
                    .untried => switch (self.skipLocked(peer, root, cid, self.connectedLocked(peer), now)) {
                        .miss => "skip:miss",
                        .backoff => "skip:backoff",
                        .none => "untried",
                    },
                };
                w.print(" {x}:{s}", .{ peer.bytes[0..4], what }) catch break;
            }
        }
        std.debug.print("fetcher: {x} not fetched:{s} -> {s}\n", .{ cid[0..4], w.buffered(), @errorName(verdict) });
    }

    fn done(self: *Fetcher, peer: NodeID, root: *const Cid, cid: *const Cid, outcome: Outcome) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        const now = sync.monotonicMillis();
        const st = self.getOrAddLocked(peer, now);
        st.in_flight -|= 1;
        switch (outcome) {
            .served => |s| {
                st.fails = 0;
                st.down_until = 0;
                st.link_failed = false;
                st.blocks += 1;
                st.bytes += s.len;
                self.stats.fetched += 1;
                self.stats.fetched_bytes += s.len;
                // Small index blocks measure latency, not throughput.
                if (s.leaf and s.len >= 16 * 1024) {
                    const sample: u32 = @intCast(@min(s.len / @as(usize, @intCast(@max(s.ms, 1))), std.math.maxInt(u32)));
                    st.rate = if (st.rate == 0) sample else @intCast((@as(u64, st.rate) * 3 + sample) / 4);
                }
                self.clearRootMissLocked(peer, root);
            },
            .not_found => {
                self.stats.not_found += 1;
                self.addBlockMissLocked(peer, cid, now);
                self.addRootMissLocked(peer, root, now);
            },
            .failed => |err| {
                self.stats.failed += 1;
                st.link_failed = link_error(err);
                st.fails +|= 1;
                const shift: u6 = @intCast(@min(st.fails - 1, 4));
                st.down_until = now + @min(backoff_first_ms << shift, backoff_max_ms);
            },
        }
    }

    fn count(self: *Fetcher, comptime what: enum { local }, _: usize) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        switch (what) {
            .local => self.stats.local += 1,
        }
    }

    /// Whether `peer` is down: failed to connect recently.
    pub fn isDown(self: *Fetcher, peer: NodeID) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        const st = self.findLocked(peer) orelse return false;
        return sync.monotonicMillis() < st.down_until;
    }

    /// Marks `peer` down (e.g. the mount saw it fail), with backoff.
    pub fn markDown(self: *Fetcher, peer: NodeID) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        const now = sync.monotonicMillis();
        const st = self.getOrAddLocked(peer, now);
        st.fails +|= 1;
        const shift: u6 = @intCast(@min(st.fails - 1, 4));
        st.down_until = now + @min(backoff_first_ms << shift, backoff_max_ms);
    }

    pub fn markUp(self: *Fetcher, peer: NodeID) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        const st = self.findLocked(peer) orelse return;
        st.fails = 0;
        st.down_until = 0;
        st.link_failed = false;
    }

    /// Forgets every device's backoff: this node was cut off, so the
    /// failures were its own, not the devices' (Node clears the connection
    /// manager's backoff at the same moment).
    pub fn clearAllBackoff(self: *Fetcher) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        for (self.peers[0..self.peer_count]) |*s| {
            s.fails = 0;
            s.down_until = 0;
            s.link_failed = false;
        }
    }

    /// Whether the transport has a live connection to `peer`. Caller holds
    /// `mutex`.
    fn connectedLocked(self: *Fetcher, peer: NodeID) bool {
        const f = self.transport.connectedFn orelse return false;
        return f(self.transport.ctx, peer);
    }

    /// A copy of what is known about each device, for measuring.
    pub fn snapshot(self: *Fetcher, out: []PeerState) []PeerState {
        self.mutex.lock();
        defer self.mutex.unlock();
        const n = @min(out.len, self.peer_count);
        @memcpy(out[0..n], self.peers[0..n]);
        return out[0..n];
    }

    pub fn totals(self: *Fetcher) Stats {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.stats;
    }

    // ---- State (caller holds mutex) ----

    fn findLocked(self: *Fetcher, peer: NodeID) ?*PeerState {
        for (self.peers[0..self.peer_count]) |*s| if (s.id.eql(peer)) return s;
        return null;
    }

    /// Full: the device used longest ago (and not busy) makes room.
    fn getOrAddLocked(self: *Fetcher, peer: NodeID, now: i64) *PeerState {
        if (self.findLocked(peer)) |s| return s;
        if (self.peer_count < max_peers) {
            self.peers[self.peer_count] = .{ .id = peer, .last_used = now };
            self.peer_count += 1;
            return &self.peers[self.peer_count - 1];
        }
        var victim: usize = 0;
        for (self.peers[0..self.peer_count], 0..) |s, i| {
            const v = self.peers[victim];
            if ((s.in_flight == 0 and v.in_flight > 0) or (s.in_flight == v.in_flight and s.last_used < v.last_used)) victim = i;
        }
        self.peers[victim] = .{ .id = peer, .last_used = now };
        return &self.peers[victim];
    }

    fn bestRateLocked(self: *Fetcher) u32 {
        var best: u32 = 0;
        for (self.peers[0..self.peer_count]) |s| best = @max(best, s.rate);
        return if (best > 0) best else default_rate;
    }

    fn missedLocked(self: *Fetcher, peer: NodeID, root: *const Cid, cid: *const Cid, now: i64) bool {
        for (self.block_misses[0..self.block_miss_count]) |m| {
            if (now < m.until and m.peer.eql(peer) and std.mem.eql(u8, &m.cid, cid)) return true;
        }
        for (self.root_misses[0..self.root_miss_count]) |m| {
            if (m.count >= root_miss_after and now < m.until and m.peer.eql(peer) and std.mem.eql(u8, &m.root, root)) return true;
        }
        return false;
    }

    /// A ring: the oldest miss makes room.
    fn addBlockMissLocked(self: *Fetcher, peer: NodeID, cid: *const Cid, now: i64) void {
        self.block_misses[self.block_miss_next] = .{ .peer = peer, .cid = cid.*, .until = now + block_miss_ms };
        self.block_miss_next = (self.block_miss_next + 1) % max_block_misses;
        self.block_miss_count = @min(self.block_miss_count + 1, max_block_misses);
    }

    fn addRootMissLocked(self: *Fetcher, peer: NodeID, root: *const Cid, now: i64) void {
        for (self.root_misses[0..self.root_miss_count]) |*m| {
            if (m.peer.eql(peer) and std.mem.eql(u8, &m.root, root)) {
                if (now >= m.until) m.count = 0;
                m.count +|= 1;
                m.until = now + root_miss_ms;
                return;
            }
        }
        const entry: RootMiss = .{ .peer = peer, .root = root.*, .count = 1, .until = now + root_miss_ms };
        if (self.root_miss_count < max_root_misses) {
            self.root_misses[self.root_miss_count] = entry;
            self.root_miss_count += 1;
            return;
        }
        // Full: replace the one expiring first.
        var victim: usize = 0;
        for (self.root_misses, 0..) |m, i| if (m.until < self.root_misses[victim].until) {
            victim = i;
        };
        self.root_misses[victim] = entry;
    }

    /// A block served: the device has (part of) the file after all.
    fn clearRootMissLocked(self: *Fetcher, peer: NodeID, root: *const Cid) void {
        for (self.root_misses[0..self.root_miss_count]) |*m| {
            if (m.peer.eql(peer) and std.mem.eql(u8, &m.root, root)) m.count = 0;
        }
    }
};

// ---- Tests: scheduling against a fake network ----

const testing = std.testing;

pub const FakeNet = struct {
    /// Per peer: has the blocks, delay in ms, fails to connect, answers
    /// with an error (reachable but failing).
    /// `connected`: the transport reports a live connection to it.
    /// `offline`: fails like the real connection manager does for a device
    /// none of whose addresses answers (error.AllAddressesFailed). `refused`: refused at once by the
    /// manager's dial backoff (error.PeerUnreachable). `timeout`: the
    /// request goes out but no answer comes back in time (error.Timeout).
    pub const Peer = struct { id: NodeID, has: bool = true, delay_ms: u64 = 0, down: bool = false, offline: bool = false, refused: bool = false, broken: bool = false, timeout: bool = false, connected: bool = false, served: std.atomic.Value(u32) = .init(0) };
    peers: []Peer,
    blocks: std.AutoHashMapUnmanaged(Cid, []const u8) = .empty,

    pub fn transport(self: *FakeNet) Transport {
        return .{ .ctx = self, .getFn = get, .connectedFn = connected };
    }

    fn connected(ctx: *anyopaque, peer: NodeID) bool {
        const self: *FakeNet = @ptrCast(@alignCast(ctx));
        for (self.peers) |p| if (p.id.eql(peer)) return p.connected;
        return false;
    }

    fn get(ctx: *anyopaque, peer: NodeID, cid: *const Cid, allocator: std.mem.Allocator) anyerror!?[]u8 {
        const self: *FakeNet = @ptrCast(@alignCast(ctx));
        for (self.peers) |*p| if (p.id.eql(peer)) {
            if (p.down) return error.ConnectionRefused;
            if (p.offline) return error.AllAddressesFailed;
            if (p.refused) return error.PeerUnreachable;
            if (p.broken) return error.InvalidResponse;
            if (p.timeout) return error.Timeout;
            if (p.delay_ms > 0) sync.sleep(p.delay_ms * std.time.ns_per_ms);
            if (!p.has) return null;
            const data = self.blocks.get(cid.*) orelse return null;
            _ = p.served.fetchAdd(1, .monotonic);
            return try allocator.dupe(u8, data);
        };
        return error.UnknownPeer;
    }
};

fn idOf(b: u8) NodeID {
    return .{ .bytes = [_]u8{b} ** 32 };
}

/// A fresh store at `path` for a test (keeper.zig's tests use it too).
pub fn testStore(path: []const u8) !storage.engine.StorageEngine {
    const io = std.Io.Threaded.global_single_threaded.io();
    std.Io.Dir.cwd().deleteTree(io, path) catch {};
    return storage.engine.StorageEngine.init(testing.allocator, path);
}

/// `n` leaf blocks of `size` bytes in `net`; their CIDs in `out`.
fn addBlocks(net: *FakeNet, arena: std.mem.Allocator, n: usize, size: usize, out: []Cid) !void {
    for (out[0..n], 0..) |*cid, i| {
        const data = try arena.alloc(u8, size);
        @memset(data, @intCast(i % 251));
        data[0] = 0; // a leaf
        std.mem.writeInt(u32, data[1..5], @intCast(i), .little);
        std.crypto.hash.sha2.Sha256.hash(data, cid, .{});
        try net.blocks.put(arena, cid.*, data);
    }
}

test "fetcher: skips a device without the file after a few misses, then uses one that has it" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const path = "test_fetcher_miss";
    var store = try testStore(path);
    defer {
        store.deinit();
        std.Io.Dir.cwd().deleteTree(std.Io.Threaded.global_single_threaded.io(), path) catch {};
    }
    var peers = [_]FakeNet.Peer{ .{ .id = idOf(1), .has = false }, .{ .id = idOf(2) } };
    var net: FakeNet = .{ .peers = &peers };
    var cids: [10]Cid = undefined;
    try addBlocks(&net, arena.allocator(), cids.len, 1024, &cids);
    var f = Fetcher.init(&store, net.transport());
    const root = [_]u8{9} ** 32;
    const holders = [_]NodeID{ idOf(1), idOf(2) };
    for (&cids) |*cid| testing.allocator.free(try f.fetch(&root, cid, &holders, testing.allocator));
    // The device without the file is asked until it has missed 3 times in a
    // row on this file, then skipped.
    try testing.expectEqual(@as(u64, Fetcher.root_miss_after), f.totals().not_found);
    try testing.expectEqual(@as(u32, 10), peers[1].served.load(.monotonic));
    // Read again: local now.
    for (&cids) |*cid| testing.allocator.free(try f.fetch(&root, cid, &holders, testing.allocator));
    try testing.expectEqual(@as(u64, 10), f.totals().local);
}

test "fetcher: a device that fails to connect is skipped until its backoff ends" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const path = "test_fetcher_down";
    var store = try testStore(path);
    defer {
        store.deinit();
        std.Io.Dir.cwd().deleteTree(std.Io.Threaded.global_single_threaded.io(), path) catch {};
    }
    var peers = [_]FakeNet.Peer{ .{ .id = idOf(1), .down = true }, .{ .id = idOf(2) } };
    var net: FakeNet = .{ .peers = &peers };
    var cids: [5]Cid = undefined;
    try addBlocks(&net, arena.allocator(), cids.len, 1024, &cids);
    var f = Fetcher.init(&store, net.transport());
    const root = [_]u8{9} ** 32;
    const holders = [_]NodeID{ idOf(1), idOf(2) };
    for (&cids) |*cid| testing.allocator.free(try f.fetch(&root, cid, &holders, testing.allocator));
    try testing.expectEqual(@as(u64, 1), f.totals().failed);
    try testing.expect(f.isDown(idOf(1)));
    // Nothing is left in flight after failures.
    var buf: [8]Fetcher.PeerState = undefined;
    for (f.snapshot(&buf)) |s| try testing.expectEqual(@as(u16, 0), s.in_flight);
    // A block 2 doesn't have: 1, backing off, is still asked once; it may
    // have it, so the read says out of reach, not "not found".
    const missing = [_]u8{7} ** 32;
    try testing.expectError(error.HoldersUnreachable, f.fetch(&root, &missing, &holders, testing.allocator));
    try testing.expectEqual(@as(u64, 2), f.totals().failed);
}

test "fetcher: concurrent fetches spread across holders, more to the faster one" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const path = "test_fetcher_spread";
    var store = try testStore(path);
    defer {
        store.deinit();
        std.Io.Dir.cwd().deleteTree(std.Io.Threaded.global_single_threaded.io(), path) catch {};
    }
    var peers = [_]FakeNet.Peer{ .{ .id = idOf(1), .delay_ms = 2 }, .{ .id = idOf(2), .delay_ms = 2 }, .{ .id = idOf(3), .delay_ms = 20 } };
    var net: FakeNet = .{ .peers = &peers };
    var cids: [120]Cid = undefined;
    try addBlocks(&net, arena.allocator(), cids.len, 64 * 1024, &cids);
    var f = Fetcher.init(&store, net.transport());
    const root = [_]u8{9} ** 32;
    const holders = [_]NodeID{ idOf(3), idOf(1), idOf(2) };

    // Six workers, like read-ahead.
    const Worker = struct {
        fn run(fetcher: *Fetcher, all: []Cid, next: *std.atomic.Value(usize), hs: []const NodeID, r: *const Cid) void {
            while (true) {
                const i = next.fetchAdd(1, .monotonic);
                if (i >= all.len) return;
                const bytes = fetcher.fetch(r, &all[i], hs, testing.allocator) catch return;
                testing.allocator.free(bytes);
            }
        }
    };
    var next: std.atomic.Value(usize) = .init(0);
    var threads: [6]std.Thread = undefined;
    for (&threads) |*t| t.* = try std.Thread.spawn(.{}, Worker.run, .{ &f, &cids, &next, &holders, &root });
    for (threads) |t| t.join();

    const slow = peers[2].served.load(.monotonic);
    const fast = peers[0].served.load(.monotonic) + peers[1].served.load(.monotonic);
    try testing.expectEqual(@as(u64, cids.len), f.totals().fetched);
    // Every holder served some; the fast ones most of it.
    try testing.expect(peers[0].served.load(.monotonic) > 0 and peers[1].served.load(.monotonic) > 0);
    try testing.expect(fast > slow * 3);
}

test "fetcher: lost when the author and every reachable holder said not found" {
    const path = "test_fetcher_lost";
    var store = try testStore(path);
    defer {
        store.deinit();
        std.Io.Dir.cwd().deleteTree(std.Io.Threaded.global_single_threaded.io(), path) catch {};
    }
    var peers = [_]FakeNet.Peer{
        .{ .id = idOf(1), .has = false }, // the author
        .{ .id = idOf(2), .has = false },
        .{ .id = idOf(3), .down = true }, // away: doesn't count
        .{ .id = idOf(4), .broken = true }, // reachable, answers an error
    };
    var net: FakeNet = .{ .peers = &peers };
    var f = Fetcher.init(&store, net.transport());
    const root = [_]u8{9} ** 32;
    const cid = [_]u8{7} ** 32;
    const author = idOf(1);
    var lost = false;
    try testing.expectError(error.BlockNotFound, f.fetchVerdict(&root, &cid, &.{ idOf(1), idOf(2) }, testing.allocator, author, &lost));
    try testing.expect(lost);
    // Asked again right away: both are skipped for their recent miss; still lost.
    _ = f.fetchVerdict(&root, &cid, &.{ idOf(1), idOf(2) }, testing.allocator, author, &lost) catch {};
    try testing.expect(lost);
    // A device that can't be reached doesn't hold the verdict back, now or
    // while it is backing off.
    _ = f.fetchVerdict(&root, &cid, &.{ idOf(1), idOf(2), idOf(3) }, testing.allocator, author, &lost) catch {};
    try testing.expect(lost);
    _ = f.fetchVerdict(&root, &cid, &.{ idOf(1), idOf(2), idOf(3) }, testing.allocator, author, &lost) catch {};
    try testing.expect(lost);
    // No author given, or the author not among the holders: never lost.
    _ = f.fetchVerdict(&root, &cid, &.{ idOf(1), idOf(2) }, testing.allocator, null, &lost) catch {};
    try testing.expect(!lost);
    _ = f.fetchVerdict(&root, &cid, &.{idOf(2)}, testing.allocator, author, &lost) catch {};
    try testing.expect(!lost);
    // No holder at all: not lost.
    try testing.expectError(error.NoHolders, f.fetchVerdict(&root, &cid, &.{}, testing.allocator, author, &lost));
    try testing.expect(!lost);
}

test "fetcher: a reachable holder that answers with an error keeps it from being lost" {
    const path = "test_fetcher_lost_broken";
    var store = try testStore(path);
    defer {
        store.deinit();
        std.Io.Dir.cwd().deleteTree(std.Io.Threaded.global_single_threaded.io(), path) catch {};
    }
    var peers = [_]FakeNet.Peer{ .{ .id = idOf(1), .has = false }, .{ .id = idOf(4), .broken = true } };
    var net: FakeNet = .{ .peers = &peers };
    var f = Fetcher.init(&store, net.transport());
    const root = [_]u8{9} ** 32;
    const cid = [_]u8{7} ** 32;
    var lost = true;
    _ = f.fetchVerdict(&root, &cid, &.{ idOf(1), idOf(4) }, testing.allocator, idOf(1), &lost) catch {};
    try testing.expect(!lost);
}

test "fetcher: an author that can't be reached never makes it lost" {
    const path = "test_fetcher_lost_author_away";
    var store = try testStore(path);
    defer {
        store.deinit();
        std.Io.Dir.cwd().deleteTree(std.Io.Threaded.global_single_threaded.io(), path) catch {};
    }
    var peers = [_]FakeNet.Peer{ .{ .id = idOf(1), .down = true }, .{ .id = idOf(2), .has = false } };
    var net: FakeNet = .{ .peers = &peers };
    var f = Fetcher.init(&store, net.transport());
    const root = [_]u8{9} ** 32;
    const cid = [_]u8{7} ** 32;
    var lost = true;
    _ = f.fetchVerdict(&root, &cid, &.{ idOf(1), idOf(2) }, testing.allocator, idOf(1), &lost) catch {};
    try testing.expect(!lost);
}

test "fetcher: every holder backing off: the first in the caller's order is asked, never none" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const path = "test_fetcher_probe";
    var store = try testStore(path);
    defer {
        store.deinit();
        std.Io.Dir.cwd().deleteTree(std.Io.Threaded.global_single_threaded.io(), path) catch {};
    }
    var peers = [_]FakeNet.Peer{ .{ .id = idOf(1) }, .{ .id = idOf(2) } };
    var net: FakeNet = .{ .peers = &peers };
    var cids: [1]Cid = undefined;
    try addBlocks(&net, arena.allocator(), cids.len, 1024, &cids);
    var f = Fetcher.init(&store, net.transport());
    const root = [_]u8{9} ** 32;
    const holders = [_]NodeID{ idOf(1), idOf(2) };
    // Both down (say, the mount saw them fail); 1 twice, so 2 is due back
    // sooner, but 1 is listed first (the caller ranks the backup first).
    f.markDown(idOf(1));
    f.markDown(idOf(1));
    f.markDown(idOf(2));
    // Both are back: the read asks 1 instead of failing.
    testing.allocator.free(try f.fetch(&root, &cids[0], &holders, testing.allocator));
    try testing.expectEqual(@as(u32, 1), peers[0].served.load(.monotonic));
    try testing.expectEqual(@as(u32, 0), peers[1].served.load(.monotonic));
    try testing.expect(!f.isDown(idOf(1)));
}

test "fetcher: every holder out of reach reads as HoldersUnreachable; no holder as NoHolders" {
    const path = "test_fetcher_unreachable";
    var store = try testStore(path);
    defer {
        store.deinit();
        std.Io.Dir.cwd().deleteTree(std.Io.Threaded.global_single_threaded.io(), path) catch {};
    }
    var peers = [_]FakeNet.Peer{ .{ .id = idOf(1), .down = true }, .{ .id = idOf(2), .down = true } };
    var net: FakeNet = .{ .peers = &peers };
    var f = Fetcher.init(&store, net.transport());
    const root = [_]u8{9} ** 32;
    const cid = [_]u8{7} ** 32;
    const holders = [_]NodeID{ idOf(1), idOf(2) };
    try testing.expectError(error.HoldersUnreachable, f.fetch(&root, &cid, &holders, testing.allocator));
    // Both backing off now: each is still asked once, and the answer is the same.
    try testing.expectError(error.HoldersUnreachable, f.fetch(&root, &cid, &holders, testing.allocator));
    try testing.expectEqual(@as(u64, 4), f.totals().failed);
    try testing.expectError(error.NoHolders, f.fetch(&root, &cid, &.{}, testing.allocator));
    // One holder without the block, the other out of reach: the one out of
    // reach may have it, so it isn't "not found".
    peers[1].down = false;
    peers[1].has = false;
    f.clearAllBackoff();
    try testing.expectError(error.HoldersUnreachable, f.fetch(&root, &cid, &holders, testing.allocator));
    // Every holder asked said "not found" (2 now, or a moment ago): it is.
    peers[0].down = false;
    peers[0].has = false;
    f.clearAllBackoff();
    try testing.expectError(error.BlockNotFound, f.fetch(&root, &cid, &holders, testing.allocator));
}

test "fetcher: a holder backing off is asked once it is connected again" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const path = "test_fetcher_connected";
    var store = try testStore(path);
    defer {
        store.deinit();
        std.Io.Dir.cwd().deleteTree(std.Io.Threaded.global_single_threaded.io(), path) catch {};
    }
    var peers = [_]FakeNet.Peer{ .{ .id = idOf(1), .delay_ms = 20 }, .{ .id = idOf(2) } };
    var net: FakeNet = .{ .peers = &peers };
    var cids: [2]Cid = undefined;
    try addBlocks(&net, arena.allocator(), cids.len, 1024, &cids);
    var f = Fetcher.init(&store, net.transport());
    const root = [_]u8{9} ** 32;
    const holders = [_]NodeID{ idOf(2), idOf(1) };
    // 2 is backing off: 1 serves.
    f.markDown(idOf(2));
    testing.allocator.free(try f.fetch(&root, &cids[0], &holders, testing.allocator));
    try testing.expectEqual(@as(u32, 1), peers[0].served.load(.monotonic));
    // 2 is connected again (say, through a relay): asked despite its
    // backoff, first as listed first (both unmeasured: small blocks).
    peers[1].connected = true;
    testing.allocator.free(try f.fetch(&root, &cids[1], &holders, testing.allocator));
    try testing.expectEqual(@as(u32, 1), peers[1].served.load(.monotonic));
}

test "fetcher: a probe of a device backing off never holds the lost verdict back" {
    const path = "test_fetcher_probe_lost";
    var store = try testStore(path);
    defer {
        store.deinit();
        std.Io.Dir.cwd().deleteTree(std.Io.Threaded.global_single_threaded.io(), path) catch {};
    }
    // 1, the author, said "not found"; 2 is refused by the manager's dial
    // backoff (an error that holds the verdict back when asked normally).
    var peers = [_]FakeNet.Peer{ .{ .id = idOf(1), .has = false }, .{ .id = idOf(2), .refused = true } };
    var net: FakeNet = .{ .peers = &peers };
    var f = Fetcher.init(&store, net.transport());
    const root = [_]u8{9} ** 32;
    const cid = [_]u8{7} ** 32;
    const holders = [_]NodeID{ idOf(1), idOf(2) };
    var lost = true;
    // Asked normally, 2's failure holds the verdict back (as before).
    _ = f.fetchVerdict(&root, &cid, &holders, testing.allocator, idOf(1), &lost) catch {};
    try testing.expect(!lost);
    // Again at once: 1 is skipped for its miss, 2 is backing off and asked
    // only as a probe. Its failure leaves the verdict as skipping it did.
    try testing.expectError(error.HoldersUnreachable, f.fetchVerdict(&root, &cid, &holders, testing.allocator, idOf(1), &lost));
    try testing.expect(lost);
    try testing.expectEqual(@as(u64, 2), f.totals().failed);
}

test "fetcher: every holder backing off is asked once, whatever the ones before it did" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const path = "test_fetcher_probe_refused";
    var store = try testStore(path);
    defer {
        store.deinit();
        std.Io.Dir.cwd().deleteTree(std.Io.Threaded.global_single_threaded.io(), path) catch {};
    }
    // 1 (the author, listed first) is dead and backed off in the manager;
    // 2 (the backup) has the block. Both back off in the fetcher.
    var peers = [_]FakeNet.Peer{ .{ .id = idOf(1), .refused = true }, .{ .id = idOf(2) }, .{ .id = idOf(3), .offline = true } };
    var net: FakeNet = .{ .peers = &peers };
    var cids: [1]Cid = undefined;
    try addBlocks(&net, arena.allocator(), cids.len, 1024, &cids);
    var f = Fetcher.init(&store, net.transport());
    const root = [_]u8{9} ** 32;
    f.markDown(idOf(1));
    f.markDown(idOf(2));
    testing.allocator.free(try f.fetch(&root, &cids[0], &.{ idOf(1), idOf(2) }, testing.allocator));
    try testing.expectEqual(@as(u64, 1), f.totals().failed); // 1 was asked, and refused
    try testing.expectEqual(@as(u32, 1), peers[1].served.load(.monotonic));
    // A probe that cost a real dial attempt (3: every address failed)
    // doesn't end the probing: 2 is asked too.
    const missing = [_]u8{7} ** 32;
    f.markDown(idOf(3));
    f.markDown(idOf(2));
    peers[1].has = false;
    try testing.expectError(error.HoldersUnreachable, f.fetch(&root, &missing, &.{ idOf(3), idOf(2) }, testing.allocator));
    try testing.expectEqual(@as(u64, 1), f.totals().not_found); // 2 was asked
}

test "fetcher: Tally.note, one rule per kind of failed attempt" {
    const Case = struct { attempt: Fetcher.Attempt, probe: bool, any_failed: bool, verdict: anyerror };
    const cases = [_]Case{
        // Refused at once by the manager's backoff: out of reach.
        .{ .attempt = .{ .failed = error.PeerUnreachable }, .probe = true, .any_failed = false, .verdict = error.HoldersUnreachable },
        // The same refusal asked normally holds the verdict back (the narrow set, as before).
        .{ .attempt = .{ .failed = error.PeerUnreachable }, .probe = false, .any_failed = true, .verdict = error.HoldersUnreachable },
        // A dial that went out and failed.
        .{ .attempt = .{ .failed = error.ConnectionRefused }, .probe = false, .any_failed = false, .verdict = error.HoldersUnreachable },
        .{ .attempt = .{ .failed = error.AllAddressesFailed }, .probe = true, .any_failed = false, .verdict = error.HoldersUnreachable },
        // Every address failed: offline, never holds the verdict back.
        .{ .attempt = .{ .failed = error.AllAddressesFailed }, .probe = false, .any_failed = false, .verdict = error.HoldersUnreachable },
        // A connected holder timing out: out of reach, not "not found".
        .{ .attempt = .{ .failed = error.Timeout }, .probe = false, .any_failed = false, .verdict = error.HoldersUnreachable },
        // A reachable holder answering with an error: reported as such.
        .{ .attempt = .{ .failed = error.InvalidResponse }, .probe = false, .any_failed = true, .verdict = error.InvalidResponse },
        .{ .attempt = .{ .failed = error.InvalidResponse }, .probe = true, .any_failed = false, .verdict = error.InvalidResponse },
        .{ .attempt = .not_found, .probe = false, .any_failed = false, .verdict = error.BlockNotFound },
        .{ .attempt = .bad_answer, .probe = true, .any_failed = true, .verdict = error.HashMismatch },
    };
    for (cases) |c| {
        var t: Fetcher.Tally = .{};
        t.note(c.attempt, c.probe);
        try testing.expectEqual(@as(usize, 1), t.attempts);
        try testing.expectEqual(c.any_failed, t.any_failed);
        try testing.expectEqual(c.verdict, t.verdict());
    }
    // Nothing asked: never "not found".
    const none: Fetcher.Tally = .{};
    try testing.expectEqual(@as(anyerror, error.NoHolderAskable), none.verdict());
}

test "fetcher: a holder's real failure is reported whatever order the answers came in" {
    const path = "test_fetcher_precedence";
    var store = try testStore(path);
    defer {
        store.deinit();
        std.Io.Dir.cwd().deleteTree(std.Io.Threaded.global_single_threaded.io(), path) catch {};
    }
    // 1 answers with an error, 2 says "not found".
    var peers = [_]FakeNet.Peer{ .{ .id = idOf(1), .broken = true }, .{ .id = idOf(2), .has = false } };
    var net: FakeNet = .{ .peers = &peers };
    var f = Fetcher.init(&store, net.transport());
    const root = [_]u8{9} ** 32;
    const a = [_]u8{7} ** 32;
    const b = [_]u8{8} ** 32;
    try testing.expectError(error.InvalidResponse, f.fetch(&root, &a, &.{ idOf(1), idOf(2) }, testing.allocator));
    f.clearAllBackoff();
    try testing.expectError(error.InvalidResponse, f.fetch(&root, &b, &.{ idOf(2), idOf(1) }, testing.allocator));
}

test "fetcher: the holder that has it timing out, then a \"not found\", isn't BlockNotFound" {
    const path = "test_fetcher_timeout_then_miss";
    var store = try testStore(path);
    defer {
        store.deinit();
        std.Io.Dir.cwd().deleteTree(std.Io.Threaded.global_single_threaded.io(), path) catch {};
    }
    // A gone author, the backup (connected, times out), a relay without it.
    var peers = [_]FakeNet.Peer{ .{ .id = idOf(1), .offline = true }, .{ .id = idOf(2), .timeout = true, .connected = true }, .{ .id = idOf(3), .has = false } };
    var net: FakeNet = .{ .peers = &peers };
    var f = Fetcher.init(&store, net.transport());
    const root = [_]u8{9} ** 32;
    const cid = [_]u8{7} ** 32;
    try testing.expectError(error.HoldersUnreachable, f.fetch(&root, &cid, &.{ idOf(1), idOf(2), idOf(3) }, testing.allocator));
}

test "fetcher: a verified block the read cache can't keep is still returned" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const path = "test_fetcher_cache_fail";
    var store = try testStore(path);
    defer {
        store.deinit();
        std.Io.Dir.cwd().deleteTree(std.Io.Threaded.global_single_threaded.io(), path) catch {};
    }
    var peers = [_]FakeNet.Peer{ .{ .id = idOf(1) }, .{ .id = idOf(2) } };
    var net: FakeNet = .{ .peers = &peers };
    var cids: [2]Cid = undefined;
    try addBlocks(&net, arena.allocator(), cids.len, 1024, &cids);
    var f = Fetcher.init(&store, net.transport());
    const root = [_]u8{9} ** 32;
    // The cache directory is gone: every cache write fails.
    const io = std.Io.Threaded.global_single_threaded.io();
    try std.Io.Dir.cwd().deleteTree(io, path ++ "/cache");
    for (&cids) |*cid| {
        const bytes = try f.fetch(&root, cid, &.{ idOf(1), idOf(2) }, testing.allocator);
        defer testing.allocator.free(bytes);
        try testing.expectEqualSlices(u8, net.blocks.get(cid.*).?, bytes);
    }
    // Served by the first holder each time: its answer wasn't taken for a bad one.
    try testing.expectEqual(@as(u32, 2), peers[0].served.load(.monotonic));
    try testing.expectEqual(@as(u32, 0), peers[1].served.load(.monotonic));
    try testing.expectEqual(@as(u64, 2), f.totals().cache_failed);
    try testing.expectEqual(@as(u64, 0), f.totals().failed);
    try testing.expect(!f.isDown(idOf(1)));
}

test "fetcher: the backup backing off is asked after a \"not found\" and a failed dial" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const path = "test_fetcher_probe_backup";
    var store = try testStore(path);
    defer {
        store.deinit();
        std.Io.Dir.cwd().deleteTree(std.Io.Threaded.global_single_threaded.io(), path) catch {};
    }
    // A gone author (every address fails), the backup (has it, backing off,
    // not connected right now), a relay without the block.
    var peers = [_]FakeNet.Peer{ .{ .id = idOf(1), .offline = true }, .{ .id = idOf(2) }, .{ .id = idOf(3), .has = false } };
    var net: FakeNet = .{ .peers = &peers };
    var cids: [1]Cid = undefined;
    try addBlocks(&net, arena.allocator(), cids.len, 1024, &cids);
    var f = Fetcher.init(&store, net.transport());
    const root = [_]u8{9} ** 32;
    f.markDown(idOf(2));
    testing.allocator.free(try f.fetch(&root, &cids[0], &.{ idOf(1), idOf(2), idOf(3) }, testing.allocator));
    try testing.expectEqual(@as(u32, 1), peers[1].served.load(.monotonic));
    try testing.expectEqual(@as(u64, 1), f.totals().not_found);
    try testing.expectEqual(@as(u64, 1), f.totals().failed);
}

test "fetcher: a connected holder that missed a moment ago is asked again when nobody else can be" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const path = "test_fetcher_revalidate";
    var store = try testStore(path);
    defer {
        store.deinit();
        std.Io.Dir.cwd().deleteTree(std.Io.Threaded.global_single_threaded.io(), path) catch {};
    }
    var peers = [_]FakeNet.Peer{ .{ .id = idOf(1), .has = false, .connected = true }, .{ .id = idOf(2), .has = false } };
    var net: FakeNet = .{ .peers = &peers };
    var cids: [1]Cid = undefined;
    try addBlocks(&net, arena.allocator(), cids.len, 1024, &cids);
    var f = Fetcher.init(&store, net.transport());
    const root = [_]u8{9} ** 32;
    const holders = [_]NodeID{ idOf(2), idOf(1) };
    try testing.expectError(error.BlockNotFound, f.fetch(&root, &cids[0], &holders, testing.allocator));
    // 1 got the block since. Both are skipped for their miss; 1 is
    // connected, so it is asked again (2, not connected, isn't).
    peers[0].has = true;
    testing.allocator.free(try f.fetch(&root, &cids[0], &holders, testing.allocator));
    try testing.expectEqual(@as(u32, 1), peers[0].served.load(.monotonic));
    try testing.expectEqual(@as(u64, 2), f.totals().not_found);
    // Nobody connected and every holder missed a moment ago: nothing is
    // asked, and that isn't reported as "not found".
    const other = [_]u8{6} ** 32;
    peers[0].connected = false;
    try testing.expectError(error.BlockNotFound, f.fetch(&root, &other, &holders, testing.allocator));
    try testing.expectError(error.NoHolderAskable, f.fetch(&root, &other, &holders, testing.allocator));
    try testing.expectEqual(@as(u64, 4), f.totals().not_found);
}

test "fetcher: a connected holder is asked before never-measured ones that aren't" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const path = "test_fetcher_connected_first";
    var store = try testStore(path);
    defer {
        store.deinit();
        std.Io.Dir.cwd().deleteTree(std.Io.Threaded.global_single_threaded.io(), path) catch {};
    }
    var peers = [_]FakeNet.Peer{ .{ .id = idOf(2), .delay_ms = 20, .connected = true }, .{ .id = idOf(5), .has = false }, .{ .id = idOf(6), .has = false } };
    var net: FakeNet = .{ .peers = &peers };
    var cids: [2]Cid = undefined;
    try addBlocks(&net, arena.allocator(), cids.len, 64 * 1024, &cids);
    var f = Fetcher.init(&store, net.transport());
    const root = [_]u8{9} ** 32;
    // The backup measured once, slowly; a fast device measured elsewhere
    // raises the rate assumed for devices never measured.
    testing.allocator.free(try f.fetch(&root, &cids[0], &.{idOf(2)}, testing.allocator));
    f.mutex.lock();
    f.getOrAddLocked(idOf(9), 0).rate = 1_000_000;
    f.mutex.unlock();
    // The unmeasured ones are listed first and look faster; the connected
    // backup is asked first anyway.
    testing.allocator.free(try f.fetch(&root, &cids[1], &.{ idOf(5), idOf(6), idOf(2) }, testing.allocator));
    try testing.expectEqual(@as(u64, 0), f.totals().not_found);
    try testing.expectEqual(@as(u32, 2), peers[0].served.load(.monotonic));
}

test "fetcher: a member whose every address fails doesn't hold the lost verdict back, even asked first" {
    const path = "test_fetcher_lost_offline";
    var store = try testStore(path);
    defer {
        store.deinit();
        std.Io.Dir.cwd().deleteTree(std.Io.Threaded.global_single_threaded.io(), path) catch {};
    }
    // 1, the author, said "not found"; 2 is offline and not backing off yet
    // (a keeper's parallel workers can all ask it before any of them fails).
    var peers = [_]FakeNet.Peer{ .{ .id = idOf(1), .has = false }, .{ .id = idOf(2), .offline = true } };
    var net: FakeNet = .{ .peers = &peers };
    var f = Fetcher.init(&store, net.transport());
    const root = [_]u8{9} ** 32;
    const cid = [_]u8{7} ** 32;
    var lost = false;
    try testing.expectError(error.HoldersUnreachable, f.fetchVerdict(&root, &cid, &.{ idOf(1), idOf(2) }, testing.allocator, idOf(1), &lost));
    try testing.expect(lost);
}

test "fetcher: a connected holder that missed a moment ago is asked again after another holder's not found" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const path = "test_fetcher_revalidate_mixed";
    var store = try testStore(path);
    defer {
        store.deinit();
        std.Io.Dir.cwd().deleteTree(std.Io.Threaded.global_single_threaded.io(), path) catch {};
    }
    // 2 is the backup, connected; it hadn't the block a moment ago.
    var peers = [_]FakeNet.Peer{ .{ .id = idOf(2), .has = false, .connected = true }, .{ .id = idOf(3), .has = false } };
    var net: FakeNet = .{ .peers = &peers };
    var cids: [1]Cid = undefined;
    try addBlocks(&net, arena.allocator(), cids.len, 1024, &cids);
    var f = Fetcher.init(&store, net.transport());
    const root = [_]u8{9} ** 32;
    try testing.expectError(error.BlockNotFound, f.fetch(&root, &cids[0], &.{idOf(2)}, testing.allocator));
    // It has it now. 3 (no miss) is asked and says "not found"; before
    // reporting that, the connected backup is asked again and serves.
    peers[0].has = true;
    testing.allocator.free(try f.fetch(&root, &cids[0], &.{ idOf(3), idOf(2) }, testing.allocator));
    try testing.expectEqual(@as(u32, 1), peers[0].served.load(.monotonic));
}

test "fetcher: a peer neither measured nor connected goes after a measured backup" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const path = "test_fetcher_unmeasured_last";
    var store = try testStore(path);
    defer {
        store.deinit();
        std.Io.Dir.cwd().deleteTree(std.Io.Threaded.global_single_threaded.io(), path) catch {};
    }
    // 4 is a dead author listed first; 5 the backup, measured (slow).
    var peers = [_]FakeNet.Peer{ .{ .id = idOf(4), .down = true }, .{ .id = idOf(5) } };
    var net: FakeNet = .{ .peers = &peers };
    var cids: [2]Cid = undefined;
    try addBlocks(&net, arena.allocator(), cids.len, 64 * 1024, &cids);
    var f = Fetcher.init(&store, net.transport());
    const root = [_]u8{9} ** 32;
    // Measure 5 on a leaf block (64 KiB) with 4 out of the list.
    testing.allocator.free(try f.fetch(&root, &cids[0], &.{idOf(5)}, testing.allocator));
    // 4 first in the list, never measured, not connected: 5 is asked first.
    testing.allocator.free(try f.fetch(&root, &cids[1], &.{ idOf(4), idOf(5) }, testing.allocator));
    try testing.expectEqual(@as(u64, 0), f.totals().failed);
}

test "fetcher: an offline holder doesn't keep a connected one that missed from being asked again" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const path = "test_fetcher_revalidate_offline";
    var store = try testStore(path);
    defer {
        store.deinit();
        std.Io.Dir.cwd().deleteTree(std.Io.Threaded.global_single_threaded.io(), path) catch {};
    }
    var peers = [_]FakeNet.Peer{ .{ .id = idOf(2), .has = false, .connected = true }, .{ .id = idOf(3), .offline = true } };
    var net: FakeNet = .{ .peers = &peers };
    var cids: [1]Cid = undefined;
    try addBlocks(&net, arena.allocator(), cids.len, 1024, &cids);
    var f = Fetcher.init(&store, net.transport());
    const root = [_]u8{9} ** 32;
    try testing.expectError(error.BlockNotFound, f.fetch(&root, &cids[0], &.{idOf(2)}, testing.allocator));
    // 2 (connected) has it now; 3 fails to be reached. 2 is asked again.
    peers[0].has = true;
    testing.allocator.free(try f.fetch(&root, &cids[0], &.{ idOf(3), idOf(2) }, testing.allocator));
    try testing.expectEqual(@as(u32, 1), peers[0].served.load(.monotonic));
}

test "fetcher: a connected holder whose link timed out isn't asked first on the next block" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const path = "test_fetcher_link_failed";
    var store = try testStore(path);
    defer {
        store.deinit();
        std.Io.Dir.cwd().deleteTree(std.Io.Threaded.global_single_threaded.io(), path) catch {};
    }
    // 4 looks connected but its session is silent (requests time out).
    var peers = [_]FakeNet.Peer{ .{ .id = idOf(4), .connected = true, .timeout = true }, .{ .id = idOf(5) } };
    var net: FakeNet = .{ .peers = &peers };
    var cids: [3]Cid = undefined;
    try addBlocks(&net, arena.allocator(), cids.len, 1024, &cids);
    var f = Fetcher.init(&store, net.transport());
    const root = [_]u8{9} ** 32;
    const holders = [_]NodeID{ idOf(4), idOf(5) };
    for (&cids) |*cid| testing.allocator.free(try f.fetch(&root, cid, &holders, testing.allocator));
    // One timeout, on the first block; then 5 is asked first.
    try testing.expectEqual(@as(u64, 1), f.totals().failed);
    try testing.expectEqual(@as(u32, 3), peers[1].served.load(.monotonic));
}
