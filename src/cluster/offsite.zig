//! Offsite is a cluster distribution target: fs supplies the files and their
//! reachable CIDs, storage supplies verified local blocks, net transports S3.
//! All upload, retention, purge and restore policy lives here for every UI.
//! The historical catalog deliberately outlives snapshots: ordinary deletes
//! and retention must never release backup data. Only a purge runs pack GC.
const std = @import("std");
const backup = @import("../backup/mod.zig");
const s3 = @import("../net/s3/mod.zig");
const storage = @import("../storage/mod.zig");
const manifest = @import("../fs/manifest.zig");
const Config = @import("../backup/config.zig").Config;
const StorageClass = @import("../backup/config.zig").StorageClass;
const Schedule = @import("../backup/config.zig").Schedule;
const Allocator = std.mem.Allocator;
const Cid = [32]u8;
const Entry = backup.index.Entry;
const Key = backup.keys.Key;
const max_objects = 1_000_000;
const max_metadata = 64 * 1024 * 1024;
const lease_seconds = 300;
/// A thawed copy stays readable this long: enough to finish a big restore.
const thaw_days = 7;
/// Uploads run on an hourly poll; a round this close to its time is due.
const schedule_slack = 3600;
const job_name = ".nomadfs-restore.json";
pub const Tier = s3.RestoreTier;
pub const File = struct { path: []const u8, cid: Cid, size: u64, mtime: u64 = 0, blocks: []const Cid, directory: bool = false };
pub const Snapshot = struct { time: u64, files: []const File };
pub const Source = struct {
    ctx: *anyopaque,
    filesFn: *const fn (*anyopaque, Allocator) anyerror![]const File,
};
pub const Device = struct { id: Cid, secret: Key, public: Key };
pub const Report = struct {
    uploaded_blocks: usize = 0,
    uploaded_bytes: u64 = 0,
    snapshot: []const u8 = "",
    recovery_phrase: ?[]const u8 = null,
    /// The new target took another target's key: the words are the same.
    reused_key: bool = false,
};
pub const Status = struct {
    snapshots: []const []const u8,
    indexed_blocks: usize,
    storage_class: StorageClass = .STANDARD,
    schedule: Schedule = .daily,
    /// Packs a purge left behind until their minimum storage time ends.
    deferred_packs: usize = 0,
    /// When the first and the last of them may be removed (Unix seconds).
    deferred_first: u64 = 0,
    deferred_last: u64 = 0,
};
/// A restore on a cold target ends when no pack is thawing any more.
pub const Restore = struct { files: usize = 0, thawing_packs: usize = 0, thawing_bytes: u64 = 0 };
pub const Check = struct {
    blocks: usize = 0,
    packs: usize = 0,
    /// False: packs were checked by listing only (name and size).
    downloaded: bool = true,
    thawing_packs: usize = 0,
    thawing_bytes: u64 = 0,
};
const Info = struct { name: []const u8, size: u64, modified: u64 };
const Deferred = struct { pack: [16]u8, removable: u64 };
const Job = struct { version: u32 = 1, snapshot: []const u8, path: ?[]const u8 = null, tier: Tier = .Bulk, requested: u64 = 0, packs: usize = 0, bytes: u64 = 0 };
const Packs = std.AutoHashMap([16]u8, bool);
const Layout = struct { version: u32 = 1, encrypt: bool, key_id: [8]u8 };
const Lease = struct { owner: [16]u8, expires: u64 };

