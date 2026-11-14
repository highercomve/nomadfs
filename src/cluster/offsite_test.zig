const std = @import("std");
const core = @import("offsite.zig");
const s3 = @import("../net/s3/mod.zig");
const backup = @import("../backup/mod.zig");
const storage = @import("../storage/mod.zig");
const fs_restore = @import("../fs/restore.zig");
const a = std.testing.allocator;
const io = std.testing.io;
const Cid = [32]u8;
const day = 86400;
/// The warm restore of a snapshot: every pack is readable, the count is final.
fn restore(service: *core.Service, name: []const u8, path: ?[]const u8, destination: std.Io.Dir) !usize {
    return (try restoreRequest(service, name, path, destination, .Bulk)).files;
}
fn restoreRequest(service: *core.Service, name: []const u8, path: ?[]const u8, destination: std.Io.Dir, tier: core.Tier) !core.Restore {
    return fs_restore.restore(a, io, service, .{ .from = .{ .snapshot = name }, .path = path, .tier = tier }, destination);
}
const Thaw = enum { none, ongoing, ready };
const Object = struct { bytes: []u8, version: u64, modified: u64 = 0, class: ?[]const u8 = null, thaw: Thaw = .none };
fn isCold(class: ?[]const u8) bool {
    const text = class orelse return false;
    return std.mem.eql(u8, text, "GLACIER") or std.mem.eql(u8, text, "DEEP_ARCHIVE");
}
/// A bucket in memory, behind the S3 client's transport. Not for two
/// threads at once.
pub const Fake = struct {
    objects: std.StringHashMapUnmanaged(Object) = .empty,
    version: u64 = 0,
    pack_puts: usize = 0,
    sleeps: u64 = 0,
    time: u64 = 1_700_000_000,
    multipart: std.ArrayList(u8) = .empty,
    multipart_calls: usize = 0,
    fail_segment_once: bool = false,
    fail_segment_at: usize = 0,
    segments: usize = 0,
    multipart_class: ?[]const u8 = null,
    restore_requests: usize = 0,
    last_tier: []const u8 = "",
    /// Runs once, before the next PUT of a key ending in `before_key`: what
    /// another writer does while this request is stalled on the wire.
    before_put: ?*const fn (*Fake) anyerror!void = null,
    before_key: []const u8 = "",
    /// GetBucketVersioning: the Status the bucket reports (null: never set,
    /// like R2), or a store that does not know the request at all (501).
    versioning: ?[]const u8 = null,
    versioning_unsupported: bool = false,
    /// The next PUT of a key ending like this is refused (403), once.
    fail_put_once: []const u8 = "",
    /// The next PUT of a key ending like this is stored, then its answer is
    /// lost on the wire, once: the client sends it again.
    lose_put_once: []const u8 = "",
    /// The last multipart completion carried If-None-Match.
    complete_conditional: bool = false,
    /// Every running thaw ends: the archived packs become readable.
    fn finishThaws(self: *Fake) void {
        var it = self.objects.valueIterator();
        while (it.next()) |object| {
            if (object.thaw == .ongoing) object.thaw = .ready;
        }
    }
    fn iso(time: u64, out: *[24]u8) []const u8 {
        const epoch: std.time.epoch.EpochSeconds = .{ .secs = time };
        const yd = epoch.getEpochDay().calculateYearDay();
        const md = yd.calculateMonthDay();
        const ds = epoch.getDaySeconds();
        return std.fmt.bufPrint(out, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}.000Z", .{ yd.year, md.month.numeric(), @as(u8, md.day_index) + 1, ds.getHoursIntoDay(), ds.getMinutesIntoHour(), ds.getSecondsIntoMinute() }) catch unreachable;
    }
    pub fn deinit(self: *Fake) void {
        var it = self.objects.iterator();
        while (it.next()) |entry| {
            a.free(entry.key_ptr.*);
            a.free(entry.value_ptr.bytes);
        }
        self.objects.deinit(a);
        self.multipart.deinit(a);
    }
    fn clock(ctx: ?*anyopaque) u64 {
        const self: *Fake = @ptrCast(@alignCast(ctx.?));
        return self.time;
    }
    pub fn transport(self: *Fake) s3.Transport {
        return .{ .context = self, .send = send, .sleep = sleep };
    }
    fn sleep(ctx: *anyopaque, ms: u64) s3.transport.Error!void {
        const self: *Fake = @ptrCast(@alignCast(ctx));
        self.sleeps += ms;
        self.time += ms / 1000;
    }
    fn set(self: *Fake, key: []const u8, bytes: []const u8) !void {
        const owned_bytes = try a.dupe(u8, bytes);
        errdefer a.free(owned_bytes);
        const slot = try self.objects.getOrPut(a, key);
        if (slot.found_existing) a.free(slot.value_ptr.bytes) else slot.key_ptr.* = try a.dupe(u8, key);
        self.version += 1;
        slot.value_ptr.* = .{ .bytes = owned_bytes, .version = self.version, .modified = self.time };
    }
    fn header(request: s3.transport.Request, key: []const u8) ?[]const u8 {
        for (request.headers) |h| if (std.ascii.eqlIgnoreCase(h.name, key)) return h.value;
        return null;
    }
    fn decode(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(allocator);
        var i: usize = 0;
        while (i < text.len) : (i += 1) {
            if (text[i] == '%') {
                if (i + 2 >= text.len) return error.InvalidRequest;
                try out.append(allocator, std.fmt.parseInt(u8, text[i + 1 .. i + 3], 16) catch return error.InvalidRequest);
                i += 2;
            } else try out.append(allocator, text[i]);
        }
        return out.toOwnedSlice(allocator);
    }
    fn send(ctx: *anyopaque, allocator: std.mem.Allocator, request: s3.transport.Request) s3.transport.Error!s3.Response {
        return sendImpl(ctx, allocator, request) catch |err| switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.NetworkFailure => error.NetworkFailure,
            else => error.InvalidRequest,
        };
    }
    fn sendImpl(ctx: *anyopaque, allocator: std.mem.Allocator, request: s3.transport.Request) !s3.Response {
        const self: *Fake = @ptrCast(@alignCast(ctx));
        std.debug.assert(@intFromPtr(ctx) != 0);
        std.debug.assert(std.mem.startsWith(u8, request.url, "https://endpoint/bucket"));
        var arena: std.heap.ArenaAllocator = .init(allocator);
        defer arena.deinit();
        const scratch = arena.allocator();
        const url = request.url["https://endpoint/bucket".len..];
        const query_start = std.mem.indexOfScalar(u8, url, '?') orelse url.len;
        const raw_key = std.mem.trimStart(u8, url[0..query_start], "/");
        const key = try decode(scratch, raw_key);
        const query = if (query_start < url.len) url[query_start + 1 ..] else "";
        const body = switch (request.body) {
            .bytes => |b| b,
            else => return error.InvalidRequest,
        };
        if (request.method == .PUT and std.mem.endsWith(u8, key, self.before_key)) if (self.before_put) |hook| {
            self.before_put = null;
            try hook(self);
        };
        var etag_buf: [32]u8 = undefined;
        const existing = self.objects.get(key);
        const old_etag = try std.fmt.bufPrint(&etag_buf, "\"{d}\"", .{if (existing) |o| o.version else 0});
        if (request.method == .GET and key.len == 0 and std.mem.startsWith(u8, query, "versioning=")) {
            if (self.versioning_unsupported) return s3.Response.init(allocator, 501, &.{}, "<Error><Code>NotImplemented</Code></Error>");
            const status = self.versioning orelse return s3.Response.init(allocator, 200, &.{}, "<VersioningConfiguration xmlns=\"http://s3.amazonaws.com/doc/2006-03-01/\"/>");
            return s3.Response.init(allocator, 200, &.{}, try std.fmt.allocPrint(scratch, "<VersioningConfiguration><Status>{s}</Status></VersioningConfiguration>", .{status}));
        }
        if (request.method == .GET and key.len == 0) {
            var params = std.mem.splitScalar(u8, query, '&');
            var prefix: []const u8 = "";
            while (params.next()) |param| if (std.mem.startsWith(u8, param, "prefix=")) {
                prefix = try decode(scratch, param[7..]);
            };
            var xml: std.Io.Writer.Allocating = .init(scratch);
            try xml.writer.writeAll("<ListBucketResult><IsTruncated>false</IsTruncated>");
            var it = self.objects.iterator();
            while (it.next()) |e| {
                if (!std.mem.startsWith(u8, e.key_ptr.*, prefix)) continue;
                var stamp: [24]u8 = undefined;
                try xml.writer.print("<Contents><Key>{s}</Key><LastModified>{s}</LastModified><Size>{d}</Size><ETag>&quot;{d}&quot;</ETag></Contents>", .{ e.key_ptr.*, iso(e.value_ptr.modified, &stamp), e.value_ptr.bytes.len, e.value_ptr.version });
            }
            try xml.writer.writeAll("</ListBucketResult>");
            return s3.Response.init(allocator, 200, &.{}, xml.written());
        }
        if (request.method == .POST) {
            if (std.mem.startsWith(u8, query, "restore=")) {
                const object = self.objects.getPtr(key) orelse return s3.Response.init(allocator, 404, &.{}, "");
                self.restore_requests += 1;
                self.last_tier = if (std.mem.indexOf(u8, body, "<Tier>Standard</Tier>") != null) "Standard" else if (std.mem.indexOf(u8, body, "<Tier>Bulk</Tier>") != null) "Bulk" else "other";
                std.debug.assert(std.mem.indexOf(u8, body, "<Days>7</Days>") != null);
                if (object.thaw == .ongoing) return s3.Response.init(allocator, 409, &.{}, "<Error><Code>RestoreAlreadyInProgress</Code></Error>");
                if (object.thaw == .none) object.thaw = .ongoing;
                return s3.Response.init(allocator, 202, &.{}, "");
            }
            if (std.mem.startsWith(u8, query, "uploads=")) {
                self.multipart.clearRetainingCapacity();
                self.multipart_calls += 1;
                self.multipart_class = if (header(request, "x-amz-storage-class")) |class| @tagName(std.meta.stringToEnum(Classes, class).?) else null;
                return s3.Response.init(allocator, 200, &.{}, "<InitiateMultipartUploadResult><UploadId>test</UploadId></InitiateMultipartUploadResult>");
            }
            self.complete_conditional = header(request, "if-none-match") != null;
            if (self.complete_conditional and existing != null) return s3.Response.init(allocator, 412, &.{}, "");
            try self.set(key, self.multipart.items);
            self.objects.getPtr(key).?.class = self.multipart_class;
            self.pack_puts += 1;
            return s3.Response.init(allocator, 200, &.{}, "<CompleteMultipartUploadResult/>");
        }
        if (request.method == .PUT) {
            if (header(request, "if-none-match") != null and existing != null) return s3.Response.init(allocator, 412, &.{}, "");
            if (header(request, "if-match")) |match| if (existing == null or !std.mem.eql(u8, match, old_etag)) return s3.Response.init(allocator, 412, &.{}, "");
            if (std.mem.startsWith(u8, query, "partNumber=")) {
                try self.multipart.appendSlice(a, body);
            } else if (self.fail_put_once.len > 0 and std.mem.endsWith(u8, key, self.fail_put_once)) {
                self.fail_put_once = "";
                return s3.Response.init(allocator, 403, &.{}, "");
            } else if (self.lose_put_once.len > 0 and std.mem.endsWith(u8, key, self.lose_put_once)) {
                self.lose_put_once = "";
                try self.set(key, body);
                return error.NetworkFailure;
            } else {
                if (std.mem.indexOf(u8, key, "index/") != null) self.segments += 1;
                if ((self.fail_segment_once or self.segments == self.fail_segment_at) and std.mem.indexOf(u8, key, "index/") != null) {
                    self.fail_segment_once = false;
                    return s3.Response.init(allocator, 403, &.{}, "");
                }
                try self.set(key, body);
                if (header(request, "x-amz-storage-class")) |class| self.objects.getPtr(key).?.class = @tagName(std.meta.stringToEnum(Classes, class).?);
                if (std.mem.indexOf(u8, key, "packs/") != null) self.pack_puts += 1;
            }
            const etag = try std.fmt.bufPrint(&etag_buf, "\"{d}\"", .{self.version});
            return s3.Response.init(allocator, 200, &.{.{ .name = "etag", .value = etag }}, "");
        }
        if (request.method == .DELETE) {
            if (self.objects.fetchRemove(key)) |e| {
                a.free(e.key);
                a.free(e.value.bytes);
            }
            return s3.Response.init(allocator, 204, &.{}, "");
        }
        const obj = existing orelse return s3.Response.init(allocator, 404, &.{}, "");
        if (request.method == .HEAD) {
            var length: [20]u8 = undefined;
            var headers: [3]std.http.Header = undefined;
            var count: usize = 1;
            headers[0] = .{ .name = "content-length", .value = try std.fmt.bufPrint(&length, "{d}", .{obj.bytes.len}) };
            if (obj.class) |class| {
                headers[count] = .{ .name = "x-amz-storage-class", .value = class };
                count += 1;
            }
            if (obj.thaw != .none) {
                headers[count] = .{ .name = "x-amz-restore", .value = if (obj.thaw == .ongoing) "ongoing-request=\"true\"" else "ongoing-request=\"false\", expiry-date=\"Fri, 21 Dec 2012 00:00:00 GMT\"" };
                count += 1;
            }
            return s3.Response.init(allocator, 200, headers[0..count], "");
        }
        // An archived object cannot be read before its thaw ends.
        if (isCold(obj.class) and obj.thaw != .ready) return s3.Response.init(allocator, 403, &.{}, "<Error><Code>InvalidObjectState</Code></Error>");
        if (header(request, "range")) |range| {
            var parts = std.mem.splitScalar(u8, range[6..], '-');
            const start = std.fmt.parseInt(usize, parts.next().?, 10) catch return error.InvalidRequest;
            const end = std.fmt.parseInt(usize, parts.next().?, 10) catch return error.InvalidRequest;
            if (start > end or end >= obj.bytes.len) return s3.Response.init(allocator, 416, &.{}, "");
            return s3.Response.init(allocator, 206, &.{.{ .name = "etag", .value = old_etag }}, obj.bytes[start .. end + 1]);
        }
        return s3.Response.init(allocator, 200, &.{.{ .name = "etag", .value = old_etag }}, obj.bytes);
    }
};
/// Static names for the classes a request may carry (the request text is freed).
const Classes = enum { STANDARD_IA, GLACIER_IR, GLACIER, DEEP_ARCHIVE };
const Fixture = struct {
    fake: Fake = .{},
    client: s3.Client = undefined,
    service: core.Service = undefined,
    tmp: std.testing.TmpDir,
    arena: std.heap.ArenaAllocator,
    store: storage.engine.StorageEngine = undefined,
    files: std.ArrayList(core.File) = .empty,
    /// Versions the folder lists whose blocks are not in the store yet.
    absent: []const core.Version = &.{},
    fn create() !*Fixture {
        const f = try a.create(Fixture);
        errdefer a.destroy(f);
        f.* = .{ .tmp = std.testing.tmpDir(.{}), .arena = .init(a) };
        errdefer {
            f.tmp.cleanup();
            f.arena.deinit();
        }
        var path: [std.fs.max_path_bytes]u8 = undefined;
        const root = path[0..try f.tmp.dir.realPath(io, &path)];
        f.store = try storage.engine.StorageEngine.init(a, root);
        errdefer f.store.deinit();
        f.client = try s3.Client.init(a, .{ .endpoint = "https://endpoint", .bucket = "bucket" }, .{ .access_key_id = "test", .secret_access_key = "secret" }, f.fake.transport());
        const pair = try std.crypto.dh.X25519.KeyPair.generateDeterministic([_]u8{7} ** 32);
        f.service = try core.Service.init(a, &f.client, .{ .prefix = "swarm", .pack_mb = 1 }, .{ .id = [_]u8{9} ** 32, .public = pair.public_key, .secret = pair.secret_key });
        f.service.clock_ctx = &f.fake;
        f.service.clockFn = Fake.clock;
        return f;
    }
    /// A deep-archive target with the cold defaults: monthly snapshots only.
    fn createCold() !*Fixture {
        const f = try create();
        f.service.config.storage_class = .DEEP_ARCHIVE;
        f.service.config.retain_daily = 0;
        f.service.config.retain_monthly = 0;
        return f;
    }
    fn packKey(f: *Fixture, cid: Cid) ![]const u8 {
        return f.packKeyOf(&f.service, cid);
    }
    fn packKeyOf(f: *Fixture, service: *core.Service, cid: Cid) ![]const u8 {
        const location = service.index.get(backup.index.keyedBlockId(service.key.?, cid)).?;
        return std.fmt.allocPrint(f.arena.allocator(), "swarm/packs/{s}", .{backup.index.formatPackId(location.pack_id)});
    }
    fn destroy(f: *Fixture) void {
        f.service.deinit();
        f.store.deinit();
        f.fake.deinit();
        f.arena.deinit();
        f.tmp.cleanup();
        a.destroy(f);
    }
    fn filesFn(ctx: *anyopaque, _: std.mem.Allocator) !core.Listing {
        const f: *Fixture = @ptrCast(@alignCast(ctx));
        return .{ .files = f.files.items, .waiting = f.absent.len, .absent = f.absent };
    }
    fn forget(f: *Fixture, path: []const u8) !void {
        return f.service.forget(path, f.source());
    }
    /// Objects under the backup's prefix whose name starts like this.
    fn countUnder(f: *Fixture, prefix: []const u8) usize {
        var n: usize = 0;
        var it = f.fake.objects.keyIterator();
        while (it.next()) |key| n += @intFromBool(std.mem.startsWith(u8, key.*, prefix));
        return n;
    }
    /// A device that has no wrap in the bucket: only the words open it.
    fn stranger(f: *Fixture) !core.Service {
        const pair = try std.crypto.dh.X25519.KeyPair.generateDeterministic([_]u8{8} ** 32);
        var service = try core.Service.init(a, &f.client, f.service.config, .{ .id = [_]u8{8} ** 32, .public = pair.public_key, .secret = pair.secret_key });
        service.clock_ctx = &f.fake;
        service.clockFn = Fake.clock;
        return service;
    }
    fn source(f: *Fixture) core.Source {
        return .{ .ctx = f, .filesFn = filesFn };
    }
    fn add(f: *Fixture, path: []const u8, content: []const u8) !Cid {
        const alloc = f.arena.allocator();
        const encoded = try alloc.alloc(u8, content.len + 1);
        encoded[0] = 0;
        @memcpy(encoded[1..], content);
        const block = storage.block.Block.new(encoded);
        try f.store.put(block);
        const cids = try alloc.dupe(Cid, &.{block.cid});
        try f.files.append(alloc, .{ .path = path, .cid = block.cid, .size = content.len, .blocks = cids });
        return block.cid;
    }
    fn composite(f: *Fixture, path: []const u8, chunks: []const []const u8) !Cid {
        const alloc = f.arena.allocator();
        const links = try alloc.alloc(storage.dag.node.DagLink, chunks.len);
        const cids = try alloc.alloc(Cid, chunks.len + 1);
        var size: u64 = 0;
        for (chunks, links, 0..) |chunk, *link, i| {
            cids[i] = try f.add("unused", chunk);
            _ = f.files.pop();
            link.* = .{ .name = "", .cid = &cids[i], .size = chunk.len };
            size += chunk.len;
        }
        const encoded = try storage.dag.codec.encodeParent(alloc, links);
        const block = storage.block.Block.new(encoded);
        try f.store.put(block);
        cids[chunks.len] = block.cid;
        try f.files.append(alloc, .{ .path = path, .cid = block.cid, .size = size, .blocks = cids });
        return block.cid;
    }
    fn run(f: *Fixture) !core.Report {
        f.fake.time += 1;
        return f.service.run(f.source(), &f.store);
    }
    /// True while the committed head names this snapshot.
    fn names(f: *Fixture, snapshot: []const u8) !bool {
        for ((try f.service.status()).snapshots) |n| if (std.mem.eql(u8, n, snapshot)) return true;
        return false;
    }
    /// Another uploader of the same bucket: a second device, or this one restarted.
    fn other(f: *Fixture) !core.Service {
        var service = try core.Service.init(a, &f.client, f.service.config, f.service.device);
        service.clock_ctx = &f.fake;
        service.clockFn = Fake.clock;
        return service;
    }
    fn packCount(f: *Fixture) usize {
        var count: usize = 0;
        var it = f.fake.objects.keyIterator();
        while (it.next()) |key| count += @intFromBool(std.mem.startsWith(u8, key.*, "swarm/packs/"));
        return count;
    }
};

