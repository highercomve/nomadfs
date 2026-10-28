const std = @import("std");
const builtin = @import("builtin");
const Block = @import("block.zig").Block;
const sync = @import("../sync.zig");
const env_mod = @import("../env.zig");

pub const StorageEngine = struct {
    root_dir: std.Io.Dir,
    allocator: std.mem.Allocator,
    mutex: sync.Mutex = .{},
    /// Blocks held outside the store (shared folders' file bytes). Asked
    /// only when no block file exists; what it returns is verified like any
    /// stored block.
    external: ?External = null,

    pub const External = struct {
        ctx: *anyopaque,
        /// Caller-owned block bytes for `cid`, or null when not held.
        getFn: *const fn (ctx: *anyopaque, cid: *const [32]u8, allocator: std.mem.Allocator) anyerror!?[]u8,
        hasFn: *const fn (ctx: *anyopaque, cid: *const [32]u8) bool,
    };

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

    /// Stores a block after checking its hash. Content addressing makes this
    /// idempotent; the block is written to a temporary file and renamed into
    /// place, so a crash never leaves a truncated block under its CID.
    pub fn put(self: *StorageEngine, block: Block) !void {
        var hash: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(block.data, &hash, .{});
        if (!std.mem.eql(u8, &hash, &block.cid)) {
            return error.HashMismatch;
        }

        self.mutex.lock();
        defer self.mutex.unlock();

        const hex_cid = std.fmt.bytesToHex(block.cid, .lower);
        if (self.hasLocked(&hex_cid)) return;

        const io = std.Io.Threaded.global_single_threaded.io();
        const tmp_name = hex_cid ++ ".tmp".*;
        {
            var file = try self.root_dir.createFile(io, &tmp_name, .{});
            defer file.close(io);
            try file.writePositionalAll(io, block.data, 0);
        }
        errdefer self.root_dir.deleteFile(io, &tmp_name) catch {};
        try self.root_dir.rename(&tmp_name, self.root_dir, &hex_cid, io);
    }

    pub fn has(self: *StorageEngine, cid: []const u8) bool {
        if (cid.len != 32) return false;
        self.mutex.lock();
        defer self.mutex.unlock();
        const hex_cid = std.fmt.bytesToHex(cid[0..32], .lower);
        if (self.hasLocked(&hex_cid)) return true;
        const ext = self.external orelse return false;
        return ext.hasFn(ext.ctx, cid[0..32]);
    }

    fn hasLocked(self: *StorageEngine, hex_cid: []const u8) bool {
        const io = std.Io.Threaded.global_single_threaded.io();
        _ = self.root_dir.statFile(io, hex_cid, .{}) catch return false;
        return true;
    }

    /// Returns the block, or null if it is not stored. The data is verified
    /// against the CID so on-disk corruption is reported, not returned.
    /// The bytes of a block stored here (not `external`), unverified, or
    /// null. For walking this device's own parent blocks cheaply: a shared
    /// file's leaves are never read.
    pub fn getLocal(self: *StorageEngine, cid: *const [32]u8, allocator: std.mem.Allocator) !?[]u8 {
        const hex_cid = std.fmt.bytesToHex(cid.*, .lower);
        self.mutex.lock();
        defer self.mutex.unlock();
        const io = std.Io.Threaded.global_single_threaded.io();
        var file = self.root_dir.openFile(io, &hex_cid, .{}) catch |err| switch (err) {
            error.FileNotFound => return null,
            else => return err,
        };
        defer file.close(io);
        const size = (try file.stat(io)).size;
        const buffer = try allocator.alloc(u8, size);
        errdefer allocator.free(buffer);
        if (try file.readPositionalAll(io, buffer, 0) != size) return error.ReadError;
        return buffer;
    }

    pub fn get(self: *StorageEngine, cid: []const u8, allocator: std.mem.Allocator) !?Block {
        if (cid.len != 32) return error.InvalidBlock;
        const hex_cid = std.fmt.bytesToHex(cid[0..32], .lower);

        const buffer = blk: {
            self.mutex.lock();
            defer self.mutex.unlock();

            const io = std.Io.Threaded.global_single_threaded.io();
            var file = self.root_dir.openFile(io, &hex_cid, .{}) catch |err| switch (err) {
                error.FileNotFound => {
                    const ext = self.external orelse return null;
                    break :blk (try ext.getFn(ext.ctx, cid[0..32], allocator)) orelse return null;
                },
                else => return err,
            };
            defer file.close(io);

            const size = (try file.stat(io)).size;
            const buffer = try allocator.alloc(u8, size);
            errdefer allocator.free(buffer);
            if (try file.readPositionalAll(io, buffer, 0) != size) return error.ReadError;
            break :blk buffer;
        };
        errdefer allocator.free(buffer);

        var hash: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(buffer, &hash, .{});
        if (!std.mem.eql(u8, &hash, cid)) return error.CorruptBlock;

        return Block{
            .cid = cid[0..32].*,
            .data = buffer,
        };
    }
};
