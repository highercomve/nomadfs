const std = @import("std");
const builtin = @import("builtin");
const nomadfs = @import("nomadfs");
const config_mod = nomadfs.config;

const device = nomadfs.device;
const Identity = device.identity.Identity;
const Ticket = device.pairing.Ticket;

const upgrade = @import("upgrade.zig");

const Command = enum { run, pair, trust, devices, revoke, mount, webdav, invite, join, cache, clear_cache, bench_read, bench_idle, upgrade };

const Options = struct {
    command: Command = .run,
    config_path: ?[]const u8 = null,
    address: ?[]const u8 = null,
    trust_uri: ?[]const u8 = null,
    revoke_query: ?[]const u8 = null,
    join_code: ?[]const u8 = null,
    mountpoint: ?[]const u8 = null,
    /// --webdav <port>: serve WebDAV on 127.0.0.1 without mounting it.
    webdav_port: u16 = 0,
    /// --share Name:/path, added to the configured shares.
    shares: std.ArrayList([]const u8) = .empty,
    /// --copies <N>: the swarm's copies setting, signed into its policy.
    copies: ?u8 = null,
    /// --swarm-backup: keep a copy of the whole swarm folder.
    swarm_backup: bool = false,
    bench_read_path: ?[]const u8 = null,
    bench_wait_seconds: u32 = 30,
    bench_cold: bool = false,
    bench_idle_seconds: u32 = 0,
    upgrade: upgrade.Options = .{},
};

pub fn main(init: std.process.Init) !void {
    // A long-running node: outside Debug, the general-purpose allocator.
    // (Static ReleaseSafe builds would otherwise get std's DebugAllocator,
    // which records a stack trace for every allocation.)
    const allocator = if (@import("builtin").mode == .Debug) init.gpa else std.heap.smp_allocator;
    const args = try init.minimal.args.toSlice(init.arena.allocator());

    var options: Options = .{};
    if (!try parseArgs(init.arena.allocator(), args, &options)) return;
    // Needs no config: it replaces the binary.
    if (options.command == .upgrade) std.process.exit(try upgrade.run(init.io, allocator, options.upgrade));

    // The file found when none is given: commands that save to it (--join,
    // --invite, a rotated key) need to know which.
    if (options.config_path == null) options.config_path = config_mod.findConfigPath(init.arena.allocator()) catch null;
    var config = loadConfig(allocator, options.config_path) catch |err| {
        std.debug.print("Error: could not load configuration: {any}\n", .{err});
        std.process.exit(1);
    };
    defer config.deinit(allocator);
    try applyOptions(allocator, &config, options);

    switch (options.command) {
        .pair => try pairCommand(allocator, config, options.address),
        .trust => try trustCommand(allocator, config, options.trust_uri.?),
        .devices => try devicesCommand(allocator, config),
        .revoke => try revokeCommand(allocator, config, options.revoke_query.?),
        .run => try runNode(allocator, config, options),
        .mount => try mountCommand(allocator, config, options.mountpoint.?),
        .webdav => try webdavCommand(allocator, config, options.webdav_port, null),
        .invite => try inviteCommand(allocator, config, options.config_path, options.address),
        .join => try joinCommand(allocator, config, options.config_path, options.join_code.?, options.address),
        .cache => try cacheCommand(allocator, config, false),
        .clear_cache => try cacheCommand(allocator, config, true),
        .bench_read => try benchReadCommand(allocator, config, options.bench_read_path.?, options.bench_wait_seconds, options.bench_cold),
        .bench_idle => try benchIdleCommand(allocator, config, options.bench_idle_seconds),
        .upgrade => unreachable, // handled before the config loads
    }
}

/// What the command line adds to the config file.
fn applyOptions(allocator: std.mem.Allocator, config: *config_mod.Config, options: Options) !void {
    for (options.shares.items) |spec| {
        const share = config_mod.Config.Share.parse(spec) catch {
            std.debug.print("Error: --share expects Name:/path, got '{s}'\n", .{spec});
            std.process.exit(1);
        };
        try config.addShare(allocator, share.name, share.path);
    }
    if (options.swarm_backup) config.storage.swarm_backup = true;
    if (options.copies) |n| config.storage.set_copies = n;
}

