//! Swarm key rotation, the same from every front end. The key is fixed for
//! a node's run (it keys every connection), so a new one is saved in the
//! config and the node restarts on it; how a front end restarts its node
//! is the one thing it supplies.

const std = @import("std");
const sync = @import("sync.zig");
const config_file = @import("config_file.zig");
const config_mod = @import("config.zig");
const Node = @import("node.zig").Node;

/// Adopts keys trusted devices send (the node verifies them first). One per
/// process, outliving the nodes it restarts: its worker thread is detached.
pub const Adopter = struct {
    restart: Restart,
    mutex: sync.Mutex = .{},
    /// Guarded by `mutex`, like everything below.
    path_buf: [std.fs.max_path_bytes]u8 = undefined,
    path_len: usize = 0,
    key: [32]u8 = undefined,
    /// 0: nothing pending.
    epoch: u64 = 0,
    worker_active: bool = false,

    pub const Restart = struct {
        ctx: ?*anyopaque = null,
        /// Stops the running node and starts it again on `config_path`.
        /// Called on the adopter's own thread, never a node's.
        restartFn: *const fn (ctx: ?*anyopaque, config_path: []const u8) void,
    };

    /// The config a received key is saved in: the one the node runs on.
    pub fn watch(self: *Adopter, node: *Node, config_path: []const u8) !void {
        if (config_path.len > self.path_buf.len) return error.NameTooLong;
        self.mutex.lock();
        defer self.mutex.unlock();
        @memcpy(self.path_buf[0..config_path.len], config_path);
        self.path_len = config_path.len;
        node.discovery_node.rotation_sink = .{ .ctx = self, .applyFn = apply };
    }

    /// From a request thread: save and restart on another thread, so the
    /// request can still be answered.
    fn apply(ctx: *anyopaque, new_key: [32]u8, epoch: u64) void {
        const self: *Adopter = @ptrCast(@alignCast(ctx));
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.epoch != 0 and epoch <= self.epoch) return;
        self.key = new_key;
        self.epoch = epoch;
        if (self.worker_active) return;
        self.worker_active = true;
        if (std.Thread.spawn(.{}, worker, .{self})) |t| {
            t.detach();
        } else |err| {
            self.worker_active = false;
            std.crypto.secureZero(u8, &self.key);
            self.epoch = 0;
            std.debug.print("rotation: failed to start the worker: {any}\n", .{err});
        }
    }

    fn worker(self: *Adopter) void {
        sync.sleep(500 * std.time.ns_per_ms); // let the request be answered
        const gpa = std.heap.page_allocator;
        var path_buf: [std.fs.max_path_bytes]u8 = undefined;
        // Bounded: each round takes a newer epoch, and senders are trusted.
        while (true) {
            var key: [32]u8 = undefined;
            defer std.crypto.secureZero(u8, &key);
            const epoch, const path = blk: {
                self.mutex.lock();
                defer self.mutex.unlock();
                if (self.epoch == 0) {
                    self.worker_active = false;
                    return;
                }
                key = self.key;
                const e = self.epoch;
                std.crypto.secureZero(u8, &self.key);
                self.epoch = 0;
                @memcpy(path_buf[0..self.path_len], self.path_buf[0..self.path_len]);
                break :blk .{ e, path_buf[0..self.path_len] };
            };
            config_file.setSwarmKey(gpa, path, key, epoch) catch |err| {
                std.debug.print("rotation: saving the new key failed: {any}\n", .{err});
                continue;
            };
            std.debug.print("rotation: adopted swarm key epoch {d}; restarting the node\n", .{epoch});
            self.restart.restartFn(self.restart.ctx, path);
        }
    }
};

/// Sends a fresh swarm key to every trusted device reachable now and saves
/// it here, at the next epoch; the caller restarts the node on it. Devices
/// not paired, or offline, keep the old key and are listed so they can be
/// invited again. Names are owned by the caller (free each and the slice).
pub fn rotate(allocator: std.mem.Allocator, config_path: []const u8, node: *Node) ![]Node.Delivery {
    var config = config_mod.parseConfig(allocator, config_path) catch return error.ConfigInvalid;
    const epoch = config.node.swarm_epoch + 1;
    config.deinit(allocator);

    var key: [32]u8 = undefined;
    try std.Io.Threaded.global_single_threaded.io().randomSecure(&key);
    defer std.crypto.secureZero(u8, &key);

    const report = try node.rotateSwarmKey(allocator, key, epoch);
    errdefer {
        for (report) |d| allocator.free(d.name);
        allocator.free(report);
    }
    try config_file.setSwarmKey(allocator, config_path, key, epoch);
    return report;
}

test "key rotation: a received key is saved, then the node restarted" {
    const testing = std.testing;
    const io = std.Io.Threaded.global_single_threaded.io();
    const dir = "test_key_rotation";
    std.Io.Dir.cwd().deleteTree(io, dir) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};
    try std.Io.Dir.cwd().createDirPath(io, dir);
    const path = dir ++ "/nomadfs.conf";
    try config_file.writeAtomic(testing.allocator, io, path, "nickname = \"a\"\nswarm_key = \"" ++ "ab" ** 32 ++ "\"\n");

    const Restarted = struct {
        var count = std.atomic.Value(u32).init(0);
        fn restart(_: ?*anyopaque, _: []const u8) void {
            _ = count.fetchAdd(1, .acq_rel);
        }
    };
    var adopter: Adopter = .{ .restart = .{ .restartFn = Restarted.restart } };
    @memcpy(adopter.path_buf[0..path.len], path);
    adopter.path_len = path.len;
    Adopter.apply(&adopter, [_]u8{0xcd} ** 32, 3);
    Adopter.apply(&adopter, [_]u8{0xee} ** 32, 2); // older: ignored

    var tries: u32 = 0;
    while (Restarted.count.load(.acquire) == 0 and tries < 100) : (tries += 1) sync.sleep(20 * std.time.ns_per_ms);
    try testing.expectEqual(@as(u32, 1), Restarted.count.load(.acquire));
    var buf: [512]u8 = undefined;
    var file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    const text = buf[0..try file.readPositionalAll(io, &buf, 0)];
    try testing.expect(std.mem.indexOf(u8, text, "swarm_key = \"" ++ "cd" ** 32 ++ "\"") != null);
    try testing.expect(std.mem.indexOf(u8, text, "swarm_epoch = 3") != null);
    // The worker is done before the adopter goes out of scope.
    while (true) {
        adopter.mutex.lock();
        const active = adopter.worker_active;
        adopter.mutex.unlock();
        if (!active) break;
        sync.sleep(10 * std.time.ns_per_ms);
    }
}
