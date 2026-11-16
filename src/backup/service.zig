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
    /// Verify by listing only, on any target: no pack is downloaded.
    listing: bool = false,
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
    /// Where it goes, as the configuration says (no secret among them).
    endpoint: []const u8 = "",
    bucket: []const u8 = "",
    prefix: []const u8 = "",
    encrypt: bool = true,
    /// The owner typed the recovery words back (`confirmWords`).
    words_confirmed: bool = false,
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
        list.targets[filled] = try targetState(a, config, .{ .cold = config.storage_class.cold(), .gate = worker.gate(config, roles), .words_confirmed = config.words_confirmed });
        filled += 1;
    }
    return list;
}
fn targetState(a: std.mem.Allocator, config: backup_cfg.Config, state: worker.Status) !TargetState {
    var copies: [5][]const u8 = undefined;
    var copied: usize = 0;
    errdefer for (copies[0..copied]) |text| a.free(text);
    for ([_][]const u8{ config.name, state.snapshot(), config.endpoint, config.bucket, config.prefix }) |text| {
        copies[copied] = try a.dupe(u8, text);
        copied += 1;
    }
    return .{
        .name = copies[0],
        .endpoint = copies[2],
        .bucket = copies[3],
        .prefix = copies[4],
        .encrypt = config.encrypt,
        .words_confirmed = state.words_confirmed,
        .storage_class = config.storage_class,
        .schedule = config.schedule,
        .cold = state.cold,
        .gate = state.gate,
        .not_uploading = state.gate.text(),
        .running = state.running,
        .requested = state.requested,
        .manual_runs = state.manual_runs,
        .last_upload = state.last_upload,
        .snapshot = copies[1],
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
    inline for (.{ "name", "snapshot", "endpoint", "bucket", "prefix" }) |field| a.free(@field(t, field));
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
            const check = if (request.listing) try core.checkListing(request.snapshot) else try core.check(request.snapshot, request.download, request.tier);
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

// ---- Changing the targets ----

const config_file = @import("../config_file.zig");

/// A target a front end asks for. The two keys go into a file of their own
/// (`<name>.credentials` beside the configuration, owner-only), never into
/// the configuration; the caller wipes its copies.
pub const NewTarget = struct {
    /// "": named here (`suggestName`).
    name: []const u8 = "",
    endpoint: []const u8,
    /// "": "auto".
    region: []const u8 = "",
    bucket: []const u8,
    prefix: []const u8 = "",
    /// "" (STANDARD), or a storage class by name.
    storage_class: []const u8 = "",
    /// "" (daily), "daily", "weekly" or "monthly".
    schedule: []const u8 = "",
    encrypt: bool = true,
    access_key_id: []const u8,
    secret_access_key: []const u8,
};
/// Whether a change reached the running node (`live`), or waits for the
/// next start of a node (`saved`).
pub const Applied = enum { live, saved };
pub const Added = struct { name: []const u8, applied: Applied };

/// Words `nomadfs backup` reads as commands: no target is called so.
const reserved_names = [_][]const u8{ "add", "remove", "reload" };
const max_targets = 8;
const max_key_len = 512;

fn plainText(text: []const u8) bool {
    for (text) |c| if (c < 0x20 or c == 0x7f or c == '"' or c == '\\') return false;
    return true;
}
fn noSpace(text: []const u8) bool {
    return plainText(text) and std.mem.indexOfScalar(u8, text, ' ') == null;
}
/// A settings mistake, by the field it is in.
fn validate(new: NewTarget) !void {
    const endpoint = new.endpoint;
    const scheme: usize = if (std.mem.startsWith(u8, endpoint, "https://")) 8 else if (std.mem.startsWith(u8, endpoint, "http://")) 7 else return error.InvalidEndpoint;
    if (endpoint.len == scheme or endpoint.len > 256 or !noSpace(endpoint) or endpoint[scheme] == '/' or endpoint[scheme] == '.') return error.InvalidEndpoint;
    if (new.bucket.len == 0 or new.bucket.len > 255 or !noSpace(new.bucket) or std.mem.indexOfScalar(u8, new.bucket, '/') != null) return error.InvalidBucket;
    if (new.region.len > 64 or !noSpace(new.region)) return error.InvalidRegion;
    if (new.prefix.len > 256 or !plainText(new.prefix) or std.mem.startsWith(u8, new.prefix, "/")) return error.InvalidPrefix;
    if (new.access_key_id.len == 0 or new.access_key_id.len > max_key_len or !noSpace(new.access_key_id) or new.access_key_id[0] == '#') return error.InvalidAccessKey;
    if (new.secret_access_key.len == 0 or new.secret_access_key.len > max_key_len or !noSpace(new.secret_access_key)) return error.InvalidSecretKey;
}

/// "s3" for the first warm target, "archive" for the first cold one, then
/// "s3-2", "archive-2"... The name is in `buf`.
pub fn suggestName(targets: []const backup_cfg.Config, cold: bool, buf: *[32]u8) ![]const u8 {
    const base = if (cold) "archive" else "s3";
    var n: usize = 1;
    while (n <= max_targets + 1) : (n += 1) {
        const name = if (n == 1) base else try std.fmt.bufPrint(buf, "{s}-{d}", .{ base, n });
        const taken = for (targets) |t| {
            if (std.mem.eql(u8, t.name, name)) break true;
        } else false;
        if (!taken) return name;
    }
    return error.TooManyBackupTargets;
}

/// Where `addTarget` keeps the keys of target `name`: beside the
/// configuration file (`~/.nomadfs/<name>.credentials` for the usual one).
/// Absolute: the node may run from another directory than this command.
fn credentialsPath(a: std.mem.Allocator, io: std.Io, config_path: []const u8, name: []const u8) ![]u8 {
    const expanded = try @import("../env.zig").expandHome(a, config_path);
    defer if (expanded) |p| a.free(p);
    const file = try std.fmt.allocPrint(a, "{s}.credentials", .{name});
    defer a.free(file);
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = buf[0..try std.Io.Dir.cwd().realPathFile(io, std.fs.path.dirname(expanded orelse config_path) orelse ".", &buf)];
    return std.fs.path.join(a, &.{ dir, file });
}

/// The running node takes the targets the file lists now; with none
/// running, or when it can't, the next start does.
fn applyTargets(a: std.mem.Allocator, config_path: []const u8, node: ?*Node) Applied {
    const running = node orelse return .saved;
    var cfg = config_mod.parseConfig(a, config_path) catch return .saved;
    defer cfg.deinit(a);
    running.setBackupTargets(cfg.backup_targets) catch |err| {
        std.debug.print("offsite: the new targets apply after a restart: {s}\n", .{@errorName(err)});
        return .saved;
    };
    return .live;
}

/// Adds a `[backup.<name>]` target: checks the settings, writes the two
/// keys to their owner-only file, then the section, and hands the targets
/// to the running `node` (null: none runs here). Nothing is asked of the
/// bucket: the first upload does that. The name returned is the caller's.
pub fn addTarget(a: std.mem.Allocator, io: std.Io, config_path: []const u8, node: ?*Node, new: NewTarget) !Added {
    try validate(new);
    var cfg = try config_mod.parseConfig(a, config_path);
    defer cfg.deinit(a);

    // The settings as the configuration will read them: one validation.
    var target: backup_cfg.Config = .{};
    defer target.deinit(a);
    if (new.storage_class.len > 0) try target.apply(a, "storage_class", new.storage_class);
    if (new.schedule.len > 0) try target.apply(a, "schedule", new.schedule);

    var name_buf: [32]u8 = undefined;
    const name = if (new.name.len > 0) new.name else try suggestName(cfg.backup_targets, target.storage_class.cold(), &name_buf);
    if (!backup_cfg.validName(name)) return error.InvalidBackupTarget;
    for (reserved_names) |word| if (std.mem.eql(u8, word, name)) return error.InvalidBackupTarget;
    if (cfg.backup_targets.len >= max_targets) return error.TooManyBackupTargets;
    for (cfg.backup_targets) |t| {
        if (std.mem.eql(u8, t.name, name)) return error.BackupTargetExists;
        // Two targets on one place would take each other's lease.
        if (std.mem.eql(u8, t.endpoint, new.endpoint) and std.mem.eql(u8, t.bucket, new.bucket) and std.mem.eql(u8, t.prefix, new.prefix)) return error.BackupTargetDuplicate;
    }

    const credentials = try credentialsPath(a, io, config_path, name);
    defer a.free(credentials);
    if (!plainText(credentials)) return error.InvalidPath;

    var lines: std.ArrayList([]const u8) = .empty;
    defer {
        for (lines.items) |line| a.free(line);
        lines.deinit(a);
    }
    for ([_][2][]const u8{ .{ "endpoint", new.endpoint }, .{ "region", new.region }, .{ "bucket", new.bucket }, .{ "prefix", new.prefix }, .{ "credentials", credentials }, .{ "storage_class", new.storage_class }, .{ "schedule", new.schedule } }) |pair| {
        if (pair[1].len == 0) continue;
        try target.apply(a, pair[0], pair[1]);
        const line = try std.fmt.allocPrint(a, "{s} = \"{s}\"", .{ pair[0], pair[1] });
        errdefer a.free(line);
        try lines.append(a, line);
    }
    {
        const line = try std.fmt.allocPrint(a, "encrypt = {}", .{new.encrypt});
        errdefer a.free(line);
        try lines.append(a, line);
    }

    {
        var text: [2 * max_key_len + 64]u8 = undefined;
        defer std.crypto.secureZero(u8, &text);
        const written = try std.fmt.bufPrint(&text, "access_key_id = \"{s}\"\nsecret_access_key = \"{s}\"\n", .{ new.access_key_id, new.secret_access_key });
        try config_file.writeAtomic(a, io, credentials, written);
    }
    // No section names it yet: a failure below leaves no keys behind.
    errdefer std.Io.Dir.cwd().deleteFile(io, credentials) catch {};
    try config_file.editBackup(a, config_path, name, .{ .add = lines.items });

    const owned = try a.dupe(u8, name);
    return .{ .name = owned, .applied = applyTargets(a, config_path, node) };
}

/// Removes the `[backup.<name>]` target from the configuration, and its
/// keys file when `addTarget` wrote it. The bucket and everything in it
/// stay: adding the target again finds the backup as it was.
pub fn removeTarget(a: std.mem.Allocator, io: std.Io, config_path: []const u8, node: ?*Node, name: []const u8) !Applied {
    var cfg = try config_mod.parseConfig(a, config_path);
    defer cfg.deinit(a);
    const target = for (cfg.backup_targets) |t| {
        if (std.mem.eql(u8, t.name, name)) break t;
    } else return error.UnknownBackupTarget;
    try config_file.editBackup(a, config_path, name, .remove);
    const own = try credentialsPath(a, io, config_path, name);
    defer a.free(own);
    // Keys in a file the owner pointed at by hand are theirs to keep.
    if (std.mem.eql(u8, own, target.credentials)) std.Io.Dir.cwd().deleteFile(io, own) catch {};
    return applyTargets(a, config_path, node);
}

/// The owner typed the recovery words of target `name` back: saved in its
/// section (`words_confirmed = true`) and told to the running `node`, so
/// every front end stops warning. The uploader keeps running: nothing it
/// uploads by changes.
pub fn confirmWords(a: std.mem.Allocator, config_path: []const u8, node: ?*Node, name: []const u8) !void {
    try config_file.editBackup(a, config_path, name, .{ .set = .{ .key = "words_confirmed", .line = "words_confirmed = true" } });
    if (node) |running| running.confirmBackupWords(name);
}

const TestConfig = struct {
    tmp: std.testing.TmpDir,
    dir: []u8,
    path: []u8,

    fn init() !TestConfig {
        const a = std.testing.allocator;
        const io = std.testing.io;
        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const dir = try a.dupe(u8, buf[0..try tmp.dir.realPath(io, &buf)]);
        errdefer a.free(dir);
        const conf = try std.fmt.allocPrint(a, "# mine\nnickname = \"desk\"\nswarm_key = \"{s}\"\nkey_path = \"{s}/device.key\"\nstorage_path = \"{s}/blocks\"\n", .{ "ab" ** 32, dir, dir });
        defer a.free(conf);
        try tmp.dir.writeFile(io, .{ .sub_path = "nomadfs.conf", .data = conf });
        return .{ .tmp = tmp, .dir = dir, .path = try std.fs.path.join(a, &.{ dir, "nomadfs.conf" }) };
    }
    fn deinit(self: *TestConfig) void {
        std.testing.allocator.free(self.path);
        std.testing.allocator.free(self.dir);
        self.tmp.cleanup();
    }
    fn text(self: *TestConfig) ![]u8 {
        return self.tmp.dir.readFileAlloc(std.testing.io, "nomadfs.conf", std.testing.allocator, .limited(16384));
    }
};
const test_r2: NewTarget = .{ .endpoint = "https://abc123.r2.cloudflarestorage.com", .region = "auto", .bucket = "nomadfs-swarm", .access_key_id = "AKIDEXAMPLE", .secret_access_key = "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY" };

test "offsite: adding a target writes its keys to an owner-only file and never to the configuration" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    const a = std.testing.allocator;
    const io = std.testing.io;
    var t = try TestConfig.init();
    defer t.deinit();

    const added = try addTarget(a, io, t.path, null, test_r2);
    defer a.free(added.name);
    // The first warm target is "s3"; no node runs here.
    try std.testing.expectEqualStrings("s3", added.name);
    try std.testing.expectEqual(Applied.saved, added.applied);

    const stat = try t.tmp.dir.statFile(io, "s3.credentials", .{});
    try std.testing.expectEqual(@as(u32, 0o600), @as(u32, @intFromEnum(stat.permissions)) & 0o777);
    const text = try t.text();
    defer a.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, test_r2.secret_access_key) == null);
    try std.testing.expect(std.mem.indexOf(u8, text, test_r2.access_key_id) == null);
    try std.testing.expect(std.mem.startsWith(u8, text, "# mine\n"));
    try std.testing.expect(std.mem.indexOf(u8, text, "[backup.s3]\n") != null);

    // The section reads back as asked, and the keys load from their file.
    var cfg = try config_mod.parseConfig(a, t.path);
    defer cfg.deinit(a);
    const target = cfg.backupTarget("s3").?;
    try std.testing.expect(target.configured() and target.encrypt and !target.words_confirmed);
    try std.testing.expectEqualStrings(test_r2.endpoint, target.endpoint);
    try std.testing.expectEqualStrings("nomadfs-swarm", target.bucket);
    try std.testing.expectEqual(StorageClass.STANDARD, target.storage_class);
    var keys = try backup_cfg.loadCredentials(a, io, target.credentials);
    defer keys.deinit(a);
    try std.testing.expectEqualStrings(test_r2.access_key_id, keys.access_key_id);
    try std.testing.expectEqualStrings(test_r2.secret_access_key, keys.secret_access_key);

    // What a status page lists, with no node: where it goes, no secret.
    var all = try overviewOf(a, cfg.backup_targets, .{ .swarm_backup = true });
    defer deinitOverview(a, &all);
    try std.testing.expectEqual(@as(usize, 1), all.targets.len);
    try std.testing.expectEqualStrings(test_r2.endpoint, all.targets[0].endpoint);
    try std.testing.expectEqualStrings("nomadfs-swarm", all.targets[0].bucket);
    try std.testing.expect(all.targets[0].encrypt and !all.targets[0].words_confirmed);
}

