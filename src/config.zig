const std = @import("std");
const builtin = @import("builtin");

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
    };

    pub const TransportType = enum {
        tcp,
        quic,
    };

    pub fn deinit(self: *Config, allocator: std.mem.Allocator) void {
        allocator.free(self.node.nickname);
        allocator.free(self.node.swarm_key);
        if (self.node.key_path) |p| allocator.free(p);
        allocator.free(self.storage.storage_path);
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
    var expanded_path: []const u8 = path;
    var owned_path: ?[]const u8 = null;
    defer if (owned_path) |p| allocator.free(p);

    if (std.mem.startsWith(u8, path, "~")) {
        const home_env = if (builtin.os.tag == .windows) "USERPROFILE" else "HOME";
        if (std.process.getEnvVarOwned(allocator, home_env)) |home| {
            defer allocator.free(home);
            owned_path = try std.fs.path.join(allocator, &.{ home, path[1..] });
            expanded_path = owned_path.?;
        } else |_| {}
    }

    const file = if (std.fs.path.isAbsolute(expanded_path))
        try std.fs.openFileAbsolute(expanded_path, .{})
    else
        try std.fs.cwd().openFile(expanded_path, .{});
    defer file.close();

    var file_buffer: [4096]u8 = undefined;
    var in_stream = file.reader(&file_buffer);

    var config = Config{
        .node = .{ .nickname = "", .swarm_key = "", .key_path = null },
        .storage = .{ .enabled = true, .storage_path = "" },
        .network = .{ .port = 9000, .bootstrap_peers = undefined, .transport = .tcp },
    };

    var bootstrap_list = std.ArrayListUnmanaged([]const u8){};
    errdefer {
        for (bootstrap_list.items) |item| allocator.free(item);
        bootstrap_list.deinit(allocator);
    }

    while (try in_stream.interface.takeDelimiter('\n')) |line| {
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
            if (val.len == 64) {
                const decoded = try allocator.alloc(u8, 32);
                _ = try std.fmt.hexToBytes(decoded, val);
                config.node.swarm_key = decoded;
            } else {
                config.node.swarm_key = try allocator.dupe(u8, val);
            }
        } else if (std.mem.eql(u8, key, "key_path")) {
            config.node.key_path = try allocator.dupe(u8, val);
        } else if (std.mem.eql(u8, key, "enabled")) {
            config.storage.enabled = std.mem.eql(u8, val, "true");
        } else if (std.mem.eql(u8, key, "storage_path")) {
            config.storage.storage_path = try allocator.dupe(u8, val);
        } else if (std.mem.eql(u8, key, "port")) {
            config.network.port = try std.fmt.parseInt(u16, val, 10);
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
    return config;
}

pub fn findAndParseConfig(allocator: std.mem.Allocator) !Config {
    // 1. Current working directory
    if (parseConfig(allocator, "nomadfs.conf")) |cfg| {
        return cfg;
    } else |_| {}

    // 2. Home directory: ~/.nomadfs/nomadfs.conf
    const home_env = if (builtin.os.tag == .windows) "USERPROFILE" else "HOME";
    if (std.process.getEnvVarOwned(allocator, home_env)) |home| {
        defer allocator.free(home);
        const path = try std.fs.path.join(allocator, &.{ home, ".nomadfs", "nomadfs.conf" });
        defer allocator.free(path);
        if (parseConfig(allocator, path)) |cfg| {
            return cfg;
        } else |_| {}
    } else |_| {}

    // 3. System-wide standard: /etc/nomadfs/nomadfs.conf
    if (parseConfig(allocator, "/etc/nomadfs/nomadfs.conf")) |cfg| {
        return cfg;
    } else |_| {}

    // 4. System-wide: /usr/share/nomadfs/nomadfs.conf
    // On Windows, this path might not make sense, but we keep it for Linux/macOS as requested.
    if (parseConfig(allocator, "/usr/share/nomadfs/nomadfs.conf")) |cfg| {
        return cfg;
    } else |err| {
        // If all fail, return the last error (likely FileNotFoundError)
        return err;
    }
}