/// Returns false when the command was fully handled (help).
fn parseArgs(arena: std.mem.Allocator, args: []const []const u8, options: *Options) !bool {
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (commandFlag(arg)) |command| {
            try selectCommand(options, command);
        } else if (std.mem.eql(u8, arg, "--config")) {
            options.config_path = try nextValue(args, &i, "--config");
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            printHelp();
            return false;
        } else if (std.mem.eql(u8, arg, "--version") or std.mem.eql(u8, arg, "-V")) {
            std.debug.print("nomadfs {s}\n", .{nomadfs.node_info.version});
            return false;
        } else if (switchFlag(arg, options)) {} else if (std.mem.eql(u8, arg, "--trust")) {
            try selectCommand(options, .trust);
            options.trust_uri = try nextValue(args, &i, "--trust");
        } else if (std.mem.eql(u8, arg, "--revoke")) {
            try selectCommand(options, .revoke);
            options.revoke_query = try nextValue(args, &i, "--revoke");
        } else if (std.mem.eql(u8, arg, "--join")) {
            try selectCommand(options, .join);
            options.join_code = try nextValue(args, &i, "--join");
        } else if (std.mem.eql(u8, arg, "--bench-read")) {
            try selectCommand(options, .bench_read);
            options.bench_read_path = try nextValue(args, &i, "--bench-read");
        } else if (std.mem.eql(u8, arg, "--bench-wait")) {
            const val_str = try nextValue(args, &i, "--bench-wait");
            options.bench_wait_seconds = std.fmt.parseInt(u32, val_str, 10) catch {
                std.debug.print("Error: --bench-wait expects an integer number of seconds\n", .{});
                std.process.exit(1);
            };
        } else if (std.mem.eql(u8, arg, "--bench-idle")) {
            try selectCommand(options, .bench_idle);
            const val_str = try nextValue(args, &i, "--bench-idle");
            options.bench_idle_seconds = std.fmt.parseInt(u32, val_str, 10) catch {
                std.debug.print("Error: --bench-idle expects an integer number of seconds\n", .{});
                std.process.exit(1);
            };
        } else if (std.mem.eql(u8, arg, "--mount")) {
            try selectCommand(options, .mount);
            options.mountpoint = try nextValue(args, &i, "--mount");
        } else if (std.mem.eql(u8, arg, "--webdav")) {
            try selectCommand(options, .webdav);
            const val_str = try nextValue(args, &i, "--webdav");
            options.webdav_port = std.fmt.parseInt(u16, val_str, 10) catch {
                std.debug.print("Error: --webdav expects a port (0 for any)\n", .{});
                std.process.exit(1);
            };
        } else if (std.mem.eql(u8, arg, "--share")) {
            try options.shares.append(arena, try nextValue(args, &i, "--share"));
        } else if (std.mem.eql(u8, arg, "--copies")) {
            const val_str = try nextValue(args, &i, "--copies");
            const n = std.fmt.parseInt(u8, val_str, 10) catch 0;
            if (n < 1 or n > nomadfs.device.policy.max_copies) {
                std.debug.print("Error: --copies expects 1-{d}\n", .{nomadfs.device.policy.max_copies});
                std.process.exit(1);
            }
            options.copies = n;
        } else if (std.mem.eql(u8, arg, "--address")) {
            options.address = try nextValue(args, &i, "--address");
        } else if (std.mem.startsWith(u8, arg, "-")) {
            std.debug.print("Error: Unknown option {s}\n", .{arg});
            std.process.exit(1);
        } else {
            if (options.config_path != null) {
                std.debug.print("Error: Multiple configuration paths provided\n", .{});
                std.process.exit(1);
            }
            options.config_path = arg;
        }
    }

    if ((options.upgrade.check or options.upgrade.yes) and options.command != .upgrade) {
        std.debug.print("Error: --check and --yes go with --upgrade\n", .{});
        std.process.exit(1);
    }
    if (options.address != null and options.command != .pair and options.command != .invite and options.command != .join) {
        std.debug.print("Error: --address is only valid with --pair, --invite or --join\n", .{});
        std.process.exit(1);
    }
    return true;
}

/// The flags that only pick a command.
fn commandFlag(arg: []const u8) ?Command {
    const flags = [_]struct { []const u8, Command }{
        .{ "--pair", .pair },   .{ "--devices", .devices },         .{ "--invite", .invite },
        .{ "--cache", .cache }, .{ "--clear-cache", .clear_cache }, .{ "--upgrade", .upgrade },
    };
    for (flags) |f| if (std.mem.eql(u8, arg, f[0])) return f[1];
    return null;
}

/// The on/off flags; false when `arg` isn't one.
fn switchFlag(arg: []const u8, options: *Options) bool {
    const eql = std.mem.eql;
    if (eql(u8, arg, "--check")) {
        options.upgrade.check = true;
    } else if (eql(u8, arg, "--yes") or eql(u8, arg, "-y")) {
        options.upgrade.yes = true;
    } else if (eql(u8, arg, "--bench-cold")) {
        options.bench_cold = true;
    } else if (eql(u8, arg, "--swarm-backup")) {
        options.swarm_backup = true;
    } else return false;
    return true;
}

fn nextValue(args: []const []const u8, index: *usize, flag: []const u8) ![]const u8 {
    if (index.* + 1 >= args.len) {
        std.debug.print("Error: {s} requires an argument\n", .{flag});
        std.process.exit(1);
    }
    index.* += 1;
    return args[index.*];
}

fn selectCommand(options: *Options, command: Command) !void {
    if (options.command != .run) {
        std.debug.print("Error: only one of --pair, --trust, --devices, --revoke, --mount, --webdav, --invite, --cache, --clear-cache, --bench-read, --bench-idle or --upgrade may be used\n", .{});
        std.process.exit(1);
    }
    options.command = command;
}

