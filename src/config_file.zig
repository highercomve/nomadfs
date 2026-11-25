//! Changing `nomadfs.conf` in place: the one editor the app and the command
//! line use. Legacy settings are flat `key = value` lines; [backup.<name>]
//! and [webdav] are scoped and preserved. An edit drops the lines it replaces and appends the
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
    const old = try readWhole(allocator, io, path);
    defer allocator.free(old);

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);
    var backup_section = false;
    var webdav_section = false;
    var lines = std.mem.splitScalar(u8, old, '\n');
    while (lines.next()) |line| {
        if (lines.index == null and line.len == 0) break; // trailing newline
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (std.mem.startsWith(u8, trimmed, "[")) backup_section = @import("backup/config.zig").sectionName(trimmed) != null;
        if (std.mem.startsWith(u8, trimmed, "[")) webdav_section = std.mem.eql(u8, trimmed, "[webdav]");
        if (!backup_section and !webdav_section and dropped(line, change)) continue;
        try out.appendSlice(allocator, line);
        try out.append(allocator, '\n');
    }
    // The legacy editor appends node settings; leave the scoped backup section.
    if ((backup_section or webdav_section) and change.append.len > 0) try out.appendSlice(allocator, "[node]\n");
    for (change.append) |line| {
        try out.appendSlice(allocator, line);
        try out.append(allocator, '\n');
    }
    try writeAtomic(allocator, io, path, out.items);
}

/// The whole file; the caller frees it. Held with `mutex`.
fn readWhole(allocator: std.mem.Allocator, io: std.Io, path: []const u8) ![]u8 {
    var file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    const size = (try file.stat(io)).size;
    if (size > max_bytes) return error.ConfigTooLarge;
    const buf = try allocator.alloc(u8, @intCast(size));
    errdefer allocator.free(buf);
    if (try file.readPositionalAll(io, buf, 0) != buf.len) return error.ShortRead;
    return buf;
}

/// A change to one `[backup.<name>]` section.
pub const BackupEdit = union(enum) {
    /// A new section with these `key = value` lines, at the end of the
    /// file. error.BackupTargetExists when the file has one of that name.
    add: []const []const u8,
    /// The section and every line of it. error.UnknownBackupTarget when
    /// the file has none of that name.
    remove,
    /// One `key = value` line of the section, replacing the key's old one.
    set: struct { key: []const u8, line: []const u8 },
};

