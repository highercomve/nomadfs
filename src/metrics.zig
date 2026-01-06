const std = @import("std");

pub const MetricType = enum {
    Counter,
    Gauge,
    Histogram,
};

pub const Metric = struct {
    name: []const u8,
    type: MetricType,
    value: f64,
    timestamp: i64,

    pub fn init(name: []const u8, metric_type: MetricType, value: f64) Metric {
        return .{
            .name = name,
            .type = metric_type,
            .value = value,
            .timestamp = std.time.milliTimestamp(),
        };
    }
};

pub const MetricsCollector = struct {
    metrics: std.ArrayList(Metric),
    mutex: std.Thread.Mutex = .{},

    pub fn init(allocator: std.mem.Allocator) MetricsCollector {
        return .{
            .metrics = std.ArrayList(Metric).init(allocator),
            .mutex = .{},
        };
    }

    pub fn deinit(self: *MetricsCollector) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        self.metrics.deinit();
    }

    pub fn incrementCounter(self: *MetricsCollector, name: []const u8, value: f64) void {
        std.debug.assert(name.len > 0);
        std.debug.assert(value >= 0);

        self.mutex.lock();
        defer self.mutex.unlock();

        const metric = Metric.init(name, .Counter, value);
        self.metrics.append(metric) catch {};
    }

    pub fn recordGauge(self: *MetricsCollector, name: []const u8, value: f64) void {
        std.debug.assert(name.len > 0);

        self.mutex.lock();
        defer self.mutex.unlock();

        const metric = Metric.init(name, .Gauge, value);
        self.metrics.append(metric) catch {};
    }

    pub fn recordHistogram(self: *MetricsCollector, name: []const u8, value: f64) void {
        std.debug.assert(name.len > 0);
        std.debug.assert(value >= 0);

        self.mutex.lock();
        defer self.mutex.unlock();

        const metric = Metric.init(name, .Histogram, value);
        self.metrics.append(metric) catch {};
    }

    pub fn getMetrics(self: *MetricsCollector) []Metric {
        self.mutex.lock();
        defer self.mutex.unlock();

        return self.metrics.items;
    }

    pub fn clear(self: *MetricsCollector) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        self.metrics.clearRetainingCapacity();
    }
};

pub const Span = struct {
    name: []const u8,
    start_time: i64,
    end_time: ?i64 = null,
    parent: ?*Span = null,
    children: std.ArrayList(*Span),
    allocator: std.mem.Allocator,
    metadata: std.StringHashMap([]const u8, []const u8),

    pub fn start(allocator: std.mem.Allocator, name: []const u8) Span {
        std.debug.assert(name.len > 0);

        const span = allocator.create(Span) catch unreachable;
        span.* = .{
            .name = name,
            .start_time = std.time.nanoTimestamp(),
            .children = std.ArrayList(*Span).init(allocator),
            .allocator = allocator,
            .metadata = std.StringHashMap([]const u8, []const u8).init(allocator),
        };
        return span;
    }

    pub fn end(self: *Span) void {
        std.debug.assert(self.end_time == null);

        self.end_time = std.time.nanoTimestamp();

        const duration_ns = self.end_time.? - self.start_time;
        const duration_ms = @as(f64, @floatFromInt(duration_ns)) / 1_000_000.0;

        std.debug.print("Span '{s}' completed in {d:.2}ms\n", .{ self.name, duration_ms });
    }

    pub fn addChild(self: *Span, child: *Span) void {
        std.debug.assert(child.parent == null);

        child.parent = self;
        self.children.append(child) catch {};
    }

    pub fn setMetadata(self: *Span, key: []const u8, value: []const u8) !void {
        std.debug.assert(key.len > 0);
        std.debug.assert(value.len > 0);

        try self.metadata.put(key, value);
    }

    pub fn getMetadata(self: *Span, key: []const u8) ?[]const u8 {
        return self.metadata.get(key);
    }

    pub fn deinit(self: *Span) void {
        for (self.children.items) |child| {
            child.deinit();
        }
        self.children.deinit();
        self.metadata.deinit();
        self.allocator.destroy(self);
    }
};

pub var global_metrics: ?MetricsCollector = null;

pub fn initGlobalMetrics(allocator: std.mem.Allocator) void {
    if (global_metrics == null) {
        global_metrics = allocator.create(MetricsCollector) catch unreachable;
        global_metrics.?.* = MetricsCollector.init(allocator);
    }
}

pub fn deinitGlobalMetrics(allocator: std.mem.Allocator) void {
    if (global_metrics) |*metrics| {
        metrics.deinit();
        allocator.destroy(metrics);
        global_metrics = null;
    }
}

pub fn incrementCounter(name: []const u8, value: f64) void {
    if (global_metrics) |*metrics| {
        metrics.incrementCounter(name, value);
    }
}

pub fn recordGauge(name: []const u8, value: f64) void {
    if (global_metrics) |*metrics| {
        metrics.recordGauge(name, value);
    }
}

pub fn recordHistogram(name: []const u8, value: f64) void {
    if (global_metrics) |*metrics| {
        metrics.recordHistogram(name, value);
    }
}

pub fn startSpan(allocator: std.mem.Allocator, name: []const u8) Span {
    return Span.start(allocator, name);
}
