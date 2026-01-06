const std = @import("std");
const builtin = @import("builtin");
const Block = @import("block.zig").Block;

pub const StorageEngine = struct {
    root_dir: std.fs.Dir,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, path: []const u8) !StorageEngine {
        var expanded_path: []const u8 = path;
        var owned_path: ?[]const u8 = null;
        defer if (owned_path) |p| allocator.free(p);

        // Create directory if it doesn't exist

        if (std.mem.startsWith(u8, path, "~")) {
            const home_env = if (builtin.os.tag == .windows) "USERPROFILE" else "HOME";
            if (std.process.getEnvVarOwned(allocator, home_env)) |home| {
                defer allocator.free(home);
                owned_path = try std.fs.path.join(allocator, &.{ home, path[1..] });
                expanded_path = owned_path.?;
            } else |_| {}
        }
        std.fs.cwd().makePath(expanded_path) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };

        const dir = try std.fs.cwd().openDir(expanded_path, .{});
        return StorageEngine{
            .root_dir = dir,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *StorageEngine) void {
        self.root_dir.close();
    }

    pub fn put(self: *StorageEngine, block: Block) !void {
        std.debug.assert(block.data.len > 0);
        std.debug.assert(block.cid.len == 32);
        std.debug.assert(self.allocator != null);

        const hex_cid = try std.fmt.allocPrint(self.allocator, "{s}", .{std.fmt.fmtSliceHexLower(&block.cid)});
        defer self.allocator.free(hex_cid);

        const file = try self.root_dir.createFile(hex_cid, .{});
        defer file.close();

        const bytes_written = try file.writeAll(block.data);
        std.debug.assert(bytes_written == block.data.len);
    }

    pub fn get(self: *StorageEngine, cid: []const u8, allocator: std.mem.Allocator) !?Block {
        std.debug.assert(cid.len == 32);
        std.debug.assert(allocator != null);

        const hex_cid = try std.fmt.allocPrint(allocator, "{s}", .{std.fmt.fmtSliceHexLower(cid)});
        defer allocator.free(hex_cid);

        const file = self.root_dir.openFile(hex_cid, .{}) catch |err| switch (err) {
            error.FileNotFound => return null,
            else => return err,
        };
        defer file.close();

        const size = try file.getEndPos();
        std.debug.assert(size > 0);
        const buffer = try allocator.alloc(u8, size);
        const read_bytes = try file.readAll(buffer);

        if (read_bytes != size) {
            allocator.free(buffer);
            return error.ReadError;
        }

        std.debug.assert(read_bytes == size);

        // Verify hash? For now just return
        var hash: [32]u8 = undefined;
        @memcpy(&hash, cid);

        return Block{
            .cid = hash,
            .data = buffer,
        };
    }
};