test "offsite: first run creates layout and wraps; repeated run deduplicates; new file adds only new blocks" {
    const f = try Fixture.create();
    defer f.destroy();
    _ = try f.add("Photos/a.jpg", "photo bytes");
    const first = try f.run();
    try std.testing.expectEqual(@as(usize, 1), first.uploaded_blocks);
    try std.testing.expect(first.recovery_phrase != null);
    try std.testing.expect(f.fake.objects.contains("swarm/nomadfs-backup.json"));
    // The root names one setup: the two wraps and the sealed words.
    try std.testing.expectEqual(@as(usize, 3), f.countUnder("swarm/keys/"));
    const words = try f.service.recoveryKey();
    try std.testing.expectEqualStrings(first.recovery_phrase.?, words);
    const puts = f.fake.pack_puts;
    const second = try f.run();
    try std.testing.expectEqual(@as(usize, 0), second.uploaded_blocks);
    try std.testing.expectEqual(puts, f.fake.pack_puts);
    _ = try f.add("Notes/new.txt", "new notes");
    const third = try f.run();
    try std.testing.expectEqual(@as(usize, 1), third.uploaded_blocks);
}

test "offsite: foreign lease refused; expired lease replaced with CAS; stolen lease fences writes" {
    const f = try Fixture.create();
    defer f.destroy();
    try f.fake.set("swarm/lease", "{\"owner\":[0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0],\"expires\":9999999999}");
    try std.testing.expectError(error.LeaseHeld, f.run());
    try f.fake.set("swarm/lease", "{\"owner\":[0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0],\"expires\":0}");
    try f.service.acquire();
    try f.fake.set("swarm/lease", "stolen");
    f.fake.time += 101;
    f.service.key = [_]u8{7} ** 32;
    f.service.setup_id = "0123456789abcdef0123456789abcdef";
    try std.testing.expectError(error.LeaseLost, f.service.wrapDevice([_]u8{3} ** 32, f.service.device.public));
    // release cannot erase a new owner's lease.
    f.service.release();
    try std.testing.expectEqualStrings("stolen", f.fake.objects.get("swarm/lease").?.bytes);
}

test "offsite: restore folder byte for byte and recovery-only restore" {
    const f = try Fixture.create();
    defer f.destroy();
    _ = try f.add("Photos/a.jpg", "photo bytes");
    _ = try f.add("Notes/b.txt", "notes bytes\n");
    const report = try f.run();
    var target = std.testing.tmpDir(.{});
    defer target.cleanup();
    try std.testing.expectEqual(@as(usize, 2), try restore(&f.service, report.snapshot, null, target.dir));
    const bytes = try target.dir.readFileAlloc(io, "Notes/b.txt", a, .limited(100));
    defer a.free(bytes);
    try std.testing.expectEqualStrings("notes bytes\n", bytes);
    const photo = try target.dir.readFileAlloc(io, "Photos/a.jpg", a, .limited(100));
    defer a.free(photo);
    try std.testing.expectEqualStrings("photo bytes", photo);
    const pair = try std.crypto.dh.X25519.KeyPair.generateDeterministic([_]u8{8} ** 32);
    var other = try core.Service.init(a, &f.client, f.service.config, .{ .id = [_]u8{8} ** 32, .public = pair.public_key, .secret = pair.secret_key });
    defer other.deinit();
    other.clock_ctx = &f.fake;
    other.clockFn = Fake.clock;
    try std.testing.expectError(error.RecoveryPhraseRequired, other.unlock(null));
    try other.unlock(report.recovery_phrase);
    var recovered = std.testing.tmpDir(.{});
    defer recovered.cleanup();
    try std.testing.expectEqual(@as(usize, 1), try restore(&other, report.snapshot, "Photos", recovered.dir));
    try std.testing.expectEqual(@as(usize, 2), try other.verify(null));
}

test "offsite: verify detects corrupted pack" {
    const f = try Fixture.create();
    defer f.destroy();
    const cid = try f.add("a.txt", "hello");
    _ = try f.run();
    const location = f.service.index.get(backup.index.keyedBlockId(f.service.key.?, cid)).?;
    const key = try std.fmt.allocPrint(a, "swarm/packs/{s}", .{backup.index.formatPackId(location.pack_id)});
    defer a.free(key);
    f.fake.objects.getPtr(key).?.bytes[@intCast(location.offset + location.length - 1)] ^= 1;
    try std.testing.expectError(error.AuthenticationFailed, f.service.verify(null));
}

test "offsite: retention keeps daily snapshots and latest per month forever" {
    // Jan 1, Jan 20, Feb 1, Feb 20, March 1 2024 (UTC).
    const times = [_]u64{ 1704067200, 1705708800, 1706745600, 1708387200, 1709251200, 1709251201 };
    const forever = try core.retention(a, &times, 1709251202, 2, 0);
    defer a.free(forever);
    try std.testing.expectEqualSlices(bool, &.{ false, true, false, true, true, true }, forever);
    const recent = try core.retention(a, &times, 1709251202, 2, 1);
    defer a.free(recent);
    try std.testing.expectEqualSlices(bool, &.{ false, false, false, false, true, true }, recent);
}

test "offsite: ordinary deletes and retention keep data; forget rewrites history and repacks sharing blocks" {
    const f = try Fixture.create();
    defer f.destroy();
    const removed_cid = try f.add("private.txt", "private unique bytes");
    const shared_cid = try f.add("shared-a.txt", "shared bytes");
    _ = try f.add("shared-b.txt", "shared bytes");
    const first = try f.run();
    const old_location = f.service.index.get(backup.index.keyedBlockId(f.service.key.?, removed_cid)).?;
    const old_pack = try std.fmt.allocPrint(a, "swarm/packs/{s}", .{backup.index.formatPackId(old_location.pack_id)});
    defer a.free(old_pack);
    f.files.clearRetainingCapacity();
    f.fake.time += 90 * 86400;
    _ = try f.run();
    try std.testing.expect(f.fake.objects.contains(old_pack));
    try f.forget("private.txt");
    try f.forget("shared-a.txt");
    f.service.config.schedule = .monthly;
    _ = try f.run();
    // Out of the index at once; the replaced pack goes after the grace, and
    // the uploader comes back for it without waiting for its schedule.
    try std.testing.expect(f.fake.objects.contains(old_pack));
    try std.testing.expect(!(try f.service.due()));
    f.fake.time += day;
    try std.testing.expect(try f.service.due());
    _ = try f.run();
    try std.testing.expect(!f.fake.objects.contains(old_pack));
    try std.testing.expect(!(try f.service.due()));
    try std.testing.expect(!f.service.index.contains(backup.index.keyedBlockId(f.service.key.?, removed_cid)));
    try std.testing.expect(f.service.index.contains(backup.index.keyedBlockId(f.service.key.?, shared_cid)));
    const snap = try f.service.snapshot(first.snapshot);
    try std.testing.expectEqual(@as(usize, 1), snap.files.len);
    try std.testing.expectEqualStrings("shared-b.txt", snap.files[0].path);
    try std.testing.expectEqual(@as(usize, 1), try f.service.verify(null));
}

