//! By convention, root.zig is the root source file when making a library.
const std = @import("std");

pub const config = @import("config.zig");
pub const config_file = @import("config_file.zig");
pub const settings = @import("settings.zig");
pub const key_rotation = @import("key_rotation.zig");
pub const net = @import("net/mod.zig");
pub const storage = @import("storage/mod.zig");
pub const device = @import("device/mod.zig");
pub const fs = @import("fs/mod.zig");

pub const node_info = @import("node_info.zig");

/// This release (kept in node_info.zig, which reports it).
pub const version = node_info.version;

// @atlas allow: root pulls the exports in so the library links them
/// C ABI bindings for mobile hosts; the shared library target points here.
pub const mobile_api = @import("mobile/api.zig");

/// Seconds resolution used by tickets, the trust store and revocations.
pub const nowSeconds = sync.nowSeconds;

// Force the C ABI surface into every artifact of this module, so the shared
// library keeps its exports even though nothing below references it.
comptime {
    _ = mobile_api;
}
pub const cluster = @import("cluster/mod.zig");
pub const sync = @import("sync.zig");
pub const env = @import("env.zig");

pub const Node = @import("node.zig").Node;
pub const InfoProvider = @import("node.zig").InfoProvider;

pub const metrics = @import("metrics.zig");
pub const errors = @import("errors.zig");
pub const resilience = @import("net/resilience.zig");

test {
    // Compile every module and all of its declarations, including modules
    // nothing imports yet, so broken code and tests cannot hide.
    inline for (.{
        @import("cluster/block_manager.zig"),
        @import("cluster/fetcher.zig"),
        @import("cluster/placement.zig"),
        @import("cluster/keeper.zig"),
        @import("device/policy.zig"),
        @import("device/membership.zig"),
        @import("cluster/holders.zig"),
        @import("mobile/api.zig"),
        @import("cluster/quorum.zig"),
        @import("cluster/ring.zig"),
        @import("cluster/vectors.zig"),
        @import("config.zig"),
        @import("config_file.zig"),
        @import("settings.zig"),
        @import("key_rotation.zig"),
        @import("node_info.zig"),
        @import("node.zig"),
        @import("device/auth.zig"),
        @import("device/identity.zig"),
        @import("device/invite.zig"),
        @import("device/rotation.zig"),
        @import("device/pairing.zig"),
        @import("device/paths.zig"),
        @import("device/qr.zig"),
        @import("device/trust.zig"),
        @import("env.zig"),
        @import("errors.zig"),
        @import("fs/filestore.zig"),
        @import("fs/backup_import.zig"),
        @import("fs/inspect.zig"),
        @import("fs/manifest.zig"),
        @import("fs/swarm.zig"),
        @import("fs/remote.zig"),
        @import("fs/scan.zig"),
        @import("fs/shares.zig"),
        @import("fs/tree.zig"),
        @import("metrics.zig"),
        @import("net/compat.zig"),
        @import("net/discovery/kbucket.zig"),
        @import("net/discovery/lookup.zig"),
        @import("net/discovery/node.zig"),
        @import("net/discovery/rpc.zig"),
        @import("net/id.zig"),
        @import("net/resilience.zig"),
        @import("net/transport/manager.zig"),
        @import("net/transport/mdns.zig"),
        @import("net/transport/nat.zig"),
        @import("net/transport/noise.zig"),
        @import("net/transport/tcp.zig"),
        @import("net/transport/yamux.zig"),
        @import("storage/block.zig"),
        @import("storage/chunker.zig"),
        @import("storage/dag/builder.zig"),
        @import("storage/dag/codec.zig"),
        @import("storage/dag/diff.zig"),
        @import("storage/dag/node.zig"),
        @import("storage/dag/walk.zig"),
        @import("storage/engine.zig"),
        @import("sync.zig"),
    }) |module| {
        std.testing.refAllDecls(module);
    }
}
