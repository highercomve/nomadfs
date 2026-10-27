const std = @import("std");
const builtin = @import("builtin");
const env_mod = @import("env.zig");

pub const ConfigError = error{
    InvalidSwarmKey,
    ConfigNotFound,
    MissingRequiredField,
    /// The transport is recognised but not implemented (QUIC).
    UnsupportedTransport,
    InvalidTransport,
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
        errdefer allocator.free(decoded);
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
    security: SecurityConfig = .{},
    /// Folders shared with the swarm: `share = "Name:/path"`, repeatable.
    shares: []Share = &.{},

    pub const Share = struct {
        name: []const u8,
        path: []const u8,

        /// Splits "Name:/path" at the first ':'. Slices point into `spec`.
        pub fn parse(spec: []const u8) !Share {
            const colon = std.mem.indexOfScalar(u8, spec, ':') orelse return error.InvalidShare;
            const name = std.mem.trim(u8, spec[0..colon], " \t");
            const path = std.mem.trim(u8, spec[colon + 1 ..], " \t");
            if (name.len == 0 or path.len == 0) return error.InvalidShare;
            return .{ .name = name, .path = path };
        }
    };

    pub const NodeConfig = struct {
        nickname: []const u8,
        swarm_key: []const u8,
        key_path: ?[]const u8 = null,
    };

    pub const StorageConfig = struct {
        enabled: bool,
        storage_path: []const u8,
        /// Closest peers the DAG of every new file is pushed to. 0 keeps
        /// puts local (provider records only).
        replicas: u8 = 0,
        /// Provider-record acknowledgements a put requires. 0 lets a
        /// device with no peers adopt content offline.
        write_quorum: u8 = 1,
    };

    pub const SecurityConfig = struct {
        /// Reject peers whose Ed25519 identity is not in the trust store.
        require_trusted_devices: bool = false,
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
        for (self.shares) |share| {
            allocator.free(share.name);
            allocator.free(share.path);
        }
        allocator.free(self.shares);
    }

    /// Adds a share (copies `name` and `path`), replacing one of that name.
    pub fn addShare(self: *Config, allocator: std.mem.Allocator, name: []const u8, path: []const u8) !void {
        const owned_name = try allocator.dupe(u8, name);
        errdefer allocator.free(owned_name);
        const owned_path = try allocator.dupe(u8, path);
        errdefer allocator.free(owned_path);
        for (self.shares) |*share| {
            if (!std.mem.eql(u8, share.name, name)) continue;
            allocator.free(share.name);
            allocator.free(share.path);
            share.* = .{ .name = owned_name, .path = owned_path };
            return;
        }
        const grown = try allocator.alloc(Share, self.shares.len + 1);
        @memcpy(grown[0..self.shares.len], self.shares);
        grown[self.shares.len] = .{ .name = owned_name, .path = owned_path };
        allocator.free(self.shares);
        self.shares = grown;
    }
};

/// Simple parser for the roaming.conf format.
/// Note: In a real-world scenario, we might use a full TOML parser.
/// For this MVP, we implement a basic line-by-line parser.
pub fn parseConfig(allocator: std.mem.Allocator, path: []const u8) !Config {
    std.debug.assert(path.len > 0);

    var file_buffer: [16384]u8 = undefined;
    const content = try readConfigFile(allocator, path, &file_buffer);
    return parseConfigText(allocator, content);
}

fn readConfigFile(allocator: std.mem.Allocator, path: []const u8, buffer: []u8) ![]const u8 {
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

    const n = try file.readPositionalAll(io, buffer, 0);
    return buffer[0..n];
}

