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

    pub fn init(allocator: std.mem.Allocator) VectorClock {
        return VectorClock{
            .entries = std.ArrayList(Entry).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *VectorClock) void {
        for (self.entries.items) |entry| {
            self.allocator.free(entry.node_id);
        }
        self.entries.deinit();
    }
    
    // Increment the clock for a specific node
    pub fn increment(self: *VectorClock, node_id: []const u8) !void {
        for (self.entries.items) |*entry| {
            if (std.mem.eql(u8, entry.node_id, node_id)) {
                entry.counter += 1;
                return;
            }
        }
        // Not found, add new
        try self.entries.append(Entry{
            .node_id = try self.allocator.dupe(u8, node_id),
            .counter = 1,
        });
    }

    pub const Order = enum {
        Equal,
        Less,     // self < other (self happened before other)
        Greater,  // self > other (other happened before self)
        Concurrent,
    };

    pub fn compare(self: VectorClock, other: VectorClock) Order {
        var self_is_less = false;
        var other_is_less = false;

        // Iterate over all keys (union of both clocks)
        // This O(N*M) implementation is naive but fine for MVP with small N.
        
        // Check self against other
        for (self.entries.items) |s_entry| {
            var o_counter: u64 = 0;
            for (other.entries.items) |o_entry| {
                if (std.mem.eql(u8, s_entry.node_id, o_entry.node_id)) {
                    o_counter = o_entry.counter;
                    break;
                }
            }
            if (s_entry.counter > o_counter) other_is_less = true;
            if (s_entry.counter < o_counter) self_is_less = true;
        }

        // Check other against self (for keys missing in self)
        for (other.entries.items) |o_entry| {
            var s_counter: u64 = 0;
            for (self.entries.items) |s_entry| {
                if (std.mem.eql(u8, s_entry.node_id, o_entry.node_id)) {
                    s_counter = s_entry.counter;
                    break;
                }
            }
            if (o_entry.counter > s_counter) self_is_less = true;
            if (o_entry.counter < s_counter) other_is_less = true;
        }

        if (self_is_less and other_is_less) return .Concurrent;
        if (self_is_less) return .Less;
        if (other_is_less) return .Greater;
        return .Equal;
    }
    
    // Merge two vector clocks (element-wise max)
    pub fn merge(self: *VectorClock, other: VectorClock) !void {
        for (other.entries.items) |o_entry| {
            var found = false;
            for (self.entries.items) |*s_entry| {
                if (std.mem.eql(u8, s_entry.node_id, o_entry.node_id)) {
                    s_entry.counter = @max(s_entry.counter, o_entry.counter);
                    found = true;
                    break;
                }
            }
            if (!found) {
                try self.entries.append(Entry{
                    .node_id = try self.allocator.dupe(u8, o_entry.node_id),
                    .counter = o_entry.counter,
                });
            }
        }
    }
};
