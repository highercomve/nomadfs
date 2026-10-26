//! C ABI surface for mobile bindings and other FFI clients.
//!
//! Rules of the surface:
//! - every export returns a `c_int` status (0 = ok) or a nullable handle /
//!   string; Zig panics never cross the boundary;
//! - strings are NUL-terminated, UTF-8-safe bytes owned by the caller on the
//!   way in (freewheeling with `nomadfs_free` on the way out);
//! - the handle returned by `nomadfs_node_new` must be released exactly once
//!   with `nomadfs_node_free`; `nomadfs_free` releases returned strings;
//! - calls on one handle are serialized internally, so it is safe to call
//!   from different threads, but each call blocks the others;
//! - config paths, file paths and CID strings follow the CLI semantics.

const std = @import("std");
const builtin = @import("builtin");
const nomadfs = @import("../root.zig");
const sync = nomadfs.sync;

pub const version_string = "0.1.0";

/// Status codes. Documented in the header this module shapes; unknown
/// failures collapse to `internal_error`.
pub const nomadfs_ok: c_int = 0;
const invalid_argument: c_int = 1;
const storage_disabled: c_int = 2;
const unavailable: c_int = 3;
const file_too_large: c_int = 4;
const not_found: c_int = 5;
const internal_error: c_int = 9;

fn mapError(err: anyerror) c_int {
    return switch (err) {
        error.StorageDisabled => storage_disabled,
        error.FileTooLarge => file_too_large,
        error.NoProvider,
        error.ProviderUnreachable,
        error.ConnectionRefused,
        error.ConnectionResetByPeer,
        error.NetworkUnreachable,
        error.NoBlockFound,
        error.QuorumNotReached,
        error.StoreFailed,
        => unavailable,
        error.FileNotFound,
        error.BlockNotFound,
        => not_found,
        else => internal_error,
    };
}

const allocator: std.mem.Allocator = if (builtin.link_libc)
    std.heap.c_allocator
else
    std.heap.smp_allocator;

/// Wraps a Node so FFI callers cannot misuse it: one mutex per handle,
/// explicit lifetime, and no Zig API types in exported signatures.
pub const NodeHandle = struct {
    mutex: sync.Mutex = .{},
    node: nomadfs.Node,
    config: nomadfs.config.Config,
    /// Owned copies of the bootstrap URLs the running bootstrap thread may
    /// still be reading. Freed after `node.deinit()` joins that thread.
    urls: []const []const u8 = &.{},
    running: *std.atomic.Value(bool),
    run_thread: ?std.Thread = null,
};

fn spanSlice(p: ?[*:0]const u8) ?[]const u8 {
    if (p) |ptr| return std.mem.span(ptr);
    return null;
}

const version: [*:0]const u8 = version_string;

export fn nomadfs_version() [*:0]const u8 {
    return version;
}

fn nodeNewInternal(config_value: nomadfs.config.Config) !*NodeHandle {
    var config = config_value;
    errdefer config.deinit(allocator);
    var node = try nomadfs.Node.init(allocator, config);
    errdefer node.deinit();
    const running = try allocator.create(std.atomic.Value(bool));
    errdefer allocator.destroy(running);
    running.* = std.atomic.Value(bool).init(false);
    const self = try allocator.create(NodeHandle);
    self.* = .{ .node = node, .config = config, .running = running };
    return self;
}

export fn nomadfs_node_new(config_path: ?[*:0]const u8) ?*NodeHandle {
    const path = spanSlice(config_path) orelse return null;
    const config = nomadfs.config.parseConfig(allocator, path) catch return null;
    return nodeNewInternal(config) catch null;
}

export fn nomadfs_node_free(node: ?*NodeHandle) void {
    const self = node orelse return;
    self.running.store(false, .release);
    // Node.run() exits within one poll interval once the flag drops.
    if (self.run_thread) |t| t.join();
    self.node.deinit();
    self.config.deinit(allocator);
    for (self.urls) |url| allocator.free(url);
    if (self.urls.len > 0) allocator.free(self.urls);
    allocator.destroy(self.running);
    allocator.destroy(self);
}

