const std = @import("std");
const builtin = @import("builtin");
const Block = @import("block.zig").Block;
const sync = @import("../sync.zig");
const env_mod = @import("../env.zig");

pub const StorageEngine = struct {
    root_dir: std.Io.Dir,
    allocator: std.mem.Allocator,
    mutex: sync.Mutex = .{},

    pub fn init(allocator: std.mem.Allocator, path: []const u8) !StorageEngine {
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
        std.Io.Dir.cwd().createDirPath(io, expanded_path) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };

        const dir = try std.Io.Dir.cwd().openDir(io, expanded_path, .{});
        return StorageEngine{
            .root_dir = dir,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *StorageEngine) void {
        const io = std.Io.Threaded.global_single_threaded.io();
        self.root_dir.close(io);
    }

    pub fn put(self: *StorageEngine, block: Block) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (block.data.len == 0) return error.InvalidBlock;
        if (block.cid.len != 32) return error.InvalidBlock;

        var hash: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(block.data, &hash);
        if (!std.mem.eql(u8, &hash, &block.cid)) {
            return error.HashMismatch;
        }

        const hex_cid = try std.fmt.allocPrint(self.allocator, "{s}", .{std.fmt.fmtSliceHexLower(&block.cid)});
        defer self.allocator.free(hex_cid);

        const io = std.Io.Threaded.global_single_threaded.io();
        var file = try self.root_dir.createFile(io, hex_cid, .{});
        defer file.close(io);

        try file.writePositionalAll(io, block.data, 0);
    }

    pub fn get(self: *StorageEngine, cid: []const u8, allocator: std.mem.Allocator) !?Block {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (cid.len != 32) return error.InvalidBlock;

        const hex_cid = try std.fmt.allocPrint(allocator, "{s}", .{std.fmt.fmtSliceHexLower(cid)});
        defer allocator.free(hex_cid);

        const io = std.Io.Threaded.global_single_threaded.io();
        var file = self.root_dir.openFile(io, hex_cid, .{}) catch |err| switch (err) {
            error.FileNotFound => return null,
            else => return err,
        };
        defer file.close(io);

        const stat = try file.stat(io);
        const size = stat.size;
        if (size == 0) return error.InvalidBlock;
        const buffer = try allocator.alloc(u8, size);
        errdefer allocator.free(buffer);

        const read_bytes = try file.readPositionalAll(io, buffer, 0);
        if (read_bytes != size) {
            return error.ReadError;
        }

        var hash: [32]u8 = undefined;
        @memcpy(&hash, cid);

        return Block{
            .cid = hash,
            .data = buffer,
        };
    }
};
