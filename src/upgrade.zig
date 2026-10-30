//! `nomadfs --upgrade`: replaces this binary with the latest release's.
//!
//! Each release signs the command line binaries into `latest-cli.json`
//! (scripts/release.sh), with the key that signs the app's `latest.json`.
//! Oriel's updater engine fetches it, checks the Ed25519 signature and the
//! download's SHA-256, and swaps the binary atomically; a running node
//! keeps the old one until it restarts.

const std = @import("std");
const core = @import("oriel_updater");
const node_info = @import("nomadfs").node_info;

const manifest_url = "https://github.com/highercomve/nomadfs/releases/latest/download/latest-cli.json";
/// The public half of the release key; the app carries the same one
/// (update_public_key in nomadfs-gui/build.zig).
const public_key = "fVWa5YivLO9rnCOY27zfM7wBASax5JcA/ZnwAImSSB8=";
const app_id = "com.foreachdeveloper.nomadfs.cli";

pub const Options = struct {
    /// Only say whether there is a newer release.
    check: bool = false,
    /// Don't ask before installing.
    yes: bool = false,
};

/// Returns the process exit code.
pub fn run(io: std.Io, gpa: std.mem.Allocator, options: Options) !u8 {
    core.backend.cleanupStale(io, gpa);
    const current = node_info.version;
    var maybe = core.checkForUpdate(io, gpa, .{
        .app_id = app_id,
        .manifest_url = manifest_url,
        .current_version = current,
        .public_key_b64 = public_key,
    }) catch |err| {
        std.debug.print("Error: could not check for an update: {s}\n", .{@errorName(err)});
        if (err == error.BadHttpStatus)
            std.debug.print("The latest release may predate command line updates (no latest-cli.json).\n", .{});
        return 1;
    };
    var update = maybe orelse {
        std.debug.print("nomadfs {s} is the latest release\n", .{current});
        return 0;
    };
    maybe = null;
    defer update.deinit();

    if (options.check) {
        std.debug.print("nomadfs {s} is available (this is {s}); install it with nomadfs --upgrade\n", .{ update.version, current });
        return 0;
    }
    if (!options.yes and !try confirm(io, current, update.version)) return 0;

    std.debug.print("Downloading nomadfs {s} ({d} MB)...\n", .{ update.version, update.size / (1024 * 1024) });
    const path = core.download(io, gpa, update, .{}) catch |err| {
        std.debug.print("Error: could not install the update: {s}\n", .{@errorName(err)});
        const name = @errorName(err);
        if (std.mem.eql(u8, name, "AccessDenied") or std.mem.eql(u8, name, "PermissionDenied"))
            std.debug.print("The binary's folder isn't writable by this user: run it with sudo.\n", .{});
        return 1;
    };
    defer gpa.free(path);
    std.debug.print("Updated nomadfs {s} -> {s} at {s}\nRestart a running node to use it (systemctl restart nomadfs, or systemctl --user ...).\n", .{ current, update.version, path });
    return 0;
}

/// Asks on the terminal; without one, --yes is required.
fn confirm(io: std.Io, current: []const u8, next: []const u8) !bool {
    const stdin = std.Io.File.stdin();
    if (!(stdin.isTty(io) catch false)) {
        std.debug.print("Error: not a terminal; add --yes to install nomadfs {s}\n", .{next});
        return false;
    }
    std.debug.print("Install nomadfs {s} -> {s}? [y/N] ", .{ current, next });
    var buf: [64]u8 = undefined;
    var reader = stdin.readerStreaming(io, &buf);
    const answer = std.mem.trim(u8, (reader.interface.takeDelimiter('\n') catch null) orelse "", " \t\r\n");
    return std.ascii.eqlIgnoreCase(answer, "y") or std.ascii.eqlIgnoreCase(answer, "yes");
}
