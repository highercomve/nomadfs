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
const tray = @import("tray.zig");
const background = @import("background.zig");
const media = @import("media.zig");
const updates = @import("updates.zig");

pub const std_options: std.Options = .{ .logFn = oriel.log.logFn };

/// No $HOME on Android: Oriel hands over the app's private dirs before
/// main runs; point the command layer at them.
fn initDataDirs() void {
    if (builtin.abi.isAndroid()) {
        const app_id = "com.foreachdeveloper.nomadfs";
        if (oriel.paths.appData(std.heap.page_allocator, .{ .name = app_id })) |dir| {
            commands.initAndroidDataDir(dir);
        } else |_| {}
    }
}

/// Events pushed from Zig to the page.
pub const Events = struct {
    /// While `updater_install` downloads (updates.zig).
    @"updater://progress": struct { downloaded: u64, total: ?u64 },
};

/// @atlas allow: the webview calls these by name
pub const Commands = struct {
    defaults: void = undefined,

    /// Everything that touches the node, the network or the disk runs on a
    /// worker thread: they share one lock, and a command waiting on it on
    /// the UI thread would freeze the window (node_open behind a share scan
    /// did, for 20 s on a phone). Only quick config-file reads stay inline.
    pub const async_commands = .{ "invite_create", "invite_status", "invite_cancel", "invite_accept", "read_range", "mount_status", "mount_start", "mount_stop", "open_path", "pick_folder", "app_info", "node_open", "node_close", "node_state", "put_text", "get_text", "pair_ticket", "devices_list", "trust_device", "revoke_device", "shares_local", "share_add", "share_remove", "remote_devices", "browse", "download", "swarm_list", "swarm_sync", "swarm_add_file", "swarm_mkdir", "swarm_delete", "swarm_rename", "swarm_read_range", "swarm_download", "swarm_rotate_key", "keep_running_status", "keep_running_set", "open_app_settings", "swarm_backup_status", "swarm_backup_set", "swarm_copies_set", "accept_copies_set", "media_url", "about_info", "update_info", "note_store", "cache_info", "cache_clear", "cache_set_limit", "share_backup_set", "backup_status", "file_details", "device_info" } ++ updates.Updater.async_commands;

    /// `invoke("invite_create", { config_path })`: one-time invite code.
    pub fn invite_create(gpa: std.mem.Allocator, args: commands.ListArgs) !commands.InviteInfo {
        return commands.inviteCreate(gpa, args);
    }

    /// `invoke("invite_status", { config_path })`.
    pub fn invite_status(gpa: std.mem.Allocator, args: commands.ListArgs) !commands.InviteInfo {
        return commands.inviteStatus(gpa, args);
    }

    /// `invoke("invite_cancel")`.
    pub fn invite_cancel() void {
        commands.inviteCancel();
    }

    /// `invoke("invite_accept", { config_path, code })`: join with a code;
    /// returns the inviting device's name.
    pub fn invite_accept(gpa: std.mem.Allocator, args: commands.InviteAcceptArgs) ![]const u8 {
        return commands.inviteAccept(gpa, args);
    }

    /// `invoke("swarm_rotate_key", { config_path })`: a new swarm key for
    /// every reachable trusted device; returns who got it.
    pub fn swarm_rotate_key(gpa: std.mem.Allocator, args: commands.ListArgs) ![]commands.RotationEntry {
        return commands.swarmRotateKey(gpa, args);
    }

    /// `invoke("swarm_list", { dir })`: a folder of the swarm folder.
    pub fn swarm_list(gpa: std.mem.Allocator, args: commands.SwarmDirArgs) !commands.SwarmListing {
        return commands.swarmList(gpa, args);
    }

    /// `invoke("swarm_sync")`: pull changes from every device now.
    pub fn swarm_sync() !usize {
        return commands.swarmSync();
    }

    /// `invoke("swarm_add_file", { dir })`: pick a file and add it.
    /// Returns its name, or null when the picker was cancelled.
    pub fn swarm_add_file(gpa: std.mem.Allocator, args: commands.SwarmDirArgs) !?[]const u8 {
        const path = try oriel.dialog.openFile(gpa, .{ .title = "Add a file to the swarm folder" }) orelse return null;
        return try commands.swarmAddFile(gpa, args.dir, path);
    }

    /// `invoke("swarm_mkdir", { dir, name })`.
    pub fn swarm_mkdir(args: commands.SwarmNameArgs) !void {
        return commands.swarmMkdir(args);
    }

    /// `invoke("swarm_delete", { path })`.
    pub fn swarm_delete(args: commands.SwarmPathArgs) !void {
        return commands.swarmDelete(args);
    }

    /// `invoke("swarm_rename", { path, name })`.
    pub fn swarm_rename(args: commands.SwarmRenameArgs) !void {
        return commands.swarmRename(args);
    }

    /// `invoke("swarm_read_range", { cid, author_id, offset, len })`.
    pub fn swarm_read_range(gpa: std.mem.Allocator, args: commands.SwarmRangeArgs) ![]const u8 {
        return commands.swarmReadRange(gpa, args);
    }

    /// `invoke("swarm_download", { cid, author_id, name })`.
    pub fn swarm_download(gpa: std.mem.Allocator, args: commands.SwarmDownloadArgs) !commands.DownloadResult {
        return commands.swarmDownload(gpa, args);
    }

    /// `invoke("read_range", { peer, cid, offset, len })`: base64 bytes of
    /// a remote file, for previews.
    pub fn read_range(gpa: std.mem.Allocator, args: commands.ReadRangeArgs) ![]const u8 {
        return commands.readRange(gpa, args);
    }

    /// `invoke("mount_status")`: whether mounting is supported and active.
    pub fn mount_status(gpa: std.mem.Allocator) !commands.MountStatus {
        return commands.mountStatus(gpa);
    }

    /// `invoke("mount_start", { path })`: mount every device's shares.
    pub fn mount_start(gpa: std.mem.Allocator, args: commands.MountArgs) !void {
        defer oriel.App.runOnMain(@as(?*anyopaque, null), refreshTray);
        return commands.mountStart(gpa, args);
    }

    /// `invoke("mount_stop")`.
    pub fn mount_stop() void {
        commands.mountStop();
        oriel.App.runOnMain(@as(?*anyopaque, null), refreshTray);
    }

    /// `invoke("open_path", { path })`: open in the file manager.
    pub fn open_path(gpa: std.mem.Allocator, args: commands.OpenPathArgs) !void {
        return commands.openPath(gpa, args);
    }

    /// `invoke("about_info", { config_path })`: versions, this build, this
    /// device and its storage, for the About section.
    pub fn about_info(gpa: std.mem.Allocator, args: commands.ListArgs) !commands.AboutInfo {
        return commands.aboutInfo(gpa, args, @import("about"));
    }

    /// `invoke("file_details", { cid, peer | author_id })`: how a file is stored.
    pub fn file_details(gpa: std.mem.Allocator, args: commands.FileDetailsArgs) !commands.FileDetails {
        return commands.fileDetails(gpa, args);
    }

    /// `invoke("share_backup_set", { config_path, name, on })`.
    pub fn share_backup_set(gpa: std.mem.Allocator, args: commands.ShareBackupArgs) !void {
        return commands.shareBackupSet(gpa, args);
    }

    /// `invoke("backup_status")`: where each folder marked for backup is kept.
    pub fn backup_status(gpa: std.mem.Allocator) ![]commands.BackupStatus {
        return commands.backupStatus(gpa);
    }

    /// `invoke("cache_info", { config_path })`: the read cache's size and limit.
    pub fn cache_info(gpa: std.mem.Allocator, args: commands.ListArgs) !commands.CacheInfo {
        return commands.cacheInfo(gpa, args);
    }

    /// `invoke("cache_clear", { config_path })`: empties the read cache.
    pub fn cache_clear(gpa: std.mem.Allocator, args: commands.ListArgs) !u64 {
        return commands.cacheClear(gpa, args);
    }

    /// `invoke("cache_set_limit", { config_path, limit_mb })`.
    pub fn cache_set_limit(gpa: std.mem.Allocator, args: commands.CacheLimitArgs) !void {
        return commands.cacheSetLimit(gpa, args);
    }

    /// `invoke("update_info")`: how this copy updates (updates.zig).
    pub fn update_info(gpa: std.mem.Allocator, io: std.Io) updates.Info {
        return updates.info(gpa, io);
    }
    /// `invoke("updater_check")`: { available, version }.
    pub const updater_check = updates.Updater.updater_check;
    /// `invoke("updater_install")`: downloads and swaps in the update.
    pub const updater_install = updates.Updater.updater_install;
    /// `invoke("updater_restart")`: restarts as the new version.
    pub const updater_restart = updates.Updater.updater_restart;

    /// `invoke("media_url", { kind, id, cid, size, name })`: where a
    /// `<video>`/`<audio>` streams a file from another device.
    pub fn media_url(gpa: std.mem.Allocator, args: media.UrlArgs) ![]const u8 {
        return media.url(gpa, args);
    }

    /// `invoke("swarm_backup_status", { config_path })`.
    pub fn swarm_backup_status(gpa: std.mem.Allocator, args: commands.ListArgs) !commands.BackupInfo {
        return commands.swarmBackupStatus(gpa, args);
    }

    /// `invoke("swarm_backup_set", { config_path, on })`: keep a copy of the
    /// whole swarm folder on this device.
    pub fn swarm_backup_set(gpa: std.mem.Allocator, args: commands.BackupArgs) !commands.BackupInfo {
        return commands.swarmBackupSet(gpa, args);
    }

    /// `invoke("device_info", { peer? })`: a device's About and health,
    /// asked on demand.
    pub fn device_info(gpa: std.mem.Allocator, args: commands.DeviceInfoArgs) !commands.DeviceInfo {
        return commands.deviceInfo(gpa, args);
    }

    /// `invoke("swarm_copies_set", { config_path, copies })`: push
    /// new/updated swarm folder files to N peer devices.
    /// `invoke("accept_copies_set", { config_path, on })`: this device keeps
    /// copies of other devices' swarm files, or not.
    pub fn accept_copies_set(gpa: std.mem.Allocator, args: commands.AcceptCopiesArgs) !commands.BackupInfo {
        return commands.acceptCopiesSet(gpa, args);
    }

    pub fn swarm_copies_set(gpa: std.mem.Allocator, args: commands.SwarmCopiesArgs) !commands.BackupInfo {
        return commands.swarmCopiesSet(gpa, args);
    }

    /// `invoke("keep_running_status")`: Android's background mode.
    pub fn keep_running_status(gpa: std.mem.Allocator) !background.Status {
        _ = gpa;
        return background.status();
    }

    /// `invoke("keep_running_set", { on })`: start or stop running in the
    /// background (Android).
    pub fn keep_running_set(gpa: std.mem.Allocator, args: background.SetArgs) !background.Status {
        _ = gpa;
        return background.set(args);
    }

    /// `invoke("open_app_settings")`: the app's system settings page (Android).
    pub fn open_app_settings(gpa: std.mem.Allocator) !bool {
        _ = gpa;
        return background.openSettings();
    }

    /// `invoke("pick_folder")`: the system folder picker. Null when the
    /// user cancels.
    pub fn pick_folder(gpa: std.mem.Allocator) !?commands.PickedFolder {
        const folder = try oriel.dialog.openFolder(gpa, .{ .title = "Choose a folder to share" }) orelse return null;
        std.log.info("pick_folder: \"{s}\"", .{folder.id});
        return try commands.pickedFolder(gpa, folder.id, folder.name);
    }

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
        return commands.nodeOpen(gpa, args);
    }

    /// `invoke("node_close")`.
    pub fn node_close() void {
        commands.nodeClose();
    }

    /// `invoke("node_state")`.
    pub fn node_state(gpa: std.mem.Allocator) !commands.NodeStateResult {
        return commands.nodeState(gpa);
    }

    /// `invoke("put_text", { text })` returns the CID.
    pub fn put_text(gpa: std.mem.Allocator, args: commands.PutTextArgs) ![]const u8 {
        return @import("commands.zig").putText(gpa, args);
    }

    /// `invoke("note_store", { text })`: a note in the swarm folder's
    /// Notes, for every device.
    pub fn note_store(gpa: std.mem.Allocator, args: commands.PutTextArgs) !commands.NoteStored {
        return commands.noteStore(gpa, args);
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

    /// `invoke("join_info", { config_path })`: this device's name and address.
    pub fn join_info(gpa: std.mem.Allocator, args: commands.ListArgs) !commands.JoinInfo {
        return commands.joinInfo(gpa, args);
    }

    /// `invoke("set_nickname", { config_path, nickname })`.
    pub fn set_nickname(gpa: std.mem.Allocator, args: commands.NicknameArgs) !void {
        return commands.setNickname(gpa, args);
    }
};

