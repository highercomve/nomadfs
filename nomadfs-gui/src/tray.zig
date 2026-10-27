//! The desktop tray: NomadFS keeps running (and keeps the mount served)
//! after its window closes. The icon's left click shows or hides the
//! window; its menu mounts and unmounts every device's shares, opens the
//! mount folder and quits for real.

const std = @import("std");
const oriel = @import("oriel");
const commands = @import("commands.zig");

pub const available = oriel.tray.available;

var tray: if (available) ?*oriel.tray.Tray else void = if (available) null else {};
var busy: std.atomic.Value(bool) = .init(false);

const gpa = std.heap.smp_allocator;

pub fn setup() !void {
    if (!available) return;
    tray = try oriel.tray.Tray.create(gpa, .{
        .id = "net.nomadfs.app",
        .title = "NomadFS",
        .tooltip = "NomadFS is running",
        .icon = .{ .png = @embedFile("tray.png") },
        .menu = menu(false),
        .on_menu = onMenu,
    });
    refresh();
}

fn menu(mounted: bool) []const oriel.tray.MenuItem {
    const items = struct {
        const off = [_]oriel.tray.MenuItem{
            .{ .item = .{ .id = "show", .label = "Show or hide NomadFS" } },
            .separator,
            .{ .check = .{ .id = "mount", .label = "Mount devices", .checked = false } },
            .{ .item = .{ .id = "open", .label = "Open mount folder", .enabled = false } },
            .separator,
            .{ .item = .{ .id = "quit", .label = "Quit NomadFS" } },
        };
        const on = [_]oriel.tray.MenuItem{
            .{ .item = .{ .id = "show", .label = "Show or hide NomadFS" } },
            .separator,
            .{ .check = .{ .id = "mount", .label = "Mount devices", .checked = true } },
            .{ .item = .{ .id = "open", .label = "Open mount folder" } },
            .separator,
            .{ .item = .{ .id = "quit", .label = "Quit NomadFS" } },
        };
    };
    return if (mounted) &items.on else &items.off;
}

/// Brings the menu and tooltip in line with the mount (main thread).
pub fn refresh() void {
    if (!available) return;
    const t = tray orelse return;
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const status = commands.mountPeek(&path_buf) orelse return; // busy: next change refreshes
    t.setMenu(menu(status.mounted)) catch {};
    var buf: [std.fs.max_path_bytes + 64]u8 = undefined;
    const tip = if (status.mounted)
        std.fmt.bufPrint(&buf, "NomadFS: devices mounted at {s}", .{status.path}) catch "NomadFS"
    else
        "NomadFS is running";
    t.setTooltip(tip) catch {};
}

fn onMenu(id: []const u8, _: ?bool) void {
    if (std.mem.eql(u8, id, "show")) {
        if (oriel.App.getWindow("main")) |w| w.toggle();
    } else if (std.mem.eql(u8, id, "mount")) {
        // Mounting waits for the kernel; keep the UI thread free.
        if (busy.swap(true, .acq_rel)) return;
        const thread = std.Thread.spawn(.{}, toggleMount, .{}) catch {
            busy.store(false, .release);
            return;
        };
        thread.detach();
    } else if (std.mem.eql(u8, id, "open")) {
        var path_buf: [std.fs.max_path_bytes]u8 = undefined;
        const status = commands.mountPeek(&path_buf) orelse return;
        if (status.mounted) commands.openPath(gpa, .{ .path = status.path }) catch {};
    } else if (std.mem.eql(u8, id, "quit")) {
        // Unmount and stop the node cleanly before leaving.
        commands.nodeClose();
        oriel.App.quit(0);
    }
}

fn toggleMount() void {
    defer busy.store(false, .release);
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const status = commands.mountStatus(arena) catch return;
    if (status.mounted) {
        commands.mountStop();
    } else {
        commands.mountStart(arena, .{ .path = status.default_path }) catch |err| {
            std.debug.print("tray: mount failed: {any}\n", .{err});
        };
    }
    oriel.App.runOnMain(@as(?*anyopaque, null), refreshOnMain);
}

fn refreshOnMain(_: ?*anyopaque) void {
    refresh();
}
