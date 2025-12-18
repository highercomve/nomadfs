const std = @import("std");
const Block = @import("block.zig").Block;

pub const StorageEngine = struct {
    root_dir: std.fs.Dir,

    pub fn init(path: []const u8) !StorageEngine {
        // Create directory if it doesn't exist
        std.fs.cwd().makeDir(path) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };

        const dir = try std.fs.cwd().openDir(path, .{});
        return StorageEngine{
            .root_dir = dir,
        };
    }

    pub fn deinit(self: *StorageEngine) void {
        self.root_dir.close();
    }

    pub fn put(self: *StorageEngine, block: Block) !void {
        const hex_cid = try std.fmt.allocPrint(std.heap.page_allocator, "{s}", .{std.fmt.fmtSliceHexLower(&block.cid)});
        defer std.heap.page_allocator.free(hex_cid);

        const file = try self.root_dir.createFile(hex_cid, .{});
        defer file.close();

        try file.writeAll(block.data);
    }

    pub fn get(self: *StorageEngine, cid: []const u8, allocator: std.mem.Allocator) !?Block {
        if (cid.len != 32) return error.InvalidCid;
        
        const hex_cid = try std.fmt.allocPrint(allocator, "{s}", .{std.fmt.fmtSliceHexLower(cid)});
        defer allocator.free(hex_cid);

        const file = self.root_dir.openFile(hex_cid, .{}) catch |err| switch (err) {
            error.FileNotFound => return null,
            else => return err,
        };
        defer file.close();

        const size = try file.getEndPos();
        const buffer = try allocator.alloc(u8, size);
        const read_bytes = try file.readAll(buffer);
        
        if (read_bytes != size) {
            allocator.free(buffer);
            return error.ReadError;
        }

        // Verify hash? For now just return
        var hash: [32]u8 = undefined;
        @memcpy(&hash, cid);

        return Block{
            .cid = hash,
            .data = buffer,
        };
    }
};