/// Parses config text. On error every allocation made so far is released.
pub fn parseConfigText(allocator: std.mem.Allocator, content: []const u8) !Config {
    var config = Config{
        .node = .{ .nickname = "", .swarm_key = "", .key_path = null },
        .storage = .{ .enabled = true, .storage_path = "" },
        .network = .{ .port = 9000, .bootstrap_peers = &.{}, .transport = .tcp },
        .security = .{},
    };
    errdefer config.deinit(allocator);

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
        const val = if (val_raw.len >= 2 and std.mem.startsWith(u8, val_raw, "\"") and std.mem.endsWith(u8, val_raw, "\""))
            val_raw[1 .. val_raw.len - 1]
        else
            val_raw;

        try applyConfigEntry(allocator, &config, &bootstrap_list, key, val);
    }

    // Ownership of the list moves into config; the list errdefer is now a no-op.
    config.network.bootstrap_peers = try bootstrap_list.toOwnedSlice(allocator);

    if (config.node.nickname.len == 0) return error.MissingRequiredField;
    if (config.node.swarm_key.len != 32) return error.MissingRequiredField;
    if (config.storage.storage_path.len == 0) return error.MissingRequiredField;
    if (config.network.port == 0) return error.MissingRequiredField;

    return config;
}

/// Replaces an owned string, freeing the previous value. A repeated key in
/// the file therefore does not leak the earlier value.
/// Upper bound on storage.replicas: mirrors the routing-table width
/// (kbucket.K), which is the widest replica set the DHT can address.
pub const max_replicas: u8 = 20;

fn replaceString(allocator: std.mem.Allocator, field: *[]const u8, new_value: []const u8) void {
    if (field.len > 0) allocator.free(field.*);
    field.* = new_value;
}

fn applyConfigEntry(
    allocator: std.mem.Allocator,
    config: *Config,
    bootstrap_list: *std.ArrayListUnmanaged([]const u8),
    key: []const u8,
    val: []const u8,
) !void {
    if (std.mem.eql(u8, key, "nickname")) {
        replaceString(allocator, &config.node.nickname, try allocator.dupe(u8, val));
    } else if (std.mem.eql(u8, key, "swarm_key")) {
        replaceString(allocator, &config.node.swarm_key, try validateSwarmKey(val, allocator));
    } else if (std.mem.eql(u8, key, "key_path")) {
        const path = try allocator.dupe(u8, val);
        if (config.node.key_path) |old| allocator.free(old);
        config.node.key_path = path;
    } else if (std.mem.eql(u8, key, "enabled")) {
        config.storage.enabled = std.mem.eql(u8, val, "true");
    } else if (std.mem.eql(u8, key, "storage_path")) {
        replaceString(allocator, &config.storage.storage_path, try allocator.dupe(u8, val));
    } else if (std.mem.eql(u8, key, "write_quorum")) {
        config.storage.write_quorum = try std.fmt.parseInt(u8, val, 10);
    } else if (std.mem.eql(u8, key, "replicas")) {
        // Bounded by the routing-table width (kbucket.K): replicating wider
        // than the DHT can name targets is pointless.
        const n = try std.fmt.parseInt(u8, val, 10);
        if (n > max_replicas) return error.ReplicasOutOfRange;
        config.storage.replicas = n;
    } else if (std.mem.eql(u8, key, "port")) {
        config.network.port = try std.fmt.parseInt(u16, val, 10);
    } else if (std.mem.eql(u8, key, "upnp_enabled")) {
        config.network.upnp_enabled = std.mem.eql(u8, val, "true");
    } else if (std.mem.eql(u8, key, "enable_mdns")) {
        config.network.enable_mdns = std.mem.eql(u8, val, "true");
    } else if (std.mem.eql(u8, key, "require_trusted_devices")) {
        config.security.require_trusted_devices = std.mem.eql(u8, val, "true");
    } else if (std.mem.eql(u8, key, "transport")) {
        // Reject at startup rather than failing on first connect, and never
        // silently fall back to TCP on a typo.
        if (std.mem.eql(u8, val, "tcp")) {
            config.network.transport = .tcp;
        } else if (std.mem.eql(u8, val, "quic")) {
            return error.UnsupportedTransport;
        } else {
            return error.InvalidTransport;
        }
    } else if (std.mem.eql(u8, key, "bootstrap_peers")) {
        try appendBootstrapPeers(allocator, bootstrap_list, val);
    } else if (std.mem.eql(u8, key, "share")) {
        const share = try Config.Share.parse(val);
        try config.addShare(allocator, share.name, share.path);
    }
}

