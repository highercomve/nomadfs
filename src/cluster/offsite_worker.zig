//! The keeper's offsite target host, and the policy of which target this
//! device uploads to: warm targets on a swarm backup device, cold ones
//! (GLACIER, DEEP_ARCHIVE) only on a deep backup device. Uses the same core
//! as explicit CLI/app operations.
const std = @import("std");
const sync = @import("../sync.zig");
const core = @import("offsite.zig");
const cfg_mod = @import("../backup/config.zig");
const device = @import("../device/mod.zig");
const storage = @import("../storage/mod.zig");
const s3 = @import("../net/s3/mod.zig");
/// The roles of this device that decide where it uploads.
pub const Roles = struct { swarm_backup: bool = false, deep_backup: bool = false };

/// Whether this device uploads to a target, or what it lacks.
pub const Gate = enum {
    uploading,
    needs_swarm_backup,
    needs_deep_backup,

    /// One line for a status page; "" when the target uploads.
    pub fn text(self: Gate) []const u8 {
        return switch (self) {
            .uploading => "",
            .needs_swarm_backup => "not uploading: this device is not a swarm backup",
            .needs_deep_backup => "not uploading: an archive target needs deep backup on this device",
        };
    }
};

/// What a deep backup device without a cold target reports.
pub const no_archive = "no archive target configured";

/// The policy: a cold target takes the whole swarm backup of a deep backup
/// device; a warm one runs on every swarm backup device.
pub fn gate(config: cfg_mod.Config, roles: Roles) Gate {
    if (config.storage_class.cold()) return if (roles.deep_backup) .uploading else .needs_deep_backup;
    return if (roles.swarm_backup or roles.deep_backup) .uploading else .needs_swarm_backup;
}

/// True when a configured target is cold (deep backup has somewhere to go).
pub fn hasArchive(targets: []const cfg_mod.Config) bool {
    for (targets) |target| if (target.configured() and target.storage_class.cold()) return true;
    return false;
}

pub const Status = struct {
    name: []const u8 = "",
    /// A GLACIER or DEEP_ARCHIVE target.
    cold: bool = false,
    gate: Gate = .uploading,
    last_upload: u64 = 0,
    uploaded_blocks: usize = 0,
    uploaded_bytes: u64 = 0,
    /// Files the last snapshot left out: their blocks were not all here.
    waiting_files: usize = 0,
    failure: ?anyerror = null,
    /// An upload to this target is under way.
    running: bool = false,
    /// A run asked for by hand (`request`) that has not begun yet.
    requested: bool = false,
    /// Runs asked for by hand that ended, well or not, since the node
    /// started: who asked waits for the count to pass what `request` gave.
    manual_runs: u64 = 0,
    /// The last upload made this target's key (its recovery words are new),
    /// or took another target's (`reused_key`).
    new_key: bool = false,
    reused_key: bool = false,
    /// Packs a purge left behind until their minimum storage time ends, and
    /// when the first and the last may go, as the last upload found them.
    deferred_packs: usize = 0,
    deferred_first: u64 = 0,
    deferred_last: u64 = 0,
    snapshot_buf: [max_snapshot_name]u8 = undefined,
    snapshot_len: u8 = 0,

    /// The last upload's snapshot; "" before the first.
    pub fn snapshot(self: *const Status) []const u8 {
        return self.snapshot_buf[0..self.snapshot_len];
    }
};
const max_snapshot_name = 128;

