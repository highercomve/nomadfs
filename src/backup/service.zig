//! Host-facing backup service. Owns configuration, HTTP, identity and node
//! lifetimes so CLI, app and mobile use the same operation entry point.
const std = @import("std");
const config_mod = @import("../config.zig");
const credentials_mod = @import("config.zig");
const offsite = @import("../cluster/offsite.zig");
const device = @import("../device/mod.zig");
const s3 = @import("../net/s3/mod.zig");
const Node = @import("../node.zig").Node;
pub const Action = enum { status, run, verify, restore, @"recovery-key", forget };
pub const Request = struct {
    action: Action,
    config_path: ?[]const u8 = null,
    snapshot: ?[]const u8 = null,
    path: ?[]const u8 = null,
    destination: ?[]const u8 = null,
    recovery_words: ?[]const u8 = null,
};
pub const Result = struct {
    report: ?offsite.Report = null,
    status: ?offsite.Status = null,
    count: usize = 0,
    recovery_phrase: ?[]const u8 = null,
};
/// Returned strings and lists are copied into the caller's allocator.
pub fn execute(a: std.mem.Allocator, io: std.Io, request: Request) !Result {
    const path = if (request.config_path) |p| try a.dupe(u8, p) else try config_mod.findConfigPath(a);
    defer a.free(path);
    var cfg = try config_mod.parseConfig(a, path);
    defer cfg.deinit(a);
    if (cfg.backup_s3.endpoint.len == 0 or cfg.backup_s3.bucket.len == 0 or cfg.backup_s3.credentials.len == 0) return error.BackupNotConfigured;
    var creds = try credentials_mod.loadCredentials(a, io, cfg.backup_s3.credentials);
    defer creds.deinit(a);
    var paths = try device.paths.Paths.resolve(a, cfg.node.key_path);
    defer paths.deinit(a);
    const identity = try device.identity.Identity.loadOrCreate(paths.identity);
    var pair = try std.crypto.dh.X25519.KeyPair.fromEd25519(identity.key_pair);
    defer std.crypto.secureZero(u8, &pair.secret_key);
    var http: std.http.Client = .{ .allocator = a, .io = io };
    defer http.deinit();
    var adapter: s3.HttpTransport = .{ .client = &http };
    var client = try s3.Client.init(a, .{ .endpoint = cfg.backup_s3.endpoint, .bucket = cfg.backup_s3.bucket, .region = if (cfg.backup_s3.region.len == 0) "auto" else cfg.backup_s3.region, .max_response_bytes = 64 * 1024 * 1024 }, .{ .access_key_id = creds.access_key_id, .secret_access_key = creds.secret_access_key }, adapter.transport());
    var core = try offsite.Service.init(a, &client, cfg.backup_s3, .{ .id = identity.deviceId().bytes, .secret = pair.secret_key, .public = pair.public_key });
    defer core.deinit();
    if (request.action == .run) return run(a, &core, cfg);
    try core.unlock(request.recovery_words);
    switch (request.action) {
        .status => {
            const status = try core.status();
            const names = try a.alloc([]const u8, status.snapshots.len);
            errdefer a.free(names);
            var initialized: usize = 0;
            errdefer for (names[0..initialized]) |n| a.free(n);
            for (status.snapshots, names) |n, *copy| {
                copy.* = try a.dupe(u8, n);
                initialized += 1;
            }
            return .{ .status = .{ .snapshots = names, .indexed_blocks = status.indexed_blocks } };
        },
        .verify => return .{ .count = try core.verify(request.snapshot) },
        .restore => {
            const destination = request.destination orelse return error.DestinationRequired;
            try std.Io.Dir.cwd().createDirPath(io, destination);
            const dir = try std.Io.Dir.cwd().openDir(io, destination, .{ .follow_symlinks = false });
            defer dir.close(io);
            return .{ .count = try core.restore(io, request.snapshot orelse return error.SnapshotRequired, request.path, dir) };
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
    try @import("../cluster/offsite_worker.zig").enroll(core, node.trust_store);
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
