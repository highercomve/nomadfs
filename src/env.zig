const std = @import("std");
const builtin = @import("builtin");

/// Retrieves an environment variable across platforms without requiring libc.
/// Caller owns the returned slice and must free it with `allocator`.
pub fn getEnv(allocator: std.mem.Allocator, key: []const u8) ?[]const u8 {
    if (builtin.os.tag == .windows) {
        const env: std.process.Environ = .{ .block = .global };
        return env.getAlloc(allocator, key) catch null;
    } else if (builtin.os.tag.isDarwin()) {
        // No /proc on macOS; libSystem is always linked there.
        var key_buf: [256]u8 = undefined;
        if (key.len >= key_buf.len) return null;
        @memcpy(key_buf[0..key.len], key);
        key_buf[key.len] = 0;
        const value = std.c.getenv(key_buf[0..key.len :0]) orelse return null;
        return allocator.dupe(u8, std.mem.span(value)) catch null;
    } else {
        // Read from /proc/self/environ on Linux / Android
        const io = std.Io.Threaded.global_single_threaded.io();
        var file = std.Io.Dir.cwd().openFile(io, "/proc/self/environ", .{}) catch return null;
        defer file.close(io);

        var bytes: std.ArrayList(u8) = .empty;
        defer bytes.deinit(allocator);
        var buf: [4096]u8 = undefined;
        while (true) {
            const n = file.readPositionalAll(io, &buf, bytes.items.len) catch return null;
            bytes.appendSlice(allocator, buf[0..n]) catch return null;
            if (n < buf.len) break;
        }
        var it = std.mem.splitScalar(u8, bytes.items, 0);
        while (it.next()) |entry| {
            // Only complete NUL-terminated entries can be environment values.
            if (it.index == null) break;
            if (std.mem.startsWith(u8, entry, key) and entry.len > key.len and entry[key.len] == '=') {
                return allocator.dupe(u8, entry[key.len + 1 ..]) catch null;
            }
        }
        return null;
    }
}

test "env.getEnv retrieves HOME" {
    if (builtin.os.tag != .windows) {
        const home = getEnv(std.testing.allocator, "HOME");
        try std.testing.expect(home != null);
        defer std.testing.allocator.free(home.?);
        try std.testing.expect(home.?.len > 0);
    }
}

/// `path` with a leading `~` replaced by the home directory (HOME, or
/// USERPROFILE on Windows); null when there's nothing to expand. Caller
/// frees.
pub fn expandHome(allocator: std.mem.Allocator, path: []const u8) !?[]u8 {
    if (!std.mem.startsWith(u8, path, "~")) return null;
    const home_env = if (builtin.os.tag == .windows) "USERPROFILE" else "HOME";
    const home = getEnv(allocator, home_env) orelse return null;
    defer allocator.free(home);
    return try std.fs.path.join(allocator, &.{ home, path[1..] });
}
