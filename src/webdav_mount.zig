//! The mount where there is no FUSE: the node's WebDAV server
//! (webdav.zig), mounted where the system's own tools show it like a disk:
//! macOS's mount_webdav into a folder, Windows's `net use` on a drive
//! letter (the WebClient service). The command line (`nomadfs --mount`)
//! and the app start and stop it the same way (Node.startWebDav).

const std = @import("std");
const builtin = @import("builtin");
const webdav = @import("webdav.zig");

/// A running server, mounted or not. `stop` unmounts, then stops it.
pub const Mount = struct {
    allocator: std.mem.Allocator,
    server: *webdav.Server,
    /// Where it is mounted (owned), or null when only served.
    at: ?[]u8 = null,
    url_buf: [96]u8 = undefined,
    url_len: usize = 0,

    pub fn url(self: *const Mount) []const u8 {
        return self.url_buf[0..self.url_len];
    }

    /// Unmounts (if mounted), stops the server and frees everything,
    /// `self` included.
    pub fn stop(self: *Mount) void {
        if (self.at) |at| {
            unmount(self.allocator, at) catch {};
            self.allocator.free(at);
        }
        self.server.deinit();
        self.allocator.destroy(self.server);
        self.allocator.destroy(self);
    }
};

/// Takes a started `server`; mounts it at `target` when given. On error
/// the server is stopped and freed.
pub fn start(allocator: std.mem.Allocator, server: *webdav.Server, target: ?[]const u8) !*Mount {
    errdefer {
        server.deinit();
        allocator.destroy(server);
    }
    const self = try allocator.create(Mount);
    errdefer allocator.destroy(self);
    self.* = .{ .allocator = allocator, .server = server };
    self.url_len = (try server.url(&self.url_buf)).len;
    if (target) |t| self.at = try mount(allocator, std.Io.Threaded.global_single_threaded.io(), self.url(), t);
    return self;
}

pub const supported = builtin.os.tag == .macos or builtin.os.tag == .windows;

/// Mounts `url` at `target`: a folder (macOS, created if missing) or a
/// drive letter like `Z:` (Windows; `*` takes the first free one).
/// Returns where it is mounted (caller frees).
pub fn mount(gpa: std.mem.Allocator, io: std.Io, url: []const u8, target: []const u8) ![]u8 {
    switch (builtin.os.tag) {
        .macos => {
            try std.Io.Dir.cwd().createDirPath(io, target);
            // -S: no dialogs (no credentials are asked); -v: the volume's name.
            try runOk(gpa, &.{ "/sbin/mount_webdav", "-S", "-v", "NomadFS", url, target });
            return gpa.dupe(u8, target);
        },
        .windows => {
            const out = try runOut(gpa, &.{ "net", "use", target, url, "/persistent:no" });
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
pub fn unmount(gpa: std.mem.Allocator, target: []const u8) !void {
    switch (builtin.os.tag) {
        // A volume Finder still has open needs forcing.
        .macos => runOk(gpa, &.{ "/sbin/umount", target }) catch try runOk(gpa, &.{ "/sbin/umount", "-f", target }),
        .windows => try runOk(gpa, &.{ "net", "use", target, "/delete", "/y" }),
        else => return error.Unsupported,
    }
}

/// Unmounts `target` (macOS) with the unmount system call alone, forced:
/// safe in a signal handler, for a process about to end that would
/// otherwise leave a volume with no server behind.
pub fn forceUnmount(target: [*:0]const u8) void {
    if (builtin.os.tag != .macos) return;
    const mnt_force = 0x00080000;
    _ = darwin.unmount(target, mnt_force);
}

const darwin = struct {
    extern "c" fn unmount(dir: [*:0]const u8, flags: c_int) c_int;
};

fn runOk(gpa: std.mem.Allocator, argv: []const []const u8) !void {
    gpa.free(try runOut(gpa, argv));
}

/// Runs `argv`; its output on success, error.MountFailed (its message
/// logged) otherwise.
fn runOut(gpa: std.mem.Allocator, argv: []const []const u8) ![]u8 {
    // Spawning allocates through the Io's own allocator, and the child
    // gets its environment: the global single-threaded Io has neither.
    var threaded = std.Io.Threaded.init(gpa, .{ .environ = processEnviron() });
    defer threaded.deinit();
    const res = std.process.run(gpa, threaded.io(), .{ .argv = argv, .stdout_limit = .limited(64 * 1024), .stderr_limit = .limited(64 * 1024) }) catch |err| {
        std.debug.print("{s}: {s}\n", .{ argv[0], @errorName(err) });
        return error.MountFailed;
    };
    defer gpa.free(res.stderr);
    const ok = switch (res.term) {
        .exited => |code| code == 0,
        else => false,
    };
    if (!ok) {
        std.debug.print("{s} failed ({any}): {s} {s}\n", .{ argv[0], res.term, std.mem.trim(u8, res.stderr, " \r\n"), std.mem.trim(u8, res.stdout, " \r\n") });
        gpa.free(res.stdout);
        return error.MountFailed;
    }
    return res.stdout;
}

fn processEnviron() std.process.Environ {
    return switch (builtin.os.tag) {
        .windows => .{ .block = .global },
        .macos => .{ .block = .{ .slice = std.mem.span(std.c.environ) } },
        else => .empty,
    };
}