/// One target's credentials, HTTP client and core service. The parts point
/// at each other: open in place and never move it.
pub const Session = struct {
    allocator: std.mem.Allocator,
    credentials: cfg_mod.Credentials,
    http: std.http.Client,
    adapter: s3.HttpTransport,
    client: s3.Client,
    service: core.Service,

    pub fn open(self: *Session, a: std.mem.Allocator, io: std.Io, config: cfg_mod.Config, identity: device.identity.Identity) !void {
        return self.openOn(a, io, config, identity, null);
    }
    /// `open` over `transport` in place of HTTP (tests: a bucket in memory).
    pub fn openOn(self: *Session, a: std.mem.Allocator, io: std.Io, config: cfg_mod.Config, identity: device.identity.Identity, transport: ?s3.Transport) !void {
        if (!config.configured()) return error.BackupNotConfigured;
        self.allocator = a;
        self.credentials = try cfg_mod.loadCredentials(a, io, config.credentials);
        errdefer self.credentials.deinit(a);
        self.http = .{ .allocator = a, .io = io };
        errdefer self.http.deinit();
        self.adapter = .{ .client = &self.http };
        self.client = try s3.Client.init(a, .{ .endpoint = config.endpoint, .bucket = config.bucket, .region = if (config.region.len == 0) "auto" else config.region }, .{ .access_key_id = self.credentials.access_key_id, .secret_access_key = self.credentials.secret_access_key }, transport orelse self.adapter.transport());
        var pair = try std.crypto.dh.X25519.KeyPair.fromEd25519(identity.key_pair);
        defer std.crypto.secureZero(u8, &pair.secret_key);
        self.service = try core.Service.init(a, &self.client, config, .{ .id = identity.deviceId().bytes, .secret = pair.secret_key, .public = pair.public_key });
    }
    pub fn close(self: *Session) void {
        self.service.deinit();
        self.http.deinit();
        self.credentials.deinit(self.allocator);
    }
};

/// A target not written yet takes the backup key and the recovery words of
/// another target this device can open, so one set of 24 words opens every
/// copy. Any failure leaves the target to make its own key, as before.
pub fn shareKey(a: std.mem.Allocator, io: std.Io, service: *core.Service, others: []const cfg_mod.Config, identity: device.identity.Identity, transport: ?s3.Transport) void {
    if (service.initialised() catch true) return;
    for (others) |other| {
        if (std.mem.eql(u8, other.name, service.config.name)) continue;
        var session: Session = undefined;
        session.openOn(a, io, other, identity, transport) catch continue;
        defer session.close();
        session.service.unlockKey(null) catch continue;
        const phrase = session.service.recoveryKey() catch continue;
        service.adopt(session.service.key.?, phrase) catch continue;
        return;
    }
}

