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

/// Thread condition variable compatible with Zig 0.16.
pub const Condition = struct {
    inner: std.Io.Condition = .init,

    pub fn wait(self: *Condition, mutex: *Mutex) void {
        const io = std.Io.Threaded.global_single_threaded.io();
        self.inner.waitUncancelable(io, &mutex.inner);
    }

    pub fn signal(self: *Condition) void {
        const io = std.Io.Threaded.global_single_threaded.io();
        self.inner.signal(io);
    }

    pub fn broadcast(self: *Condition) void {
        const io = std.Io.Threaded.global_single_threaded.io();
        self.inner.broadcast(io);
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

/// WaitGroup compatible with Zig 0.16.
pub const WaitGroup = struct {
    state: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    event: std.Io.Event = .unset,

    const is_waiting: usize = 1 << 0;
    const one_pending: usize = 1 << 1;

    pub fn start(wg: *WaitGroup) void {
        _ = wg.state.fetchAdd(one_pending, .monotonic);
    }

    pub fn wait(wg: *WaitGroup) void {
        const io = std.Io.Threaded.global_single_threaded.io();
        const prev_state = wg.state.fetchAdd(is_waiting, .acquire);
        if ((prev_state / one_pending) > 0) wg.event.wait(io) catch {};
    }

    pub fn finish(wg: *WaitGroup) void {
        const io = std.Io.Threaded.global_single_threaded.io();
        const state = wg.state.fetchSub(one_pending, .acq_rel);
        if (state == (one_pending | is_waiting)) {
            wg.event.set(io);
        }
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
            .clock = .monotonic,
        };
        _ = duration.sleep(io) catch {};
    }
}

/// Returns current Unix timestamp in seconds.
pub fn timestamp() i64 {
    const io = std.Io.Threaded.global_single_threaded.io();
    return std.Io.Clock.real.now(io).toSeconds();
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