fn printHelp() void {
    std.debug.print(
        \\NomadFS - Private, decentralized distributed file system
        \\
        \\Usage:
        \\  nomadfs [options] [config_path]
        \\  nomadfs --pair [--address host:port] [config_path]
        \\  nomadfs --trust <nomadfs://pair?...> [config_path]
        \\  nomadfs --devices [config_path]
        \\  nomadfs --revoke <device-id-or-fingerprint> [config_path]
        \\  nomadfs --mount <dir> [config_path]
        \\  nomadfs --webdav <port> [config_path]
        \\  nomadfs --invite [--address ip] [config_path]
        \\  nomadfs --cache | --clear-cache [config_path]
        \\  nomadfs --bench-read <swarm path> [--bench-wait SECONDS] [--bench-cold] [config_path]
        \\  nomadfs --bench-idle SECONDS [config_path]
        \\  nomadfs --upgrade [--check] [--yes]
        \\  nomadfs --version
        \\
        \\Options:
        \\  --config <path>    Path to the configuration file
        \\  --pair             Print this device's pairing ticket and QR code
        \\  --address <addr>   Address(es) to publish in the ticket, comma separated
        \\  --trust <uri>      Verify and add a pairing ticket to the trust store
        \\  --devices          List trusted devices
        \\  --revoke <id>      Remove a trusted device by ID or fingerprint
        \\  --share Name:/path Share a folder with the swarm (repeatable; also
        \\                     `share = "Name:/path"` in the config)
        \\                     Mark a share for backup with `backup = "Name"`: every
        \\                     swarm backup device keeps a copy of it
        \\  --swarm-backup     Keep a copy of every swarm folder file on this device,
        \\                     so the folder stays readable while the device that
        \\                     added a file is offline (also `swarm_backup = true`
        \\                     under [storage])
        \\  --copies <N>       Keep each swarm folder file on N devices (1-8): the
        \\                     author and N-1 devices chosen for each file among
        \\                     those that accept copies (`accept_copies = false`
        \\                     under [storage] to refuse). A swarm-wide setting,
        \\                     signed by this device and sent to the others
        \\  --invite           Print a one-time invite code (10 min, one use) that
        \\                     lets another device join this swarm; the swarm key
        \\                     travels encrypted and is never shown
        \\  --join <code>      Join the swarm of the device showing this invite code:
        \\                     trusts it and saves the swarm key and its address
        \\                     in the config (restart a running node afterwards)
        \\  --mount <dir>      Run the node and mount the swarm folder at <dir>/Swarm
        \\                     (read and write) and every device's shares at
        \\                     <dir>/<device>/<share> (read only); files download
        \\                     on demand. Linux: FUSE (fusermount3). macOS: WebDAV
        \\                     mounted with mount_webdav. Windows: WebDAV on a drive
        \\                     letter (<dir> like Z:, or * for a free one)
        \\  --webdav <port>    Serve the same over WebDAV on 127.0.0.1:<port> without
        \\                     mounting it (0 picks a port)
        \\  --cache            Show the read cache: blocks fetched from other devices
        \\                     to be read, evicted least recently used first past
        \\                     `cache_mb` under [storage] (default 2048, 0 = no limit)
        \\  --clear-cache      Empty the read cache; what this device keeps (its
        \\                     writes, backups) is not touched
        \\  --bench-read <path> Read a swarm folder file in 1 MiB chunks and print benchmark stats
        \\  --bench-wait <sec>  Seconds to wait for swarm peer sync before bench read (default 30)
        \\  --bench-cold        Clear the read cache before benchmarking a read
        \\  --bench-idle <sec>  Run the node for SECONDS and print wire chatter totals
        \\  --upgrade          Replace this binary with the latest release, after
        \\                     checking its signature (asks first; --yes doesn't,
        \\                     --check only says whether there is one). A running
        \\                     node uses it once restarted
        \\  --version, -V      Print the version
        \\  --help, -h         Show this help message
        \\
    , .{});
}

fn loadConfig(allocator: std.mem.Allocator, config_path: ?[]const u8) !config_mod.Config {
    if (config_path) |path| {
        return config_mod.parseConfig(allocator, path) catch |err| {
            std.debug.print("Error: failed to parse config file '{s}': {any}\n", .{ path, err });
            return err;
        };
    }
    return config_mod.findAndParseConfig(allocator) catch |err| {
        std.debug.print("Error: could not find or parse a default configuration file: {any}\n", .{err});
        return err;
    };
}

/// Node.init, saying so when another node (the app, a service) already
/// runs on this config.
fn startNode(allocator: std.mem.Allocator, config: config_mod.Config) !nomadfs.Node {
    return nomadfs.Node.init(allocator, config) catch |err| {
        if (err == error.NodeAlreadyRunning) {
            std.debug.print("Error: a NomadFS node already runs on this configuration (the app or a service).\nStop it first, or use another --config.\n", .{});
            std.process.exit(1);
        }
        return err;
    };
}

