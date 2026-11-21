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
/// Which roots this device must keep (what the collection may not delete).
pub const live_set = @import("live_set.zig");
pub const notes = @import("notes.zig");
/// What kind of picture or film a file is, and the timeline of them all.
pub const media = @import("media.zig");
pub const photos = @import("photos.zig");
/// Thumbnails of those: where they are kept, and how one is come by.
pub const thumb_store = @import("thumb_store.zig");
pub const thumbs = @import("thumbs.zig");
pub const raw_preview = @import("raw_preview.zig");
pub const readahead = @import("readahead.zig");
pub const device_names = @import("device_names.zig");
pub const backup_import = @import("backup_import.zig");
/// Files a front end sends in pieces, staged until they go into the swarm folder.
pub const uploads = @import("uploads.zig");
pub const inspect = @import("inspect.zig");
/// The devices a mount shows (FUSE and WebDAV).
pub const devices = @import("devices.zig");
/// Read-only FUSE mount of every device's shares (desktop Linux only).
pub const fuse = if (builtin.os.tag == .linux and !builtin.abi.isAndroid()) @import("fuse.zig") else struct {};

pub const ShareIndex = shares.ShareIndex;
pub const Remote = remote.Remote;
pub const SwarmFolder = swarm.SwarmFolder;
pub const Thumbs = thumbs.Thumbs;
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
    _ = live_set;
    _ = notes;
    _ = media;
    _ = photos;
    _ = thumb_store;
    _ = thumbs;
    _ = raw_preview;
    _ = backup_import;
    _ = uploads;
    _ = device_names;
    _ = devices;
    std.testing.refAllDecls(fuse);
}
