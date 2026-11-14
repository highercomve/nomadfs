//! A frame of a film as a small JPEG, taken by ffmpeg: the one codec that
//! is another program. It is looked for once: the path the user set, then
//! `ffmpeg` on PATH, then the copies media servers bring with them (on a
//! home server that is often the only one). Never on Android: an app
//! there has no ffmpeg to run.
//!
//! ffmpeg reads the film itself, from a URL or a path, and seeks in it: a
//! phone's films keep their index at the end, so nothing here could feed
//! it a stream. Where the film is and how it is served is the caller's
//! business.

const std = @import("std");
const builtin = @import("builtin");

/// The most bytes a frame may be: ffmpeg's output is cut off there.
pub const max_frame_len = 256 * 1024;
/// How long a frame may take before ffmpeg is killed.
pub const default_timeout_ms: u32 = 20_000;
/// How long a candidate has to answer `-version`.
const probe_timeout_ms: u32 = 5_000;
/// What ffmpeg may say on stderr before it is taken for failed.
const max_stderr_len = 64 * 1024;
const max_path = std.fs.max_path_bytes;

const exe_name = if (builtin.os.tag == .windows) "ffmpeg.exe" else "ffmpeg";

/// Copies that run on their own, where no `ffmpeg` is on PATH. Emby's is
/// a script that sets the library path and runs its ffmpeg.
const bundled = [_][]const u8{
    "/opt/emby-server/bin/emby-ffmpeg",
    "/usr/lib/jellyfin-ffmpeg/ffmpeg",
    "/usr/share/jellyfin-ffmpeg/ffmpeg",
};

pub const FrameError = error{
    OutOfMemory,
    /// No ffmpeg on this device.
    NoTool,
    /// ffmpeg was killed: it took longer than the caller gave it.
    Timeout,
};

/// The ffmpeg found, looked for once per process (and again after
/// `configure`).
var tool: struct {
    /// Guards the fields below; held while candidates are tried, so the
    /// first callers wait for one search.
    mutex: std.Io.Mutex = .init,
    state: enum { unknown, none, found } = .unknown,
    configured: [max_path]u8 = undefined,
    configured_len: usize = 0,
    path: [max_path]u8 = undefined,
    path_len: usize = 0,
} = .{};

/// The path the user set for ffmpeg ("": look for it). Tried first; the
/// next `available` or `frame` looks again.
pub fn configure(path: []const u8) void {
    std.Io.Threaded.mutexLock(&tool.mutex);
    defer std.Io.Threaded.mutexUnlock(&tool.mutex);
    const n = if (path.len <= max_path) path.len else 0; // no path is that long
    @memcpy(tool.configured[0..n], path[0..n]);
    tool.configured_len = n;
    tool.state = .unknown;
}

/// Whether this device can take a frame of a film. The first call looks
/// for ffmpeg (each candidate gets 5 seconds to answer); later ones only
/// read what it found.
pub fn available() bool {
    var buf: [max_path]u8 = undefined;
    return toolPath(&buf) != null;
}

/// The ffmpeg to run, copied into `buf`; null when there is none.
fn toolPath(buf: *[max_path]u8) ?[]const u8 {
    if (builtin.abi.isAndroid()) return null;
    std.Io.Threaded.mutexLock(&tool.mutex);
    defer std.Io.Threaded.mutexUnlock(&tool.mutex);
    if (tool.state == .unknown) search();
    if (tool.state != .found) return null;
    @memcpy(buf[0..tool.path_len], tool.path[0..tool.path_len]);
    return buf[0..tool.path_len];
}

/// Tries the candidates in order and keeps the first that runs. Caller
/// holds `tool.mutex`.
fn search() void {
    tool.state = .none;
    var candidates: [2 + bundled.len][]const u8 = undefined;
    var n: usize = 0;
    if (tool.configured_len > 0) {
        candidates[n] = tool.configured[0..tool.configured_len];
        n += 1;
    }
    candidates[n] = exe_name;
    n += 1;
    if (builtin.os.tag == .linux) for (bundled) |path| {
        candidates[n] = path;
        n += 1;
    };
    for (candidates[0..n]) |candidate| {
        if (!runs(candidate)) continue;
        @memcpy(tool.path[0..candidate.len], candidate); // <= max_path: ours, or checked by configure
        tool.path_len = candidate.len;
        tool.state = .found;
        return;
    }
}

/// Whether `candidate -hide_banner -version` exits 0 in time.
fn runs(candidate: []const u8) bool {
    const gpa = std.heap.smp_allocator;
    var threaded = std.Io.Threaded.init(gpa, .{ .environ = processEnviron() });
    defer threaded.deinit();
    const io = threaded.io();
    const res = std.process.run(gpa, io, .{
        .argv = &.{ candidate, "-hide_banner", "-version" },
        .stdout_limit = .limited(max_stderr_len),
        .stderr_limit = .limited(max_stderr_len),
        .timeout = deadline(io, probe_timeout_ms),
    }) catch return false; // not there, not a program, too slow: not this one
    gpa.free(res.stdout);
    gpa.free(res.stderr);
    return exitedOk(res.term);
}

