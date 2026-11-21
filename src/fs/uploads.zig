//! Files a front end sends in pieces (the app's page reads picked or
//! dropped files and sends them a piece at a time): each piece waits in
//! `<storage_path>.uploads`, beside the store (not /tmp, which is memory on
//! many desktops), and the whole file goes into the swarm folder at the
//! end. One table per node: the node's lifetime bounds every upload.

const std = @import("std");
const sync = @import("../sync.zig");
const storage = @import("../storage/mod.zig");
const manifest = @import("manifest.zig");
const SwarmFolder = @import("swarm.zig").SwarmFolder;

pub const Uploads = struct {
    /// The bytes of one piece, at most.
    pub const max_chunk_len: u64 = 4 * 1024 * 1024;
    /// Uploads open at once; the oldest goes when a new one needs its slot
    /// (a page that reloaded mid-upload never finishes it).
    pub const max_uploads = 4;

    allocator: std.mem.Allocator,
    io: std.Io,
    folder: *SwarmFolder,
    /// `<storage_path>.uploads`.
    staging: []u8,
    /// Guards `slots`; never held while adding to the folder.
    mutex: sync.Mutex = .{},
    slots: [max_uploads]?Upload = @splat(null),

    const Upload = struct {
        id: u64,
        dir: []u8,
        name: []u8,
        size: u64,
        written: u64 = 0,
        mtime: ?u64,
        part_path: []u8,
    };

    /// Pieces left in the staging dir by a node that stopped mid-upload
    /// are deleted: no upload is open before this one is.
    pub fn create(allocator: std.mem.Allocator, io: std.Io, folder: *SwarmFolder, storage_path: []const u8) !*Uploads {
        const self = try allocator.create(Uploads);
        errdefer allocator.destroy(self);
        // Beside the store, never inside it: "data/" must give "data.uploads".
        const base = std.mem.trimEnd(u8, storage_path, "/\\");
        const staging = try std.fmt.allocPrint(allocator, "{s}.uploads", .{base});
        errdefer allocator.free(staging);
        std.Io.Dir.cwd().deleteTree(io, staging) catch |err|
            std.debug.print("uploads: leftover pieces not deleted: {any}\n", .{err});
        self.* = .{
            .allocator = allocator,
            .io = io,
            .folder = folder,
            .staging = staging,
        };
        return self;
    }

    /// Drops every open upload and its pieces. No call may be running.
    pub fn destroy(self: *Uploads) void {
        for (&self.slots) |*slot| if (slot.*) |up| {
            self.free(up);
            slot.* = null;
        };
        self.allocator.free(self.staging);
        self.allocator.destroy(self);
    }

    /// One count for the whole process, not per table: ids never repeat
    /// across the nodes of one run, so a page's id from an earlier node
    /// finds nothing on this one (a clock could repeat or step back).
    /// Far below 2^53, so a page keeps them exact.
    var next_id: std.atomic.Value(u64) = .init(1);

    fn free(self: *Uploads, up: Upload) void {
        std.Io.Dir.cwd().deleteFile(self.io, up.part_path) catch {};
        self.allocator.free(up.dir);
        self.allocator.free(up.name);
        self.allocator.free(up.part_path);
    }

    /// A new upload of `size` bytes for `dir/name` ("" = the top) with
    /// the file's own modified time (Unix seconds); its id, for its pieces.
    /// Refused while the folder waits for its first pull: an upload that
    /// can't finish isn't begun.
    pub fn begin(self: *Uploads, dir: []const u8, name: []const u8, size: u64, mtime: ?u64) !u64 {
        if (!storage.dag.codec.isValidName(name)) return error.InvalidName;
        if (!validPath(dir, name)) return error.InvalidPath;
        if (!self.folder.editReady()) return error.NotSynced;
        try std.Io.Dir.cwd().createDirPath(self.io, self.staging);

        self.mutex.lock();
        defer self.mutex.unlock();
        var slot: usize = 0;
        for (self.slots, 0..) |s, i| {
            const up = s orelse {
                slot = i;
                break;
            };
            if (up.id < self.slots[slot].?.id) slot = i;
        } else if (self.slots[slot]) |oldest| {
            self.free(oldest);
            self.slots[slot] = null;
        }

        const id = next_id.fetchAdd(1, .monotonic);
        const part_path = try std.fmt.allocPrint(self.allocator, "{s}/{d}.part", .{ self.staging, id });
        errdefer self.allocator.free(part_path);
        {
            var file = try std.Io.Dir.cwd().createFile(self.io, part_path, .{ .truncate = true });
            file.close(self.io);
        }
        errdefer std.Io.Dir.cwd().deleteFile(self.io, part_path) catch {};
        const dir_copy = try self.allocator.dupe(u8, dir);
        errdefer self.allocator.free(dir_copy);
        const name_copy = try self.allocator.dupe(u8, name);
        self.slots[slot] = .{
            .id = id,
            .dir = dir_copy,
            .name = name_copy,
            .size = size,
            .mtime = mtime,
            .part_path = part_path,
        };
        return id;
    }

    /// The piece at `offset`. Pieces come in order; one already written is
    /// ignored (a retry), any other offset is error.BadOffset. The write
    /// holds the table's lock: the page sends one piece at a time, so only
    /// another upload's call waits, for one 4 MiB write at most.
    pub fn chunk(self: *Uploads, id: u64, offset: u64, bytes: []const u8) !void {
        if (bytes.len > max_chunk_len) return error.InvalidArgument;
        self.mutex.lock();
        defer self.mutex.unlock();
        const up = self.find(id) orelse return error.UploadNotFound;
        if (try chunkStep(up.written, up.size, offset, bytes.len) == .skip) return;
        var file = try std.Io.Dir.cwd().openFile(self.io, up.part_path, .{ .mode = .write_only });
        defer file.close(self.io);
        try file.writePositionalAll(self.io, bytes, up.written);
        up.written += bytes.len;
    }

    /// Every piece is in: the file goes into the swarm folder (replacing
    /// what has its path, as Add does). Its name, owned by `allocator`.
    /// After an error finishing again can pass (`finishCanRetry`) the
    /// upload stays for another finish; after any other it is gone.
    pub fn finish(self: *Uploads, allocator: std.mem.Allocator, id: u64) ![]const u8 {
        // Out of the table while the folder adds it: that takes a while,
        // and other uploads go on meanwhile.
        const up = blk: {
            self.mutex.lock();
            defer self.mutex.unlock();
            for (&self.slots) |*slot| if (slot.*) |found| if (found.id == id) {
                slot.* = null;
                break :blk found;
            };
            return error.UploadNotFound;
        };
        if (up.written != up.size) {
            self.free(up);
            return error.UploadIncomplete;
        }
        const name = allocator.dupe(u8, up.name) catch |err| {
            self.putBack(up);
            return err;
        };
        errdefer allocator.free(name);
        self.folder.addFileAt(up.dir, up.name, up.part_path, up.mtime) catch |err| {
            if (finishCanRetry(err)) self.putBack(up) else self.free(up);
            return err;
        };
        self.free(up);
        return name;
    }

    /// Drops upload `id` and its pieces (none: nothing to do).
    pub fn cancel(self: *Uploads, id: u64) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        for (&self.slots) |*slot| if (slot.*) |found| if (found.id == id) {
            self.free(found);
            slot.* = null;
        };
    }

    /// Back in the table for another finish; freed when every slot is
    /// taken by uploads begun since.
    fn putBack(self: *Uploads, up: Upload) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        for (&self.slots) |*slot| if (slot.* == null) {
            slot.* = up;
            return;
        };
        self.free(up);
    }

    /// Caller holds `mutex`.
    fn find(self: *Uploads, id: u64) ?*Upload {
        for (&self.slots) |*slot| if (slot.*) |*up| if (up.id == id) return up;
        return null;
    }
};

