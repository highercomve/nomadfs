//! The devices a mount shows: every reachable device's shares, each under a
//! name unique on this device (device_names.zig). The FUSE mount (Linux)
//! and the WebDAV server (macOS, Windows) both read it.
//!
//! A refresher thread asks the known peers for their shares, at most every
//! few seconds and only when something reads the device list; a device
//! that doesn't answer for ten minutes leaves it. Indices into `devices`
//! never change (the list only grows), and each device's Remote lives as
//! long as the directory.

const std = @import("std");
const NodeID = @import("../net/id.zig").NodeID;
const cluster = @import("../cluster/mod.zig");
const sync = @import("../sync.zig");
const tree = @import("tree.zig");
const remote_mod = @import("remote.zig");
const device_names = @import("device_names.zig");
const device_trust = @import("../device/trust.zig");
pub const Remote = remote_mod.Remote;

/// How long a device list stays fresh before peers are asked again.
const refresh_interval_ms = 5 * std.time.ms_per_s;
const refresh_parallel = 8;
/// How long a first listing waits for the first answers.
const first_refresh_wait_ms = 3000;
/// A device not heard from for this long leaves the list.
const forget_after_ms = 10 * 60 * 1000;

pub const Device = struct {
    name: []u8,
    remote: *Remote,
    shares: ?tree.Listing = null,
    online: bool = false,
    last_seen_ms: i64 = 0,
    device_id: ?[32]u8 = null,
    claimed: []u8 = &[_]u8{},
};

/// One share of a device, as listed (names and CIDs copied out).
pub const Share = struct { name: []const u8, cid: tree.Cid, size: u64, mtime: u64 };

/// An online device: its index into `devices` and its folder name.
pub const Named = struct { index: u32, name: []const u8 };

