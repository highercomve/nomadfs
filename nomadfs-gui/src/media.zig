//! Video and audio previews stream instead of downloading first: the page's
//! `<video>` asks for byte ranges as it plays and seeks, and each range is
//! read from the other device through the node's read-ahead. On the desktop
//! the ranges go through Oriel's media server on 127.0.0.1 (WebKitGTK only
//! plays http(s)); on Android through the WebView's request interception
//! (`oriel.media_scheme`).
//!
//! URLs: `<base><token>/<kind>/<device>/<cid>/<size>/f.<ext>`. `kind` is
//! `d` (a device's share; `device` is that device) or `s` (the swarm folder;
//! `device` is who added the file). A finished download plays from its saved
//! file instead: `<base><token>/l/<download id>/<size>/f.<ext>`. The random token makes the URLs
//! unguessable to other programs on the machine; the extension gives the
//! MIME type.

const std = @import("std");
const builtin = @import("builtin");
const oriel = @import("oriel");
const nomadfs = @import("nomadfs");
const commands = @import("commands.zig");
const downloads = @import("downloads.zig");

const is_android = builtin.abi.isAndroid();
const gpa = std.heap.smp_allocator;

var g_mutex: nomadfs.sync.Mutex = .{};
var g_started = false;
var g_token: [32]u8 = undefined;
var g_base_buf: [64]u8 = undefined;
var g_base: []const u8 = "";
var g_server: oriel.media_server.Server = undefined;
/// The HTTP server's base (`http://127.0.0.1:<port>/`), once it runs: on
/// the desktop from the start; on Android when another app needs a URL
/// (the scheme serves only this app's WebView).
var g_http_base_buf: [64]u8 = undefined;
var g_http_base: []const u8 = "";
var g_network_server: oriel.media_server.Server = undefined;
var g_network_started = false;
var g_network_port: u16 = 0;

// One type, re-exported by both (media_server doesn't exist on Android).
const Source = if (is_android) oriel.media_scheme.Source else oriel.media_server.Source;
const source: Source = .{ .ctx = undefined, .sizeFn = sizeOf, .readFn = readAt };

pub const UrlArgs = struct {
    /// "device" (a device's share), "swarm" (the swarm folder) or
    /// "download" (a finished download's saved file).
    kind: []const u8,
    /// The device sharing the file, or (swarm) the one that added it, hex;
    /// a download's id.
    id: []const u8,
    cid: []const u8 = "",
    size: u64,
    name: []const u8,
    /// For another app (VLC, ...): an http://127.0.0.1 URL on every
    /// platform, not the WebView-only scheme Android previews use.
    external: bool = false,
    /// "lan" or "tailscale": make a URL for another device on that network.
    network: []const u8 = "",
};

/// `invoke("media_url", { kind, id, cid, size, name })`: a URL the page's
/// `<video>`/`<audio>` streams the file from.
pub fn url(alloc: std.mem.Allocator, args: UrlArgs) ![]const u8 {
    try ensureStarted();
    const k: u8 = if (std.mem.eql(u8, args.kind, "swarm")) 's' else if (std.mem.eql(u8, args.kind, "device")) 'd' else if (std.mem.eql(u8, args.kind, "download")) 'l' else return error.InvalidArgument;
    if (k == 'l') {
        _ = std.fmt.parseInt(u32, args.id, 10) catch return error.InvalidArgument;
    } else if (!isHex64(args.id) or !isHex64(args.cid)) return error.InvalidArgument;
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
    var network_base_buf: [64]u8 = undefined;
    const base = if (std.mem.eql(u8, args.network, "lan"))
        try networkBase(&network_base_buf, .lan)
    else if (std.mem.eql(u8, args.network, "tailscale"))
        try networkBase(&network_base_buf, .tailscale)
    else if (args.network.len > 0)
        return error.InvalidArgument
    else if (args.external)
        try httpBase()
    else
        g_base;
    if (k == 'l') return std.fmt.allocPrint(alloc, "{s}{s}/l/{s}/{d}/f.{s}", .{ base, &g_token, args.id, args.size, ext });
    return std.fmt.allocPrint(alloc, "{s}{s}/{c}/{s}/{s}/{d}/f.{s}", .{ base, &g_token, k, args.id, args.cid, args.size, ext });
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
        try startHttpLocked(io);
        g_base = g_http_base;
    }
    g_started = true;
}