/// Errors after which finishing the same upload again can pass.
pub fn finishCanRetry(err: anyerror) bool {
    return switch (err) {
        error.NotSynced, error.OutOfMemory, error.NoSpaceLeft, error.StorageFull => true,
        else => false,
    };
}

const ChunkStep = enum { skip, write };

/// What a piece at `offset` of `len` bytes does to an upload with
/// `written` of `size` bytes in: a retry of a piece we have is skipped,
/// any offset but the next is error.BadOffset. No sum can overflow.
fn chunkStep(written: u64, size: u64, offset: u64, len: u64) !ChunkStep {
    if (offset <= written and len <= written - offset) return .skip;
    if (offset != written) return error.BadOffset;
    if (len > size - written) return error.InvalidArgument;
    return .write;
}

/// Whether `dir/name` ("" = top) is a path the swarm folder takes.
fn validPath(dir: []const u8, name: []const u8) bool {
    var buf: [manifest.max_path_len]u8 = undefined;
    const path = if (dir.len == 0) name else std.fmt.bufPrint(&buf, "{s}/{s}", .{ dir, name }) catch return false;
    return manifest.validPath(path);
}

test "chunkStep: next piece, retry, bad and overflow-sized offsets" {
    try std.testing.expectEqual(ChunkStep.write, try chunkStep(0, 10, 0, 4));
    try std.testing.expectEqual(ChunkStep.skip, try chunkStep(8, 10, 4, 4));
    try std.testing.expectEqual(ChunkStep.skip, try chunkStep(8, 10, 0, 0));
    try std.testing.expectEqual(ChunkStep.write, try chunkStep(8, 10, 8, 2));
    try std.testing.expectError(error.BadOffset, chunkStep(8, 10, 9, 1));
    try std.testing.expectError(error.BadOffset, chunkStep(8, 10, 6, 4));
    try std.testing.expectError(error.InvalidArgument, chunkStep(8, 10, 8, 3));
    const max = std.math.maxInt(u64);
    try std.testing.expectError(error.BadOffset, chunkStep(8, 10, max, 4));
    try std.testing.expectError(error.BadOffset, chunkStep(8, 10, max - 1, max));
    try std.testing.expectError(error.InvalidArgument, chunkStep(0, 10, 0, max));
}

