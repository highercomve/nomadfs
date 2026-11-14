//! S3 settings and owner-only credentials; secrets are never config entries.
const std = @import("std");
const builtin = @import("builtin");
const env = @import("../env.zig");
/// S3 storage classes a target may ask for. Cold ones need a thaw to read.
pub const StorageClass = enum {
    STANDARD,
    STANDARD_IA,
    GLACIER_IR,
    GLACIER,
    DEEP_ARCHIVE,

    pub fn cold(self: StorageClass) bool {
        return self == .GLACIER or self == .DEEP_ARCHIVE;
    }
    /// Minimum storage duration: deleting a pack earlier is billed in full.
    pub fn minDays(self: StorageClass) u32 {
        return switch (self) {
            .GLACIER => 90,
            .DEEP_ARCHIVE => 180,
            else => 0,
        };
    }
};
/// How often the periodic uploader writes a new snapshot to the target.
pub const Schedule = enum {
    daily,
    weekly,
    monthly,

    pub fn seconds(self: Schedule) u64 {
        return switch (self) {
            .daily => 86400,
            .weekly => 7 * 86400,
            .monthly => 30 * 86400,
        };
    }
};
const text_fields = .{ "name", "endpoint", "region", "bucket", "prefix", "credentials" };
/// One `[backup.<name>]` target: a full copy with its own bucket and lease.
pub const Config = struct {
    name: []const u8 = "",
    endpoint: []const u8 = "",
    region: []const u8 = "",
    bucket: []const u8 = "",
    prefix: []const u8 = "",
    credentials: []const u8 = "",
    encrypt: bool = true,
    upload_limit_kbps: u32 = 0,
    pack_mb: u32 = 32,
    retain_daily: u32 = 30,
    retain_monthly: u32 = 0,
    storage_class: StorageClass = .STANDARD,
    schedule: Schedule = .daily,
    /// Keys written in the file: a cold class never overrides them.
    set_pack_mb: bool = false,
    set_retain_daily: bool = false,
    set_retain_monthly: bool = false,

    pub fn deinit(self: *Config, a: std.mem.Allocator) void {
        inline for (text_fields) |field| {
            if (@field(self, field).len > 0) a.free(@field(self, field));
            @field(self, field) = "";
        }
    }
    /// A deep copy owned by `a`.
    pub fn clone(self: Config, a: std.mem.Allocator) !Config {
        var copied = self;
        inline for (text_fields) |field| @field(copied, field) = "";
        errdefer copied.deinit(a);
        inline for (text_fields) |field| {
            if (@field(self, field).len > 0) @field(copied, field) = try a.dupe(u8, @field(self, field));
        }
        return copied;
    }
    pub fn configured(self: Config) bool {
        return self.endpoint.len > 0 and self.bucket.len > 0 and self.credentials.len > 0;
    }
    pub fn apply(self: *Config, a: std.mem.Allocator, key: []const u8, value: []const u8) !void {
        inline for (.{ "endpoint", "region", "bucket", "prefix", "credentials" }) |field| {
            if (std.mem.eql(u8, key, field)) {
                const owned = if (value.len > 0) try a.dupe(u8, value) else "";
                if (@field(self, field).len > 0) a.free(@field(self, field));
                @field(self, field) = owned;
                return;
            }
        }
        inline for (.{ "upload_limit_kbps", "pack_mb", "retain_daily", "retain_monthly" }) |field| {
            if (std.mem.eql(u8, key, field)) {
                const n = try std.fmt.parseInt(u32, value, 10);
                if (std.mem.eql(u8, field, "pack_mb") and (n == 0 or n > 512)) return error.InvalidPackSize;
                @field(self, field) = n;
                if (@hasField(Config, "set_" ++ field)) @field(self, "set_" ++ field) = true;
                return;
            }
        }
        if (std.mem.eql(u8, key, "encrypt")) {
            if (!std.mem.eql(u8, value, "true") and !std.mem.eql(u8, value, "false")) return error.InvalidBoolean;
            self.encrypt = std.mem.eql(u8, value, "true");
            return;
        }
        if (std.mem.eql(u8, key, "storage_class")) {
            self.storage_class = std.meta.stringToEnum(StorageClass, value) orelse return error.InvalidStorageClass;
            self.applyClassDefaults();
            return;
        }
        if (std.mem.eql(u8, key, "schedule")) {
            self.schedule = std.meta.stringToEnum(Schedule, value) orelse return error.InvalidSchedule;
            return;
        }
        return error.UnknownBackupSetting;
    }
    /// Cold targets: big packs (fewer thaw requests), monthly snapshots forever.
    fn applyClassDefaults(self: *Config) void {
        const cold = self.storage_class.cold();
        if (!self.set_pack_mb) self.pack_mb = if (cold) 256 else 32;
        if (!self.set_retain_daily) self.retain_daily = if (cold) 0 else 30;
        if (!self.set_retain_monthly) self.retain_monthly = 0;
    }
};
/// The target name of a `[backup.<name>]` section header, or null.
pub fn sectionName(header: []const u8) ?[]const u8 {
    const text = stripComment(header);
    if (!std.mem.startsWith(u8, text, "[backup.") or !std.mem.endsWith(u8, text, "]")) return null;
    const name = text["[backup.".len .. text.len - 1];
    if (name.len == 0 or name.len > 32) return null;
    for (name) |c| if (!std.ascii.isLower(c) and !std.ascii.isDigit(c) and c != '-' and c != '_') return null;
    return name;
}
pub const Credentials = struct {
    access_key_id: []const u8,
    secret_access_key: []const u8,
    pub fn deinit(self: *Credentials, a: std.mem.Allocator) void {
        std.crypto.secureZero(u8, @constCast(self.secret_access_key));
        a.free(self.secret_access_key);
        a.free(self.access_key_id);
    }
};
/// File format: access_key_id = "...", secret_access_key = "..." (one per line).
pub fn loadCredentials(a: std.mem.Allocator, io: std.Io, path: []const u8) !Credentials {
    const expanded = try env.expandHome(a, path);
    defer if (expanded) |p| a.free(p);
    const file = try std.Io.Dir.cwd().openFile(io, expanded orelse path, .{});
    defer file.close(io);
    const stat = try file.stat(io);
    if (builtin.os.tag == .windows) return error.CredentialsPermissionsUnsupported;
    if (@intFromEnum(stat.permissions) & 0o077 != 0) return error.InsecureCredentials;
    if (stat.size > 8192 or stat.kind != .file) return error.InvalidCredentials;
    var buf: [8192]u8 = undefined;
    defer std.crypto.secureZero(u8, &buf);
    const n = try file.readPositionalAll(io, &buf, 0);
    var id: ?[]const u8 = null;
    var secret: ?[]const u8 = null;
    var lines = std.mem.splitScalar(u8, buf[0..n], '\n');
    while (lines.next()) |line| {
        const text = std.mem.trim(u8, line, " \t\r");
        if (text.len == 0 or text[0] == '#') continue;
        const eq = std.mem.indexOfScalar(u8, text, '=') orelse return error.InvalidCredentials;
        const key = std.mem.trim(u8, text[0..eq], " \t");
        const val = std.mem.trim(u8, text[eq + 1 ..], " \t\"");
        if (std.mem.eql(u8, key, "access_key_id") and id == null) id = val else if (std.mem.eql(u8, key, "secret_access_key") and secret == null) secret = val else return error.InvalidCredentials;
    }
    if (id == null or secret == null or id.?.len == 0 or secret.?.len == 0) return error.InvalidCredentials;
    const owned = try a.dupe(u8, id.?);
    errdefer a.free(owned);
    return .{ .access_key_id = owned, .secret_access_key = try a.dupe(u8, secret.?) };
}

