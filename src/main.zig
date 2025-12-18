const std = @import("std");
const nomadfs = @import("nomadfs");
const config_mod = nomadfs.config;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    var config_path: ?[]const u8 = null;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--config")) {
            if (i + 1 < args.len) {
                config_path = args[i + 1];
                i += 1;
            } else {
                std.debug.print("Error: --config requires a path argument\n", .{});
                std.process.exit(1);
            }
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            std.debug.print("NomadFS - Private, decentralized distributed file system\n\nUsage:\n  nomadfs [options] [config_path]\n\nOptions:\n  --config <path>    Path to the configuration file\n  --help, -h         Show this help message\n", .{});
            return;
        } else if (std.mem.startsWith(u8, arg, "-")) {
            std.debug.print("Error: Unknown option {s}\n", .{arg});
            std.process.exit(1);
        } else {
            if (config_path == null) {
                config_path = arg;
            } else {
                std.debug.print("Error: Multiple configuration paths provided\n", .{});
                std.process.exit(1);
            }
        }
    }

    var config: config_mod.Config = undefined;
    if (config_path) |path| {
        config = config_mod.parseConfig(allocator, path) catch |err| {
            std.debug.print("Error: Failed to parse config file '{s}': {any}\n", .{ path, err });
            std.process.exit(1);
        };
    } else {
        config = config_mod.findAndParseConfig(allocator) catch |err| {
            std.debug.print("Error: Could not find or parse a default configuration file: {any}\n", .{err});
            std.process.exit(1);
        };
    }
    defer config.deinit(allocator);

    std.debug.print("NomadFS Node: {s} (Storage: {any})\n", .{ config.node.nickname, config.storage.enabled });
    std.debug.print("Listening on port: {d}\n", .{config.network.port});

    // Initialize the Node
    var node = try nomadfs.Node.init(allocator, config);
    defer node.deinit();

    std.debug.print("Node Initialized. Local ID: {x}\n", .{node.net.node_id.bytes});

    var running = std.atomic.Value(bool).init(true);

    // Start the node's network listener
    try node.start(config.network.port, config.node.swarm_key, &running);

    // Give listener a moment to start
    std.Thread.sleep(100 * std.time.ns_per_ms);

    // Join the network via bootstrap peers
    node.bootstrap(config.network.bootstrap_peers, config.node.swarm_key) catch |err| {
        std.debug.print("Bootstrap error: {any}\n", .{err});
    };

    // Keep main thread alive
    while (running.load(.acquire)) {
        std.Thread.sleep(1 * std.time.ns_per_s);
    }
}