test "offsite: committed packs survive a failed index upload and run resumes" {
    const f = try Fixture.create();
    defer f.destroy();
    _ = try f.add("a.txt", "hello");
    f.fake.fail_segment_once = true;
    try std.testing.expectError(error.AccessDenied, f.run());
    const report = try f.run();
    try std.testing.expectEqual(@as(usize, 1), report.uploaded_blocks);
    try std.testing.expectEqual(@as(usize, 1), try f.service.verify(null));
}

test "offsite: multipart upload and rate limiting renew the lease during long uploads" {
    const f = try Fixture.create();
    defer f.destroy();
    f.service.config.pack_mb = 8;
    f.service.config.upload_limit_kbps = 16;
    const bytes = try a.alloc(u8, 6 * 1024 * 1024);
    defer a.free(bytes);
    @memset(bytes, 'p');
    _ = try f.add("large.bin", bytes);
    const report = try f.run();
    try std.testing.expectEqual(@as(usize, 1), report.uploaded_blocks);
    try std.testing.expectEqual(@as(usize, 1), f.fake.multipart_calls);
    // The completion refuses to replace a pack that already has the name.
    try std.testing.expect(f.fake.complete_conditional);
    try std.testing.expect(f.fake.sleeps >= 300_000);
    try std.testing.expectEqual(@as(usize, 1), try f.service.verify(null));
}

test "offsite: interruption loses at most current pack; completed segments resume" {
    const f = try Fixture.create();
    defer f.destroy();
    const bytes = try a.alloc(u8, 600 * 1024);
    defer a.free(bytes);
    @memset(bytes, 'a');
    _ = try f.add("a.bin", bytes);
    @memset(bytes, 'b');
    _ = try f.add("b.bin", bytes);
    f.fake.fail_segment_at = 2;
    try std.testing.expectError(error.AccessDenied, f.run());
    const report = try f.run();
    try std.testing.expectEqual(@as(usize, 1), report.uploaded_blocks);
    try std.testing.expectEqual(@as(usize, 2), try f.service.verify(null));
}

test "offsite: purge retries after replacement index failure without losing shared data" {
    const f = try Fixture.create();
    defer f.destroy();
    _ = try f.add("remove.txt", "remove");
    _ = try f.add("keep.txt", "keep");
    _ = try f.run();
    try f.forget("remove.txt");
    f.fake.fail_segment_once = true;
    try std.testing.expectError(error.AccessDenied, f.run());
    _ = try f.run();
    try std.testing.expectEqual(@as(usize, 1), try f.service.verify(null));
    try std.testing.expectEqual(@as(usize, 1), f.service.index.count());
}

test "offsite: clear mode restores with integrity; purge log and recovery entropy remain encrypted" {
    const f = try Fixture.create();
    defer f.destroy();
    f.service.config.encrypt = false;
    try std.testing.expectError(error.Locked, f.forget("a.txt"));
    _ = try f.add("a.txt", "clear text");
    const report = try f.run();
    try f.forget("a.txt");
    var it = f.fake.objects.iterator();
    while (it.next()) |e| {
        if (std.mem.startsWith(u8, e.key_ptr.*, "swarm/purges/") or std.mem.endsWith(u8, e.key_ptr.*, "/recovery-entropy")) {
            try std.testing.expectEqual(backup.pack.Mode.encrypted, (try backup.pack.Header.decode(e.value_ptr.bytes)).mode);
        }
    }
    var target = std.testing.tmpDir(.{});
    defer target.cleanup();
    try std.testing.expectEqual(@as(usize, 1), try restore(&f.service, report.snapshot, null, target.dir));
    try std.testing.expectEqual(@as(usize, 1), try f.service.verify(null));
    _ = try f.run();
    try std.testing.expectEqual(@as(usize, 0), f.service.index.count());
}

test "offsite: restore refuses symlink parents and existing output" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    const f = try Fixture.create();
    defer f.destroy();
    _ = try f.add("Photos/a.txt", "bytes");
    const report = try f.run();
    var target = std.testing.tmpDir(.{});
    defer target.cleanup();
    try target.dir.symLink(io, "/tmp", "Photos", .{ .is_directory = true });
    const result = restore(&f.service, report.snapshot, null, target.dir);
    if (result) |_| return error.TestExpectedError else |_| {}
    try target.dir.deleteFile(io, "Photos");
    _ = try restore(&f.service, report.snapshot, null, target.dir);
    try std.testing.expectError(error.PathAlreadyExists, restore(&f.service, report.snapshot, null, target.dir));
}

test "offsite: missing device wrap never replaces an existing bucket key" {
    const f = try Fixture.create();
    defer f.destroy();
    _ = try f.add("a.txt", "bytes");
    _ = try f.run();
    const key_before = f.service.key.?;
    var it = f.fake.objects.iterator();
    var wrap: ?[]const u8 = null;
    while (it.next()) |e| {
        if (std.mem.startsWith(u8, e.key_ptr.*, "swarm/keys/") and e.key_ptr.*.len > 70) {
            wrap = e.key_ptr.*;
            break;
        }
    }
    const removed = f.fake.objects.fetchRemove(wrap.?).?;
    a.free(removed.key);
    a.free(removed.value.bytes);
    try std.testing.expectError(error.RecoveryPhraseRequired, f.run());
    try std.testing.expectEqualSlices(u8, &key_before, &f.service.key.?);
}

test "offsite: multi-level DAG restore preserves repeated shared blocks and purge keeps another file's leaf" {
    const f = try Fixture.create();
    defer f.destroy();
    const removed = try f.composite("remove.txt", &.{ "shared", "private" });
    _ = try f.composite("keep.txt", &.{ "shared", "retained", "shared" });
    const report = try f.run();
    var target = std.testing.tmpDir(.{});
    defer target.cleanup();
    try std.testing.expectEqual(@as(usize, 2), try restore(&f.service, report.snapshot, null, target.dir));
    const bytes = try target.dir.readFileAlloc(io, "keep.txt", a, .limited(100));
    defer a.free(bytes);
    try std.testing.expectEqualStrings("sharedretainedshared", bytes);
    try f.forget("remove.txt");
    _ = try f.run();
    try std.testing.expect(!f.service.index.contains(backup.index.keyedBlockId(f.service.key.?, removed)));
    try std.testing.expectEqual(@as(usize, 3), try f.service.verify(null));
    try std.testing.expectEqual(@as(usize, 3), f.service.index.count());
}

test "offsite: fs source snapshots the public manifest with nested files and empty directories" {
    const f = try Fixture.create();
    defer f.destroy();
    var path: [std.fs.max_path_bytes]u8 = undefined;
    const root = path[0..try f.tmp.dir.realPath(io, &path)];
    const manifest_path = try std.fs.path.join(a, &.{ root, "manifest.json" });
    defer a.free(manifest_path);
    const folder = try @import("../fs/swarm.zig").SwarmFolder.create(a, io, &f.store, .{ .bytes = [_]u8{7} ** 32 }, "test", manifest_path);
    defer folder.destroy();
    const cid = try f.add("Folder/a.txt", "source bytes");
    _ = try folder.importFiles(&.{.{ .path = "Folder/a.txt", .cid = cid, .size = "source bytes".len, .mtime = 1 }});
    try folder.makeDir("", "Empty");
    var source: @import("../fs/offsite.zig").Source = .{ .folder = folder, .store = &f.store };
    const report = try f.service.run(source.source(), &f.store);
    var target = std.testing.tmpDir(.{});
    defer target.cleanup();
    try std.testing.expectEqual(@as(usize, 1), try restore(&f.service, report.snapshot, null, target.dir));
    const empty = try target.dir.openDir(io, "Empty", .{});
    empty.close(io);
    const bytes = try target.dir.readFileAlloc(io, "Folder/a.txt", a, .limited(100));
    defer a.free(bytes);
    try std.testing.expectEqualStrings("source bytes", bytes);
}

test "offsite: trusted device enrollment writes an identity-derived wrap" {
    const f = try Fixture.create();
    defer f.destroy();
    _ = try f.run();
    const identity = try @import("../device/identity.zig").Identity.fromSeed([_]u8{44} ** 32);
    var pair = try std.crypto.dh.X25519.KeyPair.fromEd25519(identity.key_pair);
    defer std.crypto.secureZero(u8, &pair.secret_key);
    try f.service.acquire();
    try f.service.wrapDevice(identity.deviceId().bytes, pair.public_key);
    f.service.release();
    var other = try core.Service.init(a, &f.client, f.service.config, .{ .id = identity.deviceId().bytes, .public = pair.public_key, .secret = pair.secret_key });
    defer other.deinit();
    other.clock_ctx = &f.fake;
    other.clockFn = Fake.clock;
    try other.unlock(null);
    try std.testing.expectEqualSlices(u8, &f.service.key.?, &other.key.?);
}

test "offsite: retention prunes snapshots but historical catalog keeps normally deleted bytes through another purge" {
    const f = try Fixture.create();
    defer f.destroy();
    const historical = try f.add("historical.txt", "historical bytes");
    _ = try f.add("purge.txt", "purged bytes");
    const first = try f.run();
    f.files.clearRetainingCapacity();
    _ = try f.run(); // same month, later empty snapshot
    f.fake.time += 90 * 86400;
    _ = try f.run();
    try std.testing.expect(!(try f.names(first.snapshot)));
    try f.forget("purge.txt");
    _ = try f.run();
    const bytes = try f.service.readBlock(historical);
    defer a.free(bytes);
    try std.testing.expectEqualStrings("\x00historical bytes", bytes);
    try std.testing.expectEqual(@as(usize, 1), f.service.index.count());
}

test "offsite: a block larger than pack target gets its own bounded pack" {
    const f = try Fixture.create();
    defer f.destroy();
    const bytes = try a.alloc(u8, 2 * 1024 * 1024);
    defer a.free(bytes);
    @memset(bytes, 'a');
    _ = try f.add("large.bin", bytes);
    _ = try f.run();
    try std.testing.expectEqual(@as(usize, 1), try f.service.verify(null));
}

test "offsite: only packs take the cold storage class; metadata stays standard" {
    const f = try Fixture.createCold();
    defer f.destroy();
    f.service.config.pack_mb = 8;
    _ = try f.add("Photos/a.jpg", "photo bytes");
    _ = try f.run();
    const bytes = try a.alloc(u8, 6 * 1024 * 1024);
    defer a.free(bytes);
    @memset(bytes, 'p');
    _ = try f.add("large.bin", bytes);
    _ = try f.run();
    try f.forget("nothing.txt");
    try std.testing.expectEqual(@as(usize, 1), f.fake.multipart_calls);
    var packs: usize = 0;
    var others: usize = 0;
    var it = f.fake.objects.iterator();
    while (it.next()) |e| {
        if (std.mem.startsWith(u8, e.key_ptr.*, "swarm/packs/")) {
            try std.testing.expectEqualStrings("DEEP_ARCHIVE", e.value_ptr.class.?);
            packs += 1;
        } else {
            try std.testing.expect(e.value_ptr.class == null);
            others += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 2), packs);
    // Layout, wraps, recovery entropy, catalog, index, snapshots, purge, lease.
    try std.testing.expect(others >= 9);
    const status = try f.service.status();
    try std.testing.expectEqual(@TypeOf(status.storage_class).DEEP_ARCHIVE, status.storage_class);
}

test "offsite: warm target sends no storage class at all" {
    const f = try Fixture.create();
    defer f.destroy();
    _ = try f.add("a.txt", "bytes");
    _ = try f.run();
    var it = f.fake.objects.valueIterator();
    while (it.next()) |object| try std.testing.expect(object.class == null);
}

test "offsite: cold target retention prunes snapshots and never deletes a young pack" {
    const f = try Fixture.createCold();
    defer f.destroy();
    const cid = try f.add("old.txt", "kept by the catalog");
    const first = try f.run();
    const pack = try f.packKey(cid);
    f.files.clearRetainingCapacity();
    _ = try f.run(); // same month: the monthly rule keeps the later snapshot only
    try std.testing.expect(!(try f.names(first.snapshot)));
    // An unreferenced pack (an upload cut before its index segment) and a
    // purge that makes every run sweep: the young orphan must stay.
    const orphan = "swarm/packs/000102030405060708090a0b0c0d0e0f";
    try f.fake.set(orphan, "orphan pack bytes");
    f.fake.objects.getPtr(orphan).?.class = "DEEP_ARCHIVE";
    try f.forget("never-there.txt");
    f.fake.time += 40 * day;
    _ = try f.run();
    try std.testing.expect(f.fake.objects.contains(pack));
    try std.testing.expect(f.fake.objects.contains(orphan));
    var status = try f.service.status();
    try std.testing.expectEqual(@as(usize, 2), status.snapshots.len);
    try std.testing.expectEqual(@as(usize, 1), status.deferred_packs);
    try std.testing.expectEqual(f.fake.objects.get(orphan).?.modified + 180 * day, status.deferred_first);
    // Past the 180 days the orphan goes; the referenced pack is never touched.
    f.fake.time += 150 * day;
    _ = try f.run();
    try std.testing.expect(!f.fake.objects.contains(orphan));
    try std.testing.expect(f.fake.objects.contains(pack));
    status = try f.service.status();
    try std.testing.expectEqual(@as(usize, 0), status.deferred_packs);
    try std.testing.expectEqual(@as(usize, 0), f.fake.restore_requests);
}

