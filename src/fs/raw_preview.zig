//! Reads a RAW photo file and extracts its embedded preview JPEG (or RGB
//! fallback) for the viewer. Bounded: files over 256 MiB are refused.

const std = @import("std");
const codec = @import("../codec/mod.zig");
const SwarmFolder = @import("swarm.zig").SwarmFolder;

pub const max_raw_file_len: u64 = 256 * 1024 * 1024;

pub fn preview(allocator: std.mem.Allocator, swarm: *SwarmFolder, cid: [32]u8, author: [32]u8) ![]u8 {
    var bytes: []u8 = undefined;
    if (swarm.sizeOfCid(&cid)) |size| {
        if (size > max_raw_file_len) return error.TooLarge;
        if (size == 0) return error.NoPreview;
        bytes = try allocator.alloc(u8, @intCast(size));
        errdefer allocator.free(bytes);
        var offset: u64 = 0;
        while (offset < size) {
            const n = try swarm.readAt(allocator, cid, author, offset, bytes[offset..]);
            if (n == 0) return error.UnexpectedEof; // errdefer frees `bytes`
            offset += n;
        }
    } else {
        var list: std.ArrayList(u8) = .empty;
        errdefer list.deinit(allocator);
        // Read straight into the list's spare room: a chunk on the stack
        // overflowed the WebView's media thread on Android (its stack is
        // well under the 1 MiB a chunk took).
        const chunk_len = 1024 * 1024;
        var offset: u64 = 0;
        while (offset < max_raw_file_len) {
            try list.ensureUnusedCapacity(allocator, chunk_len);
            const room = list.unusedCapacitySlice();
            const n = try swarm.readAt(allocator, cid, author, offset, room[0..@min(room.len, chunk_len)]);
            if (n == 0) break;
            list.items.len += n;
            offset += n;
        }
        if (offset >= max_raw_file_len) return error.TooLarge;
        if (list.items.len == 0) return error.NoPreview;
        bytes = try list.toOwnedSlice(allocator);
    }
    defer allocator.free(bytes);

    return (try codec.raw.previewJpeg(allocator, bytes)) orelse error.NoPreview;
}