fn runNodeThread(self: *NodeHandle) void {
    self.node.run(self.running, self.config) catch |err| {
        std.debug.print("mobile node stopped: {any}\n", .{err});
    };
    self.running.store(false, .release);
}

/// Starts the listener under a dedicated thread. Non-blocking.
export fn nomadfs_node_run(node: ?*NodeHandle) c_int {
    const self = node orelse return invalid_argument;
    self.mutex.lock();
    defer self.mutex.unlock();
    if (self.run_thread != null) return nomadfs_ok;

    self.running.store(true, .release);
    self.run_thread = std.Thread.spawn(.{}, runNodeThread, .{self}) catch {
        self.running.store(false, .release);
        return internal_error;
    };
    return nomadfs_ok;
}

/// Connects to a comma-separated list of bootstrap peers in the background.
export fn nomadfs_node_bootstrap(node: ?*NodeHandle, urls_csv: ?[*:0]const u8) c_int {
    const self = node orelse return invalid_argument;
    const csv = spanSlice(urls_csv) orelse return invalid_argument;

    self.mutex.lock();
    defer self.mutex.unlock();

    var list: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, csv, ',');
    while (it.next()) |piece| {
        if (piece.len == 0) continue;
        const dup = allocator.dupe(u8, piece) catch {
            freeUrlList(&list);
            return internal_error;
        };
        list.append(allocator, dup) catch {
            allocator.free(dup);
            freeUrlList(&list);
            return internal_error;
        };
    }

    // Own the slice BEFORE spawning: the bootstrap thread reads it at its
    // own pace, so it must not point at a buffer we might still resize.
    const owned = list.toOwnedSlice(allocator) catch {
        freeUrlList(&list);
        return internal_error;
    };
    // The previous thread joined first inside bootstrap(), so the urls it
    // reads are safe to release afterwards.
    self.node.bootstrap(owned, self.config.node.swarm_key) catch {
        freeUrls(owned);
        return internal_error;
    };
    for (self.urls) |url| allocator.free(url);
    if (self.urls.len > 0) allocator.free(self.urls);
    self.urls = owned;
    return nomadfs_ok;
}

/// Frees a url list owned by nothing else; used on failure paths.
fn freeUrlList(list: *std.ArrayList([]const u8)) void {
    for (list.items) |item| allocator.free(item);
    list.deinit(allocator);
}

fn freeUrls(urls: []const []const u8) void {
    for (urls) |url| allocator.free(url);
    if (urls.len > 0) allocator.free(urls);
}

export fn nomadfs_node_stop(node: ?*NodeHandle) c_int {
    const self = node orelse return invalid_argument;
    self.mutex.lock();
    defer self.mutex.unlock();
    self.running.store(false, .release);
    if (self.run_thread) |t| {
        t.join();
        self.run_thread = null;
    }
    return nomadfs_ok;
}

/// Reads `in_path`, chunks it into the local DAG and returns the root CID
/// as a hex string (callers free it with `nomadfs_free`). The write fails
/// (NULL) when the provider record cannot reach the write quorum, which is
/// also what happens while offline; the blocks are kept locally either way
/// and a retry after connecting announces them.
export fn nomadfs_put_file(node: ?*NodeHandle, in_path: ?[*:0]const u8) ?[*:0]u8 {
    const self = node orelse return null;
    const path = spanSlice(in_path) orelse return null;

    self.mutex.lock();
    defer self.mutex.unlock();

    const io = std.Io.Threaded.global_single_threaded.io();
    var file = std.Io.Dir.cwd().openFile(io, path, .{}) catch return null;
    defer file.close(io);

    var reader = FileReader{ .io = io, .file = file };
    const root = self.node.block_manager.put(&reader) catch |err| {
        std.debug.print("put failed: {any}\n", .{err});
        return null;
    };
    defer allocator.free(root);
    return hexCid(root[0..32].*) catch null;
}