test "offsite: purge on a cold target forgets the file at once and removes the pack bytes after the minimum storage time" {
    const f = try Fixture.createCold();
    defer f.destroy();
    const removed = try f.add("private.txt", "private unique bytes");
    const kept = try f.add("keep.txt", "kept bytes");
    _ = try f.run();
    const old_pack = try f.packKey(removed);
    const born = f.fake.objects.get(old_pack).?.modified;
    try f.forget("private.txt");
    // The monthly rule keeps this later snapshot; the purge filters the new one too.
    const second = try f.run();
    // Gone from history and index now; the pack itself waits.
    try std.testing.expect(f.fake.objects.contains(old_pack));
    try std.testing.expect(!f.service.index.contains(backup.index.keyedBlockId(f.service.key.?, removed)));
    try std.testing.expect(f.service.index.contains(backup.index.keyedBlockId(f.service.key.?, kept)));
    const snap = try f.service.snapshot(second.snapshot);
    try std.testing.expectEqual(@as(usize, 1), snap.files.len);
    try std.testing.expectEqualStrings("keep.txt", snap.files[0].path);
    var status = try f.service.status();
    try std.testing.expectEqual(@as(usize, 1), status.deferred_packs);
    try std.testing.expectEqual(born + 180 * day, status.deferred_first);
    try std.testing.expectEqual(born + 180 * day, status.deferred_last);
    try std.testing.expectEqual(@as(usize, 0), f.fake.restore_requests);
    // Still young at 179 days: nothing moves, nothing is thawed.
    f.fake.time += 179 * day;
    _ = try f.run();
    try std.testing.expect(f.fake.objects.contains(old_pack));
    try std.testing.expectEqual(@as(usize, 0), f.fake.restore_requests);
    // Aged out: the kept block needs the pack thawed before it can be copied.
    f.fake.time += 2 * day;
    _ = try f.run();
    try std.testing.expect(f.fake.objects.contains(old_pack));
    try std.testing.expectEqual(@as(usize, 1), f.fake.restore_requests);
    try std.testing.expectEqualStrings("Bulk", f.fake.last_tier);
    f.fake.finishThaws();
    _ = try f.run();
    // Copied; the old pack is garbage now and goes after the grace.
    try std.testing.expect(f.fake.objects.contains(old_pack));
    f.fake.time += day;
    _ = try f.run();
    try std.testing.expect(!f.fake.objects.contains(old_pack));
    const new_pack = try f.packKey(kept);
    try std.testing.expect(!std.mem.eql(u8, old_pack, new_pack));
    try std.testing.expectEqualStrings("DEEP_ARCHIVE", f.fake.objects.get(new_pack).?.class.?);
    status = try f.service.status();
    try std.testing.expectEqual(@as(usize, 0), status.deferred_packs);
    const check = try f.service.check(null, false, .Bulk);
    try std.testing.expectEqual(@as(usize, 1), check.packs);
    try std.testing.expectEqual(@as(usize, 1), check.blocks);
}

test "offsite: cold restore asks for thaws first, then restores when the packs are ready" {
    const f = try Fixture.createCold();
    defer f.destroy();
    _ = try f.add("Photos/a.jpg", "photo bytes");
    _ = try f.add("Notes/b.txt", "notes bytes\n");
    const report = try f.run();
    var target = std.testing.tmpDir(.{});
    defer target.cleanup();
    const first = try restoreRequest(&f.service, report.snapshot, null, target.dir, .Standard);
    try std.testing.expectEqual(@as(usize, 0), first.files);
    try std.testing.expectEqual(@as(usize, 1), first.thawing_packs);
    try std.testing.expect(first.thawing_bytes > 0);
    try std.testing.expectEqual(@as(usize, 1), f.fake.restore_requests);
    try std.testing.expectEqualStrings("Standard", f.fake.last_tier);
    try std.testing.expectError(error.FileNotFound, target.dir.statFile(io, "Notes/b.txt", .{}));
    // The pending job is on disk: a new session (a restart) picks it up.
    const job = try target.dir.readFileAlloc(io, ".nomadfs-restore/job.json", a, .limited(4096));
    defer a.free(job);
    try std.testing.expect(std.mem.indexOf(u8, job, report.snapshot) != null);
    var other = try core.Service.init(a, &f.client, f.service.config, f.service.device);
    defer other.deinit();
    other.clock_ctx = &f.fake;
    other.clockFn = Fake.clock;
    try other.unlock(null);
    // Still thawing: no second request, nothing written.
    const waiting = try restoreRequest(&other, report.snapshot, null, target.dir, .Standard);
    try std.testing.expectEqual(@as(usize, 0), waiting.files);
    try std.testing.expectEqual(@as(usize, 1), waiting.thawing_packs);
    try std.testing.expectEqual(@as(usize, 1), f.fake.restore_requests);
    // A different request must not reuse this directory's job.
    try std.testing.expectError(error.RestoreJobMismatch, restoreRequest(&other, report.snapshot, "Photos", target.dir, .Standard));
    f.fake.finishThaws();
    const done = try restoreRequest(&other, report.snapshot, null, target.dir, .Standard);
    try std.testing.expectEqual(@as(usize, 2), done.files);
    try std.testing.expectEqual(@as(usize, 0), done.thawing_packs);
    try std.testing.expectEqual(@as(usize, 1), f.fake.restore_requests);
    const bytes = try target.dir.readFileAlloc(io, "Notes/b.txt", a, .limited(100));
    defer a.free(bytes);
    try std.testing.expectEqualStrings("notes bytes\n", bytes);
    const photo = try target.dir.readFileAlloc(io, "Photos/a.jpg", a, .limited(100));
    defer a.free(photo);
    try std.testing.expectEqualStrings("photo bytes", photo);
    try std.testing.expectError(error.FileNotFound, target.dir.statFile(io, ".nomadfs-restore", .{}));
}

test "offsite: cold restore writes the files of ready packs and resumes for the rest" {
    const f = try Fixture.createCold();
    defer f.destroy();
    _ = try f.add("a.txt", "first pack");
    _ = try f.run();
    const b = try f.add("b.txt", "second pack");
    const report = try f.run();
    var it = f.fake.objects.valueIterator();
    while (it.next()) |object| {
        if (isCold(object.class)) object.thaw = .ready;
    }
    f.fake.objects.getPtr(try f.packKey(b)).?.thaw = .none;
    var target = std.testing.tmpDir(.{});
    defer target.cleanup();
    const first = try restoreRequest(&f.service, report.snapshot, null, target.dir, .Bulk);
    try std.testing.expectEqual(@as(usize, 1), first.files);
    try std.testing.expectEqual(@as(usize, 1), first.thawing_packs);
    f.fake.finishThaws();
    const done = try restoreRequest(&f.service, report.snapshot, null, target.dir, .Bulk);
    try std.testing.expectEqual(@as(usize, 2), done.files);
    try std.testing.expectEqual(@as(usize, 0), done.thawing_packs);
    const bytes = try target.dir.readFileAlloc(io, "b.txt", a, .limited(100));
    defer a.free(bytes);
    try std.testing.expectEqualStrings("second pack", bytes);
}

test "offsite: cold verify checks packs by listing, finds a missing or cut pack, and downloads only when asked" {
    const f = try Fixture.createCold();
    defer f.destroy();
    const cid = try f.add("a.txt", "hello");
    _ = try f.add("b.txt", "world");
    _ = try f.run();
    const listed = try f.service.check(null, false, .Bulk);
    try std.testing.expect(!listed.downloaded);
    try std.testing.expectEqual(@as(usize, 1), listed.packs);
    try std.testing.expectEqual(@as(usize, 2), listed.blocks);
    try std.testing.expectEqual(@as(usize, 0), f.fake.restore_requests);
    // --download: thaw first, read every block once the packs are ready.
    const thawing = try f.service.check(null, true, .Bulk);
    try std.testing.expectEqual(@as(usize, 1), thawing.thawing_packs);
    try std.testing.expectEqual(@as(usize, 0), thawing.blocks);
    try std.testing.expectEqual(@as(usize, 1), f.fake.restore_requests);
    f.fake.finishThaws();
    const read = try f.service.check(null, true, .Bulk);
    try std.testing.expect(read.downloaded);
    try std.testing.expectEqual(@as(usize, 2), read.blocks);
    const pack = try f.packKey(cid);
    const object = f.fake.objects.getPtr(pack).?;
    const full = object.bytes;
    object.bytes = full[0 .. full.len - 1];
    try std.testing.expectError(error.PackTruncated, f.service.check(null, false, .Bulk));
    object.bytes = full;
    const removed = f.fake.objects.fetchRemove(pack).?;
    a.free(removed.key);
    a.free(removed.value.bytes);
    try std.testing.expectError(error.PackMissing, f.service.check(null, false, .Bulk));
}

test "offsite: a new target reuses another target's backup key and recovery words" {
    const f = try Fixture.create();
    defer f.destroy();
    _ = try f.add("a.txt", "bytes");
    const warm = try f.run();
    var config = f.service.config;
    config.prefix = "archive";
    config.storage_class = .DEEP_ARCHIVE;
    var cold = try core.Service.init(a, &f.client, config, f.service.device);
    defer cold.deinit();
    cold.clock_ctx = &f.fake;
    cold.clockFn = Fake.clock;
    try std.testing.expect(!(try cold.initialised()));
    try cold.adopt(f.service.key.?, try f.service.recoveryKey());
    const report = try cold.run(f.source(), &f.store);
    try std.testing.expect(report.reused_key);
    try std.testing.expectEqualStrings(warm.recovery_phrase.?, report.recovery_phrase.?);
    try std.testing.expectEqualSlices(u8, &f.service.key.?, &cold.key.?);
    try std.testing.expect(try cold.initialised());
    // The one set of words opens the archive from a device with no wrap.
    const pair = try std.crypto.dh.X25519.KeyPair.generateDeterministic([_]u8{8} ** 32);
    var stranger = try core.Service.init(a, &f.client, config, .{ .id = [_]u8{8} ** 32, .public = pair.public_key, .secret = pair.secret_key });
    defer stranger.deinit();
    stranger.clock_ctx = &f.fake;
    stranger.clockFn = Fake.clock;
    try stranger.unlock(warm.recovery_phrase);
    try std.testing.expectEqualStrings(warm.recovery_phrase.?, try stranger.recoveryKey());
}

test "offsite: the periodic uploader is due by the target's schedule" {
    const f = try Fixture.create();
    defer f.destroy();
    f.service.config.schedule = .weekly;
    try std.testing.expect(try f.service.due());
    _ = try f.add("a.txt", "bytes");
    _ = try f.run();
    try std.testing.expect(!(try f.service.due()));
    f.fake.time += 6 * day;
    try std.testing.expect(!(try f.service.due()));
    f.fake.time += day;
    try std.testing.expect(try f.service.due());
    f.service.config.schedule = .monthly;
    try std.testing.expect(!(try f.service.due()));
    f.service.config.schedule = .daily;
    try std.testing.expect(try f.service.due());
}

test "offsite: a file with a missing block is left out and counted, then uploaded once the block is here" {
    const f = try Fixture.create();
    defer f.destroy();
    var path: [std.fs.max_path_bytes]u8 = undefined;
    const root = path[0..try f.tmp.dir.realPath(io, &path)];
    const manifest_path = try std.fs.path.join(a, &.{ root, "manifest.json" });
    defer a.free(manifest_path);
    const folder = try @import("../fs/swarm.zig").SwarmFolder.create(a, io, &f.store, .{ .bytes = [_]u8{7} ** 32 }, "test", manifest_path);
    defer folder.destroy();
    const whole = try f.add("whole.txt", "all here");
    // A two-chunk file whose second chunk the keeper has not fetched yet.
    const here = try f.add("unused", "first chunk");
    const late = storage.block.Block.new(&([_]u8{0} ++ "second chunk".*));
    const links = [_]storage.dag.node.DagLink{ .{ .name = "", .cid = &here, .size = 11 }, .{ .name = "", .cid = &late.cid, .size = 12 } };
    const parent = storage.block.Block.new(try storage.dag.codec.encodeParent(f.arena.allocator(), &links));
    try f.store.put(parent);
    _ = try folder.importFiles(&.{ .{ .path = "whole.txt", .cid = whole, .size = 8, .mtime = 1 }, .{ .path = "Phone/Camera/partial.bin", .cid = parent.cid, .size = 23, .mtime = 1 } });
    var source: @import("../fs/offsite.zig").Source = .{ .folder = folder, .store = &f.store };

    const first = try f.service.run(source.source(), &f.store);
    try std.testing.expectEqual(@as(usize, 1), first.waiting_files);
    const partial = try f.service.snapshot(first.snapshot);
    try std.testing.expectEqual(@as(usize, 1), partial.files.len);
    try std.testing.expectEqualStrings("whole.txt", partial.files[0].path);
    // Nothing of the half-present file went up, not even the chunk that is here.
    try std.testing.expectEqual(@as(usize, 1), first.uploaded_blocks);

    try f.store.put(late);
    f.fake.time += 1;
    const second = try f.service.run(source.source(), &f.store);
    try std.testing.expectEqual(@as(usize, 0), second.waiting_files);
    try std.testing.expectEqual(@as(usize, 3), second.uploaded_blocks);
    var target = std.testing.tmpDir(.{});
    defer target.cleanup();
    try std.testing.expectEqual(@as(usize, 2), try restore(&f.service, second.snapshot, null, target.dir));
    const bytes = try target.dir.readFileAlloc(io, "Phone/Camera/partial.bin", a, .limited(100));
    defer a.free(bytes);
    try std.testing.expectEqualStrings("first chunksecond chunk", bytes);
}