/// The run loop's flag; cleared to stop (or restart) the node.
var node_running = std.atomic.Value(bool).init(true);
var restart_requested = std.atomic.Value(bool).init(false);
/// Saves keys trusted devices send; the node then restarts on them.
var rotation: nomadfs.key_rotation.Adopter = .{ .restart = .{ .restartFn = requestRestart } };

fn requestRestart(_: ?*anyopaque, _: []const u8) void {
    restart_requested.store(true, .release);
    node_running.store(false, .release);
}

/// Runs the node until it stops; a rotated swarm key restarts it on the
/// re-read config.
fn runNode(allocator: std.mem.Allocator, first: config_mod.Config, options: Options) !void {
    try runOnce(allocator, first, options.config_path);
    while (restart_requested.swap(false, .acq_rel)) {
        var config = try loadConfig(allocator, options.config_path);
        defer config.deinit(allocator);
        try applyOptions(allocator, &config, options);
        node_running.store(true, .release);
        try runOnce(allocator, config, options.config_path);
    }
}

fn runOnce(allocator: std.mem.Allocator, config: config_mod.Config, config_path: ?[]const u8) !void {
    std.debug.print("NomadFS Node: {s} (Storage: {any})\n", .{ config.node.nickname, config.storage.enabled });
    std.debug.print("Listening on port: {d}\n", .{config.network.port});
    if (config.storage.swarm_backup) std.debug.print("Backing up the swarm folder on this device\n", .{});

    var node = try startNode(allocator, config);
    defer node.deinit();
    // Without a config file (none given, none found) there's nowhere to
    // save a rotated key.
    if (config_path) |path| try rotation.watch(&node, path);

    std.debug.print("Node Initialized. Local ID: {x}\n", .{node.connection_manager.node_id.bytes});
    std.debug.print("Device ID: {x}\n", .{node.device_identity.deviceId().bytes});
    node.bootstrap(config.network.bootstrap_peers, config.node.swarm_key) catch |err| {
        std.debug.print("Bootstrap error: {any}\n", .{err});
    };
    try node.run(&node_running, config);
}

var mounted_at: [std.fs.max_path_bytes:0]u8 = undefined;
var mounted_len: usize = 0;

fn onStopSignal(_: std.os.linux.SIG) callconv(.c) void {
    // Unmounting makes the FUSE loop return, which shuts the node down.
    if (mounted_len > 0) nomadfs.fs.fuse.unmount(mounted_at[0..mounted_len :0]);
}

fn mountCommand(allocator: std.mem.Allocator, config: config_mod.Config, mountpoint: []const u8) !void {
    if (comptime @hasDecl(nomadfs.fs.fuse, "Mount")) return mountLinux(allocator, config, mountpoint);
    if (comptime !nomadfs.webdav_mount.supported) {
        std.debug.print("Error: --mount isn't supported here; --webdav <port> serves the same over WebDAV\n", .{});
        std.process.exit(1);
    }
    return webdavCommand(allocator, config, 0, mountpoint);
}

/// Set by Ctrl-C (or the console closing): the WebDAV command ends.
var webdav_stop = std.atomic.Value(bool).init(false);

fn onWebDavStop(_: std.posix.SIG) callconv(.c) void {
    webdav_stop.store(true, .release);
}

/// Set once the WebDAV mount is unmounted and stopped.
var webdav_done = std.atomic.Value(bool).init(false);

fn onWebDavConsole(event: u32) callconv(.winapi) c_int {
    webdav_stop.store(true, .release);
    // Closing the window, logoff, shutdown: the process ends when this
    // returns, so wait (Windows allows 5 seconds) for `net use /delete`.
    const close_event = 2;
    const logoff_event = 5;
    const shutdown_event = 6;
    if (event == close_event or event == logoff_event or event == shutdown_event) {
        var waited: u32 = 0;
        while (!webdav_done.load(.acquire) and waited < 4500) : (waited += 50) nomadfs.sync.sleep(50 * std.time.ns_per_ms);
    }
    return 1;
}

extern "kernel32" fn SetConsoleCtrlHandler(handler: ?*const fn (u32) callconv(.winapi) c_int, add: c_int) callconv(.winapi) c_int;

/// macOS, Windows (and anywhere with --webdav): the node and a WebDAV
/// server on 127.0.0.1, mounted at `mountpoint` when given (a folder on
/// macOS, a drive letter like Z: on Windows), until Ctrl-C.
fn webdavCommand(allocator: std.mem.Allocator, config: config_mod.Config, port: u16, mountpoint: ?[]const u8) !void {
    var live: LiveNode = undefined;
    try live.start(allocator, config, "--mount and --webdav");
    defer live.stop();
    if (builtin.os.tag == .windows) {
        _ = SetConsoleCtrlHandler(onWebDavConsole, 1);
    } else {
        const action = std.posix.Sigaction{ .handler = .{ .handler = onWebDavStop }, .mask = std.posix.sigemptyset(), .flags = 0 };
        std.posix.sigaction(.INT, &action, null);
        std.posix.sigaction(.TERM, &action, null);
    }
    const mount = live.node.startWebDav(allocator, port, mountpoint) catch |err| {
        std.debug.print("Error: couldn't start the mount: {s}\n", .{@errorName(err)});
        if (builtin.os.tag == .windows and mountpoint != null) std.debug.print("Windows mounts WebDAV with its WebClient service: start it (services.msc), or use --webdav <port> and connect from Explorer.\n", .{});
        return err;
    };
    defer {
        mount.stop();
        webdav_done.store(true, .release);
    }
    if (mount.at) |at| {
        std.debug.print("Mounted at {s}, served at {s} (Ctrl-C to unmount)\n", .{ at, mount.url() });
    } else {
        std.debug.print("WebDAV at {s}: the swarm folder (read and write) and every device's shares (Ctrl-C to stop)\n", .{mount.url()});
    }
    while (!webdav_stop.load(.acquire)) nomadfs.sync.sleep(200 * std.time.ns_per_ms);
}

