//! The allocator stb uses (`STBI_MALLOC` and friends in stb/stb_impl.c): C
//! malloc behind a per-thread byte budget. The codec opens a budget around
//! each call into stb, sized from the dimensions it already checked, so a
//! file whose header lies about its size fails to decode instead of taking
//! all the memory. Outside a budget every allocation fails.

const std = @import("std");

/// Bytes in front of each block: its size, so `realloc` and `free` can
/// return it to the budget. 16 keeps malloc's alignment.
const header_len = 16;

const State = struct {
    active: bool = false,
    /// Bytes this budget may still hand out (headers included).
    remaining: usize = 0,
    /// Bytes handed out and not yet freed (headers included).
    in_use: usize = 0,
    /// Most bytes handed out at once (headers included).
    peak: usize = 0,
    /// An allocation was refused for lack of budget.
    denied: bool = false,
    /// The system allocator itself had no memory for a block in budget.
    no_memory: bool = false,
};

threadlocal var state: State = .{};

/// Opens a budget of `limit` bytes on this thread. Budgets don't nest.
pub fn begin(limit: usize) void {
    std.debug.assert(!state.active);
    state = .{ .active = true, .remaining = limit };
}

/// Closes this thread's budget. Every block must have been freed.
pub fn end() void {
    std.debug.assert(state.active);
    std.debug.assert(state.in_use == 0);
    state = .{};
}

/// Whether an allocation was refused because the budget ran out.
pub fn denied() bool {
    return state.denied;
}

/// Whether the system ran out of memory for a block the budget allowed.
pub fn outOfMemory() bool {
    return state.no_memory;
}

/// The most bytes this budget had handed out at one time.
pub fn peak() usize {
    return state.peak;
}

/// Bytes handed out and not yet freed (for tests).
pub fn inUse() usize {
    return state.in_use;
}

fn take(size: usize) bool {
    if (!state.active or size > state.remaining) {
        state.denied = true;
        return false;
    }
    state.remaining -= size;
    state.in_use += size;
    state.peak = @max(state.peak, state.in_use);
    return true;
}

fn give(size: usize) void {
    std.debug.assert(state.in_use >= size);
    state.remaining += size;
    state.in_use -= size;
}

fn blockSize(base: [*]u8) usize {
    return std.mem.readInt(usize, base[0..@sizeOf(usize)], .little);
}

fn setBlockSize(base: [*]u8, size: usize) void {
    std.mem.writeInt(usize, base[0..@sizeOf(usize)], size, .little);
}

fn baseOf(ptr: *anyopaque) [*]u8 {
    return @as([*]u8, @ptrCast(ptr)) - header_len;
}

fn codecMalloc(size: usize) callconv(.c) ?*anyopaque {
    const total = std.math.add(usize, size, header_len) catch return null;
    if (!take(total)) return null;
    const raw = std.c.malloc(total) orelse {
        give(total);
        state.no_memory = true;
        return null;
    };
    const base: [*]u8 = @ptrCast(raw);
    setBlockSize(base, total);
    return base + header_len;
}

fn codecRealloc(ptr: ?*anyopaque, size: usize) callconv(.c) ?*anyopaque {
    const old_ptr = ptr orelse return codecMalloc(size);
    const base = baseOf(old_ptr);
    const old_total = blockSize(base);
    const total = std.math.add(usize, size, header_len) catch return null;
    if (total > old_total and !take(total - old_total)) return null;
    const raw = std.c.realloc(base, total) orelse {
        // The old block is untouched; return what was reserved for growth.
        if (total > old_total) give(total - old_total);
        state.no_memory = true;
        return null;
    };
    if (total < old_total) give(old_total - total);
    const new_base: [*]u8 = @ptrCast(raw);
    setBlockSize(new_base, total);
    return new_base + header_len;
}

fn codecFree(ptr: ?*anyopaque) callconv(.c) void {
    const p = ptr orelse return;
    const base = baseOf(p);
    give(blockSize(base));
    std.c.free(base);
}

// Hidden: stb finds them at link time, but the mobile shared library
// doesn't export them.
comptime {
    @export(&codecMalloc, .{ .name = "nomadfs_codec_malloc", .visibility = .hidden });
    @export(&codecRealloc, .{ .name = "nomadfs_codec_realloc", .visibility = .hidden });
    @export(&codecFree, .{ .name = "nomadfs_codec_free", .visibility = .hidden });
}

test "allocations fail outside a budget and once it runs out" {
    try std.testing.expect(codecMalloc(16) == null);

    begin(1024);
    defer end();
    const a = codecMalloc(512) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 512 + header_len), inUse());
    try std.testing.expect(codecMalloc(1024) == null);
    try std.testing.expect(denied());

    // Growing past the budget fails and leaves the block intact.
    const bytes: [*]u8 = @ptrCast(a);
    bytes[0] = 0xAB;
    try std.testing.expect(codecRealloc(a, 2048) == null);
    try std.testing.expectEqual(@as(u8, 0xAB), bytes[0]);

    // Shrinking gives bytes back; freeing returns the rest.
    const b = codecRealloc(a, 64) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 64 + header_len), inUse());
    try std.testing.expectEqual(@as(u8, 0xAB), @as([*]u8, @ptrCast(b))[0]);
    codecFree(b);
    codecFree(null);
    try std.testing.expectEqual(@as(usize, 0), inUse());
}
