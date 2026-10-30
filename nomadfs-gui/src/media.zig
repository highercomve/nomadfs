//! Video and audio previews stream instead of downloading first: the page's
//! `<video>` asks for byte ranges as it plays and seeks, and each range is
//! read from the other device through the node's read-ahead. On the desktop
//! the ranges go through Oriel's media server on 127.0.0.1 (WebKitGTK only
//! plays http(s)); on Android through the WebView's request interception
//! (`oriel.media_scheme`).
//!
//! URLs: `<base><token>/<kind>/<device>/<cid>/<size>/f.<ext>`. `kind` is
//! `d` (a device's share; `device` is that device) or `s` (the swarm folder;
//! `device` is who added the file). The random token makes the URLs
//! unguessable to other programs on the machine; the extension gives the
//! MIME type.

const std = @import("std");
const builtin = @import("builtin");
const oriel = @import("oriel");
const nomadfs = @import("nomadfs");
const commands = @import("commands.zig");

const is_android = builtin.abi.isAndroid();
const gpa = std.heap.smp_allocator;

var g_mutex: nomadfs.sync.Mutex = .{};
var g_started = false;
var g_token: [32]u8 = undefined;
var g_base_buf: [64]u8 = undefined;
var g_base: []const u8 = "";
var g_server: if (is_android) void else oriel.media_server.Server = undefined;

// One type, re-exported by both (media_server doesn't exist on Android).
const Source = if (is_android) oriel.media_scheme.Source else oriel.media_server.Source;
const source: Source = .{ .ctx = undefined, .sizeFn = sizeOf, .readFn = readAt };

pub const UrlArgs = struct {
    /// "device" (a device's share) or "swarm" (the swarm folder).
    kind: []const u8,
    /// The device sharing the file, or (swarm) the one that added it, hex.
    id: []const u8,
    cid: []const u8,
    size: u64,
    name: []const u8,
};

/// `invoke("media_url", { kind, id, cid, size, name })`: a URL the page's
/// `<video>`/`<audio>` streams the file from.
pub fn url(alloc: std.mem.Allocator, args: UrlArgs) ![]const u8 {
    try ensureStarted();
    const k: u8 = if (std.mem.eql(u8, args.kind, "swarm")) 's' else if (std.mem.eql(u8, args.kind, "device")) 'd' else return error.InvalidArgument;
    if (!isHex64(args.id) or !isHex64(args.cid)) return error.InvalidArgument;
    // Only the extension matters (the MIME type); keep it to [a-z0-9].
    var ext_buf: [8]u8 = undefined;
    var ext_len: usize = 0;
    const dot = std.mem.lastIndexOfScalar(u8, args.name, '.');
    if (dot) |d| for (args.name[d + 1 ..]) |c| {
        if (ext_len == ext_buf.len) break;
        const lower = std.ascii.toLower(c);
        if (!std.ascii.isAlphanumeric(lower)) break;
        ext_buf[ext_len] = lower;
        ext_len += 1;
    };
    const ext = if (ext_len > 0) ext_buf[0..ext_len] else "bin";
    return std.fmt.allocPrint(alloc, "{s}{s}/{c}/{s}/{s}/{d}/f.{s}", .{ g_base, &g_token, k, args.id, args.cid, args.size, ext });
}

fn ensureStarted() !void {
    g_mutex.lock();
    defer g_mutex.unlock();
    if (g_started) return;
    const io = std.Io.Threaded.global_single_threaded.io();
    var raw: [16]u8 = undefined;
    try io.randomSecure(&raw);
    g_token = std.fmt.bytesToHex(raw, .lower);
    if (is_android) {
        try oriel.media_scheme.setSource(source);
        g_base = oriel.media_scheme.base_url;
    } else {
        // A free port: try a few random ones above the registered range.
        var attempt: usize = 0;
        while (true) : (attempt += 1) {
            var r: [2]u8 = undefined;
            io.random(&r);
            const port: u16 = 40000 + std.mem.readInt(u16, &r, .little) % 20000;
            g_server.start(io, gpa, .{ .root_dir = "", .port = port, .source = source }) catch |err| {
                if (attempt < 20) continue;
                return err;
            };
            g_base = try std.fmt.bufPrint(&g_base_buf, "http://127.0.0.1:{d}/", .{port});
            break;
        }
    }
    g_started = true;
}

const Target = struct { kind: u8, id: [32]u8, cid: [32]u8, size: u64 };

/// `<token>/<kind>/<id>/<cid>/<size>/<name>`; null for anything else.
fn parse(path: []const u8) ?Target {
    var it = std.mem.splitScalar(u8, path, '/');
    const token = it.next() orelse return null;
    if (!g_started or token.len != g_token.len) return null;
    if (!std.crypto.timing_safe.eql([32]u8, token[0..32].*, g_token)) return null;
    const kind = it.next() orelse return null;
    if (kind.len != 1 or (kind[0] != 'd' and kind[0] != 's')) return null;
    var out: Target = .{ .kind = kind[0], .id = undefined, .cid = undefined, .size = 0 };
    const id = it.next() orelse return null;
    const cid = it.next() orelse return null;
    _ = std.fmt.hexToBytes(&out.id, id) catch return null;
    _ = std.fmt.hexToBytes(&out.cid, cid) catch return null;
    if (id.len != 64 or cid.len != 64) return null;
    out.size = std.fmt.parseInt(u64, it.next() orelse return null, 10) catch return null;
    return out;
}

fn sizeOf(_: *anyopaque, path: []const u8) ?u64 {
    const t = parse(path) orelse return null;
    return t.size;
}

fn readAt(_: *anyopaque, path: []const u8, offset: u64, dest: []u8) anyerror!usize {
    const t = parse(path) orelse return error.FileNotFound;
    if (offset >= t.size) return 0;
    const want = dest[0..@intCast(@min(dest.len, t.size - offset))];
    const handle = commands.mediaAcquire() orelse return error.NotRunning;
    defer commands.mediaRelease();
    const file: nomadfs.Node.FileSource = if (t.kind == 's')
        .{ .swarm = .{ .cid = t.cid, .author = t.id } }
    else
        .{ .share = .{ .peer = .{ .bytes = t.id }, .cid = t.cid } };
    return handle.node.readFile(gpa, file, offset, want);
}

fn isHex64(s: []const u8) bool {
    if (s.len != 64) return false;
    for (s) |c| if (!std.ascii.isHex(c)) return false;
    return true;
}
