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

    // Reach the devices this one joined (config bootstrap_peers).
    const peers = node.config.network.bootstrap_peers;
    if (peers.len > 0) {
        const csv = try std.mem.joinZ(gpa, ",", peers);
        defer gpa.free(csv);
        _ = mobile.nomadfs_node_bootstrap(node, csv.ptr);
    }
}

/// `invoke("node_close")`.
pub fn nodeClose() void {
    g_mutex.lock();
    defer g_mutex.unlock();
    stopMountLocked(); // the mount reads through this node
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
    {
        const io = std.Io.Threaded.global_single_threaded.io();
        const dir = try dataDir(gpa);
        defer gpa.free(dir);
        const keys_path = try std.fs.path.join(gpa, &.{ dir, "keys", "node.key" });
        defer gpa.free(keys_path);
        const storage_path_abs = try std.fs.path.join(gpa, &.{ dir, "data" });
        defer gpa.free(storage_path_abs);
        _ = std.Io.Dir.cwd().statFile(io, path, .{}) catch {
            var swarm: [64]u8 = undefined;
            var prng = std.Random.DefaultPrng.init(nomadfs.nowSeconds() * 7919);
            var rnd: [32]u8 = undefined;
            prng.random().bytes(&rnd);
            const swarm_key = std.fmt.bufPrint(&swarm, "{s}", .{std.fmt.bytesToHex(rnd, .lower)}) catch unreachable;
            try std.Io.Dir.cwd().createDirPath(io, std.fs.path.dirname(path) orelse "/");
            const keys_dir = try std.fs.path.join(gpa, &.{ dir, "keys" });
            defer gpa.free(keys_dir);
            try std.Io.Dir.cwd().createDirPath(io, keys_dir);
            var file = try std.Io.Dir.cwd().createFile(io, path, .{});
            defer file.close(io);
            var text: std.Io.Writer.Allocating = .init(gpa);
            defer text.deinit();
            var nick_buf: [64]u8 = undefined;
            try text.writer.print("\n[node]\nnickname = \"{s}\"\nswarm_key = \"{s}\"\nkey_path = \"{s}\"\n" ++
                "\n[storage]\nenabled = true\nstorage_path = \"{s}\"\n" ++
                "\n[network]\nport = 14700\ntransport = \"tcp\"\nupnp_enabled = false\n" ++
                "enable_mdns = false\nwrite_quorum = 0\nreplicas = 1\n", .{ defaultNickname(&nick_buf), swarm_key, keys_path, storage_path_abs });
            try file.writePositionalAll(io, text.written(), 0);
            return .{ .path = path, .created = true };
        };
    }
    return .{ .path = path, .created = false };
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

// ---- Shared folders ----

const fs = nomadfs.fs;

pub const ShareInfo = struct {
    name: []const u8,
    path: []const u8,
    files: u64,
    size: u64,
    /// False until the first scan finished; unscanned shares aren't listed
    /// to other devices yet.
    ready: bool,
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
    for (snapshot, out) |s, *o| {
        o.* = .{ .name = s.name, .path = s.path, .files = s.files, .size = s.size, .ready = s.root != null };
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

pub const ShareAddArgs = struct { config_path: []const u8, name: []const u8, path: []const u8 };

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
pub const RemoteDevice = struct { peer: []const u8, nickname: []const u8, shares: []RemoteShare };

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
    var out: std.ArrayList(RemoteDevice) = .empty;
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
        try out.append(gpa, .{ .peer = try hexAlloc(gpa, &peer.bytes), .nickname = shares.nickname, .shares = list });
    }
    return out.items;
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
    const n = try fs.tree.readAt(gpa, remote.loader(), cid, args.offset, buf);
    const encoder = std.base64.standard.Encoder;
    const out = try gpa.alloc(u8, encoder.calcSize(n));
    return encoder.encode(out, buf[0..n]);
}

// ---- Mounting (desktop Linux) ----

const can_mount = builtin.os.tag == .linux and !builtin.abi.isAndroid();

const MountJob = struct {
    mount: if (can_mount) fs.fuse.Mount else void,
    thread: std.Thread,
    path: [:0]u8,
    failed: std.atomic.Value(bool) = .init(false),
    done: std.atomic.Value(bool) = .init(false),
};

var g_mount: ?*MountJob = null;

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
    try std.Io.Dir.cwd().createDirPath(io, args.path);

    const job = try std.heap.page_allocator.create(MountJob);
    errdefer std.heap.page_allocator.destroy(job);
    job.* = .{
        .mount = try fs.fuse.Mount.init(std.heap.page_allocator, handle.node.block_manager, store),
        .thread = undefined,
        .path = try std.heap.page_allocator.dupeZ(u8, args.path),
    };
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
    if (can_mount) job.mount.deinit();
    std.heap.page_allocator.free(job.path);
    std.heap.page_allocator.destroy(job);
}

