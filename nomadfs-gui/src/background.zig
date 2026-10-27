//! Android: NomadFS keeps running with no window in front, so the other
//! devices can still browse this phone's shares and the swarm folder keeps
//! syncing. A foreground service holds the process, with an ongoing
//! notification and a Stop button. The desktop has the tray instead.

const std = @import("std");
const builtin = @import("builtin");
const oriel = @import("oriel");

pub const supported = builtin.abi.isAndroid();

pub const Status = struct {
    supported: bool,
    on: bool,
    /// Battery optimization leaves NomadFS alone. While it doesn't, Android
    /// (and MIUI sooner) may still stop it in the background.
    battery_unrestricted: bool,
};

pub const SetArgs = struct { on: bool };

var running: std.atomic.Value(bool) = .init(false);

/// Registers the notification's Stop button (main thread, at setup).
pub fn setup() void {
    if (!supported) return;
    oriel.android.onSystemEvent(onSystemEvent);
}

fn onSystemEvent(name: []const u8, data: []const u8) void {
    // The page hears the same event (`android:event`) and updates its switch.
    if (std.mem.eql(u8, name, "action") and std.mem.eql(u8, data, "stop")) _ = set(.{ .on = false }) catch {};
}

pub fn status() Status {
    if (!supported) return .{ .supported = false, .on = false, .battery_unrestricted = false };
    return .{ .supported = true, .on = running.load(.monotonic), .battery_unrestricted = oriel.android.batteryUnrestricted() };
}

pub fn set(args: SetArgs) !Status {
    if (!supported) return error.Unsupported;
    if (args.on) {
        // Android 13+ shows the notification only with this permission;
        // the service runs either way.
        _ = oriel.permissions.request(.notifications);
        try oriel.android.setKeepRunning(true, "NomadFS is running", "Your other devices can reach this phone's shares and the swarm folder", &.{
            .{ .id = "stop", .label = "Stop" },
        });
    } else {
        try oriel.android.setKeepRunning(false, "", "", &.{});
    }
    running.store(args.on, .monotonic);
    return status();
}

/// The app's page in the system settings: battery usage, autostart (MIUI).
pub fn openSettings() bool {
    if (!supported) return false;
    return oriel.android.openAppSettings();
}
