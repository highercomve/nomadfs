//! Maps of peers to deadlines (recent dials, relay misses), pruned of
//! the ones that passed.

const std = @import("std");
const id = @import("../id.zig");

/// Entries pruned per call, at most (the maps hold no more).
pub const max_recent_peers = 1024;

// Remove expired entries without allocating or invalidating a live iterator.
pub fn pruneRecent(map: *std.AutoHashMapUnmanaged(id.NodeID, i64), now: i64) void {
    var stale: [max_recent_peers]id.NodeID = undefined;
    var count: usize = 0;
    var it = map.iterator();
    while (it.next()) |entry| {
        if (entry.value_ptr.* <= now) {
            stale[count] = entry.key_ptr.*;
            count += 1;
        }
    }
    for (stale[0..count]) |key| _ = map.remove(key);
}