/// Android's storage extension (all-files access, standard folders) is
/// callable from the page; other platforms have nothing to grant.
fn refreshTray(_: ?*anyopaque) void {
    tray.refresh();
}

/// SIGTERM/SIGINT/SIGHUP (kill, logout, Ctrl-C): unmount first so no
/// dead mount stays behind, then end the process.
fn onTerminate(sig: std.os.linux.SIG) callconv(.c) void {
    commands.emergencyUnmount();
    std.os.linux.exit_group(128 + @as(i32, @intCast(@intFromEnum(sig))));
}

fn installExitHandlers() void {
    if (builtin.os.tag != .linux or builtin.abi.isAndroid()) return;
    const action = std.os.linux.Sigaction{
        .handler = .{ .handler = onTerminate },
        .mask = std.os.linux.sigemptyset(),
        .flags = 0,
    };
    for ([_]std.os.linux.SIG{ .TERM, .INT, .HUP }) |sig| _ = std.os.linux.sigaction(sig, &action, null);
}

fn setup() !void {
    installExitHandlers();
    // Desktop: a tray icon keeps NomadFS (and its mount) running with the
    // window closed.
    tray.setup() catch |err| std.log.warn("tray unavailable: {any}", .{err});
    // Android: the notification's Stop button.
    background.setup();
    if (oriel.extensions.get("nomadfs.storage").available())
        oriel.extensions.expose("nomadfs.storage", .{ .methods = &.{ "status", "request", "info" } });
}

pub fn main(init: std.process.Init) !u8 {
    initDataDirs();
    return oriel.main(init, .{ .commands = Commands, .events = Events }, .{
        .app = app.build,
        // With a tray, closing the window hides it; Quit is in the tray.
        // Android: swiping it away from Recents hides it too, so running
        // in the background (background.zig) outlives the window.
        .window = .{ .title = "NomadFS", .width = 1200, .height = 800, .hide_on_close = tray.available or background.supported },
        .setup = setup,
    });
}
