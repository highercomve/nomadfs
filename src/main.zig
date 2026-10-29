const std = @import("std");
const nomadfs = @import("nomadfs");
const config_mod = nomadfs.config;

const device = nomadfs.device;
const Identity = device.identity.Identity;
const Ticket = device.pairing.Ticket;
const TrustStore = device.trust.Store;
const DevicePaths = device.paths.Paths;

/// Pairing tickets are short-lived on purpose: the transport key inside them
/// rotates, and an old QR code should not grant access forever.
const ticket_lifetime_seconds = 24 * 60 * 60;

const Command = enum { run, pair, trust, devices, revoke, mount, invite, cache, clear_cache, bench_read, bench_idle };

const Options = struct {
    command: Command = .run,
    config_path: ?[]const u8 = null,
    address: ?[]const u8 = null,
    trust_uri: ?[]const u8 = null,
    revoke_query: ?[]const u8 = null,
    mountpoint: ?[]const u8 = null,
    /// --share Name:/path, added to the configured shares.
    shares: std.ArrayList([]const u8) = .empty,
    /// --swarm-backup: keep a copy of the whole swarm folder.
    /// --swarm-replicas <N>: push new/updated swarm folder files to N peers.
    copies: ?u8 = null,
    swarm_backup: bool = false,
    bench_read_path: ?[]const u8 = null,
    bench_wait_seconds: u32 = 30,
    bench_cold: bool = false,
    bench_idle_seconds: u32 = 0,
};

pub fn main(init: std.process.Init) !void {
    // A long-running node: outside Debug, the general-purpose allocator.
    // (Static ReleaseSafe builds would otherwise get std's DebugAllocator,
    // which records a stack trace for every allocation.)
    const allocator = if (@import("builtin").mode == .Debug) init.gpa else std.heap.smp_allocator;
    const args = try init.minimal.args.toSlice(init.arena.allocator());

    var options: Options = .{};
    if (!try parseArgs(init.arena.allocator(), args, &options)) return;

    var config = loadConfig(allocator, options.config_path) catch |err| {
        std.debug.print("Error: could not load configuration: {any}\n", .{err});
        std.process.exit(1);
    };
    defer config.deinit(allocator);
    for (options.shares.items) |spec| {
        const share = config_mod.Config.Share.parse(spec) catch {
            std.debug.print("Error: --share expects Name:/path, got '{s}'\n", .{spec});
            std.process.exit(1);
        };
        try config.addShare(allocator, share.name, share.path);
    }
    if (options.swarm_backup) config.storage.swarm_backup = true;
    if (options.copies) |n| config.storage.set_copies = n;

    switch (options.command) {
        .pair => try pairCommand(allocator, config, options.address),
        .trust => try trustCommand(allocator, config, options.trust_uri.?),
        .devices => try devicesCommand(allocator, config),
        .revoke => try revokeCommand(allocator, config, options.revoke_query.?),
        .run => try runNode(allocator, config),
        .mount => try mountCommand(allocator, config, options.mountpoint.?),
        .invite => try inviteCommand(allocator, config, options.address),
        .cache => try cacheCommand(allocator, config, false),
        .clear_cache => try cacheCommand(allocator, config, true),
        .bench_read => try benchReadCommand(allocator, config, options.bench_read_path.?, options.bench_wait_seconds, options.bench_cold),
        .bench_idle => try benchIdleCommand(allocator, config, options.bench_idle_seconds),
    }
}