pub const Worker = struct {
    allocator: std.mem.Allocator,
    /// Every configured target, in file order; each has its own state.
    configs: []cfg_mod.Config,
    states: []Status,
    identity: device.identity.Identity,
    trust: *device.trust.Store,
    /// What to back up, described by the layer above; the worker never
    /// looks at folders itself.
    source: core.Source,
    store: *storage.engine.StorageEngine,
    worker: sync.Worker = .{},
    mutex: sync.Mutex = .{},
    round_mutex: sync.Mutex = .{},
    swarm_backup: std.atomic.Value(bool) = .init(false),
    deep_backup: std.atomic.Value(bool) = .init(false),
    /// Set when a role changes: the loop looks at once.
    poked: std.atomic.Value(bool) = .init(false),
    /// One target's upload; tests replace it.
    uploadFn: *const fn (*Worker, cfg_mod.Config, usize, bool) anyerror!void = upload,
    /// What the sessions reach the buckets over; null is HTTP. Tests set a
    /// bucket in memory.
    transport: ?s3.Transport = null,
    pub fn create(a: std.mem.Allocator, targets: []const cfg_mod.Config, identity: device.identity.Identity, trust: *device.trust.Store, source: core.Source, store: *storage.engine.StorageEngine) !*Worker {
        const self = try a.create(Worker);
        errdefer a.destroy(self);
        var wanted: usize = 0;
        for (targets) |target| wanted += @intFromBool(target.configured());
        if (wanted == 0) return error.BackupNotConfigured;
        const configs = try a.alloc(cfg_mod.Config, wanted);
        errdefer a.free(configs);
        var copied: usize = 0;
        errdefer for (configs[0..copied]) |*config| config.deinit(a);
        for (targets) |target| {
            if (!target.configured()) continue;
            configs[copied] = try target.clone(a);
            copied += 1;
        }
        const states = try a.alloc(Status, wanted);
        for (states, configs) |*state, config| state.* = .{ .name = config.name, .cold = config.storage_class.cold(), .gate = gate(config, .{}) };
        self.* = .{ .allocator = a, .configs = configs, .states = states, .identity = identity, .trust = trust, .source = source, .store = store };
        return self;
    }
    pub fn destroy(self: *Worker) void {
        self.stop();
        const a = self.allocator;
        for (self.configs) |*config| config.deinit(a);
        a.free(self.configs);
        a.free(self.states);
        std.crypto.secureZero(u8, std.mem.asBytes(&self.identity));
        a.destroy(self);
    }
    pub fn start(self: *Worker) !void {
        try self.worker.start(loop, .{self});
    }
    pub fn stop(self: *Worker) void {
        self.worker.stop();
    }
    /// The device's roles, applied at once: a target that may now upload
    /// is looked at within a moment, one that may not stops being started
    /// (an upload under way finishes its packs).
    pub fn setRoles(self: *Worker, now: Roles) void {
        self.swarm_backup.store(now.swarm_backup, .release);
        self.deep_backup.store(now.deep_backup, .release);
        self.mutex.lock();
        for (self.states, self.configs) |*state, config| state.gate = gate(config, now);
        self.mutex.unlock();
        self.poked.store(true, .release);
    }
    pub fn roles(self: *Worker) Roles {
        return .{ .swarm_backup = self.swarm_backup.load(.acquire), .deep_backup = self.deep_backup.load(.acquire) };
    }
    /// The first target's state (the one settings pages showed before).
    pub fn status(self: *Worker) Status {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.states[0];
    }
    /// The first cold target's state; null when none is configured (a deep
    /// backup device then reports `no_archive`).
    pub fn archiveStatus(self: *Worker) ?Status {
        self.mutex.lock();
        defer self.mutex.unlock();
        for (self.states) |state| if (state.cold) return state;
        return null;
    }
    /// A deep backup device with no cold target: nothing goes to an archive.
    pub fn archiveMissing(self: *Worker) bool {
        return self.deep_backup.load(.acquire) and !hasArchive(self.configs);
    }
    pub fn statusOf(self: *Worker, name: []const u8) ?Status {
        self.mutex.lock();
        defer self.mutex.unlock();
        for (self.states) |state| if (std.mem.eql(u8, state.name, name)) return state;
        return null;
    }
    /// The state of target `i` of `configs`.
    pub fn statusAt(self: *Worker, i: usize) Status {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.states[i];
    }
    /// Which of `configs` a command means, as the configuration names its
    /// sections: null (or "s3" with no such section) is the first.
    pub fn indexOf(self: *const Worker, name: ?[]const u8) ?usize {
        const wanted = name orelse return 0;
        for (self.configs, 0..) |config, i| if (std.mem.eql(u8, config.name, wanted)) return i;
        return if (std.mem.eql(u8, wanted, "s3")) 0 else null;
    }
    /// A run of target `i` by hand: the loop starts it within a moment,
    /// whatever its schedule says, and `statusAt` tells how it went once
    /// `manual_runs` passed the count returned here. As a run in a process
    /// of its own, a warm target uploads without the swarm backup role; an
    /// archive takes the whole swarm backup or nothing (error.DeepBackupOff).
    pub fn request(self: *Worker, i: usize) !u64 {
        if (gate(self.configs[i], self.roles()) == .needs_deep_backup) return error.DeepBackupOff;
        // Nothing would take it: the node is stopping, or never listened.
        if (!self.worker.isRunning()) return error.Cancelled;
        self.mutex.lock();
        self.states[i].requested = true;
        const done = self.states[i].manual_runs;
        self.mutex.unlock();
        self.poked.store(true, .release);
        return done;
    }
    fn loop(self: *Worker) void {
        var waited: u64 = 3_590_000;
        while (self.worker.isRunning()) {
            sync.sleep(200 * std.time.ns_per_ms);
            waited += 200;
            // First look after 10 s, then once per hour (at once when a role
            // changes): a target uploads when its schedule (daily, weekly,
            // monthly) says its newest snapshot is old enough, or when its
            // last snapshot left files out that waited for blocks. A failed
            // round retries after a minute.
            if (self.poked.swap(false, .acq_rel)) waited = 3_600_000;
            if (waited < 3_600_000) continue;
            waited = 0;
            self.round(false) catch |err| {
                if (err != error.Cancelled) std.debug.print("offsite: upload failed: {s}\n", .{if (err == error.BucketVersioningEnabled) core.versioned_bucket else @errorName(err)});
                waited = 3_540_000;
            };
        }
    }
    /// Uploads to every target this device's roles allow; `force` ignores
    /// the schedules (an explicit "back up now"), never the roles. Each
    /// target's failure is kept; the first is returned.
    pub fn round(self: *Worker, force: bool) !void {
        self.round_mutex.lock();
        defer self.round_mutex.unlock();
        if (self.archiveMissing()) std.debug.print("offsite: deep backup is on: {s}\n", .{no_archive});
        var failure: ?anyerror = null;
        for (self.configs, 0..) |config, i| {
            const allowed = gate(config, self.roles());
            self.mutex.lock();
            const state = &self.states[i];
            state.gate = allowed;
            const asked = state.requested;
            state.requested = false;
            const go = allowed == .uploading or (asked and allowed == .needs_swarm_backup);
            state.running = go;
            // Deep backup went off between the request and this look.
            if (asked and !go) {
                state.failure = error.DeepBackupOff;
                state.manual_runs += 1;
            }
            self.mutex.unlock();
            if (!go) continue;
            const result = self.uploadFn(self, config, i, force or asked);
            self.mutex.lock();
            state.running = false;
            if (asked) state.manual_runs += 1;
            if (result) |_| {} else |err| state.failure = err;
            self.mutex.unlock();
            result catch |err| {
                if (failure == null) failure = err;
                if (err == error.Cancelled) break;
            };
        }
        if (failure) |err| return err;
    }
    fn upload(self: *Worker, config: cfg_mod.Config, i: usize, force: bool) anyerror!void {
        const a = self.allocator;
        const io = std.Io.Threaded.global_single_threaded.io();
        var session: Session = undefined;
        try session.openOn(a, io, config, self.identity, self.transport);
        defer session.close();
        const service = &session.service;
        if (self.worker.isRunning()) service.keep_going = &self.worker.running;
        // Files that waited for blocks go in on the next look, not at the
        // next daily, weekly or monthly snapshot: the bucket's head records
        // the unfinished round, so `due` says so after a restart too.
        if (!force and !(try service.due())) return;
        shareKey(a, io, service, self.configs, self.identity, self.transport);
        const report = try service.run(self.source, self.store);
        if (report.recovery_phrase) |phrase| std.debug.print("S3 backup \"{s}\" recovery words — save these:\n{s}\n", .{ config.name, phrase });
        if (report.waiting_files > 0) std.debug.print("offsite: \"{s}\": {d} files waiting for blocks\n", .{ config.name, report.waiting_files });
        try enroll(service, self.trust);
        // What the run left in the session: nothing more is asked of the bucket.
        const bucket = service.status() catch core.Status{ .snapshots = &.{}, .indexed_blocks = 0 };
        self.mutex.lock();
        defer self.mutex.unlock();
        const state = &self.states[i];
        state.last_upload = sync.nowSeconds();
        state.uploaded_blocks = report.uploaded_blocks;
        state.uploaded_bytes = report.uploaded_bytes;
        state.waiting_files = report.waiting_files;
        state.failure = null;
        state.new_key = report.recovery_phrase != null;
        state.reused_key = report.reused_key;
        state.deferred_packs = bucket.deferred_packs;
        state.deferred_first = bucket.deferred_first;
        state.deferred_last = bucket.deferred_last;
        state.snapshot_len = @intCast(@min(report.snapshot.len, max_snapshot_name));
        @memcpy(state.snapshot_buf[0..state.snapshot_len], report.snapshot[0..state.snapshot_len]);
    }
};
/// Existing members receive identity-derived wraps, never Noise session keys.
pub fn enroll(service: *core.Service, trust: *device.trust.Store) !void {
    const entries = try trust.copyEntries(service.allocator);
    defer service.allocator.free(entries);
    try service.acquire();
    defer service.release();
    for (entries) |entry| {
        if (!trust.isTrusted(entry.device_id)) continue;
        const public = try std.crypto.sign.Ed25519.PublicKey.fromBytes(entry.public_key);
        const xpublic = try std.crypto.dh.X25519.publicKeyFromEd25519(public);
        try service.wrapDevice(entry.device_id.bytes, xpublic);
    }
}
