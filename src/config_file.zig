//! Changing `nomadfs.conf` in place: the one editor the app and the command
//! line use. The file is flat `key = value` lines (config.zig ignores the
//! section headers), so an edit drops the lines it replaces and appends the
//! new ones, keeping comments and every other setting as they are. Writes
//! are atomic (temp file, fsync, rename) and owner-only: the file holds the
//! swarm key.

const std = @import("std");
const builtin = @import("builtin");
const sync = @import("sync.zig");
const config_mod = @import("config.zig");

pub const private_file_perms: std.Io.File.Permissions = if (builtin.os.tag == .windows) .default_file else @enumFromInt(0o600);
pub const private_dir_perms: std.Io.File.Permissions = if (builtin.os.tag == .windows) .default_file else @enumFromInt(0o700);
/// Bigger is not a config this program wrote.
pub const max_bytes = 64 * 1024;

/// Serializes every read-modify-write of a config file in this process.
pub var mutex: sync.Mutex = .{};

pub const Edit = struct {
    /// Remove `key = ...` lines for these keys.
    drop_keys: []const []const u8 = &.{},
    /// Remove the `share = "<name>:..."` line of this share.
    drop_share: ?[]const u8 = null,
    /// Remove the `backup = "<name>"` line of this share.
    drop_backup: ?[]const u8 = null,
    append: []const []const u8 = &.{},
};

/// Drops the matching lines and appends new ones.
pub fn edit(allocator: std.mem.Allocator, path: []const u8, change: Edit) !void {
    mutex.lock();
    defer mutex.unlock();
    const io = std.Io.Threaded.global_single_threaded.io();
    const old = blk: {
        var file = try std.Io.Dir.cwd().openFile(io, path, .{});
        defer file.close(io);
        const size = (try file.stat(io)).size;
        if (size > max_bytes) return error.ConfigTooLarge;
        const buf = try allocator.alloc(u8, @intCast(size));
        errdefer allocator.free(buf);
        if (try file.readPositionalAll(io, buf, 0) != buf.len) return error.ShortRead;
        break :blk buf;
    };
    defer allocator.free(old);

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);
    var lines = std.mem.splitScalar(u8, old, '\n');
    while (lines.next()) |line| {
        if (lines.index == null and line.len == 0) break; // trailing newline
        if (dropped(line, change)) continue;
        try out.appendSlice(allocator, line);
        try out.append(allocator, '\n');
    }
    for (change.append) |line| {
        try out.appendSlice(allocator, line);
        try out.append(allocator, '\n');
    }
    try writeAtomic(allocator, io, path, out.items);
}

fn dropped(line: []const u8, change: Edit) bool {
    const trimmed = std.mem.trim(u8, line, " \t\r");
    const eq = std.mem.indexOfScalar(u8, trimmed, '=') orelse return false;
    const key = std.mem.trim(u8, trimmed[0..eq], " \t");
    const value = std.mem.trim(u8, trimmed[eq + 1 ..], " \t\"");
    for (change.drop_keys) |k| if (std.mem.eql(u8, key, k)) return true;
    if (change.drop_share) |name| if (std.mem.eql(u8, key, "share")) {
        if (config_mod.Config.Share.parse(value)) |share| {
            if (std.mem.eql(u8, share.name, name)) return true;
        } else |_| {}
    };
    if (change.drop_backup) |name| if (std.mem.eql(u8, key, "backup") and std.mem.eql(u8, value, name)) return true;
    return false;
}

/// Temp file (owner-only), fsync, rename: the old file stays whole if
/// anything fails.
pub fn writeAtomic(allocator: std.mem.Allocator, io: std.Io, path: []const u8, text: []const u8) !void {
    const tmp_path = try std.fmt.allocPrint(allocator, "{s}.tmp", .{path});
    defer allocator.free(tmp_path);
    const cwd = std.Io.Dir.cwd();
    errdefer cwd.deleteFile(io, tmp_path) catch {};
    {
        var file = try cwd.createFile(io, tmp_path, .{ .truncate = true, .permissions = private_file_perms });
        defer file.close(io);
        // A temp file left by an earlier run keeps its old mode on truncate.
        try file.setPermissions(io, private_file_perms);
        try file.writePositionalAll(io, text, 0);
        try file.sync(io);
    }
    try cwd.rename(tmp_path, cwd, path, io);
}

// ---- Typed changes ----

pub fn setBool(allocator: std.mem.Allocator, path: []const u8, key: []const u8, on: bool) !void {
    var buf: [64]u8 = undefined;
    const line = try std.fmt.bufPrint(&buf, "{s} = {s}", .{ key, if (on) "true" else "false" });
    try edit(allocator, path, .{ .drop_keys = &.{key}, .append = &.{line} });
}

pub fn setInt(allocator: std.mem.Allocator, path: []const u8, key: []const u8, value: u64) !void {
    var buf: [64]u8 = undefined;
    const line = try std.fmt.bufPrint(&buf, "{s} = {d}", .{ key, value });
    try edit(allocator, path, .{ .drop_keys = &.{key}, .append = &.{line} });
}

pub fn setNickname(allocator: std.mem.Allocator, path: []const u8, nickname: []const u8) !void {
    const nick = std.mem.trim(u8, nickname, " \t");
    if (nick.len == 0 or nick.len > 64 or std.mem.indexOfAny(u8, nick, "\"\n") != null) return error.InvalidNickname;
    var buf: [96]u8 = undefined;
    const line = try std.fmt.bufPrint(&buf, "nickname = \"{s}\"", .{nick});
    try edit(allocator, path, .{ .drop_keys = &.{"nickname"}, .append = &.{line} });
}

