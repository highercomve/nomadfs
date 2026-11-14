//! The keeper's offsite target host: only a node configured to keep the
//! swarm locally starts it. Uses the same core as explicit CLI/app operations.
const std = @import("std");
const sync = @import("../sync.zig");
const core = @import("offsite.zig");
const cfg_mod = @import("../backup/config.zig");
const device = @import("../device/mod.zig");
const fs_source = @import("../fs/offsite.zig");
const s3 = @import("../net/s3/mod.zig");
pub const Status = struct { name: []const u8 = "", last_upload: u64 = 0, uploaded_blocks: usize = 0, failure: ?anyerror = null };

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
        if (!config.configured()) return error.BackupNotConfigured;
        self.allocator = a;
        self.credentials = try cfg_mod.loadCredentials(a, io, config.credentials);
        errdefer self.credentials.deinit(a);
        self.http = .{ .allocator = a, .io = io };
        errdefer self.http.deinit();
        self.adapter = .{ .client = &self.http };
        self.client = try s3.Client.init(a, .{ .endpoint = config.endpoint, .bucket = config.bucket, .region = if (config.region.len == 0) "auto" else config.region }, .{ .access_key_id = self.credentials.access_key_id, .secret_access_key = self.credentials.secret_access_key }, self.adapter.transport());
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
pub fn shareKey(a: std.mem.Allocator, io: std.Io, service: *core.Service, others: []const cfg_mod.Config, identity: device.identity.Identity) void {
    if (service.initialised() catch true) return;
    for (others) |other| {
        if (std.mem.eql(u8, other.name, service.config.name)) continue;
        var session: Session = undefined;
        session.open(a, io, other, identity) catch continue;
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
    source: fs_source.Source,
    worker: sync.Worker = .{},
    mutex: sync.Mutex = .{},
    round_mutex: sync.Mutex = .{},
    pub fn create(a: std.mem.Allocator, targets: []const cfg_mod.Config, identity: device.identity.Identity, trust: *device.trust.Store, source: fs_source.Source) !*Worker {
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
        for (states, configs) |*state, config| state.* = .{ .name = config.name };
        self.* = .{ .allocator = a, .configs = configs, .states = states, .identity = identity, .trust = trust, .source = source };
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
    /// The first target's state (the one settings pages showed before).
    pub fn status(self: *Worker) Status {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.states[0];
    }
    pub fn statusOf(self: *Worker, name: []const u8) ?Status {
        self.mutex.lock();
        defer self.mutex.unlock();
        for (self.states) |state| if (std.mem.eql(u8, state.name, name)) return state;
        return null;
    }
    fn loop(self: *Worker) void {
        var waited: u64 = 3_590_000;
        while (self.worker.isRunning()) {
            sync.sleep(200 * std.time.ns_per_ms);
            waited += 200;
            // First look after 10 s, then once per hour: a target uploads when
            // its schedule (daily, weekly, monthly) says its newest snapshot
            // is old enough. Failed/missing local DAGs retry after a minute
            // while the local keeper catches up.
            if (waited < 3_600_000) continue;
            waited = 0;
            self.round(false) catch |err| {
                if (err != error.Cancelled) std.debug.print("offsite: upload failed: {s}\n", .{@errorName(err)});
                waited = 3_540_000;
            };
        }
    }
    /// Uploads to every target; `force` ignores the schedules (an explicit
    /// "back up now"). Each target's failure is kept; the first is returned.
    pub fn round(self: *Worker, force: bool) !void {
        self.round_mutex.lock();
        defer self.round_mutex.unlock();
        var failure: ?anyerror = null;
        for (self.configs, 0..) |config, i| {
            self.upload(config, i, force) catch |err| {
                self.mutex.lock();
                self.states[i].failure = err;
                self.mutex.unlock();
                if (failure == null) failure = err;
                if (err == error.Cancelled) break;
            };
        }
        if (failure) |err| return err;
    }
    fn upload(self: *Worker, config: cfg_mod.Config, i: usize, force: bool) !void {
        const a = self.allocator;
        const io = std.Io.Threaded.global_single_threaded.io();
        var session: Session = undefined;
        try session.open(a, io, config, self.identity);
        defer session.close();
        const service = &session.service;
        if (self.worker.isRunning()) service.keep_going = &self.worker.running;
        if (!force and !(try service.due())) return;
        shareKey(a, io, service, self.configs, self.identity);
        const report = try service.run(self.source.source(), self.source.store);
        if (report.recovery_phrase) |phrase| std.debug.print("S3 backup \"{s}\" recovery words — save these:\n{s}\n", .{ config.name, phrase });
        try enroll(service, self.trust);
        self.mutex.lock();
        defer self.mutex.unlock();
        self.states[i] = .{ .name = config.name, .last_upload = sync.nowSeconds(), .uploaded_blocks = report.uploaded_blocks };
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