test "offsite: a cold target is named archive, later ones are numbered, and names can't clash" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var t = try TestConfig.init();
    defer t.deinit();

    var cold = test_r2;
    cold.endpoint = "https://s3.eu-west-1.amazonaws.com";
    cold.region = "eu-west-1";
    cold.bucket = "nomadfs-archive";
    cold.storage_class = "DEEP_ARCHIVE";
    cold.schedule = "weekly";
    cold.encrypt = false;
    const archive = try addTarget(a, io, t.path, null, cold);
    defer a.free(archive.name);
    try std.testing.expectEqualStrings("archive", archive.name);

    const first = try addTarget(a, io, t.path, null, test_r2);
    defer a.free(first.name);
    var other = test_r2;
    other.bucket = "second";
    const second = try addTarget(a, io, t.path, null, other);
    defer a.free(second.name);
    try std.testing.expectEqualStrings("s3-2", second.name);

    // The same bucket twice, a taken name, a command word.
    try std.testing.expectError(error.BackupTargetDuplicate, addTarget(a, io, t.path, null, test_r2));
    other.bucket = "third";
    other.name = "archive";
    try std.testing.expectError(error.BackupTargetExists, addTarget(a, io, t.path, null, other));
    other.name = "remove";
    try std.testing.expectError(error.InvalidBackupTarget, addTarget(a, io, t.path, null, other));
    other.name = "Has Space";
    try std.testing.expectError(error.InvalidBackupTarget, addTarget(a, io, t.path, null, other));

    var cfg = try config_mod.parseConfig(a, t.path);
    defer cfg.deinit(a);
    try std.testing.expectEqual(@as(usize, 3), cfg.backup_targets.len);
    const kept = cfg.backupTarget("archive").?;
    try std.testing.expectEqual(StorageClass.DEEP_ARCHIVE, kept.storage_class);
    try std.testing.expectEqual(Schedule.weekly, kept.schedule);
    try std.testing.expect(!kept.encrypt);
    // The cold class brings its defaults, as in a section written by hand.
    try std.testing.expectEqual(@as(u32, 256), kept.pack_mb);
}

