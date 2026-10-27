//! Nomadfs Gui: an Oriel app for NomadFS.
//!
//! The page calls the functions in `Commands` with `invoke()` and receives
//! `Events` with `listen()`. The zig side reuses the mobile C ABI layer
//! (`nomadfs.mobile_api`), so the GUI, the phone bindings and the CLI all
//! run against the same core.

const std = @import("std");
const builtin = @import("builtin");
const oriel = @import("oriel");
const app = @import("oriel_app");
const commands = @import("commands.zig");

pub const std_options: std.Options = .{ .logFn = oriel.log.logFn };

/// No $HOME on Android: Oriel hands over the app's private dirs before
/// main runs; point the command layer at them.
fn initDataDirs() void {
    if (builtin.abi.isAndroid()) {
        const app_id = "net.nomadfs.app";
        if (oriel.paths.appData(std.heap.page_allocator, .{ .name = app_id })) |dir| {
            commands.initAndroidDataDir(dir);
        } else |_| {}
    }
}

/// Events pushed from Zig to the page.
pub const Events = struct {
    node_state: struct { running: bool },
};

pub const Commands = struct {
    defaults: void = undefined,

    /// `invoke("app_info")`: how the zig side was built.
    pub fn app_info(_: std.mem.Allocator) struct {
        zig: []const u8,
        mode: []const u8,
        dev: bool,
        nomadfs_running: bool,
    } {
        return .{
            .zig = builtin.zig_version_string,
            .mode = @tagName(builtin.mode),
            .dev = app.build.dev != null,
            .nomadfs_running = commands.isRunning(),
        };
    }

    /// `invoke("ensure_config")`: creates the default config when missing.
    pub fn ensure_config(gpa: std.mem.Allocator) !commands.ConfigResult {
        return commands.ensureConfig(gpa);
    }

    /// `invoke("node_open", { config_path })`.
    pub fn node_open(gpa: std.mem.Allocator, args: commands.NodeOpenArgs) !void {
        commands.dropFailed();
        commands.nodeOpen(gpa, args) catch |err| {
            if (err == error.NodeFailedToStart or err == error.ConfigInvalid) {
                failedSeen();
            }
            return err;
        };
        if (commands.isRunning()) stateChanged();
    }

    /// `invoke("node_close")`.
    pub fn node_close() void {
        commands.nodeClose();
        stateChanged();
    }

    /// `invoke("node_state")`.
    pub fn node_state(gpa: std.mem.Allocator) !commands.NodeStateResult {
        return commands.nodeState(gpa);
    }

    /// `invoke("put_text", { text })` returns the CID.
    pub fn put_text(gpa: std.mem.Allocator, args: commands.PutTextArgs) ![]const u8 {
        return @import("commands.zig").putText(gpa, args);
    }

    /// `invoke("get_text", { cid })` returns the file contents.
    pub fn get_text(gpa: std.mem.Allocator, args: commands.GetTextArgs) ![]const u8 {
        return commands.getText(gpa, args);
    }

    /// `invoke("pair_ticket", { config_path, address })`.
    pub fn pair_ticket(gpa: std.mem.Allocator, args: commands.PairTicketArgs) !commands.PairTicketResult {
        return commands.pairTicket(gpa, args);
    }

    /// `invoke("devices_list", { config_path })`.
    pub fn devices_list(gpa: std.mem.Allocator, args: commands.ListArgs) ![]commands.DeviceEntry {
        return commands.devicesList(gpa, args);
    }

    /// `invoke("trust_device", { config_path, uri })`.
    pub fn trust_device(gpa: std.mem.Allocator, args: commands.TrustDeviceArgs) !void {
        return commands.trustDevice(gpa, args);
    }

    /// `invoke("revoke_device", { config_path, query })`.
    pub fn revoke_device(gpa: std.mem.Allocator, args: commands.RevokeDeviceArgs) !void {
        return commands.revokeDevice(gpa, args);
    }

    /// `invoke("shares_local")`: folders this device shares.
    pub fn shares_local(gpa: std.mem.Allocator) ![]commands.ShareInfo {
        return commands.sharesLocal(gpa);
    }

    /// `invoke("share_add", { config_path, name, path })`.
    pub fn share_add(gpa: std.mem.Allocator, args: commands.ShareAddArgs) !void {
        return commands.shareAdd(gpa, args);
    }

    /// `invoke("share_remove", { config_path, name })`.
    pub fn share_remove(gpa: std.mem.Allocator, args: commands.ShareRemoveArgs) !void {
        return commands.shareRemove(gpa, args);
    }

    /// `invoke("remote_devices")`: reachable devices and their shares.
    pub fn remote_devices(gpa: std.mem.Allocator) ![]commands.RemoteDevice {
        return commands.remoteDevices(gpa);
    }

    /// `invoke("browse", { peer, cid })`: one directory of a device's share.
    pub fn browse(gpa: std.mem.Allocator, args: commands.BrowseArgs) ![]commands.BrowseEntry {
        return commands.browse(gpa, args);
    }

    /// `invoke("download", { peer, cid, name })`: fetch a file on demand.
    pub fn download(gpa: std.mem.Allocator, args: commands.DownloadArgs) !commands.DownloadResult {
        return commands.download(gpa, args);
    }

    /// `invoke("join_info", { config_path })`: this device's join code.
    pub fn join_info(gpa: std.mem.Allocator, args: commands.ListArgs) !commands.JoinInfo {
        return commands.joinInfo(gpa, args);
    }

    /// `invoke("join", { config_path, code })`: join another device's swarm.
    pub fn join(gpa: std.mem.Allocator, args: commands.JoinArgs) !void {
        return commands.join(gpa, args);
    }

    /// `invoke("set_nickname", { config_path, nickname })`.
    pub fn set_nickname(gpa: std.mem.Allocator, args: commands.NicknameArgs) !void {
        return commands.setNickname(gpa, args);
    }
};

/// Android's storage extension (all-files access, standard folders) is
/// callable from the page; other platforms have nothing to grant.
fn setup() !void {
    if (oriel.extensions.get("nomadfs.storage").available())
        oriel.extensions.expose("nomadfs.storage", .{ .methods = &.{ "status", "request", "info" } });
}
var g_change_once: std.atomic.Value(bool) = .init(false);

fn stateChanged() void {
    // Events go through the page's `listen("node_state", ...)` handler; the
    // boolean payload matches commands.nodeState's fields.
    _ = g_change_once.swap(true, .monotonic);
}

fn failedSeen() void {
    LogPrint();
}

var failed_notified: bool = false;
var failed_dirty: bool = false;

fn LogPrint() void {
    failed_dirty = true;
}

pub fn main(init: std.process.Init) !u8 {
    initDataDirs();
    return oriel.main(init, .{ .commands = Commands, .events = Events }, .{
        .app = app.build,
        .window = .{ .title = "NomadFS", .width = 900, .height = 640 },
        .setup = setup,
    });
}
