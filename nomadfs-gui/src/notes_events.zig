//! Tells the page when a sync changed the notes. The notes service decides
//! whether what is under Notes/ is different (`Notes.changedSince`) and calls
//! its subscribers; this only subscribes and emits `notes://changed`.

const std = @import("std");
const oriel = @import("oriel");
const nomadfs = @import("nomadfs");

pub const Changed = struct { at: u64 };

const events = oriel.App.events(struct { @"notes://changed": Changed });

/// What the subscription points at (the hook needs some address).
var g_token: u8 = 0;

/// Subscribes the page to the node's notes service. Runs when a node has
/// started, under the app's node lock (commands.after_node_open): the
/// subscription lives and dies with that node.
pub fn subscribe(handle: *nomadfs.mobile_api.NodeHandle) void {
    const service = handle.node.notes orelse return;
    service.subscribe(.{ .ctx = &g_token, .runFn = emit }) catch |err|
        std.debug.print("notes: the page won't hear of changes: {any}\n", .{err});
}

fn emit(_: *anyopaque) void {
    const seconds = std.Io.Timestamp.now(std.Io.Threaded.global_single_threaded.io(), .real).toSeconds();
    events.emit(.@"notes://changed", .{ .at = @intCast(@max(0, seconds)) });
}