/// Whether /proc/self/mountinfo lists a NomadFS mount at `path`.
fn isMounted(gpa: std.mem.Allocator, path: []const u8) bool {
    const io = std.Io.Threaded.global_single_threaded.io();
    var file = std.Io.Dir.cwd().openFile(io, "/proc/self/mountinfo", .{}) catch return false;
    defer file.close(io);
    const buf = gpa.alloc(u8, 1024 * 1024) catch return false;
    defer gpa.free(buf);
    var len: usize = 0;
    while (len < buf.len) {
        const n = file.readStreaming(io, &.{buf[len..]}) catch return false;
        if (n == 0) break;
        len += n;
    }
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
        // Detach so the opener outlives nothing of ours.
        _ = linux.setsid();
        _ = linux.execve(program.ptr, &argv, envp);
        linux.exit(127);
    }
    var status: u32 = 0;
    _ = linux.wait4(@intCast(pid), &status, linux.W.NOHANG, null);
}

// ---- Joining devices ----

pub const JoinInfo = struct { nickname: []const u8, addresses: []const u8 };

/// `invoke("join_info", { config_path })`: this device's name and the
/// address other devices reach it at. (Never the swarm key: devices join
/// through one-time invites.)
pub fn joinInfo(gpa: std.mem.Allocator, args: ListArgs) !JoinInfo {
    var config = config_mod.parseConfig(gpa, args.config_path) catch return error.ConfigInvalid;
    defer config.deinit(gpa);
    var ip_buf: [16]u8 = undefined;
    const ip = primaryIp(&ip_buf) orelse "127.0.0.1";
    return .{
        .nickname = try gpa.dupe(u8, config.node.nickname),
        .addresses = try std.fmt.allocPrint(gpa, "{s}:{d}", .{ ip, config.network.port }),
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
    const my_addr = try std.fmt.allocPrint(gpa, "{s}:{d}", .{ ip, config.network.port });
    defer gpa.free(my_addr);
    const ticket = try pairTicket(gpa, .{ .config_path = args.config_path, .address = my_addr });

    g_invite_mutex.lock();
    defer g_invite_mutex.unlock();
    cancelInviteLocked();
    const host = try invite.Host.start(std.heap.page_allocator, .{
        .swarm_key = config.node.swarm_key[0..32].*,
        .node_port = config.network.port,
        .ticket_uri = ticket.uri,
    }, config.network.port +% 1, invite.default_lifetime_s, nomadfs.nowSeconds());
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
    try trustDevice(gpa, .{ .config_path = config_path, .uri = ticket_uri });
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
    config.deinit(gpa);

    var ip_buf: [16]u8 = undefined;
    const ip = primaryIp(&ip_buf) orelse "127.0.0.1";
    const my_addr = try std.fmt.allocPrint(gpa, "{s}:{d}", .{ ip, port });
    defer gpa.free(my_addr);
    const mine = try pairTicket(gpa, .{ .config_path = args.config_path, .address = my_addr });

    var joined = try invite.join(gpa, args.code, mine.uri);
    defer joined.deinit(gpa);

    const was_running = isRunning();
    if (was_running) nodeClose();
    const key_hex = std.fmt.bytesToHex(joined.swarm_key, .lower);
    const key_line = try std.fmt.allocPrint(gpa, "swarm_key = \"{s}\"", .{&key_hex});
    defer gpa.free(key_line);
    try editConfig(gpa, args.config_path, .{ .drop_keys = &.{"swarm_key"}, .append = &.{key_line} });
    const url = try std.fmt.allocPrint(gpa, "tcp://{s}:{d}", .{ joined.host_ip, joined.node_port });
    defer gpa.free(url);
    try addBootstrapPeers(gpa, args.config_path, &.{url});
    trustDevice(gpa, .{ .config_path = args.config_path, .uri = joined.ticket_uri }) catch |err|
        std.debug.print("invite: trusting the inviter failed: {any}\n", .{err});
    if (was_running) try nodeOpen(gpa, .{ .config_path = args.config_path });

    const ticket = Ticket.parseAt(joined.ticket_uri, nomadfs.nowSeconds()) catch return gpa.dupe(u8, "");
    return gpa.dupe(u8, ticket.nicknameSlice());
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

const ConfigEdit = struct {
    /// Remove `key = ...` lines for these keys.
    drop_keys: []const []const u8 = &.{},
    /// Remove the `share = "<name>:..."` line for this share.
    drop_share: ?[]const u8 = null,
    append: []const []const u8 = &.{},
};

/// Rewrites the config file line by line: drops matching lines, appends
/// new ones. Comments and unrelated settings are kept as they are.
fn editConfig(gpa: std.mem.Allocator, path: []const u8, edit: ConfigEdit) !void {
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
        if (drop) continue;
        try out.appendSlice(gpa, line);
        try out.append(gpa, '\n');
    }
    for (edit.append) |line| {
        try out.appendSlice(gpa, line);
        try out.append(gpa, '\n');
    }

    var file = try std.Io.Dir.cwd().createFile(io, path, .{ .truncate = true });
    defer file.close(io);
    try file.writePositionalAll(io, out.items, 0);
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
