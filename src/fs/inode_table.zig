//! Inode lifetime and names. The caller holds Mount.lock (L1).
//! IDs are never reused. Names may detach while kernel lookups/open handles
//! keep the inode alive; parents stay alive until their last child leaves.
const std = @import("std");
pub const root: u64 = 1;

pub fn Table(comptime T: type) type {
    return struct {
        const Self = @This();
        pub const Entry = struct {
            data: T,
            parent: u64 = 0,
            key: []u8 = &.{},
            nlookup: u64 = 0,
            kids: u32 = 0,
            pins: u32 = 0,
        };
        allocator: std.mem.Allocator,
        map: std.AutoHashMapUnmanaged(u64, Entry) = .empty,
        names: std.StringHashMapUnmanaged(u64) = .empty,
        next: u64 = 2,

        pub fn init(allocator: std.mem.Allocator, data: T) !Self {
            var self = Self{ .allocator = allocator };
            try self.map.put(allocator, root, .{ .data = data });
            return self;
        }

        pub fn deinit(self: *Self) void {
            var it = self.map.valueIterator();
            while (it.next()) |e| self.allocator.free(e.key);
            self.names.deinit(self.allocator);
            self.map.deinit(self.allocator);
        }

        fn keyOf(buf: *[264]u8, parent: u64, name: []const u8) ?[]const u8 {
            if (name.len > 256) return null;
            std.mem.writeInt(u64, buf[0..8], parent, .little);
            @memcpy(buf[8..][0..name.len], name);
            return buf[0 .. 8 + name.len];
        }

        pub fn find(self: *const Self, parent: u64, name: []const u8) ?u64 {
            var buf: [264]u8 = undefined;
            return self.names.get(keyOf(&buf, parent, name) orelse return null);
        }

        pub fn getOrCreate(self: *Self, parent: u64, name: []const u8, data: T, equivalent: *const fn (T, T) bool) !u64 {
            if (!self.map.contains(parent)) return error.FileNotFound;
            var buf: [264]u8 = undefined;
            const key = keyOf(&buf, parent, name) orelse return error.NameTooLong;
            const old = self.names.get(key);
            if (old) |ino| {
                const e = self.map.getPtr(ino).?;
                if (equivalent(e.data, data)) {
                    e.data = data;
                    return ino;
                }
            }
            if (self.next >= (@as(u64, 1) << 63)) return error.InodeExhausted;
            const owned = try self.allocator.dupe(u8, key);
            errdefer self.allocator.free(owned);
            try self.map.ensureUnusedCapacity(self.allocator, 1);
            try self.names.ensureUnusedCapacity(self.allocator, 1);
            // Replacing the last child must not evict its parent midway.
            self.pin(parent);
            if (old != null) self.detach(parent, name);
            const ino = self.next;
            self.next += 1;
            self.map.putAssumeCapacity(ino, .{ .data = data, .parent = parent, .key = owned });
            self.names.putAssumeCapacity(owned, ino);
            self.map.getPtr(parent).?.kids += 1;
            self.unpin(parent);
            return ino;
        }

        pub fn ref(self: *Self, ino: u64) void {
            if (ino == root) return;
            if (self.map.getPtr(ino)) |e| e.nlookup += 1;
        }

        pub fn unref(self: *Self, ino: u64, n: u64) void {
            if (ino == root) return;
            if (self.map.getPtr(ino)) |e| e.nlookup -|= n;
            self.evictIfDead(ino);
        }

        pub fn pin(self: *Self, ino: u64) void {
            if (self.map.getPtr(ino)) |e| e.pins += 1;
        }

        pub fn unpin(self: *Self, ino: u64) void {
            if (self.map.getPtr(ino)) |e| {
                std.debug.assert(e.pins > 0);
                e.pins -= 1;
            }
            self.evictIfDead(ino);
        }

        pub fn detach(self: *Self, parent: u64, name: []const u8) void {
            const ino = self.find(parent, name) orelse return;
            const e = self.map.getPtr(ino).?;
            std.debug.assert(self.names.remove(e.key));
            self.allocator.free(e.key);
            e.key = &.{};
            e.parent = 0;
            self.map.getPtr(parent).?.kids -= 1;
            self.evictIfDead(ino);
            self.evictIfDead(parent);
        }

        pub fn move(self: *Self, old_parent: u64, old_name: []const u8, new_parent: u64, new_name: []const u8) !void {
            const ino = self.find(old_parent, old_name) orelse return;
            if (old_parent == new_parent and std.mem.eql(u8, old_name, new_name)) return;
            if (!self.map.contains(new_parent)) return error.FileNotFound;
            // Reject cycles before touching any names.
            var ancestor = new_parent;
            while (ancestor != 0) {
                if (ancestor == ino) return error.InvalidPath;
                ancestor = self.map.get(ancestor).?.parent;
            }
            var buf: [264]u8 = undefined;
            const key = keyOf(&buf, new_parent, new_name) orelse return error.NameTooLong;
            const owned = try self.allocator.dupe(u8, key);
            errdefer self.allocator.free(owned);
            try self.names.ensureUnusedCapacity(self.allocator, 1);
            self.pin(old_parent);
            self.pin(new_parent);
            self.detach(new_parent, new_name);
            const e = self.map.getPtr(ino).?;
            std.debug.assert(self.names.remove(e.key));
            self.allocator.free(e.key);
            e.key = owned;
            e.parent = new_parent;
            self.names.putAssumeCapacity(owned, ino);
            self.map.getPtr(old_parent).?.kids -= 1;
            self.map.getPtr(new_parent).?.kids += 1;
            self.unpin(old_parent);
            self.unpin(new_parent);
        }

        pub fn evictIfDead(self: *Self, first: u64) void {
            var ino = first;
            while (ino != 0 and ino != root) {
                const e = self.map.get(ino) orelse return;
                if (e.nlookup != 0 or e.kids != 0 or e.pins != 0) return;
                if (e.key.len != 0) {
                    std.debug.assert(self.names.get(e.key).? == ino);
                    std.debug.assert(self.names.remove(e.key));
                }
                self.allocator.free(e.key);
                std.debug.assert(self.map.remove(ino));
                if (e.parent != 0) self.map.getPtr(e.parent).?.kids -= 1;
                ino = e.parent;
            }
        }

        pub fn pathOf(self: *const Self, allocator: std.mem.Allocator, ino: u64, stop: u64) ![]u8 {
            var parts: [32][]const u8 = undefined;
            var depth: usize = 0;
            var cursor = ino;
            while (cursor != stop) {
                const e = self.map.get(cursor) orelse return error.Detached;
                if (e.parent == 0) return error.Detached;
                if (depth == parts.len) return error.InvalidPath;
                parts[depth] = e.key[8..];
                depth += 1;
                cursor = e.parent;
            }
            std.mem.reverse([]const u8, parts[0..depth]);
            return std.mem.join(allocator, "/", parts[0..depth]);
        }

        pub fn count(self: *const Self) usize {
            return self.map.count();
        }

        pub fn assertConsistent(self: *const Self) void {
            var it = self.map.iterator();
            var attached: usize = 0;
            while (it.next()) |kv| {
                const e = kv.value_ptr;
                if (e.kids > 0) {
                    var kids: u32 = 0;
                    var children = self.map.valueIterator();
                    while (children.next()) |child| {
                        if (child.parent == kv.key_ptr.*) kids += 1;
                    }
                    std.debug.assert(kids == e.kids);
                }
                std.debug.assert(kv.key_ptr.* < self.next);
                if (e.key.len != 0) {
                    attached += 1;
                    std.debug.assert(self.names.get(e.key).? == kv.key_ptr.*);
                    std.debug.assert(self.map.get(e.parent).?.kids > 0);
                } else std.debug.assert(e.parent == 0);
            }
            std.debug.assert(attached == self.names.count());
        }
    };
}

