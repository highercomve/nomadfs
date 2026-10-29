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
/// Resolved once; staging files go here instead of /tmp (which does not
/// exist on Android).
var g_tmp_dir: ?[]const u8 = null;
/// Staging dir for the tmp file `nomadfs_put_file` reads: /tmp on
/// desktop, the Oriel-provided cache dir on Android. Callers already
/// hold `g_mutex`.
fn initTmpDir() void {
    if (g_tmp_dir != null) return;
    if (builtin.abi.isAndroid() and g_android_data_dir != null) {
        g_tmp_dir = std.fmt.allocPrint(std.heap.page_allocator, "{s}/cache\x00", .{g_android_data_dir.?}) catch null;
        if (g_tmp_dir) |d| g_tmp_dir = d[0 .. d.len - 1 :0];
        if (g_tmp_dir) |dir| {
            const io = std.Io.Threaded.global_single_threaded.io();
            std.Io.Dir.cwd().createDirPath(io, dir) catch {};
        }
    } else {
        g_tmp_dir = std.heap.page_allocator.dupeZ(u8, "/tmp") catch null;
    }
}
var g_mutex: nomadfs.sync.Mutex = .{};
/// Serialises every read-modify-write of the config file (editConfig and
/// ensureConfig). Lock order: g_mutex first, then this one. Nothing takes
/// g_mutex while holding it.
var g_config_mutex: nomadfs.sync.Mutex = .{};
var g_tick: u64 = 0;

/// Owner-only, like `device.key` and `trust.store`: the config holds the
/// swarm key, and the directory holds the keys. Windows keeps its defaults.
const private_file_perms: std.Io.File.Permissions = if (builtin.os.tag == .windows) .default_file else @enumFromInt(0o600);
const private_dir_perms: std.Io.File.Permissions = if (builtin.os.tag == .windows) .default_file else @enumFromInt(0o700);

pub const NodeOpenArgs = struct { config_path: []const u8 };
pub const DeviceEntry = struct {
    fingerprint: []const u8,
    label: []const u8,
    added_at: u64,
};

pub fn isRunning() bool {
    g_mutex.lock();
    defer g_mutex.unlock();
    return g_node != null;
}

/// `invoke("node_open", { config_path })`: opens and starts listening.
pub fn nodeOpen(gpa: std.mem.Allocator, args: NodeOpenArgs) !void {
    g_mutex.lock();
    defer g_mutex.unlock();
    if (g_node != null) return;

    const path = try gpa.dupeZ(u8, args.config_path);
    defer gpa.free(path);

    const node = mobile.nomadfs_node_new(path.ptr) orelse return error.ConfigInvalid;
    // A trusted device may rotate the swarm key: adopt it (see onRotation).
    rememberConfigPath(args.config_path);
    node.node.discovery_node.rotation_sink = .{ .ctx = &g_rotation, .applyFn = onRotation };
    if (mobile.nomadfs_node_run(node) != 0) {
        mobile.nomadfs_node_free(node);
        return error.NodeFailedToStart;
    }
    g_node = node;

    // Reach the devices this one joined (config bootstrap_peers), and keep
    // finding devices: the same thread re-dials remembered ones and looks
    // for new ones, so it runs even with no bootstrap peers.
    const csv = try std.mem.joinZ(gpa, ",", node.config.network.bootstrap_peers);
    defer gpa.free(csv);
    _ = mobile.nomadfs_node_bootstrap(node, csv.ptr);
}

/// `invoke("node_close")`.
/// Media reads in progress (media.zig). They read through the node without
/// holding g_mutex, so a slow fetch doesn't stall every other command;
/// nodeClose waits for them before freeing the node.
var g_media_users: std.atomic.Value(u32) = .init(0);

/// The running node for one media read, or null; pair with mediaRelease.
pub fn mediaAcquire() ?*mobile.NodeHandle {
    g_mutex.lock();
    defer g_mutex.unlock();
    const handle = g_node orelse return null;
    _ = g_media_users.fetchAdd(1, .acq_rel);
    return handle;
}

pub fn mediaRelease() void {
    _ = g_media_users.fetchSub(1, .acq_rel);
}

pub fn nodeClose() void {
    g_mutex.lock();
    defer g_mutex.unlock();
    stopMountLocked(); // the mount reads through this node
    // No new media reads can start (they need g_mutex); let current ones end.
    while (g_media_users.load(.acquire) > 0) nomadfs.sync.sleep(10 * std.time.ns_per_ms);
    if (g_node) |node| {
        mobile.nomadfs_node_free(node);
        g_node = null;
    }
}

/// Callers already hold `g_mutex`; this must not lock again.
fn nextTickPath(buf: []u8, comptime suffix: []const u8) ![:0]u8 {
    initTmpDir();
    const base = g_tmp_dir orelse return error.NoTempDir;
    g_tick += 1;
    return std.fmt.bufPrintZ(buf, "{s}/nomadfs-gui-{d}{s}", .{ base, g_tick, suffix });
}

/// The absolute CLI-shaped default: `$HOME/.nomadfs/nomadfs.conf`.
/// Where per-device files live: `$HOME` on desktop (same layout the CLI
/// uses), the Oriel app data dir on Android (no HOME env there).
/// Set by the app shell (main.zig) at startup on Android, where there is
/// no $HOME: Oriel hands over the app's private data dir.
var g_android_data_dir: ?[]const u8 = null;

/// The host data dir Oriel provides; caller keeps it for the process
/// lifetime (it leaks one allocation by design).
pub fn initAndroidDataDir(dir: []const u8) void {
    if (g_android_data_dir == null) {
        g_android_data_dir = std.heap.page_allocator.dupe(u8, dir) catch null;
    }
}

pub fn dataDir(gpa: std.mem.Allocator) ![]const u8 {
    if (builtin.abi.isAndroid() and g_android_data_dir != null)
        return gpa.dupe(u8, g_android_data_dir.?);
    const home_env = if (builtin.os.tag == .windows) "USERPROFILE" else "HOME";
    const home = nomadfs.env.getEnv(gpa, home_env) orelse return error.HomeNotFound;
    defer gpa.free(home);
    return std.fs.path.join(gpa, &.{ home, ".nomadfs" });
}