/// Handles the array format ["...", "..."].
fn appendBootstrapPeers(allocator: std.mem.Allocator, list: *std.ArrayListUnmanaged([]const u8), val: []const u8) !void {
    var p_val = val;
    if (std.mem.startsWith(u8, p_val, "[")) p_val = p_val[1..];
    if (std.mem.endsWith(u8, p_val, "]")) p_val = p_val[0 .. p_val.len - 1];

    var p_it = std.mem.splitSequence(u8, p_val, ",");
    while (p_it.next()) |p| {
        const peer = std.mem.trim(u8, p, " \t\"");
        if (peer.len == 0) continue;
        try list.ensureUnusedCapacity(allocator, 1);
        list.appendAssumeCapacity(try allocator.dupe(u8, peer));
    }
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

test "parseConfigText parses all fields" {
    const allocator = std.testing.allocator;
    var cfg = try parseConfigText(allocator,
        \\[node]
        \\nickname = "alpha"
        \\nickname = "beta"
        \\swarm_key = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
        \\[storage]
        \\storage_path = "/tmp/nomad"
        \\replicas = 2
        \\[network]
        \\port = 9100
        \\transport = "tcp"
        \\bootstrap_peers = ["tcp://10.0.0.1:9000", "tcp://10.0.0.2:9000"]
        \\require_trusted_devices = true
    );
    defer cfg.deinit(allocator);

    try std.testing.expectEqualStrings("beta", cfg.node.nickname);
    try std.testing.expectEqual(@as(usize, 32), cfg.node.swarm_key.len);
    try std.testing.expectEqual(@as(u16, 9100), cfg.network.port);
    try std.testing.expectEqual(Config.TransportType.tcp, cfg.network.transport);
    try std.testing.expectEqual(@as(usize, 2), cfg.network.bootstrap_peers.len);
    try std.testing.expect(cfg.security.require_trusted_devices);
    try std.testing.expectEqual(@as(u8, 2), cfg.storage.replicas);
}

test "parseConfigText releases everything on failure" {
    const allocator = std.testing.allocator;
    const text =
        \\nickname = "alpha"
        \\storage_path = "/tmp/nomad"
        \\bootstrap_peers = ["tcp://10.0.0.1:9000"]
        \\swarm_key = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
        \\key_path = "/tmp/node.key"
    ;
    try std.testing.checkAllAllocationFailures(allocator, struct {
        fn run(a: std.mem.Allocator, t: []const u8) !void {
            var cfg = try parseConfigText(a, t);
            cfg.deinit(a);
        }
    }.run, .{text});

    // A late parse error and a missing required field must not leak either.
    try std.testing.expectError(error.InvalidCharacter, parseConfigText(allocator, text ++ "\nport = abc"));
    try std.testing.expectError(error.MissingRequiredField, parseConfigText(allocator, "nickname = \"alpha\""));
    try std.testing.expectError(error.UnsupportedTransport, parseConfigText(allocator, text ++ "\ntransport = \"quic\""));
    try std.testing.expectError(error.InvalidTransport, parseConfigText(allocator, text ++ "\ntransport = \"tpc\""));
}

test "parseConfigText reads repeatable shares" {
    const allocator = std.testing.allocator;
    var config = try parseConfigText(allocator,
        \\nickname = "Desk"
        \\swarm_key = "0123456789abcdef0123456789abcdef"
        \\storage_path = "/tmp/x"
        \\[shares]
        \\share = "Documents:/home/me/Documents"
        \\share = "Camera: /sdcard/DCIM/Camera"
        \\share = "Documents:/srv/docs"
    );
    defer config.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 2), config.shares.len);
    try std.testing.expectEqualStrings("Documents", config.shares[0].name);
    try std.testing.expectEqualStrings("/srv/docs", config.shares[0].path);
    try std.testing.expectEqualStrings("Camera", config.shares[1].name);
    try std.testing.expectEqualStrings("/sdcard/DCIM/Camera", config.shares[1].path);
    try std.testing.expectError(error.InvalidShare, Config.Share.parse("no-colon"));
}