/// A node started, bootstrapped and running on its own thread, for the
/// commands that serve it (--mount, --webdav).
const LiveNode = struct {
    node: nomadfs.Node,
    running: std.atomic.Value(bool),
    thread: std.Thread,

    fn start(self: *LiveNode, allocator: std.mem.Allocator, config: config_mod.Config, what: []const u8) !void {
        if (!config.storage.enabled) {
            std.debug.print("Error: {s} needs storage enabled (fetched blocks are cached there)\n", .{what});
            std.process.exit(1);
        }
        self.node = try startNode(allocator, config);
        errdefer self.node.deinit();
        std.debug.print("NomadFS {s}: device {x}\n", .{ config.node.nickname, self.node.device_identity.deviceId().bytes[0..6] });
        self.node.bootstrap(config.network.bootstrap_peers, config.node.swarm_key) catch |err| {
            std.debug.print("Bootstrap error: {any}\n", .{err});
        };
        self.running = .init(true);
        self.thread = try std.Thread.spawn(.{}, runUntilStopped, .{ &self.node, &self.running, config });
    }

    fn stop(self: *LiveNode) void {
        self.running.store(false, .release);
        self.thread.join();
        self.node.deinit();
    }
};

fn mountLinux(allocator: std.mem.Allocator, config: config_mod.Config, mountpoint: []const u8) !void {
    var live: LiveNode = undefined;
    try live.start(allocator, config, "--mount");
    defer live.stop();

    if (mountpoint.len >= mounted_at.len) return error.NameTooLong;
    @memcpy(mounted_at[0..mountpoint.len], mountpoint);
    mounted_at[mountpoint.len] = 0;
    mounted_len = mountpoint.len;
    const handler = std.os.linux.Sigaction{
        .handler = .{ .handler = onStopSignal },
        .mask = std.os.linux.sigemptyset(),
        .flags = 0,
    };
    _ = std.os.linux.sigaction(.INT, &handler, null);
    _ = std.os.linux.sigaction(.TERM, &handler, null);

    try nomadfs.fs.fuse.prepareMountpoint(allocator, mountpoint);
    var mount = try live.node.newMount(allocator);
    defer mount.deinit();
    std.debug.print("Mounted at {s} (Ctrl-C to unmount)\n", .{mountpoint});
    mount.serve(mountpoint) catch |err| {
        std.debug.print("Error: mount failed: {any}\n", .{err});
        if (err == error.FusermountNotFound) std.debug.print("Install fuse3 (fusermount3).\n", .{});
        return err;
    };
    std.debug.print("Unmounted.\n", .{});
}

fn runUntilStopped(node: *nomadfs.Node, running: *std.atomic.Value(bool), config: config_mod.Config) void {
    node.run(running, config) catch |err| {
        std.debug.print("Node stopped: {any}\n", .{err});
    };
}

fn inviteCommand(allocator: std.mem.Allocator, config: config_mod.Config, config_path: ?[]const u8, address: ?[]const u8) !void {
    var ip_buf: [16]u8 = undefined;
    const ip = address orelse device.invite.lanAddress(&ip_buf) orelse "127.0.0.1";
    var addr_buf: [64]u8 = undefined;
    // The ticket lists every address this device has (LAN, VPNs) unless
    // --address picks one.
    const node_addr = if (address != null) try std.fmt.bufPrint(&addr_buf, "{s}:{d}", .{ ip, config.network.port }) else "";

    var membership = try device.membership.Membership.open(allocator, config);
    defer membership.close();
    const opened = try membership.startInvite(ip, node_addr, nowSeconds());

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try out.writer.print("Invite (one use, expires in {d} minutes). Scan it with the NomadFS app\n(Connect devices > Scan QR code) or enter the code:\n\n", .{device.invite.default_lifetime_s / 60});
    var matrix = try device.qr.encode(allocator, opened.code, .medium);
    defer matrix.deinit();
    try device.qr.renderAscii(matrix, &out.writer, .{});
    try out.writer.print("\n{s}\n\nWaiting for the other device...\n", .{opened.code});
    try writeStdout(out.written());

    // The service trusts the joiner the first time it sees the join; a node
    // running on this config picks it up from the trust store.
    while (true) {
        nomadfs.sync.sleep(500 * std.time.ns_per_ms);
        const st = membership.inviteStatus(nowSeconds());
        switch (st.state) {
            .waiting => continue,
            .expired, .none => {
                std.debug.print("Invite expired.\n", .{});
                return;
            },
            .joined => {
                const joiner = st.joined orelse return;
                if (config_path) |path| nomadfs.settings.rememberPeer(allocator, path, &joiner) catch |err|
                    std.debug.print("Saving its addresses failed: {any}\n", .{err});
                var fp_buf: [19]u8 = undefined;
                std.debug.print("{s} joined ({s}, {s}) and is now trusted.\n", .{
                    joiner.nicknameSlice(),
                    Identity.formatFingerprint(joiner.fingerprint(), &fp_buf),
                    joiner.addressesSlice(),
                });
                return;
            },
        }
    }
}

