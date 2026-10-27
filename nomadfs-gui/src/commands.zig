//! NomadFS commands for the Oriel page.
//!
//! One global node handle backs every command: the desktop app runs at
//! most one node per process, with the same lifecycle the CLI exposes.
//! The heavy lifting lives in the core (`nomadfs` module); the C ABI
//! surface in `src/mobile/api.zig` is reused verbatim on Linux by marking
//! its exports `pub`, so the GUI, the mobile bindings and the CLI all
//! exercise the same runner.

const std = @import("std");
const builtin = @import("builtin");
const nomadfs = @import("nomadfs");

const mobile = nomadfs.mobile_api;
const Ticket = nomadfs.device.pairing.Ticket;
const TrustStore = nomadfs.device.trust.Store;
const Identity = nomadfs.device.identity.Identity;
const DevicePaths = nomadfs.device.paths.Paths;
const config_mod = nomadfs.config;
const NodeID = nomadfs.net.id.NodeID;

/// Matches HOME's `.nomadfs`, like the CLI's default lookup.
pub const default_config_subpath = ".nomadfs/nomadfs.conf";

/// Bounded text payloads; the core stores files, not unbounded strings.
pub const max_text_len: usize = 8 * 1024 * 1024;

var g_node: ?*mobile.NodeHandle = null;
var g_mutex: nomadfs.sync.Mutex = .{};
var g_tick: u64 = 0;

pub const NodeOpenArgs = struct { config_path: []const u8 };
pub const DeviceEntry = struct {
    fingerprint: []const u8,
    label: []const u8,
    added_at: u64,
};
pub var failed_running: bool = false;

pub fn dropFailed() void {
    failed_running = false;
}

pub fn isRunning() bool {
    g_mutex.lock();
    defer g_mutex.unlock();
    return g_node != null;
}

fn setFailed(value: bool) void {
    failed_running = value;
}

/// `invoke("node_open", { config_path })`: opens and starts listening.
pub fn nodeOpen(gpa: std.mem.Allocator, args: NodeOpenArgs) !void {
    g_mutex.lock();
    defer g_mutex.unlock();
    if (g_node != null) return;

    const path = try gpa.dupeZ(u8, args.config_path);
    defer gpa.free(path);

    const node = mobile.nomadfs_node_new(path.ptr) orelse return error.ConfigInvalid;
    if (mobile.nomadfs_node_run(node) != 0) {
        mobile.nomadfs_node_free(node);
        return error.NodeFailedToStart;
    }
    g_node = node;
}

/// `invoke("node_close")`.
pub fn nodeClose() void {
    g_mutex.lock();
    defer g_mutex.unlock();
    if (g_node) |node| {
        mobile.nomadfs_node_free(node);
        g_node = null;
    }
    setFailed(false);
}

fn requireRunning() *mobile.NodeHandle {
    if (g_node) |handle| return handle;
    return error.NotRunning;
}

/// Callers already hold `g_mutex`; this must not lock again.
fn nextTickPath(buf: []u8, comptime suffix: []const u8) ![:0]u8 {
    g_tick += 1;
    return std.fmt.bufPrintZ(buf, "/tmp/nomadfs-gui-{d}{s}", .{ g_tick, suffix });
}

/// The absolute CLI-shaped default: `$HOME/.nomadfs/nomadfs.conf`.
pub fn defaultConfigPath(gpa: std.mem.Allocator) ![]const u8 {
    const home_env = if (builtin.os.tag == .windows) "USERPROFILE" else "HOME";
    const home = nomadfs.env.getEnv(gpa, home_env) orelse return error.HomeNotFound;
    defer gpa.free(home);
    return std.fs.path.join(gpa, &.{ home, ".nomadfs", "nomadfs.conf" });
}