const worker_mod = @import("offsite_worker.zig");
const TargetConfig = @import("../backup/config.zig").Config;
const Uploads = struct {
    var names: [8][]const u8 = undefined;
    var count: usize = 0;
    fn record(_: *worker_mod.Worker, config: TargetConfig, _: usize, _: bool) anyerror!void {
        names[count] = config.name;
        count += 1;
    }
    fn took(name: []const u8) bool {
        for (names[0..count]) |n| if (std.mem.eql(u8, n, name)) return true;
        return false;
    }
};

test "offsite: the worker uploads to cold targets only on a deep backup device, warm ones on a swarm backup device" {
    const Config = TargetConfig;
    const warm: Config = .{ .name = "s3", .endpoint = "https://warm", .bucket = "b", .credentials = "/none" };
    const cold: Config = .{ .name = "archive", .endpoint = "https://cold", .bucket = "b", .credentials = "/none", .storage_class = .DEEP_ARCHIVE };
    const glacier: Config = .{ .name = "glacier", .endpoint = "https://cold", .bucket = "g", .credentials = "/none", .storage_class = .GLACIER };

    // The policy itself.
    try std.testing.expectEqual(worker_mod.Gate.needs_swarm_backup, worker_mod.gate(warm, .{}));
    try std.testing.expectEqual(worker_mod.Gate.uploading, worker_mod.gate(warm, .{ .swarm_backup = true }));
    try std.testing.expectEqual(worker_mod.Gate.needs_deep_backup, worker_mod.gate(cold, .{ .swarm_backup = true }));
    try std.testing.expectEqual(worker_mod.Gate.needs_deep_backup, worker_mod.gate(glacier, .{ .swarm_backup = true }));
    try std.testing.expectEqual(worker_mod.Gate.uploading, worker_mod.gate(cold, .{ .swarm_backup = true, .deep_backup = true }));
    try std.testing.expect(worker_mod.hasArchive(&.{ warm, cold }) and !worker_mod.hasArchive(&.{warm}));
    try std.testing.expect(!worker_mod.hasArchive(&.{.{ .name = "half", .storage_class = .GLACIER }}));

    const identity = try @import("../device/mod.zig").identity.Identity.fromSeed([_]u8{3} ** 32);
    const w = try worker_mod.Worker.create(a, &.{ warm, cold, glacier }, identity, undefined, undefined, undefined);
    defer w.destroy();
    w.uploadFn = Uploads.record;

    // Neither role: nothing uploads, and each status says why.
    Uploads.count = 0;
    try w.round(true);
    try std.testing.expectEqual(@as(usize, 0), Uploads.count);
    try std.testing.expectEqual(worker_mod.Gate.needs_swarm_backup, w.statusOf("s3").?.gate);
    try std.testing.expectEqual(worker_mod.Gate.needs_deep_backup, w.archiveStatus().?.gate);

    // Swarm backup: the warm target only, also when asked to run now.
    w.setRoles(.{ .swarm_backup = true });
    try w.round(true);
    try std.testing.expectEqual(@as(usize, 1), Uploads.count);
    try std.testing.expect(Uploads.took("s3"));
    try std.testing.expectEqual(worker_mod.Gate.uploading, w.statusOf("s3").?.gate);
    try std.testing.expectEqual(worker_mod.Gate.needs_deep_backup, w.statusOf("archive").?.gate);
    try std.testing.expect(w.statusOf("archive").?.gate.text().len > 0);
    try std.testing.expect(!w.archiveMissing());

    // Deep backup: every target, applied without a restart.
    Uploads.count = 0;
    w.setRoles(.{ .swarm_backup = true, .deep_backup = true });
    try std.testing.expectEqual(worker_mod.Gate.uploading, w.statusOf("glacier").?.gate);
    try w.round(false);
    try std.testing.expectEqual(@as(usize, 3), Uploads.count);
    try std.testing.expect(Uploads.took("archive") and Uploads.took("glacier") and Uploads.took("s3"));

    // Turned off again: the cold targets stop.
    Uploads.count = 0;
    w.setRoles(.{ .swarm_backup = true });
    try w.round(false);
    try std.testing.expectEqual(@as(usize, 1), Uploads.count);
    try std.testing.expect(!Uploads.took("archive"));

    // A deep backup device with warm targets only has no archive to fill.
    const lone = try worker_mod.Worker.create(a, &.{warm}, identity, undefined, undefined, undefined);
    defer lone.destroy();
    lone.setRoles(.{ .swarm_backup = true, .deep_backup = true });
    try std.testing.expect(lone.archiveMissing());
    try std.testing.expect(lone.archiveStatus() == null);
    try std.testing.expectEqualStrings("no archive target configured", worker_mod.no_archive);
}

fn restoreHistory(service: *core.Service, path: ?[]const u8, version: fs_restore.Version, destination: std.Io.Dir) !core.Restore {
    return fs_restore.restore(a, io, service, .{ .from = .{ .history = version }, .path = path }, destination);
}
fn expectFile(dir: std.Io.Dir, path: []const u8, expected: []const u8) !void {
    const bytes = try dir.readFileAlloc(io, path, a, .limited(4096));
    defer a.free(bytes);
    try std.testing.expectEqualStrings(expected, bytes);
}
/// The absolute path of `name` inside a test directory.
fn pathIn(dir: std.Io.Dir, name: []const u8) ![]u8 {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = buf[0..try dir.realPath(io, &buf)];
    return std.fs.path.join(a, &.{ root, name });
}

test "offsite: restore job files never follow a symlink placed in the destination" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    const f = try Fixture.createCold();
    defer f.destroy();
    _ = try f.add("a.txt", "good");
    const report = try f.run();
    var victim = std.testing.tmpDir(.{});
    defer victim.cleanup();
    try victim.dir.writeFile(io, .{ .sub_path = "victim", .data = "precious" });
    const precious = try pathIn(victim.dir, "victim");
    defer a.free(precious);

    // The old predictable temporary name: nothing opens it any more.
    var target = std.testing.tmpDir(.{});
    defer target.cleanup();
    try target.dir.symLink(io, precious, ".nomadfs-restore.json.tmp", .{});
    const first = try restoreRequest(&f.service, report.snapshot, null, target.dir, .Bulk);
    try std.testing.expectEqual(@as(usize, 1), first.thawing_packs);
    try expectFile(victim.dir, "victim", "precious");

    // The job directory itself is a link to somewhere else: refused.
    var linked = std.testing.tmpDir(.{});
    defer linked.cleanup();
    const outside = try pathIn(victim.dir, ".");
    defer a.free(outside);
    try linked.dir.symLink(io, outside, ".nomadfs-restore", .{ .is_directory = true });
    if (restoreRequest(&f.service, report.snapshot, null, linked.dir, .Bulk)) |_| return error.TestExpectedError else |_| {}
    try std.testing.expectError(error.FileNotFound, victim.dir.statFile(io, "job.json", .{}));
    try std.testing.expectError(error.FileNotFound, victim.dir.statFile(io, "done.log", .{}));

    // A job directory made in advance, with links where the job files go.
    var planted = std.testing.tmpDir(.{});
    defer planted.cleanup();
    try planted.dir.createDir(io, ".nomadfs-restore", .fromMode(0o700));
    try planted.dir.symLink(io, precious, ".nomadfs-restore/done.log", .{});
    if (restoreRequest(&f.service, report.snapshot, null, planted.dir, .Bulk)) |_| return error.TestExpectedError else |_| {}
    try planted.dir.deleteFile(io, ".nomadfs-restore/job.json");
    try planted.dir.symLink(io, precious, ".nomadfs-restore/job.json", .{});
    if (restoreRequest(&f.service, report.snapshot, null, planted.dir, .Bulk)) |_| return error.TestExpectedError else |_| {}
    try expectFile(victim.dir, "victim", "precious");
    try std.testing.expectError(error.FileNotFound, planted.dir.statFile(io, "a.txt", .{}));

    // A link at a file's final name is replaced, never written through.
    f.fake.finishThaws();
    try target.dir.symLink(io, precious, "a.txt", .{});
    const done = try restoreRequest(&f.service, report.snapshot, null, target.dir, .Bulk);
    try std.testing.expectEqual(@as(usize, 1), done.files);
    try expectFile(target.dir, "a.txt", "good");
    try expectFile(victim.dir, "victim", "precious");
}

test "offsite: restored files named like the job files are plain files; the job directory name is reserved" {
    const f = try Fixture.createCold();
    defer f.destroy();
    _ = try f.add(".nomadfs-restore.json", "first");
    _ = try f.add(".nomadfs-restore.json.tmp", "second");
    _ = try f.add("job.json", "third");
    const report = try f.run();
    var target = std.testing.tmpDir(.{});
    defer target.cleanup();
    const first = try restoreRequest(&f.service, report.snapshot, null, target.dir, .Bulk);
    try std.testing.expectEqual(@as(usize, 0), first.files);
    f.fake.finishThaws();
    const done = try restoreRequest(&f.service, report.snapshot, null, target.dir, .Bulk);
    try std.testing.expectEqual(@as(usize, 3), done.files);
    try expectFile(target.dir, ".nomadfs-restore.json", "first");
    try expectFile(target.dir, ".nomadfs-restore.json.tmp", "second");
    try expectFile(target.dir, "job.json", "third");
    try std.testing.expectError(error.FileNotFound, target.dir.statFile(io, ".nomadfs-restore", .{}));

    // A snapshot path inside the job directory would collide: refused whole.
    _ = try f.add(".nomadfs-restore/job.json", "fourth");
    const colliding = try f.run();
    var other = std.testing.tmpDir(.{});
    defer other.cleanup();
    try std.testing.expectError(error.ReservedPath, restoreRequest(&f.service, colliding.snapshot, null, other.dir, .Bulk));
    try std.testing.expectError(error.FileNotFound, other.dir.statFile(io, ".nomadfs-restore", .{}));
    // The other files are still reachable one by one (their pack is thawed).
    try std.testing.expectEqual(@as(usize, 1), (try restoreRequest(&f.service, colliding.snapshot, "job.json", other.dir, .Bulk)).files);
    try expectFile(other.dir, "job.json", "third");
}

test "offsite: cold restore resume rewrites a file with wrong bytes of the same size" {
    const f = try Fixture.createCold();
    defer f.destroy();
    _ = try f.add("a.txt", "good");
    const report = try f.run();
    var target = std.testing.tmpDir(.{});
    defer target.cleanup();
    _ = try restoreRequest(&f.service, report.snapshot, null, target.dir, .Bulk);
    f.fake.finishThaws();
    try target.dir.writeFile(io, .{ .sub_path = "a.txt", .data = "EVIL" });
    const done = try restoreRequest(&f.service, report.snapshot, null, target.dir, .Bulk);
    try std.testing.expectEqual(@as(usize, 1), done.files);
    try expectFile(target.dir, "a.txt", "good");
}

test "offsite: cold restore resume replaces a file cut short" {
    const f = try Fixture.createCold();
    defer f.destroy();
    _ = try f.add("a.txt", "good");
    const report = try f.run();
    var target = std.testing.tmpDir(.{});
    defer target.cleanup();
    _ = try restoreRequest(&f.service, report.snapshot, null, target.dir, .Bulk);
    f.fake.finishThaws();
    try target.dir.writeFile(io, .{ .sub_path = "a.txt", .data = "go" });
    const done = try restoreRequest(&f.service, report.snapshot, null, target.dir, .Bulk);
    try std.testing.expectEqual(@as(usize, 1), done.files);
    try expectFile(target.dir, "a.txt", "good");
}

