//! CLI parsing and presentation only; backup/service.zig owns operations.
const std = @import("std");
const service = @import("nomadfs").backup_service;
const usage = "nomadfs backup <target> status|run|verify|restore|recovery-key|forget [options]\n" ++
    "  <target>                      a [backup.<target>] section of the configuration (s3: the first)\n" ++
    "  --config FILE                 configuration file\n" ++
    "  --snapshot snapshots/ID       verify/restore snapshot (status lists IDs)\n" ++
    "  --path PATH                   restore one path or subtree\n" ++
    "  --to DIRECTORY                restore destination\n" ++
    "  --recovery-words WORDS         unlock with quoted 24 words\n" ++
    "  --tier bulk|standard|expedited  thaw speed on an archive target (restore, verify --download)\n" ++
    "  --download                    verify an archive target by reading every block (thaws it)\n" ++
    "  forget PATH                   queue permanent offsite purge for next run\n";
fn parseTier(text: []const u8) ?service.Tier {
    if (std.mem.eql(u8, text, "bulk")) return .Bulk;
    if (std.mem.eql(u8, text, "standard")) return .Standard;
    if (std.mem.eql(u8, text, "expedited")) return .Expedited;
    return null;
}
pub fn parse(args: []const []const u8) !service.Request {
    if (args.len < 2 or args[0].len == 0 or args[0][0] == '-') return error.InvalidArguments;
    var request: service.Request = .{ .target = args[0], .action = std.meta.stringToEnum(service.Action, args[1]) orelse return error.InvalidArguments };
    var i: usize = 2;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (request.action == .forget and request.path == null and !std.mem.startsWith(u8, arg, "--")) {
            request.path = arg;
            continue;
        }
        if (std.mem.eql(u8, arg, "--download")) {
            request.download = true;
            continue;
        }
        if (i + 1 >= args.len) return error.InvalidArguments;
        i += 1;
        if (std.mem.eql(u8, arg, "--config")) request.config_path = args[i] else if (std.mem.eql(u8, arg, "--snapshot")) request.snapshot = args[i] else if (std.mem.eql(u8, arg, "--path")) request.path = args[i] else if (std.mem.eql(u8, arg, "--to")) request.destination = args[i] else if (std.mem.eql(u8, arg, "--recovery-words")) request.recovery_words = args[i] else if (std.mem.eql(u8, arg, "--tier")) request.tier = parseTier(args[i]) orelse return error.InvalidArguments else return error.InvalidArguments;
    }
    if (request.action == .restore and (request.snapshot == null or request.destination == null)) return error.InvalidArguments;
    if (request.action == .forget and request.path == null) return error.InvalidArguments;
    if (request.download and request.action != .verify) return error.InvalidArguments;
    return request;
}
/// "2026-11-14" for a Unix time.
fn date(time: u64, out: *[10]u8) []const u8 {
    const epoch: std.time.epoch.EpochSeconds = .{ .secs = time };
    const yd = epoch.getEpochDay().calculateYearDay();
    const md = yd.calculateMonthDay();
    return std.fmt.bufPrint(out, "{d:0>4}-{d:0>2}-{d:0>2}", .{ yd.year, md.month.numeric(), @as(u8, md.day_index) + 1 }) catch unreachable;
}
fn thawTime(tier: service.Tier) []const u8 {
    return switch (tier) {
        .Bulk => "12-48 h",
        .Standard => "3-12 h",
        .Expedited => "a few minutes",
    };
}
fn printThaw(packs: usize, bytes: u64, tier: service.Tier) void {
    std.debug.print("Thawing {d} packs ({d:.2} GB), ready in about {s}. Run the same command again to continue.\n", .{ packs, @as(f64, @floatFromInt(bytes)) / (1024.0 * 1024.0 * 1024.0), thawTime(tier) });
}
pub fn run(io: std.Io, a: std.mem.Allocator, args: []const []const u8) !u8 {
    if (args.len == 0 or (args.len == 1 and std.mem.eql(u8, args[0], "--help"))) {
        std.debug.print("{s}", .{usage});
        return 0;
    }
    const request = parse(args) catch {
        std.debug.print("{s}", .{usage});
        return 2;
    };
    var result = service.execute(a, io, request) catch |err| {
        if (err == error.DeepBackupOff) {
            std.debug.print("Backup \"{s}\" {s} (deep_backup = true, or Settings → Deep backup in the app)\n", .{ request.target.?, service.Gate.needs_deep_backup.text() });
        } else std.debug.print("Backup \"{s}\" failed: {s}\n", .{ request.target.?, @errorName(err) });
        return 1;
    };
    defer service.deinitResult(a, &result);
    if (result.status) |status| {
        std.debug.print("{s}: storage class {s}, {s} uploads\n", .{ request.target.?, @tagName(status.storage_class), @tagName(status.schedule) });
        std.debug.print("{d} indexed blocks; {d} snapshots\n", .{ status.indexed_blocks, status.snapshots.len });
        if (status.deferred_packs > 0) {
            var first: [10]u8 = undefined;
            var last: [10]u8 = undefined;
            std.debug.print("{d} packs waiting to be removed (minimum storage time): from {s} to {s}\n", .{ status.deferred_packs, date(status.deferred_first, &first), date(status.deferred_last, &last) });
        }
        if (result.gate != .uploading) std.debug.print("{s}\n", .{result.gate.text()});
        if (result.archive_missing) std.debug.print("deep backup is on: {s}\n", .{service.no_archive});
        for (status.snapshots) |name| std.debug.print("{s}\n", .{name});
    }
    if (result.report) |report| {
        std.debug.print("Uploaded {d} new blocks ({d} bytes)\nSnapshot: {s}\n", .{ report.uploaded_blocks, report.uploaded_bytes, report.snapshot });
        if (report.waiting_files > 0) std.debug.print("{d} files waiting for blocks: not in this snapshot, a later run takes them\n", .{report.waiting_files});
        if (report.recovery_phrase) |phrase| {
            if (report.reused_key) std.debug.print("This target opens with the recovery words of your other backup target:\n{s}\n", .{phrase}) else std.debug.print("Save these recovery words:\n{s}\n", .{phrase});
        }
    }
    if (result.recovery_phrase) |phrase| std.debug.print("{s}\n", .{phrase});
    if (result.check) |check| {
        if (check.thawing_packs > 0) {
            printThaw(check.thawing_packs, check.thawing_bytes, request.tier);
        } else if (check.downloaded) {
            std.debug.print("Verified {d} blocks\n", .{check.blocks});
        } else std.debug.print("Checked {d} packs by listing and {d} blocks in the index (nothing downloaded; --download reads every block)\n", .{ check.packs, check.blocks });
    }
    if (result.restore) |restored| {
        std.debug.print("Restored {d} files\n", .{restored.files});
        if (restored.thawing_packs > 0) printThaw(restored.thawing_packs, restored.thawing_bytes, request.tier);
    }
    if (request.action == .forget) std.debug.print("Purge recorded; the next run removes this path from offsite history and packs.\n", .{});
    return 0;
}
test "backup CLI: parse target, restore, forget, tier and download" {
    const r = try parse(&.{ "s3", "restore", "--snapshot", "snapshots/test", "--to", "/tmp/restore", "--path", "Photos/a.jpg" });
    try std.testing.expectEqual(service.Action.restore, r.action);
    try std.testing.expectEqualStrings("s3", r.target.?);
    try std.testing.expectEqualStrings("Photos/a.jpg", r.path.?);
    try std.testing.expectEqual(service.Tier.Bulk, r.tier);
    const f = try parse(&.{ "s3", "forget", "Photos/a.jpg" });
    try std.testing.expectEqual(service.Action.forget, f.action);
    try std.testing.expectError(error.InvalidArguments, parse(&.{ "s3", "restore" }));
    const cold = try parse(&.{ "archive", "restore", "--snapshot", "snapshots/test", "--to", "/tmp/restore", "--tier", "standard" });
    try std.testing.expectEqualStrings("archive", cold.target.?);
    try std.testing.expectEqual(service.Tier.Standard, cold.tier);
    const v = try parse(&.{ "archive", "verify", "--download", "--tier", "expedited" });
    try std.testing.expect(v.download);
    try std.testing.expectEqual(service.Tier.Expedited, v.tier);
    try std.testing.expect(!(try parse(&.{ "archive", "verify" })).download);
    try std.testing.expectError(error.InvalidArguments, parse(&.{ "archive", "verify", "--tier", "slow" }));
    try std.testing.expectError(error.InvalidArguments, parse(&.{ "archive", "status", "--download" }));
    try std.testing.expectError(error.InvalidArguments, parse(&.{ "status", "--config" }));
    try std.testing.expectError(error.InvalidArguments, parse(&.{ "--config", "status" }));
}