/// `invoke("node_state")`.
pub fn nodeState(gpa: std.mem.Allocator) !NodeStateResult {
    g_mutex.lock();
    defer g_mutex.unlock();
    var device_id: []const u8 = "";
    if (g_node) |node| {
        var buf: [65]u8 = undefined;
        if (mobile.nomadfs_node_device_id(node, &buf, buf.len) == 0) {
            device_id = try gpa.dupe(u8, buf[0..64]);
        }
    }
    return .{ .running = g_node != null, .device_id = device_id };
}

pub const ConfigResult = struct { path: []const u8, created: bool };

pub const PairTicketResult = struct { uri: []const u8, fingerprint: []const u8, nickname: []const u8 };
pub const NodeStateResult = struct { running: bool, device_id: []const u8 };
pub const PutTextArgs = struct { text: []const u8 };
pub const GetTextArgs = struct { cid: []const u8 };
pub const TrustDeviceArgs = struct { config_path: []const u8, uri: []const u8 };
pub const RevokeDeviceArgs = struct { config_path: []const u8, query: []const u8 };

/// Writes a CLI-shaped config the first time, returns the path and whether
/// the file was newly created. The swarm key is random, like `--pair`'s
/// transport key; it lands in the user's own configuration file.
pub fn ensureConfig(gpa: std.mem.Allocator) !ConfigResult {
    const path = try defaultConfigPath(gpa);
    {
        const io = std.Io.Threaded.global_single_threaded.io();
        _ = std.Io.Dir.cwd().statFile(io, path, .{}) catch {
            var swarm: [64]u8 = undefined;
            var prng = std.Random.DefaultPrng.init(nomadfs.nowSeconds() * 7919);
            var rnd: [32]u8 = undefined;
            prng.random().bytes(&rnd);
            const swarm_key = std.fmt.bufPrint(&swarm, "{s}", .{std.fmt.bytesToHex(rnd, .lower)}) catch unreachable;
            try std.Io.Dir.cwd().createDirPath(io, std.fs.path.dirname(path) orelse "/");
            var file = try std.Io.Dir.cwd().createFile(io, path, .{});
            defer file.close(io);
            var text: std.Io.Writer.Allocating = .init(gpa);
            defer text.deinit();
            try text.writer.print("\n[node]\nnickname = \"gui\"\nswarm_key = \"{s}\"\n" ++
                "\n[storage]\nenabled = true\nstorage_path = \"~/.nomadfs/data\"\n" ++
                "\n[network]\nport = 14700\ntransport = \"tcp\"\nupnp_enabled = false\n" ++
                "enable_mdns = false\nreplicas = 1\n", .{swarm_key});
            try file.writePositionalAll(io, text.written(), 0);
            return .{ .path = path, .created = true };
        };
    }
    return .{ .path = path, .created = false };
}

/// `invoke("put_text", { text })`: stores the text and returns its CID.
pub fn putText(gpa: std.mem.Allocator, args: PutTextArgs) ![]const u8 {
    if (args.text.len == 0 or args.text.len > max_text_len) return error.InvalidArgument;

    g_mutex.lock();
    defer g_mutex.unlock();
    const node = g_node orelse return error.NotRunning;

    const io = std.Io.Threaded.global_single_threaded.io();
    var buf: [64]u8 = undefined;
    const tmp_path = try nextTickPath(&buf, ".bin");
    defer std.Io.Dir.cwd().deleteFile(io, tmp_path) catch {};
    {
        var file = try std.Io.Dir.cwd().createFile(io, tmp_path, .{ .truncate = true });
        defer file.close(io);
        try file.writePositionalAll(io, args.text, 0);
    }

    const cid_ptr = mobile.nomadfs_put_file(node, tmp_path.ptr) orelse return error.PutFailed;
    defer mobile.nomadfs_free(cid_ptr);
    const cid = std.mem.span(cid_ptr);
    return gpa.dupe(u8, cid[0..64]);
}

