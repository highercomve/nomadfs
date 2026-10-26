const sync = @import("../sync.zig");
const std = @import("std");

pub const VectorClock = struct {
    // Map NodeID (string for now) -> Counter (u64)
    // Using a simple array of structs for MVP, sorted by node_id for easy comparison
    pub const Entry = struct {
        node_id: []const u8,
        counter: u64,
    };

    entries: std.ArrayList(Entry),
    allocator: std.mem.Allocator,
    mutex: sync.RwLock = .{},

    pub fn init(allocator: std.mem.Allocator) VectorClock {
        return VectorClock{
            .entries = .empty,
            .allocator = allocator,
            .mutex = .{},
        };
    }

    pub fn deinit(self: *VectorClock) void {
        for (self.entries.items) |entry| {
            self.allocator.free(entry.node_id);
        }
        self.entries.deinit(self.allocator);
    }

    // Increment the clock for a specific node
    pub fn increment(self: *VectorClock, node_id: []const u8) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        std.debug.assert(node_id.len > 0);
        std.debug.assert(self.entries.items.len < MAX_VECTOR_CLOCK_ENTRIES);

        const Context = struct {
            pub fn compare(key: []const u8, entry: Entry) std.math.Order {
                return std.mem.order(u8, key, entry.node_id);
            }
        };

        // Binary search for the node_id
        const index = std.sort.lowerBound(Entry, self.entries.items, node_id, Context.compare);

        if (index < self.entries.items.len and std.mem.eql(u8, self.entries.items[index].node_id, node_id)) {
            self.entries.items[index].counter += 1;
        } else {
            // Not found, insert at index to maintain sort order
            try self.insertCopy(index, node_id, 1);
        }

        std.debug.assert(self.entries.items.len <= MAX_VECTOR_CLOCK_ENTRIES);
    }

    /// Inserts an entry owning a copy of `node_id`. On error nothing is
    /// inserted and nothing leaks. Caller holds the write lock.
    fn insertCopy(self: *VectorClock, index: usize, node_id: []const u8, counter: u64) !void {
        try self.entries.ensureUnusedCapacity(self.allocator, 1);
        const node_id_copy = try self.allocator.dupe(u8, node_id);
        self.entries.insertAssumeCapacity(index, .{ .node_id = node_id_copy, .counter = counter });
    }

    pub const Order = enum {
        Equal,
        Less, // self < other (self happened before other)
        Greater, // self > other (other happened before self)
        Concurrent,
    };

    const MAX_VECTOR_CLOCK_ENTRIES = 1000;

    /// Compare two vector clocks for causal ordering.
    ///
    /// Time Complexity: O(N+M) where N = self.entries.len, M = other.entries.len
    /// Space Complexity: O(1)
    pub fn compare(self: *VectorClock, other: *VectorClock) Order {
        self.mutex.lockShared();
        defer self.mutex.unlockShared();
        other.mutex.lockShared();
        defer other.mutex.unlockShared();

        var self_is_less = false;
        var other_is_less = false;

        var i: usize = 0;
        var j: usize = 0;

        while (i < self.entries.items.len and j < other.entries.items.len) {
            const s_entry = self.entries.items[i];
            const o_entry = other.entries.items[j];

            const order = std.mem.order(u8, s_entry.node_id, o_entry.node_id);
            switch (order) {
                .eq => {
                    if (s_entry.counter < o_entry.counter) self_is_less = true;
                    if (s_entry.counter > o_entry.counter) other_is_less = true;
                    i += 1;
                    j += 1;
                },
                .lt => {
                    // self has a node that other doesn't have (implicitly 0 in other)
                    // s_entry.counter > 0, so other is less
                    other_is_less = true;
                    i += 1;
                },
                .gt => {
                    // other has a node that self doesn't have (implicitly 0 in self)
                    // o_entry.counter > 0, so self is less
                    self_is_less = true;
                    j += 1;
                },
            }
        }

        // Process remaining elements
        while (i < self.entries.items.len) {
            other_is_less = true;
            i += 1;
        }
        while (j < other.entries.items.len) {
            self_is_less = true;
            j += 1;
        }

        if (self_is_less and other_is_less) return .Concurrent;
        if (self_is_less) return .Less;
        if (other_is_less) return .Greater;
        return .Equal;
    }

    // Merge two vector clocks (element-wise max)
    pub fn merge(self: *VectorClock, other: *VectorClock) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        other.mutex.lockShared();
        defer other.mutex.unlockShared();

        var i: usize = 0;
        var j: usize = 0;

        // We need to mutate self.entries. We will iterate and insert/update.
        // Since inserting can shift elements, we need to be careful with index 'i'.

        while (j < other.entries.items.len) {
            const o_entry = other.entries.items[j];

            // If we reached end of self, just append remaining from other
            if (i >= self.entries.items.len) {
                try self.insertCopy(i, o_entry.node_id, o_entry.counter);
                j += 1;
                i += 1;
                continue;
            }

            const s_entry = &self.entries.items[i];
            const order = std.mem.order(u8, s_entry.node_id, o_entry.node_id);

            switch (order) {
                .eq => {
                    s_entry.counter = @max(s_entry.counter, o_entry.counter);
                    i += 1;
                    j += 1;
                },
                .lt => {
                    // self has node that other doesn't, skip it
                    i += 1;
                },
                .gt => {
                    // other has node that self doesn't, insert it at i
                    try self.insertCopy(i, o_entry.node_id, o_entry.counter);
                    i += 1; // Point to next element (after insertion)
                    j += 1;
                },
            }
        }
    }
};