fn joinCommand(allocator: std.mem.Allocator, config: config_mod.Config, config_path: ?[]const u8, code: []const u8, address: ?[]const u8) !void {
    const path = config_path orelse {
        std.debug.print("Error: no configuration file to save the swarm key in; use --config <file>\n", .{});
        std.process.exit(1);
    };
    var ip_buf: [16]u8 = undefined;
    const ip = address orelse device.invite.lanAddress(&ip_buf) orelse "127.0.0.1";
    var addr_buf: [64]u8 = undefined;
    // The ticket lists every address this device has (LAN, VPNs) unless
    // --address picks one.
    const node_addr = if (address != null) try std.fmt.bufPrint(&addr_buf, "{s}:{d}", .{ ip, config.network.port }) else "";

    var membership = try device.membership.Membership.open(allocator, config);
    defer membership.close();
    const joined = nomadfs.settings.joinSwarm(allocator, path, &membership, code, node_addr, nowSeconds()) catch |err| {
        std.debug.print("Error: joining failed: {any}\n", .{err});
        return err;
    };
    var fp_buf: [19]u8 = undefined;
    std.debug.print("Joined the swarm of {s} ({s}) at {s}; it is now trusted.\nRestart the node to use the new swarm key.\n", .{
        joined.inviter.nicknameSlice(),
        Identity.formatFingerprint(joined.inviter.fingerprint(), &fp_buf),
        joined.peer(),
    });
}

fn pairCommand(allocator: std.mem.Allocator, config: config_mod.Config, address: ?[]const u8) !void {
    var membership = try device.membership.Membership.open(allocator, config);
    defer membership.close();
    const ticket = try membership.ticket(address orelse "", nowSeconds());

    var uri_buf: [device.pairing.max_uri_len]u8 = undefined;
    const uri = try ticket.toUri(&uri_buf);
    var fingerprint_buf: [19]u8 = undefined;
    const fingerprint = Identity.formatFingerprint(ticket.fingerprint(), &fingerprint_buf);

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try out.writer.print(
        "Device: {s}\nFingerprint: {s}\nAddresses: {s}\nExpires: {d}\n\n{s}\n\n",
        .{ ticket.nicknameSlice(), fingerprint, ticket.addressesSlice(), ticket.expires_at, uri },
    );
    var matrix = try ticket.qrMatrix(allocator, .medium);
    defer matrix.deinit();
    try device.qr.renderAscii(matrix, &out.writer, .{});
    try writeStdout(out.written());
}

fn trustCommand(allocator: std.mem.Allocator, config: config_mod.Config, uri: []const u8) !void {
    var membership = try device.membership.Membership.open(allocator, config);
    defer membership.close();
    const trusted = membership.trustUri(uri, nowSeconds()) catch |err| {
        switch (err) {
            error.StaleTicket => std.debug.print("Refused: a newer ticket for this device is already trusted. Ask it for a fresh one.\n", .{}),
            else => std.debug.print("Error: ticket rejected: {any}\n", .{err}),
        }
        return err;
    };
    var fingerprint_buf: [19]u8 = undefined;
    std.debug.print("{s} device '{s}' ({s}) at {s}\n", .{
        if (trusted.added) "Trusted" else "Refreshed",
        trusted.ticket.nicknameSlice(),
        Identity.formatFingerprint(trusted.ticket.fingerprint(), &fingerprint_buf),
        membership.trust.path,
    });
}

/// `--cache` / `--clear-cache`: works on the store directly, so it runs
/// while a node is running too (the node recounts before it reports).
fn cacheCommand(allocator: std.mem.Allocator, config: config_mod.Config, clear: bool) !void {
    if (!config.storage.enabled) {
        std.debug.print("Storage is disabled in this configuration.\n", .{});
        return;
    }
    if (clear) {
        const freed = try nomadfs.settings.cacheClear(allocator, config, null);
        var buf: [32]u8 = undefined;
        std.debug.print("Cleared the read cache: freed {s}.\n", .{formatBytes(&buf, freed)});
        return;
    }
    const info = try nomadfs.settings.cacheInfo(allocator, config, null);
    var used_buf: [32]u8 = undefined;
    var limit_buf: [32]u8 = undefined;
    const limit = if (info.limit_mb == 0) "no limit" else formatBytes(&limit_buf, info.limit_mb * 1024 * 1024);
    std.debug.print("Read cache: {s} in {d} blocks (limit {s})\n", .{ formatBytes(&used_buf, info.bytes), info.blocks, limit });
}