/// A frame from about the first second of the film at `input` (a URL or a
/// path ffmpeg can seek in), as a JPEG whose long edge is `max_edge`
/// pixels at most: caller-owned. Null when ffmpeg makes no picture of it
/// (not a film, damaged, a codec it lacks). ffmpeg is killed after
/// `timeout_ms` (error.Timeout).
pub fn frame(allocator: std.mem.Allocator, input: []const u8, max_edge: u32, timeout_ms: u32) FrameError!?[]u8 {
    var buf: [max_path]u8 = undefined;
    const path = toolPath(&buf) orelse return error.NoTool;
    return frameWith(allocator, path, input, max_edge, timeout_ms);
}

/// `frame`, by the ffmpeg at `tool_path`.
fn frameWith(allocator: std.mem.Allocator, tool_path: []const u8, input: []const u8, max_edge: u32, timeout_ms: u32) FrameError!?[]u8 {
    // Spawning needs an Io with an allocator and the environment (PATH,
    // the library path): the caller's may have neither.
    var threaded = std.Io.Threaded.init(allocator, .{ .environ = processEnviron() });
    defer threaded.deinit();
    const io = threaded.io();
    // One deadline for both tries.
    const until = deadline(io, timeout_ms);
    var scale_buf: [96]u8 = undefined;
    const scale = std.fmt.bufPrint(&scale_buf, "scale=w={d}:h={d}:force_original_aspect_ratio=decrease", .{ max_edge, max_edge }) catch unreachable; // two u32 fit
    // A second in: past the black a film may fade in from. A clip shorter
    // than that has no frame there, and gives its first.
    for ([_][]const u8{ "1", "0" }) |seek| {
        if (try frameAt(allocator, io, tool_path, input, seek, scale, until)) |jpeg| return jpeg;
    }
    return null;
}

fn frameAt(allocator: std.mem.Allocator, io: std.Io, tool_path: []const u8, input: []const u8, seek: []const u8, scale: []const u8, until: std.Io.Timeout) FrameError!?[]u8 {
    const res = std.process.run(allocator, io, .{
        .argv = &.{ tool_path, "-nostdin", "-v", "error", "-ss", seek, "-i", input, "-frames:v", "1", "-vf", scale, "-q:v", "5", "-f", "mjpeg", "pipe:1" },
        .stdout_limit = .limited(max_frame_len),
        .stderr_limit = .limited(max_stderr_len),
        .timeout = until,
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Timeout => return error.Timeout,
        // It did not start, or wrote more than a frame is: no picture.
        else => return null,
    };
    defer allocator.free(res.stderr);
    if (exitedOk(res.term) and isJpeg(res.stdout)) return res.stdout;
    allocator.free(res.stdout);
    return null;
}

/// Whether `bytes` start and end as a JPEG does.
fn isJpeg(bytes: []const u8) bool {
    return bytes.len >= 4 and bytes[0] == 0xFF and bytes[1] == 0xD8 and bytes[bytes.len - 2] == 0xFF and bytes[bytes.len - 1] == 0xD9;
}

fn exitedOk(term: std.process.Child.Term) bool {
    return switch (term) {
        .exited => |code| code == 0,
        else => false,
    };
}

/// `ms` from now, whatever the process does meanwhile.
fn deadline(io: std.Io, ms: u32) std.Io.Timeout {
    const timeout: std.Io.Timeout = .{ .duration = .{ .raw = .fromMilliseconds(ms), .clock = .awake } };
    return timeout.toDeadline(io);
}

/// The environment ffmpeg runs in: this process's.
fn processEnviron() std.process.Environ {
    return switch (builtin.os.tag) {
        .windows => .{ .block = .global },
        else => if (builtin.link_libc) .{ .block = .{ .slice = std.mem.span(std.c.environ) } } else .empty,
    };
}

/// Helpers for the tests of the layers above.
pub const testing = struct {
    /// A film made by ffmpeg's test source: `seconds` long, 640x360, as
    /// `name` in `dir`. Its path, caller-owned. error.SkipZigTest without
    /// ffmpeg.
    pub fn clip(allocator: std.mem.Allocator, dir: std.Io.Dir, name: []const u8, seconds: []const u8) ![]u8 {
        var buf: [max_path]u8 = undefined;
        const ffmpeg = toolPath(&buf) orelse return error.SkipZigTest;
        var dir_buf: [max_path]u8 = undefined;
        const dir_path = dir_buf[0..try dir.realPath(std.testing.io, &dir_buf)];
        const out = try std.fs.path.join(allocator, &.{ dir_path, name });
        errdefer allocator.free(out);
        const source = try std.fmt.allocPrint(allocator, "testsrc=duration={s}:size=640x360:rate=10", .{seconds});
        defer allocator.free(source);
        var threaded = std.Io.Threaded.init(allocator, .{ .environ = processEnviron() });
        defer threaded.deinit();
        const res = try std.process.run(allocator, threaded.io(), .{
            .argv = &.{ ffmpeg, "-nostdin", "-v", "error", "-y", "-f", "lavfi", "-i", source, "-pix_fmt", "yuv420p", out },
            .stdout_limit = .limited(max_stderr_len),
            .stderr_limit = .limited(max_stderr_len),
            .timeout = deadline(threaded.io(), 30_000),
        });
        defer allocator.free(res.stdout);
        defer allocator.free(res.stderr);
        // An ffmpeg built without an MP4 encoder: nothing to test with.
        if (!exitedOk(res.term)) return error.SkipZigTest;
        return out;
    }
};

/// The width and height a JPEG's frame header gives.
fn jpegDims(jpeg: []const u8) ?[2]u32 {
    var at: usize = 2;
    while (at + 9 <= jpeg.len) {
        if (jpeg[at] != 0xFF) return null;
        const marker = jpeg[at + 1];
        const len = std.mem.readInt(u16, jpeg[at + 2 ..][0..2], .big);
        // SOF0..SOF15, but not the tables that share the range.
        if (marker >= 0xC0 and marker <= 0xCF and marker != 0xC4 and marker != 0xC8 and marker != 0xCC) {
            return .{ std.mem.readInt(u16, jpeg[at + 7 ..][0..2], .big), std.mem.readInt(u16, jpeg[at + 5 ..][0..2], .big) };
        }
        at += 2 + @as(usize, len);
    }
    return null;
}

test "video: a frame of a film is a JPEG no larger than asked for" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try testing.clip(allocator, tmp.dir, "two.mp4", "2");
    defer allocator.free(path);
    try std.testing.expect(available());

    const jpeg = (try frame(allocator, path, 320, default_timeout_ms)).?;
    defer allocator.free(jpeg);
    try std.testing.expect(isJpeg(jpeg));
    try std.testing.expect(jpeg.len <= max_frame_len);
    const dims = jpegDims(jpeg).?;
    try std.testing.expectEqual(@as(u32, 320), dims[0]);
    try std.testing.expectEqual(@as(u32, 180), dims[1]);

    // Smaller when asked.
    const small = (try frame(allocator, path, 160, default_timeout_ms)).?;
    defer allocator.free(small);
    try std.testing.expectEqual(@as(u32, 160), jpegDims(small).?[0]);
}