const TestTable = Table(bool);
fn same(a: bool, b: bool) bool {
    return a == b;
}

test "inode table: refs, pins, saturation, cascade and detached names" {
    var t = try TestTable.init(std.testing.allocator, false);
    defer t.deinit();
    const p = try t.getOrCreate(root, "p", false, same);
    const c = try t.getOrCreate(p, "c", true, same);
    t.ref(p);
    t.ref(c);
    t.ref(c);
    t.unref(p, 1);
    t.unref(c, 1);
    try std.testing.expectEqual(@as(usize, 3), t.count());
    t.pin(c);
    t.unref(c, 100);
    try std.testing.expectEqual(@as(usize, 3), t.count());
    t.unpin(c);
    try std.testing.expectEqual(@as(usize, 1), t.count());
    t.unref(root, 100);
    t.unref(999, 100);
    const old = try t.getOrCreate(root, "x", true, same);
    t.ref(old);
    t.detach(root, "x");
    const fresh = try t.getOrCreate(root, "x", true, same);
    try std.testing.expect(fresh > old);
    try std.testing.expect(t.map.contains(old));
    t.detach(root, "x");
    try std.testing.expect(!t.map.contains(fresh));
    t.unref(old, 1);
    t.assertConsistent();
    try std.testing.expectEqual(@as(usize, 1), t.count());
}