/// One operation/session at a time. Scratch metadata belongs to this bounded
/// session's arena; pack buffers and local block data are released promptly.
pub const Service = struct {
    allocator: Allocator,
    arena: std.heap.ArenaAllocator,
    client: *s3.Client,
    config: Config,
    device: Device,
    key: ?Key = null,
    encrypted: bool = true,
    index: backup.index.Index,
    lease_etag: ?[]const u8 = null,
    lease_renew_at: u64 = 0,
    owner: [16]u8,
    clock_ctx: ?*anyopaque = null,
    clockFn: ?*const fn (?*anyopaque) u64 = null,
    created_phrase: ?[]const u8 = null,
    keep_going: ?*const std.atomic.Value(bool) = null,
    /// Key and recovery words of another target, used if this one is new.
    seed_key: ?Key = null,
    seed_phrase: ?[]const u8 = null,

    pub fn init(allocator: Allocator, client: *s3.Client, config: Config, device: Device) !Service {
        if (config.pack_mb == 0 or config.pack_mb > 512) return error.InvalidPackSize;
        return .{ .allocator = allocator, .arena = .init(allocator), .client = client, .config = config, .device = device, .index = .init(allocator), .owner = try backup.index.generatePackId() };
    }
    pub fn deinit(self: *Service) void {
        self.index.deinit();
        if (self.key) |*k| std.crypto.secureZero(u8, k);
        std.crypto.secureZero(u8, &self.device.secret);
        if (self.created_phrase) |p| std.crypto.secureZero(u8, @constCast(p));
        if (self.seed_key) |*k| std.crypto.secureZero(u8, k);
        if (self.seed_phrase) |p| std.crypto.secureZero(u8, @constCast(p));
        self.arena.deinit();
    }
    fn a(self: *Service) Allocator {
        return self.arena.allocator();
    }
    fn now(self: *Service) u64 {
        return if (self.clockFn) |f| f(self.clock_ctx) else @import("../sync.zig").nowSeconds();
    }
    fn timestamp(self: *Service) [16]u8 {
        const epoch: std.time.epoch.EpochSeconds = .{ .secs = self.now() };
        const yd = epoch.getEpochDay().calculateYearDay();
        const md = yd.calculateMonthDay();
        const ds = epoch.getDaySeconds();
        var out: [16]u8 = undefined;
        _ = std.fmt.bufPrint(&out, "{d:0>4}{d:0>2}{d:0>2}T{d:0>2}{d:0>2}{d:0>2}Z", .{
            yd.year, md.month.numeric(), @as(u8, md.day_index) + 1, ds.getHoursIntoDay(), ds.getMinutesIntoHour(), ds.getSecondsIntoMinute(),
        }) catch unreachable;
        return out;
    }
    fn name(self: *Service, relative: []const u8) ![]const u8 {
        const prefix = std.mem.trim(u8, self.config.prefix, "/");
        return if (prefix.len == 0) relative else std.fmt.allocPrint(self.a(), "{s}/{s}", .{ prefix, relative });
    }
    fn randomName(self: *Service, dir: []const u8) ![]const u8 {
        const hex = backup.index.formatPackId(try backup.index.generatePackId());
        return std.fmt.allocPrint(self.a(), "{s}/{d:0>20}-{s}", .{ dir, self.now(), hex });
    }
    fn get(self: *Service, relative: []const u8) ![]const u8 {
        const ts = self.timestamp();
        var response = try self.client.getObject(try self.name(relative), null, &ts);
        defer response.deinit();
        return self.a().dupe(u8, response.body);
    }
    /// Metadata: always the bucket's default class, readable without a thaw.
    fn put(self: *Service, relative: []const u8, bytes: []const u8) !void {
        return self.putClass(relative, bytes, null);
    }
    fn putClass(self: *Service, relative: []const u8, bytes: []const u8, class: ?[]const u8) !void {
        try self.renew();
        const ts = self.timestamp();
        var response = try self.client.putObject(try self.name(relative), .{ .bytes = bytes }, .{ .storage_class = class }, &ts);
        defer response.deinit();
    }
    fn cold(self: *Service) bool {
        return self.config.storage_class.cold();
    }
    /// Seconds a pack must stay before it may be deleted or replaced.
    fn hold(self: *Service) u64 {
        return @as(u64, self.config.storage_class.minDays()) * 86400;
    }
    /// Only packs take the target's class.
    fn packClass(self: *Service) ?[]const u8 {
        return if (self.config.storage_class == .STANDARD) null else @tagName(self.config.storage_class);
    }
    fn delete(self: *Service, relative: []const u8) !void {
        try self.renew();
        const ts = self.timestamp();
        try self.client.deleteObject(try self.name(relative), &ts);
    }
    fn json(self: *Service, value: anytype) ![]const u8 {
        return std.json.Stringify.valueAlloc(self.a(), value, .{});
    }
    fn parse(self: *Service, comptime T: type, bytes: []const u8) !T {
        return (try std.json.parseFromSlice(T, self.a(), bytes, .{ .allocate = .alloc_always, .max_value_len = max_metadata })).value;
    }
    fn cryptoKey(self: *Service) ?Key {
        return if (self.encrypted) self.key else null;
    }
    fn seal(self: *Service, bytes: []const u8) ![]const u8 {
        if (bytes.len > max_metadata - 128) return error.MetadataTooLarge;
        var writer = try backup.pack.Writer.init(self.allocator, .{ .key = self.cryptoKey(), .target_size = bytes.len + 128 });
        defer writer.deinit();
        const span = try writer.append([_]u8{0} ** 32, bytes);
        _ = span;
        return self.a().dupe(u8, writer.bytes());
    }
    fn open(self: *Service, bytes: []const u8) ![]const u8 {
        if (bytes.len < backup.pack.header_len or bytes.len > max_metadata) return error.InvalidMetadata;
        const plain = try backup.pack.readBlock(self.allocator, bytes, backup.pack.header_len, @intCast(bytes.len - backup.pack.header_len), self.cryptoKey());
        defer {
            std.crypto.secureZero(u8, plain);
            self.allocator.free(plain);
        }
        return self.a().dupe(u8, plain);
    }
    fn putJson(self: *Service, relative: []const u8, value: anytype) !void {
        try self.put(relative, try self.seal(try self.json(value)));
    }
    fn getJson(self: *Service, comptime T: type, relative: []const u8) !T {
        return self.parse(T, try self.open(try self.get(relative)));
    }

    /// Paginated names relative to this backup prefix. Caller uses session arena.
    pub fn list(self: *Service, dir: []const u8) ![]const []const u8 {
        const objects = try self.listObjects(dir);
        const names = try self.a().alloc([]const u8, objects.len);
        for (objects, names) |object, *n| n.* = object.name;
        return names;
    }
    fn listObjects(self: *Service, dir: []const u8) ![]const Info {
        var names: std.ArrayList(Info) = .empty;
        var token: ?[]const u8 = null;
        const prefix = try self.name(try std.fmt.allocPrint(self.a(), "{s}/", .{dir}));
        const strip = (try self.name("")).len;
        for (0..max_objects / 1000 + 1) |_| {
            const ts = self.timestamp();
            var page = try self.client.listObjectsV2(.{ .prefix = prefix, .continuation_token = token }, &ts);
            defer page.deinit();
            for (page.objects) |obj| {
                if (names.items.len >= max_objects or !std.mem.startsWith(u8, obj.key, prefix)) return error.TooManyObjects;
                try names.append(self.a(), .{ .name = try self.a().dupe(u8, obj.key[strip..]), .size = obj.size, .modified = obj.last_modified });
            }
            if (!page.is_truncated) return names.toOwnedSlice(self.a());
            const next = page.next_continuation_token orelse return error.InvalidPagination;
            if (token) |prev| if (std.mem.eql(u8, prev, next)) return error.InvalidPagination;
            token = try self.a().dupe(u8, next);
        }
        return error.TooManyObjects;
    }
    pub fn acquire(self: *Service) !void {
        if (self.lease_etag != null) return error.LeaseAlreadyHeld;
        const ts = self.timestamp();
        const key = try self.name("lease");
        var condition: s3.client.Condition = .if_none_match;
        if (self.client.getObject(key, null, &ts)) |result| {
            var old = result;
            defer old.deinit();
            const lease = try self.parse(Lease, old.body);
            if (lease.expires > self.now()) return error.LeaseHeld;
            condition = .{ .if_match = try self.a().dupe(u8, old.header("etag") orelse return error.MissingEtag) };
        } else |err| if (err != error.NotFound) return err;
        const bytes = try self.json(Lease{ .owner = self.owner, .expires = self.now() + lease_seconds });
        var response = self.client.putObject(key, .{ .bytes = bytes }, .{ .condition = condition }, &ts) catch |err| switch (err) {
            error.PreconditionFailed => return error.LeaseHeld,
            else => return err,
        };
        defer response.deinit();
        self.lease_etag = try self.a().dupe(u8, response.header("etag") orelse return error.MissingEtag);
        self.lease_renew_at = self.now() + lease_seconds / 3;
    }
    fn renew(self: *Service) !void {
        if (self.keep_going) |running| if (!running.load(.acquire)) return error.Cancelled;
        const etag = self.lease_etag orelse return error.LeaseRequired;
        if (self.now() < self.lease_renew_at) return;
        const ts = self.timestamp();
        var response = self.client.putObject(try self.name("lease"), .{ .bytes = try self.json(Lease{ .owner = self.owner, .expires = self.now() + lease_seconds }) }, .{ .condition = .{ .if_match = etag } }, &ts) catch |err| switch (err) {
            error.PreconditionFailed => return error.LeaseLost,
            else => return err,
        };
        defer response.deinit();
        self.lease_etag = try self.a().dupe(u8, response.header("etag") orelse return error.MissingEtag);
        self.lease_renew_at = self.now() + lease_seconds / 3;
    }
    pub fn release(self: *Service) void {
        const etag = self.lease_etag orelse return;
        self.lease_etag = null;
        self.lease_renew_at = 0;
        const ts = self.timestamp();
        var response = self.client.putObject(self.name("lease") catch return, .{ .bytes = self.json(Lease{ .owner = self.owner, .expires = 0 }) catch return }, .{ .condition = .{ .if_match = etag } }, &ts) catch return;
        response.deinit();
    }
    fn deviceWrapName(self: *Service) ![]const u8 {
        const id = std.fmt.bytesToHex(self.device.id, .lower);
        return std.fmt.allocPrint(self.a(), "keys/{s}.wrap", .{id});
    }
    pub fn unlock(self: *Service, phrase: ?[]const u8) !void {
        try self.unlockKey(phrase);
        self.index.deinit();
        self.index = .init(self.allocator);
        for (try self.list("index")) |name_| try self.index.mergeSegment(try self.get(name_), self.cryptoKey());
    }
    /// False for a bucket (prefix) no run has written its layout to yet.
    pub fn initialised(self: *Service) !bool {
        _ = self.get("nomadfs-backup.json") catch |err| switch (err) {
            error.NotFound => return false,
            else => return err,
        };
        return true;
    }
    /// A new target is created with this key and these 24 words (those of
    /// another target this device opened) instead of fresh ones.
    pub fn adopt(self: *Service, key: Key, phrase: []const u8) !void {
        var entropy = try backup.recovery_words.decodePhrase(phrase);
        std.crypto.secureZero(u8, &entropy);
        if (self.seed_phrase) |old| std.crypto.secureZero(u8, @constCast(old));
        self.seed_phrase = try self.a().dupe(u8, phrase);
        self.seed_key = key;
    }
    /// The key alone, without loading the index.
    pub fn unlockKey(self: *Service, phrase: ?[]const u8) !void {
        const layout = try self.parse(Layout, try self.get("nomadfs-backup.json"));
        if (layout.version != 1) return error.UnsupportedBackupVersion;
        self.encrypted = layout.encrypt;
        const blob = self.get(try self.deviceWrapName()) catch |err| switch (err) {
            error.NotFound => "",
            else => return err,
        };
        self.key = backup.keys.unwrapForDevice(blob, self.device.secret) catch blk: {
            const words = phrase orelse return error.RecoveryPhraseRequired;
            break :blk try backup.keys.unwrapWithRecovery(self.allocator, try self.get("keys/recovery.wrap"), words);
        };
        if (!std.mem.eql(u8, &layout.key_id, &backup.keys.keyId(self.key.?))) return error.KeyIdMismatch;
    }
    fn setup(self: *Service) !void {
        _ = self.get("nomadfs-backup.json") catch |err| {
            if (err != error.NotFound) return err;
            self.encrypted = self.config.encrypt;
            self.key = self.seed_key orelse try backup.keys.generateKey();
            const device_wrap = try backup.keys.wrapForDevice(self.key.?, self.device.public);
            try self.put(try self.deviceWrapName(), &device_wrap);
            var entropy = if (self.seed_phrase) |words| try backup.recovery_words.decodePhrase(words) else try backup.keys.generateKey();
            defer std.crypto.secureZero(u8, &entropy);
            var buf: [backup.recovery_words.max_phrase_len]u8 = undefined;
            defer std.crypto.secureZero(u8, &buf);
            const phrase = backup.recovery_words.formatPhrase(entropy, &buf);
            const recovery = try backup.keys.wrapWithRecovery(self.allocator, self.key.?, phrase);
            try self.put("keys/recovery.wrap", &recovery);
            // Recovery words stay encrypted even in the explicitly clear backup mode.
            const saved_mode = self.encrypted;
            self.encrypted = true;
            const sealed_entropy = try self.seal(&entropy);
            self.encrypted = saved_mode;
            try self.put("keys/recovery-entropy", sealed_entropy);
            try self.putJson("catalog", @as([]const File, &.{}));
            try self.put("nomadfs-backup.json", try self.json(Layout{ .encrypt = self.encrypted, .key_id = backup.keys.keyId(self.key.?) }));
            self.created_phrase = try self.a().dupe(u8, phrase);
            return;
        };
        try self.unlock(null);
    }
    /// Explicitly requested re-display requires an unlockable envelope.
    pub fn recoveryKey(self: *Service) ![]const u8 {
        if (self.key == null) return error.Locked;
        if (self.created_phrase) |phrase| return phrase;
        const mode = self.encrypted;
        self.encrypted = true;
        defer self.encrypted = mode;
        const entropy = try self.open(try self.get("keys/recovery-entropy"));
        defer std.crypto.secureZero(u8, @constCast(entropy));
        if (entropy.len != 32) return error.InvalidRecoveryEntropy;
        var buf: [backup.recovery_words.max_phrase_len]u8 = undefined;
        defer std.crypto.secureZero(u8, &buf);
        const phrase = try self.a().dupe(u8, backup.recovery_words.formatPhrase(entropy[0..32].*, &buf));
        if (self.created_phrase) |old| std.crypto.secureZero(u8, @constCast(old));
        self.created_phrase = phrase;
        return phrase;
    }
    /// Enroll a trusted device using its identity-derived X25519 public key.
    /// Caller holds the uploader lease; never creates a new backup key.
    pub fn wrapDevice(self: *Service, id: Cid, public: Key) !void {
        const hex = std.fmt.bytesToHex(id, .lower);
        const relative = try std.fmt.allocPrint(self.a(), "keys/{s}.wrap", .{hex});
        _ = self.get(relative) catch |err| {
            if (err != error.NotFound) return err;
            const wrapped = try backup.keys.wrapForDevice(self.key orelse return error.Locked, public);
            try self.put(relative, &wrapped);
            return;
        };
    }
    pub fn status(self: *Service) !Status {
        var result: Status = .{ .snapshots = try self.list("snapshots"), .indexed_blocks = self.index.count(), .storage_class = self.config.storage_class, .schedule = self.config.schedule };
        if (self.hold() == 0 or self.key == null) return result;
        for (try self.loadDeferred()) |d| {
            result.deferred_first = if (result.deferred_packs == 0) d.removable else @min(result.deferred_first, d.removable);
            result.deferred_last = @max(result.deferred_last, d.removable);
            result.deferred_packs += 1;
        }
        return result;
    }
    /// True when the newest snapshot is older than the target's schedule.
    /// Only the periodic uploader asks; an explicit run always uploads.
    pub fn due(self: *Service) !bool {
        var newest: u64 = 0;
        for (try self.list("snapshots")) |n| {
            const text = std.fs.path.basename(n);
            if (text.len < 20) continue;
            newest = @max(newest, std.fmt.parseInt(u64, text[0..20], 10) catch continue);
        }
        return newest == 0 or self.now() + schedule_slack >= newest + self.config.schedule.seconds();
    }
    pub fn snapshot(self: *Service, name_: []const u8) !Snapshot {
        if (!std.mem.startsWith(u8, name_, "snapshots/") or std.mem.indexOf(u8, name_, "..") != null) return error.InvalidSnapshot;
        const result = try self.getJson(Snapshot, name_);
        if (result.files.len > manifest.max_entries) return error.InvalidSnapshot;
        for (result.files) |file| if (!validFile(file)) return error.InvalidSnapshot;
        return result;
    }
    fn blockId(self: *Service, cid: Cid) Cid {
        return backup.index.blockIdForCid(self.cryptoKey(), cid);
    }
    fn packName(self: *Service, id: [16]u8) ![]const u8 {
        return std.fmt.allocPrint(self.a(), "packs/{s}", .{backup.index.formatPackId(id)});
    }
    fn segmentName(self: *Service, id: [16]u8) ![]const u8 {
        return std.fmt.allocPrint(self.a(), "index/{s}", .{backup.index.formatPackId(id)});
    }
    fn throttle(self: *Service, bytes: usize) !void {
        if (self.config.upload_limit_kbps == 0) return;
        var remaining = @as(u64, @intCast(bytes)) * 1000 / (@as(u64, self.config.upload_limit_kbps) * 1024);
        while (remaining > 0) {
            try self.renew();
            const ms = @min(remaining, 1000);
            try self.client.transport.sleep(self.client.transport.context, ms);
            remaining -= ms;
        }
    }
    fn uploadPack(self: *Service, name_: []const u8, bytes: []const u8) !void {
        const part_size = 5 * 1024 * 1024;
        if (bytes.len <= part_size) {
            try self.throttle(bytes.len);
            return self.putClass(name_, bytes, self.packClass());
        }
        try self.renew();
        var ts = self.timestamp();
        const full_name = try self.name(name_);
        const upload = try self.client.createMultipartUpload(full_name, .{ .storage_class = self.packClass() }, &ts);
        defer self.client.allocator.free(upload);
        errdefer self.client.abortMultipartUpload(full_name, upload, &ts) catch {};
        var parts: std.ArrayList(s3.client.CompletedPart) = .empty;
        var offset: usize = 0;
        while (offset < bytes.len) {
            const end = @min(offset + part_size, bytes.len);
            try self.throttle(end - offset);
            try self.renew();
            ts = self.timestamp();
            const number: u16 = @intCast(parts.items.len + 1);
            var response = try self.client.uploadPart(full_name, upload, number, .{ .bytes = bytes[offset..end] }, &ts);
            defer response.deinit();
            try parts.append(self.a(), .{ .part_number = number, .etag = try self.a().dupe(u8, response.header("etag") orelse return error.MissingEtag) });
            offset = end;
        }
        try self.renew();
        ts = self.timestamp();
        var response = try self.client.completeMultipartUpload(full_name, upload, parts.items, &ts);
        response.deinit();
    }
    fn flush(self: *Service, writer: *backup.pack.Writer, id: [16]u8, segment: ?[]const u8) !void {
        if (writer.blockCount() == 0 and segment == null) return;
        var entries: std.ArrayList(Entry) = .empty;
        defer entries.deinit(self.allocator);
        for (writer.spans()) |span| try entries.append(self.allocator, .{ .block_id = span.block_id, .pack_id = id, .offset = span.offset, .length = span.length });
        if (entries.items.len > 0) try self.uploadPack(try self.packName(id), writer.bytes());
        // Each immutable pack has one segment. A purge atomically replaces that
        // segment only after its replacement pack is durable, then removes bytes.
        const encoded = try backup.index.encodeSegment(self.allocator, entries.items, self.cryptoKey());
        defer self.allocator.free(encoded);
        try self.put(segment orelse try self.segmentName(id), encoded);
        try self.index.mergeEntries(entries.items);
    }
    pub fn run(self: *Service, source: Source, store: *storage.engine.StorageEngine) !Report {
        if (self.created_phrase) |old| std.crypto.secureZero(u8, @constCast(old));
        self.created_phrase = null;
        try self.acquire();
        defer self.release();
        try self.setup();
        if (self.config.encrypt != self.encrypted) return error.EncryptionModeMismatch;
        try self.applyPurges();
        const files = try source.filesFn(source.ctx, self.a());
        if (files.len > manifest.max_entries) return error.TooManyFiles;
        const purges = try self.purgePaths();
        var live: std.ArrayList(File) = .empty;
        var catalog: std.ArrayList(File) = .empty;
        try catalog.appendSlice(self.a(), try self.getJson([]const File, "catalog"));
        var writer = try backup.pack.Writer.init(self.allocator, .{ .key = self.cryptoKey(), .target_size = @as(usize, self.config.pack_mb) * 1024 * 1024 });
        defer writer.deinit();
        var id = try backup.index.generatePackId();
        var report: Report = .{};
        var pending: std.AutoHashMap(Cid, void) = .init(self.allocator);
        defer pending.deinit();
        for (files) |file| {
            if (!validFile(file)) return error.InvalidFile;
            if (purged(file.path, purges)) continue;
            try live.append(self.a(), file);
            if (!catalogHas(catalog.items, file)) try catalog.append(self.a(), file);
            for (file.blocks) |cid| {
                try self.renew();
                const bid = self.blockId(cid);
                if (self.index.contains(bid) or pending.contains(bid)) continue;
                const block = (try store.get(&cid, self.allocator)) orelse return error.BlockNotFound;
                defer self.allocator.free(block.data);
                if (!writer.wouldFit(block.data.len)) {
                    try self.flush(&writer, id, null);
                    const target = @max(@as(usize, self.config.pack_mb) * 1024 * 1024, backup.pack.header_len + writer.recordSize(block.data.len));
                    const replacement = try backup.pack.Writer.init(self.allocator, .{ .key = self.cryptoKey(), .target_size = target });
                    writer.deinit();
                    writer = replacement;
                    id = try backup.index.generatePackId();
                }
                _ = try writer.append(bid, block.data);
                try pending.put(bid, {});
                report.uploaded_blocks += 1;
                report.uploaded_bytes += block.data.len;
            }
        }
        try self.flush(&writer, id, null);
        try self.putJson("catalog", catalog.items);
        report.snapshot = try self.randomName("snapshots");
        try self.putJson(report.snapshot, Snapshot{ .time = self.now(), .files = live.items });
        try self.pruneSnapshots();
        report.recovery_phrase = self.created_phrase;
        report.reused_key = self.created_phrase != null and self.seed_key != null;
        return report;
    }
    pub fn readBlock(self: *Service, cid: Cid) ![]u8 {
        const location = self.index.get(self.blockId(cid)) orelse return error.BlockNotFound;
        const ts = self.timestamp();
        var response = try self.client.getObject(try self.name(try self.packName(location.pack_id)), .{ .start = location.offset, .end = location.offset + location.length - 1 }, &ts);
        defer response.deinit();
        if (response.body.len != location.length) return error.InvalidRangeResponse;
        var decoded = try backup.pack.decodeRangeChunk(self.allocator, response.body, self.cryptoKey());
        errdefer decoded.deinit(self.allocator);
        var hash: Cid = undefined;
        std.crypto.hash.sha2.Sha256.hash(decoded.data, &hash, .{});
        if (!std.mem.eql(u8, &hash, &cid) or !std.mem.eql(u8, &decoded.block_id, &self.blockId(cid))) return error.CidMismatch;
        return decoded.data;
    }
    pub fn verify(self: *Service, name_: ?[]const u8) !usize {
        var seen: std.AutoHashMap(Cid, void) = .init(self.allocator);
        defer seen.deinit();
        const names = if (name_) |n| &[_][]const u8{n} else try self.list("snapshots");
        for (names) |n| for ((try self.snapshot(n)).files) |file| {
            for (file.blocks) |cid| {
                if ((try seen.getOrPut(cid)).found_existing) continue;
                const bytes = try self.readBlock(cid);
                self.allocator.free(bytes);
            }
        };
        return seen.count();
    }
    /// Warm targets download and check every block. A cold target checks by
    /// listing (every indexed pack is there with all its bytes, every index
    /// segment and snapshot decrypts, every snapshot block is indexed) and
    /// never thaws; `download` asks for the thaws and then checks like warm.
    pub fn check(self: *Service, name_: ?[]const u8, download: bool, tier: Tier) !Check {
        if (!self.cold()) return .{ .blocks = try self.verify(name_) };
        const names = if (name_) |n| &[_][]const u8{n} else try self.list("snapshots");
        if (download) {
            var ready: Packs = .init(self.allocator);
            defer ready.deinit();
            var thaw: Restore = .{};
            for (names) |n| for ((try self.snapshot(n)).files) |file| {
                _ = try self.packsReady(file, &ready, tier, &thaw);
            };
            if (thaw.thawing_packs > 0) return .{ .packs = ready.count(), .thawing_packs = thaw.thawing_packs, .thawing_bytes = thaw.thawing_bytes };
            return .{ .blocks = try self.verify(name_), .packs = ready.count() };
        }
        var sizes: std.AutoHashMap([16]u8, u64) = .init(self.allocator);
        defer sizes.deinit();
        for (try self.listObjects("packs")) |object| try sizes.put(try backup.index.parsePackId(std.fs.path.basename(object.name)), object.size);
        var ends: std.AutoHashMap([16]u8, u64) = .init(self.allocator);
        defer ends.deinit();
        const entries = try self.index.toEntriesAlloc(self.allocator);
        defer self.allocator.free(entries);
        for (entries) |entry| {
            const slot = try ends.getOrPut(entry.pack_id);
            const end = entry.offset + entry.length;
            slot.value_ptr.* = if (slot.found_existing) @max(slot.value_ptr.*, end) else end;
        }
        var it = ends.iterator();
        while (it.next()) |pack| {
            const size = sizes.get(pack.key_ptr.*) orelse return error.PackMissing;
            if (size < pack.value_ptr.*) return error.PackTruncated;
        }
        var seen: std.AutoHashMap(Cid, void) = .init(self.allocator);
        defer seen.deinit();
        for (names) |n| for ((try self.snapshot(n)).files) |file| {
            for (file.blocks) |cid| {
                if ((try seen.getOrPut(cid)).found_existing) continue;
                if (!self.index.contains(self.blockId(cid))) return error.BlockNotFound;
            }
        };
        return .{ .blocks = seen.count(), .packs = ends.count(), .downloaded = false };
    }
    /// HEADs one pack. An archived pack with no thaw running gets one asked
    /// for; the answer says whether its bytes can be read now.
    fn thawPack(self: *Service, id: [16]u8, tier: Tier) !struct { readable: bool, size: u64 } {
        const ts = self.timestamp();
        const key = try self.name(try self.packName(id));
        var response = self.client.headObject(key, &ts) catch |err| switch (err) {
            error.NotFound => return error.PackMissing,
            else => return err,
        };
        defer response.deinit();
        const state = s3.objectState(&response);
        const size = state.size orelse 0;
        const class = std.meta.stringToEnum(StorageClass, state.storage_class) orelse StorageClass.STANDARD;
        if (!class.cold() or state.restore == .ready) return .{ .readable = true, .size = size };
        if (state.restore == .none) try self.client.restoreObject(key, .{ .days = thaw_days, .tier = tier }, &ts);
        return .{ .readable = false, .size = size };
    }
    /// True when every pack holding the file's blocks is readable. Asks for
    /// the thaw of each pack that is not, once per pack (`ready` remembers).
    fn packsReady(self: *Service, file: File, ready: *Packs, tier: Tier, progress: *Restore) !bool {
        var all = true;
        for (file.blocks) |cid| {
            const location = self.index.get(self.blockId(cid)) orelse return error.BlockNotFound;
            const slot = try ready.getOrPut(location.pack_id);
            if (!slot.found_existing) {
                slot.value_ptr.* = false; // stays "not ready" if the HEAD fails
                const pack = try self.thawPack(location.pack_id, tier);
                ready.getPtr(location.pack_id).?.* = pack.readable;
                if (!pack.readable) {
                    progress.thawing_packs += 1;
                    progress.thawing_bytes += pack.size;
                }
            }
            if (!ready.get(location.pack_id).?) all = false;
        }
        return all;
    }
    /// The pending job of an earlier restore into this directory, if any.
    fn loadJob(self: *Service, io: std.Io, destination: std.Io.Dir) !?Job {
        const bytes = destination.readFileAlloc(io, job_name, self.a(), .limited(64 * 1024)) catch |err| switch (err) {
            error.FileNotFound => return null,
            else => return err,
        };
        return self.parse(Job, bytes) catch error.InvalidRestoreJob;
    }
    fn saveJob(self: *Service, io: std.Io, destination: std.Io.Dir, job: Job) !void {
        const tmp = job_name ++ ".tmp";
        errdefer destination.deleteFile(io, tmp) catch {};
        {
            var file = try destination.createFile(io, tmp, .{ .truncate = true, .permissions = .fromMode(0o600) });
            defer file.close(io);
            try file.writePositionalAll(io, try self.json(job), 0);
            try file.sync(io);
        }
        try destination.rename(tmp, destination, job_name, io);
    }
    /// The warm restore: every pack is readable, so the count is final.
    pub fn restore(self: *Service, io: std.Io, name_: []const u8, path: ?[]const u8, destination: std.Io.Dir) !usize {
        return (try self.restoreRequest(io, name_, path, destination, .Bulk)).files;
    }
    /// Restores through an already-open directory capability. Every component
    /// is opened without following symlinks; existing output files are refused.
    /// On a cold target it first asks for the thaw of every pack the request
    /// needs, writes the files whose packs are readable, and leaves a job file
    /// in the destination while packs are thawing: the same call, repeated,
    /// skips the files already written and ends when none is left.
    pub fn restoreRequest(self: *Service, io: std.Io, name_: []const u8, path: ?[]const u8, destination: std.Io.Dir, tier: Tier) !Restore {
        if (path) |p| if (!manifest.validPath(p)) return error.InvalidPath;
        var result: Restore = .{};
        var matched = false;
        const is_cold = self.cold();
        var ready: Packs = .init(self.allocator);
        defer ready.deinit();
        const job = if (is_cold) try self.loadJob(io, destination) else null;
        if (job) |j| {
            const same_path = if (j.path) |old| path != null and std.mem.eql(u8, old, path.?) else path == null;
            if (j.version != 1 or !std.mem.eql(u8, j.snapshot, name_) or !same_path) return error.RestoreJobMismatch;
        }
        for ((try self.snapshot(name_)).files) |file| {
            if (path) |p| if (!under(file.path, p)) continue;
            matched = true;
            if (is_cold and !file.directory and !(try self.packsReady(file, &ready, tier, &result))) continue;
            if (file.directory) {
                const dummy = try std.fmt.allocPrint(self.a(), "{s}/.directory", .{file.path});
                const dir = try safeParent(io, destination, dummy);
                dir.close(io);
                continue;
            }
            var parent = try safeParent(io, destination, file.path);
            defer parent.close(io);
            if (job != null) {
                // Written by an earlier pass of this job: complete files only.
                if (parent.statFile(io, std.fs.path.basename(file.path), .{ .follow_symlinks = false })) |st| {
                    if (st.kind == .file and st.size == file.size) {
                        result.files += 1;
                        continue;
                    }
                } else |err| if (err != error.FileNotFound) return err;
            }
            const out = try parent.createFile(io, std.fs.path.basename(file.path), .{ .exclusive = true, .permissions = .fromMode(0o600) });
            var complete = false;
            defer {
                out.close(io);
                if (!complete) parent.deleteFile(io, std.fs.path.basename(file.path)) catch {};
            }
            try self.restoreFile(io, out, file);
            try out.sync(io);
            complete = true;
            result.files += 1;
        }
        if (path != null and !matched) return error.PathNotFound;
        if (result.thawing_packs > 0) {
            try self.saveJob(io, destination, .{ .snapshot = name_, .path = path, .tier = tier, .requested = if (job) |j| j.requested else self.now(), .packs = result.thawing_packs, .bytes = result.thawing_bytes });
        } else if (job != null) try destination.deleteFile(io, job_name);
        return result;
    }
    fn restoreFile(self: *Service, io: std.Io, out: std.Io.File, file: File) !void {
        var stack: std.ArrayList(Cid) = .empty;
        defer stack.deinit(self.allocator);
        try stack.append(self.allocator, file.cid);
        var offset: u64 = 0;
        var visited: usize = 0;
        while (stack.pop()) |cid| {
            visited += 1;
            if (visited > storage.dag.walk.blockBudget(file.size)) return error.DagTooLarge;
            const bytes = try self.readBlock(cid);
            defer self.allocator.free(bytes);
            switch (try storage.dag.codec.decode(bytes)) {
                .leaf => |data| {
                    if (data.len > file.size - offset) return error.FileTooLarge;
                    try out.writePositionalAll(io, data, offset);
                    offset += data.len;
                },
                .parent => |links| try storage.dag.walk.pushChildren(self.allocator, &stack, links),
                .dir => return error.IsDirectory,
            }
        }
        if (offset != file.size) return error.SizeMismatch;
    }
    /// Offsite portion only: durable encrypted intent, applied by the next run.
    pub fn forget(self: *Service, path: []const u8) !void {
        if (self.key == null) return error.Locked;
        if (!manifest.validPath(path)) return error.InvalidPath;
        try self.acquire();
        defer self.release();
        const mode = self.encrypted;
        self.encrypted = true;
        defer self.encrypted = mode;
        try self.putJson(try self.randomName("purges"), path);
    }
    fn purgePaths(self: *Service) ![]const []const u8 {
        const mode = self.encrypted;
        self.encrypted = true;
        defer self.encrypted = mode;
        var paths: std.ArrayList([]const u8) = .empty;
        for (try self.list("purges")) |n| {
            const p = try self.getJson([]const u8, n);
            if (!manifest.validPath(p)) return error.InvalidPurge;
            try paths.append(self.a(), p);
        }
        return paths.toOwnedSlice(self.a());
    }
    fn filtered(self: *Service, files: []const File, paths: []const []const u8) ![]const File {
        var result: std.ArrayList(File) = .empty;
        for (files) |f| if (!purged(f.path, paths)) try result.append(self.a(), f);
        return result.toOwnedSlice(self.a());
    }
    fn applyPurges(self: *Service) !void {
        const paths = try self.purgePaths();
        if (paths.len == 0) return;
        for (try self.list("snapshots")) |n| {
            const snap = try self.snapshot(n);
            const files = try self.filtered(snap.files, paths);
            if (files.len != snap.files.len) try self.putJson(n, Snapshot{ .time = snap.time, .files = files });
        }
        const catalog = try self.filtered(try self.getJson([]const File, "catalog"), paths);
        // Commit the keep set before GC. Replaying the durable purge after any
        // crash computes the same set, including when an old pack still exists.
        try self.putJson("catalog", catalog);
        var keep: std.AutoHashMap(Cid, void) = .init(self.allocator);
        defer keep.deinit();
        for (catalog) |f| for (f.blocks) |cid| {
            try keep.put(self.blockId(cid), {});
        };
        try self.repack(&keep);
    }
    fn loadDeferred(self: *Service) ![]const Deferred {
        return self.getJson([]const Deferred, "deferred") catch |err| switch (err) {
            error.NotFound => &.{},
            else => return err,
        };
    }
    /// The packs waiting for their minimum storage time, with the day it ends.
    fn saveDeferred(self: *Service, waiting: *std.AutoHashMap([16]u8, void), born: *std.AutoHashMap([16]u8, u64)) !void {
        var list_: std.ArrayList(Deferred) = .empty;
        var it = waiting.keyIterator();
        while (it.next()) |id| try list_.append(self.a(), .{ .pack = id.*, .removable = (born.get(id.*) orelse self.now()) + self.hold() });
        try self.putJson("deferred", list_.items);
    }
    /// A pack whose upload time is unknown counts as young: never delete early.
    fn young(self: *Service, born: *std.AutoHashMap([16]u8, u64), id: [16]u8) bool {
        const time = born.get(id) orelse return true;
        return time == 0 or self.now() < time + self.hold();
    }
    /// Warm targets replace a pack holding purged bytes at once. A target
    /// with a minimum storage time drops the purged blocks from the index at
    /// once and leaves the pack until that time ends: then an unreferenced
    /// pack is deleted, and one still holding kept blocks is thawed (asked
    /// here, ready on a later run), copied without the purged bytes, deleted.
    fn repack(self: *Service, keep: *std.AutoHashMap(Cid, void)) !void {
        const hold_seconds = self.hold();
        var born: std.AutoHashMap([16]u8, u64) = .init(self.allocator);
        defer born.deinit();
        var waiting: std.AutoHashMap([16]u8, void) = .init(self.allocator);
        defer waiting.deinit();
        var recorded: usize = 0;
        if (hold_seconds > 0) {
            for (try self.listObjects("packs")) |object| try born.put(try backup.index.parsePackId(std.fs.path.basename(object.name)), object.modified);
            for (try self.loadDeferred()) |d| try waiting.put(d.pack, {});
            recorded = waiting.count();
        }
        var changed = false;
        for (try self.list("index")) |segment| {
            const entries = try backup.index.decodeSegment(self.allocator, try self.get(segment), self.cryptoKey());
            defer self.allocator.free(entries);
            if (entries.len == 0) continue;
            var kept: usize = 0;
            for (entries) |entry| {
                if (!std.mem.eql(u8, &entry.pack_id, &entries[0].pack_id)) return error.InvalidIndex;
                if (keep.contains(entry.block_id)) kept += 1;
            }
            const pack = entries[0].pack_id;
            const removed = kept != entries.len;
            if (!removed and !waiting.contains(pack)) continue;
            if (hold_seconds > 0) {
                if (removed) {
                    // Record the pack before its segment forgets the purged blocks.
                    if (!waiting.contains(pack)) {
                        try waiting.put(pack, {});
                        try self.saveDeferred(&waiting, &born);
                        recorded = waiting.count();
                    }
                    var remaining: std.ArrayList(Entry) = .empty;
                    defer remaining.deinit(self.allocator);
                    for (entries) |entry| if (keep.contains(entry.block_id)) try remaining.append(self.allocator, entry);
                    const encoded = try backup.index.encodeSegment(self.allocator, remaining.items, self.cryptoKey());
                    defer self.allocator.free(encoded);
                    try self.put(segment, encoded);
                }
                if (kept == 0 or self.young(&born, pack)) continue;
                if (!(try self.thawPack(pack, .Bulk)).readable) continue;
            }
            var writer = try backup.pack.Writer.init(self.allocator, .{ .key = self.cryptoKey(), .target_size = 512 * 1024 * 1024 });
            defer writer.deinit();
            for (entries) |entry| {
                if (!keep.contains(entry.block_id)) continue;
                const ts = self.timestamp();
                var response = try self.client.getObject(try self.name(try self.packName(entry.pack_id)), .{ .start = entry.offset, .end = entry.offset + entry.length - 1 }, &ts);
                defer response.deinit();
                var decoded = try backup.pack.decodeRangeChunk(self.allocator, response.body, self.cryptoKey());
                defer decoded.deinit(self.allocator);
                if (!std.mem.eql(u8, &decoded.block_id, &entry.block_id)) return error.CidMismatch;
                _ = try writer.append(entry.block_id, decoded.data);
            }
            const new_id = try backup.index.generatePackId();
            try self.flush(&writer, new_id, segment);
        }
        // Sweep packs only AFTER all segment replacements commit. A retry also
        // finds old packs orphaned between a segment commit and its deletion.
        var referenced: std.AutoHashMap([16]u8, void) = .init(self.allocator);
        defer referenced.deinit();
        self.index.deinit();
        self.index = .init(self.allocator);
        for (try self.list("index")) |segment| try self.index.mergeSegment(try self.get(segment), self.cryptoKey());
        const entries = try self.index.toEntriesAlloc(self.allocator);
        defer self.allocator.free(entries);
        for (entries) |e| try referenced.put(e.pack_id, {});
        for (try self.list("packs")) |n| {
            const id = try backup.index.parsePackId(std.fs.path.basename(n));
            if (referenced.contains(id)) continue;
            if (hold_seconds > 0 and self.young(&born, id)) {
                if (!waiting.contains(id)) changed = true;
                try waiting.put(id, {});
                continue;
            }
            try self.delete(n);
            if (waiting.remove(id)) changed = true;
        }
        if (hold_seconds == 0) return;
        // A replaced pack is gone; one whose upload this run just made is not waiting.
        var gone: std.ArrayList([16]u8) = .empty;
        var it = waiting.keyIterator();
        while (it.next()) |id| if (!born.contains(id.*)) try gone.append(self.a(), id.*);
        for (gone.items) |id| _ = waiting.remove(id);
        if (changed or gone.items.len > 0 or waiting.count() != recorded) try self.saveDeferred(&waiting, &born);
    }
    fn pruneSnapshots(self: *Service) !void {
        const names = try self.list("snapshots");
        const times = try self.a().alloc(u64, names.len);
        for (names, times) |n, *t| t.* = (try self.snapshot(n)).time;
        const retain = try retention(self.a(), times, self.now(), self.config.retain_daily, self.config.retain_monthly);
        for (names, retain) |n, yes| if (!yes) try self.delete(n);
    }
};
fn validFile(file: File) bool {
    if (!manifest.validPath(file.path) or file.blocks.len > 1 << 20) return false;
    if (file.directory) return file.blocks.len == 0 and file.size == 0;
    for (file.blocks) |cid| if (std.mem.eql(u8, &cid, &file.cid)) return true;
    return false;
}
fn catalogHas(files: []const File, file: File) bool {
    for (files) |f| if (std.mem.eql(u8, f.path, file.path) and std.mem.eql(u8, &f.cid, &file.cid) and f.directory == file.directory) return true;
    return false;
}
fn under(path: []const u8, prefix: []const u8) bool {
    return std.mem.eql(u8, path, prefix) or (std.mem.startsWith(u8, path, prefix) and path.len > prefix.len and path[prefix.len] == '/');
}
fn purged(path: []const u8, paths: []const []const u8) bool {
    for (paths) |p| if (under(path, p)) return true;
    return false;
}
fn safeParent(io: std.Io, root: std.Io.Dir, path: []const u8) !std.Io.Dir {
    var dir = try root.openDir(io, ".", .{ .follow_symlinks = false });
    errdefer dir.close(io);
    var parts = std.mem.splitScalar(u8, std.fs.path.dirname(path) orelse "", '/');
    while (parts.next()) |part| {
        if (part.len == 0) continue;
        dir.createDir(io, part, .fromMode(0o700)) catch |err| if (err != error.PathAlreadyExists) return err;
        const next = try dir.openDir(io, part, .{ .follow_symlinks = false });
        dir.close(io);
        dir = next;
    }
    return dir;
}
fn month(time: u64) u64 {
    const epoch: std.time.epoch.EpochSeconds = .{ .secs = time };
    const yd = epoch.getEpochDay().calculateYearDay();
    return @as(u64, yd.year) * 12 + yd.calculateMonthDay().month.numeric() - 1;
}
/// All snapshots in the last N calendar days, plus the latest per calendar
/// month. Monthly 0 is forever; a positive value is a count of recent months.
pub fn retention(a: Allocator, times: []const u64, now: u64, daily: u32, monthly: u32) ![]bool {
    const result = try a.alloc(bool, times.len);
    errdefer a.free(result);
    var latest: std.AutoHashMap(u64, usize) = .init(a);
    defer latest.deinit();
    const day = now / 86400;
    for (times, 0..) |t, i| {
        result[i] = t / 86400 <= day and day - t / 86400 < daily;
        const m = month(t);
        if (m > month(now) or (monthly != 0 and month(now) - m >= monthly)) continue;
        const slot = try latest.getOrPut(m);
        if (!slot.found_existing or t > times[slot.value_ptr.*]) slot.value_ptr.* = i;
    }
    var it = latest.valueIterator();
    while (it.next()) |i| result[i.*] = true;
    return result;
}

test {
    _ = @import("offsite_test.zig");
}
