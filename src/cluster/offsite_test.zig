const std = @import("std");
const core = @import("offsite.zig");
const s3 = @import("../net/s3/mod.zig");
const backup = @import("../backup/mod.zig");
const storage = @import("../storage/mod.zig");
const a = std.testing.allocator;
const io = std.testing.io;
const Cid = [32]u8;
const Thaw = enum { none, ongoing, ready };
const Object = struct { bytes: []u8, version: u64, modified: u64 = 0, class: ?[]const u8 = null, thaw: Thaw = .none };
fn isCold(class: ?[]const u8) bool {
    const text = class orelse return false;
    return std.mem.eql(u8, text, "GLACIER") or std.mem.eql(u8, text, "DEEP_ARCHIVE");
}
const Fake = struct {
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
    fn deinit(self: *Fake) void {
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
    fn transport(self: *Fake) s3.Transport {
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
        var etag_buf: [32]u8 = undefined;
        const existing = self.objects.get(key);
        const old_etag = try std.fmt.bufPrint(&etag_buf, "\"{d}\"", .{if (existing) |o| o.version else 0});
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
        const location = f.service.index.get(backup.index.keyedBlockId(f.service.key.?, cid)).?;
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
        return .{ .files = f.files.items };
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
};

test "offsite: first run creates layout and wraps; repeated run deduplicates; new file adds only new blocks" {
    const f = try Fixture.create();
    defer f.destroy();
    _ = try f.add("Photos/a.jpg", "photo bytes");
    const first = try f.run();
    try std.testing.expectEqual(@as(usize, 1), first.uploaded_blocks);
    try std.testing.expect(first.recovery_phrase != null);
    try std.testing.expect(f.fake.objects.contains("swarm/nomadfs-backup.json"));
    try std.testing.expect(f.fake.objects.contains("swarm/keys/recovery.wrap"));
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
    try std.testing.expectEqual(@as(usize, 2), try f.service.restore(io, report.snapshot, null, target.dir));
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
    try std.testing.expectEqual(@as(usize, 1), try other.restore(io, report.snapshot, "Photos", recovered.dir));
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
    try f.service.forget("private.txt");
    try f.service.forget("shared-a.txt");
    _ = try f.run();
    try std.testing.expect(!f.fake.objects.contains(old_pack));
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
    try f.service.forget("remove.txt");
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
    try std.testing.expectError(error.Locked, f.service.forget("a.txt"));
    _ = try f.add("a.txt", "clear text");
    const report = try f.run();
    try f.service.forget("a.txt");
    var it = f.fake.objects.iterator();
    while (it.next()) |e| {
        if (std.mem.startsWith(u8, e.key_ptr.*, "swarm/purges/") or std.mem.eql(u8, e.key_ptr.*, "swarm/keys/recovery-entropy")) {
            try std.testing.expectEqual(backup.pack.Mode.encrypted, (try backup.pack.Header.decode(e.value_ptr.bytes)).mode);
        }
    }
    var target = std.testing.tmpDir(.{});
    defer target.cleanup();
    try std.testing.expectEqual(@as(usize, 1), try f.service.restore(io, report.snapshot, null, target.dir));
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
    const result = f.service.restore(io, report.snapshot, null, target.dir);
    if (result) |_| return error.TestExpectedError else |_| {}
    try target.dir.deleteFile(io, "Photos");
    _ = try f.service.restore(io, report.snapshot, null, target.dir);
    try std.testing.expectError(error.PathAlreadyExists, f.service.restore(io, report.snapshot, null, target.dir));
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
    try std.testing.expectEqual(@as(usize, 2), try f.service.restore(io, report.snapshot, null, target.dir));
    const bytes = try target.dir.readFileAlloc(io, "keep.txt", a, .limited(100));
    defer a.free(bytes);
    try std.testing.expectEqualStrings("sharedretainedshared", bytes);
    try f.service.forget("remove.txt");
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
    try std.testing.expectEqual(@as(usize, 1), try f.service.restore(io, report.snapshot, null, target.dir));
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
    const old_snapshot_key = try std.fmt.allocPrint(a, "swarm/{s}", .{first.snapshot});
    defer a.free(old_snapshot_key);
    try std.testing.expect(!f.fake.objects.contains(old_snapshot_key));
    try f.service.forget("purge.txt");
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

const day = 86400;

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
    try f.service.forget("nothing.txt");
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
    const first_key = try std.fmt.allocPrint(f.arena.allocator(), "swarm/{s}", .{first.snapshot});
    try std.testing.expect(!f.fake.objects.contains(first_key));
    // An unreferenced pack (an upload cut before its index segment) and a
    // purge that makes every run sweep: the young orphan must stay.
    const orphan = "swarm/packs/000102030405060708090a0b0c0d0e0f";
    try f.fake.set(orphan, "orphan pack bytes");
    f.fake.objects.getPtr(orphan).?.class = "DEEP_ARCHIVE";
    try f.service.forget("never-there.txt");
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
    try f.service.forget("private.txt");
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
    const first = try f.service.restoreRequest(io, report.snapshot, null, target.dir, .Standard);
    try std.testing.expectEqual(@as(usize, 0), first.files);
    try std.testing.expectEqual(@as(usize, 1), first.thawing_packs);
    try std.testing.expect(first.thawing_bytes > 0);
    try std.testing.expectEqual(@as(usize, 1), f.fake.restore_requests);
    try std.testing.expectEqualStrings("Standard", f.fake.last_tier);
    try std.testing.expectError(error.FileNotFound, target.dir.statFile(io, "Notes/b.txt", .{}));
    // The pending job is on disk: a new session (a restart) picks it up.
    const job = try target.dir.readFileAlloc(io, ".nomadfs-restore.json", a, .limited(4096));
    defer a.free(job);
    try std.testing.expect(std.mem.indexOf(u8, job, report.snapshot) != null);
    var other = try core.Service.init(a, &f.client, f.service.config, f.service.device);
    defer other.deinit();
    other.clock_ctx = &f.fake;
    other.clockFn = Fake.clock;
    try other.unlock(null);
    // Still thawing: no second request, nothing written.
    const waiting = try other.restoreRequest(io, report.snapshot, null, target.dir, .Standard);
    try std.testing.expectEqual(@as(usize, 0), waiting.files);
    try std.testing.expectEqual(@as(usize, 1), waiting.thawing_packs);
    try std.testing.expectEqual(@as(usize, 1), f.fake.restore_requests);
    // A different request must not reuse this directory's job.
    try std.testing.expectError(error.RestoreJobMismatch, other.restoreRequest(io, report.snapshot, "Photos", target.dir, .Standard));
    f.fake.finishThaws();
    const done = try other.restoreRequest(io, report.snapshot, null, target.dir, .Standard);
    try std.testing.expectEqual(@as(usize, 2), done.files);
    try std.testing.expectEqual(@as(usize, 0), done.thawing_packs);
    try std.testing.expectEqual(@as(usize, 1), f.fake.restore_requests);
    const bytes = try target.dir.readFileAlloc(io, "Notes/b.txt", a, .limited(100));
    defer a.free(bytes);
    try std.testing.expectEqualStrings("notes bytes\n", bytes);
    const photo = try target.dir.readFileAlloc(io, "Photos/a.jpg", a, .limited(100));
    defer a.free(photo);
    try std.testing.expectEqualStrings("photo bytes", photo);
    try std.testing.expectError(error.FileNotFound, target.dir.statFile(io, ".nomadfs-restore.json", .{}));
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
    const first = try f.service.restoreRequest(io, report.snapshot, null, target.dir, .Bulk);
    try std.testing.expectEqual(@as(usize, 1), first.files);
    try std.testing.expectEqual(@as(usize, 1), first.thawing_packs);
    f.fake.finishThaws();
    const done = try f.service.restoreRequest(io, report.snapshot, null, target.dir, .Bulk);
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
    try std.testing.expectEqual(@as(usize, 2), try f.service.restore(io, second.snapshot, null, target.dir));
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
    const w = try worker_mod.Worker.create(a, &.{ warm, cold, glacier }, identity, undefined, .{ .folder = undefined, .store = undefined });
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
    const lone = try worker_mod.Worker.create(a, &.{warm}, identity, undefined, .{ .folder = undefined, .store = undefined });
    defer lone.destroy();
    lone.setRoles(.{ .swarm_backup = true, .deep_backup = true });
    try std.testing.expect(lone.archiveMissing());
    try std.testing.expect(lone.archiveStatus() == null);
    try std.testing.expectEqualStrings("no archive target configured", worker_mod.no_archive);
}