/// Writes the file rooted at the hex CID to `out_path`. Creates or
/// truncates the output file.
export fn nomadfs_get_file(node: ?*NodeHandle, cid: ?[*:0]const u8, out_path: ?[*:0]const u8) c_int {
    const self = node orelse return invalid_argument;
    const cid_text = spanSlice(cid) orelse return invalid_argument;
    const path = spanSlice(out_path) orelse return invalid_argument;

    self.mutex.lock();
    defer self.mutex.unlock();

    var root: [32]u8 = undefined;
    _ = std.fmt.hexToBytes(&root, cid_text) catch return invalid_argument;

    const io = std.Io.Threaded.global_single_threaded.io();
    var file = std.Io.Dir.cwd().createFile(io, path, .{}) catch return internal_error;
    defer file.close(io);

    var writer = FileWriter{ .io = io, .file = file };
    _ = self.node.block_manager.get(&root, &writer, .{}) catch |err| {
        std.debug.print("get failed: {any}\n", .{err});
        _ = std.Io.Dir.cwd().deleteFile(io, path) catch {};
        return mapError(err);
    };
    return nomadfs_ok;
}

/// Writes the node's own device ID as a 64 hex-character string into `out`
/// (`out` must hold at least 65 bytes).
export fn nomadfs_node_device_id(node: ?*NodeHandle, out: ?[*]u8, out_len: usize) c_int {
    const self = node orelse return invalid_argument;
    const buf = out orelse return invalid_argument;
    if (out_len < 65) return invalid_argument;

    self.mutex.lock();
    defer self.mutex.unlock();
    const hex = std.fmt.bytesToHex(self.node.device_identity.deviceId().bytes, .lower);
    @memcpy(buf[0..64], &hex);
    buf[64] = 0;
    return nomadfs_ok;
}

/// Releases a string returned by this API.
export fn nomadfs_free(ptr: ?*anyopaque) void {
    const p = ptr orelse return;
    const s: [*:0]u8 = @ptrCast(@alignCast(p));
    allocator.free(std.mem.span(s));
}

fn hexCid(cid: [32]u8) ![*:0]u8 {
    const out = try allocator.allocSentinel(u8, 64, 0);
    errdefer allocator.free(out);
    const hex = std.fmt.bytesToHex(cid, .lower);
    @memcpy(out[0..64], &hex);
    return out;
}

const FileReader = struct {
    io: std.Io,
    file: std.Io.File,
    offset: u64 = 0,

    pub fn read(self: *FileReader, dest: []u8) std.Io.File.ReadPositionalError!usize {
        if (dest.len == 0) return 0;
        const n = try self.file.readPositional(self.io, &.{dest}, self.offset);
        self.offset += n;
        return n;
    }
};

const FileWriter = struct {
    io: std.Io,
    file: std.Io.File,
    offset: u64 = 0,

    pub fn writeAll(self: *FileWriter, bytes: []const u8) std.Io.File.WritePositionalError!void {
        try self.file.writePositionalAll(self.io, bytes, self.offset);
        self.offset += bytes.len;
    }
};

const testing = std.testing;

/// Writes a minimal config pointing both nodes at isolated dirs/ports.
fn writeConfig(path: []const u8, nickname: []const u8, port: u16, data_dir: []const u8, key_dir: []const u8) !void {
    const io = std.Io.Threaded.global_single_threaded.io();
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try out.writer.print(
        \\[node]
        \\nickname = "{s}"
        \\swarm_key = "4090e76685f6f17bbe398fd4b2f12945168aaaa64107b7e57fe72dffa2c9436e"
        \\key_path = "{s}/node.key"
        \\
        \\[storage]
        \\enabled = true
        \\storage_path = "{s}"
        \\
        \\[network]
        \\port = {d}
        \\transport = "tcp"
        \\bootstrap_peers = []
        \\upnp_enabled = false
        \\enable_mdns = false
        \\
    , .{ nickname, key_dir, data_dir, port });
    var file = try std.Io.Dir.cwd().createFile(io, path, .{});
    defer file.close(io);
    try file.writePositionalAll(io, out.written(), 0);
}

