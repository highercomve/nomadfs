//! Provider records: which nodes hold the content stored under a key.
//! Bounded in every dimension, since any peer can add records.

const std = @import("std");
const NodeID = @import("../id.zig").NodeID;

/// At most this many providers are kept (and sent) per key.
pub const max_per_key = 20;

/// Records older than this are dropped; holders must re-announce.
pub const default_ttl_s: i64 = 24 * 60 * 60;

pub const ProviderStore = struct {
    const Entry = struct {
        ids: [max_per_key]NodeID = undefined,
        seen: [max_per_key]i64 = undefined,
        len: u8 = 0,

        fn expire(self: *Entry, now: i64, ttl_s: i64) void {
            var i: usize = 0;
            while (i < self.len) {
                if (now - self.seen[i] > ttl_s) {
                    self.len -= 1;
                    self.ids[i] = self.ids[self.len];
                    self.seen[i] = self.seen[self.len];
                } else {
                    i += 1;
                }
            }
        }
    };

    entries: std.AutoHashMapUnmanaged(NodeID, Entry) = .empty,
    max_keys: usize = 100_000,
    ttl_s: i64 = default_ttl_s,

    pub fn deinit(self: *ProviderStore, allocator: std.mem.Allocator) void {
        self.entries.deinit(allocator);
    }

    /// Records `provider` for `key`, refreshing it if already present. When a
    /// key is full the stalest provider is replaced. error.StorageFull when a
    /// new key would exceed max_keys.
    pub fn add(self: *ProviderStore, allocator: std.mem.Allocator, key: NodeID, provider: NodeID, now: i64) !void {
        if (!self.entries.contains(key) and self.entries.count() >= self.max_keys) {
            return error.StorageFull;
        }
        const res = try self.entries.getOrPut(allocator, key);
        if (!res.found_existing) res.value_ptr.* = .{};
        const entry = res.value_ptr;
        entry.expire(now, self.ttl_s);

        for (entry.ids[0..entry.len], 0..) |existing, i| {
            if (existing.eql(provider)) {
                entry.seen[i] = now;
                return;
            }
        }
        if (entry.len < max_per_key) {
            entry.ids[entry.len] = provider;
            entry.seen[entry.len] = now;
            entry.len += 1;
            return;
        }
        const oldest = std.mem.indexOfMin(i64, &entry.seen);
        entry.ids[oldest] = provider;
        entry.seen[oldest] = now;
    }

    /// Copies the live providers of `key` into `out` and returns them.
    pub fn get(self: *ProviderStore, key: NodeID, now: i64, out: *[max_per_key]NodeID) []NodeID {
        const entry = self.entries.getPtr(key) orelse return out[0..0];
        entry.expire(now, self.ttl_s);
        if (entry.len == 0) {
            _ = self.entries.remove(key);
            return out[0..0];
        }
        @memcpy(out[0..entry.len], entry.ids[0..entry.len]);
        return out[0..entry.len];
    }
};

fn testId(byte: u8) NodeID {
    return .{ .bytes = [_]u8{byte} ** NodeID.len };
}

test "ProviderStore dedupes, caps and expires" {
    const allocator = std.testing.allocator;
    var store = ProviderStore{ .max_keys = 2, .ttl_s = 100 };
    defer store.deinit(allocator);
    var out: [max_per_key]NodeID = undefined;

    // Duplicates refresh instead of growing.
    try store.add(allocator, testId(1), testId(10), 0);
    try store.add(allocator, testId(1), testId(10), 5);
    try std.testing.expectEqual(@as(usize, 1), store.get(testId(1), 5, &out).len);

    // A full key replaces its stalest provider.
    var i: u8 = 0;
    while (i < max_per_key) : (i += 1) try store.add(allocator, testId(1), testId(20 + i), 10 + i);
    try std.testing.expectEqual(@as(usize, max_per_key), store.get(testId(1), 50, &out).len);
    for (out[0..max_per_key]) |p| try std.testing.expect(!p.eql(testId(10)));

    // Key cap: a third key is refused, existing keys still update.
    try store.add(allocator, testId(2), testId(30), 0);
    try std.testing.expectError(error.StorageFull, store.add(allocator, testId(3), testId(31), 0));
    try store.add(allocator, testId(2), testId(32), 0);

    // Expiry: everything is stale long after the TTL, and the key is freed.
    try std.testing.expectEqual(@as(usize, 0), store.get(testId(1), 1000, &out).len);
    try store.add(allocator, testId(3), testId(31), 1000);
}