test "offsite: a restore killed half way resumes: recorded files stay, the rest is written again, stale temporary files go" {
    const f = try Fixture.createCold();
    defer f.destroy();
    _ = try f.add("a.txt", "first pack");
    _ = try f.run();
    const b = try f.add("Sub/b.txt", "second pack");
    _ = try f.run();
    _ = try f.add("c.txt", "third");
    const report = try f.run();
    var it = f.fake.objects.valueIterator();
    while (it.next()) |object| {
        if (isCold(object.class)) object.thaw = .ready;
    }
    f.fake.objects.getPtr(try f.packKey(b)).?.thaw = .none;
    var target = std.testing.tmpDir(.{});
    defer target.cleanup();
    const first = try restoreRequest(&f.service, report.snapshot, null, target.dir, .Bulk);
    try std.testing.expectEqual(@as(usize, 2), first.files);
    try std.testing.expectEqual(@as(usize, 1), first.thawing_packs);

    // What a kill leaves: a temporary file, a half-written record at the
    // end of the list, and a file that reached its name but not the list.
    try target.dir.writeFile(io, .{ .sub_path = ".nomadfs-restore/file-0123456789abcdef0123456789abcdef.tmp", .data = "half a fi" });
    const log = try target.dir.readFileAlloc(io, ".nomadfs-restore/done.log", a, .limited(4096));
    defer a.free(log);
    const one = std.mem.indexOfScalar(u8, log, '\n').? + 1;
    const torn = try std.mem.concat(a, u8, &.{ log[0..one], log[one .. one + 20] });
    defer a.free(torn);
    try target.dir.writeFile(io, .{ .sub_path = ".nomadfs-restore/done.log", .data = torn });
    const recorded_first = std.mem.indexOf(u8, log[0..one], "a.txt") != null;
    const recorded: []const u8 = if (recorded_first) "a.txt" else "c.txt";
    const unrecorded: []const u8 = if (recorded_first) "c.txt" else "a.txt";
    try target.dir.writeFile(io, .{ .sub_path = unrecorded, .data = "junk" });
    const before = (try target.dir.statFile(io, recorded, .{})).inode;

    f.fake.finishThaws();
    var again = try core.Service.init(a, &f.client, f.service.config, f.service.device);
    defer again.deinit();
    again.clock_ctx = &f.fake;
    again.clockFn = Fake.clock;
    try again.unlock(null);
    const done = try restoreRequest(&again, report.snapshot, null, target.dir, .Bulk);
    try std.testing.expectEqual(@as(usize, 3), done.files);
    try std.testing.expectEqual(@as(usize, 0), done.thawing_packs);
    try expectFile(target.dir, "a.txt", "first pack");
    try expectFile(target.dir, "Sub/b.txt", "second pack");
    try expectFile(target.dir, "c.txt", "third");
    // The recorded file was not written again.
    try std.testing.expectEqual(before, (try target.dir.statFile(io, recorded, .{})).inode);
    try std.testing.expectError(error.FileNotFound, target.dir.statFile(io, ".nomadfs-restore", .{}));

    // A warm restore that failed half way leaves its job and resumes too.
    const w = try Fixture.create();
    defer w.destroy();
    const lost = try w.add("x.txt", "one");
    _ = try w.run();
    _ = try w.add("y.txt", "two");
    const warm = try w.run();
    const pack = try a.dupe(u8, try w.packKey(lost));
    defer a.free(pack);
    const removed = w.fake.objects.fetchRemove(pack).?;
    var half = std.testing.tmpDir(.{});
    defer half.cleanup();
    try std.testing.expectError(error.NotFound, restore(&w.service, warm.snapshot, null, half.dir));
    _ = try half.dir.statFile(io, ".nomadfs-restore/job.json", .{});
    try w.fake.objects.put(a, removed.key, removed.value);
    try std.testing.expectEqual(@as(usize, 2), try restore(&w.service, warm.snapshot, null, half.dir));
    try expectFile(half.dir, "x.txt", "one");
    try expectFile(half.dir, "y.txt", "two");
    try std.testing.expectError(error.FileNotFound, half.dir.statFile(io, ".nomadfs-restore", .{}));
    // Finished: the same restore again finds its files in the way.
    try std.testing.expectError(error.PathAlreadyExists, restore(&w.service, warm.snapshot, null, half.dir));
    try std.testing.expectError(error.FileNotFound, half.dir.statFile(io, ".nomadfs-restore", .{}));
}

test "offsite: a recorded file changed to other bytes of the same size is written again on resume" {
    const f = try Fixture.createCold();
    defer f.destroy();
    const first = try f.add("a.txt", "good");
    _ = try f.run();
    _ = try f.add("b.txt", "later");
    const report = try f.run();
    f.fake.objects.getPtr(try f.packKey(first)).?.thaw = .ready;
    var target = std.testing.tmpDir(.{});
    defer target.cleanup();
    const partial = try restoreRequest(&f.service, report.snapshot, null, target.dir, .Bulk);
    try std.testing.expectEqual(@as(usize, 1), partial.files);
    // The record holds the digest of the bytes written, not only the name.
    const log = try target.dir.readFileAlloc(io, ".nomadfs-restore/done.log", a, .limited(4096));
    defer a.free(log);
    var digest: [32]u8 = undefined;
    std.crypto.hash.Blake3.hash("good", &digest, .{});
    try std.testing.expect(std.mem.indexOf(u8, log, &std.fmt.bytesToHex(digest, .lower)) != null);
    // Recorded as finished, then replaced by other bytes of the same size.
    try target.dir.writeFile(io, .{ .sub_path = "a.txt", .data = "EVIL" });
    f.fake.finishThaws();
    const done = try restoreRequest(&f.service, report.snapshot, null, target.dir, .Bulk);
    try std.testing.expectEqual(@as(usize, 2), done.files);
    try expectFile(target.dir, "a.txt", "good");
    try expectFile(target.dir, "b.txt", "later");
    try std.testing.expectError(error.FileNotFound, target.dir.statFile(io, ".nomadfs-restore", .{}));
}

test "offsite: a cold restore resumes from its own plan after retention dropped its snapshot" {
    const f = try Fixture.createCold();
    defer f.destroy();
    _ = try f.add("a.txt", "good");
    const report = try f.run();
    var target = std.testing.tmpDir(.{});
    defer target.cleanup();
    const first = try restoreRequest(&f.service, report.snapshot, null, target.dir, .Bulk);
    try std.testing.expectEqual(@as(usize, 1), first.thawing_packs);
    // The next runs (same month, no dailies) stop naming the snapshot, and
    // after the grace its object is deleted: a bulk thaw takes up to 48 h.
    f.fake.time += day;
    _ = try f.run();
    try std.testing.expect(!(try f.names(report.snapshot)));
    f.fake.time += 2 * day;
    _ = try f.run();
    const object = try std.fmt.allocPrint(f.arena.allocator(), "swarm/{s}", .{report.snapshot});
    try std.testing.expect(!f.fake.objects.contains(object));
    f.fake.finishThaws();
    // A restart: the new session cannot read that snapshot, the job needs none.
    var again = try f.other();
    defer again.deinit();
    try again.unlock(null);
    try std.testing.expectError(error.InvalidSnapshot, again.snapshot(report.snapshot));
    const done = try restoreRequest(&again, report.snapshot, null, target.dir, .Bulk);
    try std.testing.expectEqual(@as(usize, 1), done.files);
    try std.testing.expectEqual(@as(usize, 0), done.thawing_packs);
    try expectFile(target.dir, "a.txt", "good");
    try std.testing.expectError(error.FileNotFound, target.dir.statFile(io, ".nomadfs-restore", .{}));
}

/// A restore of three files in two packs that stopped at its first file (its
/// pack was unreachable), then a purge of one of the other two: the pack
/// they share is copied without it and waits to be deleted.
const Interrupted = struct {
    f: *Fixture,
    reader: core.Service,
    target: std.testing.TmpDir,
    snapshot: []const u8,
    /// The pack the purge replaced.
    shared: []const u8,
    fn create() !Interrupted {
        const f = try Fixture.create();
        errdefer f.destroy();
        const lost = try f.add("first.txt", "one");
        _ = try f.run();
        _ = try f.add("private.txt", "secret");
        const kept = try f.add("keep.txt", "good");
        const report = try f.run();
        var self: Interrupted = .{ .f = f, .reader = try f.other(), .target = std.testing.tmpDir(.{}), .snapshot = report.snapshot, .shared = try f.packKey(kept) };
        errdefer self.reader.deinit();
        errdefer self.target.cleanup();
        try self.reader.unlock(null);
        const removed = f.fake.objects.fetchRemove(try f.packKey(lost)).?;
        try std.testing.expectError(error.NotFound, restore(&self.reader, report.snapshot, null, self.target.dir));
        try f.fake.objects.put(a, removed.key, removed.value);
        try std.testing.expectEqual(@as(usize, 1), self.pins());
        try f.forget("private.txt");
        _ = try f.run();
        try std.testing.expect(!std.mem.eql(u8, self.shared, try f.packKey(kept)));
        return self;
    }
    fn destroy(self: *Interrupted) void {
        self.target.cleanup();
        self.reader.deinit();
        self.f.destroy();
    }
    fn pins(self: *Interrupted) usize {
        var count: usize = 0;
        var it = self.f.fake.objects.keyIterator();
        while (it.next()) |key| count += @intFromBool(std.mem.startsWith(u8, key.*, "swarm/pins/"));
        return count;
    }
};

test "offsite: a pack a restore job pins outlives the purge that replaced it, then goes" {
    var t = try Interrupted.create();
    defer t.destroy();
    const f = t.f;
    // Past the grace: every other piece of garbage goes, the pinned pack waits.
    f.fake.time += 2 * day;
    _ = try f.run();
    try std.testing.expect(f.fake.objects.contains(t.shared));
    try std.testing.expectEqual(@as(usize, 1), (try f.service.status()).deferred_packs);
    // The reader still has the index from before the purge: its job reads
    // the plan, and the plan's packs are all there.
    try std.testing.expectEqual(@as(usize, 3), try restore(&t.reader, t.snapshot, null, t.target.dir));
    try expectFile(t.target.dir, "first.txt", "one");
    try expectFile(t.target.dir, "keep.txt", "good");
    try expectFile(t.target.dir, "private.txt", "secret");
    // The job is over and its pin with it: the pack goes within the grace.
    try std.testing.expectEqual(@as(usize, 0), t.pins());
    f.fake.time += day;
    _ = try f.run();
    try std.testing.expect(!f.fake.objects.contains(t.shared));
    try std.testing.expectEqual(@as(usize, 0), (try f.service.status()).deferred_packs);
}

test "offsite: a restore whose pin ran out plans the rest again from the current head" {
    var t = try Interrupted.create();
    defer t.destroy();
    const f = t.f;
    // Nobody resumed for longer than a pin lasts: the pack is deleted, and
    // the forgotten pin a grace later.
    f.fake.time += core.pin_seconds + day;
    _ = try f.run();
    try std.testing.expect(!f.fake.objects.contains(t.shared));
    try std.testing.expectEqual(@as(usize, 0), t.pins());
    // The stale reader finds the pack gone and reads the head again: the
    // kept file is restored from the copy, the purged one is left out.
    const done = try restoreRequest(&t.reader, t.snapshot, null, t.target.dir, .Bulk);
    try std.testing.expectEqual(@as(usize, 2), done.files);
    try std.testing.expectEqual(@as(usize, 1), done.purged_files);
    try expectFile(t.target.dir, "first.txt", "one");
    try expectFile(t.target.dir, "keep.txt", "good");
    try std.testing.expectError(error.FileNotFound, t.target.dir.statFile(io, "private.txt", .{}));
    try std.testing.expectError(error.FileNotFound, t.target.dir.statFile(io, ".nomadfs-restore", .{}));
}

test "offsite: pins are sealed, renewed by every pass, and one that cannot be read protects nothing" {
    const f = try Fixture.create();
    defer f.destroy();
    _ = try f.add("private.txt", "secret");
    const kept = try f.add("keep.txt", "good");
    _ = try f.run();
    const at = try f.service.locate(kept);
    const pack = try f.packKey(kept);
    const job = [_]u8{0xab} ** 16;
    try f.service.pin(job, &.{at.pack_id});
    const name = "swarm/pins/" ++ "ab" ** 16;
    const sealed = f.fake.objects.get(name).?;
    try std.testing.expect(sealed.class == null);
    try std.testing.expect(std.mem.indexOf(u8, sealed.bytes, "expires") == null);
    try f.forget("private.txt");
    _ = try f.run();
    // Renewed on day 10: the pack is still pinned on day 20, gone after day 24.
    f.fake.time += 10 * day;
    try f.service.pin(job, &.{at.pack_id});
    f.fake.time += 10 * day;
    _ = try f.run();
    try std.testing.expect(f.fake.objects.contains(pack));
    // The location recorded before the purge still reads the kept block.
    const bytes = try f.service.readAt(kept, at);
    defer a.free(bytes);
    try std.testing.expectEqualStrings("\x00good", bytes);
    f.fake.time += 5 * day;
    _ = try f.run();
    try std.testing.expect(!f.fake.objects.contains(pack));

    // A pin nobody can open defers nothing, and is deleted once it is old.
    const other = try f.add("other.txt", "more");
    _ = try f.add("doomed.txt", "bytes");
    _ = try f.run();
    const second = try f.packKey(other);
    try f.fake.set("swarm/pins/" ++ "cd" ** 16, "not a pin");
    try f.forget("doomed.txt");
    _ = try f.run();
    f.fake.time += 2 * day;
    _ = try f.run();
    try std.testing.expect(!f.fake.objects.contains(second));
    try std.testing.expect(f.fake.objects.contains("swarm/pins/" ++ "cd" ** 16));
    f.fake.time += core.pin_seconds;
    try f.forget("other.txt");
    _ = try f.run();
    f.fake.time += 2 * day;
    _ = try f.run();
    try std.testing.expect(!f.fake.objects.contains("swarm/pins/" ++ "cd" ** 16));
}

