//! Shared folders: scan a local folder into a Merkle tree (scan.zig), list
//! what a device shares (shares.zig), and read any tree block by block,
//! locally or from the device that shares it (tree.zig, remote.zig).

const std = @import("std");
const builtin = @import("builtin");

pub const scan = @import("scan.zig");
pub const shares = @import("shares.zig");
pub const tree = @import("tree.zig");
pub const remote = @import("remote.zig");
pub const filestore = @import("filestore.zig");
pub const manifest = @import("manifest.zig");
pub const swarm = @import("swarm.zig");
pub const readahead = @import("readahead.zig");
/// Read-only FUSE mount of every device's shares (desktop Linux only).
pub const fuse = if (builtin.os.tag == .linux and !builtin.abi.isAndroid()) @import("fuse.zig") else struct {};

pub const ShareIndex = shares.ShareIndex;
pub const Remote = remote.Remote;
pub const SwarmFolder = swarm.SwarmFolder;
pub const ReadAhead = readahead.ReadAhead;

test {
    _ = scan;
    _ = @import("scan_cache.zig");
    _ = shares;
    _ = tree;
    _ = remote;
    _ = filestore;
    _ = manifest;
    _ = swarm;
    std.testing.refAllDecls(fuse);
}