test "validPath: top, nested, too deep, bad parts" {
    try std.testing.expect(validPath("", "a.jpg"));
    try std.testing.expect(validPath("x/y", "a.jpg"));
    try std.testing.expect(!validPath("x//y", "a.jpg"));
    try std.testing.expect(!validPath("/x", "a.jpg"));
    try std.testing.expect(!validPath("", ""));
    var deep: [2 * manifest.max_depth]u8 = undefined;
    for (0..manifest.max_depth) |i| {
        deep[2 * i] = 'd';
        deep[2 * i + 1] = '/';
    }
    try std.testing.expect(!validPath(deep[0 .. deep.len - 1], "a.jpg"));
}

test "uploads: ids never repeat across tables (nodes) of one process" {
    var t: TestFolder = undefined;
    try t.open(0x58, "Desk");
    defer t.close();
    const a = try testUploads(&t);
    const first = try a.begin("", "a.txt", 1, null);
    a.destroy();
    const b = try testUploads(&t);
    defer b.destroy();
    const second = try b.begin("", "a.txt", 1, null);
    try std.testing.expect(second > first);
    try std.testing.expectError(error.UploadNotFound, b.chunk(first, 0, "x"));
}

const TestFolder = @import("test_fixture.zig").Fixture(SwarmFolder);

/// A table over a fixture's folder, staging beside its store (`<dir>/blocks`).
fn testUploads(t: *TestFolder) !*Uploads {
    const store_path = try std.fs.path.join(std.testing.allocator, &.{ t.dir, "blocks" });
    defer std.testing.allocator.free(store_path);
    return Uploads.create(std.testing.allocator, std.testing.io, t.folder, store_path);
}

fn partExists(u: *Uploads, id: u64) bool {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = std.fmt.bufPrint(&buf, "{s}/{d}.part", .{ u.staging, id }) catch return false;
    _ = std.Io.Dir.cwd().statFile(std.testing.io, path, .{}) catch return false;
    return true;
}

test "uploads: pieces in order, a retried piece, a bad offset, then into the folder" {
    var t: TestFolder = undefined;
    try t.open(0x51, "Desk");
    defer t.close();
    const u = try testUploads(&t);
    defer u.destroy();

    try std.testing.expectError(error.InvalidPath, u.begin("x//y", "a.jpg", 1, null));
    try std.testing.expectError(error.InvalidName, u.begin("", "a/b", 1, null));
    const id = try u.begin("Camera", "a.jpg", 6, 1_500_000_000);
    try u.chunk(id, 0, "abc");
    try u.chunk(id, 0, "abc"); // a retry: skipped
    try std.testing.expectError(error.BadOffset, u.chunk(id, 4, "ef"));
    try std.testing.expectError(error.InvalidArgument, u.chunk(id, 3, "defg"));
    try std.testing.expectError(error.UploadNotFound, u.chunk(id + 1, 0, "x"));
    try u.chunk(id, 3, "def");

    const name = try u.finish(std.testing.allocator, id);
    defer std.testing.allocator.free(name);
    try std.testing.expectEqualStrings("a.jpg", name);
    const info = t.folder.fileInfo("Camera/a.jpg").?;
    try std.testing.expectEqual(@as(u64, 6), info.size);
    try std.testing.expectEqual(@as(u64, 1_500_000_000), info.mtime);
    try std.testing.expect(!partExists(u, id));
    try std.testing.expectError(error.UploadNotFound, u.finish(std.testing.allocator, id));
}

