const std = @import("std");
const builtin = @import("builtin");
const env_mod = @import("env.zig");

pub const ConfigError = error{
    InvalidSwarmKey,
    ConfigNotFound,
    MissingRequiredField,
};

/// Validate and decode swarm key from configuration.
/// Accepts:
/// - 64-character hex string (decoded to 32 bytes)
/// - 32-byte binary string
/// Rejects all other formats
fn validateSwarmKey(val: []const u8, allocator: std.mem.Allocator) ![]const u8 {
    if (val.len == 64) {
        // Validate hex characters
        for (val) |c| {
            if (!std.ascii.isHex(c)) return error.InvalidSwarmKey;
        }
        const decoded = try allocator.alloc(u8, 32);
        _ = try std.fmt.hexToBytes(decoded, val);
        return decoded;
    } else if (val.len == 32) {
        // Binary key, just duplicate
        return try allocator.dupe(u8, val);
    } else {
        return error.InvalidSwarmKey;
    }
}

pub const Config = struct {
    node: NodeConfig,
    storage: StorageConfig,
    network: NetworkConfig,

    pub const NodeConfig = struct {
        nickname: []const u8,
        swarm_key: []const u8,
        key_path: ?[]const u8 = null,
    };

    pub const StorageConfig = struct {
        enabled: bool,
        storage_path: []const u8,
    };

    pub const NetworkConfig = struct {
        port: u16,
        bootstrap_peers: [][]const u8,
        transport: TransportType,
        upnp_enabled: bool = true,
        enable_mdns: bool = true,
    };

    pub const TransportType = enum {
        tcp,
        quic,
    };

    pub fn deinit(self: *Config, allocator: std.mem.Allocator) void {
        if (self.node.nickname.len > 0) allocator.free(self.node.nickname);
        if (self.node.swarm_key.len > 0) allocator.free(self.node.swarm_key);
        if (self.node.key_path) |p| allocator.free(p);
        if (self.storage.storage_path.len > 0) allocator.free(self.storage.storage_path);
        for (self.network.bootstrap_peers) |peer| {
            allocator.free(peer);
        }
        allocator.free(self.network.bootstrap_peers);
    }
};

