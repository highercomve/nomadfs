//! Snapshot source: fs decides what the swarm folder contains. The cluster
//! target receives only immutable file descriptions and reachable local CIDs.
//! A file whose blocks are not all in the local store (the keeper is still
//! fetching it) is left out and counted: a snapshot never holds half a file.
const std = @import("std");
const offsite = @import("../cluster/offsite.zig");
const storage = @import("../storage/mod.zig");
const SwarmFolder = @import("swarm.zig").SwarmFolder;
pub const Source = struct {
    folder: *SwarmFolder,
    store: *storage.engine.StorageEngine,
    pub fn source(self: *Source) offsite.Source {
        return .{ .ctx = self, .filesFn = files };
    }
    fn files(ctx: *anyopaque, a: std.mem.Allocator) !offsite.Listing {
        const self: *Source = @ptrCast(@alignCast(ctx));
        // Public manifest export takes one immutable view under the folder
        // lock, including empty directories. Never inspect folder internals.
        const provider = self.folder.source();
        const bytes = try provider.listFn(provider.ctx, a);
        defer a.free(bytes);
        var parsed = try @import("manifest.zig").Manifest.parse(a, bytes);
        defer parsed.deinit();
        var out: std.ArrayList(offsite.File) = .empty;
        var waiting: usize = 0;
        // Listed by the folder but not uploadable yet: named, so a purge
        // asked for now covers them too.
        var absent: std.ArrayList(offsite.Version) = .empty;
        for (parsed.wire) |entry| {
            if (entry.x) continue;
            if (!@import("manifest.zig").validPath(entry.p)) return error.InvalidPath;
            const path = try a.dupe(u8, entry.p);
            if (entry.k == 1) {
                try out.append(a, .{ .path = path, .cid = [_]u8{0} ** 32, .size = 0, .mtime = entry.m, .blocks = &.{}, .directory = true });
                continue;
            }
            if (entry.k != 0 or entry.h.len != 64) return error.InvalidManifest;
            var root: [32]u8 = undefined;
            _ = try std.fmt.hexToBytes(&root, entry.h);
            var reached = storage.dag.walk.collectReachableWithOptions(a, self.store, &root, .{ .read_leaves = false }) catch |err| switch (err) {
                error.BlockNotFound => {
                    try absent.append(a, .{ .path = path, .cid = root });
                    waiting += 1;
                    continue;
                },
                else => return err,
            };
            defer reached.deinit(a);
            if (reached.count() > 1 << 20) return error.DagTooLarge;
            const cids = try a.alloc([32]u8, reached.count());
            var it = reached.keyIterator();
            var i: usize = 0;
            while (it.next()) |cid| : (i += 1) cids[i] = cid.*;
            try out.append(a, .{ .path = path, .cid = root, .size = entry.s, .mtime = entry.m, .blocks = cids });
        }
        return .{ .files = try out.toOwnedSlice(a), .waiting = waiting, .absent = try absent.toOwnedSlice(a) };
    }
};