/// Returns false when the command was fully handled (help).
fn parseArgs(arena: std.mem.Allocator, args: []const []const u8, options: *Options) !bool {
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--config")) {
            options.config_path = try nextValue(args, &i, "--config");
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            printHelp();
            return false;
        } else if (std.mem.eql(u8, arg, "--pair")) {
            try selectCommand(options, .pair);
        } else if (std.mem.eql(u8, arg, "--trust")) {
            try selectCommand(options, .trust);
            options.trust_uri = try nextValue(args, &i, "--trust");
        } else if (std.mem.eql(u8, arg, "--devices")) {
            try selectCommand(options, .devices);
        } else if (std.mem.eql(u8, arg, "--revoke")) {
            try selectCommand(options, .revoke);
            options.revoke_query = try nextValue(args, &i, "--revoke");
        } else if (std.mem.eql(u8, arg, "--invite")) {
            try selectCommand(options, .invite);
        } else if (std.mem.eql(u8, arg, "--cache")) {
            try selectCommand(options, .cache);
        } else if (std.mem.eql(u8, arg, "--clear-cache")) {
            try selectCommand(options, .clear_cache);
        } else if (std.mem.eql(u8, arg, "--bench-read")) {
            try selectCommand(options, .bench_read);
            options.bench_read_path = try nextValue(args, &i, "--bench-read");
        } else if (std.mem.eql(u8, arg, "--bench-wait")) {
            const val_str = try nextValue(args, &i, "--bench-wait");
            options.bench_wait_seconds = std.fmt.parseInt(u32, val_str, 10) catch {
                std.debug.print("Error: --bench-wait expects an integer number of seconds\n", .{});
                std.process.exit(1);
            };
        } else if (std.mem.eql(u8, arg, "--bench-cold")) {
            options.bench_cold = true;
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
        } else if (std.mem.eql(u8, arg, "--share")) {
            try options.shares.append(arena, try nextValue(args, &i, "--share"));
        } else if (std.mem.eql(u8, arg, "--swarm-backup")) {
            options.swarm_backup = true;
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

    if (options.address != null and options.command != .pair and options.command != .invite) {
        std.debug.print("Error: --address is only valid with --pair or --invite\n", .{});
        std.process.exit(1);
    }
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
        std.debug.print("Error: only one of --pair, --trust, --devices, --revoke, --mount, --invite, --cache, --clear-cache, --bench-read or --bench-idle may be used\n", .{});
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
        \\  nomadfs --invite [--address ip] [config_path]
        \\  nomadfs --cache | --clear-cache [config_path]
        \\  nomadfs --bench-read <swarm path> [--bench-wait SECONDS] [--bench-cold] [config_path]
        \\  nomadfs --bench-idle SECONDS [config_path]
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
        \\  --mount <dir>      Run the node and mount every device's shares at
        \\                     <dir>/<device>/<share>, read-only; files download
        \\                     on demand (Linux, needs fusermount3)
        \\  --cache            Show the read cache: blocks fetched from other devices
        \\                     to be read, evicted least recently used first past
        \\                     `cache_mb` under [storage] (default 2048, 0 = no limit)
        \\  --clear-cache      Empty the read cache; what this device keeps (its
        \\                     writes, backups) is not touched
        \\  --bench-read <path> Read a swarm folder file in 1 MiB chunks and print benchmark stats
        \\  --bench-wait <sec>  Seconds to wait for swarm peer sync before bench read (default 30)
        \\  --bench-cold        Clear the read cache before benchmarking a read
        \\  --bench-idle <sec>  Run the node for SECONDS and print wire chatter totals
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

fn runNode(allocator: std.mem.Allocator, config: config_mod.Config) !void {
    std.debug.print("NomadFS Node: {s} (Storage: {any})\n", .{ config.node.nickname, config.storage.enabled });
    std.debug.print("Listening on port: {d}\n", .{config.network.port});
    if (config.storage.swarm_backup) std.debug.print("Backing up the swarm folder on this device\n", .{});

    var node = try nomadfs.Node.init(allocator, config);
    defer node.deinit();

    std.debug.print("Node Initialized. Local ID: {x}\n", .{node.connection_manager.node_id.bytes});
    std.debug.print("Device ID: {x}\n", .{node.device_identity.deviceId().bytes});
    var running = std.atomic.Value(bool).init(true);
    node.bootstrap(config.network.bootstrap_peers, config.node.swarm_key) catch |err| {
        std.debug.print("Bootstrap error: {any}\n", .{err});
    };
    try node.run(&running, config);
}

var mounted_at: [std.fs.max_path_bytes:0]u8 = undefined;
var mounted_len: usize = 0;

fn onStopSignal(_: std.os.linux.SIG) callconv(.c) void {
    // Unmounting makes the FUSE loop return, which shuts the node down.
    if (mounted_len > 0) nomadfs.fs.fuse.unmount(mounted_at[0..mounted_len :0]);
}

fn mountCommand(allocator: std.mem.Allocator, config: config_mod.Config, mountpoint: []const u8) !void {
    if (comptime !@hasDecl(nomadfs.fs.fuse, "Mount")) {
        std.debug.print("Error: --mount is only supported on Linux\n", .{});
        std.process.exit(1);
    } else {
        return mountLinux(allocator, config, mountpoint);
    }
}

fn mountLinux(allocator: std.mem.Allocator, config: config_mod.Config, mountpoint: []const u8) !void {
    if (!config.storage.enabled) {
        std.debug.print("Error: --mount needs storage enabled (fetched blocks are cached there)\n", .{});
        std.process.exit(1);
    }

    var node = try nomadfs.Node.init(allocator, config);
    defer node.deinit();
    std.debug.print("NomadFS {s}: device {x}\n", .{ config.node.nickname, node.device_identity.deviceId().bytes[0..6] });
    node.bootstrap(config.network.bootstrap_peers, config.node.swarm_key) catch |err| {
        std.debug.print("Bootstrap error: {any}\n", .{err});
    };

    var running = std.atomic.Value(bool).init(true);
    const run_thread = try std.Thread.spawn(.{}, runUntilStopped, .{ &node, &running, config });
    defer {
        running.store(false, .release);
        run_thread.join();
    }

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

    var mount = try nomadfs.fs.fuse.Mount.init(allocator, node.block_manager, node.store.?);
    defer mount.deinit();
    mount.swarm = node.swarm;
    mount.read_ahead = node.read_ahead;
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

fn inviteCommand(allocator: std.mem.Allocator, config: config_mod.Config, address: ?[]const u8) !void {
    const invite = device.invite;
    var ip_buf: [16]u8 = undefined;
    const ip = address orelse invite.lanAddress(&ip_buf) orelse "127.0.0.1";

    var paths = try DevicePaths.resolve(allocator, config.node.key_path);
    defer paths.deinit(allocator);
    const identity = try Identity.loadOrCreate(paths.identity);
    const transport = try nomadfs.net.transport.manager.ConnectionManager.loadOrCreateKey(allocator, config.node.key_path);
    var addr_buf: [64]u8 = undefined;
    const node_addr = try std.fmt.bufPrint(&addr_buf, "{s}:{d}", .{ ip, config.network.port });
    const now = nowSeconds();
    const ticket = try Ticket.init(identity, transport.public_key, config.node.nickname, node_addr, now + ticket_lifetime_seconds);
    var uri_buf: [device.pairing.max_uri_len]u8 = undefined;
    const uri = try ticket.toUri(&uri_buf);

    const host = try invite.Host.start(allocator, .{
        .identity = identity,
        .swarm_key = config.node.swarm_key[0..32].*,
        .node_port = config.network.port,
        .ticket_uri = uri,
    }, try std.math.add(u16, config.network.port, 1), invite.default_lifetime_s, now);
    defer host.destroy();

    var code_buf: [160]u8 = undefined;
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    const code = try host.code(ip, &code_buf);
    try out.writer.print("Invite (one use, expires in {d} minutes). Scan it with the NomadFS app\n(Connect devices > Scan QR code) or enter the code:\n\n", .{invite.default_lifetime_s / 60});
    var matrix = try device.qr.encode(allocator, code, .medium);
    defer matrix.deinit();
    try device.qr.renderAscii(matrix, &out.writer, .{});
    try out.writer.print("\n{s}\n\nWaiting for the other device...\n", .{code});
    try writeStdout(out.written());

    while (true) {
        nomadfs.sync.sleep(500 * std.time.ns_per_ms);
        switch (host.status(nowSeconds())) {
            .waiting => continue,
            .expired => {
                std.debug.print("Invite expired.\n", .{});
                return;
            },
            .joined => break,
        }
    }
    const joined_uri = (try host.joinedTicket(allocator)).?;
    defer allocator.free(joined_uri);
    const joiner = try Ticket.parseAt(joined_uri, nowSeconds());
    var store = try TrustStore.load(allocator, paths.trust, identity.seed());
    defer store.deinit();
    // The joiner proved it holds this ticket's identity; a newer ticket
    // already on file still wins over it.
    if (store.trustTicket(joiner, nowSeconds())) |_| {
        try store.save();
    } else |err| switch (err) {
        error.StaleTicket => std.debug.print("Warning: a newer ticket for this device is already trusted; kept it.\n", .{}),
        else => return err,
    }
    var fp_buf: [19]u8 = undefined;
    std.debug.print("{s} joined ({s}, {s}) and is now trusted.\n", .{
        joiner.nicknameSlice(),
        Identity.formatFingerprint(joiner.fingerprint(), &fp_buf),
        joiner.addressesSlice(),
    });
}

fn pairCommand(allocator: std.mem.Allocator, config: config_mod.Config, address: ?[]const u8) !void {
    var paths = try DevicePaths.resolve(allocator, config.node.key_path);
    defer paths.deinit(allocator);

    const identity = try Identity.loadOrCreate(paths.identity);
    const transport = try nomadfs.net.transport.manager.ConnectionManager.loadOrCreateKey(allocator, config.node.key_path);

    var default_address: [64]u8 = undefined;
    const addresses = address orelse
        try std.fmt.bufPrint(&default_address, "127.0.0.1:{d}", .{config.network.port});

    const now = nowSeconds();
    const ticket = try Ticket.init(
        identity,
        transport.public_key,
        config.node.nickname,
        addresses,
        now + ticket_lifetime_seconds,
    );

    var uri_buf: [device.pairing.max_uri_len]u8 = undefined;
    const uri = try ticket.toUri(&uri_buf);

    var fingerprint_buf: [19]u8 = undefined;
    const fingerprint = Identity.formatFingerprint(identity.fingerprint(), &fingerprint_buf);

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try out.writer.print(
        "Device: {s}\nFingerprint: {s}\nAddresses: {s}\nExpires: {d}\n\n{s}\n\n",
        .{ config.node.nickname, fingerprint, ticket.addressesSlice(), ticket.expires_at, uri },
    );

    var matrix = try ticket.qrMatrix(allocator, .medium);
    defer matrix.deinit();
    try device.qr.renderAscii(matrix, &out.writer, .{});
    try writeStdout(out.written());
}

fn trustCommand(allocator: std.mem.Allocator, config: config_mod.Config, uri: []const u8) !void {
    var paths = try DevicePaths.resolve(allocator, config.node.key_path);
    defer paths.deinit(allocator);

    const identity = try Identity.loadOrCreate(paths.identity);
    var store = try TrustStore.load(allocator, paths.trust, identity.seed());
    defer store.deinit();

    const now = nowSeconds();
    const ticket = Ticket.parseAt(uri, now) catch |err| {
        std.debug.print("Error: ticket rejected: {any}\n", .{err});
        return err;
    };

    const added = store.trustTicket(ticket, now) catch |err| switch (err) {
        error.StaleTicket => {
            std.debug.print("Refused: a newer ticket for this device is already trusted. Ask it for a fresh one.\n", .{});
            return err;
        },
        else => return err,
    };
    try store.save();

    var fingerprint_buf: [19]u8 = undefined;
    const fingerprint = Identity.formatFingerprint(ticket.fingerprint(), &fingerprint_buf);
    std.debug.print("{s} device '{s}' ({s}) at {s}\n", .{
        if (added) "Trusted" else "Refreshed",
        ticket.nicknameSlice(),
        fingerprint,
        paths.trust,
    });
}

/// `--cache` / `--clear-cache`: works on the store directly, so it runs
/// while a node is running too (the node recounts before it reports).
fn cacheCommand(allocator: std.mem.Allocator, config: config_mod.Config, clear: bool) !void {
    if (!config.storage.enabled) {
        std.debug.print("Storage is disabled in this configuration.\n", .{});
        return;
    }
    var store = try nomadfs.storage.engine.StorageEngine.init(allocator, config.storage.storage_path);
    defer store.deinit();
    if (clear) {
        const freed = try store.clearCache();
        var buf: [32]u8 = undefined;
        std.debug.print("Cleared the read cache: freed {s}.\n", .{formatBytes(&buf, freed)});
        return;
    }
    const stats = store.cacheStats();
    var used_buf: [32]u8 = undefined;
    var limit_buf: [32]u8 = undefined;
    const limit = if (config.storage.cache_mb == 0) "no limit" else formatBytes(&limit_buf, config.storage.cache_mb * 1024 * 1024);
    std.debug.print("Read cache: {s} in {d} blocks (limit {s})\n", .{ formatBytes(&used_buf, stats.bytes), stats.blocks, limit });
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
    var paths = try DevicePaths.resolve(allocator, config.node.key_path);
    defer paths.deinit(allocator);

    const identity = try Identity.loadOrCreate(paths.identity);
    var store = try TrustStore.load(allocator, paths.trust, identity.seed());
    defer store.deinit();

    const entries = store.list();
    if (entries.len == 0) {
        std.debug.print("No trusted devices in {s}\n", .{paths.trust});
        return;
    }

    std.debug.print("Trusted devices in {s}:\n", .{paths.trust});
    for (entries) |*entry| {
        var fingerprint_buf: [19]u8 = undefined;
        const fingerprint = Identity.formatFingerprint(entry.fingerprint(), &fingerprint_buf);
        std.debug.print("  {s}  {s}  added {d}  [{x}]\n", .{
            fingerprint,
            entry.labelSlice(),
            entry.added_at,
            entry.device_id.bytes[0..4],
        });
    }
}

fn revokeCommand(allocator: std.mem.Allocator, config: config_mod.Config, query: []const u8) !void {
    var paths = try DevicePaths.resolve(allocator, config.node.key_path);
    defer paths.deinit(allocator);

    // The revocation is signed with this device's identity so peers can
    // verify it was issued by a trusted operator node, not forged on the
    // wire.
    const identity = try Identity.loadOrCreate(paths.identity);

    var store = try TrustStore.load(allocator, paths.trust, identity.seed());
    defer store.deinit();

    const device_id = store.resolve(query) catch |err| switch (err) {
        error.InvalidDeviceQuery => {
            std.debug.print("Error: '{s}' is not a hex device ID or fingerprint\n", .{query});
            std.process.exit(1);
        },
        error.AmbiguousDeviceQuery => {
            std.debug.print("Error: '{s}' matches more than one device; use the full device ID\n", .{query});
            std.process.exit(1);
        },
        else => return err,
    } orelse {
        std.debug.print("No trusted device matches '{s}' in {s}\n", .{ query, paths.trust });
        std.process.exit(1);
    };

    const removed = try store.revokeDevice(device_id, identity.deviceId(), nowSeconds());
    try store.save();
    std.debug.print("Revoked device '{s}' from {s}{s}\n", .{
        query,
        paths.trust,
        if (removed) "" else " (tombstone recorded; no local entry)",
    });
}

fn nowSeconds() u64 {
    const io = std.Io.Threaded.global_single_threaded.io();
    const timestamp = std.Io.Clock.real.now(io);
    const seconds = @divFloor(timestamp.nanoseconds, std.time.ns_per_s);
    return @intCast(seconds);
}

fn writeStdout(bytes: []const u8) !void {
    const io = std.Io.Threaded.global_single_threaded.io();
    try std.Io.File.stdout().writeStreamingAll(io, bytes);
}

fn benchReadCommand(allocator: std.mem.Allocator, config: config_mod.Config, raw_path: []const u8, wait_seconds: u32, cold: bool) !void {
    var node = try nomadfs.Node.init(allocator, config);
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
    const entry_opt = if (swarm.manifest.get(path)) |e| if (!e.deleted and e.kind == .file) e else null else null;
    swarm.mutex.unlock();
    const entry = entry_opt orelse {
        std.debug.print("Error: swarm entry '{s}' not found\n", .{raw_path});
        std.process.exit(1);
    };

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
    var offset: u64 = 0;
    while (offset < entry.size) {
        const to_read = @min(@as(u64, chunk_size), entry.size - offset);
        const n = try swarm.readAt(allocator, entry.cid, entry.version.device, offset, buf[0..@intCast(to_read)]);
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
    var node = try nomadfs.Node.init(allocator, config);
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