/// Simple parser for the roaming.conf format.
/// Note: In a real-world scenario, we might use a full TOML parser.
/// For this MVP, we implement a basic line-by-line parser.
pub fn parseConfig(allocator: std.mem.Allocator, path: []const u8) !Config {
    std.debug.assert(path.len > 0);

    var expanded_path: []const u8 = path;
    var owned_path: ?[]const u8 = null;
    defer if (owned_path) |p| allocator.free(p);

    if (std.mem.startsWith(u8, path, "~")) {
        const home_env = if (builtin.os.tag == .windows) "USERPROFILE" else "HOME";
        if (env_mod.getEnv(allocator, home_env)) |home| {
            defer allocator.free(home);
            owned_path = try std.fs.path.join(allocator, &.{ home, path[1..] });
            expanded_path = owned_path.?;
        }
    }

    const io = std.Io.Threaded.global_single_threaded.io();
    var file = try std.Io.Dir.cwd().openFile(io, expanded_path, .{});
    defer file.close(io);

    var file_buffer: [16384]u8 = undefined;
    const n = try file.readPositionalAll(io, &file_buffer, 0);
    const content = file_buffer[0..n];

    var config = Config{
        .node = .{ .nickname = "", .swarm_key = "", .key_path = null },
        .storage = .{ .enabled = true, .storage_path = "" },
        .network = .{ .port = 9000, .bootstrap_peers = undefined, .transport = .tcp },
    };

    var bootstrap_list: std.ArrayListUnmanaged([]const u8) = .empty;
    errdefer {
        for (bootstrap_list.items) |item| allocator.free(item);
        bootstrap_list.deinit(allocator);
    }

    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0 or trimmed[0] == '#') continue;

        if (std.mem.startsWith(u8, trimmed, "[")) continue; // Skip section headers for now

        var it = std.mem.splitSequence(u8, trimmed, "=");
        const key = std.mem.trim(u8, it.next() orelse continue, " \t");
        const val_raw = std.mem.trim(u8, it.next() orelse continue, " \t");

        // Simple string unquoting
        const val = if (std.mem.startsWith(u8, val_raw, "\"") and std.mem.endsWith(u8, val_raw, "\""))
            val_raw[1 .. val_raw.len - 1]
        else
            val_raw;

        if (std.mem.eql(u8, key, "nickname")) {
            config.node.nickname = try allocator.dupe(u8, val);
        } else if (std.mem.eql(u8, key, "swarm_key")) {
            config.node.swarm_key = try validateSwarmKey(val, allocator);
        } else if (std.mem.eql(u8, key, "key_path")) {
            config.node.key_path = try allocator.dupe(u8, val);
        } else if (std.mem.eql(u8, key, "enabled")) {
            config.storage.enabled = std.mem.eql(u8, val, "true");
        } else if (std.mem.eql(u8, key, "storage_path")) {
            config.storage.storage_path = try allocator.dupe(u8, val);
        } else if (std.mem.eql(u8, key, "port")) {
            config.network.port = try std.fmt.parseInt(u16, val, 10);
        } else if (std.mem.eql(u8, key, "upnp_enabled")) {
            config.network.upnp_enabled = std.mem.eql(u8, val, "true");
        } else if (std.mem.eql(u8, key, "enable_mdns")) {
            config.network.enable_mdns = std.mem.eql(u8, val, "true");
        } else if (std.mem.eql(u8, key, "transport")) {
            if (std.mem.eql(u8, val, "quic")) {
                config.network.transport = .quic;
            } else {
                config.network.transport = .tcp;
            }
        } else if (std.mem.eql(u8, key, "bootstrap_peers")) {
            // Handle array format ["...", "..."]
            var p_val = val;
            if (std.mem.startsWith(u8, p_val, "[")) p_val = p_val[1..];
            if (std.mem.endsWith(u8, p_val, "]")) p_val = p_val[0 .. p_val.len - 1];

            var p_it = std.mem.splitSequence(u8, p_val, ",");
            while (p_it.next()) |p| {
                const peer = std.mem.trim(u8, p, " \t\"");
                if (peer.len > 0) {
                    try bootstrap_list.append(allocator, try allocator.dupe(u8, peer));
                }
            }
        }
    }

    config.network.bootstrap_peers = try bootstrap_list.toOwnedSlice(allocator);

    if (config.node.nickname.len == 0) return error.MissingRequiredField;
    if (config.node.swarm_key.len != 32) return error.MissingRequiredField;
    if (config.storage.storage_path.len == 0) return error.MissingRequiredField;
    if (config.network.port == 0) return error.MissingRequiredField;

    return config;
}

pub fn findAndParseConfig(allocator: std.mem.Allocator) !Config {
    // 1. Current working directory
    if (parseConfig(allocator, "nomadfs.conf")) |cfg| {
        return cfg;
    } else |_| {}

    // 2. Home directory: ~/.nomadfs/nomadfs.conf
    const home_env = if (builtin.os.tag == .windows) "USERPROFILE" else "HOME";
    if (env_mod.getEnv(allocator, home_env)) |home| {
        defer allocator.free(home);
        const path = try std.fs.path.join(allocator, &.{ home, ".nomadfs", "nomadfs.conf" });
        defer allocator.free(path);
        if (parseConfig(allocator, path)) |cfg| {
            return cfg;
        } else |_| {}
    }

    // 3. System-wide standard: /etc/nomadfs/nomadfs.conf
    if (parseConfig(allocator, "/etc/nomadfs/nomadfs.conf")) |cfg| {
        return cfg;
    } else |_| {}

    // 4. System-wide: /usr/share/nomadfs/nomadfs.conf
    if (parseConfig(allocator, "/usr/share/nomadfs/nomadfs.conf")) |cfg| {
        return cfg;
    } else |err| {
        return err;
    }
}