fn formatBytes(buf: []u8, bytes: u64) []const u8 {
    const units = [_][]const u8{ "B", "KiB", "MiB", "GiB", "TiB" };
    var value: f64 = @floatFromInt(bytes);
    var unit: usize = 0;
    while (value >= 1024 and unit + 1 < units.len) : (unit += 1) value /= 1024;
    return (if (unit == 0)
        std.fmt.bufPrint(buf, "{d} B", .{bytes})
    else
        std.fmt.bufPrint(buf, "{d:.1} {s}", .{ value, units[unit] })) catch "?";
}

fn devicesCommand(allocator: std.mem.Allocator, config: config_mod.Config) !void {
    var membership = try device.membership.Membership.open(allocator, config);
    defer membership.close();
    const entries = try membership.devices(allocator);
    defer allocator.free(entries);
    if (entries.len == 0) {
        std.debug.print("No trusted devices in {s}\n", .{membership.trust.path});
        return;
    }
    std.debug.print("Trusted devices in {s}:\n", .{membership.trust.path});
    for (entries) |*entry| {
        var fingerprint_buf: [19]u8 = undefined;
        std.debug.print("  {s}  {s}  added {d}  [{x}]\n", .{
            Identity.formatFingerprint(entry.fingerprint(), &fingerprint_buf),
            entry.labelSlice(),
            entry.added_at,
            entry.device_id.bytes[0..4],
        });
    }
}

fn revokeCommand(allocator: std.mem.Allocator, config: config_mod.Config, query: []const u8) !void {
    var membership = try device.membership.Membership.open(allocator, config);
    defer membership.close();
    // Signed with this device's identity, so peers can verify who revoked.
    const revoked = membership.revoke(query, nowSeconds()) catch |err| {
        switch (err) {
            error.InvalidDeviceQuery => std.debug.print("Error: '{s}' is not a hex device ID or fingerprint\n", .{query}),
            error.AmbiguousDeviceQuery => std.debug.print("Error: '{s}' matches more than one device; use the full device ID\n", .{query}),
            error.DeviceNotFound => std.debug.print("No trusted device matches '{s}' in {s}\n", .{ query, membership.trust.path }),
            else => return err,
        }
        std.process.exit(1);
    };
    std.debug.print("Revoked device '{s}' from {s}{s}\n", .{
        query,
        membership.trust.path,
        if (revoked.removed) "" else " (tombstone recorded; no local entry)",
    });
}

const nowSeconds = nomadfs.sync.nowSeconds;

fn writeStdout(bytes: []const u8) !void {
    const io = std.Io.Threaded.global_single_threaded.io();
    try std.Io.File.stdout().writeStreamingAll(io, bytes);
}