pub fn defaultConfigPath(gpa: std.mem.Allocator) ![]const u8 {
    const dir = try dataDir(gpa);
    defer gpa.free(dir);
    return std.fs.path.join(gpa, &.{ dir, "nomadfs.conf" });
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
pub const ListArgs = struct { config_path: []const u8 };
pub const PairTicketArgs = struct { config_path: []const u8, address: []const u8 };
pub const RevokeDeviceArgs = struct { config_path: []const u8, query: []const u8 };

/// Writes a CLI-shaped config the first time, returns the path and whether
/// the file was newly created. The swarm key is random, like `--pair`'s
/// transport key; it lands in the user's own configuration file.
pub fn ensureConfig(gpa: std.mem.Allocator) !ConfigResult {
    const path = try defaultConfigPath(gpa);
    const io = std.Io.Threaded.global_single_threaded.io();
    const dir = try dataDir(gpa);
    defer gpa.free(dir);

    g_config_mutex.lock();
    defer g_config_mutex.unlock();
    _ = std.Io.Dir.cwd().statFile(io, path, .{}) catch {
        try createConfig(gpa, io, dir, path);
        return .{ .path = path, .created = true };
    };
    // A config written before owner-only modes existed holds the swarm key
    // world-readable: tighten it and its directory.
    var file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    try file.setPermissions(io, private_file_perms);
    if (std.Io.Dir.cwd().openDir(io, dir, .{})) |d_val| {
        var d = d_val;
        defer d.close(io);
        d.setPermissions(io, private_dir_perms) catch {};
    } else |_| {}
    return .{ .path = path, .created = false };
}

/// Writes a new config with a random swarm key, in `dir` (created owner-only
/// with its keys subdirectory). Caller holds g_config_mutex.
fn createConfig(gpa: std.mem.Allocator, io: std.Io, dir: []const u8, path: []const u8) !void {
    const keys_path = try std.fs.path.join(gpa, &.{ dir, "keys", "node.key" });
    defer gpa.free(keys_path);
    const storage_path_abs = try std.fs.path.join(gpa, &.{ dir, "data" });
    defer gpa.free(storage_path_abs);

    var swarm: [64]u8 = undefined;
    defer std.crypto.secureZero(u8, &swarm);
    // The swarm key admits devices to the swarm: from the OS's secure
    // random source, never a seeded PRNG.
    var rnd: [32]u8 = undefined;
    try io.randomSecure(&rnd);
    defer std.crypto.secureZero(u8, &rnd);
    const swarm_key = std.fmt.bufPrint(&swarm, "{s}", .{std.fmt.bytesToHex(rnd, .lower)}) catch unreachable;

    _ = try std.Io.Dir.cwd().createDirPathStatus(io, std.fs.path.dirname(path) orelse "/", private_dir_perms);
    const keys_dir = try std.fs.path.join(gpa, &.{ dir, "keys" });
    defer gpa.free(keys_dir);
    _ = try std.Io.Dir.cwd().createDirPathStatus(io, keys_dir, private_dir_perms);

    var text: std.Io.Writer.Allocating = .init(gpa);
    defer {
        @memset(text.written(), 0);
        text.deinit();
    }
    var nick_buf: [64]u8 = undefined;
    try text.writer.print("\n[node]\nnickname = \"{s}\"\nswarm_key = \"{s}\"\nkey_path = \"{s}\"\n" ++
        "\n[storage]\nenabled = true\nstorage_path = \"{s}\"\n" ++
        "\n[network]\nport = 14700\ntransport = \"tcp\"\nupnp_enabled = false\n" ++
        "enable_mdns = false\nwrite_quorum = 0\nreplicas = 1\n", .{ defaultNickname(&nick_buf), swarm_key, keys_path, storage_path_abs });
    try writeConfigAtomic(gpa, io, path, text.written());
}

/// Replaces the file at `path` with `text`: the text goes to a temp file in
/// the same directory, which is fsynced and then renamed over `path`. A
/// crash or a failed write leaves the old file whole, and the new one is
/// owner-only.
fn writeConfigAtomic(gpa: std.mem.Allocator, io: std.Io, path: []const u8, text: []const u8) !void {
    const tmp_path = try std.fmt.allocPrint(gpa, "{s}.tmp", .{path});
    defer gpa.free(tmp_path);
    const cwd = std.Io.Dir.cwd();
    errdefer cwd.deleteFile(io, tmp_path) catch {};
    {
        var file = try cwd.createFile(io, tmp_path, .{ .truncate = true, .permissions = private_file_perms });
        defer file.close(io);
        // A temp file left by an earlier run keeps its old mode on truncate.
        try file.setPermissions(io, private_file_perms);
        try file.writePositionalAll(io, text, 0);
        try file.sync(io);
    }
    try cwd.rename(tmp_path, cwd, path, io);
}

/// What other devices call this one until it is renamed: the hostname on
/// desktop Linux. Android starts as "gui" and the page renames it after the
/// phone model on first run.
fn defaultNickname(buf: *[64]u8) []const u8 {
    if (builtin.os.tag != .linux or builtin.abi.isAndroid()) return "gui";
    const io = std.Io.Threaded.global_single_threaded.io();
    var file = std.Io.Dir.cwd().openFile(io, "/etc/hostname", .{}) catch return "Desktop";
    defer file.close(io);
    const n = file.readPositionalAll(io, buf, 0) catch return "Desktop";
    const name = std.mem.trim(u8, buf[0..n], " \t\r\n");
    if (name.len == 0 or std.mem.indexOfAny(u8, name, "\"\n") != null) return "Desktop";
    return name;
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

/// Where text drop notes go in the swarm folder: every device lists and
/// syncs them, and swarm backup devices keep a copy.
pub const notes_dir = "Notes";

pub const NoteStored = struct { path: []const u8, name: []const u8, cid: []const u8 };

/// `invoke("note_store", { text })`: saves the text as
/// `Notes/<UTC date and time> <first line>.txt` in the swarm folder and
/// returns where, and its CID (the note's code).
pub fn noteStore(gpa: std.mem.Allocator, args: PutTextArgs) !NoteStored {
    if (args.text.len == 0 or args.text.len > max_text_len) return error.InvalidArgument;
    const io = std.Io.Threaded.global_single_threaded.io();
    const now = std.Io.Timestamp.now(io, .real).nanoseconds;
    const name = try noteName(gpa, args.text, @intCast(@max(0, @divFloor(now, std.time.ns_per_s))));
    errdefer gpa.free(name);

    g_mutex.lock();
    defer g_mutex.unlock();
    const folder = try swarmFolder();

    var buf: [64]u8 = undefined;
    const tmp_path = try nextTickPath(&buf, ".txt");
    defer std.Io.Dir.cwd().deleteFile(io, tmp_path) catch {};
    {
        var file = try std.Io.Dir.cwd().createFile(io, tmp_path, .{ .truncate = true });
        defer file.close(io);
        try file.writePositionalAll(io, args.text, 0);
    }
    try folder.addFile(notes_dir, name, tmp_path);

    const path = try std.fmt.allocPrint(gpa, notes_dir ++ "/{s}", .{name});
    errdefer gpa.free(path);
    const info = folder.fileInfo(path) orelse return error.PutFailed;
    return .{ .path = path, .name = name, .cid = try hexAlloc(gpa, &info.cid) };
}

/// `2026-10-28 17-49-03 Shopping list.txt`: sorts by time, and the first
/// line says what it is. Characters a file name can't hold become spaces.
fn noteName(gpa: std.mem.Allocator, text: []const u8, unix_s: u64) ![]u8 {
    const max_title = 48;
    var lines = std.mem.splitScalar(u8, text, '\n');
    const first = while (lines.next()) |l| {
        const t = std.mem.trim(u8, l, " \t\r");
        if (t.len > 0) break t;
    } else "";
    var title: std.ArrayList(u8) = .empty;
    defer title.deinit(gpa);
    var view = std.unicode.Utf8View.init(first) catch std.unicode.Utf8View.initUnchecked("note");
    var it = view.iterator();
    while (it.nextCodepointSlice()) |cp| {
        if (title.items.len + cp.len > max_title) break;
        const bad = cp.len == 1 and (cp[0] < 0x20 or cp[0] == 0x7f or cp[0] == '/' or cp[0] == '\\');
        try title.appendSlice(gpa, if (bad) " " else cp);
    }
    const trimmed = std.mem.trim(u8, title.items, " .");
    const es = std.time.epoch.EpochSeconds{ .secs = unix_s };
    const day = es.getEpochDay().calculateYearDay();
    const md = day.calculateMonthDay();
    const secs = es.getDaySeconds();
    return std.fmt.allocPrint(gpa, "{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}-{d:0>2}-{d:0>2} {s}.txt", .{
        day.year,                                 md.month.numeric(),        md.day_index + 1,
        secs.getHoursIntoDay(),                   secs.getMinutesIntoHour(), secs.getSecondsIntoMinute(),
        if (trimmed.len > 0) trimmed else "note",
    });
}

test "commands: note names sort by time and start with the first line" {
    const gpa = std.testing.allocator;
    const a = try noteName(gpa, "\n  Shopping list \nmilk\n", 1793210943);
    defer gpa.free(a);
    try std.testing.expectEqualStrings("2026-10-28 18-09-03 Shopping list.txt", a);
    const b = try noteName(gpa, "a/b\\c\x01d", 0);
    defer gpa.free(b);
    try std.testing.expectEqualStrings("1970-01-01 00-00-00 a b c d.txt", b);
    const c = try noteName(gpa, "   \n\t", 0);
    defer gpa.free(c);
    try std.testing.expectEqualStrings("1970-01-01 00-00-00 note.txt", c);
    const d = try noteName(gpa, "ñ" ** 40, 0);
    defer gpa.free(d);
    try std.testing.expect(std.unicode.utf8ValidateSlice(d));
    try std.testing.expect(nomadfs.storage.dag.codec.isValidName(d));
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
pub fn pairTicket(gpa: std.mem.Allocator, args: PairTicketArgs) !PairTicketResult {
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
pub fn devicesList(gpa: std.mem.Allocator, args: ListArgs) ![]DeviceEntry {
    var config = config_mod.parseConfig(gpa, args.config_path) catch return error.ConfigInvalid;
    defer config.deinit(gpa);

    var paths = try DevicePaths.resolve(gpa, config.node.key_path);
    defer paths.deinit(gpa);

    const identity = try Identity.loadOrCreate(paths.identity);
    var store = try TrustStore.load(gpa, paths.trust, identity.seed());
    defer store.deinit();

    g_mutex.lock();
    defer g_mutex.unlock();
    const target: *TrustStore = liveTrustStore(paths.trust) orelse &store;

    // A running node's store changes under revocations from peers: copy it.
    const list = try target.copyEntries(gpa);
    defer gpa.free(list);
    const entries = try gpa.alloc(DeviceEntry, list.len);
    for (entries, list) |*out, entry| {
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

/// The running node's trust store, when the node reads the trust file at
/// `trust_path`; null otherwise. Caller holds g_mutex. The node keeps its
/// own copy in memory and rewrites the file from that copy on its next
/// save, so an edit made to the file behind its back would be lost.
fn liveTrustStore(trust_path: []const u8) ?*TrustStore {
    const handle = g_node orelse return null;
    const live = handle.node.trust_store;
    if (!std.mem.eql(u8, live.path, trust_path)) return null;
    return live;
}

/// `invoke("trust_device", { config_path, uri })`.
pub fn trustDevice(gpa: std.mem.Allocator, args: TrustDeviceArgs) !void {
    var config = config_mod.parseConfig(gpa, args.config_path) catch return error.ConfigInvalid;
    defer config.deinit(gpa);

    var paths = try DevicePaths.resolve(gpa, config.node.key_path);
    defer paths.deinit(gpa);

    const identity = try Identity.loadOrCreate(paths.identity);
    const now = nomadfs.nowSeconds();
    const ticket = Ticket.parseAt(args.uri, now) catch return error.TicketRejected;

    g_mutex.lock();
    defer g_mutex.unlock();
    if (liveTrustStore(paths.trust)) |live| {
        _ = live.trustTicket(ticket, now) catch |err| return staleTicket(err);
        return live.save();
    }
    var store = try TrustStore.load(gpa, paths.trust, identity.seed());
    defer store.deinit();
    _ = store.trustTicket(ticket, now) catch |err| return staleTicket(err);
    try store.save();
}

/// A newer ticket for the device is already pinned: tell the page, which
/// asks for a fresh ticket instead of overwriting the newer pin.
fn staleTicket(err: anyerror) anyerror {
    return if (err == error.StaleTicket) error.TicketStale else err;
}

/// This device's Ed25519 identity, as the ticket emitter uses it.
fn deviceIdentity(gpa: std.mem.Allocator, key_path: ?[]const u8) !Identity {
    var paths = try DevicePaths.resolve(gpa, key_path);
    defer paths.deinit(gpa);
    return Identity.loadOrCreate(paths.identity);
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

    // A running node holds its own copy of the store: revoke there, so it
    // stops trusting the device now (and the file isn't overwritten by an
    // older copy on its next save).
    g_mutex.lock();
    defer g_mutex.unlock();
    const target: *TrustStore = liveTrustStore(paths.trust) orelse &store;

    const id = try target.resolve(args.query) orelse return error.DeviceNotFound;
    _ = try target.revokeDevice(id, identity.deviceId(), @intCast(nomadfs.nowSeconds()));
    try target.save();
    if (g_node) |handle| _ = handle.node.connection_manager.closePeer(id);
}

// ---- Shared folders ----

const fs = nomadfs.fs;

pub const ShareInfo = struct {
    name: []const u8,
    path: []const u8,
    files: u64,
    size: u64,
    /// False until the first scan has something to list; other devices
    /// don't see the share before that.
    ready: bool,
    /// The first scan is still running: other devices see what it has
    /// done so far.
    indexing: bool,
    /// Marked for backup: swarm backup devices keep a copy (fs/backup.zig).
    backup: bool = false,
    /// Why the last scan failed (an error name), until one succeeds.
    scan_error: ?[]const u8 = null,
};

fn shareIndex(handle: *mobile.NodeHandle) !*fs.ShareIndex {
    return handle.node.shares orelse error.StorageDisabled;
}

/// `invoke("shares_local")`: the folders this device shares.
pub fn sharesLocal(gpa: std.mem.Allocator) ![]ShareInfo {
    g_mutex.lock();
    defer g_mutex.unlock();
    const handle = g_node orelse return error.NotRunning;
    const snapshot = try (try shareIndex(handle)).snapshot(gpa);
    defer gpa.free(snapshot);
    const out = try gpa.alloc(ShareInfo, snapshot.len);
    const index = try shareIndex(handle);
    for (snapshot, out) |s, *o| {
        o.* = .{ .name = s.name, .path = s.path, .files = s.files, .size = s.size, .ready = s.root != null, .indexing = s.indexing, .backup = index.isBackup(s.name), .scan_error = if (s.scan_error) |e| @errorName(e) else null };
    }
    return out;
}

pub const PickedFolder = struct { path: []const u8, name: []const u8 };

/// Turns the picker's folder id into a path the scanner can read: the path
/// itself on desktops; on Android, the SAF tree URI of a shared-storage
/// folder (`.../tree/primary%3ADCIM%2FCamera`) mapped onto
/// /storage/emulated/0/DCIM/Camera, which all-files access lets us read
/// directly. Folders of other providers (cloud drives) have no path.
pub fn pickedFolder(gpa: std.mem.Allocator, id: []const u8, name: []const u8) !PickedFolder {
    if (!builtin.abi.isAndroid()) return .{ .path = try gpa.dupe(u8, id), .name = try gpa.dupe(u8, name) };
    return .{ .path = try treeUriToPath(gpa, id), .name = try gpa.dupe(u8, name) };
}

fn treeUriToPath(gpa: std.mem.Allocator, uri: []const u8) ![]const u8 {
    const authority = "content://com.android.externalstorage.documents/tree/";
    if (!std.mem.startsWith(u8, uri, authority)) return error.UnsupportedFolder;
    var encoded = uri[authority.len..];
    if (std.mem.indexOfScalar(u8, encoded, '/')) |slash| encoded = encoded[0..slash];
    const doc_id = try percentDecode(gpa, encoded);
    defer gpa.free(doc_id);
    const colon = std.mem.indexOfScalar(u8, doc_id, ':') orelse return error.UnsupportedFolder;
    const volume = doc_id[0..colon];
    const rel = std.mem.trim(u8, doc_id[colon + 1 ..], "/");
    if (std.mem.indexOf(u8, rel, "..") != null or volume.len == 0 or std.mem.indexOfScalar(u8, volume, '/') != null)
        return error.UnsupportedFolder;
    const root = if (std.mem.eql(u8, volume, "primary"))
        try gpa.dupe(u8, "/storage/emulated/0")
    else
        try std.fmt.allocPrint(gpa, "/storage/{s}", .{volume}); // SD cards: /storage/XXXX-XXXX
    defer gpa.free(root);
    if (rel.len == 0) return gpa.dupe(u8, root);
    return std.fs.path.join(gpa, &.{ root, rel });
}

fn percentDecode(gpa: std.mem.Allocator, text: []const u8) ![]u8 {
    const out = try gpa.alloc(u8, text.len);
    var n: usize = 0;
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        if (text[i] == '%' and i + 2 < text.len) {
            out[n] = std.fmt.parseInt(u8, text[i + 1 .. i + 3], 16) catch return error.UnsupportedFolder;
            i += 2;
        } else {
            out[n] = text[i];
        }
        n += 1;
    }
    return gpa.realloc(out, n);
}

test "commands: SAF tree URIs map onto shared storage paths" {
    const gpa = testing.allocator;
    const cases = [_][2][]const u8{
        .{ "content://com.android.externalstorage.documents/tree/primary%3ADCIM%2FCamera", "/storage/emulated/0/DCIM/Camera" },
        .{ "content://com.android.externalstorage.documents/tree/primary%3A", "/storage/emulated/0" },
        .{ "content://com.android.externalstorage.documents/tree/1A2B-3C4D%3APhotos", "/storage/1A2B-3C4D/Photos" },
    };
    for (cases) |c| {
        const path = try treeUriToPath(gpa, c[0]);
        defer gpa.free(path);
        try testing.expectEqualStrings(c[1], path);
    }
    try testing.expectError(error.UnsupportedFolder, treeUriToPath(gpa, "content://com.google.android.apps.docs.storage/tree/abc"));
    try testing.expectError(error.UnsupportedFolder, treeUriToPath(gpa, "content://com.android.externalstorage.documents/tree/primary%3A..%2Fx"));
}

pub const ShareAddArgs = struct { config_path: []const u8, name: []const u8, path: []const u8, backup: bool = false };

/// `invoke("share_add", { config_path, name, path })`: scans the folder,
/// starts sharing it and records it in the config so it survives restarts.
pub fn shareAdd(gpa: std.mem.Allocator, args: ShareAddArgs) !void {
    const name = std.mem.trim(u8, args.name, " \t");
    const path = std.mem.trim(u8, args.path, " \t");
    if (!nomadfs.storage.dag.codec.isValidName(name) or std.mem.indexOfScalar(u8, name, ':') != null)
        return error.InvalidShareName;
    if (path.len == 0 or std.mem.indexOfAny(u8, path, "\"\n") != null) return error.InvalidPath;

    g_mutex.lock();
    defer g_mutex.unlock();
    const handle = g_node orelse return error.NotRunning;
    const index = try shareIndex(handle);
    try index.add(name, path);
    try index.start();

    const line = try std.fmt.allocPrint(gpa, "share = \"{s}:{s}\"", .{ name, path });
    defer gpa.free(line);
    try editConfig(gpa, args.config_path, .{ .drop_share = name, .append = &.{line} });
    if (args.backup) try setShareBackup(gpa, args.config_path, index, name, true);
}

/// Marks or unmarks a share for backup, live and in the config.
fn setShareBackup(gpa: std.mem.Allocator, config_path: []const u8, index: *fs.ShareIndex, name: []const u8, on: bool) !void {
    try index.setBackup(name, on);
    const line = try std.fmt.allocPrint(gpa, "backup = \"{s}\"", .{name});
    defer gpa.free(line);
    try editConfig(gpa, config_path, .{ .drop_backup = name, .append = if (on) &.{line} else &.{} });
}

pub const ShareBackupArgs = struct { config_path: []const u8, name: []const u8, on: bool };

/// `invoke("share_backup_set", { config_path, name, on })`: asks the swarm's
/// backup devices to keep a copy of this share, or stops asking (copies
/// already made stay on them).
pub fn shareBackupSet(gpa: std.mem.Allocator, args: ShareBackupArgs) !void {
    g_mutex.lock();
    defer g_mutex.unlock();
    const handle = g_node orelse return error.NotRunning;
    try setShareBackup(gpa, args.config_path, try shareIndex(handle), args.name, args.on);
}

pub const BackupCopy = struct {
    /// The backup device, as this device names it.
    device: []const u8,
    /// Its copy matches this share as it is now.
    current: bool,
    synced_at: u64,
};
pub const BackupStatus = struct {
    share: []const u8,
    copies: []BackupCopy,
    /// This device is on Wi-Fi (or not a phone): marked shares are offered.
    unmetered: bool,
};

/// `invoke("backup_status")`: for each share marked for backup, which
/// backup devices hold a copy and whether it's up to date. Asks every
/// reachable device, so it takes a moment.
pub fn backupStatus(gpa: std.mem.Allocator) ![]BackupStatus {
    var my_id: [32]u8 = undefined;
    var bm: *nomadfs.cluster.BlockManager = undefined;
    var store: *nomadfs.storage.engine.StorageEngine = undefined;
    var trust: *TrustStore = undefined;
    var snap: []fs.shares.Share = &.{};
    var marked: std.ArrayList([]const u8) = .empty;
    {
        g_mutex.lock();
        defer g_mutex.unlock();
        const handle = g_node orelse return error.NotRunning;
        const index = try shareIndex(handle);
        my_id = handle.node.device_identity.deviceId().bytes;
        bm = handle.node.block_manager;
        store = handle.node.store orelse return error.StorageDisabled;
        trust = handle.node.trust_store;
        snap = try index.snapshot(gpa);
        for (snap) |s| if (index.isBackup(s.name)) try marked.append(gpa, s.name);
        // Asking every device takes a while: keep the node alive without
        // holding g_mutex (nodeClose waits for media users).
        _ = g_media_users.fetchAdd(1, .acq_rel);
    }
    defer mediaRelease();
    const peers = fs.remote.knownPeers(bm, gpa) catch &.{};
    var copies = try gpa.alloc(std.ArrayList(BackupCopy), marked.items.len);
    for (copies) |*c| c.* = .empty;
    for (peers) |peer| {
        var remote = fs.Remote{ .block_manager = bm, .store = store, .peer = peer };
        const listed = remote.shares(gpa) catch continue;
        var info = fs.backup.decodeInfo(gpa, listed.backup) catch continue;
        defer info.deinit();
        const device_name = blk: {
            if (listed.device_id) |d| if (trust.lookup(d)) |e| break :blk try gpa.dupe(u8, e.labelSlice());
            break :blk listed.nickname;
        };
        for (info.held) |h| {
            if (!std.mem.eql(u8, &h.owner, &my_id)) continue;
            for (marked.items, 0..) |name, i| {
                if (!std.mem.eql(u8, name, h.share)) continue;
                const root = for (snap) |s| {
                    if (std.mem.eql(u8, s.name, name)) break s.root;
                } else null;
                const current = if (root) |r| std.mem.eql(u8, &r, &h.source_root) else false;
                try copies[i].append(gpa, .{ .device = device_name, .current = current, .synced_at = h.synced_at });
            }
        }
    }
    const out = try gpa.alloc(BackupStatus, marked.items.len);
    const unmetered = nomadfs.net.local_addrs.onUnmeteredNetwork();
    for (marked.items, out, copies) |name, *o, *c| o.* = .{ .share = name, .copies = c.items, .unmetered = unmetered };
    return out;
}

pub const ShareRemoveArgs = struct { config_path: []const u8, name: []const u8 };

/// `invoke("share_remove", { config_path, name })`.
pub fn shareRemove(gpa: std.mem.Allocator, args: ShareRemoveArgs) !void {
    g_mutex.lock();
    defer g_mutex.unlock();
    const handle = g_node orelse return error.NotRunning;
    _ = (try shareIndex(handle)).remove(args.name);
    try editConfig(gpa, args.config_path, .{ .drop_share = args.name });
}

pub const RemoteShare = struct { name: []const u8, cid: []const u8, size: u64, mtime: u64 };
pub const RemoteDevice = struct {
    peer: []const u8, // transport id hex (unchanged: keys browse/download calls)
    nickname: []const u8, // CLAIMED name, untrusted
    shares: []RemoteShare,
    device_id: []const u8, // hex of the authenticated device id ("" if unknown)
    fingerprint: []const u8, // "aaaa-bbbb-cccc-dddd" (same format as devices_list)
    trusted: bool,
    label: []const u8, // trust-store label, "" if not trusted
    mount_name: []const u8, // exactly what the mount shows (device_names.assign)
};

/// `invoke("remote_devices")`: every reachable device and what it shares.
/// Devices that don't answer are left out.
pub fn remoteDevices(gpa: std.mem.Allocator) ![]RemoteDevice {
    g_mutex.lock();
    defer g_mutex.unlock();
    const handle = g_node orelse return error.NotRunning;
    const store = handle.node.store orelse return error.StorageDisabled;
    const bm = handle.node.block_manager;

    const peers = try fs.remote.knownPeers(bm, gpa);
    defer gpa.free(peers);

    const ProbeResult = struct {
        peer: NodeID,
        device_id: ?NodeID,
        nickname: []u8,
        shares: []RemoteShare,
        trusted: bool,
        label: []const u8,
        added_at: u64,
    };

    var results: std.ArrayList(ProbeResult) = .empty;
    defer {
        for (results.items) |r| {
            gpa.free(r.nickname);
            gpa.free(r.label);
            for (r.shares) |s| {
                gpa.free(s.name);
                gpa.free(s.cid);
            }
            gpa.free(r.shares);
        }
        results.deinit(gpa);
    }

    const trust_store = handle.node.trust_store;

    for (peers) |peer| {
        var remote = fs.Remote{ .block_manager = bm, .store = store, .peer = peer };
        const shares = remote.shares(gpa) catch |err| {
            std.debug.print("remote_devices: {x} unavailable: {any}\n", .{ peer.bytes[0..4], err });
            continue;
        };
        defer shares.listing.deinit();
        const list = try gpa.alloc(RemoteShare, shares.listing.entries.len);
        for (shares.listing.entries, list) |e, *o| {
            o.* = .{ .name = try gpa.dupe(u8, e.name), .cid = try hexAlloc(gpa, &e.cid), .size = e.size, .mtime = e.mtime };
        }

        const dev_id_opt = shares.device_id;
        var is_trusted = false;
        var label: []const u8 = try gpa.dupe(u8, "");
        var added_at: u64 = 0;

        if (dev_id_opt) |did| {
            if (trust_store.lookup(did)) |entry| {
                is_trusted = true;
                gpa.free(label);
                label = try gpa.dupe(u8, entry.labelSlice());
                added_at = entry.added_at;
            }
        }

        try results.append(gpa, .{
            .peer = peer,
            .device_id = dev_id_opt,
            .nickname = shares.nickname,
            .shares = list,
            .trusted = is_trusted,
            .label = label,
            .added_at = added_at,
        });
    }

    if (results.items.len == 0) {
        return gpa.alloc(RemoteDevice, 0);
    }

    const assign_entries = try gpa.alloc(fs.device_names.Entry, results.items.len);
    defer gpa.free(assign_entries);
    const mount_names = try gpa.alloc([]u8, results.items.len);
    defer gpa.free(mount_names);

    for (results.items, 0..) |r, i| {
        const id_bytes = if (r.device_id) |did| did.bytes else r.peer.bytes;
        assign_entries[i] = .{
            .device_id = id_bytes,
            .trusted = if (r.trusted) .{ .label = r.label, .added_at = r.added_at } else null,
            .nickname = r.nickname,
        };
    }

    try fs.device_names.assign(gpa, assign_entries, mount_names);

    const out = try gpa.alloc(RemoteDevice, results.items.len);
    for (results.items, 0..) |r, i| {
        const dev_id_bytes = if (r.device_id) |did| did.bytes else r.peer.bytes;
        var fp_buf: [19]u8 = undefined;
        const fp_str = if (r.device_id != null)
            Identity.formatFingerprint(dev_id_bytes[0..8].*, &fp_buf)
        else
            "";
        const dev_id_hex = if (r.device_id != null)
            try hexAlloc(gpa, &dev_id_bytes)
        else
            try gpa.dupe(u8, "");

        out[i] = .{
            .peer = try hexAlloc(gpa, &r.peer.bytes),
            .nickname = r.nickname,
            .shares = r.shares,
            .device_id = dev_id_hex,
            .fingerprint = try gpa.dupe(u8, fp_str),
            .trusted = r.trusted,
            .label = r.label,
            .mount_name = mount_names[i],
        };
    }

    results.items.len = 0;
    return out;
}

pub const BrowseArgs = struct { peer: []const u8, cid: []const u8 };
pub const BrowseEntry = struct { name: []const u8, cid: []const u8, size: u64, mtime: u64, dir: bool };

/// `invoke("browse", { peer, cid })`: lists a directory of a device's
/// share. Only that directory's block is fetched.
pub fn browse(gpa: std.mem.Allocator, args: BrowseArgs) ![]BrowseEntry {
    g_mutex.lock();
    defer g_mutex.unlock();
    var remote = try remoteFor(args.peer);
    const cid = try parseHex32(args.cid);
    const listing = try fs.tree.listDir(gpa, remote.loader(), &cid);
    defer gpa.free(listing.entries);
    const out = try gpa.alloc(BrowseEntry, listing.entries.len);
    for (listing.entries, out) |e, *o| {
        o.* = .{ .name = e.name, .cid = try hexAlloc(gpa, &e.cid), .size = e.size, .mtime = e.mtime, .dir = e.kind == .dir };
    }
    return out;
}

pub const DownloadArgs = struct { peer: []const u8, cid: []const u8, name: []const u8 };
pub const DownloadResult = struct { path: []const u8, size: u64 };

/// `invoke("download", { peer, cid, name })`: copies one file from a
/// device's share into Downloads/NomadFS and returns where it landed.
pub fn download(gpa: std.mem.Allocator, args: DownloadArgs) !DownloadResult {
    if (!nomadfs.storage.dag.codec.isValidName(args.name)) return error.InvalidName;
    g_mutex.lock();
    defer g_mutex.unlock();
    var remote = try remoteFor(args.peer);
    const cid = try parseHex32(args.cid);
    const loader = remote.loader();

    const io = std.Io.Threaded.global_single_threaded.io();
    const dir = try downloadsDir(gpa);
    defer gpa.free(dir);
    try std.Io.Dir.cwd().createDirPath(io, dir);
    const path = try uniquePath(gpa, dir, args.name);
    errdefer gpa.free(path);

    var file = try std.Io.Dir.cwd().createFile(io, path, .{ .exclusive = true });
    defer file.close(io);
    errdefer std.Io.Dir.cwd().deleteFile(io, path) catch {};

    const chunk = try gpa.alloc(u8, 1024 * 1024);
    defer gpa.free(chunk);
    var offset: u64 = 0;
    while (true) {
        const n = try fs.tree.readAt(gpa, loader, cid, offset, chunk);
        if (n == 0) break;
        try file.writePositionalAll(io, chunk[0..n], offset);
        offset += n;
    }
    return .{ .path = path, .size = offset };
}

/// Caller holds g_mutex.
fn remoteFor(peer_hex: []const u8) !fs.Remote {
    const handle = g_node orelse return error.NotRunning;
    const store = handle.node.store orelse return error.StorageDisabled;
    return .{ .block_manager = handle.node.block_manager, .store = store, .peer = .{ .bytes = try parseHex32(peer_hex) } };
}

fn parseHex32(text: []const u8) ![32]u8 {
    if (text.len != 64) return error.InvalidArgument;
    var out: [32]u8 = undefined;
    _ = std.fmt.hexToBytes(&out, text) catch return error.InvalidArgument;
    return out;
}

fn hexAlloc(gpa: std.mem.Allocator, bytes: *const [32]u8) ![]const u8 {
    const hex = std.fmt.bytesToHex(bytes.*, .lower);
    return gpa.dupe(u8, &hex);
}

/// Downloads/NomadFS: the shared Download folder on Android (readable by
/// other apps; needs all-files access), $HOME/Downloads elsewhere.
fn downloadsDir(gpa: std.mem.Allocator) ![]const u8 {
    if (builtin.abi.isAndroid()) return gpa.dupe(u8, "/storage/emulated/0/Download/NomadFS");
    const home_env = if (builtin.os.tag == .windows) "USERPROFILE" else "HOME";
    const home = nomadfs.env.getEnv(gpa, home_env) orelse return error.HomeNotFound;
    defer gpa.free(home);
    return std.fs.path.join(gpa, &.{ home, "Downloads", "NomadFS" });
}

/// `dir/name`, or `dir/name (n).ext` when that exists already.
fn uniquePath(gpa: std.mem.Allocator, dir: []const u8, name: []const u8) ![]const u8 {
    const io = std.Io.Threaded.global_single_threaded.io();
    const ext = std.fs.path.extension(name);
    const stem = name[0 .. name.len - ext.len];
    var n: u32 = 0;
    while (n < 1000) : (n += 1) {
        const candidate = if (n == 0)
            try std.fs.path.join(gpa, &.{ dir, name })
        else
            try std.fmt.allocPrint(gpa, "{s}/{s} ({d}){s}", .{ dir, stem, n, ext });
        _ = std.Io.Dir.cwd().statFile(io, candidate, .{}) catch return candidate;
        gpa.free(candidate);
    }
    return error.PathAlreadyExists;
}

pub const ReadRangeArgs = struct { peer: []const u8, cid: []const u8, offset: u64, len: u32 };

/// Largest slice `read_range` returns; previews read files in pieces.
pub const max_range_len: u32 = 4 * 1024 * 1024;

/// `invoke("read_range", { peer, cid, offset, len })`: bytes of a file in
/// a device's share, base64-encoded for the page, which builds a preview
/// from consecutive ranges. Only the blocks covering the range are fetched.
pub fn readRange(gpa: std.mem.Allocator, args: ReadRangeArgs) ![]const u8 {
    if (args.len == 0 or args.len > max_range_len) return error.InvalidArgument;
    g_mutex.lock();
    defer g_mutex.unlock();
    var remote = try remoteFor(args.peer);
    const cid = try parseHex32(args.cid);
    const buf = try gpa.alloc(u8, args.len);
    defer gpa.free(buf);
    const n = if (g_node.?.node.read_ahead) |ra|
        try ra.readAt(gpa, &.{remote.peer}, cid, args.offset, buf)
    else
        try fs.tree.readAt(gpa, remote.loader(), cid, args.offset, buf);
    const encoder = std.base64.standard.Encoder;
    const out = try gpa.alloc(u8, encoder.calcSize(n));
    return encoder.encode(out, buf[0..n]);
}

// ---- Swarm folder: one folder every device reads and writes ----

pub const SwarmItem = struct {
    name: []const u8,
    path: []const u8,
    dir: bool,
    size: u64,
    mtime: u64,
    cid: []const u8,
    author: []const u8,
    author_id: []const u8,
};
pub const SwarmListing = struct { items: []SwarmItem, entries: usize, peers_synced: u32, last_sync: u64 };
pub const SwarmDirArgs = struct { dir: []const u8 };

/// Caller holds g_mutex.
fn swarmFolder() !*fs.SwarmFolder {
    const handle = g_node orelse return error.NotRunning;
    return handle.node.swarm orelse error.StorageDisabled;
}

/// `swarm_list { dir }`: a folder of the swarm folder ("" = top).
pub fn swarmList(gpa: std.mem.Allocator, args: SwarmDirArgs) !SwarmListing {
    g_mutex.lock();
    defer g_mutex.unlock();
    const folder = try swarmFolder();
    const items = try folder.list(gpa, args.dir);
    const out = try gpa.alloc(SwarmItem, items.len);
    for (items, out) |it, *o| {
        o.* = .{
            .name = it.name,
            .path = it.path,
            .dir = it.dir,
            .size = it.size,
            .mtime = it.mtime,
            .cid = if (it.cid) |c| try hexAlloc(gpa, &c) else "",
            .author = it.author,
            .author_id = if (it.author_id) |a| try hexAlloc(gpa, &a) else "",
        };
    }
    const st = folder.status();
    return .{ .items = out, .entries = st.entries, .peers_synced = st.peers_synced, .last_sync = st.last_sync };
}

pub const BackupArgs = struct { config_path: []const u8, on: bool };

pub const BackupInfo = struct {
    /// Not offered on phones: a backup copies the whole folder.
    supported: bool,
    enabled: bool,
    /// The node is running (else the counts are 0).
    running: bool,
    files: usize = 0,
    backed_up: usize = 0,
    bytes: u64 = 0,
    unreachable_files: usize = 0,
    last_round: u64 = 0,
    replicas: u8 = 0,
};

pub const SwarmReplicasArgs = struct { config_path: []const u8, replicas: u8 };

const backup_supported = !builtin.abi.isAndroid();

/// `swarm_backup_status { config_path }`: whether this device keeps a copy
/// of the whole swarm folder, and how far it got.
pub fn swarmBackupStatus(gpa: std.mem.Allocator, args: ListArgs) !BackupInfo {
    if (!backup_supported) return .{ .supported = false, .enabled = false, .running = false };
    {
        g_mutex.lock();
        defer g_mutex.unlock();
        if (swarmFolder()) |folder| {
            const st = folder.backupStatus();
            const reps = folder.swarm_replicas.load(.acquire);
            return .{
                .supported = true,
                .enabled = st.enabled,
                .running = true,
                .files = st.files,
                .backed_up = st.backed_up,
                .bytes = st.bytes,
                .unreachable_files = st.unreachable_files,
                .last_round = st.last_round,
                .replicas = reps,
            };
        } else |_| {}
    }
    var config = config_mod.parseConfig(gpa, args.config_path) catch return error.ConfigInvalid;
    defer config.deinit(gpa);
    return .{ .supported = true, .enabled = config.storage.swarm_backup, .running = false, .replicas = config.storage.swarm_replicas };
}

/// `swarm_backup_set { config_path, on }`: saved in the config
/// (`swarm_backup`), and applied to the running node at once.
pub fn swarmBackupSet(gpa: std.mem.Allocator, args: BackupArgs) !BackupInfo {
    if (!backup_supported) return error.Unsupported;
    try editConfig(gpa, args.config_path, .{
        .drop_keys = &.{"swarm_backup"},
        .append = &.{if (args.on) "swarm_backup = true" else "swarm_backup = false"},
    });
    {
        g_mutex.lock();
        defer g_mutex.unlock();
        if (swarmFolder()) |folder| try folder.setBackup(args.on) else |_| {}
    }
    return swarmBackupStatus(gpa, .{ .config_path = args.config_path });
}

/// `swarm_replicas_set { config_path, replicas }`: saved in the config
/// (`swarm_replicas`), and applied to the running swarm folder at once.
pub fn swarmReplicasSet(gpa: std.mem.Allocator, args: SwarmReplicasArgs) !BackupInfo {
    if (args.replicas > config_mod.max_replicas) return error.ReplicasOutOfRange;
    var buf: [32]u8 = undefined;
    const line = try std.fmt.bufPrint(&buf, "swarm_replicas = {d}", .{args.replicas});
    try editConfig(gpa, args.config_path, .{
        .drop_keys = &.{"swarm_replicas"},
        .append = &.{line},
    });
    {
        g_mutex.lock();
        defer g_mutex.unlock();
        if (swarmFolder()) |folder| {
            folder.swarm_replicas.store(args.replicas, .release);
        } else |_| {}
    }
    return swarmBackupStatus(gpa, .{ .config_path = args.config_path });
}

/// `swarm_sync`: pull every reachable device's changes now.
pub fn swarmSync() !usize {
    g_mutex.lock();
    defer g_mutex.unlock();
    return (try swarmFolder()).syncNow();
}

/// `swarm_add_file { dir }`: the system file picker, then the picked
/// file is added to `dir`. Returns its name, or null when cancelled.
pub fn swarmAddFile(gpa: std.mem.Allocator, dir: []const u8, picked_path: []const u8) ![]const u8 {
    const name = std.fs.path.basename(picked_path);
    if (!nomadfs.storage.dag.codec.isValidName(name)) return error.InvalidName;
    g_mutex.lock();
    defer g_mutex.unlock();
    try (try swarmFolder()).addFile(dir, name, picked_path);
    return gpa.dupe(u8, name);
}

pub const SwarmNameArgs = struct { dir: []const u8, name: []const u8 };

/// `swarm_mkdir { dir, name }`.
pub fn swarmMkdir(args: SwarmNameArgs) !void {
    g_mutex.lock();
    defer g_mutex.unlock();
    try (try swarmFolder()).makeDir(args.dir, std.mem.trim(u8, args.name, " \t"));
}

pub const SwarmPathArgs = struct { path: []const u8 };

/// `swarm_delete { path }`: a file, or a folder and everything in it.
pub fn swarmDelete(args: SwarmPathArgs) !void {
    g_mutex.lock();
    defer g_mutex.unlock();
    try (try swarmFolder()).remove(args.path);
}

pub const SwarmRenameArgs = struct { path: []const u8, name: []const u8 };

/// `swarm_rename { path, name }`: in place, same parent folder.
pub fn swarmRename(args: SwarmRenameArgs) !void {
    g_mutex.lock();
    defer g_mutex.unlock();
    try (try swarmFolder()).rename(args.path, std.mem.trim(u8, args.name, " \t"));
}

// ---- File details (how NomadFS stores a file) ----

pub const FileDetailsArgs = struct {
    cid: []const u8,
    /// The device sharing the file (Browse), or
    peer: ?[]const u8 = null,
    /// the swarm folder file's author (Swarm folder).
    author_id: ?[]const u8 = null,
};

pub const ChunkInfo = struct { offset: u64, size: u64, cid: []const u8, where: []const u8 };

pub const FileDetails = struct {
    cid: []const u8,
    size: u64,
    /// Levels of parent blocks above the chunks.
    depth: u32,
    parents: u32,
    chunks: usize,
    chunk_min: u64,
    chunk_avg: u64,
    chunk_max: u64,
    /// Chunks by where this device holds them.
    kept: usize,
    cached: usize,
    external: usize,
    missing: usize,
    /// Every chunk's size and where it is (0 kept, 1 read cache, 2 the
    /// shared file itself, 3 not here), in file order, for the chunk map.
    sizes: []u64,
    /// Numbers, not `[]u8`: JSON writes a `[]u8` as a string.
    states: []u32,
    /// The first chunks, for a table.
    first: []ChunkInfo,
    /// The chunker's bounds (FastCDC).
    chunker_min: u64,
    chunker_avg: u64,
    chunker_max: u64,
};

/// `invoke("file_details", { cid, peer | author_id })`: the file's DAG and
/// chunks, and where this device holds each chunk. Loads only parent blocks
/// (and one chunk), never the whole file.
pub fn fileDetails(gpa: std.mem.Allocator, args: FileDetailsArgs) !FileDetails {
    const root = try parseHex32(args.cid);
    // The walk may fetch blocks from other devices: hold the node, not g_mutex.
    const handle = mediaAcquire() orelse return error.NotRunning;
    defer mediaRelease();
    const store = handle.node.store orelse return error.StorageDisabled;
    const bm = handle.node.block_manager;

    var remote: fs.Remote = undefined;
    var multi: fs.remote.MultiRemote = undefined;
    var peers: std.ArrayList(nomadfs.net.id.NodeID) = .empty;
    const loader = if (args.peer) |p| blk: {
        remote = .{ .block_manager = bm, .store = store, .peer = .{ .bytes = try parseHex32(p) }, .root = root };
        break :blk remote.loader();
    } else blk: {
        if (args.author_id) |a| if (a.len == 64) try peers.append(gpa, .{ .bytes = try parseHex32(a) });
        const known = fs.remote.knownPeers(bm, gpa) catch &.{};
        for (known) |k| try peers.append(gpa, k);
        multi = .{ .block_manager = bm, .store = store, .peers = peers.items, .root = root };
        break :blk multi.loader();
    };

    const info = try fs.inspect.inspect(gpa, loader, root);
    var d: FileDetails = .{
        .cid = try gpa.dupe(u8, args.cid),
        .size = 0,
        .depth = info.depth,
        .parents = info.parents,
        .chunks = info.chunks.len,
        .chunk_min = std.math.maxInt(u64),
        .chunk_avg = 0,
        .chunk_max = 0,
        .kept = 0,
        .cached = 0,
        .external = 0,
        .missing = 0,
        .sizes = try gpa.alloc(u64, info.chunks.len),
        .states = try gpa.alloc(u32, info.chunks.len),
        .first = try gpa.alloc(ChunkInfo, @min(info.chunks.len, 8)),
        .chunker_min = (nomadfs.storage.chunker.Params{}).min_size,
        .chunker_avg = (nomadfs.storage.chunker.Params{}).avg_size,
        .chunker_max = (nomadfs.storage.chunker.Params{}).max_size,
    };
    for (info.chunks, 0..) |c, i| {
        d.size +|= c.size;
        d.chunk_min = @min(d.chunk_min, c.size);
        d.chunk_max = @max(d.chunk_max, c.size);
        d.sizes[i] = c.size;
        const where = store.locate(&c.cid);
        d.states[i] = @intFromEnum(where);
        switch (where) {
            .kept => d.kept += 1,
            .cached => d.cached += 1,
            .external => d.external += 1,
            .missing => d.missing += 1,
        }
        if (i < d.first.len) d.first[i] = .{ .offset = c.offset, .size = c.size, .cid = try hexAlloc(gpa, &c.cid), .where = @tagName(where) };
    }
    if (info.chunks.len == 0) d.chunk_min = 0 else d.chunk_avg = d.size / info.chunks.len;
    return d;
}

pub const DeviceInfoArgs = struct { peer: ?[]const u8 = null };

/// node_info.Info with its texts as strings, for JSON.
pub const DeviceInfo = struct {
    version: []const u8,
    platform: []const u8,
    uptime_s: u64,
    disk_total: u64,
    disk_free: u64,
    kept_bytes: u64,
    kept_blocks: u64,
    cache_bytes: u64,
    cache_limit: u64,
    quota: u64,
    peers: u32,
    connections: u32,
    trusted: u32,
    shares: u32,
    shares_failing: u32,
    shares_indexing: u32,
    swarm_files: u32,
    swarm_last_sync: u64,
    swarm_backup: bool,
    swarm_backed_up: u32,
    swarm_unreachable: u32,
    held_backups: u32,
    unmetered: bool,
};

/// `invoke("device_info", { peer? })`: what a device reports about itself
/// (GET_NODE_INFO), asked now; this device's own without `peer`. Fails with
/// NotTrusted when the device doesn't trust this one, and with
/// NeedsUpdate when it is too old to answer.
pub fn deviceInfo(gpa: std.mem.Allocator, args: DeviceInfoArgs) !DeviceInfo {
    // Asking takes a round trip: hold the node, not g_mutex.
    const handle = mediaAcquire() orelse return error.NotRunning;
    defer mediaRelease();
    const info: nomadfs.node_info.Info = if (args.peer) |p| blk: {
        const peer: NodeID = .{ .bytes = try parseHex32(p) };
        const bm = handle.node.block_manager;
        const conn = try bm.connectTo(peer);
        defer conn.deinit();
        const bytes = bm.dht_node.fetchNodeInfo(conn, gpa) catch |err| switch (err) {
            error.NotTrusted => return err,
            // An older device drops the request it can't read.
            error.EndOfStream, error.InvalidResponse, error.ConnectionResetByPeer => return error.NeedsUpdate,
            else => return err,
        };
        break :blk nomadfs.node_info.decode(bytes) catch return error.NeedsUpdate;
    } else try handle.node.info_provider.info(gpa);
    var out: DeviceInfo = undefined;
    inline for (std.meta.fields(DeviceInfo)) |f| {
        const v = @field(info, f.name);
        @field(out, f.name) = if (@TypeOf(v) == nomadfs.node_info.Info.Text) try gpa.dupe(u8, v.slice()) else v;
    }
    return out;
}

pub const SwarmRangeArgs = struct { cid: []const u8, author_id: []const u8, offset: u64, len: u32 };

/// `swarm_read_range`: base64 bytes of a swarm file, for previews.
pub fn swarmReadRange(gpa: std.mem.Allocator, args: SwarmRangeArgs) ![]const u8 {
    if (args.len == 0 or args.len > max_range_len) return error.InvalidArgument;
    const cid = try parseHex32(args.cid);
    const author = try parseHex32(args.author_id);
    g_mutex.lock();
    defer g_mutex.unlock();
    const buf = try gpa.alloc(u8, args.len);
    defer gpa.free(buf);
    const n = try (try swarmFolder()).readAt(gpa, cid, author, args.offset, buf);
    const encoder = std.base64.standard.Encoder;
    const out = try gpa.alloc(u8, encoder.calcSize(n));
    return encoder.encode(out, buf[0..n]);
}

pub const SwarmDownloadArgs = struct { cid: []const u8, author_id: []const u8, name: []const u8 };

/// `swarm_download`: copies a swarm file into Downloads/NomadFS.
pub fn swarmDownload(gpa: std.mem.Allocator, args: SwarmDownloadArgs) !DownloadResult {
    if (!nomadfs.storage.dag.codec.isValidName(args.name)) return error.InvalidName;
    const cid = try parseHex32(args.cid);
    const author = try parseHex32(args.author_id);
    g_mutex.lock();
    defer g_mutex.unlock();
    const folder = try swarmFolder();
    const io = std.Io.Threaded.global_single_threaded.io();
    const dir = try downloadsDir(gpa);
    defer gpa.free(dir);
    try std.Io.Dir.cwd().createDirPath(io, dir);
    const path = try uniquePath(gpa, dir, args.name);
    errdefer gpa.free(path);
    var file = try std.Io.Dir.cwd().createFile(io, path, .{ .exclusive = true });
    defer file.close(io);
    errdefer std.Io.Dir.cwd().deleteFile(io, path) catch {};
    const chunk = try gpa.alloc(u8, 1024 * 1024);
    defer gpa.free(chunk);
    var offset: u64 = 0;
    while (true) {
        const n = try folder.readAt(gpa, cid, author, offset, chunk);
        if (n == 0) break;
        try file.writePositionalAll(io, chunk[0..n], offset);
        offset += n;
    }
    return .{ .path = path, .size = offset };
}

// ---- Mounting (desktop Linux) ----

const can_mount = builtin.os.tag == .linux and !builtin.abi.isAndroid();

const MountJob = struct {
    mount: if (can_mount) fs.fuse.Mount else void,
    thread: std.Thread,
    /// Points into `g_mount_path`, never a heap copy.
    path: [:0]u8,
    failed: std.atomic.Value(bool) = .init(false),
    done: std.atomic.Value(bool) = .init(false),
};

var g_mount: ?*MountJob = null;

/// The mount point of the live job. Static, because emergencyUnmount reads
/// it without the lock: a heap copy freed with the job would be a
/// use-after-free from the signal handler.
var g_mount_path: [std.fs.max_path_bytes:0]u8 = undefined;
/// True from before the serve thread starts until its job is freed. The
/// signal handler checks this, never the job.
var g_mount_active: std.atomic.Value(bool) = .init(false);

/// Copies `path` into g_mount_path. Caller holds g_mutex and no job is live.
fn setMountPath(path: []const u8) ![:0]u8 {
    if (path.len >= g_mount_path.len) return error.InvalidPath;
    @memcpy(g_mount_path[0..path.len], path);
    g_mount_path[path.len] = 0;
    return g_mount_path[0..path.len :0];
}

pub const MountStatus = struct {
    supported: bool,
    mounted: bool,
    path: []const u8,
    default_path: []const u8,
};

/// `invoke("mount_status")`.
pub fn mountStatus(gpa: std.mem.Allocator) !MountStatus {
    g_mutex.lock();
    defer g_mutex.unlock();
    reapMountLocked();
    const default_path = defaultMountPath(gpa) catch try gpa.dupe(u8, "");
    if (g_mount) |job| return .{ .supported = can_mount, .mounted = true, .path = try gpa.dupe(u8, job.path), .default_path = default_path };
    return .{ .supported = can_mount, .mounted = false, .path = "", .default_path = default_path };
}

fn defaultMountPath(gpa: std.mem.Allocator) ![]const u8 {
    const home = nomadfs.env.getEnv(gpa, "HOME") orelse return error.HomeNotFound;
    defer gpa.free(home);
    return std.fs.path.join(gpa, &.{ home, "NomadFS" });
}

pub const MountPeek = struct { mounted: bool, path: []const u8 };

/// Mount state without waiting: null while another command holds the
/// lock (a download, a browse), so the UI thread never blocks on one.
/// `path` points into `buf`.
pub fn mountPeek(buf: []u8) ?MountPeek {
    if (!g_mutex.tryLock()) return null;
    defer g_mutex.unlock();
    reapMountLocked();
    const job = g_mount orelse return .{ .mounted = false, .path = "" };
    const n = @min(buf.len, job.path.len);
    @memcpy(buf[0..n], job.path[0..n]);
    return .{ .mounted = true, .path = buf[0..n] };
}

pub const MountArgs = struct { path: []const u8 };

/// `invoke("mount_start", { path })`: mounts every reachable device's
/// shares at `path` (created if missing), read-only; files download when
/// an app reads them. Returns once the kernel shows the mount.
pub fn mountStart(gpa: std.mem.Allocator, args: MountArgs) !void {
    if (!can_mount) return error.MountUnsupported;
    if (args.path.len == 0 or args.path[0] != '/') return error.InvalidPath;
    const io = std.Io.Threaded.global_single_threaded.io();

    g_mutex.lock();
    defer g_mutex.unlock();
    reapMountLocked();
    if (g_mount != null) return error.AlreadyMounted;
    const handle = g_node orelse return error.NotRunning;
    const store = handle.node.store orelse return error.StorageDisabled;
    // A NomadFS mount left behind by a process that died ("transport
    // endpoint is not connected"): detach it before mounting again.
    if (can_mount and isMounted(gpa, args.path)) {
        const z = try gpa.dupeZ(u8, args.path);
        defer gpa.free(z);
        fs.fuse.unmount(z);
        // fusermount3 may be reaped by the toolkit before we wait on it:
        // trust the mount table, not the exit status.
        var tries: u32 = 0;
        while (tries < 30 and isMounted(gpa, args.path)) : (tries += 1) {
            nomadfs.sync.sleep(100 * std.time.ns_per_ms);
        }
        if (isMounted(gpa, args.path)) return error.StaleMountBusy;
    }
    try std.Io.Dir.cwd().createDirPath(io, args.path);

    const path = try setMountPath(args.path);
    const job = try std.heap.page_allocator.create(MountJob);
    errdefer std.heap.page_allocator.destroy(job);
    job.* = .{
        .mount = try fs.fuse.Mount.init(std.heap.page_allocator, handle.node.block_manager, store),
        .thread = undefined,
        .path = path,
    };
    // Each failure below unwinds what the steps above set up.
    errdefer if (can_mount) job.mount.deinit();
    if (can_mount) {
        job.mount.swarm = handle.node.swarm;
        job.mount.read_ahead = handle.node.read_ahead;
    }
    g_mount_active.store(true, .release);
    errdefer g_mount_active.store(false, .release);
    job.thread = try std.Thread.spawn(.{}, serveMount, .{job});
    g_mount = job;

    // Wait (bounded) for the kernel to list the mount, or the thread to fail.
    var waited: u32 = 0;
    while (waited < 50) : (waited += 1) {
        if (job.done.load(.acquire)) break;
        if (isMounted(gpa, args.path)) return;
        nomadfs.sync.sleep(100 * std.time.ns_per_ms);
    }
    if (job.done.load(.acquire)) {
        reapMountLocked();
        return error.MountFailed;
    }
}

fn serveMount(job: *MountJob) void {
    if (can_mount) {
        job.mount.serve(job.path) catch |err| {
            std.debug.print("mount at {s} failed: {any}\n", .{ job.path, err });
            job.failed.store(true, .release);
        };
    }
    job.done.store(true, .release);
}

/// Unmounts without taking any lock, for a signal handler about to end
/// the process: the kernel would otherwise keep a dead mount behind.
pub fn emergencyUnmount() void {
    if (!can_mount) return;
    if (!g_mount_active.load(.acquire)) return;
    // Unmounting a mount that already ended just fails; harmless here.
    fs.fuse.unmount(std.mem.sliceTo(&g_mount_path, 0));
}

/// `invoke("mount_stop")`.
pub fn mountStop() void {
    g_mutex.lock();
    defer g_mutex.unlock();
    stopMountLocked();
}

/// Caller holds g_mutex.
fn stopMountLocked() void {
    const job = g_mount orelse return;
    if (can_mount and !job.done.load(.acquire)) fs.fuse.unmount(job.path);
    // Unmounting makes the serve loop return.
    job.thread.join();
    freeMountJob(job);
    g_mount = null;
}

/// Frees a job whose thread has ended on its own (unmounted from outside,
/// or failed to mount). Caller holds g_mutex.
fn reapMountLocked() void {
    const job = g_mount orelse return;
    if (!job.done.load(.acquire)) return;
    job.thread.join();
    freeMountJob(job);
    g_mount = null;
}

fn freeMountJob(job: *MountJob) void {
    g_mount_active.store(false, .release);
    if (can_mount) job.mount.deinit();
    std.heap.page_allocator.destroy(job);
}

/// Whether /proc/self/mountinfo lists a NomadFS mount at `path`.
fn isMounted(gpa: std.mem.Allocator, path: []const u8) bool {
    const io = std.Io.Threaded.global_single_threaded.io();
    var file = std.Io.Dir.cwd().openFile(io, "/proc/self/mountinfo", .{}) catch return false;
    defer file.close(io);
    const buf = gpa.alloc(u8, 1024 * 1024) catch return false;
    defer gpa.free(buf);
    // One positional read: readStreaming ends /proc files with an error.
    const len = file.readPositionalAll(io, buf, 0) catch return false;
    var lines = std.mem.splitScalar(u8, buf[0..len], '\n');
    while (lines.next()) |line| {
        if (std.mem.indexOf(u8, line, "fuse.nomadfs") == null) continue;
        var fields = std.mem.splitScalar(u8, line, ' ');
        var i: usize = 0;
        while (fields.next()) |field| : (i += 1) {
            if (i == 4) {
                if (std.mem.eql(u8, field, path)) return true;
                break;
            }
        }
    }
    return false;
}

pub const OpenPathArgs = struct { path: []const u8 };

/// `invoke("open_path", { path })`: shows a folder or file in the desktop's
/// file manager / default app (xdg-open).
pub fn openPath(gpa: std.mem.Allocator, args: OpenPathArgs) !void {
    if (!can_mount) return error.Unsupported;
    const linux = std.os.linux;
    const programs = [_][:0]const u8{ "/usr/bin/xdg-open", "/bin/xdg-open", "/usr/local/bin/xdg-open" };
    const program = for (programs) |p| {
        if (linux.errno(linux.access(p.ptr, linux.X_OK)) == .SUCCESS) break p;
    } else return error.XdgOpenNotFound;
    const path = try gpa.dupeZ(u8, args.path);
    defer gpa.free(path);
    const argv = [_:null]?[*:0]const u8{ program.ptr, path.ptr };
    const envp: [*:null]const ?[*:0]const u8 = @ptrCast(std.c.environ);
    const pid = linux.fork();
    if (linux.errno(pid) != .SUCCESS) return error.ForkFailed;
    if (pid == 0) {
        // Double-fork: the grandchild is reparented to init (PID 1) and reaped
        // by the OS, while the intermediate child exits immediately so the
        // parent can reap it synchronously without leaving a zombie.
        const child2 = linux.fork();
        if (child2 == 0) {
            _ = linux.setsid();
            _ = linux.execve(program.ptr, &argv, envp);
            linux.exit(127);
        }
        linux.exit(if (linux.errno(child2) == .SUCCESS) 0 else 127);
    }
    var status: u32 = 0;
    _ = linux.wait4(@intCast(pid), &status, 0, null);
}

// ---- Joining devices ----

pub const JoinInfo = struct { nickname: []const u8, addresses: []const u8 };

/// `invoke("join_info", { config_path })`: this device's name and the
/// address other devices reach it at. (Never the swarm key: devices join
/// through one-time invites.)
pub fn joinInfo(gpa: std.mem.Allocator, args: ListArgs) !JoinInfo {
    var config = config_mod.parseConfig(gpa, args.config_path) catch return error.ConfigInvalid;
    defer config.deinit(gpa);
    return .{
        .nickname = try gpa.dupe(u8, config.node.nickname),
        .addresses = try myAddresses(gpa, config.network.port),
    };
}

// ---- Invites: join a device without showing the swarm key ----

const invite = nomadfs.device.invite;

var g_invite: ?*invite.Host = null;
var g_invite_code: ?[]u8 = null;
var g_invite_handled = false;
var g_invite_mutex: nomadfs.sync.Mutex = .{};

pub const InviteInfo = struct {
    /// "none", "waiting", "joined" or "expired".
    state: []const u8,
    code: []const u8,
    expires_in: u64,
    /// Who joined, once state is "joined".
    peer: []const u8,
    /// The code as a QR (SVG markup) while the invite is waiting, for
    /// another device's camera.
    qr_svg: []const u8,
};

/// `invite_create { config_path }`: opens a one-time invite (10 minutes,
/// one join) on the node port + 1 and returns its code. The code holds a
/// throwaway token, never the swarm key.
pub fn inviteCreate(gpa: std.mem.Allocator, args: ListArgs) !InviteInfo {
    var config = config_mod.parseConfig(gpa, args.config_path) catch return error.ConfigInvalid;
    defer config.deinit(gpa);
    var ip_buf: [16]u8 = undefined;
    const ip = primaryIp(&ip_buf) orelse return error.NoNetwork;
    const my_addr = try myAddresses(gpa, config.network.port);
    defer gpa.free(my_addr);
    const ticket = try pairTicket(gpa, .{ .config_path = args.config_path, .address = my_addr });

    g_invite_mutex.lock();
    defer g_invite_mutex.unlock();
    cancelInviteLocked();
    const host = try invite.Host.start(std.heap.page_allocator, .{
        .identity = try deviceIdentity(gpa, config.node.key_path),
        .swarm_key = config.node.swarm_key[0..32].*,
        .node_port = config.network.port,
        .ticket_uri = ticket.uri,
    }, try std.math.add(u16, config.network.port, 1), invite.default_lifetime_s, nomadfs.nowSeconds());
    errdefer host.destroy();
    var buf: [160]u8 = undefined;
    g_invite_code = try std.heap.page_allocator.dupe(u8, try host.code(ip, &buf));
    g_invite = host;
    g_invite_handled = false;
    return inviteInfoLocked(gpa, args.config_path);
}

/// `invite_status { config_path }`. When the invite has been used, the
/// joiner is trusted and remembered as a peer (once).
pub fn inviteStatus(gpa: std.mem.Allocator, args: ListArgs) !InviteInfo {
    g_invite_mutex.lock();
    defer g_invite_mutex.unlock();
    return inviteInfoLocked(gpa, args.config_path);
}

pub fn inviteCancel() void {
    g_invite_mutex.lock();
    defer g_invite_mutex.unlock();
    cancelInviteLocked();
}

fn cancelInviteLocked() void {
    if (g_invite) |host| host.destroy();
    g_invite = null;
    if (g_invite_code) |c| std.heap.page_allocator.free(c);
    g_invite_code = null;
}

fn inviteInfoLocked(gpa: std.mem.Allocator, config_path: []const u8) !InviteInfo {
    const host = g_invite orelse return .{ .state = "none", .code = "", .expires_in = 0, .peer = "", .qr_svg = "" };
    const now = nomadfs.nowSeconds();
    const state = host.status(now);
    var peer: []const u8 = "";
    if (state == .joined) {
        if (try host.joinedTicket(gpa)) |uri| {
            const ticket = Ticket.parseAt(uri, now) catch null;
            if (ticket) |t| peer = try gpa.dupe(u8, t.nicknameSlice());
            if (!g_invite_handled) {
                g_invite_handled = true;
                adoptPeer(gpa, config_path, uri) catch |err| std.debug.print("invite: adopting the joiner failed: {any}\n", .{err});
            }
        }
    }
    var qr_svg: []const u8 = "";
    if (state == .waiting) {
        var matrix = try nomadfs.device.qr.encode(gpa, g_invite_code orelse "", .medium);
        defer matrix.deinit();
        qr_svg = try nomadfs.device.qr.renderSvg(gpa, matrix, 4);
    }
    return .{
        .state = @tagName(state),
        .code = if (state == .waiting) try gpa.dupe(u8, g_invite_code orelse "") else "",
        .expires_in = if (host.expires_at > now) host.expires_at - now else 0,
        .peer = peer,
        .qr_svg = qr_svg,
    };
}

/// Trusts a device's pairing ticket and remembers its addresses as
/// bootstrap peers, dialing them now if the node is running.
fn adoptPeer(gpa: std.mem.Allocator, config_path: []const u8, ticket_uri: []const u8) !void {
    // The invite peer proved it holds this identity; when a newer ticket of
    // it is already pinned, keep that pin and still learn its addresses.
    trustDevice(gpa, .{ .config_path = config_path, .uri = ticket_uri }) catch |err| switch (err) {
        error.TicketStale => {},
        else => return err,
    };
    const ticket = try Ticket.parseAt(ticket_uri, nomadfs.nowSeconds());
    var urls: std.ArrayList([]const u8) = .empty;
    defer {
        for (urls.items) |u| gpa.free(u);
        urls.deinit(gpa);
    }
    var it = std.mem.splitScalar(u8, ticket.addressesSlice(), ',');
    while (it.next()) |addr| {
        const a = std.mem.trim(u8, addr, " ");
        if (a.len == 0 or std.mem.startsWith(u8, a, "127.")) continue;
        try urls.append(gpa, try std.fmt.allocPrint(gpa, "tcp://{s}", .{a}));
    }
    if (urls.items.len == 0) return;
    try addBootstrapPeers(gpa, config_path, urls.items);
    g_mutex.lock();
    defer g_mutex.unlock();
    if (g_node) |node| {
        const csv = try std.mem.joinZ(gpa, ",", urls.items);
        defer gpa.free(csv);
        _ = mobile.nomadfs_node_bootstrap(node, csv.ptr);
    }
}

/// Merges `urls` into the config's bootstrap_peers (no duplicates).
fn addBootstrapPeers(gpa: std.mem.Allocator, config_path: []const u8, urls: []const []const u8) !void {
    var config = config_mod.parseConfig(gpa, config_path) catch return error.ConfigInvalid;
    defer config.deinit(gpa);
    var line: std.ArrayList(u8) = .empty;
    defer line.deinit(gpa);
    try line.appendSlice(gpa, "bootstrap_peers = [");
    var first = true;
    for (config.network.bootstrap_peers) |p| {
        try line.print(gpa, "{s}\"{s}\"", .{ if (first) "" else ",", p });
        first = false;
    }
    for (urls) |u| {
        const dup = for (config.network.bootstrap_peers) |p| {
            if (std.mem.eql(u8, p, u)) break true;
        } else false;
        if (dup) continue;
        if (std.mem.indexOfAny(u8, u, "\"[]\n") != null) continue;
        try line.print(gpa, "{s}\"{s}\"", .{ if (first) "" else ",", u });
        first = false;
    }
    try line.append(gpa, ']');
    try editConfig(gpa, config_path, .{ .drop_keys = &.{"bootstrap_peers"}, .append = &.{line.items} });
}

pub const InviteAcceptArgs = struct { config_path: []const u8, code: []const u8 };

/// `invite_accept { config_path, code }`: joins the inviting device's
/// swarm through the one-time exchange, trusts it, remembers its address
/// and restarts the node with the new swarm key.
pub fn inviteAccept(gpa: std.mem.Allocator, args: InviteAcceptArgs) ![]const u8 {
    var config = config_mod.parseConfig(gpa, args.config_path) catch return error.ConfigInvalid;
    const port = config.network.port;
    const identity = deviceIdentity(gpa, config.node.key_path) catch |err| {
        config.deinit(gpa);
        return err;
    };
    config.deinit(gpa);

    const my_addr = try myAddresses(gpa, port);
    defer gpa.free(my_addr);
    const mine = try pairTicket(gpa, .{ .config_path = args.config_path, .address = my_addr });

    var joined = try invite.join(gpa, args.code, mine.uri, identity);
    defer joined.deinit(gpa);

    const was_running = isRunning();
    if (was_running) nodeClose();
    try writeSwarmKey(gpa, args.config_path, joined.swarm_key, 0);
    const url = try std.fmt.allocPrint(gpa, "tcp://{s}:{d}", .{ joined.host_ip, joined.node_port });
    defer gpa.free(url);
    try addBootstrapPeers(gpa, args.config_path, &.{url});
    trustDevice(gpa, .{ .config_path = args.config_path, .uri = joined.ticket_uri }) catch |err|
        std.debug.print("invite: trusting the inviter failed: {any}\n", .{err});
    if (was_running) try nodeOpen(gpa, .{ .config_path = args.config_path });

    const ticket = Ticket.parseAt(joined.ticket_uri, nomadfs.nowSeconds()) catch return gpa.dupe(u8, "");
    return gpa.dupe(u8, ticket.nicknameSlice());
}

// ---- Swarm key rotation ----

var g_config_path_buf: [std.fs.max_path_bytes]u8 = undefined;
var g_config_path_len: usize = 0;

fn rememberConfigPath(path: []const u8) void {
    const n = @min(path.len, g_config_path_buf.len);
    @memcpy(g_config_path_buf[0..n], path[0..n]);
    g_config_path_len = n;
}

var g_rotation_mutex: nomadfs.sync.Mutex = .{};
var g_rotation_worker_active: bool = false;
const PendingRotation = struct { key: [32]u8 = undefined, epoch: u64 = 0 };
var g_rotation: PendingRotation = .{};

/// A trusted device sent a new swarm key (already verified by the node).
/// Runs on a request thread: persist and restart from another thread, so
/// this request can still be answered.
fn onRotation(ctx: *anyopaque, new_key: [32]u8, epoch: u64) void {
    _ = ctx;
    g_rotation_mutex.lock();
    defer g_rotation_mutex.unlock();
    if (epoch <= g_rotation.epoch and g_rotation.epoch != 0) return;
    g_rotation.key = new_key;
    g_rotation.epoch = epoch;
    if (!g_rotation_worker_active) {
        g_rotation_worker_active = true;
        if (std.Thread.spawn(.{}, adoptRotationWorker, .{})) |t| {
            t.detach();
        } else |err| {
            g_rotation_worker_active = false;
            std.crypto.secureZero(u8, &g_rotation.key);
            g_rotation.epoch = 0;
            std.debug.print("rotation: failed to spawn worker: {any}\n", .{err});
        }
    }
}

fn adoptRotationWorker() void {
    nomadfs.sync.sleep(500 * std.time.ns_per_ms);
    const gpa = std.heap.page_allocator;

    while (true) {
        g_rotation_mutex.lock();
        if (g_rotation.epoch == 0) {
            g_rotation_worker_active = false;
            g_rotation_mutex.unlock();
            break;
        }
        var work_key = g_rotation.key;
        const work_epoch = g_rotation.epoch;
        std.crypto.secureZero(u8, &g_rotation.key);
        g_rotation.epoch = 0;
        g_rotation_mutex.unlock();

        defer std.crypto.secureZero(u8, &work_key);

        const path = blk: {
            g_mutex.lock();
            defer g_mutex.unlock();
            break :blk gpa.dupe(u8, g_config_path_buf[0..g_config_path_len]) catch null;
        } orelse continue;
        defer gpa.free(path);

        writeSwarmKey(gpa, path, work_key, work_epoch) catch |err| {
            std.debug.print("rotation: saving the new key failed: {any}\n", .{err});
            continue;
        };
        std.debug.print("rotation: adopted swarm key epoch {d}; restarting the node\n", .{work_epoch});
        nodeClose();
        nodeOpen(gpa, .{ .config_path = path }) catch |err| {
            std.debug.print("rotation: restart failed: {any}\n", .{err});
        };
    }
}

fn writeSwarmKey(gpa: std.mem.Allocator, path: []const u8, key: [32]u8, epoch: u64) !void {
    var hex: [64]u8 = undefined;
    _ = std.fmt.bufPrint(&hex, "{s}", .{std.fmt.bytesToHex(key, .lower)}) catch unreachable;
    defer std.crypto.secureZero(u8, &hex);
    const key_line = try std.fmt.allocPrint(gpa, "swarm_key = \"{s}\"", .{&hex});
    defer {
        @memset(key_line, 0);
        gpa.free(key_line);
    }
    const epoch_line = try std.fmt.allocPrint(gpa, "swarm_epoch = {d}", .{epoch});
    defer gpa.free(epoch_line);
    try editConfig(gpa, path, .{ .drop_keys = &.{ "swarm_key", "swarm_epoch" }, .append = &.{ key_line, epoch_line } });
}

pub const RotationEntry = struct { name: []const u8, status: []const u8 };

/// `swarm_rotate_key { config_path }`: a fresh swarm key for every trusted
/// device that can be reached now; this device adopts it and restarts.
/// Devices that aren't paired, or are offline, keep the old key and are
/// listed so they can be invited again.
pub fn swarmRotateKey(gpa: std.mem.Allocator, args: ListArgs) ![]RotationEntry {
    var config = config_mod.parseConfig(gpa, args.config_path) catch return error.ConfigInvalid;
    const epoch = config.node.swarm_epoch + 1;
    config.deinit(gpa);

    var key: [32]u8 = undefined;
    try std.Io.Threaded.global_single_threaded.io().randomSecure(&key);
    defer std.crypto.secureZero(u8, &key);

    const report = blk: {
        g_mutex.lock();
        defer g_mutex.unlock();
        const handle = g_node orelse return error.NotRunning;
        break :blk try handle.node.rotateSwarmKey(gpa, key, epoch);
    };
    try writeSwarmKey(gpa, args.config_path, key, epoch);
    nodeClose();
    try nodeOpen(gpa, .{ .config_path = args.config_path });

    const out = try gpa.alloc(RotationEntry, report.len);
    for (report, out) |r, *o| o.* = .{ .name = r.name, .status = @tagName(r.status) };
    return out;
}

pub const NicknameArgs = struct { config_path: []const u8, nickname: []const u8 };

/// `invoke("set_nickname", { config_path, nickname })`: how other devices
/// list this one. Takes effect on the next node start.
pub fn setNickname(gpa: std.mem.Allocator, args: NicknameArgs) !void {
    const nick = std.mem.trim(u8, args.nickname, " \t");
    if (nick.len == 0 or nick.len > 64 or std.mem.indexOfAny(u8, nick, "\"\n") != null) return error.InvalidNickname;
    const line = try std.fmt.allocPrint(gpa, "nickname = \"{s}\"", .{nick});
    defer gpa.free(line);
    try editConfig(gpa, args.config_path, .{ .drop_keys = &.{"nickname"}, .append = &.{line} });
}

fn primaryIp(buf: *[16]u8) ?[]const u8 {
    return nomadfs.device.invite.lanAddress(buf);
}

/// Every address this device is reachable at, with `port`, comma
/// separated: the LAN one first, then the others (Tailscale and other
/// VPNs), so a device that joins can also reach this one away from home.
fn myAddresses(gpa: std.mem.Allocator, port: u16) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var ip_buf: [16]u8 = undefined;
    if (primaryIp(&ip_buf)) |ip| try out.print(gpa, "{s}:{d}", .{ ip, port });
    var addrs: [8]nomadfs.net.compat.Address = undefined;
    const n = nomadfs.net.local_addrs.list(&addrs, port);
    for (addrs[0..n]) |a| {
        var text_buf: [64]u8 = undefined;
        const text = std.fmt.bufPrint(&text_buf, "{f}", .{a}) catch continue;
        if (std.mem.indexOf(u8, out.items, text) != null) continue;
        if (out.items.len > 0) try out.append(gpa, ',');
        try out.appendSlice(gpa, text);
    }
    if (out.items.len == 0) try out.print(gpa, "127.0.0.1:{d}", .{port});
    return out.toOwnedSlice(gpa);
}

const ConfigEdit = struct {
    /// Remove `key = ...` lines for these keys.
    drop_keys: []const []const u8 = &.{},
    /// Remove the `share = "<name>:..."` line for this share.
    drop_share: ?[]const u8 = null,
    /// Remove the `backup = "<name>"` line for this share.
    drop_backup: ?[]const u8 = null,
    append: []const []const u8 = &.{},
};

/// Rewrites the config file line by line: drops matching lines, appends
/// new ones. Comments and unrelated settings are kept as they are.
fn editConfig(gpa: std.mem.Allocator, path: []const u8, edit: ConfigEdit) !void {
    g_config_mutex.lock();
    defer g_config_mutex.unlock();

    const io = std.Io.Threaded.global_single_threaded.io();
    const old = blk: {
        var file = try std.Io.Dir.cwd().openFile(io, path, .{});
        defer file.close(io);
        const size = (try file.stat(io)).size;
        if (size > 64 * 1024) return error.ConfigTooLarge;
        const buf = try gpa.alloc(u8, @intCast(size));
        errdefer gpa.free(buf);
        _ = try file.readPositionalAll(io, buf, 0);
        break :blk buf;
    };
    defer gpa.free(old);

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    var lines = std.mem.splitScalar(u8, old, '\n');
    while (lines.next()) |line| {
        if (lines.index == null and line.len == 0) break; // trailing newline
        const trimmed = std.mem.trim(u8, line, " \t\r");
        const key = std.mem.trim(u8, trimmed[0 .. std.mem.indexOfScalar(u8, trimmed, '=') orelse 0], " \t");
        var drop = false;
        for (edit.drop_keys) |k| {
            if (std.mem.eql(u8, key, k)) drop = true;
        }
        if (edit.drop_share) |name| {
            if (std.mem.eql(u8, key, "share")) {
                const value = std.mem.trim(u8, trimmed[std.mem.indexOfScalar(u8, trimmed, '=').? + 1 ..], " \t\"");
                if (config_mod.Config.Share.parse(value)) |share| {
                    if (std.mem.eql(u8, share.name, name)) drop = true;
                } else |_| {}
            }
        }
        if (edit.drop_backup) |name| {
            if (std.mem.eql(u8, key, "backup")) {
                const value = std.mem.trim(u8, trimmed[std.mem.indexOfScalar(u8, trimmed, '=').? + 1 ..], " \t\"");
                if (std.mem.eql(u8, value, name)) drop = true;
            }
        }
        if (drop) continue;
        try out.appendSlice(gpa, line);
        try out.append(gpa, '\n');
    }
    for (edit.append) |line| {
        try out.appendSlice(gpa, line);
        try out.append(gpa, '\n');
    }

    try writeConfigAtomic(gpa, io, path, out.items);
}

const testing = std.testing;

test "commands: node put/get text round trip" {
    const io = std.Io.Threaded.global_single_threaded.io();
    const dir = "/tmp/nomadfs-gui-test";
    std.Io.Dir.cwd().deleteTree(io, dir) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};
    try std.Io.Dir.cwd().createDirPath(io, dir);
    try std.Io.Dir.cwd().createDirPath(io, dir ++ "/keys");
    try std.Io.Dir.cwd().createDirPath(io, dir ++ "/data");

    var conf_buf: [512]u8 = undefined;
    const conf_path = try std.fmt.bufPrint(&conf_buf, "{s}/nomadfs.conf", .{dir});
    // A self-contained config: no peers, writes stay local.
    var file = try std.Io.Dir.cwd().createFile(io, conf_path, .{ .truncate = true });
    defer file.close(io);
    var text_buf: [512]u8 = undefined;
    const conf = try std.fmt.bufPrint(&text_buf,
        \\[node]
        \\nickname = "gui-test"
        \\swarm_key = "00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff"
        \\key_path = "{s}/keys/node.key"
        \\[storage]
        \\enabled = true
        \\storage_path = "{s}/data"
        \\write_quorum = 0
        \\[network]
        \\port = 14799
        \\upnp_enabled = false
        \\enable_mdns = false
        \\
    , .{ dir, dir });
    try file.writePositionalAll(io, conf, 0);

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

test "commands: editConfig is atomic, serialized, and keeps private perms" {
    const io = std.Io.Threaded.global_single_threaded.io();
    const dir = "/tmp/nomadfs-gui-test-editconfig";
    std.Io.Dir.cwd().deleteTree(io, dir) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};
    try std.Io.Dir.cwd().createDirPath(io, dir);

    var conf_buf: [512]u8 = undefined;
    const conf_path = try std.fmt.bufPrint(&conf_buf, "{s}/nomadfs.conf", .{dir});
    var file = try std.Io.Dir.cwd().createFile(io, conf_path, .{ .truncate = true, .permissions = private_file_perms });
    try file.writePositionalAll(io, "nickname = \"alpha\"\nport = 14700\n", 0);
    file.close(io);

    const alloc = testing.allocator;
    try editConfig(alloc, conf_path, .{ .drop_keys = &.{"nickname"}, .append = &.{"nickname = \"beta\""} });

    // Verify .tmp was renamed and removed
    var tmp_buf: [512]u8 = undefined;
    const tmp_path = try std.fmt.bufPrint(&tmp_buf, "{s}.tmp", .{conf_path});
    try testing.expectError(error.FileNotFound, std.Io.Dir.cwd().statFile(io, tmp_path, .{}));

    // Verify contents
    var read_file = try std.Io.Dir.cwd().openFile(io, conf_path, .{});
    defer read_file.close(io);
    var content_buf: [512]u8 = undefined;
    const n = try read_file.readPositionalAll(io, &content_buf, 0);
    try testing.expectEqualStrings("port = 14700\nnickname = \"beta\"\n", content_buf[0..n]);
}

test "commands: ensureConfig sets private permissions on dir and file" {
    const io = std.Io.Threaded.global_single_threaded.io();
    const test_dir = "/tmp/nomadfs-gui-test-perms";
    std.Io.Dir.cwd().deleteTree(io, test_dir) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, test_dir) catch {};

    const alloc = testing.allocator;
    const conf_path = try std.fs.path.join(alloc, &.{ test_dir, "nomadfs.conf" });
    defer alloc.free(conf_path);

    try createConfig(alloc, io, test_dir, conf_path);

    if (builtin.os.tag == .linux) {
        // Verify dir permissions: 0700
        var dir = try std.Io.Dir.cwd().openDir(io, test_dir, .{});
        defer dir.close(io);
        const dir_stat = try dir.stat(io);
        try testing.expectEqual(@as(std.posix.mode_t, 0o700), @intFromEnum(dir_stat.permissions) & 0o777);

        // Verify config permissions: 0600
        var file = try std.Io.Dir.cwd().openFile(io, conf_path, .{});
        defer file.close(io);
        const file_stat = try file.stat(io);
        try testing.expectEqual(@as(std.posix.mode_t, 0o600), @intFromEnum(file_stat.permissions) & 0o777);
    }
}

test "commands: remote device fields populate trust, label and mount_name" {
    const gpa = testing.allocator;
    const peer = NodeID{ .bytes = [_]u8{0x12} ** 32 };
    const dev_id = NodeID{ .bytes = [_]u8{0x34} ** 32 };

    var fp_buf: [19]u8 = undefined;
    const fp_str = Identity.formatFingerprint(dev_id.bytes[0..8].*, &fp_buf);

    const dev = RemoteDevice{
        .peer = try hexAlloc(gpa, &peer.bytes),
        .nickname = try gpa.dupe(u8, "Alpha"),
        .shares = try gpa.alloc(RemoteShare, 0),
        .device_id = try hexAlloc(gpa, &dev_id.bytes),
        .fingerprint = try gpa.dupe(u8, fp_str),
        .trusted = false,
        .label = try gpa.dupe(u8, ""),
        .mount_name = try gpa.dupe(u8, "Alpha-34343434"),
    };
    defer {
        gpa.free(dev.peer);
        gpa.free(dev.nickname);
        gpa.free(dev.shares);
        gpa.free(dev.device_id);
        gpa.free(dev.fingerprint);
        gpa.free(dev.label);
        gpa.free(dev.mount_name);
    }

    try testing.expect(!dev.trusted);
    try testing.expectEqualStrings("", dev.label);
    try testing.expectEqualStrings("Alpha-34343434", dev.mount_name);
    try testing.expectEqualStrings("3434-3434-3434-3434", dev.fingerprint);
}

// ---- About ----

// ---- Read cache ----

pub const CacheInfo = struct {
    /// Bytes and blocks held in the read cache.
    bytes: u64,
    blocks: u64,
    /// The limit in MiB, 0 when there is none.
    limit_mb: u64,
};

pub const CacheLimitArgs = struct { config_path: []const u8, limit_mb: u64 };

/// The running node's store, or the one the config names (closed by the
/// caller) when no node runs.
fn withStore(gpa: std.mem.Allocator, config: config_mod.Config, owned: *?nomadfs.storage.engine.StorageEngine) !*nomadfs.storage.engine.StorageEngine {
    if (g_node) |handle| if (handle.node.store) |s| return s;
    if (!config.storage.enabled) return error.StorageDisabled;
    owned.* = try nomadfs.storage.engine.StorageEngine.init(gpa, config.storage.storage_path);
    return &owned.*.?;
}

/// `invoke("cache_info", { config_path })`: the read cache's size and limit.
pub fn cacheInfo(gpa: std.mem.Allocator, args: ListArgs) !CacheInfo {
    var config = config_mod.parseConfig(gpa, args.config_path) catch return error.ConfigInvalid;
    defer config.deinit(gpa);
    g_mutex.lock();
    defer g_mutex.unlock();
    var owned: ?nomadfs.storage.engine.StorageEngine = null;
    defer if (owned) |*o| o.deinit();
    const stats = (try withStore(gpa, config, &owned)).cacheStats();
    return .{ .bytes = stats.bytes, .blocks = stats.blocks, .limit_mb = config.storage.cache_mb };
}

/// `invoke("cache_clear", { config_path })`: empties the read cache and
/// returns the bytes freed. Blocks this device keeps are not touched.
pub fn cacheClear(gpa: std.mem.Allocator, args: ListArgs) !u64 {
    var config = config_mod.parseConfig(gpa, args.config_path) catch return error.ConfigInvalid;
    defer config.deinit(gpa);
    g_mutex.lock();
    defer g_mutex.unlock();
    var owned: ?nomadfs.storage.engine.StorageEngine = null;
    defer if (owned) |*o| o.deinit();
    return (try withStore(gpa, config, &owned)).clearCache();
}

/// `invoke("cache_set_limit", { config_path, limit_mb })`: saves `cache_mb`
/// and applies it to the running node at once (0 = no limit).
pub fn cacheSetLimit(gpa: std.mem.Allocator, args: CacheLimitArgs) !void {
    _ = std.math.mul(u64, args.limit_mb, 1024 * 1024) catch return error.InvalidLimit;
    var line_buf: [48]u8 = undefined;
    const line = try std.fmt.bufPrint(&line_buf, "cache_mb = {d}", .{args.limit_mb});
    try editConfig(gpa, args.config_path, .{ .drop_keys = &.{"cache_mb"}, .append = &.{line} });
    g_mutex.lock();
    defer g_mutex.unlock();
    if (g_node) |handle| if (handle.node.store) |s| {
        try s.setCacheLimit(if (args.limit_mb == 0) null else args.limit_mb * 1024 * 1024);
    };
}

pub const AboutInfo = struct {
    // Versions and how this build was made.
    nomadfs: []const u8,
    oriel: []const u8,
    zig: []const u8,
    commit: []const u8,
    mode: []const u8,
    platform: []const u8,
    /// Wayland or X11 on Linux desktops, "" elsewhere.
    session: []const u8,
    /// The running app (the AppImage when it runs from one); size 0 if unknown.
    app_path: []const u8,
    app_size: u64,
    // This device.
    running: bool,
    nickname: []const u8,
    fingerprint: []const u8,
    node_id: []const u8,
    port: u16,
    addresses: []const u8,
    devices_connected: usize,
    devices_trusted: usize,
    // Where its files are.
    config_path: []const u8,
    data_path: []const u8,
    data_size: u64,
    data_files: u64,
};

/// `about_info { config_path }`: what the About section shows.
pub fn aboutInfo(gpa: std.mem.Allocator, args: ListArgs, about: anytype) !AboutInfo {
    var config = config_mod.parseConfig(gpa, args.config_path) catch return error.ConfigInvalid;
    defer config.deinit(gpa);

    var paths = try DevicePaths.resolve(gpa, config.node.key_path);
    defer paths.deinit(gpa);
    const identity = try Identity.loadOrCreate(paths.identity);
    var fp_buf: [19]u8 = undefined;
    const fingerprint = Identity.formatFingerprint(identity.fingerprint(), &fp_buf);
    var store = try TrustStore.load(gpa, paths.trust, identity.seed());
    defer store.deinit();

    var running = false;
    var node_id: []const u8 = "";
    var connected: usize = 0;
    {
        g_mutex.lock();
        defer g_mutex.unlock();
        if (g_node) |handle| {
            running = true;
            node_id = try hexAlloc(gpa, &handle.node.connection_manager.node_id.bytes);
            const peers = fs.remote.knownPeers(handle.node.block_manager, gpa) catch &.{};
            connected = peers.len;
            gpa.free(peers);
        }
    }

    var data_size: u64 = 0;
    var data_files: u64 = 0;
    dirUsage(config.storage.storage_path, &data_size, &data_files);

    const app = appFile(gpa);
    return .{
        .nomadfs = about.version,
        .oriel = about.oriel_version,
        .zig = builtin.zig_version_string,
        .commit = about.commit,
        .mode = @tagName(builtin.mode),
        .platform = try std.fmt.allocPrint(gpa, "{s} {s}", .{ if (builtin.abi.isAndroid()) "Android" else @tagName(builtin.os.tag), @tagName(builtin.cpu.arch) }),
        .session = sessionType(),
        .app_path = app.path,
        .app_size = app.size,
        .running = running,
        .nickname = try gpa.dupe(u8, config.node.nickname),
        .fingerprint = try gpa.dupe(u8, fingerprint),
        .node_id = node_id,
        .port = config.network.port,
        .addresses = try myAddresses(gpa, config.network.port),
        .devices_connected = connected,
        .devices_trusted = store.list().len,
        .config_path = try gpa.dupe(u8, args.config_path),
        .data_path = try gpa.dupe(u8, config.storage.storage_path),
        .data_size = data_size,
        .data_files = data_files,
    };
}

fn sessionType() []const u8 {
    if (builtin.os.tag != .linux or builtin.abi.isAndroid()) return "";
    const t = std.c.getenv("XDG_SESSION_TYPE") orelse return "";
    return std.mem.span(t);
}

/// The file the app runs from: the AppImage when it runs from one.
fn appFile(gpa: std.mem.Allocator) struct { path: []const u8, size: u64 } {
    if (builtin.abi.isAndroid()) return .{ .path = "", .size = 0 };
    const io = std.Io.Threaded.global_single_threaded.io();
    var path: []const u8 = "";
    if (builtin.os.tag == .linux) {
        if (std.c.getenv("APPIMAGE")) |p| {
            path = gpa.dupe(u8, std.mem.span(p)) catch "";
        } else {
            var buf: [std.fs.max_path_bytes]u8 = undefined;
            const n = std.os.linux.readlink("/proc/self/exe", &buf, buf.len);
            if (std.os.linux.errno(n) == .SUCCESS) path = gpa.dupe(u8, buf[0..n]) catch "";
        }
    }
    if (path.len == 0) return .{ .path = "", .size = 0 };
    const st = std.Io.Dir.cwd().statFile(io, path, .{}) catch return .{ .path = path, .size = 0 };
    return .{ .path = path, .size = st.size };
}

/// Bytes and files under `path` (stops counting after 500 000 entries).
fn dirUsage(path: []const u8, size: *u64, files: *u64) void {
    const io = std.Io.Threaded.global_single_threaded.io();
    var dir = std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true }) catch return;
    defer dir.close(io);
    var walker = dir.walk(std.heap.page_allocator) catch return;
    defer walker.deinit();
    var seen: u64 = 0;
    while (walker.next(io) catch null) |entry| {
        seen += 1;
        if (seen > 500_000) break;
        if (entry.kind != .file) continue;
        const st = entry.dir.statFile(io, entry.basename, .{}) catch continue;
        size.* += st.size;
        files.* += 1;
    }
}
