const std = @import("std");
const builtin = @import("builtin");

/// Thread-safe Mutex compatible with Zig 0.16 std.Io infrastructure.
pub const Mutex = struct {
    inner: std.Io.Mutex = .init,

    pub fn lock(self: *Mutex) void {
        std.Io.Threaded.mutexLock(&self.inner);
    }

    pub fn unlock(self: *Mutex) void {
        std.Io.Threaded.mutexUnlock(&self.inner);
    }

    pub fn tryLock(self: *Mutex) bool {
        return self.inner.tryLock();
    }
};

/// Condition variable built on a futex sequence counter, so that it can
/// offer a timed wait (std.Io.Condition has none in Zig 0.16).
/// Waiters must re-check their predicate after waking (spurious wakeups).
pub const Condition = struct {
    seq: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),

    /// Caller holds `mutex`.
    pub fn wait(self: *Condition, mutex: *Mutex) void {
        const io = std.Io.Threaded.global_single_threaded.io();
        const observed = self.seq.load(.acquire);
        mutex.unlock();
        io.futexWaitUncancelable(u32, &self.seq.raw, observed);
        mutex.lock();
    }

    /// Like wait, but also returns once `timeout_ns` has elapsed.
    /// Caller holds `mutex`.
    pub fn timedWait(self: *Condition, mutex: *Mutex, timeout_ns: u64) void {
        const io = std.Io.Threaded.global_single_threaded.io();
        const observed = self.seq.load(.acquire);
        mutex.unlock();
        io.futexWaitTimeout(u32, &self.seq.raw, observed, .{ .duration = .{
            .raw = .fromNanoseconds(@intCast(timeout_ns)),
            .clock = .awake,
        } }) catch {};
        mutex.lock();
    }

    pub fn signal(self: *Condition) void {
        const io = std.Io.Threaded.global_single_threaded.io();
        _ = self.seq.fetchAdd(1, .release);
        io.futexWake(u32, &self.seq.raw, 1);
    }

    pub fn broadcast(self: *Condition) void {
        const io = std.Io.Threaded.global_single_threaded.io();
        _ = self.seq.fetchAdd(1, .release);
        io.futexWake(u32, &self.seq.raw, std.math.maxInt(u32));
    }
};

/// Reader-writer lock compatible with Zig 0.16.
pub const RwLock = struct {
    inner: std.Io.RwLock = .init,

    pub fn lock(self: *RwLock) void {
        const io = std.Io.Threaded.global_single_threaded.io();
        self.inner.lockUncancelable(io);
    }

    pub fn unlock(self: *RwLock) void {
        const io = std.Io.Threaded.global_single_threaded.io();
        self.inner.unlock(io);
    }

    pub fn lockShared(self: *RwLock) void {
        const io = std.Io.Threaded.global_single_threaded.io();
        self.inner.lockSharedUncancelable(io);
    }

    pub fn unlockShared(self: *RwLock) void {
        const io = std.Io.Threaded.global_single_threaded.io();
        self.inner.unlockShared(io);
    }
};

/// WaitGroup compatible with Zig 0.16. Supports any number of waiters and
/// reuse after reaching zero.
pub const WaitGroup = struct {
    mutex: Mutex = .{},
    cond: Condition = .{},
    pending: usize = 0,

    pub fn start(wg: *WaitGroup) void {
        wg.mutex.lock();
        defer wg.mutex.unlock();
        wg.pending += 1;
    }

    pub fn wait(wg: *WaitGroup) void {
        wg.mutex.lock();
        defer wg.mutex.unlock();
        while (wg.pending > 0) wg.cond.wait(&wg.mutex);
    }

    pub fn finish(wg: *WaitGroup) void {
        wg.mutex.lock();
        defer wg.mutex.unlock();
        std.debug.assert(wg.pending > 0);
        wg.pending -= 1;
        if (wg.pending == 0) wg.cond.broadcast();
    }
};

/// Sleeps for specified nanoseconds without requiring libc.
pub fn sleep(nanoseconds: u64) void {
    if (builtin.os.tag == .linux) {
        const ts: std.os.linux.timespec = .{
            .sec = @intCast(nanoseconds / std.time.ns_per_s),
            .nsec = @intCast(nanoseconds % std.time.ns_per_s),
        };
        _ = std.os.linux.nanosleep(&ts, null);
    } else {
        const io = std.Io.Threaded.global_single_threaded.io();
        const duration: std.Io.Clock.Duration = .{
            .raw = .{ .nanoseconds = @intCast(nanoseconds) },
            .clock = .awake,
        };
        _ = duration.sleep(io) catch {};
    }
}

/// Returns current Unix timestamp in seconds.
pub fn timestamp() i64 {
    const io = std.Io.Threaded.global_single_threaded.io();
    return std.Io.Clock.real.now(io).toSeconds();
}

/// Milliseconds on a clock that never jumps; use for deadlines.
pub fn monotonicMillis() i64 {
    const io = std.Io.Threaded.global_single_threaded.io();
    return @intCast(std.Io.Clock.awake.now(io).toMilliseconds());
}

/// Returns current Unix timestamp in milliseconds.
pub fn milliTimestamp() i64 {
    const io = std.Io.Threaded.global_single_threaded.io();
    return std.Io.Clock.real.now(io).toMilliseconds();
}

test "sync primitives work correctly" {
    var m: Mutex = .{};
    var c: Condition = .{};
    var wg: WaitGroup = .{};
    var rw: RwLock = .{};

    rw.lock();
    rw.unlock();
    rw.lockShared();
    rw.unlockShared();

    try std.testing.expect(timestamp() > 1700000000);
    try std.testing.expect(milliTimestamp() > 1700000000000);

    wg.start();
    const t = try std.Thread.spawn(.{}, struct {
        fn run(mutex: *Mutex, cond: *Condition, group: *WaitGroup) void {
            mutex.lock();
            cond.signal();
            mutex.unlock();
            group.finish();
        }
    }.run, .{ &m, &c, &wg });
    t.detach();

    m.lock();
    c.wait(&m);
    m.unlock();

    wg.wait();
}

test "WaitGroup supports reuse and concurrent waiters" {
    var wg: WaitGroup = .{};
    wg.wait(); // Nothing pending: returns immediately.

    var round: usize = 0;
    while (round < 2) : (round += 1) {
        wg.start();
        wg.start();
        const Waiter = struct {
            fn run(group: *WaitGroup) void {
                group.wait();
            }
        };
        const w1 = try std.Thread.spawn(.{}, Waiter.run, .{&wg});
        const w2 = try std.Thread.spawn(.{}, Waiter.run, .{&wg});
        wg.finish();
        wg.finish();
        w1.join();
        w2.join();
        try std.testing.expectEqual(@as(usize, 0), wg.pending);
    }
}

test "Condition.timedWait returns after the timeout" {
    var m: Mutex = .{};
    var c: Condition = .{};
    m.lock();
    defer m.unlock();
    const start = monotonicMillis();
    c.timedWait(&m, 50 * std.time.ns_per_ms);
    try std.testing.expect(monotonicMillis() - start >= 40);
}
