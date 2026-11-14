//! CLI parsing and presentation only; backup/service.zig owns operations.
//! With a node running, status, run, history and forget go to it through
//! the local API (swarm_api.zig): its uploader holds the swarm folder and
//! the bucket's lease. The others, and all of them with no node running,
//! run here (`service.execute`).
const std = @import("std");
const nomadfs = @import("nomadfs");
const service = nomadfs.backup_service;
const swarm_api = nomadfs.swarm_api;
const swarm_cli = @import("swarm_cli.zig");
const usage = "nomadfs backup <target> status|run|verify|restore|history|recovery-key|forget [options]\n" ++
    "  <target>                      a [backup.<target>] section of the configuration (s3: the first)\n" ++
    "  --config FILE                 configuration file\n" ++
    "  --snapshot snapshots/ID       verify/restore snapshot (status lists IDs)\n" ++
    "  --path PATH                   restore (or list the history of) one path or subtree\n" ++
    "  history                       every file version the backup holds, also deleted files\n" ++
    "  --from-history                restore from the history instead of a snapshot\n" ++
    "  --version latest|DATE|TIME|ID  with --from-history: YYYY-MM-DD, Unix time or content id\n" ++
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
        if (std.mem.eql(u8, arg, "--from-history")) {
            request.from_history = true;
            continue;
        }
        if (i + 1 >= args.len) return error.InvalidArguments;
        i += 1;
        if (std.mem.eql(u8, arg, "--config")) request.config_path = args[i] else if (std.mem.eql(u8, arg, "--snapshot")) request.snapshot = args[i] else if (std.mem.eql(u8, arg, "--path")) request.path = args[i] else if (std.mem.eql(u8, arg, "--to")) request.destination = args[i] else if (std.mem.eql(u8, arg, "--recovery-words")) request.recovery_words = args[i] else if (std.mem.eql(u8, arg, "--version")) request.version = args[i] else if (std.mem.eql(u8, arg, "--tier")) request.tier = parseTier(args[i]) orelse return error.InvalidArguments else return error.InvalidArguments;
    }
    // A restore names exactly one source: a snapshot or the history.
    if (request.action == .restore and (request.destination == null or (request.snapshot == null) != request.from_history)) return error.InvalidArguments;
    if (request.from_history and request.action != .restore) return error.InvalidArguments;
    if (request.version != null and !request.from_history) return error.InvalidArguments;
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
/// Where a command runs.
pub const Route = enum { node, here };
/// The running node takes what it does itself (uploads) or holds the
/// swarm folder for (a purge names the folder's versions), and answers
/// the two read-only questions it can; restores, verifications and the
/// recovery words need neither. Recovery words given on the command line
/// never leave this process.
pub fn route(request: service.Request, node_running: bool) Route {
    if (!node_running or request.recovery_words != null) return .here;
    return switch (request.action) {
        .status, .run, .history, .forget => .node,
        .verify, .restore, .@"recovery-key" => .here,
    };
}
/// The running node's API, from the device files the configuration names;
/// null when none is published.
fn findNode(arena: std.mem.Allocator, io: std.Io, request: service.Request) ?swarm_cli.Endpoint {
    const config = nomadfs.config;
    const path = request.config_path orelse (config.findConfigPath(arena) catch return null);
    var cfg = config.parseConfig(arena, path) catch return null;
    defer cfg.deinit(arena);
    const key_path = if (cfg.node.key_path) |k| arena.dupe(u8, k) catch return null else null;
    return swarm_cli.findEndpoint(arena, io, key_path) catch null;
}
const Answer = union(enum) {
    /// As `service.execute` returns it: freed with `service.deinitResult`.
    result: service.Result,
    /// The node's error, by name.
    failed: []const u8,
    /// No node answered, or this one can't say: the command runs here.
    absent,
};
/// How often a `run` asks the node whether the upload ended.
const poll_ms = 1000;
/// One command through the running node. `a` owns the result, `arena`
/// everything else.
fn askNode(a: std.mem.Allocator, arena: std.mem.Allocator, io: std.Io, ep: swarm_cli.Endpoint, request: service.Request) !Answer {
    const target = request.target.?;
    var query: std.Io.Writer.Allocating = .init(arena);
    if (request.path) |p| {
        try query.writer.writeAll("path=");
        try swarm_cli.writeEncoded(&query.writer, p);
    }
    const method: []const u8, const path = switch (request.action) {
        .status => .{ "GET", try std.fmt.allocPrint(arena, "backup/{s}", .{target}) },
        .history => .{ "GET", try std.fmt.allocPrint(arena, "backup/{s}/history", .{target}) },
        .run => .{ "POST", try std.fmt.allocPrint(arena, "backup/{s}/run", .{target}) },
        .forget => .{ "POST", try std.fmt.allocPrint(arena, "backup/{s}/forget", .{target}) },
        else => unreachable, // `route` keeps them here
    };
    const r = swarm_cli.send(arena, ep, method, path, query.written(), &.{}, "") catch |err| {
        // A stale api.json, or an answer too long for one response (a
        // long history): what only reads is asked of the bucket from here.
        if (err == error.NodeNotRunning or request.action == .status or request.action == .history) return .absent;
        return .{ .failed = @errorName(err) };
    };
    if (r.code >= 300) {
        const name = r.err orelse "BadResponse";
        // A node that uploads nowhere (or started before this target was
        // configured) still lets the bucket be read from here.
        const unknown = std.mem.eql(u8, name, "BackupNotConfigured") or std.mem.eql(u8, name, "UnknownBackupTarget");
        if (unknown and (request.action == .status or request.action == .history)) return .absent;
        return .{ .failed = name };
    }
    const json: std.json.ParseOptions = .{ .ignore_unknown_fields = true };
    switch (request.action) {
        .forget => return .{ .result = .{} },
        .status => {
            const s = std.json.parseFromSliceLeaky(swarm_api.BackupStatus, arena, r.body, json) catch return .{ .failed = "BadResponse" };
            const names = try a.alloc([]const u8, s.snapshots.len);
            var copied: usize = 0;
            errdefer {
                for (names[0..copied]) |n| a.free(n);
                a.free(names);
            }
            for (s.snapshots, names) |n, *copy| {
                copy.* = try a.dupe(u8, n);
                copied += 1;
            }
            return .{ .result = .{
                .status = .{ .snapshots = names, .indexed_blocks = s.indexed_blocks, .storage_class = s.storage_class, .schedule = s.schedule, .deferred_packs = s.deferred_packs, .deferred_first = s.deferred_first, .deferred_last = s.deferred_last },
                .gate = s.gate,
                .archive_missing = s.archive_missing,
            } };
        },
        .history => {
            const versions = std.json.parseFromSliceLeaky([]const swarm_api.BackupVersion, arena, r.body, json) catch return .{ .failed = "BadResponse" };
            const list = try a.alloc(service.FileVersion, versions.len);
            var copied: usize = 0;
            errdefer {
                for (list[0..copied]) |v| a.free(v.path);
                a.free(list);
            }
            for (versions, list) |v, *out| {
                if (v.cid.len != 64) return .{ .failed = "BadResponse" };
                out.* = .{ .path = try a.dupe(u8, v.path), .cid = v.cid[0..64].*, .size = v.size, .mtime = v.mtime, .first_seen = v.first_seen, .last_seen = v.last_seen };
                copied += 1;
            }
            return .{ .result = .{ .history = list, .count = list.len } };
        },
        .run => {
            const started = std.json.parseFromSliceLeaky(swarm_api.BackupRun, arena, r.body, json) catch return .{ .failed = "BadResponse" };
            // The upload takes as long as it takes, like one run here.
            while (true) {
                nomadfs.sync.sleep(poll_ms * std.time.ns_per_ms);
                const state = (try runState(arena, ep, started.name)) orelse return .{ .failed = "NodeStopped" };
                if (state.manual_runs <= started.manual_runs) continue;
                if (state.failure) |name| return .{ .failed = name };
                return .{ .result = try runResult(a, io, request, state) };
            }
        },
        else => unreachable,
    }
}
/// The node's state of target `name` now; null when it answers no more.
fn runState(arena: std.mem.Allocator, ep: swarm_cli.Endpoint, name: []const u8) !?service.TargetState {
    const r = swarm_cli.request(arena, ep, "GET", "backup", &.{}, "") catch return null;
    if (r.code >= 300) return null;
    const all = std.json.parseFromSliceLeaky(service.Overview, arena, r.body, .{ .ignore_unknown_fields = true }) catch return null;
    for (all.targets) |t| if (std.mem.eql(u8, t.name, name)) return t;
    return null;
}
/// What a run here would have returned, from the node's state after its
/// upload. Words of a key the upload made are read from the bucket here.
fn runResult(a: std.mem.Allocator, io: std.Io, request: service.Request, state: service.TargetState) !service.Result {
    const snapshot = try a.dupe(u8, state.snapshot);
    errdefer a.free(snapshot);
    var report: service.Report = .{ .uploaded_blocks = state.uploaded_blocks, .uploaded_bytes = state.uploaded_bytes, .snapshot = snapshot, .reused_key = state.reused_key, .waiting_files = state.waiting_files };
    if (state.new_key) {
        var words = service.execute(a, io, .{ .action = .@"recovery-key", .target = request.target, .config_path = request.config_path }) catch |err| {
            std.debug.print("The upload made this target's recovery words; reading them failed ({s}): `nomadfs backup {s} recovery-key` shows them\n", .{ @errorName(err), request.target.? });
            return .{ .report = report };
        };
        // Moved into the report: `deinitResult` wipes and frees it there.
        report.recovery_phrase = words.recovery_phrase;
        words.recovery_phrase = null;
        service.deinitResult(a, &words);
    }
    return .{ .report = report };
}
fn printFailure(target: []const u8, name: []const u8) void {
    const eql = std.mem.eql;
    if (eql(u8, name, "DeepBackupOff")) {
        std.debug.print("Backup \"{s}\" {s} (deep_backup = true, or Settings → Deep backup in the app)\n", .{ target, service.Gate.needs_deep_backup.text() });
    } else if (eql(u8, name, "BucketVersioningEnabled")) {
        std.debug.print("Backup \"{s}\" refused: {s}\n", .{ target, service.versioned_bucket });
    } else std.debug.print("Backup \"{s}\" failed: {s}\n", .{ target, name });
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
    var arena_state = std.heap.ArenaAllocator.init(a);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const node = findNode(arena, io, request);
    const answer: Answer = if (route(request, node != null) == .node) try askNode(a, arena, io, node.?, request) else .absent;
    var result = switch (answer) {
        .result => |r| r,
        .failed => |name| {
            printFailure(request.target.?, name);
            if (std.mem.eql(u8, name, "BackupNotConfigured") or std.mem.eql(u8, name, "UnknownBackupTarget")) std.debug.print("The running node read its configuration when it started: restart it after a change.\n", .{});
            return 1;
        },
        .absent => service.execute(a, io, request) catch |err| {
            printFailure(request.target.?, @errorName(err));
            return 1;
        },
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
    if (result.history) |versions| {
        for (versions) |v| {
            var first: [10]u8 = undefined;
            var last: [10]u8 = undefined;
            var changed: [10]u8 = undefined;
            std.debug.print("{s}  {d} bytes  modified {s}  seen {s} to {s}  {s}\n", .{ v.path, v.size, date(v.mtime, &changed), if (v.first_seen == 0) "?" else date(v.first_seen, &first), if (v.last_seen == 0) "?" else date(v.last_seen, &last), v.cid });
        }
        std.debug.print("{d} file versions\n", .{versions.len});
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
        if (restored.purged_files > 0) std.debug.print("{d} files were deleted from the backup after this restore began and were left out\n", .{restored.purged_files});
        if (restored.thawing_packs > 0) printThaw(restored.thawing_packs, restored.thawing_bytes, request.tier);
    }
    if (request.action == .forget) std.debug.print("Purge recorded; the next run removes this path from offsite history and packs.\n", .{});
    return 0;
}
test "backup CLI: a running node takes status, run, history and forget; the rest run here" {
    const t = std.testing;
    for ([_][]const []const u8{ &.{ "s3", "status" }, &.{ "s3", "run" }, &.{ "s3", "history", "--path", "Photos" }, &.{ "s3", "forget", "Photos/a.jpg" } }) |args| {
        const request = try parse(args);
        try t.expectEqual(Route.node, route(request, true));
        // No api.json (or none that answers): as before.
        try t.expectEqual(Route.here, route(request, false));
    }
    for ([_][]const []const u8{ &.{ "s3", "verify" }, &.{ "s3", "recovery-key" }, &.{ "s3", "restore", "--snapshot", "snapshots/x", "--to", "/tmp/r" } }) |args| {
        try t.expectEqual(Route.here, route(try parse(args), true));
    }
    // The words stay in this process.
    try t.expectEqual(Route.here, route(try parse(&.{ "s3", "status", "--recovery-words", "a b c" }), true));
}
test "backup CLI: with no api.json, or one nothing listens behind, the command runs here" {
    const t = std.testing;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = buf[0..try tmp.dir.realPath(t.io, &buf)];
    const config_path = try std.fs.path.join(arena, &.{ dir, "nomadfs.toml" });
    try tmp.dir.writeFile(t.io, .{ .sub_path = "nomadfs.toml", .data = try std.fmt.allocPrint(arena, "[node]\nnickname = \"desk\"\nswarm_key = \"{s}\"\nkey_path = \"{s}/device.key\"\n[storage]\nstorage_path = \"{s}/blocks\"\n[network]\nport = 9000\n", .{ "ab" ** 32, dir, dir }) });
    const request: service.Request = .{ .action = .forget, .target = "s3", .path = "a.txt", .config_path = config_path };
    try t.expect(findNode(arena, t.io, request) == null);

    // A node that died without removing its api.json: found, not answering.
    const listener = try nomadfs.net.compat.listenLoopback(0);
    const port = listener.inner.socket.address.getPort();
    var closing = listener;
    closing.deinit();
    const f = try tmp.dir.createFile(t.io, swarm_api.api_file, .{ .permissions = .fromMode(0o600) });
    try f.writeStreamingAll(t.io, try std.fmt.allocPrint(arena, "{{\"version\":1,\"url\":\"http://127.0.0.1:{d}/{s}/v1/\"}}", .{ port, "ab" ** 32 }));
    f.close(t.io);
    const ep = findNode(arena, t.io, request) orelse return error.TestExpectedEndpoint;
    try t.expectEqual(port, ep.port);
    try t.expectEqual(Route.node, route(request, true));
    try t.expect(try askNode(t.allocator, arena, t.io, ep, request) == .absent);
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
    const h = try parse(&.{ "s3", "history", "--path", "Photos" });
    try std.testing.expectEqual(service.Action.history, h.action);
    try std.testing.expectEqualStrings("Photos", h.path.?);
    const old = try parse(&.{ "s3", "restore", "--from-history", "--path", "Photos/a.jpg", "--version", "2026-11-01", "--to", "/tmp/restore" });
    try std.testing.expect(old.from_history and old.snapshot == null);
    try std.testing.expectEqualStrings("2026-11-01", old.version.?);
    try std.testing.expectError(error.InvalidArguments, parse(&.{ "s3", "restore", "--from-history", "--snapshot", "snapshots/test", "--to", "/tmp/restore" }));
    try std.testing.expectError(error.InvalidArguments, parse(&.{ "s3", "restore", "--snapshot", "snapshots/test", "--version", "latest", "--to", "/tmp/restore" }));
    try std.testing.expectError(error.InvalidArguments, parse(&.{ "s3", "status", "--from-history" }));
    try std.testing.expectError(error.InvalidArguments, parse(&.{ "status", "--config" }));
    try std.testing.expectError(error.InvalidArguments, parse(&.{ "--config", "status" }));
}
