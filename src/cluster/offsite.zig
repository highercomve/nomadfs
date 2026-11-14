//! Offsite is a cluster distribution target: fs supplies the files and their
//! reachable CIDs, storage supplies verified local blocks, net transports S3.
//! All upload, retention, purge and thaw policy lives here for every UI.
//! Paths are opaque names here: what a path means, which version of a file
//! is wanted and how files reach a local directory belong to fs (restore.zig),
//! which asks this target for snapshots, history, thaws and verified bytes.
//! The historical catalog deliberately outlives snapshots: ordinary deletes
//! and retention must never release backup data. Only a purge removes blocks.
//! Bucket metadata is generations: index segments, snapshots, the catalog,
//! purges and the manifest listing them are written once under new names,
//! and one small `head` names the committed manifest, moved only with
//! If-Match. Whatever the head does not name is garbage, deleted by a later
//! run after a grace much longer than the lease.
const std = @import("std");
const backup = @import("../backup/mod.zig");
const s3 = @import("../net/s3/mod.zig");
const storage = @import("../storage/mod.zig");
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
/// Garbage stays this long after the head stopped naming it: a reader that
/// started before, or a writer still sending, never loses an object under it.
const grace_seconds = 24 * 3600;
/// A thawed copy stays readable this long: enough to finish a big restore.
const thaw_days = 7;
/// Uploads run on an hourly poll; a round this close to its time is due.
const schedule_slack = 3600;
/// Bounds of what a source or a stored snapshot may describe.
const max_files = 100_000;
const max_name = 4096;
pub const Tier = s3.RestoreTier;
/// `first_seen`/`last_seen`: set in the catalog only, one unbroken stretch
/// of upload runs that found this version at the path (0: before they were
/// kept). A version that comes back after another one has a second entry.
/// `first_run`/`last_run`: the numbers of those runs. Run numbers only grow,
/// so they order what the clock cannot: two runs within one second (0: the
/// catalog was written before they were kept).
pub const File = struct { path: []const u8, cid: Cid, size: u64, mtime: u64 = 0, blocks: []const Cid, directory: bool = false, first_seen: u64 = 0, last_seen: u64 = 0, first_run: u64 = 0, last_run: u64 = 0 };
pub const Snapshot = struct { time: u64, files: []const File };
/// One content of one path: what a purge names.
pub const Version = struct { path: []const u8, cid: Cid };
/// What the source can describe now. `waiting`: files left out because
/// their blocks are not all in the local store yet (the keeper is still
/// fetching them); a later run takes them. `absent` names them: the folder
/// lists these versions although they cannot be uploaded yet.
pub const Listing = struct { files: []const File, waiting: usize = 0, absent: []const Version = &.{} };
pub const Source = struct {
    ctx: *anyopaque,
    filesFn: *const fn (*anyopaque, Allocator) anyerror!Listing,
};
pub const Device = struct { id: Cid, secret: Key, public: Key };
pub const Report = struct {
    uploaded_blocks: usize = 0,
    uploaded_bytes: u64 = 0,
    snapshot: []const u8 = "",
    recovery_phrase: ?[]const u8 = null,
    /// The new target took another target's key: the words are the same.
    reused_key: bool = false,
    /// Files not in this snapshot: their blocks are not all here yet.
    waiting_files: usize = 0,
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
/// A restore ends when no pack is thawing any more. `purged_files`: files
/// of the job left out because they were deleted from the backup meanwhile,
/// counted since the job began; `omitted` names them (path and content),
/// in the allocator the restore was called with: `deinit` frees them.
pub const Restore = struct {
    files: usize = 0,
    thawing_packs: usize = 0,
    thawing_bytes: u64 = 0,
    purged_files: usize = 0,
    omitted: []const Version = &.{},

    pub fn deinit(self: *Restore, allocator: Allocator) void {
        for (self.omitted) |v| allocator.free(v.path);
        allocator.free(self.omitted);
        self.omitted = &.{};
    }
};
/// Receives a file's bytes in order, each piece with its offset in the file.
pub const Sink = struct {
    ctx: *anyopaque,
    writeFn: *const fn (*anyopaque, u64, []const u8) anyerror!void,
};
pub const Check = struct {
    blocks: usize = 0,
    packs: usize = 0,
    /// False: packs were checked by listing only (name and size).
    downloaded: bool = true,
    thawing_packs: usize = 0,
    thawing_bytes: u64 = 0,
};
const Info = struct { name: []const u8, size: u64, modified: u64 };
/// A pack the head names. Its class and the first time it may be deleted are
/// fixed when it is uploaded, whatever the target is configured to later.
/// `purged`: it still holds purged bytes and waits to be copied without them.
const PackRecord = struct { pack: [16]u8, class: StorageClass, removable: u64, purged: bool = false };
/// An object the head names no more, and when it may be deleted.
const Garbage = struct { name: []const u8, removable: u64 };
/// A snapshot keeps its name when a purge rewrites it into a new object.
const SnapshotRef = struct { name: []const u8, object: []const u8 };
/// A purge covers exactly the file versions that were there when it was
/// asked for: `versions`, taken from the history and the folder by `forget`
/// (also the ones whose blocks were not here yet). It is kept while the
/// source still lists one of them, so that one is never uploaded; anything
/// else at the path is. `applied`: the history was rewritten without them.
const Purge = struct { path: []const u8, time: u64, applied: bool = false, versions: []const Version = &.{} };
/// The one mutable object: names the committed generation and is replaced
/// only with If-Match. Readable without the key: `newest` is the time of the
/// last finished run, `waiting` the files it left out, `sweep_at` when the
/// first removed pack may be deleted (0: none).
const Head = struct { version: u32 = 1, generation: u64 = 0, manifest: []const u8 = "", newest: u64 = 0, waiting: usize = 0, sweep_at: u64 = 0 };
/// Everything a generation is made of. An object it does not name is garbage.
const Manifest = struct {
    segments: []const []const u8 = &.{},
    snapshots: []const SnapshotRef = &.{},
    catalog: []const u8 = "",
    packs: []const PackRecord = &.{},
    garbage: []const Garbage = &.{},
    purges: []const []const u8 = &.{},
};
/// Packs already asked about in one request: true when readable now.
pub const Packs = std.AutoHashMap([16]u8, bool);
/// The create-only root of a backup. `setup` names the immutable key
/// material it was made with (`keys/<setup>/`), `creator` the device that
/// made it. Whatever else is under `keys/` belongs to a setup that never
/// finished.
const Layout = struct { version: u32 = 3, encrypt: bool, key_id: [8]u8, setup: []const u8 = "", creator: Cid = [_]u8{0} ** 32 };
const layout_name = "nomadfs-backup.json";
/// What every front end says for error.BucketVersioningEnabled.
pub const versioned_bucket = "the bucket has versioning on: turn off versioning or use a bucket without it; a versioned bucket keeps deleted backup data";
/// Where a block's bytes are. A pack is never rewritten, so this holds for
/// as long as the pack exists, whatever the head names later.
pub const Location = backup.index.Location;
/// Answers where a block is from a plan made earlier (null: not in it).
pub const Locator = struct {
    ctx: *anyopaque,
    findFn: *const fn (*anyopaque, Cid) ?Location,
};
pub const Class = StorageClass;
/// A restore job keeps the packs of its plan: no run deletes a pack an
/// unexpired pin names. Every pass of the restore writes it again.
pub const pin_seconds = 14 * 86400;
/// However often it is renewed, a pin protects nothing this long after its
/// job began: a job resumed for ever cannot keep purged bytes. The restore
/// then plans again from the head.
pub const pin_limit_seconds = 30 * 86400;
/// A pin is deleted only this long after it expired. A restore may renew its
/// pin while a run is deleting it; this far past the expiry the job has long
/// been planning from the head, so the lost pin costs it nothing.
pub const pin_keep_seconds = 30 * 86400;
/// Packs a sweep decides on between two reads of the pins.
const sweep_batch = 64;
/// `created`: when the job began (0: unknown, protects nothing).
const Pin = struct {
    version: u32 = 2,
    expires: u64,
    created: u64 = 0,
    packs: []const [16]u8,

    /// The time this pin stops protecting its packs.
    fn until(self: Pin) u64 {
        return @min(self.expires, self.created +| pin_limit_seconds);
    }
};
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
    /// The generation this session read (or last committed), in the arena.
    head: Head = .{},
    head_etag: ?[]const u8 = null,
    segments: std.ArrayList([]const u8) = .empty,
    snapshots: std.ArrayList(SnapshotRef) = .empty,
    packs: std.ArrayList(PackRecord) = .empty,
    garbage: std.ArrayList(Garbage) = .empty,
    purges: std.ArrayList([]const u8) = .empty,
    catalog: []const u8 = "",
    /// The key material the root names: `keys/<setup>/`.
    setup_id: []const u8 = "",
    /// Packs a sweep deletes before it reads the pins again.
    sweep_batch: usize = sweep_batch,

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
    pub fn now(self: *Service) u64 {
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
    /// True when a pack may need a thaw before it can be read: the target
    /// is cold, or it was when one of its packs was uploaded.
    pub fn cold(self: *Service) bool {
        if (self.config.storage_class.cold()) return true;
        for (self.packs.items) |p| if (p.class.cold()) return true;
        return false;
    }
    /// The class a pack was uploaded with; null when the head has no record.
    pub fn recordedClass(self: *Service, id: [16]u8) ?StorageClass {
        return self.packs.items[self.packIndex(id) orelse return null].class;
    }
    /// Seconds a pack uploaded now must stay before it may be deleted.
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
    /// Generation metadata is immutable: written once under a new name
    /// (If-None-Match), never replaced. Only the head moves.
    fn create(self: *Service, relative: []const u8, bytes: []const u8) !void {
        try self.renew();
        const ts = self.timestamp();
        var response = self.client.putObject(try self.name(relative), .{ .bytes = bytes }, .{ .condition = .if_none_match }, &ts) catch |err| switch (err) {
            error.PreconditionFailed => return error.LeaseLost,
            else => return err,
        };
        defer response.deinit();
    }
    fn createJson(self: *Service, dir: []const u8, value: anytype) ![]const u8 {
        const relative = try self.randomName(dir);
        try self.create(relative, try self.seal(try self.json(value)));
        return relative;
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
    /// An object of the setup the root names.
    fn keyName(self: *Service, leaf: []const u8) ![]const u8 {
        if (self.setup_id.len == 0) return error.Locked;
        return std.fmt.allocPrint(self.a(), "keys/{s}/{s}", .{ self.setup_id, leaf });
    }
    fn wrapName(self: *Service, id: Cid) ![]const u8 {
        const hex = std.fmt.bytesToHex(id, .lower);
        return self.keyName(try std.fmt.allocPrint(self.a(), "{s}.wrap", .{hex}));
    }
    /// The root, or null for a bucket (prefix) no setup has finished in.
    fn loadLayout(self: *Service) !?Layout {
        const bytes = self.get(layout_name) catch |err| switch (err) {
            error.NotFound => return null,
            else => return err,
        };
        const layout = try self.parse(Layout, bytes);
        if (layout.version != 3) return error.UnsupportedBackupVersion;
        if (layout.setup.len != 32) return error.InvalidMetadata;
        for (layout.setup) |c| if (!std.ascii.isHex(c)) return error.InvalidMetadata;
        return layout;
    }
    /// A versioned bucket keeps every deleted object as an old version: a
    /// purge would never remove its bytes. Such a bucket is refused.
    fn requireUnversioned(self: *Service) !void {
        const ts = self.timestamp();
        if (try self.client.getBucketVersioning(&ts) != .off) return error.BucketVersioningEnabled;
    }
    pub fn unlock(self: *Service, phrase: ?[]const u8) !void {
        try self.unlockKey(phrase);
        try self.loadHead();
        try self.loadIndex();
    }
    /// Reads the committed generation. Readers and writers trust only what
    /// the head names; a bucket with no head yet is an empty backup.
    fn loadHead(self: *Service) !void {
        self.head = .{};
        self.head_etag = null;
        self.segments = .empty;
        self.snapshots = .empty;
        self.packs = .empty;
        self.garbage = .empty;
        self.purges = .empty;
        self.catalog = "";
        for (0..3) |_| {
            const ts = self.timestamp();
            var response = self.client.getObject(try self.name("head"), null, &ts) catch |err| switch (err) {
                error.NotFound => return,
                else => return err,
            };
            defer response.deinit();
            const head = try self.parse(Head, response.body);
            if (head.version != 1) return error.UnsupportedBackupVersion;
            if (!std.mem.startsWith(u8, head.manifest, "manifests/")) return error.InvalidMetadata;
            // A commit between the two reads removed that manifest: read again.
            const manifest = self.getJson(Manifest, head.manifest) catch |err| switch (err) {
                error.NotFound => continue,
                else => return err,
            };
            if (manifest.segments.len > max_objects or manifest.packs.len > max_objects or manifest.garbage.len > max_objects) return error.InvalidMetadata;
            self.head = head;
            self.head_etag = try self.a().dupe(u8, response.header("etag") orelse return error.MissingEtag);
            try self.segments.appendSlice(self.a(), manifest.segments);
            try self.snapshots.appendSlice(self.a(), manifest.snapshots);
            try self.packs.appendSlice(self.a(), manifest.packs);
            try self.garbage.appendSlice(self.a(), manifest.garbage);
            try self.purges.appendSlice(self.a(), manifest.purges);
            self.catalog = manifest.catalog;
            return;
        }
        return error.HeadChanged;
    }
    /// Reads the committed generation again: what a reader does when an
    /// object of the one it had is gone.
    pub fn refresh(self: *Service) !void {
        if (self.key == null) return error.Locked;
        try self.loadHead();
        try self.loadIndex();
    }
    fn loadIndex(self: *Service) !void {
        self.index.deinit();
        self.index = .init(self.allocator);
        for (self.segments.items) |segment| try self.index.mergeSegment(try self.get(segment), self.cryptoKey());
    }
    /// Publishes this session's state as the next generation. The manifest
    /// is a new object and the head moves to it only if nobody committed
    /// since it was read (If-Match): a writer whose lease ran out while a
    /// request stalled finds the head changed and can never publish.
    fn commit(self: *Service) !void {
        const old = self.head.manifest;
        var next = self.head;
        next.generation += 1;
        next.sweep_at = 0;
        for (self.garbage.items) |g| {
            if (!std.mem.startsWith(u8, g.name, "packs/")) continue;
            next.sweep_at = if (next.sweep_at == 0) g.removable else @min(next.sweep_at, g.removable);
        }
        next.manifest = try self.createJson("manifests", Manifest{ .segments = self.segments.items, .snapshots = self.snapshots.items, .catalog = self.catalog, .packs = self.packs.items, .garbage = self.garbage.items, .purges = self.purges.items });
        try self.renew();
        const ts = self.timestamp();
        const condition: s3.client.Condition = if (self.head_etag) |etag| .{ .if_match = etag } else .if_none_match;
        var response = self.client.putObject(try self.name("head"), .{ .bytes = try self.json(next) }, .{ .condition = condition }, &ts) catch |err| switch (err) {
            error.PreconditionFailed => return error.LeaseLost,
            else => return err,
        };
        defer response.deinit();
        self.head_etag = try self.a().dupe(u8, response.header("etag") orelse return error.MissingEtag);
        self.head = next;
        // Only the replaced head named the old manifest; a reader that still
        // wants it reads the head again.
        if (old.len > 0) self.delete(old) catch {};
    }
    /// The head stops naming an object. It stays for the grace (and a pack
    /// for its minimum storage time, `hold_until`), then a later run deletes it.
    fn discard(self: *Service, relative: []const u8, hold_until: u64) !void {
        try self.garbage.append(self.a(), .{ .name = relative, .removable = @max(self.now() + grace_seconds, hold_until) });
    }
    /// Deletes the garbage whose time has come. Only records a committed
    /// head holds are old enough, and nothing ever names such an object again.
    /// A pack a restore job pins waits, and is looked at again within the
    /// grace. The pins are read again before every batch of packs: one
    /// written or renewed while the sweep runs counts for the packs still to
    /// go. A pin that lands after its batch was decided loses the pack; its
    /// restore finds the pack gone and plans again from the head.
    fn sweep(self: *Service) !void {
        var pinned: std.AutoHashMap([16]u8, u64) = .init(self.allocator);
        defer pinned.deinit();
        const batch = @max(self.sweep_batch, 1);
        var decided: usize = batch;
        var i: usize = 0;
        while (i < self.garbage.items.len) {
            const item = &self.garbage.items[i];
            if (self.now() < item.removable) {
                i += 1;
                continue;
            }
            if (std.mem.startsWith(u8, item.name, "packs/")) {
                if (decided >= batch) {
                    pinned.clearRetainingCapacity();
                    try self.loadPins(&pinned);
                    decided = 0;
                }
                decided += 1;
                const id: ?[16]u8 = backup.index.parsePackId(item.name["packs/".len..]) catch null;
                if (if (id) |pack| pinned.get(pack) else null) |until| {
                    item.removable = @min(until, self.now() + grace_seconds);
                    i += 1;
                    continue;
                }
            }
            try self.delete(item.name);
            _ = self.garbage.swapRemove(i);
        }
    }
    fn pinName(self: *Service, job: [16]u8) ![]const u8 {
        return std.fmt.allocPrint(self.a(), "pins/{s}", .{std.fmt.bytesToHex(job, .lower)});
    }
    /// Keeps `packs` in the bucket for a restore job that began at `created`,
    /// for `pin_seconds` from now and never past `pin_limit_seconds` after
    /// `created`. Needs no lease: only the job writes its pin. A pin is a
    /// request, not a lock: a run that read the pins before this write may
    /// still delete a pack, and the job must then plan again from the head.
    pub fn pin(self: *Service, job: [16]u8, packs: []const [16]u8, created: u64) !void {
        if (self.key == null) return error.Locked;
        if (packs.len > max_objects) return error.TooManyObjects;
        const sealed = try self.seal(try self.json(Pin{ .expires = self.now() + pin_seconds, .created = created, .packs = packs }));
        const ts = self.timestamp();
        var response = try self.client.putObject(try self.name(try self.pinName(job)), .{ .bytes = sealed }, .{}, &ts);
        defer response.deinit();
    }
    /// The job is over: its packs follow the head again.
    pub fn unpin(self: *Service, job: [16]u8) !void {
        const ts = self.timestamp();
        try self.client.deleteObject(try self.name(try self.pinName(job)), &ts);
    }
    /// The packs live pins name, each with the latest time one protects it
    /// to. A pin is deleted `pin_keep_seconds` after it expired and nothing
    /// is checked afterwards: one renewed at that very moment is written
    /// again by its job's next pass. One that cannot be read protects
    /// nothing: its restore plans again from the head.
    fn loadPins(self: *Service, pinned: *std.AutoHashMap([16]u8, u64)) !void {
        for (try self.listObjects("pins")) |object| {
            const sealed = self.get(object.name) catch |err| switch (err) {
                error.NotFound => continue,
                else => return err,
            };
            const found: ?Pin = self.readPin(sealed) catch |err| switch (err) {
                error.OutOfMemory => return err,
                else => null,
            };
            const written = if (object.modified == 0) self.now() else object.modified;
            const expires = if (found) |p| p.expires else written + pin_seconds;
            if (self.now() >= expires +| pin_keep_seconds) {
                try self.delete(object.name);
                continue;
            }
            const live = found orelse continue;
            const until = live.until();
            if (self.now() >= until) continue;
            for (live.packs) |pack| {
                const slot = try pinned.getOrPut(pack);
                slot.value_ptr.* = if (slot.found_existing) @max(slot.value_ptr.*, until) else until;
            }
        }
    }
    fn readPin(self: *Service, sealed: []const u8) !Pin {
        const result = try self.parse(Pin, try self.open(sealed));
        if (result.version != 2 or result.packs.len > max_objects) return error.InvalidMetadata;
        return result;
    }
    /// Objects no head names: left by a run that stopped before its commit
    /// or by a writer that lost the race. Recorded now, deleted after the grace.
    fn adoptOrphans(self: *Service) !void {
        var known: std.StringHashMap(void) = .init(self.allocator);
        defer known.deinit();
        for (self.segments.items) |n| try known.put(n, {});
        for (self.snapshots.items) |ref| try known.put(ref.object, {});
        for (self.purges.items) |n| try known.put(n, {});
        for (self.garbage.items) |g| try known.put(g.name, {});
        for (self.packs.items) |p| try known.put(try self.packName(p.pack), {});
        try known.put(self.catalog, {});
        try known.put(self.head.manifest, {});
        for ([_][]const u8{ "packs", "index", "snapshots", "catalog", "manifests", "purges" }) |dir| {
            for (try self.listObjects(dir)) |object| {
                if (known.contains(object.name)) continue;
                try self.discard(object.name, if (std.mem.eql(u8, dir, "packs")) try self.orphanHold(object) else 0);
            }
        }
    }
    /// A pack with no record keeps the minimum storage time of the class the
    /// bucket reports for it; a class not known here counts as the longest.
    fn orphanHold(self: *Service, object: Info) !u64 {
        const ts = self.timestamp();
        var response = self.client.headObject(try self.name(object.name), &ts) catch |err| switch (err) {
            error.NotFound => return 0,
            else => return err,
        };
        defer response.deinit();
        const class = std.meta.stringToEnum(StorageClass, s3.objectState(&response).storage_class) orelse StorageClass.DEEP_ARCHIVE;
        const born = if (object.modified == 0) self.now() else object.modified;
        return born + @as(u64, class.minDays()) * 86400;
    }
    /// True when a pack still holding purged bytes may now be copied without them.
    fn packsAgedOut(self: *Service) bool {
        for (self.packs.items) |p| if (p.purged and self.now() >= p.removable) return true;
        return false;
    }
    fn packIndex(self: *Service, id: [16]u8) ?usize {
        for (self.packs.items, 0..) |p, i| if (std.mem.eql(u8, &p.pack, &id)) return i;
        return null;
    }
    fn loadCatalog(self: *Service) ![]const File {
        if (self.catalog.len == 0) return &.{};
        return self.getJson([]const File, self.catalog);
    }
    /// False for a bucket (prefix) no setup has finished in yet.
    pub fn initialised(self: *Service) !bool {
        return (try self.loadLayout()) != null;
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
        const layout = (try self.loadLayout()) orelse return error.NotFound;
        try self.unlockWith(layout, phrase);
    }
    fn unlockWith(self: *Service, layout: Layout, phrase: ?[]const u8) !void {
        self.encrypted = layout.encrypt;
        self.setup_id = layout.setup;
        const blob = self.get(try self.wrapName(self.device.id)) catch |err| switch (err) {
            error.NotFound => "",
            else => return err,
        };
        self.key = backup.keys.unwrapForDevice(blob, self.device.secret) catch blk: {
            const words = phrase orelse return error.RecoveryPhraseRequired;
            break :blk try backup.keys.unwrapWithRecovery(self.allocator, try self.get(try self.keyName("recovery.wrap")), words);
        };
        if (!std.mem.eql(u8, &layout.key_id, &backup.keys.keyId(self.key.?))) return error.KeyIdMismatch;
    }
    /// Opens the backup, creating it in an empty bucket. Creation is one
    /// create-only root naming key material already written under a random
    /// setup id: a setup that stopped before its root left nothing a later
    /// one trips over, and two devices cannot both win.
    fn setup(self: *Service) !void {
        const layout = (try self.loadLayout()) orelse return self.initialise();
        try self.unlockWith(layout, null);
        try self.loadHead();
        try self.loadIndex();
        // This device made the backup and no run has committed since: the
        // words were perhaps never shown (the run stopped after the root).
        if (self.head_etag == null and std.mem.eql(u8, &layout.creator, &self.device.id)) _ = try self.recoveryKey();
    }
    fn initialise(self: *Service) !void {
        self.encrypted = self.config.encrypt;
        self.key = self.seed_key orelse try backup.keys.generateKey();
        var entropy = if (self.seed_phrase) |words| try backup.recovery_words.decodePhrase(words) else try backup.keys.generateKey();
        defer std.crypto.secureZero(u8, &entropy);
        var buf: [backup.recovery_words.max_phrase_len]u8 = undefined;
        defer std.crypto.secureZero(u8, &buf);
        const phrase = backup.recovery_words.formatPhrase(entropy, &buf);
        const id = backup.index.formatPackId(try backup.index.generatePackId());
        self.setup_id = try self.a().dupe(u8, &id);
        const recovery = try backup.keys.wrapWithRecovery(self.allocator, self.key.?, phrase);
        try self.create(try self.keyName("recovery.wrap"), &recovery);
        const device_wrap = try backup.keys.wrapForDevice(self.key.?, self.device.public);
        try self.create(try self.wrapName(self.device.id), &device_wrap);
        // Recovery words stay encrypted even in the explicitly clear backup mode.
        const saved_mode = self.encrypted;
        self.encrypted = true;
        const sealed_entropy = try self.seal(&entropy);
        self.encrypted = saved_mode;
        try self.create(try self.keyName("recovery-entropy"), sealed_entropy);
        const root = Layout{ .encrypt = self.encrypted, .key_id = backup.keys.keyId(self.key.?), .setup = self.setup_id, .creator = self.device.id };
        self.create(layout_name, try self.json(root)) catch |err| {
            if (err != error.LeaseLost) return err;
            // A root is there. Ours, when the answer to our write was lost:
            // go on. Another device's: it won, and this setup is dropped.
            const winner = (try self.loadLayout()) orelse return err;
            if (!std.mem.eql(u8, winner.setup, self.setup_id)) {
                self.dropSetup(self.setup_id);
                return err;
            }
        };
        self.created_phrase = try self.a().dupe(u8, phrase);
        self.sweepSetups();
        try self.loadHead();
        try self.loadIndex();
    }
    /// Best effort: the three objects of a setup no root names.
    fn dropSetup(self: *Service, id: []const u8) void {
        const dir = std.fmt.allocPrint(self.a(), "keys/{s}", .{id}) catch return;
        for (self.list(dir) catch return) |relative| self.delete(relative) catch {};
    }
    /// Best effort, by the device that just published the root: key material
    /// of setups that stopped before theirs. Nothing can name it any more.
    fn sweepSetups(self: *Service) void {
        const mine = std.fmt.allocPrint(self.a(), "keys/{s}/", .{self.setup_id}) catch return;
        for (self.list("keys") catch return) |relative| {
            if (!std.mem.startsWith(u8, relative, mine)) self.delete(relative) catch {};
        }
    }
    /// Explicitly requested re-display requires an unlockable envelope.
    pub fn recoveryKey(self: *Service) ![]const u8 {
        if (self.key == null) return error.Locked;
        if (self.created_phrase) |phrase| return phrase;
        const mode = self.encrypted;
        self.encrypted = true;
        defer self.encrypted = mode;
        const entropy = try self.open(try self.get(try self.keyName("recovery-entropy")));
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
        const relative = try self.wrapName(id);
        _ = self.get(relative) catch |err| {
            if (err != error.NotFound) return err;
            const wrapped = try backup.keys.wrapForDevice(self.key orelse return error.Locked, public);
            try self.put(relative, &wrapped);
            return;
        };
    }
    /// Of an unlocked target: what the committed head names.
    pub fn status(self: *Service) !Status {
        const names = try self.snapshotNames();
        var result: Status = .{ .snapshots = names, .indexed_blocks = self.index.count(), .storage_class = self.config.storage_class, .schedule = self.config.schedule };
        for (self.packs.items) |p| if (p.purged) deferred(&result, p.removable);
        for (self.garbage.items) |g| if (std.mem.startsWith(u8, g.name, "packs/")) deferred(&result, g.removable);
        return result;
    }
    fn deferred(result: *Status, removable: u64) void {
        result.deferred_first = if (result.deferred_packs == 0) removable else @min(result.deferred_first, removable);
        result.deferred_last = @max(result.deferred_last, removable);
        result.deferred_packs += 1;
    }
    fn snapshotNames(self: *Service) ![]const []const u8 {
        const names = try self.a().alloc([]const u8, self.snapshots.items.len);
        for (self.snapshots.items, names) |ref, *n| n.* = ref.name;
        return names;
    }
    /// True when the last finished run is older than the target's schedule,
    /// when it left files out that waited for blocks (the head remembers, so
    /// a restart keeps the hourly retry), or when a removed pack may now be
    /// deleted. Only the periodic uploader asks; an explicit run always uploads.
    pub fn due(self: *Service) !bool {
        const ts = self.timestamp();
        var response = self.client.getObject(try self.name("head"), null, &ts) catch |err| switch (err) {
            error.NotFound => return true,
            else => return err,
        };
        defer response.deinit();
        const head = try self.parse(Head, response.body);
        if (head.newest == 0 or head.waiting > 0) return true;
        if (head.sweep_at != 0 and self.now() >= head.sweep_at) return true;
        return self.now() + schedule_slack >= head.newest + self.config.schedule.seconds();
    }
    pub fn snapshot(self: *Service, name_: []const u8) !Snapshot {
        const object = for (self.snapshots.items) |ref| {
            if (std.mem.eql(u8, ref.name, name_)) break ref.object;
        } else return error.InvalidSnapshot;
        const result = try self.getJson(Snapshot, object);
        if (result.files.len > max_files) return error.InvalidSnapshot;
        for (result.files) |file| if (!validFile(file)) return error.InvalidSnapshot;
        return result;
    }
    fn blockId(self: *Service, cid: Cid) Cid {
        return backup.index.blockIdForCid(self.cryptoKey(), cid);
    }
    fn packName(self: *Service, id: [16]u8) ![]const u8 {
        return std.fmt.allocPrint(self.a(), "packs/{s}", .{backup.index.formatPackId(id)});
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
        // A pack is immutable: its name is never given to other bytes.
        var response = try self.client.completeMultipartUpload(full_name, upload, parts.items, .if_none_match, &ts);
        response.deinit();
    }
    /// Uploads the pack and its index segment; returns the segment for the
    /// caller to add to the generation it commits (null: nothing to write).
    fn flush(self: *Service, writer: *backup.pack.Writer, id: [16]u8) !?[]const u8 {
        if (writer.blockCount() == 0) return null;
        var entries: std.ArrayList(Entry) = .empty;
        defer entries.deinit(self.allocator);
        for (writer.spans()) |span| try entries.append(self.allocator, .{ .block_id = span.block_id, .pack_id = id, .offset = span.offset, .length = span.length });
        try self.uploadPack(try self.packName(id), writer.bytes());
        // Each immutable pack has one immutable segment; a purge writes a new
        // segment and the head moves from the old one to it.
        const encoded = try backup.index.encodeSegment(self.allocator, entries.items, self.cryptoKey());
        defer self.allocator.free(encoded);
        const segment = try self.randomName("index");
        try self.create(segment, encoded);
        // The class and the storage time of this upload, kept with the pack.
        try self.packs.append(self.a(), .{ .pack = id, .class = self.config.storage_class, .removable = self.now() + self.hold() });
        try self.index.mergeEntries(entries.items);
        return segment;
    }
    /// A finished pack is committed at once: an interrupted run keeps it.
    fn flushCommit(self: *Service, writer: *backup.pack.Writer, id: [16]u8) !void {
        const segment = (try self.flush(writer, id)) orelse return;
        try self.segments.append(self.a(), segment);
        try self.commit();
    }
    pub fn run(self: *Service, source: Source, store: *storage.engine.StorageEngine) !Report {
        if (self.created_phrase) |old| std.crypto.secureZero(u8, @constCast(old));
        self.created_phrase = null;
        try self.requireUnversioned();
        try self.acquire();
        defer self.release();
        try self.setup();
        if (self.config.encrypt != self.encrypted) return error.EncryptionModeMismatch;
        try self.sweep();
        try self.adoptOrphans();
        const listing = try source.filesFn(source.ctx, self.a());
        const files = listing.files;
        if (files.len > max_files) return error.TooManyFiles;
        for (files) |file| if (!validFile(file)) return error.InvalidFile;
        for (listing.absent) |v| if (!validName(v.path)) return error.InvalidFile;
        const left_out = try self.applyPurges(listing);
        var live: std.ArrayList(File) = .empty;
        var catalog: std.ArrayList(File) = .empty;
        try catalog.appendSlice(self.a(), try self.loadCatalog());
        var newest: std.StringHashMap(usize) = .init(self.allocator);
        defer newest.deinit();
        const last = try newestIntervals(catalog.items, &newest);
        // This run's number: the generation its next commit makes, above
        // every generation, and so every run, committed before it.
        const seen: Run = .{ .time = self.now(), .number = self.head.generation + 1 };
        var writer = try backup.pack.Writer.init(self.allocator, .{ .key = self.cryptoKey(), .target_size = @as(usize, self.config.pack_mb) * 1024 * 1024 });
        defer writer.deinit();
        var id = try backup.index.generatePackId();
        var report: Report = .{ .waiting_files = listing.waiting };
        var pending: std.AutoHashMap(Cid, void) = .init(self.allocator);
        defer pending.deinit();
        for (files) |file| {
            if (listed(&.{file}, left_out)) continue;
            try live.append(self.a(), file);
            // The catalog is the history: each version with when it was seen.
            try observe(self.a(), &catalog, &newest, file, last, seen);
            for (file.blocks) |cid| {
                try self.renew();
                const bid = self.blockId(cid);
                if (self.index.contains(bid) or pending.contains(bid)) continue;
                const block = (try store.get(&cid, self.allocator)) orelse return error.BlockNotFound;
                defer self.allocator.free(block.data);
                if (!writer.wouldFit(block.data.len)) {
                    try self.flushCommit(&writer, id);
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
        if (try self.flush(&writer, id)) |segment| try self.segments.append(self.a(), segment);
        if (self.catalog.len > 0) try self.discard(self.catalog, 0);
        self.catalog = try self.createJson("catalog", catalog.items);
        report.snapshot = try self.createJson("snapshots", Snapshot{ .time = self.now(), .files = live.items });
        try self.snapshots.append(self.a(), .{ .name = report.snapshot, .object = report.snapshot });
        try self.pruneSnapshots();
        // The finished round: when it ran and what it could not take yet.
        self.head.newest = self.now();
        self.head.waiting = listing.waiting;
        try self.commit();
        report.recovery_phrase = self.created_phrase;
        report.reused_key = self.created_phrase != null and self.seed_key != null;
        return report;
    }
    /// Where the committed index says the block is.
    pub fn locate(self: *Service, cid: Cid) !Location {
        return self.index.get(self.blockId(cid)) orelse error.BlockNotFound;
    }
    pub fn readBlock(self: *Service, cid: Cid) ![]u8 {
        return self.readAt(cid, try self.locate(cid));
    }
    /// The block's bytes from a known location, checked against its content id.
    pub fn readAt(self: *Service, cid: Cid, location: Location) ![]u8 {
        if (location.length == 0) return error.InvalidRangeResponse;
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
        const names = if (name_) |n| &[_][]const u8{n} else try self.snapshotNames();
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
        const names = if (name_) |n| &[_][]const u8{n} else try self.snapshotNames();
        if (download) {
            var ready: Packs = .init(self.allocator);
            defer ready.deinit();
            var thaw: Restore = .{};
            for (names) |n| for ((try self.snapshot(n)).files) |file| {
                _ = try self.fileReady(file, &ready, tier, &thaw);
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
    /// for; the answer says whether its bytes can be read now. The class is
    /// the one the bucket reports, never today's configuration. `refused`:
    /// a GET was just answered InvalidObjectState, so a class not known here
    /// counts as archived.
    fn thawPack(self: *Service, id: [16]u8, tier: Tier, refused: bool) !struct { readable: bool, size: u64 } {
        const ts = self.timestamp();
        const key = try self.name(try self.packName(id));
        var response = self.client.headObject(key, &ts) catch |err| switch (err) {
            error.NotFound => return error.PackMissing,
            else => return err,
        };
        defer response.deinit();
        const state = s3.objectState(&response);
        const size = state.size orelse 0;
        const archived = if (std.meta.stringToEnum(StorageClass, state.storage_class)) |class| class.cold() else refused;
        if (!archived or state.restore == .ready) return .{ .readable = true, .size = size };
        if (state.restore == .none) try self.client.restoreObject(key, .{ .days = thaw_days, .tier = tier }, &ts);
        return .{ .readable = false, .size = size };
    }
    /// True when every pack holding the file's blocks is readable. Asks for
    /// the thaw of each pack that is not, once per pack (`ready` remembers).
    pub fn fileReady(self: *Service, file: File, ready: *Packs, tier: Tier, progress: *Restore) !bool {
        var all = true;
        for (file.blocks) |cid| {
            const pack = (try self.locate(cid)).pack_id;
            if (!(try self.packReady(pack, self.recordedClass(pack), ready, tier, progress))) all = false;
        }
        return all;
    }
    /// True when the pack can be read now, asked once per pack (`ready`
    /// remembers). `class` is the one recorded at its upload: a warm one
    /// needs no question; a cold one, or none (null), is asked with a HEAD
    /// and its thaw requested when the bucket holds it archived.
    pub fn packReady(self: *Service, id: [16]u8, class: ?StorageClass, ready: *Packs, tier: Tier, progress: *Restore) !bool {
        const slot = try ready.getOrPut(id);
        if (slot.found_existing) return slot.value_ptr.*;
        slot.value_ptr.* = false; // stays "not ready" if the HEAD fails
        var readable = true;
        if (if (class) |c| c.cold() else true) {
            const pack = try self.thawPack(id, tier, false);
            readable = pack.readable;
            if (!readable) {
                progress.thawing_packs += 1;
                progress.thawing_bytes += pack.size;
            }
        }
        ready.getPtr(id).?.* = readable;
        return readable;
    }
    /// A GET of this pack was answered InvalidObjectState although nothing
    /// said it was archived (a lifecycle rule moved it): asks the bucket and
    /// requests the thaw. False when it is thawing now; true when the bucket
    /// calls it readable all the same.
    pub fn packRefused(self: *Service, id: [16]u8, ready: *Packs, tier: Tier, progress: *Restore) !bool {
        const counted = if (ready.get(id)) |was| !was else false;
        const pack = try self.thawPack(id, tier, true);
        try ready.put(id, pack.readable);
        if (!pack.readable and !counted) {
            progress.thawing_packs += 1;
            progress.thawing_bytes += pack.size;
        }
        return pack.readable;
    }
    /// Every version of every file the backup still holds, also the ones no
    /// kept snapshot lists any more (retention never removes them, only a
    /// purge does). One entry per stretch of runs a version was seen in: a
    /// version that came back after another has two. `path` limits it to
    /// one file or subtree.
    pub fn history(self: *Service, path: ?[]const u8) ![]const File {
        if (self.key == null) return error.Locked;
        var versions: std.ArrayList(File) = .empty;
        for (try self.loadCatalog()) |file| {
            if (file.directory or !validFile(file)) continue;
            if (path) |p| if (!under(file.path, p)) continue;
            try versions.append(self.a(), file);
        }
        return versions.toOwnedSlice(self.a());
    }
    /// Sends the bytes of one file, in order, to `sink`. Every block is
    /// checked against its content id; the total must match the file's size.
    /// With a `locator` the blocks are read where it says and the index is
    /// never asked: a restore job reads its own plan.
    pub fn streamFile(self: *Service, file: File, locator: ?Locator, sink: Sink) !void {
        var stack: std.ArrayList(Cid) = .empty;
        defer stack.deinit(self.allocator);
        try stack.append(self.allocator, file.cid);
        var offset: u64 = 0;
        var visited: usize = 0;
        while (stack.pop()) |cid| {
            visited += 1;
            if (visited > storage.dag.walk.blockBudget(file.size)) return error.DagTooLarge;
            const location = if (locator) |l| l.findFn(l.ctx, cid) orelse return error.BlockNotFound else try self.locate(cid);
            const bytes = try self.readAt(cid, location);
            defer self.allocator.free(bytes);
            switch (try storage.dag.codec.decode(bytes)) {
                .leaf => |data| {
                    if (data.len > file.size - offset) return error.FileTooLarge;
                    try sink.writeFn(sink.ctx, offset, data);
                    offset += data.len;
                },
                .parent => |links| try storage.dag.walk.pushChildren(self.allocator, &stack, links),
                .dir => return error.IsDirectory,
            }
        }
        if (offset != file.size) return error.SizeMismatch;
    }
    /// Offsite portion only: durable encrypted intent, applied by the next
    /// run. What it covers is fixed here, by content: every version under the
    /// path the history holds and every one the folder lists now, also those
    /// still waiting for their blocks. Content that comes later is not in it.
    pub fn forget(self: *Service, path: []const u8, source: Source) !void {
        if (self.key == null) return error.Locked;
        if (!validName(path)) return error.InvalidPath;
        try self.acquire();
        defer self.release();
        try self.loadHead();
        var versions: std.ArrayList(Version) = .empty;
        for (try self.loadCatalog()) |f| if (!f.directory and under(f.path, path)) try addVersion(self.a(), &versions, f.path, f.cid);
        const listing = try source.filesFn(source.ctx, self.a());
        if (listing.files.len > max_files or listing.absent.len > max_files) return error.TooManyFiles;
        for (listing.files) |f| if (!f.directory and under(f.path, path)) try addVersion(self.a(), &versions, f.path, f.cid);
        for (listing.absent) |v| if (under(v.path, path)) try addVersion(self.a(), &versions, v.path, v.cid);
        if (versions.items.len > max_objects) return error.TooManyFiles;
        try self.purges.append(self.a(), try self.createPurge(.{ .path = path, .time = self.now(), .versions = versions.items }));
        try self.commit();
    }
    /// Purges stay encrypted even in the explicitly clear backup mode.
    fn createPurge(self: *Service, purge: Purge) ![]const u8 {
        const mode = self.encrypted;
        self.encrypted = true;
        defer self.encrypted = mode;
        return self.createJson("purges", purge);
    }
    fn getPurge(self: *Service, relative: []const u8) !Purge {
        const mode = self.encrypted;
        self.encrypted = true;
        defer self.encrypted = mode;
        const purge = try self.getJson(Purge, relative);
        if (!validName(purge.path) or purge.versions.len > max_objects) return error.InvalidPurge;
        for (purge.versions) |v| if (!validName(v.path)) return error.InvalidPurge;
        return purge;
    }
    /// `files` without the purged versions, and without the directories under
    /// a purged path (a directory has no content to tell it by).
    fn filtered(self: *Service, files: []const File, paths: []const []const u8, versions: []const Version) ![]const File {
        var result: std.ArrayList(File) = .empty;
        for (files) |f| {
            if (if (f.directory) purged(f.path, paths) else listed(&.{f}, versions)) continue;
            try result.append(self.a(), f);
        }
        return result.toOwnedSlice(self.a());
    }
    /// Applies the purges asked for since the last run, in one commit: their
    /// versions leave every snapshot, the catalog and the index, and their
    /// pack bytes follow. A purge covers the versions `forget` recorded and
    /// nothing else: it never names the path for good, and no file time
    /// decides what is in it. Returns the versions this run leaves out: a
    /// purge is kept while the source still lists one of its versions (also
    /// one waiting for blocks, so it is never uploaded when they come). Once
    /// the source lists none it is done and dropped.
    fn applyPurges(self: *Service, listing: Listing) ![]const Version {
        var left_out: std.ArrayList(Version) = .empty;
        var paths: std.ArrayList([]const u8) = .empty;
        var fresh: std.ArrayList(Version) = .empty;
        var kept: std.ArrayList([]const u8) = .empty;
        for (self.purges.items) |relative| {
            var purge = try self.getPurge(relative);
            const first = !purge.applied;
            if (first) {
                try paths.append(self.a(), purge.path);
                try fresh.appendSlice(self.a(), purge.versions);
            }
            if (!listed(listing.files, purge.versions) and !named(listing.absent, purge.versions)) {
                try self.discard(relative, 0);
                continue;
            }
            try left_out.appendSlice(self.a(), purge.versions);
            if (!first) {
                try kept.append(self.a(), relative);
                continue;
            }
            purge.applied = true;
            try kept.append(self.a(), try self.createPurge(purge));
            try self.discard(relative, 0);
        }
        self.purges = kept;
        // No new purge: only a pack that waited out its storage time is left to copy.
        if (paths.items.len == 0 and !self.packsAgedOut()) return left_out.items;
        for (self.snapshots.items) |*ref| {
            if (paths.items.len == 0) break;
            const snap = try self.snapshot(ref.name);
            const files = try self.filtered(snap.files, paths.items, fresh.items);
            if (files.len == snap.files.len) continue;
            try self.discard(ref.object, 0);
            ref.object = try self.createJson("snapshots", Snapshot{ .time = snap.time, .files = files });
        }
        const history_ = try self.loadCatalog();
        const catalog = try self.filtered(history_, paths.items, fresh.items);
        if (catalog.len != history_.len) {
            if (self.catalog.len > 0) try self.discard(self.catalog, 0);
            self.catalog = try self.createJson("catalog", catalog);
        }
        var keep: std.AutoHashMap(Cid, void) = .init(self.allocator);
        defer keep.deinit();
        for (catalog) |f| for (f.blocks) |cid| {
            try keep.put(self.blockId(cid), {});
        };
        try self.repack(&keep);
        // History, index and purge progress move together or not at all.
        try self.commit();
        return left_out.items;
    }
    /// The purged blocks leave the index at once. A pack past its minimum
    /// storage time (the one recorded at its upload, not today's class) is
    /// copied without them, thawed first when archived (asked here, ready on
    /// a later run); a younger one waits. The replaced packs and segments
    /// become garbage: deleted by a later run, never before that time.
    fn repack(self: *Service, keep: *std.AutoHashMap(Cid, void)) !void {
        var live: std.ArrayList([]const u8) = .empty;
        for (self.segments.items) |segment| {
            const entries = try backup.index.decodeSegment(self.allocator, try self.get(segment), self.cryptoKey());
            defer self.allocator.free(entries);
            if (entries.len == 0) {
                try self.discard(segment, 0);
                continue;
            }
            var remaining: std.ArrayList(Entry) = .empty;
            defer remaining.deinit(self.allocator);
            for (entries) |entry| {
                if (!std.mem.eql(u8, &entry.pack_id, &entries[0].pack_id)) return error.InvalidIndex;
                if (keep.contains(entry.block_id)) try remaining.append(self.allocator, entry);
            }
            const pack = entries[0].pack_id;
            const at = self.packIndex(pack) orelse return error.InvalidIndex;
            const record = self.packs.items[at];
            const removed = remaining.items.len != entries.len;
            if (!removed and !record.purged) {
                try live.append(self.a(), segment);
                continue;
            }
            if (remaining.items.len == 0) {
                try self.discard(segment, 0);
                try self.discard(try self.packName(pack), record.removable);
                _ = self.packs.swapRemove(at);
                continue;
            }
            if (self.now() < record.removable or !(try self.thawPack(pack, .Bulk, false)).readable) {
                self.packs.items[at].purged = true;
                if (!removed) {
                    try live.append(self.a(), segment);
                    continue;
                }
                const encoded = try backup.index.encodeSegment(self.allocator, remaining.items, self.cryptoKey());
                defer self.allocator.free(encoded);
                const shorter = try self.randomName("index");
                try self.create(shorter, encoded);
                try live.append(self.a(), shorter);
                try self.discard(segment, 0);
                continue;
            }
            var writer = try backup.pack.Writer.init(self.allocator, .{ .key = self.cryptoKey(), .target_size = 512 * 1024 * 1024 });
            defer writer.deinit();
            for (remaining.items) |entry| {
                const ts = self.timestamp();
                var response = try self.client.getObject(try self.name(try self.packName(entry.pack_id)), .{ .start = entry.offset, .end = entry.offset + entry.length - 1 }, &ts);
                defer response.deinit();
                var decoded = try backup.pack.decodeRangeChunk(self.allocator, response.body, self.cryptoKey());
                defer decoded.deinit(self.allocator);
                if (!std.mem.eql(u8, &decoded.block_id, &entry.block_id)) return error.CidMismatch;
                _ = try writer.append(entry.block_id, decoded.data);
            }
            const copy = (try self.flush(&writer, try backup.index.generatePackId())) orelse return error.InvalidIndex;
            try live.append(self.a(), copy);
            try self.discard(segment, 0);
            try self.discard(try self.packName(pack), record.removable);
            _ = self.packs.swapRemove(self.packIndex(pack).?);
        }
        self.segments = live;
        try self.loadIndex();
    }
    /// Retention only stops naming a snapshot; its object goes after the grace.
    fn pruneSnapshots(self: *Service) !void {
        const refs = self.snapshots.items;
        const times = try self.a().alloc(u64, refs.len);
        for (refs, times) |ref, *t| t.* = (try self.snapshot(ref.name)).time;
        const retain = try retention(self.a(), times, self.now(), self.config.retain_daily, self.config.retain_monthly);
        var kept: std.ArrayList(SnapshotRef) = .empty;
        for (refs, retain) |ref, yes| {
            if (yes) try kept.append(self.a(), ref) else try self.discard(ref.object, 0);
        }
        self.snapshots = kept;
    }
};
/// A bounded name. Whether it is a valid path is the source's and the
/// restorer's question (fs), asked before anything is read or written.
fn validName(path: []const u8) bool {
    return path.len > 0 and path.len <= max_name and std.mem.indexOfScalar(u8, path, 0) == null;
}
fn validFile(file: File) bool {
    if (!validName(file.path) or file.blocks.len > 1 << 20) return false;
    if (file.directory) return file.blocks.len == 0 and file.size == 0;
    for (file.blocks) |cid| if (std.mem.eql(u8, &cid, &file.cid)) return true;
    return false;
}
/// One upload run: its time and its number.
const Run = struct { time: u64 = 0, number: u64 = 0 };
/// True when interval `x` of a path is later than its interval `y`: by the
/// last run that saw it, the run's number deciding within one second.
fn later(x: File, y: File) bool {
    const kx = [4]u64{ x.last_seen, x.last_run, x.first_seen, x.first_run };
    const ky = [4]u64{ y.last_seen, y.last_run, y.first_seen, y.first_run };
    return std.mem.order(u64, &kx, &ky) == .gt;
}
/// Fills `newest` with the latest interval of each path in the catalog
/// (of two that tie, the one written later). Returns the last run that saw
/// any file (a run that listed none leaves no mark, so a file missing only
/// from such runs keeps its interval).
fn newestIntervals(catalog: []const File, newest: *std.StringHashMap(usize)) !Run {
    var last: Run = .{};
    for (catalog, 0..) |file, i| {
        last.time = @max(last.time, file.last_seen);
        last.number = @max(last.number, file.last_run);
        const slot = try newest.getOrPut(file.path);
        if (!slot.found_existing or !later(catalog[slot.value_ptr.*], file)) slot.value_ptr.* = i;
    }
    return last;
}
/// This run (`seen`) found `file`. The path's latest interval grows when it
/// is this version and the last run (`last`) saw it too; after a gap
/// (another version in between, or a run without the file) the version gets
/// a new interval, so the history says what was at the path at any time.
/// Two runs in one second are told apart by their numbers.
fn observe(a: Allocator, catalog: *std.ArrayList(File), newest: *std.StringHashMap(usize), file: File, last: Run, seen: Run) !void {
    const slot = try newest.getOrPut(file.path);
    if (slot.found_existing) {
        const known = &catalog.items[slot.value_ptr.*];
        if (known.last_seen >= last.time and known.last_run >= last.number and known.directory == file.directory and std.mem.eql(u8, &known.cid, &file.cid)) {
            known.last_seen = @max(known.last_seen, seen.time);
            known.last_run = seen.number;
            return;
        }
    }
    var version = file;
    version.first_seen = seen.time;
    version.last_seen = seen.time;
    version.first_run = seen.number;
    version.last_run = seen.number;
    slot.value_ptr.* = catalog.items.len;
    try catalog.append(a, version);
}
/// True for `prefix` itself and for every name below it.
pub fn under(path: []const u8, prefix: []const u8) bool {
    return std.mem.eql(u8, path, prefix) or (std.mem.startsWith(u8, path, prefix) and path.len > prefix.len and path[prefix.len] == '/');
}
fn purged(path: []const u8, paths: []const []const u8) bool {
    for (paths) |p| if (under(path, p)) return true;
    return false;
}
fn addVersion(a: Allocator, versions: *std.ArrayList(Version), path: []const u8, cid: Cid) !void {
    for (versions.items) |v| if (std.mem.eql(u8, v.path, path) and std.mem.eql(u8, &v.cid, &cid)) return;
    try versions.append(a, .{ .path = path, .cid = cid });
}
/// True when one of `some` is one of these versions.
fn named(some: []const Version, versions: []const Version) bool {
    for (some) |s| for (versions) |v| if (std.mem.eql(u8, v.path, s.path) and std.mem.eql(u8, &v.cid, &s.cid)) return true;
    return false;
}
/// True when one of `files` is one of these versions (same path and content).
fn listed(files: []const File, versions: []const Version) bool {
    for (files) |f| {
        if (f.directory) continue;
        for (versions) |v| if (std.mem.eql(u8, v.path, f.path) and std.mem.eql(u8, &v.cid, &f.cid)) return true;
    }
    return false;
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
