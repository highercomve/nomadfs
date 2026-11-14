//! Host-facing backup service. Owns configuration, HTTP, identity and node
//! lifetimes so CLI, app and mobile use the same operation entry point.
const std = @import("std");
const config_mod = @import("../config.zig");
const offsite = @import("../cluster/offsite.zig");
const worker = @import("../cluster/offsite_worker.zig");
const device = @import("../device/mod.zig");
const Node = @import("../node.zig").Node;
pub const Action = enum { status, run, verify, restore, @"recovery-key", forget };
/// How fast a cold target thaws packs: bulk is cheapest and slowest.
pub const Tier = offsite.Tier;
pub const Gate = worker.Gate;
pub const no_archive = worker.no_archive;
pub const Request = struct {
    action: Action,
    /// A `[backup.<name>]` section; null (or "s3" with no such section) is the first.
    target: ?[]const u8 = null,
    config_path: ?[]const u8 = null,
    snapshot: ?[]const u8 = null,
    path: ?[]const u8 = null,
    destination: ?[]const u8 = null,
    recovery_words: ?[]const u8 = null,
    /// Restore, and verify with `download`, on a cold target.
    tier: Tier = .Bulk,
    /// Verify a cold target by reading every block (thaws its packs).
    download: bool = false,
};
pub const Result = struct {
    report: ?offsite.Report = null,
    status: ?offsite.Status = null,
    restore: ?offsite.Restore = null,
    check: ?offsite.Check = null,
    count: usize = 0,
    recovery_phrase: ?[]const u8 = null,
    /// Whether this device uploads to the target (its backup roles).
    gate: worker.Gate = .uploading,
    /// Deep backup is on and no target is cold: nothing goes to an archive.
    archive_missing: bool = false,
};
/// Returned strings and lists are copied into the caller's allocator.
pub fn execute(a: std.mem.Allocator, io: std.Io, request: Request) !Result {
    const path = if (request.config_path) |p| try a.dupe(u8, p) else try config_mod.findConfigPath(a);
    defer a.free(path);
    var cfg = try config_mod.parseConfig(a, path);
    defer cfg.deinit(a);
    if (cfg.backup_targets.len == 0) return error.BackupNotConfigured;
    const target = cfg.backupTarget(request.target) orelse return error.UnknownBackupTarget;
    const roles: worker.Roles = .{ .swarm_backup = cfg.storage.swarm_backup, .deep_backup = cfg.storage.deep_backup };
    const allowed = worker.gate(target.*, roles);
    // An archive takes the whole swarm backup or nothing: only a deep
    // backup device writes to it, also when asked by hand.
    if (request.action == .run and allowed == .needs_deep_backup) return error.DeepBackupOff;
    var paths = try device.paths.Paths.resolve(a, cfg.node.key_path);
    defer paths.deinit(a);
    const identity = try device.identity.Identity.loadOrCreate(paths.identity);
    var session: worker.Session = undefined;
    try session.open(a, io, target.*, identity);
    defer session.close();
    const core = &session.service;
    if (request.action == .run) {
        worker.shareKey(a, io, core, cfg.backup_targets, identity);
        return run(a, core, cfg);
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
            return .{ .status = status, .gate = allowed, .archive_missing = roles.deep_backup and !worker.hasArchive(cfg.backup_targets) };
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
            const restored = try core.restoreRequest(io, request.snapshot orelse return error.SnapshotRequired, request.path, dir, request.tier);
            return .{ .restore = restored, .count = restored.files };
        },
        .@"recovery-key" => return .{ .recovery_phrase = try a.dupe(u8, try core.recoveryKey()) },
        .forget => {
            try core.forget(request.path orelse return error.PathRequired);
            return .{};
        },
        .run => unreachable,
    }
}
fn run(a: std.mem.Allocator, core: *offsite.Service, cfg: config_mod.Config) !Result {
    // Uses the node's public composition root: shares/external leaves and the
    // swarm manifest are wired exactly as for the keeper. The node lock makes
    // a standalone run refuse simultaneous access by a running node process.
    var node = try Node.init(a, cfg);
    defer node.deinit();
    var source: @import("../fs/offsite.zig").Source = .{ .folder = node.swarm orelse return error.StorageRequired, .store = node.store orelse return error.StorageRequired };
    var report = try core.run(source.source(), source.store);
    try worker.enroll(core, node.trust_store);
    report.snapshot = try a.dupe(u8, report.snapshot);
    errdefer a.free(report.snapshot);
    if (report.recovery_phrase) |phrase| report.recovery_phrase = try a.dupe(u8, phrase);
    return .{ .report = report };
}
pub fn deinitResult(a: std.mem.Allocator, result: *Result) void {
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
    if (result.recovery_phrase) |p| {
        std.crypto.secureZero(u8, @constCast(p));
        a.free(p);
    }
}
