//! Mounting the WebDAV server (webdav.zig) where the system's own tools
//! show it like a disk: macOS's mount_webdav into a folder, Windows's
//! `net use` on a drive letter (the WebClient service). Shared by the
//! command line (`nomadfs --mount`) and the app.

const std = @import("std");
const builtin = @import("builtin");

pub const supported = builtin.os.tag == .macos or builtin.os.tag == .windows;

/// Mounts `url` at `target`: a folder (macOS, created if missing) or a
/// drive letter like `Z:` (Windows; `*` takes the first free one).
/// Returns where it is mounted (caller frees).
pub fn mount(gpa: std.mem.Allocator, io: std.Io, url: []const u8, target: []const u8) ![]u8 {
    switch (builtin.os.tag) {
        .macos => {
            try std.Io.Dir.cwd().createDirPath(io, target);
            // -S: no dialogs (no credentials are asked); -v: the volume's name.
            try runOk(gpa, io, &.{ "/sbin/mount_webdav", "-S", "-v", "NomadFS", url, target });
            return gpa.dupe(u8, target);
        },
        .windows => {
            const out = try runOut(gpa, io, &.{ "net", "use", target, url, "/persistent:no" });
            defer gpa.free(out);
            if (!std.mem.eql(u8, target, "*")) return gpa.dupe(u8, target);
            // "Drive Z: is now connected to ..." (the letter, in any language).
            var i: usize = 0;
            while (i + 1 < out.len) : (i += 1) {
                if (out[i + 1] == ':' and std.ascii.isUpper(out[i]) and (i == 0 or out[i - 1] == ' ')) return gpa.dupe(u8, out[i .. i + 2]);
            }
            return error.MountFailed;
        },
        else => return error.Unsupported,
    }
}

/// Undoes `mount`. Errors only when the system refused.
pub fn unmount(gpa: std.mem.Allocator, io: std.Io, target: []const u8) !void {
    switch (builtin.os.tag) {
        .macos => try runOk(gpa, io, &.{ "/sbin/umount", target }),
        .windows => try runOk(gpa, io, &.{ "net", "use", target, "/delete", "/y" }),
        else => return error.Unsupported,
    }
}

fn runOk(gpa: std.mem.Allocator, io: std.Io, argv: []const []const u8) !void {
    gpa.free(try runOut(gpa, io, argv));
}

/// Runs `argv`; its output on success, error.MountFailed (its message
/// logged) otherwise.
fn runOut(gpa: std.mem.Allocator, io: std.Io, argv: []const []const u8) ![]u8 {
    const res = std.process.run(gpa, io, .{ .argv = argv, .stdout_limit = .limited(64 * 1024), .stderr_limit = .limited(64 * 1024) }) catch |err| {
        std.log.warn("{s}: {s}", .{ argv[0], @errorName(err) });
        return error.MountFailed;
    };
    defer gpa.free(res.stderr);
    const ok = switch (res.term) {
        .exited => |code| code == 0,
        else => false,
    };
    if (!ok) {
        std.log.warn("{s} failed: {s}{s}", .{ argv[0], std.mem.trim(u8, res.stderr, " \r\n"), std.mem.trim(u8, res.stdout, " \r\n") });
        gpa.free(res.stdout);
        return error.MountFailed;
    }
    return res.stdout;
}
