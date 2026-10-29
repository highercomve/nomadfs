//! Updates from the GitHub releases, with Oriel's updater. Each release
//! carries a `latest.json` signed with the release key
//! (scripts/release.sh); the app checks it, and how it updates depends on
//! how it was installed:
//!
//! - AppImage (Linux): downloads the new AppImage, swaps it in, restarts.
//! - Android: the APK isn't replaced by the app; the page opens the new
//!   APK's download in the browser, which installs it.
//! - deb, rpm or a copy built from source: the package manager or the
//!   user updates it; the page links the release.

const std = @import("std");
const builtin = @import("builtin");
const oriel = @import("oriel");
const app = @import("oriel_app");
const about = @import("about");

const is_android = builtin.abi.isAndroid();

/// The manifest entry this build reads. Android reports its OS as Linux,
/// so its entries get their own name (the APK, not the desktop AppImage).
pub const target = if (is_android) @tagName(builtin.cpu.arch) ++ "-android" else oriel.updater.DEFAULT_TARGET;

const repo = "https://github.com/highercomve/nomadfs";

/// `updater_check`, `updater_install`, `updater_restart`.
pub const Updater = oriel.updater.Commands(.{
    .app_id = "com.foreachdeveloper.nomadfs",
    .manifest_url = repo ++ "/releases/latest/download/latest.json",
    .current_version = about.version,
    .public_key_b64 = app.update_public_key orelse @compileError("set update_public_key in build.zig"),
    .target = target,
});

pub const Info = struct {
    /// "install": updates itself (AppImage). "download": the page opens
    /// the new APK. "manual": updated outside the app (deb, rpm, a build
    /// from source); the page links the release.
    mode: []const u8,
    current: []const u8,
    /// The release page, for "manual".
    releases: []const u8 = repo ++ "/releases/latest",
    /// The new APK's URL for "download", with `{v}` for the version.
    apk: []const u8 = repo ++ "/releases/download/v{v}/nomadfs-{v}.apk",
};

/// `invoke("update_info")`: how this copy updates.
pub fn info(gpa: std.mem.Allocator, io: std.Io) Info {
    const mode = if (is_android)
        "download"
    else if (builtin.os.tag == .linux and (oriel.updater.runningAsAppImage(io, gpa) catch false))
        "install"
    else
        "manual";
    return .{ .mode = mode, .current = about.version };
}