test "offsite: the history keeps a content that came back as a second interval, and a time picks the right one" {
    const f = try Fixture.create();
    defer f.destroy();
    const original = try f.add("a.txt", "original");
    _ = try f.run();
    const first = f.fake.time;
    f.fake.time += day;
    _ = try f.run(); // unchanged: the interval grows
    f.files.clearRetainingCapacity();
    f.fake.time += day;
    _ = try f.add("a.txt", "changed");
    _ = try f.run();
    const changed = f.fake.time;
    f.files.clearRetainingCapacity();
    f.fake.time += day;
    _ = try f.add("a.txt", "original");
    _ = try f.run();
    const reverted = f.fake.time;
    f.fake.time += day;
    _ = try f.run();

    const versions = try f.service.history("a.txt");
    try std.testing.expectEqual(@as(usize, 3), versions.len);
    var stretches: usize = 0;
    for (versions) |v| {
        if (!std.mem.eql(u8, &v.cid, &original)) {
            try std.testing.expect(v.first_seen == changed and v.last_seen == changed);
            continue;
        }
        stretches += 1;
        if (v.first_seen == first) try std.testing.expectEqual(first + day + 1, v.last_seen) else {
            try std.testing.expectEqual(reverted, v.first_seen);
            try std.testing.expectEqual(f.fake.time, v.last_seen);
        }
    }
    try std.testing.expectEqual(@as(usize, 2), stretches);

    const cases = [_]struct { at: u64, expected: []const u8 }{
        .{ .at = first, .expected = "original" },
        .{ .at = changed - 1, .expected = "original" },
        .{ .at = changed, .expected = "changed" },
        .{ .at = reverted - 1, .expected = "changed" },
        .{ .at = reverted, .expected = "original" },
        .{ .at = f.fake.time, .expected = "original" },
    };
    for (cases) |case| {
        var target = std.testing.tmpDir(.{});
        defer target.cleanup();
        _ = try restoreHistory(&f.service, "a.txt", .{ .at = case.at }, target.dir);
        try expectFile(target.dir, "a.txt", case.expected);
    }
    // A file deleted and seen again later also begins a new interval.
    f.files.clearRetainingCapacity();
    _ = try f.add("other.txt", "stays");
    _ = try f.run();
    _ = try f.add("a.txt", "original");
    _ = try f.run();
    try std.testing.expectEqual(@as(usize, 4), (try f.service.history("a.txt")).len);
    try std.testing.expectEqual(@as(usize, 1), (try f.service.history("other.txt")).len);
}

test "offsite: packs uploaded cold are thawed after the target is set to a warm class" {
    const f = try Fixture.createCold();
    defer f.destroy();
    _ = try f.add("a.txt", "good");
    const report = try f.run();
    // Today's class only chooses where new packs go.
    f.service.config.storage_class = .STANDARD;
    var target = std.testing.tmpDir(.{});
    defer target.cleanup();
    const first = try restoreRequest(&f.service, report.snapshot, null, target.dir, .Bulk);
    try std.testing.expectEqual(@as(usize, 0), first.files);
    try std.testing.expectEqual(@as(usize, 1), first.thawing_packs);
    try std.testing.expectEqual(@as(usize, 1), f.fake.restore_requests);
    // A check still goes by listing instead of reading archived packs.
    try std.testing.expect(!(try f.service.check(null, false, .Bulk)).downloaded);
    try std.testing.expectEqual(@as(usize, 1), (try f.service.check(null, true, .Bulk)).thawing_packs);
    f.fake.finishThaws();
    const done = try restoreRequest(&f.service, report.snapshot, null, target.dir, .Bulk);
    try std.testing.expectEqual(@as(usize, 1), done.files);
    try std.testing.expectEqual(@as(usize, 1), f.fake.restore_requests);
    try expectFile(target.dir, "a.txt", "good");
    try std.testing.expectEqual(@as(usize, 1), (try f.service.check(null, true, .Bulk)).blocks);
}

test "offsite: a pack the bucket archived by itself is thawed when its read is refused" {
    const f = try Fixture.create();
    defer f.destroy();
    const moved = try f.add("a.txt", "archived");
    _ = try f.run();
    _ = try f.add("b.txt", "warm");
    const report = try f.run();
    // Uploaded warm and recorded so; a lifecycle rule moved it since.
    f.fake.objects.getPtr(try f.packKey(moved)).?.class = "DEEP_ARCHIVE";
    var target = std.testing.tmpDir(.{});
    defer target.cleanup();
    const first = try restoreRequest(&f.service, report.snapshot, null, target.dir, .Standard);
    try std.testing.expectEqual(@as(usize, 1), first.files);
    try std.testing.expectEqual(@as(usize, 1), first.thawing_packs);
    try std.testing.expect(first.thawing_bytes > 0);
    try std.testing.expectEqual(@as(usize, 1), f.fake.restore_requests);
    try std.testing.expectEqualStrings("Standard", f.fake.last_tier);
    try expectFile(target.dir, "b.txt", "warm");
    // Still thawing: the same refusal asks for nothing new.
    const waiting = try restoreRequest(&f.service, report.snapshot, null, target.dir, .Standard);
    try std.testing.expectEqual(@as(usize, 1), waiting.thawing_packs);
    try std.testing.expectEqual(@as(usize, 1), f.fake.restore_requests);
    f.fake.finishThaws();
    const done = try restoreRequest(&f.service, report.snapshot, null, target.dir, .Standard);
    try std.testing.expectEqual(@as(usize, 2), done.files);
    try std.testing.expectEqual(@as(usize, 0), done.thawing_packs);
    try expectFile(target.dir, "a.txt", "archived");
}

test "offsite: a restore job's plan is checked again: a path out of the destination is refused" {
    const f = try Fixture.createCold();
    defer f.destroy();
    _ = try f.add("a.txt", "good");
    const report = try f.run();
    var target = std.testing.tmpDir(.{});
    defer target.cleanup();
    _ = try restoreRequest(&f.service, report.snapshot, null, target.dir, .Bulk);
    const plan = try target.dir.readFileAlloc(io, ".nomadfs-restore/plan.bin", a, .limited(4096));
    defer a.free(plan);
    const at = std.mem.indexOf(u8, plan, "a.txt").?;
    @memcpy(plan[at..][0..5], "../up");
    try target.dir.writeFile(io, .{ .sub_path = ".nomadfs-restore/plan.bin", .data = plan });
    f.fake.finishThaws();
    try std.testing.expectError(error.InvalidRestoreJob, restoreRequest(&f.service, report.snapshot, null, target.dir, .Bulk));
    try target.dir.writeFile(io, .{ .sub_path = ".nomadfs-restore/plan.bin", .data = plan[0 .. plan.len - 3] });
    try std.testing.expectError(error.InvalidRestoreJob, restoreRequest(&f.service, report.snapshot, null, target.dir, .Bulk));
}

test "offsite: a file retention left in no snapshot is listed in the history and restored from it" {
    const f = try Fixture.create();
    defer f.destroy();
    const short_lived = try f.add("gone.txt", "here for a week");
    _ = try f.add("Notes/doc.txt", "draft");
    const first = try f.run();
    const seen = f.fake.time;
    f.files.clearRetainingCapacity();
    const final = try f.add("Notes/doc.txt", "final text");
    _ = try f.run(); // same month: gone.txt deleted, doc.txt changed
    const changed = f.fake.time;
    f.fake.time += 90 * day;
    _ = try f.run();
    try std.testing.expect(!(try f.names(first.snapshot)));
    // No kept snapshot lists the deleted file.
    for ((try f.service.status()).snapshots) |name| {
        for ((try f.service.snapshot(name)).files) |file| try std.testing.expect(!std.mem.eql(u8, file.path, "gone.txt"));
    }

    // The history still does, with when it was there.
    const all = try f.service.history(null);
    try std.testing.expectEqual(@as(usize, 3), all.len);
    const one = try f.service.history("gone.txt");
    try std.testing.expectEqual(@as(usize, 1), one.len);
    try std.testing.expectEqualSlices(u8, &short_lived, &one[0].cid);
    try std.testing.expectEqual(@as(u64, "here for a week".len), one[0].size);
    try std.testing.expectEqual(seen, one[0].first_seen);
    try std.testing.expectEqual(seen, one[0].last_seen);
    const versions = try f.service.history("Notes");
    try std.testing.expectEqual(@as(usize, 2), versions.len);
    for (versions) |v| {
        if (std.mem.eql(u8, &v.cid, &final)) try std.testing.expect(v.first_seen == changed and v.last_seen == f.fake.time);
    }

    // Restored from the history: the deleted file, and the newest version.
    var target = std.testing.tmpDir(.{});
    defer target.cleanup();
    try std.testing.expectEqual(@as(usize, 2), (try restoreHistory(&f.service, null, .latest, target.dir)).files);
    try expectFile(target.dir, "gone.txt", "here for a week");
    try expectFile(target.dir, "Notes/doc.txt", "final text");
    // An older version by time, and by content id.
    var earlier = std.testing.tmpDir(.{});
    defer earlier.cleanup();
    try std.testing.expectEqual(@as(usize, 1), (try restoreHistory(&f.service, "Notes", .{ .at = seen }, earlier.dir)).files);
    try expectFile(earlier.dir, "Notes/doc.txt", "draft");
    try std.testing.expectEqual(@as(usize, 1), (try restoreHistory(&f.service, "gone.txt", .{ .cid = short_lived }, earlier.dir)).files);
    try expectFile(earlier.dir, "gone.txt", "here for a week");
    try std.testing.expectError(error.PathNotFound, restoreHistory(&f.service, "gone.txt", .{ .at = seen - 10 }, earlier.dir));
    try std.testing.expectError(error.PathNotFound, restoreHistory(&f.service, "never.txt", .latest, earlier.dir));
    try std.testing.expectError(error.InvalidPath, restoreHistory(&f.service, "../up", .latest, earlier.dir));

    // A purge is the only thing that takes a file out of the history.
    try f.forget("gone.txt");
    _ = try f.run();
    try std.testing.expectEqual(@as(usize, 0), (try f.service.history("gone.txt")).len);
}

/// Run by the fake while the first writer's head commit is stalled.
const Rival = struct {
    var fixture: *Fixture = undefined;
    /// The lease runs out; a second uploader applies the purge, commits,
    /// and two days later sweeps what the stalled writer left behind.
    fn takeOver(fake: *Fake) anyerror!void {
        fake.time += 301;
        var second = try fixture.other();
        defer second.deinit();
        _ = try second.run(fixture.source(), &fixture.store);
        fake.time += 2 * day;
        _ = try second.run(fixture.source(), &fixture.store);
    }
    /// Somebody else moved the head between this writer's read and its commit.
    fn moveHead(fake: *Fake) anyerror!void {
        const copy = try a.dupe(u8, fake.objects.get("swarm/head").?.bytes);
        defer a.free(copy);
        try fake.set("swarm/head", copy);
    }
};

test "offsite: a writer stalled past its lease cannot publish after another writer committed and swept its pack" {
    const f = try Fixture.create();
    defer f.destroy();
    _ = try f.add("private.txt", "secret");
    const kept = try f.add("kept.txt", "good");
    _ = try f.run();
    try f.forget("private.txt");
    // The purge copies kept.txt's block into a new pack; the commit naming
    // it stalls after the lease was renewed, so only the head can fence it.
    Rival.fixture = f;
    f.fake.before_key = "/head";
    f.fake.before_put = Rival.takeOver;
    try std.testing.expectError(error.LeaseLost, f.run());
    // The stalled writer's pack is gone and nothing names it: the committed
    // index points at the second writer's pack, and its bytes are there.
    try std.testing.expectEqual(@as(usize, 1), f.packCount());
    var fresh = try f.other();
    defer fresh.deinit();
    try fresh.unlock(null);
    try std.testing.expect(f.fake.objects.contains(try f.packKeyOf(&fresh, kept)));
    const bytes = try fresh.readBlock(kept);
    defer a.free(bytes);
    try std.testing.expectEqualStrings("\x00good", bytes);
    try std.testing.expectEqual(@as(usize, 1), fresh.index.count());
    // The loser starts again from the committed head.
    _ = try f.run();
    try std.testing.expectEqual(@as(usize, 1), try f.service.verify(null));
}

test "offsite: a commit that finds the head moved aborts and leaves the committed generation as it was" {
    const f = try Fixture.create();
    defer f.destroy();
    const first = try f.add("a.txt", "one");
    _ = try f.run();
    const second = try f.add("b.txt", "two");
    f.fake.before_key = "/head";
    f.fake.before_put = Rival.moveHead;
    try std.testing.expectError(error.LeaseLost, f.run());
    var fresh = try f.other();
    defer fresh.deinit();
    try fresh.unlock(null);
    try std.testing.expectEqual(@as(usize, 1), fresh.index.count());
    try std.testing.expectEqual(@as(usize, 1), (try fresh.status()).snapshots.len);
    try std.testing.expectError(error.BlockNotFound, fresh.readBlock(second));
    // The next run uploads again what the lost commit named; its pack is garbage.
    const report = try f.run();
    try std.testing.expectEqual(@as(usize, 1), report.uploaded_blocks);
    try std.testing.expectEqual(@as(usize, 2), try f.service.verify(null));
    try std.testing.expectEqual(@as(usize, 3), f.packCount());
    f.fake.time += day;
    _ = try f.run();
    try std.testing.expectEqual(@as(usize, 2), f.packCount());
    const bytes = try f.service.readBlock(first);
    defer a.free(bytes);
    try std.testing.expectEqualStrings("\x00one", bytes);
}

