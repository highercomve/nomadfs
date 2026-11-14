const std = @import("std");
const core = @import("offsite.zig");
const s3 = @import("../net/s3/mod.zig");
const backup = @import("../backup/mod.zig");
const storage = @import("../storage/mod.zig");
const a = std.testing.allocator;
const io = std.testing.io;
const Cid = [32]u8;
const Object = struct { bytes: []u8, version: u64 };
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
        slot.value_ptr.* = .{ .bytes = owned_bytes, .version = self.version };
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
                try xml.writer.print("<Contents><Key>{s}</Key><Size>{d}</Size><ETag>&quot;{d}&quot;</ETag></Contents>", .{ e.key_ptr.*, e.value_ptr.bytes.len, e.value_ptr.version });
            }
            try xml.writer.writeAll("</ListBucketResult>");
            return s3.Response.init(allocator, 200, &.{}, xml.written());
        }
        if (request.method == .POST) {
            if (std.mem.startsWith(u8, query, "uploads=")) {
                self.multipart.clearRetainingCapacity();
                self.multipart_calls += 1;
                return s3.Response.init(allocator, 200, &.{}, "<InitiateMultipartUploadResult><UploadId>test</UploadId></InitiateMultipartUploadResult>");
            }
            try self.set(key, self.multipart.items);
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
    fn destroy(f: *Fixture) void {
        f.service.deinit();
        f.store.deinit();
        f.fake.deinit();
        f.arena.deinit();
        f.tmp.cleanup();
        a.destroy(f);
    }
    fn filesFn(ctx: *anyopaque, _: std.mem.Allocator) ![]const core.File {
        const f: *Fixture = @ptrCast(@alignCast(ctx));
        return f.files.items;
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