test "uploads: an incomplete finish drops it, cancel deletes its pieces" {
    var t: TestFolder = undefined;
    try t.open(0x52, "Desk");
    defer t.close();
    const u = try testUploads(&t);
    defer u.destroy();

    const short = try u.begin("", "a.jpg", 4, null);
    try u.chunk(short, 0, "ab");
    try std.testing.expectError(error.UploadIncomplete, u.finish(std.testing.allocator, short));
    try std.testing.expectError(error.UploadNotFound, u.chunk(short, 2, "cd"));
    try std.testing.expect(!partExists(u, short));

    const gone = try u.begin("", "b.jpg", 4, null);
    try std.testing.expect(partExists(u, gone));
    u.cancel(gone);
    u.cancel(gone); // twice: nothing left to do
    try std.testing.expect(!partExists(u, gone));
    try std.testing.expectError(error.UploadNotFound, u.finish(std.testing.allocator, gone));
}

test "uploads: a new one past the limit evicts the oldest and its pieces" {
    var t: TestFolder = undefined;
    try t.open(0x53, "Desk");
    defer t.close();
    const u = try testUploads(&t);
    defer u.destroy();

    var ids: [Uploads.max_uploads]u64 = undefined;
    for (&ids) |*id| id.* = try u.begin("", "a.jpg", 1, null);
    const newest = try u.begin("", "b.jpg", 1, null);
    try std.testing.expect(!partExists(u, ids[0]));
    try std.testing.expectError(error.UploadNotFound, u.chunk(ids[0], 0, "x"));
    for (ids[1..]) |id| try u.chunk(id, 0, "x");
    try u.chunk(newest, 0, "x");
}

test "uploads: not begun while the folder waits for its first pull; a finish refused then passes later" {
    var t: TestFolder = undefined;
    try t.open(0x54, "Desk");
    defer t.close();
    const u = try testUploads(&t);
    defer u.destroy();

    const id = try u.begin("", "a.jpg", 2, null);
    try u.chunk(id, 0, "ab");
    // The folder starts waiting for a pull (no placement: it keeps waiting).
    t.folder.awaiting_pull = true;
    t.folder.awaiting_since_ms = sync.monotonicMillis();
    try std.testing.expectError(error.NotSynced, u.begin("", "b.jpg", 1, null));
    try std.testing.expectError(error.NotSynced, u.finish(std.testing.allocator, id));
    try std.testing.expect(partExists(u, id));
    try std.testing.expectError(error.NotSynced, u.finish(std.testing.allocator, id));
    t.folder.awaiting_pull = false;
    const name = try u.finish(std.testing.allocator, id);
    defer std.testing.allocator.free(name);
    try std.testing.expect(t.folder.fileInfo("a.jpg") != null);
    try std.testing.expect(!partExists(u, id));
}

test "uploads: a refused finish that can't pass again drops the upload" {
    var t: TestFolder = undefined;
    try t.open(0x55, "Desk");
    defer t.close();
    const u = try testUploads(&t);
    defer u.destroy();

    _ = try t.folder.putBytes("Taken/x.txt", "x", null);
    const id = try u.begin("", "Taken", 1, null);
    try u.chunk(id, 0, "y");
    try std.testing.expectError(error.IsDirectory, u.finish(std.testing.allocator, id));
    try std.testing.expect(!partExists(u, id));
    try std.testing.expectError(error.UploadNotFound, u.finish(std.testing.allocator, id));
}

test "uploads: destroy deletes open pieces, create clears what a stopped node left" {
    var t: TestFolder = undefined;
    try t.open(0x56, "Desk");
    defer t.close();

    var part: [std.fs.max_path_bytes]u8 = undefined;
    var part_len: usize = 0;
    {
        const u = try testUploads(&t);
        defer u.destroy();
        const id = try u.begin("", "a.jpg", 4, null);
        try u.chunk(id, 0, "ab");
        part_len = (try std.fmt.bufPrint(&part, "{s}/{d}.part", .{ u.staging, id })).len;
    }
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().statFile(std.testing.io, part[0..part_len], .{}));

    // A piece left behind (the node was killed): the next table clears it.
    try t.tmp.dir.createDirPath(std.testing.io, "blocks.uploads");
    try t.tmp.dir.writeFile(std.testing.io, .{ .sub_path = "blocks.uploads/7.part", .data = "left" });
    const u = try testUploads(&t);
    defer u.destroy();
    try std.testing.expectError(error.FileNotFound, t.tmp.dir.statFile(std.testing.io, "blocks.uploads/7.part", .{}));
}

test "uploads: a store path ending in a slash stages beside the store, not in it" {
    var t: TestFolder = undefined;
    try t.open(0x57, "Desk");
    defer t.close();
    const store_path = try std.fmt.allocPrint(std.testing.allocator, "{s}/blocks/", .{t.dir});
    defer std.testing.allocator.free(store_path);
    const u = try Uploads.create(std.testing.allocator, std.testing.io, t.folder, store_path);
    defer u.destroy();
    try std.testing.expect(std.mem.endsWith(u8, u.staging, "/blocks.uploads"));
}