test "offsite: settings that can't work are refused and leave nothing behind" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var t = try TestConfig.init();
    defer t.deinit();
    const before = try t.text();
    defer a.free(before);

    const Case = struct { field: []const u8, value: []const u8, err: anyerror };
    for ([_]Case{
        .{ .field = "endpoint", .value = "abc.r2.cloudflarestorage.com", .err = error.InvalidEndpoint },
        .{ .field = "endpoint", .value = "https://", .err = error.InvalidEndpoint },
        .{ .field = "endpoint", .value = "https://a b.test", .err = error.InvalidEndpoint },
        .{ .field = "bucket", .value = "", .err = error.InvalidBucket },
        .{ .field = "bucket", .value = "a/b", .err = error.InvalidBucket },
        .{ .field = "bucket", .value = "a\"\n[node]", .err = error.InvalidBucket },
        .{ .field = "region", .value = "eu west", .err = error.InvalidRegion },
        .{ .field = "prefix", .value = "/abs", .err = error.InvalidPrefix },
        .{ .field = "storage_class", .value = "FROZEN", .err = error.InvalidStorageClass },
        .{ .field = "schedule", .value = "hourly", .err = error.InvalidSchedule },
        .{ .field = "access_key_id", .value = "", .err = error.InvalidAccessKey },
        .{ .field = "secret_access_key", .value = "", .err = error.InvalidSecretKey },
        .{ .field = "secret_access_key", .value = "two\nlines", .err = error.InvalidSecretKey },
        .{ .field = "secret_access_key", .value = "quo\"te", .err = error.InvalidSecretKey },
    }) |case| {
        var new = test_r2;
        inline for (@typeInfo(NewTarget).@"struct".fields) |f| {
            if (f.type == []const u8 and std.mem.eql(u8, f.name, case.field)) @field(new, f.name) = case.value;
        }
        try std.testing.expectError(case.err, addTarget(a, io, t.path, null, new));
    }
    const after = try t.text();
    defer a.free(after);
    try std.testing.expectEqualStrings(before, after);
    try std.testing.expectError(error.FileNotFound, t.tmp.dir.statFile(io, "s3.credentials", .{}));
}

