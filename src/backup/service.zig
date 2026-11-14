//! Host-facing backup service. Owns configuration, HTTP, identity and node
//! lifetimes so CLI, app and mobile use the same operation entry point.
//!
//! Two ways in, one set of operations (`perform`): `execute` for a process
//! of its own (it reads the configuration, and builds a node for the two
//! operations that read the swarm folder: no node may be running then), and
//! `executeLive` inside the running node, on its uploader's targets and its
//! live swarm folder (the local API and the app call it). There a `run` is
//! handed to the uploader and returns at once: `overview` shows how it went.
const std = @import("std");
const config_mod = @import("../config.zig");
const offsite = @import("../cluster/offsite.zig");
const worker = @import("../cluster/offsite_worker.zig");
const device = @import("../device/mod.zig");
const fs_restore = @import("../fs/restore.zig");
const fs_source = @import("../fs/offsite.zig");
const manifest = @import("../fs/manifest.zig");
const Node = @import("../node.zig").Node;
const s3 = @import("../net/s3/mod.zig");
const backup_cfg = @import("config.zig");
pub const Action = enum { status, run, verify, restore, history, @"recovery-key", forget };
/// How fast a cold target thaws packs: bulk is cheapest and slowest.
pub const Tier = offsite.Tier;
pub const Gate = worker.Gate;
pub const Status = offsite.Status;
pub const Report = offsite.Report;
pub const StorageClass = backup_cfg.StorageClass;
pub const Schedule = backup_cfg.Schedule;
pub const no_archive = worker.no_archive;
pub const versioned_bucket = offsite.versioned_bucket;
pub const Request = struct {
    action: Action,
    /// A `[backup.<name>]` section; null (or "s3" with no such section) is the first.
    target: ?[]const u8 = null,
    config_path: ?[]const u8 = null,
    snapshot: ?[]const u8 = null,
    path: ?[]const u8 = null,
    destination: ?[]const u8 = null,
    recovery_words: ?[]const u8 = null,
    /// Restore from the history instead of a snapshot: also the files no
    /// kept snapshot lists any more.
    from_history: bool = false,
    /// With `from_history`: "latest" (the default), a content id (64 hex
    /// digits), a Unix time or a YYYY-MM-DD day.
    version: ?[]const u8 = null,
    /// Restore, and verify with `download`, on a cold target.
    tier: Tier = .Bulk,
    /// Verify a cold target by reading every block (thaws its packs).
    download: bool = false,
};
/// One version of one file the backup holds. Times are Unix seconds; a
/// seen time of 0 is unknown (uploaded before the history kept them).
pub const FileVersion = struct { path: []const u8, cid: [64]u8, size: u64, mtime: u64, first_seen: u64, last_seen: u64 };
pub const Result = struct {
    report: ?offsite.Report = null,
    /// `history`: every version, by path, oldest first.
    history: ?[]const FileVersion = null,
    status: ?offsite.Status = null,
    restore: ?offsite.Restore = null,
    check: ?offsite.Check = null,
    count: usize = 0,
    recovery_phrase: ?[]const u8 = null,
    /// Whether this device uploads to the target (its backup roles).
    gate: worker.Gate = .uploading,
    /// Deep backup is on and no target is cold: nothing goes to an archive.
    archive_missing: bool = false,
    /// A `run` handed to the running node's uploader.
    started: ?Started = null,
};
/// `name`: the target as `overview` lists it; `manual_runs`: its count of
/// runs by hand at that moment (`TargetState.manual_runs` passes it once
/// this one ended).
pub const Started = struct { name: []const u8, manual_runs: u64 };
/// One target as a status page shows it, from what the running node's
/// uploader knows: the bucket is not asked. Times are Unix seconds.
pub const TargetState = struct {
    name: []const u8,
    storage_class: StorageClass,
    schedule: Schedule,
    /// A GLACIER or DEEP_ARCHIVE target.
    cold: bool,
    gate: Gate,
    /// Why this device doesn't upload to it; "" when it does.
    not_uploading: []const u8,
    /// An upload is under way; `requested`: one asked by hand is about to begin.
    running: bool,
    requested: bool,
    /// Runs asked by hand that ended since the node started.
    manual_runs: u64,
    /// The last upload of this node (0, "": none since it started).
    last_upload: u64,
    snapshot: []const u8,
    uploaded_blocks: usize,
    uploaded_bytes: u64,
    /// Files that upload left out: their blocks were not all here.
    waiting_files: usize,
    /// It made the target's key (`recovery-key` shows the words), or took
    /// another target's.
    new_key: bool,
    reused_key: bool,
    /// The error the last look at the target ended with, by name.
    failure: ?[]const u8,
    /// Packs waiting for their minimum storage time, as that upload found them.
    deferred_packs: usize,
    deferred_first: u64,
    deferred_last: u64,
};
pub const Overview = struct {
    swarm_backup: bool,
    deep_backup: bool,
    /// Deep backup is on and no target is cold: nothing goes to an archive.
    archive_missing: bool,
    targets: []TargetState,
};
/// Every target of the running node's uploader and how its uploads go,
/// with no request to any bucket. Free with `deinitOverview`.
pub fn overview(a: std.mem.Allocator, live: *worker.Worker) !Overview {
    const roles = live.roles();
    const list: Overview = .{ .swarm_backup = roles.swarm_backup, .deep_backup = roles.deep_backup, .archive_missing = live.archiveMissing(), .targets = try a.alloc(TargetState, live.configs.len) };
    var filled: usize = 0;
    errdefer deinitTargets(a, list.targets, filled);
    for (live.configs, list.targets, 0..) |config, *out, i| {
        out.* = try targetState(a, config, live.statusAt(i));
        filled += 1;
    }
    return list;
}
/// `overview` with no node running: the configured targets and whether
/// this device's roles let it upload to each; nothing has run.
pub fn overviewOf(a: std.mem.Allocator, targets: []const backup_cfg.Config, roles: worker.Roles) !Overview {
    var wanted: usize = 0;
    for (targets) |t| wanted += @intFromBool(t.configured());
    var list: Overview = .{ .swarm_backup = roles.swarm_backup, .deep_backup = roles.deep_backup, .archive_missing = roles.deep_backup and !worker.hasArchive(targets), .targets = try a.alloc(TargetState, wanted) };
    var filled: usize = 0;
    errdefer deinitTargets(a, list.targets, filled);
    for (targets) |config| {
        if (!config.configured()) continue;
        list.targets[filled] = try targetState(a, config, .{ .cold = config.storage_class.cold(), .gate = worker.gate(config, roles) });
        filled += 1;
    }
    return list;
}
fn targetState(a: std.mem.Allocator, config: backup_cfg.Config, state: worker.Status) !TargetState {
    const name = try a.dupe(u8, config.name);
    errdefer a.free(name);
    return .{
        .name = name,
        .storage_class = config.storage_class,
        .schedule = config.schedule,
        .cold = state.cold,
        .gate = state.gate,
        .not_uploading = state.gate.text(),
        .running = state.running,
        .requested = state.requested,
        .manual_runs = state.manual_runs,
        .last_upload = state.last_upload,
        .snapshot = try a.dupe(u8, state.snapshot()),
        .uploaded_blocks = state.uploaded_blocks,
        .uploaded_bytes = state.uploaded_bytes,
        .waiting_files = state.waiting_files,
        .new_key = state.new_key,
        .reused_key = state.reused_key,
        .failure = if (state.failure) |err| @errorName(err) else null,
        .deferred_packs = state.deferred_packs,
        .deferred_first = state.deferred_first,
        .deferred_last = state.deferred_last,
    };
}
fn deinitTargets(a: std.mem.Allocator, targets: []TargetState, filled: usize) void {
    for (targets[0..filled]) |t| freeTarget(a, t);
    a.free(targets);
}
fn freeTarget(a: std.mem.Allocator, t: TargetState) void {
    a.free(t.name);
    a.free(t.snapshot);
}
pub fn deinitOverview(a: std.mem.Allocator, o: *Overview) void {
    deinitTargets(a, o.targets, o.targets.len);
    o.targets = &.{};
}
/// What an operation runs on, whichever way it came in.
const Env = struct {
    targets: []const backup_cfg.Config,
    target: backup_cfg.Config,
    roles: worker.Roles,
    identity: device.identity.Identity,
    /// The swarm folder `run` and `forget` read: the running node's
    /// uploader, or the configuration a node is built from for the call.
    folder: union(enum) { live: *worker.Worker, config: config_mod.Config },
    /// Cleared when the host stops: a session under way ends (Cancelled).
    keep_going: ?*const std.atomic.Value(bool) = null,
    transport: ?s3.Transport = null,
};
/// Returned strings and lists are copied into the caller's allocator.
pub fn execute(a: std.mem.Allocator, io: std.Io, request: Request) !Result {
    const path = if (request.config_path) |p| try a.dupe(u8, p) else try config_mod.findConfigPath(a);
    defer a.free(path);
    var cfg = try config_mod.parseConfig(a, path);
    defer cfg.deinit(a);
    if (cfg.backup_targets.len == 0) return error.BackupNotConfigured;
    const target = cfg.backupTarget(request.target) orelse return error.UnknownBackupTarget;
    var paths = try device.paths.Paths.resolve(a, cfg.node.key_path);
    defer paths.deinit(a);
    return perform(a, io, .{
        .targets = cfg.backup_targets,
        .target = target.*,
        .roles = .{ .swarm_backup = cfg.storage.swarm_backup, .deep_backup = cfg.storage.deep_backup },
        .identity = try device.identity.Identity.loadOrCreate(paths.identity),
        .folder = .{ .config = cfg },
    }, request);
}
/// `execute` inside the running node: on the targets of its uploader
/// `live`, with its roles as they are now and its live swarm folder. A
/// `run` is handed to the uploader (`Result.started`); `keep_going`, once
/// false, ends an operation under way. The request's `config_path` is unused.
pub fn executeLive(a: std.mem.Allocator, io: std.Io, live: *worker.Worker, request: Request, keep_going: ?*const std.atomic.Value(bool)) !Result {
    const i = live.indexOf(request.target) orelse return error.UnknownBackupTarget;
    return perform(a, io, .{
        .targets = live.configs,
        .target = live.configs[i],
        .roles = live.roles(),
        .identity = live.identity,
        .folder = .{ .live = live },
        .keep_going = keep_going,
        .transport = live.transport,
    }, request);
}
fn perform(a: std.mem.Allocator, io: std.Io, env: Env, request: Request) !Result {
    const allowed = worker.gate(env.target, env.roles);
    // An archive takes the whole swarm backup or nothing: only a deep
    // backup device writes to it, also when asked by hand.
    if (request.action == .run and allowed == .needs_deep_backup) return error.DeepBackupOff;
    if (request.action == .run) switch (env.folder) {
        // The node's uploader holds the lease and the folder: it runs.
        .live => |live| {
            const name = try a.dupe(u8, env.target.name);
            errdefer a.free(name);
            return .{ .started = .{ .name = name, .manual_runs = try live.request(live.indexOf(name).?) } };
        },
        .config => {},
    };
    var session: worker.Session = undefined;
    try session.openOn(a, io, env.target, env.identity, env.transport);
    defer session.close();
    const core = &session.service;
    core.keep_going = env.keep_going;
    if (request.action == .run) {
        worker.shareKey(a, io, core, env.targets, env.identity, env.transport);
        return run(a, core, env.folder.config);
    }
    if (request.action == .forget) {
        const doomed = request.path orelse return error.PathRequired;
        if (!manifest.validPath(doomed)) return error.InvalidPath;
        try core.unlock(request.recovery_words);
        switch (env.folder) {
            .live => |live| try core.forget(doomed, live.source),
            .config => |cfg| try forget(a, core, cfg, doomed),
        }
        return .{};
    }
    try core.unlock(request.recovery_words);
    switch (request.action) {
        .status => {
            var status = try core.status();
            const names = try a.alloc([]const u8, status.snapshots.len);
            errdefer a.free(names);
            var initialized: usize = 0;
            errdefer for (names[0..initialized]) |n| a.free(n);
            for (status.snapshots, names) |n, *copy| {
                copy.* = try a.dupe(u8, n);
                initialized += 1;
            }
            status.snapshots = names;
            return .{ .status = status, .gate = allowed, .archive_missing = env.roles.deep_backup and !worker.hasArchive(env.targets) };
        },
        .verify => {
            const check = try core.check(request.snapshot, request.download, request.tier);
            return .{ .check = check, .count = check.blocks };
        },
        .restore => {
            const destination = request.destination orelse return error.DestinationRequired;
            try std.Io.Dir.cwd().createDirPath(io, destination);
            const dir = try std.Io.Dir.cwd().openDir(io, destination, .{ .follow_symlinks = false });
            defer dir.close(io);
            const from: fs_restore.From = if (request.from_history) .{ .history = try fs_restore.parseVersion(request.version) } else .{ .snapshot = request.snapshot orelse return error.SnapshotRequired };
            const restored = try fs_restore.restore(a, io, core, .{ .from = from, .path = request.path, .tier = request.tier }, dir);
            return .{ .restore = restored, .count = restored.files };
        },
        .history => {
            if (request.path) |p| if (!manifest.validPath(p)) return error.InvalidPath;
            const versions = try core.history(request.path);
            const list = try a.alloc(FileVersion, versions.len);
            errdefer a.free(list);
            var copied: usize = 0;
            errdefer for (list[0..copied]) |v| a.free(v.path);
            for (versions, list) |v, *out| {
                out.* = .{ .path = try a.dupe(u8, v.path), .cid = std.fmt.bytesToHex(v.cid, .lower), .size = v.size, .mtime = v.mtime, .first_seen = v.first_seen, .last_seen = v.last_seen };
                copied += 1;
            }
            std.mem.sort(FileVersion, list, {}, olderVersion);
            return .{ .history = list, .count = list.len };
        },
        .@"recovery-key" => return .{ .recovery_phrase = try a.dupe(u8, try core.recoveryKey()) },
        .run, .forget => unreachable,
    }
}
fn olderVersion(_: void, x: FileVersion, y: FileVersion) bool {
    return switch (std.mem.order(u8, x.path, y.path)) {
        .lt => true,
        .gt => false,
        .eq => if (x.first_seen != y.first_seen) x.first_seen < y.first_seen else x.last_seen < y.last_seen,
    };
}
fn run(a: std.mem.Allocator, core: *offsite.Service, cfg: config_mod.Config) !Result {
    // Uses the node's public composition root: shares/external leaves and the
    // swarm manifest are wired exactly as for the keeper. The node lock makes
    // a standalone run refuse simultaneous access by a running node process.
    var node = try Node.init(a, cfg);
    defer node.deinit();
    var source: fs_source.Source = .{ .folder = node.swarm orelse return error.StorageRequired, .store = node.store orelse return error.StorageRequired };
    var report = try core.run(source.source(), source.store);
    try worker.enroll(core, node.trust_store);
    report.snapshot = try a.dupe(u8, report.snapshot);
    errdefer a.free(report.snapshot);
    if (report.recovery_phrase) |phrase| report.recovery_phrase = try a.dupe(u8, phrase);
    return .{ .report = report };
}
/// The purge names the versions the folder lists at this moment (also the
/// ones still waiting for blocks), so it reads the swarm manifest through
/// the node's composition root, like a run by hand: with no node running.
/// A running node purges through its own folder (`executeLive`).
fn forget(a: std.mem.Allocator, core: *offsite.Service, cfg: config_mod.Config, path: []const u8) !void {
    var node = try Node.init(a, cfg);
    defer node.deinit();
    var source: fs_source.Source = .{ .folder = node.swarm orelse return error.StorageRequired, .store = node.store orelse return error.StorageRequired };
    try core.forget(path, source.source());
}
pub fn deinitResult(a: std.mem.Allocator, result: *Result) void {
    if (result.started) |s| a.free(s.name);
    if (result.report) |r| {
        a.free(r.snapshot);
        if (r.recovery_phrase) |p| {
            std.crypto.secureZero(u8, @constCast(p));
            a.free(p);
        }
    }
    if (result.status) |s| {
        for (s.snapshots) |n| a.free(n);
        a.free(s.snapshots);
    }
    if (result.history) |versions| {
        for (versions) |v| a.free(v.path);
        a.free(versions);
    }
    if (result.recovery_phrase) |p| {
        std.crypto.secureZero(u8, @constCast(p));
        a.free(p);
    }
    if (result.restore) |*r| r.deinit(a);
}