/// Adds, removes or changes the `[backup.<name>]` section; every other line
/// stays as it is. Settings written after a removed section (the flat
/// editor appends them under `[node]`) are kept.
pub fn editBackup(allocator: std.mem.Allocator, path: []const u8, name: []const u8, change: BackupEdit) !void {
    const backup_config = @import("backup/config.zig");
    if (!backup_config.validName(name)) return error.InvalidBackupTarget;
    mutex.lock();
    defer mutex.unlock();
    const io = std.Io.Threaded.global_single_threaded.io();
    const old = try readWhole(allocator, io, path);
    defer allocator.free(old);

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);
    var inside = false;
    var found = false;
    var lines = std.mem.splitScalar(u8, old, '\n');
    while (lines.next()) |line| {
        if (lines.index == null and line.len == 0) break; // trailing newline
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (std.mem.startsWith(u8, trimmed, "[")) {
            inside = if (backup_config.sectionName(trimmed)) |section| std.mem.eql(u8, section, name) else false;
            if (inside) {
                found = true;
                if (change == .remove) continue;
                try out.appendSlice(allocator, line);
                try out.append(allocator, '\n');
                if (change == .set) {
                    try out.appendSlice(allocator, change.set.line);
                    try out.append(allocator, '\n');
                }
                continue;
            }
        }
        if (inside) switch (change) {
            .remove => continue,
            .set => |s| if (std.mem.indexOfScalar(u8, trimmed, '=')) |eq| {
                if (std.mem.eql(u8, std.mem.trim(u8, trimmed[0..eq], " \t"), s.key)) continue;
            },
            .add => {},
        };
        try out.appendSlice(allocator, line);
        try out.append(allocator, '\n');
    }
    switch (change) {
        .add => |added| {
            if (found) return error.BackupTargetExists;
            try out.print(allocator, "[backup.{s}]\n", .{name});
            for (added) |line| {
                try out.appendSlice(allocator, line);
                try out.append(allocator, '\n');
            }
        },
        .remove, .set => if (!found) return error.UnknownBackupTarget,
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

/// A quoted string setting ("" clears it). error.InvalidValue for text
/// the file cannot hold (a quote, a line break).
pub fn setString(allocator: std.mem.Allocator, path: []const u8, key: []const u8, value: []const u8) !void {
    if (std.mem.indexOfAny(u8, value, "\"\r\n") != null) return error.InvalidValue;
    const line = try std.fmt.allocPrint(allocator, "{s} = \"{s}\"", .{ key, value });
    defer allocator.free(line);
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
    // The thumbnail settings are plain keys like the rest.
    try setInt(testing.allocator, path, "thumbs_cache_mb", 128);
    try setInt(testing.allocator, path, "thumbs_cache_mb", 64);
    try setBool(testing.allocator, path, "thumbs_prefer_local", false);
    try setString(testing.allocator, path, "ffmpeg_path", "/usr/bin/ffmpeg");
    try setString(testing.allocator, path, "ffmpeg_path", "/opt/emby-server/bin/emby-ffmpeg");
    try testing.expectError(error.InvalidValue, setString(testing.allocator, path, "ffmpeg_path", "a\"b"));
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
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, text, "thumbs_cache_mb"));
    var parsed = try config_mod.parseConfigText(testing.allocator, text);
    defer parsed.deinit(testing.allocator);
    try testing.expectEqual(@as(u64, 64), parsed.storage.thumbs_cache_mb);
    try testing.expect(!parsed.storage.thumbs_prefer_local);
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, text, "ffmpeg_path"));
    try testing.expectEqualStrings("/opt/emby-server/bin/emby-ffmpeg", parsed.storage.ffmpeg_path);
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

test "config: S3 section survives edits of node settings" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "config", .data = "nickname = alpha\nswarm_key = " ++ "ab" ** 32 ++ "\nstorage_path = /tmp/a\n[backup.s3]\nendpoint = \"https://example.test\"\nbucket = bucket\ncredentials = /tmp/credentials\n" });
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = buf[0..try tmp.dir.realPath(io, &buf)];
    const path = try std.fs.path.join(a, &.{ dir, "config" });
    defer a.free(path);
    try setNickname(a, path, "beta");
    var cfg = try config_mod.parseConfig(a, path);
    defer cfg.deinit(a);
    try std.testing.expectEqualStrings("beta", cfg.node.nickname);
    try std.testing.expectEqualStrings("https://example.test", cfg.backupTarget("s3").?.endpoint);
}

test "config: S3 sections are added, changed and removed, and the rest stays" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "config", .data = "# mine\nnickname = alpha\nswarm_key = " ++ "ab" ** 32 ++ "\nstorage_path = /tmp/a\n" });
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = buf[0..try tmp.dir.realPath(io, &buf)];
    const path = try std.fs.path.join(a, &.{ dir, "config" });
    defer a.free(path);

    try editBackup(a, path, "s3", .{ .add = &.{ "endpoint = \"https://one.test\"", "bucket = \"one\"", "credentials = \"/tmp/one\"" } });
    try std.testing.expectError(error.BackupTargetExists, editBackup(a, path, "s3", .{ .add = &.{} }));
    // A flat setting saved after it lands under [node], outside the section.
    try setNickname(a, path, "beta");
    try editBackup(a, path, "archive", .{ .add = &.{ "endpoint = \"https://two.test\"", "bucket = \"two\"", "credentials = \"/tmp/two\"", "storage_class = \"DEEP_ARCHIVE\"" } });
    try editBackup(a, path, "s3", .{ .set = .{ .key = "words_confirmed", .line = "words_confirmed = true" } });
    try editBackup(a, path, "s3", .{ .set = .{ .key = "words_confirmed", .line = "words_confirmed = true" } });
    try std.testing.expectError(error.UnknownBackupTarget, editBackup(a, path, "other", .{ .set = .{ .key = "words_confirmed", .line = "words_confirmed = true" } }));
    try std.testing.expectError(error.InvalidBackupTarget, editBackup(a, path, "No Such", .remove));
    {
        var cfg = try config_mod.parseConfig(a, path);
        defer cfg.deinit(a);
        try std.testing.expectEqual(@as(usize, 2), cfg.backup_targets.len);
        try std.testing.expect(cfg.backupTarget("s3").?.words_confirmed);
        try std.testing.expect(!cfg.backupTarget("archive").?.words_confirmed);
        try std.testing.expectEqualStrings("beta", cfg.node.nickname);
    }
    try editBackup(a, path, "s3", .remove);
    try std.testing.expectError(error.UnknownBackupTarget, editBackup(a, path, "s3", .remove));
    var cfg = try config_mod.parseConfig(a, path);
    defer cfg.deinit(a);
    try std.testing.expectEqual(@as(usize, 1), cfg.backup_targets.len);
    try std.testing.expectEqualStrings("https://two.test", cfg.backupTarget("archive").?.endpoint);
    try std.testing.expectEqualStrings("beta", cfg.node.nickname);
    const text = try tmp.dir.readFileAlloc(io, "config", a, .limited(4096));
    defer a.free(text);
    try std.testing.expect(std.mem.startsWith(u8, text, "# mine\n"));
    try std.testing.expect(std.mem.indexOf(u8, text, "one.test") == null);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, text, "[backup."));
}

