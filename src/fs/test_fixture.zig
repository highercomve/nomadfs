//! A swarm folder on a temporary store, for the tests of everything that
//! sits on it (the folder itself, notes, the backup import).

const std = @import("std");
const storage = @import("../storage/mod.zig");

/// `SwarmFolder` is passed in (not imported) so the folder's own tests can use
/// this file without the two importing each other.
pub fn Fixture(comptime SwarmFolder: type) type {
    return struct {
        const Self = @This();

        tmp: std.testing.TmpDir,
        /// The temporary directory (absolute); the store is `<dir>/blocks`.
        dir: []u8,
        store: storage.engine.StorageEngine,
        folder: *SwarmFolder,
        device_byte: u8,
        name: []const u8,
        manifest_path: []u8,
        clock_path: []u8,

        /// `device_byte`: this device's ID, filled with that byte.
        pub fn open(self: *Self, device_byte: u8, name: []const u8) !void {
            const allocator = std.testing.allocator;
            const io = std.testing.io;
            self.tmp = std.testing.tmpDir(.{});
            errdefer self.tmp.cleanup();
            var path_buf: [std.fs.max_path_bytes]u8 = undefined;
            self.dir = try allocator.dupe(u8, path_buf[0..try self.tmp.dir.realPath(io, &path_buf)]);
            errdefer allocator.free(self.dir);
            const blocks = try std.fs.path.join(allocator, &.{ self.dir, "blocks" });
            defer allocator.free(blocks);
            self.store = try storage.engine.StorageEngine.init(allocator, blocks);
            errdefer self.store.deinit();
            self.manifest_path = try std.fs.path.join(allocator, &.{ self.dir, "manifest.json" });
            errdefer allocator.free(self.manifest_path);
            self.clock_path = try std.fmt.allocPrint(allocator, "{s}.clock", .{self.manifest_path});
            errdefer allocator.free(self.clock_path);
            self.device_byte = device_byte;
            self.name = name;
            self.folder = try SwarmFolder.create(allocator, io, &self.store, .{ .bytes = [_]u8{device_byte} ** 32 }, name, self.manifest_path);
        }

        /// A restart of the device; `drop_manifest` deletes the manifest file
        /// first (after the folder wrote it), as a lost file would be.
        pub fn reopen(self: *Self, drop_manifest: bool) !void {
            self.folder.destroy();
            if (drop_manifest) std.Io.Dir.cwd().deleteFile(std.testing.io, self.manifest_path) catch {};
            self.folder = try SwarmFolder.create(std.testing.allocator, std.testing.io, &self.store, .{ .bytes = [_]u8{self.device_byte} ** 32 }, self.name, self.manifest_path);
        }

        pub fn close(self: *Self) void {
            self.folder.destroy();
            self.store.deinit();
            std.testing.allocator.free(self.manifest_path);
            std.testing.allocator.free(self.clock_path);
            std.testing.allocator.free(self.dir);
            self.tmp.cleanup();
        }
    };
}