pub const Directory = struct {
    allocator: std.mem.Allocator,
    block_manager: ?*cluster.BlockManager,
    /// Guards `devices`.
    lock: sync.Mutex = .{},
    devices: std.ArrayList(Device) = .empty,
    stopping: std.atomic.Value(bool) = .init(false),
    refresh: struct {
        mutex: sync.Mutex = .{},
        cond: sync.Condition = .{},
        wanted: bool = false,
        first_done: bool = false,
        last_start_ms: i64 = 0,
        thread: ?std.Thread = null,
    } = .{},

    pub fn init(allocator: std.mem.Allocator, block_manager: ?*cluster.BlockManager) Directory {
        return .{ .allocator = allocator, .block_manager = block_manager };
    }

    pub fn deinit(self: *Directory) void {
        self.stop();
        for (self.devices.items) |d| {
            self.allocator.free(d.name);
            if (d.claimed.len > 0) self.allocator.free(d.claimed);
            if (d.shares) |s| s.deinit();
            self.allocator.destroy(d.remote);
        }
        self.devices.deinit(self.allocator);
    }

    /// Starts the refresher thread (idempotent).
    pub fn start(self: *Directory) !void {
        self.refresh.mutex.lock();
        defer self.refresh.mutex.unlock();
        if (self.refresh.thread != null) return;
        self.stopping.store(false, .release);
        self.refresh.thread = try std.Thread.spawn(.{}, refresherMain, .{self});
    }

    /// Stops the refresher thread and waits for it.
    pub fn stop(self: *Directory) void {
        self.stopping.store(true, .release);
        const thread = blk: {
            self.refresh.mutex.lock();
            defer self.refresh.mutex.unlock();
            self.refresh.wanted = true;
            self.refresh.cond.broadcast();
            const t = self.refresh.thread;
            self.refresh.thread = null;
            break :blk t;
        };
        if (thread) |t| t.join();
    }

    /// Before listing the devices: asks for a refresh when the list is
    /// stale and, the first time, waits briefly for the answers. Without
    /// the refresher (tests), refreshes in place.
    pub fn ensureFresh(self: *Directory) void {
        if (self.refresh.thread == null) return self.refreshAll();
        self.requestRefresh();
        self.refresh.mutex.lock();
        defer self.refresh.mutex.unlock();
        if (!self.refresh.first_done and !self.stopping.load(.acquire)) {
            self.refresh.cond.timedWait(&self.refresh.mutex, first_refresh_wait_ms * std.time.ns_per_ms);
        }
    }

    pub fn requestRefresh(self: *Directory) void {
        self.refresh.mutex.lock();
        defer self.refresh.mutex.unlock();
        const now = sync.monotonicMillis();
        if (now - self.refresh.last_start_ms >= refresh_interval_ms) {
            self.refresh.wanted = true;
            self.refresh.cond.signal();
        }
    }

    /// The online devices with a name: (index, name), names in `arena`.
    pub fn online(self: *Directory, arena: std.mem.Allocator) ![]Named {
        self.lock.lock();
        defer self.lock.unlock();
        var out: std.ArrayList(Named) = .empty;
        for (self.devices.items, 0..) |d, i| {
            // A device without a name yet (naming failed) is not listed.
            if (!d.online or d.name.len == 0) continue;
            try out.append(arena, .{ .index = @intCast(i), .name = try arena.dupe(u8, d.name) });
        }
        return out.items;
    }

    /// The online device called `name`.
    pub fn find(self: *Directory, name: []const u8) ?u32 {
        self.lock.lock();
        defer self.lock.unlock();
        for (self.devices.items, 0..) |d, i| {
            if (d.online and std.mem.eql(u8, d.name, name)) return @intCast(i);
        }
        return null;
    }

    /// Device `index`'s Remote (stable for the directory's life).
    pub fn remote(self: *Directory, index: u32) ?*Remote {
        self.lock.lock();
        defer self.lock.unlock();
        if (index >= self.devices.items.len) return null;
        return self.devices.items[index].remote;
    }

    /// Device `index`'s shares, copied into `arena` (empty when unknown).
    pub fn shares(self: *Directory, arena: std.mem.Allocator, index: u32) ![]Share {
        self.lock.lock();
        defer self.lock.unlock();
        if (index >= self.devices.items.len) return &.{};
        const listing = self.devices.items[index].shares orelse return &.{};
        const out = try arena.alloc(Share, listing.entries.len);
        for (listing.entries, out) |e, *o| o.* = .{ .name = try arena.dupe(u8, e.name), .cid = e.cid, .size = e.size, .mtime = e.mtime };
        return out;
    }

    fn refresherMain(self: *Directory) void {
        while (!self.stopping.load(.acquire)) {
            self.refresh.mutex.lock();
            while (!self.refresh.wanted and !self.stopping.load(.acquire)) {
                self.refresh.cond.wait(&self.refresh.mutex);
            }
            if (self.stopping.load(.acquire)) {
                self.refresh.mutex.unlock();
                return;
            }
            self.refresh.wanted = false;
            self.refresh.last_start_ms = sync.monotonicMillis();
            self.refresh.mutex.unlock();

            self.refreshAll();

            self.refresh.mutex.lock();
            self.refresh.first_done = true;
            self.refresh.cond.broadcast();
            self.refresh.mutex.unlock();
        }
    }

    /// Asks every known peer for its shares, `refresh_parallel` at a time.
    pub fn refreshAll(self: *Directory) void {
        const bm = self.block_manager orelse return;
        const peers = remote_mod.knownPeers(bm, self.allocator) catch return;
        defer self.allocator.free(peers);

        {
            self.lock.lock();
            defer self.lock.unlock();
            const now = sync.monotonicMillis();
            for (self.devices.items) |*d| {
                if (now - d.last_seen_ms > forget_after_ms) {
                    if (d.shares) |listing| listing.deinit();
                    d.shares = null;
                    d.online = false;
                }
            }
        }

        var i: usize = 0;
        while (i < peers.len and !self.stopping.load(.acquire)) {
            const batch_end = @min(i + refresh_parallel, peers.len);
            const batch = peers[i..batch_end];
            i = batch_end;

            const ProbeContext = struct {
                directory: *Directory,
                peer: NodeID,
                shares_res: ?Remote.Shares = null,

                fn run(ctx: *@This()) void {
                    var probe = Remote{
                        .block_manager = ctx.directory.block_manager.?,
                        .peer = ctx.peer,
                    };
                    ctx.shares_res = probe.shares(ctx.directory.allocator) catch null;
                }
            };

            var contexts: [refresh_parallel]ProbeContext = undefined;
            var threads: [refresh_parallel]?std.Thread = [_]?std.Thread{null} ** refresh_parallel;

            for (batch, 0..) |peer, b_idx| {
                contexts[b_idx] = .{ .directory = self, .peer = peer };
                threads[b_idx] = std.Thread.spawn(.{}, ProbeContext.run, .{&contexts[b_idx]}) catch null;
                if (threads[b_idx] == null) {
                    contexts[b_idx].run();
                }
            }

            for (batch, 0..) |peer, b_idx| {
                if (threads[b_idx]) |t| t.join();
                if (contexts[b_idx].shares_res) |res| {
                    self.applyShares(peer, res);
                } else {
                    self.lock.lock();
                    for (self.devices.items) |*d| {
                        if (d.remote.peer.eql(peer)) {
                            d.online = false;
                            break;
                        }
                    }
                    self.lock.unlock();
                    // Reads of its files fail fast until it answers again.
                    if (bm.fetcher) |*f| f.markDown(peer);
                }
            }
        }
    }

    /// Records `peer`'s answer (takes ownership of `answer`).
    pub fn applyShares(self: *Directory, peer: NodeID, answer: Remote.Shares) void {
        defer self.allocator.free(answer.nickname);
        self.lock.lock();
        defer self.lock.unlock();

        const bm = self.block_manager orelse {
            answer.listing.deinit();
            return;
        };
        const index = for (self.devices.items, 0..) |d, i| {
            if (d.remote.peer.eql(peer)) break i;
        } else blk: {
            const r = self.allocator.create(Remote) catch {
                answer.listing.deinit();
                return;
            };
            r.* = .{ .block_manager = bm, .peer = peer };
            const name = self.allocator.dupe(u8, "") catch {
                self.allocator.destroy(r);
                answer.listing.deinit();
                return;
            };
            self.devices.append(self.allocator, .{ .name = name, .remote = r }) catch {
                self.allocator.free(name);
                self.allocator.destroy(r);
                answer.listing.deinit();
                return;
            };
            break :blk self.devices.items.len - 1;
        };
        const device = &self.devices.items[index];

        if (device.shares) |old| old.deinit();
        device.online = true;
        device.last_seen_ms = sync.monotonicMillis();
        device.device_id = if (answer.device_id) |id| id.bytes else peer.bytes;
        if (device.claimed.len > 0) self.allocator.free(device.claimed);
        device.claimed = self.allocator.dupe(u8, answer.nickname) catch &[_]u8{};
        device.shares = answer.listing;

        self.recomputeNames();
    }

    /// Recomputes the folder names of all online devices. Caller holds `lock`.
    pub fn recomputeNames(self: *Directory) void {
        var online_count: usize = 0;
        for (self.devices.items) |d| {
            if (d.online) online_count += 1;
        }
        if (online_count == 0) return;

        const online_indices = self.allocator.alloc(usize, online_count) catch return;
        defer self.allocator.free(online_indices);
        const entries = self.allocator.alloc(device_names.Entry, online_count) catch return;
        defer self.allocator.free(entries);
        const out = self.allocator.alloc([]u8, online_count) catch return;
        defer self.allocator.free(out);

        const trust_store = if (self.block_manager) |bm| bm.trustStore() else null;
        var trust_entries: std.ArrayList(device_trust.Entry) = .empty;
        defer trust_entries.deinit(self.allocator);
        trust_entries.ensureTotalCapacity(self.allocator, online_count) catch return;

        var j: usize = 0;
        for (self.devices.items, 0..) |d, i| {
            if (!d.online) continue;
            online_indices[j] = i;
            const dev_id = d.device_id orelse d.remote.peer.bytes;
            var trusted_info: ?device_names.TrustedInfo = null;
            if (trust_store) |ts| {
                if (ts.lookup(NodeID{ .bytes = dev_id })) |te| {
                    trust_entries.appendAssumeCapacity(te);
                    const last_te = &trust_entries.items[trust_entries.items.len - 1];
                    trusted_info = .{
                        .label = last_te.labelSlice(),
                        .added_at = last_te.added_at,
                    };
                }
            }
            entries[j] = .{
                .device_id = dev_id,
                .trusted = trusted_info,
                .nickname = d.claimed,
            };
            j += 1;
        }

        device_names.assign(self.allocator, entries, out) catch |err| {
            std.debug.print("recomputeNames: assign failed: {any}\n", .{err});
            return;
        };

        for (online_indices, out) |dev_idx, new_name| {
            const old_name = self.devices.items[dev_idx].name;
            if (std.mem.eql(u8, old_name, new_name)) {
                self.allocator.free(new_name);
                continue;
            }
            self.devices.items[dev_idx].name = new_name;
            self.allocator.free(old_name);
        }
    }
};
