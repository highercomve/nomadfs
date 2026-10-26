const sync = @import("../sync.zig");
const std = @import("std");

pub const RetryConfig = struct {
    max_attempts: u8 = 3,
    base_delay_ms: u64 = 100,
    max_delay_ms: u64 = 5000,
    exponential_backoff: bool = true,
};

pub const CircuitBreakerError = error{
    CircuitBreakerOpen,
};

pub const CircuitBreakerState = enum {
    Closed,
    Open,
    HalfOpen,
};

pub const CircuitBreaker = struct {
    state: CircuitBreakerState = .Closed,
    failure_count: u32 = 0,
    last_failure_time: i64 = 0,
    threshold: u32 = 5,
    timeout_ms: u64 = 60_000,
    mutex: sync.Mutex = .{},

    pub fn init(threshold: u32, timeout_ms: u64) CircuitBreaker {
        std.debug.assert(threshold > 0);
        std.debug.assert(timeout_ms > 0);

        return .{
            .threshold = threshold,
            .timeout_ms = timeout_ms,
        };
    }

    pub fn acquire(self: *CircuitBreaker) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        const now = sync.milliTimestamp();

        if (self.state == .Open) {
            if (now - self.last_failure_time > @as(i64, @intCast(self.timeout_ms))) {
                std.debug.print("Circuit breaker: Transitioning from Open to HalfOpen\n", .{});
                self.state = .HalfOpen;
            } else {
                std.debug.print("Circuit breaker: Circuit is Open, blocking request\n", .{});
                return error.CircuitBreakerOpen;
            }
        }

        std.debug.assert(self.state != .Open);
    }

    pub fn recordSuccess(self: *CircuitBreaker) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        const was_open = self.state == .Open;
        self.failure_count = 0;
        self.state = .Closed;

        if (was_open) {
            std.debug.print("Circuit breaker: Reset to Closed after success\n", .{});
        }
    }

    pub fn recordFailure(self: *CircuitBreaker) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        self.failure_count += 1;
        self.last_failure_time = sync.milliTimestamp();

        if (self.failure_count >= self.threshold) {
            std.debug.print("Circuit breaker: Opening after {d} failures\n", .{self.failure_count});
            self.state = .Open;
        }
    }

    pub fn getState(self: *CircuitBreaker) CircuitBreakerState {
        self.mutex.lock();
        defer self.mutex.unlock();

        return self.state;
    }

    pub fn getFailureCount(self: *CircuitBreaker) u32 {
        self.mutex.lock();
        defer self.mutex.unlock();

        return self.failure_count;
    }
};

pub fn retryWithBackoff(comptime T: type, config: RetryConfig, operation: fn () anyerror!T) anyerror!T {
    std.debug.assert(config.max_attempts > 0);
    std.debug.assert(config.base_delay_ms > 0);

    var attempt: u8 = 0;
    var delay: u64 = config.base_delay_ms;

    while (attempt < config.max_attempts) : (attempt += 1) {
        return operation() catch |err| {
            if (attempt >= config.max_attempts - 1) return err;

            if (!isRetriableError(err)) {
                return err;
            }

            std.debug.print("Retry attempt {d}/{d} after error: {any}\n", .{ attempt + 1, config.max_attempts, err });
            sync.sleep(delay * std.time.ns_per_ms);

            if (config.exponential_backoff) {
                delay = @min(delay * 2, config.max_delay_ms);
            }
            continue;
        };
    }
    unreachable;
}

fn isRetriableError(err: anyerror) bool {
    return switch (err) {
        error.ConnectionRefused => true,
        error.ConnectionResetByPeer => true,
        error.OperationTimedOut => true,
        error.NetworkUnreachable => true,
        error.WouldBlock => true,
        error.TimedOut => true,
        else => false,
    };
}

test "retryWithBackoff retries retriable errors" {
    const Op = struct {
        var calls: u8 = 0;
        fn run() anyerror!u32 {
            calls += 1;
            if (calls < 3) return error.ConnectionRefused;
            return 42;
        }
    };
    const value = try retryWithBackoff(u32, .{ .base_delay_ms = 1 }, Op.run);
    try std.testing.expectEqual(@as(u32, 42), value);
    try std.testing.expectEqual(@as(u8, 3), Op.calls);
}

test "CircuitBreaker opens after threshold failures" {
    var breaker = CircuitBreaker.init(2, 60_000);
    try breaker.acquire();
    breaker.recordFailure();
    breaker.recordFailure();
    try std.testing.expectError(error.CircuitBreakerOpen, breaker.acquire());
}
