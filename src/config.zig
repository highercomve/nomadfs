const std = @import("std");

pub const Config = struct {
    node: NodeConfig,
    storage: StorageConfig,
    network: NetworkConfig,

    pub const NodeConfig = struct {
        nickname: []const u8,
        swarm_key: []const u8,
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
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();

    var file_buffer: [4096]u8 = undefined;
    var in_stream = file.reader(&file_buffer);

    var config = Config{
        .node = .{ .nickname = "", .swarm_key = "" },
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
            config.node.swarm_key = try allocator.dupe(u8, val);
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
