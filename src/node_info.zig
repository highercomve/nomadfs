//! What a device tells a trusted device about itself on request
//! (GET_NODE_INFO): its version and platform, how long it has run, the
//! space on the disk its store is on and what NomadFS uses there, its
//! connections, shares, swarm folder and backups. The app shows it as the
//! device's About, and judges its health from it.
//!
//! The encoding is a version byte, then fields in a fixed order; fields are
//! only ever appended, and a reader ignores what it doesn't know.

const std = @import("std");
const builtin = @import("builtin");
const sync = @import("sync.zig");

pub const format_version: u8 = 1;
/// Longest encoded info a reader accepts.
pub const max_len = 1024;
const max_text = 48;

pub const Info = struct {
    version: Text = .{},
    platform: Text = .{},
    uptime_s: u64 = 0,
    /// The filesystem the store is on; 0 when unknown.
    disk_total: u64 = 0,
    disk_free: u64 = 0,
    /// Blocks this device keeps (its writes, backups, replicas).
    kept_bytes: u64 = 0,
    kept_blocks: u64 = 0,
    /// The read cache and its limit (0: none).
    cache_bytes: u64 = 0,
    cache_limit: u64 = 0,
    /// Cap on kept blocks from other devices (0: none).
    quota: u64 = 0,
    /// Devices in the routing table and open connections.
    peers: u32 = 0,
    connections: u32 = 0,
    trusted: u32 = 0,
    shares: u32 = 0,
    /// Shares whose last scan failed, and ones still on their first scan.
    shares_failing: u32 = 0,
    shares_indexing: u32 = 0,
    swarm_files: u32 = 0,
    /// Unix seconds; 0 when it never synced.
    swarm_last_sync: u64 = 0,
    swarm_backup: bool = false,
    swarm_backed_up: u32 = 0,
    /// Swarm files no reachable device could serve in the last round.
    swarm_unreachable: u32 = 0,
    /// Folder backups kept here for other devices.
    held_backups: u32 = 0,
    /// On Wi-Fi or wired (phones); always true elsewhere.
    unmetered: bool = true,
    bytes_sent: u64 = 0,
    bytes_received: u64 = 0,

    pub const Text = struct {
        buf: [max_text]u8 = undefined,
        len: u8 = 0,

        pub fn init(s: []const u8) Text {
            var t: Text = .{};
            const n = @min(s.len, max_text);
            @memcpy(t.buf[0..n], s[0..n]);
            t.len = @intCast(n);
            return t;
        }

        pub fn slice(self: *const Text) []const u8 {
            return self.buf[0..self.len];
        }
    };
};

/// Caller-owned bytes.
pub fn encode(allocator: std.mem.Allocator, info: Info) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    const w = &out.writer;
    try w.writeByte(format_version);
    inline for (std.meta.fields(Info)) |f| {
        const v = @field(info, f.name);
        switch (f.type) {
            Info.Text => {
                try w.writeByte(v.len);
                try w.writeAll(v.slice());
            },
            u64, u32 => try w.writeInt(f.type, v, .big),
            bool => try w.writeByte(@intFromBool(v)),
            else => @compileError("node_info: no encoding for " ++ f.name),
        }
    }
    return out.toOwnedSlice();
}

/// Fields missing at the end (an older device) keep their defaults.
pub fn decode(bytes: []const u8) !Info {
    if (bytes.len == 0 or bytes.len > max_len) return error.InvalidNodeInfo;
    if (bytes[0] != format_version) return error.UnsupportedNodeInfo;
    var info: Info = .{};
    var pos: usize = 1;
    inline for (std.meta.fields(Info)) |f| {
        if (pos == bytes.len) return info;
        switch (f.type) {
            Info.Text => {
                const n = bytes[pos];
                pos += 1;
                if (n > max_text or bytes.len - pos < n) return error.InvalidNodeInfo;
                @field(info, f.name) = Info.Text.init(bytes[pos..][0..n]);
                pos += n;
            },
            u64, u32 => {
                const size = @sizeOf(f.type);
                if (bytes.len - pos < size) return error.InvalidNodeInfo;
                @field(info, f.name) = std.mem.readInt(f.type, bytes[pos..][0..size], .big);
                pos += size;
            },
            bool => {
                @field(info, f.name) = bytes[pos] != 0;
                pos += 1;
            },
            else => @compileError("node_info: no decoding for " ++ f.name),
        }
    }
    return info;
}

