//! Shared folders: scan a local folder into a Merkle tree (scan.zig), list
//! what a device shares (shares.zig), and read any tree block by block,
//! locally or from the device that shares it (tree.zig, remote.zig).

const std = @import("std");
const builtin = @import("builtin");

pub const scan = @import("scan.zig");
pub const shares = @import("shares.zig");
pub const inode_table = @import("inode_table.zig");
pub const tree = @import("tree.zig");
pub const remote = @import("remote.zig");
pub const filestore = @import("filestore.zig");
pub const manifest = @import("manifest.zig");
pub const swarm = @import("swarm.zig");
pub const readahead = @import("readahead.zig");
pub const device_names = @import("device_names.zig");
pub const backup_import = @import("backup_import.zig");
pub const inspect = @import("inspect.zig");
/// Read-only FUSE mount of every device's shares (desktop Linux only).
pub const fuse = if (builtin.os.tag == .linux and !builtin.abi.isAndroid()) @import("fuse.zig") else struct {};

pub const ShareIndex = shares.ShareIndex;
pub const Remote = remote.Remote;
pub const SwarmFolder = swarm.SwarmFolder;
pub const ReadAhead = readahead.ReadAhead;
pub const BackupImport = backup_import.BackupImport;

test {
    _ = scan;
    _ = @import("scan_cache.zig");
    _ = shares;
    _ = tree;
    _ = inode_table;
    _ = remote;
    _ = filestore;
    _ = manifest;
    _ = swarm;
    _ = backup_import;
    _ = device_names;
    std.testing.refAllDecls(fuse);
}
