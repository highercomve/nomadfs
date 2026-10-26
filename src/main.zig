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

const Command = enum { run, pair, trust, devices, revoke };

const Options = struct {
    command: Command = .run,
    config_path: ?[]const u8 = null,
    address: ?[]const u8 = null,
    trust_uri: ?[]const u8 = null,
    revoke_query: ?[]const u8 = null,
};

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const args = try init.minimal.args.toSlice(init.arena.allocator());

    var options: Options = .{};
    if (!try parseArgs(args, &options)) return;

    var config = loadConfig(allocator, options.config_path) catch |err| {
        std.debug.print("Error: could not load configuration: {any}\n", .{err});
        std.process.exit(1);
    };
    defer config.deinit(allocator);

    switch (options.command) {
        .pair => try pairCommand(allocator, config, options.address),
        .trust => try trustCommand(allocator, config, options.trust_uri.?),
        .devices => try devicesCommand(allocator, config),
        .revoke => try revokeCommand(allocator, config, options.revoke_query.?),
        .run => try runNode(allocator, config),
    }
}

/// Returns false when the command was fully handled (help).
fn parseArgs(args: []const []const u8, options: *Options) !bool {
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

    if (options.address != null and options.command != .pair) {
        std.debug.print("Error: --address is only valid with --pair\n", .{});
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
        std.debug.print("Error: only one of --pair, --trust, --devices or --revoke may be used\n", .{});
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
        \\
        \\Options:
        \\  --config <path>    Path to the configuration file
        \\  --pair             Print this device's pairing ticket and QR code
        \\  --address <addr>   Address(es) to publish in the ticket, comma separated
        \\  --trust <uri>      Verify and add a pairing ticket to the trust store
        \\  --devices          List trusted devices
        \\  --revoke <id>      Remove a trusted device by ID or fingerprint
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

    var store = try TrustStore.load(allocator, paths.trust);
    defer store.deinit();

    const now = nowSeconds();
    const ticket = Ticket.parseAt(uri, now) catch |err| {
        std.debug.print("Error: ticket rejected: {any}\n", .{err});
        return err;
    };

    const added = try store.trustTicket(ticket, now);
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

fn devicesCommand(allocator: std.mem.Allocator, config: config_mod.Config) !void {
    var paths = try DevicePaths.resolve(allocator, config.node.key_path);
    defer paths.deinit(allocator);

    var store = try TrustStore.load(allocator, paths.trust);
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

    var store = try TrustStore.load(allocator, paths.trust);
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
