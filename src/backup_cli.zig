//! CLI parsing and presentation only; backup/service.zig owns operations.
const std = @import("std");
const service = @import("nomadfs").backup_service;
const usage = "nomadfs backup s3 status|run|verify|restore|recovery-key|forget [options]\n" ++
    "  --config FILE                 configuration file\n" ++
    "  --snapshot snapshots/ID       verify/restore snapshot (status lists IDs)\n" ++
    "  --path PATH                   restore one path or subtree\n" ++
    "  --to DIRECTORY                restore destination\n" ++
    "  --recovery-words WORDS         unlock with quoted 24 words\n" ++
    "  forget PATH                   queue permanent offsite purge for next run\n";
pub fn parse(args: []const []const u8) !service.Request {
    if (args.len < 2 or !std.mem.eql(u8, args[0], "s3")) return error.InvalidArguments;
    var request: service.Request = .{ .action = std.meta.stringToEnum(service.Action, args[1]) orelse return error.InvalidArguments };
    var i: usize = 2;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (request.action == .forget and request.path == null and !std.mem.startsWith(u8, arg, "--")) {
            request.path = arg;
            continue;
        }
        if (i + 1 >= args.len) return error.InvalidArguments;
        i += 1;
        if (std.mem.eql(u8, arg, "--config")) request.config_path = args[i] else if (std.mem.eql(u8, arg, "--snapshot")) request.snapshot = args[i] else if (std.mem.eql(u8, arg, "--path")) request.path = args[i] else if (std.mem.eql(u8, arg, "--to")) request.destination = args[i] else if (std.mem.eql(u8, arg, "--recovery-words")) request.recovery_words = args[i] else return error.InvalidArguments;
    }
    if (request.action == .restore and (request.snapshot == null or request.destination == null)) return error.InvalidArguments;
    if (request.action == .forget and request.path == null) return error.InvalidArguments;
    return request;
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
        std.debug.print("S3 backup failed: {s}\n", .{@errorName(err)});
        return 1;
    };
    defer service.deinitResult(a, &result);
    if (result.status) |status| {
        std.debug.print("{d} indexed blocks; {d} snapshots\n", .{ status.indexed_blocks, status.snapshots.len });
        for (status.snapshots) |name| std.debug.print("{s}\n", .{name});
    }
    if (result.report) |report| {
        std.debug.print("Uploaded {d} new blocks ({d} bytes)\nSnapshot: {s}\n", .{ report.uploaded_blocks, report.uploaded_bytes, report.snapshot });
        if (report.recovery_phrase) |phrase| std.debug.print("Save these recovery words:\n{s}\n", .{phrase});
    }
    if (result.recovery_phrase) |phrase| std.debug.print("{s}\n", .{phrase});
    if (request.action == .verify) std.debug.print("Verified {d} blocks\n", .{result.count});
    if (request.action == .restore) std.debug.print("Restored {d} files\n", .{result.count});
    if (request.action == .forget) std.debug.print("Purge recorded; the next run removes this path from offsite history and packs.\n", .{});
    return 0;
}
test "backup CLI: parse restore and forget" {
    const r = try parse(&.{ "s3", "restore", "--snapshot", "snapshots/test", "--to", "/tmp/restore", "--path", "Photos/a.jpg" });
    try std.testing.expectEqual(service.Action.restore, r.action);
    try std.testing.expectEqualStrings("Photos/a.jpg", r.path.?);
    const f = try parse(&.{ "s3", "forget", "Photos/a.jpg" });
    try std.testing.expectEqual(service.Action.forget, f.action);
    try std.testing.expectError(error.InvalidArguments, parse(&.{ "s3", "restore" }));
}