test "VectorClock operations" {
    const allocator = std.testing.allocator;
    var vc1 = VectorClock.init(allocator);
    defer vc1.deinit();

    try vc1.increment("A");
    try vc1.increment("A");
    try vc1.increment("B");

    try std.testing.expectEqual(@as(u64, 2), vc1.entries.items[0].counter); // "A"
    try std.testing.expectEqualStrings("A", vc1.entries.items[0].node_id);
    try std.testing.expectEqual(@as(u64, 1), vc1.entries.items[1].counter); // "B"
    try std.testing.expectEqualStrings("B", vc1.entries.items[1].node_id);

    var vc2 = VectorClock.init(allocator);
    defer vc2.deinit();

    try vc2.increment("A");
    try vc2.increment("C");

    // Compare
    // vc1: {A:2, B:1}
    // vc2: {A:1, C:1}
    // A: 2 > 1 (vc1 > vc2)
    // B: 1 > 0 (vc1 > vc2)
    // C: 0 < 1 (vc1 < vc2)
    // -> Concurrent
    try std.testing.expectEqual(VectorClock.Order.Concurrent, vc1.compare(&vc2));

    // Merge vc2 into vc1
    try vc1.merge(&vc2);
    // vc1 should be {A:2, B:1, C:1}
    try std.testing.expectEqual(@as(usize, 3), vc1.entries.items.len);
    try std.testing.expectEqual(@as(u64, 2), vc1.entries.items[0].counter);
    try std.testing.expectEqual(@as(u64, 1), vc1.entries.items[1].counter);
    try std.testing.expectEqual(@as(u64, 1), vc1.entries.items[2].counter);

    // Test Equal
    var vc3 = VectorClock.init(allocator);
    defer vc3.deinit();
    try vc3.increment("A");
    try vc3.increment("A");
    try vc3.increment("B");
    try vc3.increment("C");

    try std.testing.expectEqual(VectorClock.Order.Equal, vc1.compare(&vc3));
}

test "VectorClock does not leak when allocation fails" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, struct {
        fn run(allocator: std.mem.Allocator) !void {
            var a = VectorClock.init(allocator);
            defer a.deinit();
            var b = VectorClock.init(allocator);
            defer b.deinit();

            try a.increment("B");
            try a.increment("E");
            try b.increment("A");
            try b.increment("C");
            try b.increment("F");
            try a.merge(&b);
        }
    }.run, .{});
}