/// `invoke("get_text", { cid })`: reassembles the file and returns text.
pub fn getText(gpa: std.mem.Allocator, args: GetTextArgs) ![]const u8 {
    if (args.cid.len != 64) return error.InvalidArgument;

    g_mutex.lock();
    defer g_mutex.unlock();
    const node = g_node orelse return error.NotRunning;

    const io = std.Io.Threaded.global_single_threaded.io();
    var buf: [64]u8 = undefined;
    const out_path = try nextTickPath(&buf, "-out.bin");
    defer std.Io.Dir.cwd().deleteFile(io, out_path) catch {};

    const cid_z = try gpa.dupeZ(u8, args.cid);
    defer gpa.free(cid_z);
    if (mobile.nomadfs_get_file(node, cid_z.ptr, out_path.ptr) != 0) return error.GetFailed;

    var file = try std.Io.Dir.cwd().openFile(io, out_path, .{});
    defer file.close(io);
    const size = (try file.stat(io)).size;
    if (size > max_text_len) return error.FileTooLarge;
    const body = try gpa.alloc(u8, @intCast(size));
    _ = try file.readPositionalAll(io, body, 0);
    return body;
}

/// `invoke("pair_ticket", { config_path, address })`: prints the ticket URL
/// the CLI's --pair would print (no QR in a webview; the page can render
/// it from the URI).
pub fn pairTicket(gpa: std.mem.Allocator, args: struct { config_path: []const u8, address: []const u8 }) !PairTicketResult {
    var config = config_mod.parseConfig(gpa, args.config_path) catch return error.ConfigInvalid;
    defer config.deinit(gpa);

    var paths = try DevicePaths.resolve(gpa, config.node.key_path);
    defer paths.deinit(gpa);

    const identity = try Identity.loadOrCreate(paths.identity);
    const transport = try nomadfs.net.transport.manager.ConnectionManager.loadOrCreateKey(gpa, config.node.key_path);

    const addr = if (args.address.len > 0)
        try gpa.dupe(u8, args.address)
    else
        try std.fmt.allocPrint(gpa, "127.0.0.1:{d}", .{config.network.port});

    const seconds = nomadfs.nowSeconds();
    const ticket = try Ticket.init(identity, transport.public_key, config.node.nickname, addr, seconds + ticketLifetime());
    var uri_buf: [nomadfs.device.pairing.max_uri_len]u8 = undefined;
    const uri = try ticket.toUri(&uri_buf);

    var fingerprint_buf: [19]u8 = undefined;
    const fingerprint = Identity.formatFingerprint(identity.fingerprint(), &fingerprint_buf);

    const nickname = try gpa.dupe(u8, config.node.nickname);
    return .{
        .uri = try gpa.dupe(u8, uri),
        .fingerprint = try gpa.dupe(u8, fingerprint),
        .nickname = nickname,
    };
}

fn ticketLifetime() u64 {
    // Same expiry window the CLI is pairs with.
    return 24 * 60 * 60;
}

/// `invoke("devices_list", { config_path })`: trusted devices.
pub fn devicesList(gpa: std.mem.Allocator, args: struct { config_path: []const u8 }) ![]DeviceEntry {
    var config = config_mod.parseConfig(gpa, args.config_path) catch return error.ConfigInvalid;
    defer config.deinit(gpa);

    var paths = try DevicePaths.resolve(gpa, config.node.key_path);
    defer paths.deinit(gpa);

    const identity = try Identity.loadOrCreate(paths.identity);
    var store = try TrustStore.load(gpa, paths.trust, identity.seed());
    defer store.deinit();

    const entries = try gpa.alloc(DeviceEntry, store.list().len);
    for (entries, store.list()) |*out, entry| {
        var fingerprint_buf: [19]u8 = undefined;
        const fingerprint = Identity.formatFingerprint(entry.fingerprint(), &fingerprint_buf);
        out.* = .{
            .fingerprint = try gpa.dupe(u8, fingerprint),
            .label = try gpa.dupe(u8, entry.labelSlice()),
            .added_at = entry.added_at,
        };
    }
    return entries;
}