/// `linux x86_64`, `android aarch64`, `windows x86_64`.
pub fn platform() []const u8 {
    const os = if (builtin.abi.isAndroid()) "android" else @tagName(builtin.os.tag);
    return os ++ " " ++ @tagName(builtin.cpu.arch);
}

pub const Disk = struct { total: u64, free: u64 };

/// Size and free space (for this user) of the filesystem `path` is on, or
/// null where that isn't known (not Linux, or the call failed).
pub fn disk(path: []const u8) ?Disk {
    if (builtin.os.tag != .linux or @sizeOf(usize) != 8) return null;
    const linux = std.os.linux;
    var path_buf: [std.fs.max_path_bytes:0]u8 = undefined;
    if (path.len >= path_buf.len) return null;
    @memcpy(path_buf[0..path.len], path);
    path_buf[path.len] = 0;
    // struct statfs on 64-bit Linux (x86_64, aarch64).
    const Statfs = extern struct {
        f_type: i64,
        f_bsize: i64,
        f_blocks: u64,
        f_bfree: u64,
        f_bavail: u64,
        f_files: u64,
        f_ffree: u64,
        f_fsid: [2]i32,
        f_namelen: i64,
        f_frsize: i64,
        f_flags: i64,
        f_spare: [4]i64,
    };
    var st: Statfs = undefined;
    const rc = linux.syscall2(.statfs, @intFromPtr(&path_buf), @intFromPtr(&st));
    if (linux.errno(rc) != .SUCCESS) return null;
    const unit: u64 = @intCast(if (st.f_frsize > 0) st.f_frsize else @max(st.f_bsize, 0));
    return .{ .total = st.f_blocks *| unit, .free = st.f_bavail *| unit };
}

pub fn nowSeconds() u64 {
    return std.math.cast(u64, sync.timestamp()) orelse 0;
}

test "node info: round trip, and an older device's shorter info" {
    const a = std.testing.allocator;
    var info: Info = .{ .uptime_s = 42, .disk_total = 1 << 40, .disk_free = 1 << 30, .peers = 3, .swarm_backup = true, .held_backups = 2, .unmetered = false, .bytes_sent = 123456, .bytes_received = 654321 };
    info.version = Info.Text.init("0.2.5");
    info.platform = Info.Text.init(platform());
    const bytes = try encode(a, info);
    defer a.free(bytes);
    const got = try decode(bytes);
    try std.testing.expectEqualStrings("0.2.5", got.version.slice());
    try std.testing.expectEqual(info.disk_free, got.disk_free);
    try std.testing.expect(got.swarm_backup and !got.unmetered);
    try std.testing.expectEqual(@as(u32, 2), got.held_backups);
    try std.testing.expectEqual(@as(u64, 123456), got.bytes_sent);
    try std.testing.expectEqual(@as(u64, 654321), got.bytes_received);

    // Cut before the new traffic fields: an older device keeps defaults.
    const older_len = bytes.len - 16;
    const older = try decode(bytes[0..older_len]);
    try std.testing.expectEqual(info.disk_free, older.disk_free);
    try std.testing.expectEqual(@as(u64, 0), older.bytes_sent);
    try std.testing.expectEqual(@as(u64, 0), older.bytes_received);

    // Cut after uptime: the rest keeps its defaults.
    const short = try decode(bytes[0 .. 1 + 1 + 5 + 1 + got.platform.len + 8]);
    try std.testing.expectEqual(@as(u64, 42), short.uptime_s);
    try std.testing.expectEqual(@as(u64, 0), short.disk_total);
    try std.testing.expect(short.unmetered);

    // Junk is refused.
    try std.testing.expectError(error.InvalidNodeInfo, decode(&.{ format_version, 200 }));
    try std.testing.expectError(error.UnsupportedNodeInfo, decode(&.{9}));
}

test "node info: the disk of the working directory is known on Linux" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const d = disk(".") orelse return error.NoDiskInfo;
    try std.testing.expect(d.total > 0 and d.free <= d.total);
}