test "offsite: removing a target drops its section and its keys file, and keeps keys kept elsewhere" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var t = try TestConfig.init();
    defer t.deinit();

    const added = try addTarget(a, io, t.path, null, test_r2);
    defer a.free(added.name);
    try confirmWords(a, t.path, null, "s3");
    {
        var cfg = try config_mod.parseConfig(a, t.path);
        defer cfg.deinit(a);
        try std.testing.expect(cfg.backupTarget("s3").?.words_confirmed);
    }
    // A section written by hand, its keys where the owner put them.
    try t.tmp.dir.writeFile(io, .{ .sub_path = "mine.keys", .data = "access_key_id = \"id\"\nsecret_access_key = \"secret\"\n", .flags = .{ .permissions = .fromMode(0o600) } });
    const keys = try std.fs.path.join(a, &.{ t.dir, "mine.keys" });
    defer a.free(keys);
    const line = try std.fmt.allocPrint(a, "credentials = \"{s}\"", .{keys});
    defer a.free(line);
    try config_file.editBackup(a, t.path, "hand", .{ .add = &.{ "endpoint = \"https://hand.test\"", "bucket = \"hand\"", line } });

    try std.testing.expectError(error.UnknownBackupTarget, removeTarget(a, io, t.path, null, "nope"));
    try std.testing.expectError(error.UnknownBackupTarget, confirmWords(a, t.path, null, "nope"));
    try std.testing.expectEqual(Applied.saved, try removeTarget(a, io, t.path, null, "s3"));
    try std.testing.expectEqual(Applied.saved, try removeTarget(a, io, t.path, null, "hand"));
    try std.testing.expectError(error.FileNotFound, t.tmp.dir.statFile(io, "s3.credentials", .{}));
    _ = try t.tmp.dir.statFile(io, "mine.keys", .{});

    const text = try t.text();
    defer a.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "[backup.") == null);
    try std.testing.expect(std.mem.indexOf(u8, text, "nomadfs-swarm") == null);
    var cfg = try config_mod.parseConfig(a, t.path);
    defer cfg.deinit(a);
    try std.testing.expectEqual(@as(usize, 0), cfg.backup_targets.len);
    try std.testing.expectEqualStrings("desk", cfg.node.nickname);
}