fn cleanupFiles(io: std.Io, paths: []const []const u8) void {
    for (paths) |p| std.Io.Dir.cwd().deleteFile(io, p) catch {};
}

test "mobile: two nodes put and retrieve a file through the C ABI" {
    const io = std.Io.Threaded.global_single_threaded.io();
    const dirs = [_][]const u8{ "test_mobile_a", "test_mobile_b" };
    for (dirs) |d| std.Io.Dir.cwd().deleteTree(io, d) catch {};
    defer for (dirs) |d| std.Io.Dir.cwd().deleteTree(io, d) catch {};

    try std.Io.Dir.cwd().createDirPath(io, dirs[0]);
    try std.Io.Dir.cwd().createDirPath(io, dirs[1]);
    const cfg_paths = [_][]const u8{ "test_mobile_a.conf", "test_mobile_b.conf" };
    defer cleanupFiles(io, &cfg_paths);
    try writeConfig(cfg_paths[0], "a", 13200, "test_mobile_a/data", "test_mobile_a");
    try writeConfig(cfg_paths[1], "b", 13201, "test_mobile_b/data", "test_mobile_b");

    const node_a = nomadfs_node_new("test_mobile_a.conf".ptr);
    try testing.expect(node_a != null);
    const node_b = nomadfs_node_new("test_mobile_b.conf".ptr);
    try testing.expect(node_b != null);
    defer {
        nomadfs_node_free(node_a);
        nomadfs_node_free(node_b);
    }

    try testing.expectEqual(nomadfs_ok, nomadfs_node_run(node_a));
    try testing.expectEqual(nomadfs_ok, nomadfs_node_run(node_b));
    try testing.expectEqual(nomadfs_ok, nomadfs_node_bootstrap(node_b, "tcp://127.0.0.1:13200,127.0.0.1:13201".ptr));
    nomadfs.sync.sleep(300 * std.time.ns_per_ms);

    // Put a file on node B and read it back from node A.
    const in_bytes = "c-abi payload " ** 2000;
    {
        var file = try std.Io.Dir.cwd().createFile(io, "test_mobile_payload.bin", .{});
        defer file.close(io);
        try file.writePositionalAll(io, in_bytes, 0);
    }
    defer cleanupFiles(io, &.{"test_mobile_payload.bin"});

    const cid = nomadfs_put_file(node_b, "test_mobile_payload.bin".ptr);
    try testing.expect(cid != null);
    defer nomadfs_free(@ptrCast(@alignCast(cid.?)));

    try testing.expectEqual(nomadfs_ok, nomadfs_get_file(node_a, cid, "test_mobile_out.bin".ptr));
    defer cleanupFiles(io, &.{"test_mobile_out.bin"});

    var out_file = try std.Io.Dir.cwd().openFile(io, "test_mobile_out.bin", .{});
    defer out_file.close(io);
    const out = try testing.allocator.alloc(u8, in_bytes.len);
    defer testing.allocator.free(out);
    _ = try out_file.readPositionalAll(io, out, 0);
    try testing.expectEqualSlices(u8, in_bytes, out);

    // A malformed CID is refused, and a bogus path yields null.
    try testing.expectEqual(invalid_argument, nomadfs_get_file(node_a, "zzz", "test_mobile_out.bin".ptr));
    try testing.expect(nomadfs_put_file(node_b, "/definitely/not/here.queries".ptr) == null);

    // Device IDs are printable hex.
    var device_id: [65]u8 = undefined;
    try testing.expectEqual(nomadfs_ok, nomadfs_node_device_id(node_a, &device_id, device_id.len));
    for (device_id[0..64]) |c| try testing.expect(std.ascii.isHex(c));
    try testing.expectEqual(@as(u8, 0), device_id[64]);

    try testing.expectEqual(nomadfs_ok, nomadfs_node_stop(node_b));
    try testing.expectEqual(nomadfs_ok, nomadfs_node_stop(node_a));
}