/// The HTTP server's base, starting it if it isn't running (Android).
fn httpBase() ![]const u8 {
    g_mutex.lock();
    defer g_mutex.unlock();
    if (g_http_base.len == 0) try startHttpLocked(std.Io.Threaded.global_single_threaded.io());
    return g_http_base;
}

const Network = enum { lan, tailscale };

/// Starts an all-interface listener only when a network link is requested,
/// then returns this device's address on the selected network.
fn networkBase(buf: *[64]u8, network: Network) ![]const u8 {
    g_mutex.lock();
    defer g_mutex.unlock();
    if (!g_network_started) {
        const io = std.Io.Threaded.global_single_threaded.io();
        var attempt: usize = 0;
        while (attempt < 20) : (attempt += 1) {
            var random: [2]u8 = undefined;
            io.random(&random);
            const port: u16 = 40000 + std.mem.readInt(u16, &random, .little) % 20000;
            g_network_server.start(io, gpa, .{
                .root_dir = "",
                .port = port,
                .source = source,
                .network_accessible = true,
            }) catch continue;
            g_network_port = port;
            g_network_started = true;
            break;
        }
        if (!g_network_started) return error.AddressInUse;
    }

    var ip_buf: [16]u8 = undefined;
    const ip = switch (network) {
        .lan => nomadfs.device.invite.lanAddress(&ip_buf) orelse return error.NoLanAddress,
        .tailscale => tailscaleAddress(&ip_buf, g_network_port) orelse return error.NoTailscaleAddress,
    };
    return std.fmt.bufPrint(buf, "http://{s}:{d}/", .{ ip, g_network_port });
}

fn tailscaleAddress(buf: *[16]u8, port: u16) ?[]const u8 {
    var addresses: [8]nomadfs.net.compat.Address = undefined;
    const count = nomadfs.net.local_addrs.list(&addresses, port);
    for (addresses[0..count]) |address| switch (address.ip) {
        .ip4 => |ip| if (ip.bytes[0] == 100 and ip.bytes[1] >= 64 and ip.bytes[1] < 128)
            return std.fmt.bufPrint(buf, "{d}.{d}.{d}.{d}", .{ ip.bytes[0], ip.bytes[1], ip.bytes[2], ip.bytes[3] }) catch null,
        .ip6 => {},
    };
    return null;
}

/// Starts the HTTP server on 127.0.0.1, on a free port: a few random ones
/// above the registered range. Caller holds g_mutex.
fn startHttpLocked(io: std.Io) !void {
    var attempt: usize = 0;
    while (true) : (attempt += 1) {
        var r: [2]u8 = undefined;
        io.random(&r);
        const port: u16 = 40000 + std.mem.readInt(u16, &r, .little) % 20000;
        g_server.start(io, gpa, .{ .root_dir = "", .port = port, .source = source }) catch |err| {
            if (attempt < 20) continue;
            return err;
        };
        g_http_base = try std.fmt.bufPrint(&g_http_base_buf, "http://127.0.0.1:{d}/", .{port});
        return;
    }
}

const Target = struct { kind: u8, id: [32]u8, cid: [32]u8, size: u64, download: u32 = 0 };

/// `<token>/<kind>/<id>/<cid>/<size>/<name>`, or `<token>/l/<download
/// id>/<size>/<name>`; null for anything else.
fn parse(path: []const u8) ?Target {
    var it = std.mem.splitScalar(u8, path, '/');
    const token = it.next() orelse return null;
    if (!g_started or token.len != g_token.len) return null;
    if (!std.crypto.timing_safe.eql([32]u8, token[0..32].*, g_token)) return null;
    const kind = it.next() orelse return null;
    if (kind.len != 1 or (kind[0] != 'd' and kind[0] != 's' and kind[0] != 'l')) return null;
    var out: Target = .{ .kind = kind[0], .id = undefined, .cid = undefined, .size = 0 };
    if (kind[0] == 'l') {
        out.download = std.fmt.parseInt(u32, it.next() orelse return null, 10) catch return null;
        out.size = std.fmt.parseInt(u64, it.next() orelse return null, 10) catch return null;
        return out;
    }
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
    if (t.kind == 'l') return downloads.readSaved(t.download, offset, want);
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