/// `invoke("trust_device", { config_path, uri })`.
pub fn trustDevice(gpa: std.mem.Allocator, args: TrustDeviceArgs) !void {
    var config = config_mod.parseConfig(gpa, args.config_path) catch return error.ConfigInvalid;
    defer config.deinit(gpa);

    var paths = try DevicePaths.resolve(gpa, config.node.key_path);
    defer paths.deinit(gpa);

    const identity = try Identity.loadOrCreate(paths.identity);
    var store = try TrustStore.load(gpa, paths.trust, identity.seed());
    defer store.deinit();

    const now = nomadfs.nowSeconds();
    const ticket = Ticket.parseAt(args.uri, now) catch return error.TicketRejected;
    _ = try store.trustTicket(ticket, now);
    try store.save();
}

/// `invoke("revoke_device", { config_path, query })`.
pub fn revokeDevice(gpa: std.mem.Allocator, args: RevokeDeviceArgs) !void {
    var config = config_mod.parseConfig(gpa, args.config_path) catch return error.ConfigInvalid;
    defer config.deinit(gpa);

    var paths = try DevicePaths.resolve(gpa, config.node.key_path);
    defer paths.deinit(gpa);

    const identity = try Identity.loadOrCreate(paths.identity);
    var store = try TrustStore.load(gpa, paths.trust, identity.seed());
    defer store.deinit();

    const id = try store.resolve(args.query) orelse return error.DeviceNotFound;
    _ = try store.revokeDevice(id, identity.deviceId(), @intCast(nomadfs.nowSeconds()));
    try store.save();
}

const testing = std.testing;

test "commands: node put/get text round trip" {
    // Keep the prebuilt fixture from /tmp/nomadfs-gui-test if present, so
    // repeated runs do not re-pair; the conf carries `write_quorum = 0`.
    const io = std.Io.Threaded.global_single_threaded.io();
    const dir = "/tmp/nomadfs-gui-test";
    std.Io.Dir.cwd().deleteTree(io, dir) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};
    try std.Io.Dir.cwd().createDirPath(io, dir);
    try std.Io.Dir.cwd().createDirPath(io, dir ++ "/keys");
    try std.Io.Dir.cwd().createDirPath(io, dir ++ "/data");

    var conf_buf: [512]u8 = undefined;
    const conf_path = try std.fmt.bufPrint(&conf_buf, "{s}/nomadfs.conf", .{dir});
    // Copy the canonical fixture (written on the host once, matching
    // nothing: enough for the round trip: it never leaves this box).
    var fixture: [640]u8 = undefined;
    var fixture_file = std.Io.Dir.cwd().openFile(io, "/tmp/opencode/gui-test-fixture", .{}) catch |err| {
        std.debug.print("fixture missing: {any}\n", .{err});
        return err;
    };
    defer fixture_file.close(io);
    const read_fix = try fixture_file.readPositionalAll(io, &fixture, 0);
    var file = try std.Io.Dir.cwd().createFile(io, conf_path, .{ .truncate = true });
    defer file.close(io);
    try file.writePositionalAll(io, fixture[0..read_fix], 0);

    var gpa = try testing.allocator.create(std.heap.DebugAllocator(.{}));
    defer testing.allocator.destroy(gpa);
    gpa.* = .{ .backing_allocator = std.heap.page_allocator };
    defer std.testing.expect(gpa.deinit() == .ok) catch {};
    const alloc = gpa.allocator();

    try nodeOpen(alloc, .{ .config_path = conf_path });
    try testing.expect(isRunning());
    defer nodeClose();

    // Listener settle so the DHT's ping path doesn't race teardown.
    nomadfs.sync.sleep(200 * std.time.ns_per_ms);

    const text = "NomadFS GUI smoke: hello world!\r\n";
    const cid = try putText(alloc, .{ .text = text });
    defer alloc.free(cid);
    try testing.expectEqual(@as(usize, 64), cid.len);

    const fetched = try getText(alloc, .{ .cid = cid });
    defer alloc.free(fetched);
    try testing.expectEqualStrings(text, fetched);
}
