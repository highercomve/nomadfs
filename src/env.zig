const std = @import("std");
const builtin = @import("builtin");

/// Retrieves an environment variable across platforms without requiring libc.
/// Caller owns the returned slice and must free it with `allocator`.
pub fn getEnv(allocator: std.mem.Allocator, key: []const u8) ?[]const u8 {
    if (builtin.os.tag == .windows) {
        const env: std.process.Environ = .{ .block = .global };
        return env.getAlloc(allocator, key) catch null;
    } else {
        // Read from /proc/self/environ on Linux / Unix
        const io = std.Io.Threaded.global_single_threaded.io();
        var file = std.Io.Dir.cwd().openFile(io, "/proc/self/environ", .{}) catch return null;
        defer file.close(io);

        var buf: [16384]u8 = undefined;
        const n = file.readPositionalAll(io, &buf, 0) catch return null;
        var it = std.mem.splitScalar(u8, buf[0..n], 0);
        while (it.next()) |entry| {
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