/// Removes TOML inline comments while preserving # inside quoted strings.
pub fn stripComment(value: []const u8) []const u8 {
    var quoted = false;
    var escaped = false;
    for (value, 0..) |c, i| {
        if (escaped) {
            escaped = false;
            continue;
        }
        if (c == '\\' and quoted) {
            escaped = true;
            continue;
        }
        if (c == '"') quoted = !quoted;
        if (c == '#' and !quoted) return std.mem.trim(u8, value[0..i], " \t\r");
    }
    return std.mem.trim(u8, value, " \t\r");
}

test "backup credentials: reject group or other access and load only private files" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "credentials", .data = "access_key_id = \"id\"\nsecret_access_key = \"secret\"\n", .flags = .{ .permissions = .fromMode(0o600) } });
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = buf[0..try tmp.dir.realPath(io, &buf)];
    const path = try std.fs.path.join(a, &.{ dir, "credentials" });
    defer a.free(path);
    var creds = try loadCredentials(a, io, path);
    defer creds.deinit(a);
    try std.testing.expectEqualStrings("id", creds.access_key_id);
    try std.testing.expectEqualStrings("secret", creds.secret_access_key);
    const file = try tmp.dir.openFile(io, "credentials", .{});
    defer file.close(io);
    for ([_]u32{ 0o640, 0o604, 0o644 }) |mode| {
        try file.setPermissions(io, .fromMode(mode));
        try std.testing.expectError(error.InsecureCredentials, loadCredentials(a, io, path));
    }
}
