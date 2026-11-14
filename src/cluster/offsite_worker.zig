//! The keeper's offsite target host: only a node configured to keep the
//! swarm locally starts it. Uses the same core as explicit CLI/app operations.
const std = @import("std");
const sync = @import("../sync.zig");
const core = @import("offsite.zig");
const cfg_mod = @import("../backup/config.zig");
const device = @import("../device/mod.zig");
const fs_source = @import("../fs/offsite.zig");
const s3 = @import("../net/s3/mod.zig");
pub const Status = struct { last_upload: u64 = 0, uploaded_blocks: usize = 0, failure: ?anyerror = null };
pub const Worker = struct {
    allocator: std.mem.Allocator,
    config: cfg_mod.Config,
    identity: device.identity.Identity,
    trust: *device.trust.Store,
    source: fs_source.Source,
    worker: sync.Worker = .{},
    mutex: sync.Mutex = .{},
    round_mutex: sync.Mutex = .{},
    state: Status = .{},
    pub fn create(a: std.mem.Allocator, config: cfg_mod.Config, identity: device.identity.Identity, trust: *device.trust.Store, source: fs_source.Source) !*Worker {
        const self = try a.create(Worker);
        errdefer a.destroy(self);
        var copied = config;
        inline for (.{ "endpoint", "region", "bucket", "prefix", "credentials" }) |field| @field(copied, field) = "";
        errdefer copied.deinit(a);
        inline for (.{ "endpoint", "region", "bucket", "prefix", "credentials" }) |field| {
            if (@field(config, field).len > 0) @field(copied, field) = try a.dupe(u8, @field(config, field));
        }
        self.* = .{ .allocator = a, .config = copied, .identity = identity, .trust = trust, .source = source };
        return self;
    }
    pub fn destroy(self: *Worker) void {
        self.stop();
        self.config.deinit(self.allocator);
        std.crypto.secureZero(u8, std.mem.asBytes(&self.identity));
        self.allocator.destroy(self);
    }
    pub fn start(self: *Worker) !void {
        try self.worker.start(loop, .{self});
    }
    pub fn stop(self: *Worker) void {
        self.worker.stop();
    }
    pub fn status(self: *Worker) Status {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.state;
    }
    fn loop(self: *Worker) void {
        var waited: u64 = 3_590_000;
        while (self.worker.isRunning()) {
            sync.sleep(200 * std.time.ns_per_ms);
            waited += 200;
            // First round after 10 s, then once per hour; failed/missing local
            // DAGs retry after a minute while the local keeper catches up.
            if (waited < 3_600_000) continue;
            waited = 0;
            self.round() catch |err| {
                self.mutex.lock();
                self.state.failure = err;
                self.mutex.unlock();
                if (err != error.Cancelled) std.debug.print("offsite: upload failed: {s}\n", .{@errorName(err)});
                waited = 3_540_000;
            };
        }
    }
    pub fn round(self: *Worker) !void {
        self.round_mutex.lock();
        defer self.round_mutex.unlock();
        const a = self.allocator;
        const io = std.Io.Threaded.global_single_threaded.io();
        var credentials = try cfg_mod.loadCredentials(a, io, self.config.credentials);
        defer credentials.deinit(a);
        var http: std.http.Client = .{ .allocator = a, .io = io };
        defer http.deinit();
        var adapter: s3.HttpTransport = .{ .client = &http };
        var client = try s3.Client.init(a, .{ .endpoint = self.config.endpoint, .bucket = self.config.bucket, .region = if (self.config.region.len == 0) "auto" else self.config.region }, .{ .access_key_id = credentials.access_key_id, .secret_access_key = credentials.secret_access_key }, adapter.transport());
        var pair = try std.crypto.dh.X25519.KeyPair.fromEd25519(self.identity.key_pair);
        defer std.crypto.secureZero(u8, &pair.secret_key);
        var service = try core.Service.init(a, &client, self.config, .{ .id = self.identity.deviceId().bytes, .secret = pair.secret_key, .public = pair.public_key });
        defer service.deinit();
        if (self.worker.isRunning()) service.keep_going = &self.worker.running;
        const report = try service.run(self.source.source(), self.source.store);
        if (report.recovery_phrase) |phrase| std.debug.print("S3 backup recovery words — save these:\n{s}\n", .{phrase});
        try enroll(&service, self.trust);
        self.mutex.lock();
        defer self.mutex.unlock();
        self.state = .{ .last_upload = sync.nowSeconds(), .uploaded_blocks = report.uploaded_blocks };
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
