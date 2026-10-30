//! Changing a setting, the same way from every front end: saved in the
//! config (config_file.zig) so it holds after a restart, and applied to the
//! running node at once when there is one (`node` null: only saved).

const std = @import("std");
const config_file = @import("config_file.zig");
const Node = @import("root.zig").Node;

pub fn swarmBackup(allocator: std.mem.Allocator, config_path: []const u8, node: ?*Node, on: bool) !void {
    try config_file.setBool(allocator, config_path, "swarm_backup", on);
    if (node) |n| try n.setSwarmBackup(on);
}

pub fn acceptCopies(allocator: std.mem.Allocator, config_path: []const u8, node: ?*Node, on: bool) !void {
    try config_file.setBool(allocator, config_path, "accept_copies", on);
    if (node) |n| try n.setAcceptCopies(on);
}

/// The read cache's limit in MiB (0: none).
pub fn cacheLimit(allocator: std.mem.Allocator, config_path: []const u8, node: ?*Node, mb: u64) !void {
    _ = std.math.mul(u64, mb, 1024 * 1024) catch return error.InvalidLimit;
    try config_file.setInt(allocator, config_path, "cache_mb", mb);
    if (node) |n| try n.setCacheLimit(mb);
}

/// The swarm's `copies`: a signed swarm-wide setting, not a config line,
/// so it needs the node (its identity and policy). `--copies` applies it at
/// start.
pub fn copies(node: *Node, n: u8) !void {
    try node.setCopies(n);
}

// ---- The read cache ----

const config_mod = @import("config.zig");
const StorageEngine = @import("storage/engine.zig").StorageEngine;

pub const CacheInfo = struct { bytes: u64, blocks: u64, limit_mb: u64 };

/// The read cache's size: the running node's store, or the config's opened
/// for the call.
pub fn cacheInfo(allocator: std.mem.Allocator, config: config_mod.Config, node: ?*Node) !CacheInfo {
    var owned: ?StorageEngine = null;
    defer if (owned) |*o| o.deinit();
    const stats = (try storeFor(allocator, config, node, &owned)).cacheStats();
    return .{ .bytes = stats.bytes, .blocks = stats.blocks, .limit_mb = config.storage.cache_mb };
}

/// Empties the read cache; returns the bytes freed. Kept blocks stay.
pub fn cacheClear(allocator: std.mem.Allocator, config: config_mod.Config, node: ?*Node) !u64 {
    var owned: ?StorageEngine = null;
    defer if (owned) |*o| o.deinit();
    return (try storeFor(allocator, config, node, &owned)).clearCache();
}

fn storeFor(allocator: std.mem.Allocator, config: config_mod.Config, node: ?*Node, owned: *?StorageEngine) !*StorageEngine {
    if (node) |n| if (n.store) |s| return s;
    if (!config.storage.enabled) return error.StorageDisabled;
    owned.* = try StorageEngine.init(allocator, config.storage.storage_path);
    return &owned.*.?;
}