test "inode table: type replacement, rename ancestry and overwritten target" {
    const a = std.testing.allocator;
    var t = try TestTable.init(a, false);
    defer t.deinit();
    const old = try t.getOrCreate(root, "a", true, same);
    t.ref(old);
    const dir = try t.getOrCreate(root, "a", false, same);
    t.ref(dir);
    try std.testing.expect(dir != old);
    const child = try t.getOrCreate(dir, "child", true, same);
    t.ref(child);
    const target = try t.getOrCreate(root, "b", true, same);
    t.ref(target);
    try t.move(root, "a", root, "b");
    const path = try t.pathOf(a, child, root);
    defer a.free(path);
    try std.testing.expectEqualStrings("b/child", path);
    try std.testing.expectEqual(@as(u64, 0), t.map.get(target).?.parent);
    try std.testing.expectError(error.InvalidPath, t.move(root, "b", child, "cycle"));
    t.detach(root, "b");
    try std.testing.expectError(error.Detached, t.pathOf(a, child, root));
    t.unref(child, 1);
    t.unref(dir, 1);
    t.unref(old, 1);
    t.unref(target, 1);
    t.assertConsistent();
    try std.testing.expectEqual(@as(usize, 1), t.count());
}

test "inode table: rename allocation failure leaves both names intact" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var t = try TestTable.init(failing.allocator(), false);
    defer t.deinit();
    const a = try t.getOrCreate(root, "a", true, same);
    t.ref(a);
    const b = try t.getOrCreate(root, "b", true, same);
    t.ref(b);
    failing.fail_index = failing.alloc_index;
    try std.testing.expectError(error.OutOfMemory, t.move(root, "a", root, "b"));
    try std.testing.expectEqual(a, t.find(root, "a").?);
    try std.testing.expectEqual(b, t.find(root, "b").?);
    t.assertConsistent();
}

test "inode table: depth 32 paths" {
    var t = try TestTable.init(std.testing.allocator, false);
    defer t.deinit();
    var parent: u64 = root;
    for (0..32) |_| parent = try t.getOrCreate(parent, "x", false, same);
    const path = try t.pathOf(std.testing.allocator, parent, root);
    defer std.testing.allocator.free(path);
    try std.testing.expectEqual(@as(usize, 63), path.len);
    t.ref(parent);
    t.unref(parent, 1);
    try std.testing.expectEqual(@as(usize, 1), t.count());
}

test "inode table: randomized flat name model, two seeds" {
    for ([_]u64{ 7, 0x5eed }) |seed| {
        var t = try TestTable.init(std.testing.allocator, false);
        defer t.deinit();
        var names = [_]?u64{null} ** 16;
        var refs: std.AutoHashMap(u64, u64) = .init(std.testing.allocator);
        defer refs.deinit();
        var rng = std.Random.DefaultPrng.init(seed);
        for (0..10_000) |_| {
            const i = rng.random().uintLessThan(usize, names.len);
            const j = rng.random().uintLessThan(usize, names.len);
            const name = [_]u8{@intCast('a' + i)};
            switch (rng.random().uintLessThan(u8, 4)) {
                0 => {
                    const ino = try t.getOrCreate(root, &name, true, same);
                    if (names[i]) |expected| try std.testing.expectEqual(expected, ino);
                    names[i] = ino;
                    const r = try refs.getOrPut(ino);
                    if (!r.found_existing) r.value_ptr.* = 0;
                    r.value_ptr.* += 1;
                    t.ref(ino);
                },
                1 => if (names[i]) |ino| {
                    const r = refs.getPtr(ino).?;
                    r.* -= 1;
                    t.unref(ino, 1);
                    if (r.* == 0) {
                        names[i] = null;
                        _ = refs.remove(ino);
                    }
                },
                2 => {
                    t.detach(root, &name);
                    names[i] = null;
                },
                3 => if (i != j and names[i] != null) {
                    const dest = [_]u8{@intCast('a' + j)};
                    try t.move(root, &name, root, &dest);
                    names[j] = names[i];
                    names[i] = null;
                },
                else => unreachable,
            }
            for (names, 0..) |expected, k| {
                const key = [_]u8{@intCast('a' + k)};
                try std.testing.expectEqual(expected, t.find(root, &key));
            }
            var it = refs.iterator();
            while (it.next()) |kv| try std.testing.expectEqual(kv.value_ptr.*, t.map.get(kv.key_ptr.*).?.nlookup);
            try std.testing.expectEqual(refs.count() + 1, t.count());
            t.assertConsistent();
        }
    }
}
