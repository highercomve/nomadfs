const sync = @import("sync.zig");
const std = @import("std");

pub const MetricType = enum {
    Counter,
    Gauge,
    Histogram,
};

pub const Metric = struct {
    /// Not owned: callers pass names with static lifetime (string literals).
    name: []const u8,
    type: MetricType,
    value: f64,
    timestamp: i64,

    pub fn init(name: []const u8, metric_type: MetricType, value: f64) Metric {
        return .{
            .name = name,
            .type = metric_type,
            .value = value,
            .timestamp = sync.milliTimestamp(),
        };
    }
};

/// Fixed-capacity ring of the most recent samples. Recording never allocates
/// and never fails; the oldest sample is overwritten when full.
pub const MetricsCollector = struct {
    pub const capacity = 10_000;

    samples: []Metric,
    /// Index of the oldest sample.
    head: usize = 0,
    len: usize = 0,
    allocator: std.mem.Allocator,
    mutex: sync.Mutex = .{},

    pub fn init(allocator: std.mem.Allocator) !MetricsCollector {
        return .{
            .samples = try allocator.alloc(Metric, capacity),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *MetricsCollector) void {
        self.allocator.free(self.samples);
    }

    pub fn incrementCounter(self: *MetricsCollector, name: []const u8, value: f64) void {
        std.debug.assert(value >= 0);
        self.record(Metric.init(name, .Counter, value));
    }

    pub fn recordGauge(self: *MetricsCollector, name: []const u8, value: f64) void {
        self.record(Metric.init(name, .Gauge, value));
    }

    pub fn recordHistogram(self: *MetricsCollector, name: []const u8, value: f64) void {
        std.debug.assert(value >= 0);
        self.record(Metric.init(name, .Histogram, value));
    }

    fn record(self: *MetricsCollector, metric: Metric) void {
        std.debug.assert(metric.name.len > 0);
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.len < capacity) {
            self.samples[(self.head + self.len) % capacity] = metric;
            self.len += 1;
        } else {
            self.samples[self.head] = metric;
            self.head = (self.head + 1) % capacity;
        }
    }

    /// Returns a caller-owned snapshot, oldest first. (Returning the internal
    /// buffer would let callers read it while other threads overwrite it.)
    pub fn snapshot(self: *MetricsCollector, allocator: std.mem.Allocator) ![]Metric {
        self.mutex.lock();
        defer self.mutex.unlock();

        const out = try allocator.alloc(Metric, self.len);
        for (out, 0..) |*m, i| m.* = self.samples[(self.head + i) % capacity];
        return out;
    }

    pub fn clear(self: *MetricsCollector) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.head = 0;
        self.len = 0;
    }
};

pub const Span = struct {
    name: []const u8,
    start_time: i64,
    end_time: ?i64 = null,
    parent: ?*Span = null,
    children: std.ArrayList(*Span),
    allocator: std.mem.Allocator,
    metadata: std.StringHashMapUnmanaged([]const u8),

    pub fn start(allocator: std.mem.Allocator, name: []const u8) !*Span {
        std.debug.assert(name.len > 0);

        const span = try allocator.create(Span);
        span.* = .{
            .name = name,
            .start_time = sync.monotonicMillis(),
            .children = .empty,
            .allocator = allocator,
            .metadata = .empty,
        };
        return span;
    }

    pub fn end(self: *Span) void {
        std.debug.assert(self.end_time == null);

        self.end_time = sync.monotonicMillis();
        std.debug.print("Span '{s}' completed in {d}ms\n", .{ self.name, self.end_time.? - self.start_time });
    }

    /// Takes ownership of `child`: it is freed with this span.
    pub fn addChild(self: *Span, child: *Span) !void {
        std.debug.assert(child.parent == null);
        try self.children.append(self.allocator, child);
        child.parent = self;
    }

    /// Key and value are not copied and must outlive the span.
    pub fn setMetadata(self: *Span, key: []const u8, value: []const u8) !void {
        std.debug.assert(key.len > 0);
        try self.metadata.put(self.allocator, key, value);
    }

    pub fn getMetadata(self: *Span, key: []const u8) ?[]const u8 {
        return self.metadata.get(key);
    }

    pub fn deinit(self: *Span) void {
        for (self.children.items) |child| {
            child.deinit();
        }
        self.children.deinit(self.allocator);
        self.metadata.deinit(self.allocator);
        self.allocator.destroy(self);
    }
};

test "MetricsCollector keeps the most recent samples" {
    var metrics = try MetricsCollector.init(std.testing.allocator);
    defer metrics.deinit();

    var i: usize = 0;
    while (i < MetricsCollector.capacity + 5) : (i += 1) {
        metrics.recordGauge("queue_depth", @floatFromInt(i));
    }

    const snap = try metrics.snapshot(std.testing.allocator);
    defer std.testing.allocator.free(snap);
    try std.testing.expectEqual(@as(usize, MetricsCollector.capacity), snap.len);
    try std.testing.expectEqual(@as(f64, 5), snap[0].value);
    try std.testing.expectEqual(@as(f64, MetricsCollector.capacity + 4), snap[snap.len - 1].value);

    metrics.clear();
    const empty = try metrics.snapshot(std.testing.allocator);
    defer std.testing.allocator.free(empty);
    try std.testing.expectEqual(@as(usize, 0), empty.len);
}

test "Span owns its children" {
    const root = try Span.start(std.testing.allocator, "root");
    defer root.deinit();
    const child = try Span.start(std.testing.allocator, "child");
    try root.addChild(child);
    try root.setMetadata("peer", "abc");
    try std.testing.expectEqualStrings("abc", root.getMetadata("peer").?);
    child.end();
    root.end();
}