/// Replaces only the scoped WebDAV section, preserving all other settings.
pub fn setWebDav(a: std.mem.Allocator, path: []const u8, value: config_mod.Config.WebDavConfig) !void {
    try @import("webdav/login.zig").validate(value);
    mutex.lock();
    defer mutex.unlock();
    const io = std.Io.Threaded.global_single_threaded.io();
    const old = try readWhole(a, io, path);
    defer a.free(old);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(a);
    var inside = false;
    var lines = std.mem.splitScalar(u8, old, '\n');
    while (lines.next()) |line| {
        if (lines.index == null and line.len == 0) break;
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (std.mem.startsWith(u8, trimmed, "[")) inside = std.mem.eql(u8, trimmed, "[webdav]");
        if (inside) continue;
        try out.appendSlice(a, line);
        try out.append(a, '\n');
    }
    try out.print(a, "[webdav]\nport = {d}\nuser = \"{s}\"\npassword_hash = \"{s}\"\n", .{ value.port, value.user, value.password_hash });
    try writeAtomic(a, io, path, out.items);
}

test "config: WebDAV scoped round trip preserves peer port and credentials during edits" {
    const a = testing.allocator;
    const io = std.testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "config", .data = "nickname = alpha\nswarm_key = " ++ "ab" ** 32 ++ "\nstorage_path = /tmp/a\nport = 14700\n" });
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = buf[0..try tmp.dir.realPath(io, &buf)];
    const path = try std.fs.path.join(a, &.{ dir, "config" });
    defer a.free(path);
    var hash_buf: [106]u8 = undefined;
    const hash = try @import("webdav/login.zig").hash(a, "password", &hash_buf);
    try setWebDav(a, path, .{ .port = 8080, .user = "reader", .password_hash = hash });
    try setInt(a, path, "port", 14701);
    try setNickname(a, path, "beta");
    var cfg = try config_mod.parseConfig(a, path);
    defer cfg.deinit(a);
    try testing.expectEqual(@as(u16, 14701), cfg.network.port);
    try testing.expectEqual(@as(u16, 8080), cfg.webdav.port);
    try testing.expectEqualStrings("reader", cfg.webdav.user);
    try testing.expectEqualStrings(hash, cfg.webdav.password_hash);
    try setWebDav(a, path, .{});
    var cleared = try config_mod.parseConfig(a, path);
    defer cleared.deinit(a);
    try testing.expect(!cleared.webdav.hasLogin());
    try testing.expectEqual(@as(u16, 0), cleared.webdav.port);
    try testing.expectEqual(@as(u16, 14701), cleared.network.port);
    try testing.expectError(error.InvalidWebDavHash, setWebDav(a, path, .{ .user = "reader", .password_hash = "plaintext" }));
}