test "offsite: a purge covers the versions that were there; new content at the same path is backed up" {
    const f = try Fixture.create();
    defer f.destroy();
    const old = try f.add("a.txt", "old");
    _ = try f.run();
    try f.forget("a.txt");
    // The folder still lists the purged version: it is not uploaded again.
    const purged = try f.run();
    try std.testing.expectEqual(@as(usize, 0), purged.uploaded_blocks);
    try std.testing.expectEqual(@as(usize, 0), (try f.service.snapshot(purged.snapshot)).files.len);
    try std.testing.expect(!f.service.index.contains(backup.index.keyedBlockId(f.service.key.?, old)));
    f.files.clearRetainingCapacity();
    const cid = try f.add("a.txt", "new");
    const report = try f.run();
    try std.testing.expectEqual(@as(usize, 1), report.uploaded_blocks);
    try std.testing.expectEqual(@as(usize, 1), (try f.service.snapshot(report.snapshot)).files.len);
    try std.testing.expect(f.service.index.contains(backup.index.keyedBlockId(f.service.key.?, cid)));
    const versions = try f.service.history("a.txt");
    try std.testing.expectEqual(@as(usize, 1), versions.len);
    try std.testing.expectEqualSlices(u8, &cid, &versions[0].cid);
    // The purge is done, and a surviving copy of the old file may come back.
    f.files.clearRetainingCapacity();
    _ = try f.add("a.txt", "old");
    const again = try f.run();
    try std.testing.expectEqual(@as(usize, 1), again.uploaded_blocks);
    try std.testing.expectEqual(@as(usize, 2), (try f.service.history("a.txt")).len);
}

test "offsite: a purge of a directory does not exclude later files under it" {
    const f = try Fixture.create();
    defer f.destroy();
    const old = try f.add("Trip/old.jpg", "old photo");
    _ = try f.add("keep.txt", "keep");
    _ = try f.run();
    // In the folder when the purge is asked for, but not uploaded yet.
    const unsent = try f.add("Trip/unsent.jpg", "never uploaded");
    f.files.items[f.files.items.len - 1].mtime = f.fake.time;
    try f.forget("Trip");
    // Both are still in the folder next to a photo made later, the directory too.
    f.fake.time += 60;
    try f.files.append(f.arena.allocator(), .{ .path = "Trip", .cid = [_]u8{0} ** 32, .size = 0, .blocks = &.{}, .directory = true });
    const new = try f.add("Trip/new.jpg", "new photo");
    f.files.items[f.files.items.len - 1].mtime = f.fake.time;
    const report = try f.run();
    try std.testing.expect(!f.service.index.contains(backup.index.keyedBlockId(f.service.key.?, unsent)));
    try std.testing.expectEqual(@as(usize, 1), report.uploaded_blocks);
    const snap = try f.service.snapshot(report.snapshot);
    try std.testing.expectEqual(@as(usize, 3), snap.files.len);
    for (snap.files) |file| try std.testing.expect(!std.mem.eql(u8, file.path, "Trip/old.jpg"));
    try std.testing.expect(f.service.index.contains(backup.index.keyedBlockId(f.service.key.?, new)));
    try std.testing.expect(!f.service.index.contains(backup.index.keyedBlockId(f.service.key.?, old)));
    try std.testing.expectEqual(@as(usize, 1), (try f.service.history("Trip")).len);
    // A later run still leaves the purged version out and keeps the new one.
    const later = try f.run();
    try std.testing.expectEqual(@as(usize, 0), later.uploaded_blocks);
    try std.testing.expectEqual(@as(usize, 3), (try f.service.snapshot(later.snapshot)).files.len);
    try std.testing.expectEqual(@as(usize, 2), try f.service.verify(later.snapshot));
}

test "offsite: a pack keeps the class and minimum storage time of its upload when the target's class changes" {
    const f = try Fixture.createCold();
    defer f.destroy();
    const cid = try f.add("a.txt", "good");
    _ = try f.run();
    const pack = try f.packKey(cid);
    const born = f.fake.objects.get(pack).?.modified;
    try f.forget("a.txt");
    f.service.config.storage_class = .STANDARD;
    _ = try f.run();
    try std.testing.expect(f.fake.objects.contains(pack));
    const status = try f.service.status();
    try std.testing.expectEqual(@as(usize, 1), status.deferred_packs);
    try std.testing.expectEqual(born + 180 * day, status.deferred_first);
    f.fake.time += 179 * day;
    _ = try f.run();
    try std.testing.expect(f.fake.objects.contains(pack));
    f.fake.time += 2 * day;
    _ = try f.run();
    try std.testing.expect(!f.fake.objects.contains(pack));
    try std.testing.expectEqual(@as(usize, 0), f.fake.restore_requests);
}

const Unfinished = struct {
    fn filesFn(ctx: *anyopaque, _: std.mem.Allocator) !core.Listing {
        const f: *Fixture = @ptrCast(@alignCast(ctx));
        return .{ .files = f.files.items, .waiting = 2 };
    }
};

test "offsite: files waiting for blocks keep the target due after a restart" {
    const f = try Fixture.create();
    defer f.destroy();
    f.service.config.schedule = .monthly;
    _ = try f.add("a.txt", "bytes");
    const report = try f.service.run(.{ .ctx = f, .filesFn = Unfinished.filesFn }, &f.store);
    try std.testing.expectEqual(@as(usize, 2), report.waiting_files);
    // A new process knows nothing but the bucket: the round is still unfinished.
    var restarted = try f.other();
    defer restarted.deinit();
    try std.testing.expect(try restarted.due());
    f.fake.time += 3600;
    try std.testing.expect(try restarted.due());
    // The blocks came: the round finishes and the monthly schedule is back.
    _ = try restarted.run(f.source(), &f.store);
    var again = try f.other();
    defer again.deinit();
    try std.testing.expect(!(try again.due()));
}

test "offsite: a purge covers the versions there when it was asked for, whatever a file's time says" {
    const f = try Fixture.create();
    defer f.destroy();
    const old = try f.add("a.txt", "old");
    _ = try f.run();
    const before = f.fake.time;
    try f.forget("a.txt");
    // Different content arrives at the path afterwards, with a preserved
    // older time (an import): it was not there to be purged.
    f.fake.time += 60;
    f.files.clearRetainingCapacity();
    const new = try f.add("a.txt", "new");
    f.files.items[0].mtime = before - day;
    const report = try f.run();
    try std.testing.expectEqual(@as(usize, 1), (try f.service.snapshot(report.snapshot)).files.len);
    const versions = try f.service.history("a.txt");
    try std.testing.expectEqual(@as(usize, 1), versions.len);
    try std.testing.expectEqualSlices(u8, &new, &versions[0].cid);
    try std.testing.expectError(error.BlockNotFound, f.service.readBlock(old));
    var target = std.testing.tmpDir(.{});
    defer target.cleanup();
    try std.testing.expectEqual(@as(usize, 1), try restore(&f.service, report.snapshot, null, target.dir));
    try expectFile(target.dir, "a.txt", "new");
}

test "offsite: a purge covers a version still waiting for its blocks, and it is never uploaded" {
    const f = try Fixture.create();
    defer f.destroy();
    _ = try f.run();
    // The folder lists the file; its blocks have not reached this device.
    const cid = try f.add("private.txt", "secret");
    const waiting = f.files.pop().?;
    f.absent = &.{.{ .path = "private.txt", .cid = cid }};
    try f.forget("private.txt");
    // The purge is applied while the file still waits.
    const first = try f.run();
    try std.testing.expectEqual(@as(usize, 1), first.waiting_files);
    // The blocks came: the version is uploadable now, and stays out.
    f.absent = &.{};
    try f.files.append(f.arena.allocator(), waiting);
    const second = try f.run();
    try std.testing.expectEqual(@as(usize, 0), second.uploaded_blocks);
    try std.testing.expectEqual(@as(usize, 0), (try f.service.snapshot(second.snapshot)).files.len);
    try std.testing.expectEqual(@as(usize, 0), (try f.service.history("private.txt")).len);
    try std.testing.expectError(error.BlockNotFound, f.service.readBlock(cid));
    // Still out after a restart: the purge lives in the bucket.
    var restarted = try f.other();
    defer restarted.deinit();
    const third = try restarted.run(f.source(), &f.store);
    try std.testing.expectEqual(@as(usize, 0), third.uploaded_blocks);
    // Other content at the path is not the purged version.
    f.files.clearRetainingCapacity();
    _ = try f.add("private.txt", "public now");
    const fourth = try f.run();
    try std.testing.expectEqual(@as(usize, 1), fourth.uploaded_blocks);
    try std.testing.expectEqual(@as(usize, 1), (try f.service.history("private.txt")).len);
}

test "offsite: a setup that stopped after its wraps and before its root starts again" {
    const f = try Fixture.create();
    defer f.destroy();
    _ = try f.add("a.txt", "good");
    f.fake.fail_put_once = "nomadfs-backup.json";
    try std.testing.expectError(error.AccessDenied, f.run());
    try std.testing.expectEqual(@as(usize, 3), f.countUnder("swarm/keys/"));
    try std.testing.expect(!f.fake.objects.contains("swarm/nomadfs-backup.json"));
    // A new process: it makes its own key material and publishes the root.
    var again = try f.other();
    defer again.deinit();
    const report = try again.run(f.source(), &f.store);
    try std.testing.expect(report.recovery_phrase != null);
    // The unfinished setup's objects are gone; the root's are there.
    try std.testing.expectEqual(@as(usize, 3), f.countUnder("swarm/keys/"));
    var stranger = try f.stranger();
    defer stranger.deinit();
    try stranger.unlock(report.recovery_phrase);
    var target = std.testing.tmpDir(.{});
    defer target.cleanup();
    try std.testing.expectEqual(@as(usize, 1), try restore(&stranger, report.snapshot, null, target.dir));
    try expectFile(target.dir, "a.txt", "good");
}

test "offsite: a lost answer to the root's write does not stop the setup, and the words are still shown" {
    const f = try Fixture.create();
    defer f.destroy();
    _ = try f.add("a.txt", "good");
    // The root is stored, its answer is lost, the retry finds it there (412).
    f.fake.lose_put_once = "nomadfs-backup.json";
    // And the run then stops before its first commit.
    f.fake.fail_put_once = "swarm/head";
    try std.testing.expectError(error.AccessDenied, f.run());
    try std.testing.expect(f.fake.objects.contains("swarm/nomadfs-backup.json"));
    const words = try a.dupe(u8, try f.service.recoveryKey());
    defer a.free(words);
    // A new process finds its own root with no run finished: it goes on
    // with the same key and reports the words it made.
    var again = try f.other();
    defer again.deinit();
    const report = try again.run(f.source(), &f.store);
    try std.testing.expectEqualStrings(words, report.recovery_phrase.?);
    try std.testing.expectEqual(@as(usize, 3), f.countUnder("swarm/keys/"));
    var stranger = try f.stranger();
    defer stranger.deinit();
    try stranger.unlock(words);
    try std.testing.expectEqual(@as(usize, 1), try stranger.verify(null));
    // Once a run has finished the words are not repeated.
    const later = try again.run(f.source(), &f.store);
    try std.testing.expect(later.recovery_phrase == null);
}

test "offsite: the lost answer alone: the same run finishes the setup" {
    const f = try Fixture.create();
    defer f.destroy();
    _ = try f.add("a.txt", "good");
    f.fake.lose_put_once = "nomadfs-backup.json";
    const report = try f.run();
    try std.testing.expect(report.recovery_phrase != null);
    var stranger = try f.stranger();
    defer stranger.deinit();
    try stranger.unlock(report.recovery_phrase);
    try std.testing.expectEqual(@as(usize, 1), try stranger.verify(report.snapshot));
}

const OtherDevice = struct {
    /// Another device publishes its root while ours is on the wire.
    fn publish(fake: *Fake) !void {
        try fake.set("swarm/nomadfs-backup.json", "{\"version\":3,\"encrypt\":true,\"key_id\":[1,2,3,4,5,6,7,8],\"setup\":\"00112233445566778899aabbccddeeff\",\"creator\":[" ++ "5," ** 31 ++ "5]}");
    }
};
test "offsite: of two devices setting up one empty bucket the loser stops and leaves no key material" {
    const f = try Fixture.create();
    defer f.destroy();
    _ = try f.add("a.txt", "good");
    f.fake.before_key = "nomadfs-backup.json";
    f.fake.before_put = OtherDevice.publish;
    try std.testing.expectError(error.LeaseLost, f.run());
    try std.testing.expectEqual(@as(usize, 0), f.countUnder("swarm/keys/"));
    try std.testing.expectEqual(@as(usize, 0), f.countUnder("swarm/packs/"));
}

test "offsite: a versioned bucket is refused before anything is written; a store without versioning is accepted" {
    const f = try Fixture.create();
    defer f.destroy();
    _ = try f.add("a.txt", "good");
    for ([_][]const u8{ "Enabled", "Suspended" }) |status| {
        f.fake.versioning = status;
        try std.testing.expectError(error.BucketVersioningEnabled, f.run());
        try std.testing.expectEqual(@as(usize, 0), f.fake.objects.count());
    }
    // R2 answers without a Status; other stores do not know the request.
    f.fake.versioning = null;
    _ = try f.run();
    f.fake.versioning_unsupported = true;
    _ = try f.run();
    // Versioning turned on later stops the next run too.
    f.fake.versioning_unsupported = false;
    f.fake.versioning = "Enabled";
    try std.testing.expectError(error.BucketVersioningEnabled, f.run());
}