/// The swarm key and its rotation epoch; the key's text is wiped after.
pub fn setSwarmKey(allocator: std.mem.Allocator, path: []const u8, key: [32]u8, epoch: u64) !void {
    var key_line: [96]u8 = undefined;
    defer std.crypto.secureZero(u8, &key_line);
    const kl = try std.fmt.bufPrint(&key_line, "swarm_key = \"{s}\"", .{std.fmt.bytesToHex(key, .lower)});
    var epoch_buf: [48]u8 = undefined;
    const el = try std.fmt.bufPrint(&epoch_buf, "swarm_epoch = {d}", .{epoch});
    try edit(allocator, path, .{ .drop_keys = &.{ "swarm_key", "swarm_epoch" }, .append = &.{ kl, el } });
}

/// Adds `urls` (tcp://host:port) to `bootstrap_peers`, keeping the ones
/// already there and skipping duplicates and anything unquotable.
pub fn addBootstrapPeers(allocator: std.mem.Allocator, path: []const u8, urls: []const []const u8) !void {
    var config = config_mod.parseConfig(allocator, path) catch return error.ConfigInvalid;
    defer config.deinit(allocator);
    var line: std.ArrayList(u8) = .empty;
    defer line.deinit(allocator);
    try line.appendSlice(allocator, "bootstrap_peers = [");
    var first = true;
    for (config.network.bootstrap_peers) |p| {
        try line.print(allocator, "{s}\"{s}\"", .{ if (first) "" else ",", p });
        first = false;
    }
    for (urls) |u| {
        const dup = for (config.network.bootstrap_peers) |p| {
            if (std.mem.eql(u8, p, u)) break true;
        } else false;
        if (dup or std.mem.indexOfAny(u8, u, "\"[]\n") != null) continue;
        // Listed twice in `urls`: once.
        var quoted_buf: [256]u8 = undefined;
        const quoted = std.fmt.bufPrint(&quoted_buf, "\"{s}\"", .{u}) catch continue;
        if (std.mem.indexOf(u8, line.items, quoted) != null) continue;
        try line.print(allocator, "{s}{s}", .{ if (first) "" else ",", quoted });
        first = false;
    }
    try line.append(allocator, ']');
    try edit(allocator, path, .{ .drop_keys = &.{"bootstrap_peers"}, .append = &.{line.items} });
}

/// Adds or replaces a shared folder.
pub fn setShare(allocator: std.mem.Allocator, path: []const u8, name: []const u8, folder: []const u8) !void {
    const line = try std.fmt.allocPrint(allocator, "share = \"{s}:{s}\"", .{ name, folder });
    defer allocator.free(line);
    try edit(allocator, path, .{ .drop_share = name, .append = &.{line} });
}

/// Removes a shared folder and its backup mark.
pub fn removeShare(allocator: std.mem.Allocator, path: []const u8, name: []const u8) !void {
    try edit(allocator, path, .{ .drop_share = name, .drop_backup = name });
}

/// Marks a shared folder for backup, or not.
pub fn setShareBackup(allocator: std.mem.Allocator, path: []const u8, name: []const u8, on: bool) !void {
    const line = try std.fmt.allocPrint(allocator, "backup = \"{s}\"", .{name});
    defer allocator.free(line);
    try edit(allocator, path, .{ .drop_backup = name, .append = if (on) &.{line} else &.{} });
}

// ---- Tests ----

const testing = std.testing;

test "config file: edits are atomic, private, and keep the rest" {
    const io = std.Io.Threaded.global_single_threaded.io();
    const dir = "test_config_file";
    std.Io.Dir.cwd().deleteTree(io, dir) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};
    try std.Io.Dir.cwd().createDirPath(io, dir);
    const path = dir ++ "/nomadfs.conf";
    try writeAtomic(testing.allocator, io, path, "# mine\nnickname = \"alpha\"\nswarm_key = " ++ "ab" ** 32 ++ "\nstorage_path = \"/tmp/a\"\nshare = \"Photos:/p\"\nbackup = \"Photos\"\nport = 14700\n");

    try setNickname(testing.allocator, path, "beta");
    try setBool(testing.allocator, path, "accept_copies", false);
    try addBootstrapPeers(testing.allocator, path, &.{ "tcp://10.0.0.2:14700", "tcp://10.0.0.2:14700" });
    try removeShare(testing.allocator, path, "Photos");
    try testing.expectError(error.InvalidNickname, setNickname(testing.allocator, path, "a\"b"));

    var buf: [1024]u8 = undefined;
    var file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    const n = try file.readPositionalAll(io, &buf, 0);
    const text = buf[0..n];
    try testing.expect(std.mem.startsWith(u8, text, "# mine\n"));
    try testing.expect(std.mem.indexOf(u8, text, "nickname = \"beta\"") != null);
    try testing.expect(std.mem.indexOf(u8, text, "alpha") == null);
    try testing.expect(std.mem.indexOf(u8, text, "accept_copies = false") != null);
    // Added once, after whatever the parser defaults to.
    try testing.expect(std.mem.indexOf(u8, text, "bootstrap_peers = [") != null);
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, text, "\"tcp://10.0.0.2:14700\""));
    try testing.expect(std.mem.indexOf(u8, text, "share =") == null and std.mem.indexOf(u8, text, "backup =") == null);
    try testing.expect(std.mem.indexOf(u8, text, "port = 14700") != null);
    try testing.expectError(error.FileNotFound, std.Io.Dir.cwd().statFile(io, path ++ ".tmp", .{}));
    if (builtin.os.tag != .windows) {
        const st = try std.Io.Dir.cwd().statFile(io, path, .{});
        try testing.expectEqual(@as(u32, 0o600), @as(u32, @intFromEnum(st.permissions)) & 0o777);
    }
}
