//! Changing a setting, the same way from every front end: saved in the
//! config (config_file.zig) so it holds after a restart, and applied to the
//! running node at once when there is one (`node` null: only saved).

const std = @import("std");
const config_file = @import("config_file.zig");
const Node = @import("node.zig").Node;
const codec = @import("storage/dag/codec.zig");

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

// ---- Joining a swarm ----

const Membership = @import("device/membership.zig").Membership;

/// Joins another device's swarm with its invite code (device/membership.zig)
/// and saves the swarm key and the inviter's address. The node must be
/// (re)started on the config afterwards: the swarm key is fixed for a run.
pub fn joinSwarm(allocator: std.mem.Allocator, config_path: []const u8, membership: *Membership, code: []const u8, addresses: []const u8, now: u64) !Membership.Joined {
    var joined = try membership.join(code, addresses, now);
    errdefer std.crypto.secureZero(u8, &joined.swarm_key);
    try config_file.setSwarmKey(allocator, config_path, joined.swarm_key, 0);
    try config_file.addBootstrapPeers(allocator, config_path, &.{joined.peer()});
    std.crypto.secureZero(u8, &joined.swarm_key);
    return joined;
}

// ---- Shared folders ----

/// Shares a folder, saved in the config (`share = "Name:/path"`) and, with a
/// node, scanned and offered at once. `backup` also marks it for backup.
pub fn addShare(allocator: std.mem.Allocator, config_path: []const u8, node: ?*Node, name_in: []const u8, path_in: []const u8, backup: bool) !void {
    const name = std.mem.trim(u8, name_in, " \t");
    const path = std.mem.trim(u8, path_in, " \t");
    if (!codec.isValidName(name) or std.mem.indexOfScalar(u8, name, ':') != null) return error.InvalidShareName;
    if (path.len == 0 or std.mem.indexOfAny(u8, path, "\"\n") != null) return error.InvalidPath;
    if (node) |n| try n.addShare(name, path);
    try config_file.setShare(allocator, config_path, name, path);
    if (backup) try shareBackup(allocator, config_path, node, name, true);
}

/// Stops sharing a folder and drops its backup mark.
pub fn removeShare(allocator: std.mem.Allocator, config_path: []const u8, node: ?*Node, name: []const u8) !void {
    if (node) |n| _ = try n.removeShare(name);
    try config_file.removeShare(allocator, config_path, name);
}

/// Marks a share for backup, or not.
pub fn shareBackup(allocator: std.mem.Allocator, config_path: []const u8, node: ?*Node, name: []const u8, on: bool) !void {
    if (node) |n| try n.setShareBackup(name, on);
    try config_file.setShareBackup(allocator, config_path, name, on);
}

// ---- The read cache ----

const config_mod = @import("config.zig");
const StorageEngine = @import("storage/engine.zig").StorageEngine;

pub const CacheInfo = struct { bytes: u64, blocks: u64, limit_mb: u64 };

/// The read cache's size: the running node's (with its live limit), or the
/// config's store opened for the call.
pub fn cacheInfo(allocator: std.mem.Allocator, config: config_mod.Config, node: ?*Node) !CacheInfo {
    if (node) |n| {
        const stats = try n.cacheStats();
        return .{ .bytes = stats.bytes, .blocks = stats.blocks, .limit_mb = (stats.limit orelse 0) / (1024 * 1024) };
    }
    var store = try openStore(allocator, config);
    defer store.deinit();
    const stats = store.cacheStats();
    return .{ .bytes = stats.bytes, .blocks = stats.blocks, .limit_mb = config.storage.cache_mb };
}

/// Empties the read cache; returns the bytes freed. Kept blocks stay.
pub fn cacheClear(allocator: std.mem.Allocator, config: config_mod.Config, node: ?*Node) !u64 {
    if (node) |n| return n.clearCache();
    var store = try openStore(allocator, config);
    defer store.deinit();
    return store.clearCache();
}

fn openStore(allocator: std.mem.Allocator, config: config_mod.Config) !StorageEngine {
    if (!config.storage.enabled) return error.StorageDisabled;
    return StorageEngine.init(allocator, config.storage.storage_path);
}
