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
    mutex: std.Thread.Mutex = .{},

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

        const now = std.time.milliTimestamp();

        if (self.state == .Open) {
            if (now - self.last_failure_time > self.timeout_ms) {
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
        self.last_failure_time = std.time.milliTimestamp();

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

pub fn retryWithBackoff(comptime T: type, config: RetryConfig, operation: fn () !T) !T {
    std.debug.assert(config.max_attempts > 0);
    std.debug.assert(config.base_delay_ms > 0);

    var attempt: u8 = 0;
    var delay: u64 = config.base_delay_ms;

    while (attempt < config.max_attempts) : (attempt += 1) {
        const result = operation() catch |err| {
            if (attempt >= config.max_attempts - 1) return err;

            if (!isRetriableError(err)) {
                return err;
            }

            std.debug.print("Retry attempt {d}/{d} after error: {any}\n", .{ attempt + 1, config.max_attempts, err });
            std.time.sleep(delay * 1_000_000);

            if (config.exponential_backoff) {
                delay = @min(delay * 2, config.max_delay_ms);
            }
        };

        return result;
    }
}
            } else {
                return err;
            }
        };

        return result;
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