test "video: a clip shorter than a second gives its first frame" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try testing.clip(allocator, tmp.dir, "half.mp4", "0.5");
    defer allocator.free(path);
    const jpeg = (try frame(allocator, path, 320, default_timeout_ms)).?;
    defer allocator.free(jpeg);
    try std.testing.expect(jpegDims(jpeg).?[0] <= 320);
}

test "video: what is no film gives no frame" {
    const allocator = std.testing.allocator;
    if (!available()) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "text.mp4", .data = "this is no film at all" });
    var buf: [max_path]u8 = undefined;
    const dir = buf[0..try tmp.dir.realPath(std.testing.io, &buf)];
    const path = try std.fs.path.join(allocator, &.{ dir, "text.mp4" });
    defer allocator.free(path);
    try std.testing.expect(try frame(allocator, path, 320, default_timeout_ms) == null);
    const missing = try std.fs.path.join(allocator, &.{ dir, "nothing.mp4" });
    defer allocator.free(missing);
    try std.testing.expect(try frame(allocator, missing, 320, default_timeout_ms) == null);
}

test "video: an ffmpeg that hangs is killed at the timeout, one that is not there gives nothing" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "slow", .data = "#!/bin/sh\nexec sleep 30\n" });
    var buf: [max_path]u8 = undefined;
    const dir = buf[0..try tmp.dir.realPath(std.testing.io, &buf)];
    const slow = try std.fs.path.join(allocator, &.{ dir, "slow" });
    defer allocator.free(slow);
    var file = try tmp.dir.openFile(std.testing.io, "slow", .{});
    try file.setPermissions(std.testing.io, .fromMode(0o755));
    file.close(std.testing.io);

    const started = std.Io.Timestamp.now(std.testing.io, .awake);
    try std.testing.expectError(error.Timeout, frameWith(allocator, slow, "film.mp4", 320, 300));
    const took = started.durationTo(std.Io.Timestamp.now(std.testing.io, .awake));
    try std.testing.expect(took.toMilliseconds() < 10_000);

    const absent = try std.fs.path.join(allocator, &.{ dir, "no-ffmpeg" });
    defer allocator.free(absent);
    try std.testing.expect(try frameWith(allocator, absent, "film.mp4", 320, 1_000) == null);
    try std.testing.expect(!runs(absent));
}

test isJpeg {
    try std.testing.expect(isJpeg("\xFF\xD8\xFF\xE0 and the rest \xFF\xD9"));
    try std.testing.expect(!isJpeg("\xFF\xD8\xFF\xE0 cut off"));
    try std.testing.expect(!isJpeg("\xFF\xD9"));
    try std.testing.expect(!isJpeg(""));
}
