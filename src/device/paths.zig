//! Where the device identity and trust store live.
//!
//! An explicit `key_path` in the configuration keeps everything next to the
//! node key. Otherwise the same search order as the transport key is used:
//! an existing `device.key` in the working directory first, then
//! `~/.nomadfs`, then the working directory as a last resort.

const std = @import("std");
const builtin = @import("builtin");
const env_mod = @import("../env.zig");

pub const identity_filename = "device.key";
pub const trust_filename = "trust.store";
pub const peers_filename = "known_peers";
/// Held (an exclusive lock) by the one node running on these files.
pub const lock_filename = "node.lock";

/// Locks the device's files for a running node: one node per config, since
/// two would each save the trust store, policy, known peers and folders
/// from their own memory. Released when the file is closed (or the process
/// dies). error.NodeAlreadyRunning when another node holds it.
pub fn lockNode(allocator: std.mem.Allocator, key_path: ?[]const u8) !std.Io.File {
    var paths = try Paths.resolve(allocator, key_path);
    defer paths.deinit(allocator);
    const dir = std.fs.path.dirname(paths.identity) orelse ".";
    const path = try std.fs.path.join(allocator, &.{ dir, lock_filename });
    defer allocator.free(path);
    const io = std.Io.Threaded.global_single_threaded.io();
    return std.Io.Dir.cwd().createFile(io, path, .{ .truncate = false, .lock = .exclusive, .lock_nonblocking = true }) catch |err| switch (err) {
        error.WouldBlock => error.NodeAlreadyRunning,
        else => err,
    };
}

pub const Paths = struct {
    identity: []u8,
    trust: []u8,
    /// Devices met and their addresses (net/discovery/known_peers.zig).
    peers: []u8,

    pub fn resolve(allocator: std.mem.Allocator, key_path: ?[]const u8) !Paths {
        if (key_path) |path| {
            const dir = std.fs.path.dirname(path) orelse ".";
            return joinPaths(allocator, dir);
        }

        const io = std.Io.Threaded.global_single_threaded.io();
        if (fileExists(io, identity_filename)) return joinPaths(allocator, ".");

        const home_env = if (builtin.os.tag == .windows) "USERPROFILE" else "HOME";
        if (env_mod.getEnv(allocator, home_env)) |home| {
            defer allocator.free(home);
            const dot_nomad = try std.fs.path.join(allocator, &.{ home, ".nomadfs" });
            defer allocator.free(dot_nomad);
            std.Io.Dir.cwd().createDirPath(io, dot_nomad) catch {};
            return joinPaths(allocator, dot_nomad);
        }

        return joinPaths(allocator, ".");
    }

    pub fn deinit(self: *Paths, allocator: std.mem.Allocator) void {
        allocator.free(self.identity);
        allocator.free(self.trust);
        allocator.free(self.peers);
        self.* = undefined;
    }
};

fn joinPaths(allocator: std.mem.Allocator, dir: []const u8) !Paths {
    const use_dir = !std.mem.eql(u8, dir, ".");
    const identity = if (use_dir)
        try std.fs.path.join(allocator, &.{ dir, identity_filename })
    else
        try allocator.dupe(u8, identity_filename);
    errdefer allocator.free(identity);
    const trust = if (use_dir)
        try std.fs.path.join(allocator, &.{ dir, trust_filename })
    else
        try allocator.dupe(u8, trust_filename);
    errdefer allocator.free(trust);
    const peers = if (use_dir)
        try std.fs.path.join(allocator, &.{ dir, peers_filename })
    else
        try allocator.dupe(u8, peers_filename);
    return .{ .identity = identity, .trust = trust, .peers = peers };
}

fn fileExists(io: std.Io, path: []const u8) bool {
    _ = std.Io.Dir.cwd().statFile(io, path, .{}) catch return false;
    return true;
}

const testing = std.testing;

test "paths: explicit key path keeps device files alongside" {
    var paths = try Paths.resolve(testing.allocator, "some/dir/node.key");
    defer paths.deinit(testing.allocator);
    try testing.expectEqualStrings("some/dir/device.key", paths.identity);
    try testing.expectEqualStrings("some/dir/trust.store", paths.trust);
}

test "paths: bare key path falls back to the working directory" {
    var paths = try Paths.resolve(testing.allocator, "node.key");
    defer paths.deinit(testing.allocator);
    try testing.expectEqualStrings("device.key", paths.identity);
    try testing.expectEqualStrings("trust.store", paths.trust);
}

test "paths: one node at a time holds the device's files" {
    const io = std.Io.Threaded.global_single_threaded.io();
    const dir = "test_node_lock";
    std.Io.Dir.cwd().deleteTree(io, dir) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};
    try std.Io.Dir.cwd().createDirPath(io, dir);
    const key = dir ++ "/node.key";
    const first = try lockNode(std.testing.allocator, key);
    try std.testing.expectError(error.NodeAlreadyRunning, lockNode(std.testing.allocator, key));
    first.close(io);
    const again = try lockNode(std.testing.allocator, key); // released with the file
    again.close(io);
}