fn benchReadCommand(allocator: std.mem.Allocator, config: config_mod.Config, raw_path: []const u8, wait_seconds: u32, cold: bool) !void {
    var node = try startNode(allocator, config);
    defer node.deinit();

    var running = std.atomic.Value(bool).init(true);
    node.bootstrap(config.network.bootstrap_peers, config.node.swarm_key) catch |err| {
        std.debug.print("Bootstrap error: {any}\n", .{err});
    };
    try node.listen(&running, config);
    defer node.stopListener();

    const swarm = node.swarm orelse {
        std.debug.print("Error: swarm folder not available (storage disabled?)\n", .{});
        std.process.exit(1);
    };

    const deadline = nomadfs.sync.monotonicMillis() + @as(i64, wait_seconds) * std.time.ms_per_s;
    while (nomadfs.sync.monotonicMillis() < deadline) {
        if (swarm.status().peers_synced > 0) break;
        nomadfs.sync.sleep(50 * std.time.ns_per_ms);
        if (node.connection_manager.getConnectionsCount() > 0) {
            _ = swarm.syncNow() catch {};
        }
    }

    var path = raw_path;
    while (path.len > 0 and path[0] == '/') path = path[1..];
    swarm.mutex.lock();
    const entry_opt = swarm.fileInfo(path);
    swarm.mutex.unlock();
    const entry = entry_opt orelse {
        std.debug.print("Error: swarm entry '{s}' not found\n", .{raw_path});
        std.process.exit(1);
    };

    // A device behind NAT is reached only once it connects to this one
    // (a relay in the cloud): wait for the author, so the clock times the
    // read, not the reconnection.
    const author: nomadfs.net.id.NodeID = .{ .bytes = entry.author };
    const connect_deadline = nomadfs.sync.monotonicMillis() + @as(i64, wait_seconds) * std.time.ms_per_s;
    while (nomadfs.sync.monotonicMillis() < connect_deadline) {
        if (node.connection_manager.existingConnection(author)) |conn| {
            conn.deinit();
            break;
        }
        nomadfs.sync.sleep(200 * std.time.ns_per_ms);
    }

    if (cold) {
        if (node.store) |s| {
            _ = s.clearCache() catch {};
        }
    }

    const fetcher = if (node.block_manager.fetcher) |*f| f else {
        std.debug.print("Error: fetcher not available\n", .{});
        std.process.exit(1);
    };

    var before_peer_buf: [64]nomadfs.cluster.Fetcher.PeerState = undefined;
    const before_snap = fetcher.snapshot(&before_peer_buf);
    const before_totals = fetcher.totals();
    const before_traffic = node.connection_manager.trafficTotals();

    const chunk_size: usize = 1024 * 1024;
    const buf = try allocator.alloc(u8, chunk_size);
    defer allocator.free(buf);

    const io = std.Io.Threaded.global_single_threaded.io();
    const t0 = std.Io.Clock.awake.now(io).nanoseconds;
    const source: nomadfs.Node.FileSource = .{ .swarm = .{ .cid = entry.cid, .author = entry.author } };
    var offset: u64 = 0;
    while (offset < entry.size) {
        const to_read = @min(@as(u64, chunk_size), entry.size - offset);
        const n = try node.readFile(allocator, source, offset, buf[0..@intCast(to_read)]);
        if (n == 0) break;
        offset += n;
    }
    const t1 = std.Io.Clock.awake.now(io).nanoseconds;
    const elapsed_ns = @max(t1 - t0, 0);

    const after_traffic = node.connection_manager.trafficTotals();
    const after_totals = fetcher.totals();
    var after_peer_buf: [64]nomadfs.cluster.Fetcher.PeerState = undefined;
    const after_snap = fetcher.snapshot(&after_peer_buf);

    const seconds = @as(f64, @floatFromInt(elapsed_ns)) / @as(f64, @floatFromInt(std.time.ns_per_s));
    const mib_per_s = if (seconds > 0) (@as(f64, @floatFromInt(offset)) / (1024.0 * 1024.0)) / seconds else 0.0;
    const wire_sent = after_traffic.sent -| before_traffic.sent;
    const wire_received = after_traffic.received -| before_traffic.received;
    const fetched_blocks = after_totals.fetched -| before_totals.fetched;
    const fetched_bytes = after_totals.fetched_bytes -| before_totals.fetched_bytes;
    const local_blocks = after_totals.local -| before_totals.local;
    const not_found = after_totals.not_found -| before_totals.not_found;
    const failed = after_totals.failed -| before_totals.failed;

    const main_lines = try std.fmt.allocPrint(allocator,
        \\bytes={d}
        \\seconds={d:.3}
        \\mib_per_s={d:.2}
        \\wire_sent={d}
        \\wire_received={d}
        \\fetched_blocks={d}
        \\fetched_bytes={d}
        \\local_blocks={d}
        \\not_found={d}
        \\failed={d}
        \\
    , .{
        offset,
        seconds,
        mib_per_s,
        wire_sent,
        wire_received,
        fetched_blocks,
        fetched_bytes,
        local_blocks,
        not_found,
        failed,
    });
    defer allocator.free(main_lines);
    try writeStdout(main_lines);

    for (after_snap) |ap| {
        var prev_blocks: u64 = 0;
        var prev_bytes: u64 = 0;
        for (before_snap) |bp| {
            if (bp.id.eql(ap.id)) {
                prev_blocks = bp.blocks;
                prev_bytes = bp.bytes;
                break;
            }
        }
        const delta_blocks = ap.blocks -| prev_blocks;
        const delta_bytes = ap.bytes -| prev_bytes;
        const hex_id = std.fmt.bytesToHex(ap.id.bytes[0..4].*, .lower);
        const peer_line = try std.fmt.allocPrint(allocator, "peer={s} blocks={d} bytes={d} rate_kib_s={d}\n", .{
            hex_id,
            delta_blocks,
            delta_bytes,
            ap.rate,
        });
        defer allocator.free(peer_line);
        try writeStdout(peer_line);
    }
}

fn benchIdleCommand(allocator: std.mem.Allocator, config: config_mod.Config, seconds: u32) !void {
    var node = try startNode(allocator, config);
    defer node.deinit();

    var running = std.atomic.Value(bool).init(true);
    node.bootstrap(config.network.bootstrap_peers, config.node.swarm_key) catch |err| {
        std.debug.print("Bootstrap error: {any}\n", .{err});
    };
    try node.listen(&running, config);
    defer node.stopListener();

    const before = node.connection_manager.trafficTotals();
    nomadfs.sync.sleep(@as(u64, seconds) * std.time.ns_per_s);
    const after = node.connection_manager.trafficTotals();

    const wire_sent = after.sent -| before.sent;
    const wire_received = after.received -| before.received;

    const out = try std.fmt.allocPrint(allocator,
        \\wire_sent={d}
        \\wire_received={d}
        \\
    , .{ wire_sent, wire_received });
    defer allocator.free(out);
    try writeStdout(out);
}
