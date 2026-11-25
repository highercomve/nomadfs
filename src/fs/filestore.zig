//! Leaf blocks of shared files, served from the files themselves. A shared
//! folder is not copied into the block store: the scanner records where
//! each leaf's bytes sit (file, offset, length) and only the small parent
//! and dir blocks are stored. The StorageEngine asks here for blocks it has
//! no file for (StorageEngine.External), so peers fetch shared files with
//! the same GET_BLOCK as anything else.
//!
//! Bytes are re-hashed on every read: a file edited since the scan no
//! longer matches its recorded CIDs and reads as missing, never as wrong
//! data. The next rescan records the new content.

const std = @import("std");
const sync = @import("../sync.zig");
const storage = @import("../storage/mod.zig");
const codec = storage.dag.codec;

pub const Cid = codec.Cid;

pub const Leaf = struct {
    cid: Cid,
    offset: u64,
    len: u32,
};

const Ref = struct {
    offset: u64,
    file: u32,
    len: u32,
};

comptime {
    std.debug.assert(@sizeOf(Ref) == 16);
}

const Table = struct {
    generation: u64,
    paths: std.ArrayList(FileSlot) = .empty,
    by_path: std.StringHashMapUnmanaged(u32) = .empty,
    refs: Refs = .empty,
    /// Extra locations are needed only for CIDs shared by distinct files.
    copies: Copies = .empty,
    free: ?u32 = null,
    retired: ?u32 = null,
    retired_tail: ?u32 = null,
    retired_chunks: u64 = 0,
    retired_slots: usize = 0,
    refs_removed: u32 = 0,
    copies_removed: u32 = 0,
    paths_removed: u32 = 0,
    mutations: u64 = 0,
    shrinks: u64 = 0,

    // Scale maintenance with the index, with a floor for small shares.
    const sweep_divisor = 16;
    const sweep_chunk_floor = 16;
    const sweep_slot_floor = 16;
    // Leave a wide gap between low utilization and the normal growth load.
    const shrink_divisor = 8;
    const MapField = enum { refs, copies, by_path };

    const Refs = std.AutoHashMapUnmanaged(Cid, Ref);
    const Copies = std.AutoHashMapUnmanaged(Cid, Alternates);
    const FileSlot = struct {
        path: ?[]const u8,
        cid: Cid,
        seen: u32,
        leaf_count: u32,
        next_free: ?u32 = null,
    };

    const Alternates = union(enum) {
        one: Ref,
        many: std.ArrayList(Ref),

        fn items(self: *Alternates) []Ref {
            return switch (self.*) {
                .one => |*ref| @as(*[1]Ref, @ptrCast(ref)),
                .many => |*list| list.items,
            };
        }

        fn append(self: *Alternates, allocator: std.mem.Allocator, ref: Ref) !void {
            switch (self.*) {
                .one => |first| {
                    var list: std.ArrayList(Ref) = .empty;
                    errdefer list.deinit(allocator);
                    try list.appendSlice(allocator, &.{ first, ref });
                    self.* = .{ .many = list };
                },
                .many => |*list| try list.append(allocator, ref),
            }
        }

        fn truncate(self: *Alternates, allocator: std.mem.Allocator, len: usize) void {
            std.debug.assert(len > 0);
            switch (self.*) {
                .one => std.debug.assert(len == 1),
                .many => |*list| {
                    if (len == 1) {
                        const first = list.items[0];
                        list.deinit(allocator);
                        self.* = .{ .one = first };
                    } else if (len <= list.capacity / 4) {
                        list.shrinkAndFree(allocator, len);
                    } else {
                        list.shrinkRetainingCapacity(len);
                    }
                },
            }
        }

        fn deinit(self: *Alternates, allocator: std.mem.Allocator) void {
            if (self.* == .many) self.many.deinit(allocator);
        }
    };

    fn deinit(self: *Table, allocator: std.mem.Allocator) void {
        for (self.paths.items) |slot| if (slot.path) |path| allocator.free(path);
        self.paths.deinit(allocator);
        self.by_path.deinit(allocator);
        var it = self.copies.valueIterator();
        while (it.next()) |list| list.deinit(allocator);
        self.copies.deinit(allocator);
        self.refs.deinit(allocator);
    }

    fn reuseFile(self: *Table, path: []const u8, cid: Cid, seen: u32) bool {
        const file = self.by_path.get(path) orelse return false;
        const slot = &self.paths.items[file];
        if (!std.mem.eql(u8, &slot.cid, &cid)) return false;
        slot.seen = seen;
        return true;
    }

    /// Stages a new slot and its refs under the mutex. On allocation failure
    /// the old slot still owns the path and all of its refs.
    fn setFile(self: *Table, allocator: std.mem.Allocator, path: []const u8, cid: Cid, seen: u32, leaves: []const Leaf) !void {
        if (self.reuseFile(path, cid, seen)) return;
        const leaf_count = std.math.cast(u32, leaves.len) orelse return error.TooManyChunks;
        const owned = try allocator.dupe(u8, path);
        errdefer allocator.free(owned);
        const old = self.by_path.get(path);
        if (old == null) try self.by_path.ensureUnusedCapacity(allocator, 1);
        const file = self.free orelse std.math.cast(u32, self.paths.items.len) orelse return error.TooManyFiles;
        if (self.free == null) try self.paths.ensureUnusedCapacity(allocator, 1);

        var staged: usize = 0;
        errdefer for (leaves[0..staged]) |leaf| self.unstageRef(allocator, leaf.cid, file);
        for (leaves) |leaf| {
            try self.addRef(allocator, leaf.cid, .{ .file = file, .offset = leaf.offset, .len = leaf.len });
            staged += 1;
        }

        const slot: FileSlot = .{ .path = owned, .cid = cid, .seen = seen, .leaf_count = leaf_count };
        if (self.free != null) {
            self.free = self.paths.items[file].next_free;
            self.paths.items[file] = slot;
        } else {
            self.paths.appendAssumeCapacity(slot);
        }
        // Replace the key as well as the value. The old slot owns its key.
        const entry = self.by_path.getOrPutAssumeCapacity(path);
        entry.key_ptr.* = owned;
        entry.value_ptr.* = file;
        if (old) |previous| self.retire(allocator, previous);
    }

    fn addRef(self: *Table, allocator: std.mem.Allocator, cid: Cid, ref: Ref) !void {
        const primary = try self.refs.getOrPut(allocator, cid);
        if (!primary.found_existing) {
            primary.value_ptr.* = ref;
        } else {
            if (primary.value_ptr.file == ref.file) return;
            const extra = try self.copies.getOrPut(allocator, cid);
            if (!extra.found_existing) {
                extra.value_ptr.* = .{ .one = ref };
            } else {
                const items = extra.value_ptr.items();
                // The same CID can repeat within the file being staged.
                if (items[items.len - 1].file == ref.file) return;
                try extra.value_ptr.append(allocator, ref);
            }
        }
        self.countMutation();
    }

    fn unstageRef(self: *Table, allocator: std.mem.Allocator, cid: Cid, file: u32) void {
        if (self.refs.get(cid)) |ref| {
            if (ref.file == file) {
                self.removeRef(cid);
                return;
            }
        }
        const entry = self.copies.getEntry(cid) orelse return;
        const items = entry.value_ptr.items();
        if (items[items.len - 1].file != file) return;
        self.dropCopies(allocator, entry, items.len - 1);
        self.countMutation();
    }

    fn dropCopies(self: *Table, allocator: std.mem.Allocator, entry: Copies.Entry, keep: usize) void {
        if (keep > 0) {
            entry.value_ptr.truncate(allocator, keep);
        } else {
            entry.value_ptr.deinit(allocator);
            const removed = self.copies.remove(entry.key_ptr.*);
            std.debug.assert(removed);
            self.copies_removed +|= 1;
        }
    }

    fn removeRef(self: *Table, cid: Cid) void {
        const removed = self.refs.remove(cid);
        std.debug.assert(removed);
        self.refs_removed +|= 1;
        self.countMutation();
    }

    fn reclaimTombstones(self: *Table, allocator: std.mem.Allocator) void {
        // Rehash only after both sweep iterators have finished.
        rehashAfterRemovals(&self.refs, &self.refs_removed, std.hash_map.AutoContext(Cid){});
        rehashAfterRemovals(&self.by_path, &self.paths_removed, std.hash_map.StringContext{});
        if (self.copies.count() == 0) {
            if (self.copies.capacity() > 0) {
                self.copies.clearAndFree(allocator);
                self.countShrink();
            }
            self.copies_removed = 0;
        } else {
            rehashAfterRemovals(&self.copies, &self.copies_removed, std.hash_map.AutoContext(Cid){});
        }
    }

    /// A map is rehashed in place once removals reach capacity / this.
    /// std doesn't count tombstones against load, so keep a wide margin.
    const rehash_divisor = 8;

    fn rehashAfterRemovals(map: anytype, removed: *u32, context: anytype) void {
        if (removed.* == 0 or removed.* < map.capacity() / rehash_divisor) return;
        map.rehash(context);
        removed.* = 0;
    }

    /// Invalidates all refs to a file at once. Retired slots can only be
    /// reused after the sweep has removed every reference to them.
    fn retire(self: *Table, allocator: std.mem.Allocator, file: u32) void {
        const slot = &self.paths.items[file];
        allocator.free(slot.path.?);
        slot.path = null;
        slot.next_free = self.retired;
        self.retired = file;
        if (self.retired_tail == null) self.retired_tail = file;
        // Repeated leaves count toward the threshold even when their ref is shared.
        self.retired_chunks += slot.leaf_count;
        self.retired_slots += 1;
    }

    fn needsSweep(self: *const Table) bool {
        return self.retired_chunks >= @max(sweep_chunk_floor, self.refs.count() / sweep_divisor) or
            self.retired_slots >= @max(sweep_slot_floor, self.paths.items.len / sweep_divisor) or
            // A long paths list can keep the slot threshold above what the
            // (possibly shrunk) path map tolerates in tombstones.
            self.paths_removed >= @max(sweep_slot_floor, self.by_path.capacity() / rehash_divisor);
    }

    fn recycleRetired(self: *Table) void {
        const retired = self.retired orelse return;
        self.paths.items[self.retired_tail.?].next_free = self.free;
        self.free = retired;
        self.retired = null;
        self.retired_tail = null;
        self.retired_chunks = 0;
        self.retired_slots = 0;
    }

    fn shrinkPaths(self: *Table, allocator: std.mem.Allocator) void {
        // The free list is rebuilt from every slot without a path, which
        // must not catch retired slots that still have refs.
        std.debug.assert(self.retired == null);
        const capacity = self.paths.capacity;
        const limit = capacity / shrink_divisor;
        if (self.by_path.count() >= limit) return;

        // The path map has already been through the shrink check. Find the
        // last live index without walking the potentially large free suffix.
        var len: usize = 0;
        var it = self.by_path.valueIterator();
        while (it.next()) |file| {
            len = @max(len, @as(usize, file.*) + 1);
            if (len >= limit) return;
        }

        self.paths.shrinkAndFree(allocator, len);
        if (self.paths.capacity < capacity) self.countShrink();
        // shrinkAndFree truncates the list even if allocation fails.
        self.free = null;
        for (0..len) |i| {
            const slot = &self.paths.items[i];
            if (slot.path != null) continue;
            slot.next_free = self.free;
            self.free = @intCast(i);
        }
    }

    fn countShrink(self: *Table) void {
        if (@import("builtin").is_test) self.shrinks += 1;
    }

    fn pruneCopies(self: *Table, allocator: std.mem.Allocator, entry: Copies.Entry) bool {
        const items = entry.value_ptr.items();
        var kept: usize = 0;
        for (items) |ref| {
            if (self.paths.items[ref.file].path == null) {
                self.countMutation();
                continue;
            }
            items[kept] = ref;
            kept += 1;
        }
        const primary = self.refs.getPtr(entry.key_ptr.*).?;
        if (self.paths.items[primary.file].path == null and kept > 0) {
            kept -= 1;
            primary.* = items[kept];
            self.countMutation();
        }
        if (kept == items.len) return false;
        self.dropCopies(allocator, entry, kept);
        return true;
    }

    fn countMutation(self: *Table) void {
        if (@import("builtin").is_test) self.mutations += 1;
    }

    const Location = struct { path: []const u8, ref: Ref };

    fn location(self: *Table, cid: Cid, next: *usize) ?Location {
        const primary = self.refs.get(cid) orelse return null;
        if (next.* == 0) {
            next.* = 1;
            if (self.paths.items[primary.file].path) |path| return .{ .path = path, .ref = primary };
        }
        const copies = self.copies.getPtr(cid) orelse return null;
        const items = copies.items();
        while (next.* <= items.len) {
            const ref = items[next.* - 1];
            next.* += 1;
            if (self.paths.items[ref.file].path) |path| return .{ .path = path, .ref = ref };
        }
        return null;
    }
};

pub const Filestore = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    /// One live table per share. Guarded by `mutex`.
    tables: std.StringHashMapUnmanaged(Table) = .empty,
    /// Changes that can invalidate a read's cursor between disk attempts.
    revision: u64 = 0,
    mutex: sync.Mutex = .{},

    pub fn init(allocator: std.mem.Allocator, io: std.Io) Filestore {
        return .{ .allocator = allocator, .io = io };
    }

    pub fn deinit(self: *Filestore) void {
        var it = self.tables.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            entry.value_ptr.deinit(self.allocator);
        }
        self.tables.deinit(self.allocator);
    }

    /// The caller serializes this with registration and removal. A scan
    /// keeps only the name and generation, so no table is pinned by a scan.
    pub fn prepare(self: *Filestore, share: []const u8, generation: u64) !Target {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.tables.getPtr(share)) |table| {
            std.debug.assert(table.generation == generation);
        } else {
            const owned = try self.allocator.dupe(u8, share);
            errdefer self.allocator.free(owned);
            try self.tables.put(self.allocator, owned, .{ .generation = generation });
            self.revision +%= 1;
        }
        return .{ .store = self, .share = share, .generation = generation };
    }

    pub const Detached = struct {
        key: []const u8,
        table: Table,

        pub fn deinit(self: *Detached, allocator: std.mem.Allocator) void {
            allocator.free(self.key);
            self.table.deinit(allocator);
        }
    };

    /// Transfers ownership to the caller, which can free the table outside
    /// its registration lock. Serialize this with prepare().
    pub fn detach(self: *Filestore, share: []const u8) ?Detached {
        self.mutex.lock();
        defer self.mutex.unlock();
        const entry = self.tables.fetchRemove(share) orelse return null;
        self.revision +%= 1;
        return .{ .key = entry.key, .table = entry.value };
    }

    pub const Target = struct {
        store: *Filestore,
        share: []const u8,
        generation: u64,

        const batch_size = 1024;

        fn tableLocked(self: Target) error{ScanCancelled}!*Table {
            const table = self.store.tables.getPtr(self.share) orelse return error.ScanCancelled;
            if (table.generation != self.generation) return error.ScanCancelled;
            return table;
        }

        pub fn reuseFile(self: Target, path: []const u8, cid: Cid, seen: u32) !bool {
            self.store.mutex.lock();
            defer self.store.mutex.unlock();
            return (try self.tableLocked()).reuseFile(path, cid, seen);
        }

        pub fn setFile(self: Target, path: []const u8, cid: Cid, seen: u32, leaves: []const Leaf) !void {
            self.store.mutex.lock();
            defer self.store.mutex.unlock();
            try (try self.tableLocked()).setFile(self.store.allocator, path, cid, seen, leaves);
        }

        pub fn forgetUnseen(self: Target, seen: u32) !void {
            var start: usize = 0;
            while (try self.retireBatch(seen, &start)) {}
        }

        fn retireBatch(self: Target, seen: u32, start: *usize) !bool {
            self.store.mutex.lock();
            defer self.store.mutex.unlock();
            const table = try self.tableLocked();
            const end = @min(start.* + batch_size, table.paths.items.len);
            for (start.*..end) |i| {
                const slot = table.paths.items[i];
                const path = slot.path orelse continue;
                if (slot.seen == seen) continue;
                const removed = table.by_path.remove(path);
                std.debug.assert(removed);
                table.paths_removed +|= 1;
                table.retire(self.store.allocator, @intCast(i));
            }
            start.* = end;
            return end < table.paths.items.len;
        }

        /// The scanner is the only writer to this generation. Retired refs
        /// stay invisible until there is enough work to justify a sweep.
        pub fn sweep(self: Target) void {
            if (self.shouldSweep()) self.forceSweep();
        }

        fn shouldSweep(self: Target) bool {
            self.store.mutex.lock();
            defer self.store.mutex.unlock();
            const table = self.tableLocked() catch return false;
            return table.needsSweep();
        }

        /// Physically purges retired refs and reclaims their slots.
        pub fn forceSweep(self: Target) void {
            var cursor: u32 = 0;
            while (self.sweepBatch(.copies, &cursor)) {}
            cursor = 0;
            while (self.sweepBatch(.refs, &cursor)) {}
            if (!self.recycleAfterSweep()) return;
            // Shrink first: a shrunk map is rebuilt without tombstones, so it
            // must not also pay a whole-map rehash in one lock hold.
            inline for (.{ .refs, .copies, .by_path }) |field| self.shrinkMap(field);

            self.store.mutex.lock();
            defer self.store.mutex.unlock();
            const table = self.tableLocked() catch return;
            table.reclaimTombstones(self.store.allocator);
            table.shrinkPaths(self.store.allocator);
        }

        fn recycleAfterSweep(self: Target) bool {
            self.store.mutex.lock();
            defer self.store.mutex.unlock();
            const table = self.tableLocked() catch return false;
            table.recycleRetired();
            return true;
        }

        fn sweepBatch(self: Target, comptime field: Table.MapField, cursor: *u32) bool {
            self.store.mutex.lock();
            defer self.store.mutex.unlock();
            const table = self.tableLocked() catch return false;
            if (table.retired_chunks == 0) return false;
            const map = &@field(table, @tagName(field));
            if (map.count() == 0) return false;
            const end = cursor.* + @min(batch_size, map.capacity() - cursor.*);
            const keys = map.keyIterator();
            const values = map.valueIterator();
            for (cursor.*..end) |i| {
                if (!keys.metadata[i].isUsed()) continue;
                if (field == .copies) {
                    const entry: Table.Copies.Entry = .{ .key_ptr = &keys.items[i], .value_ptr = &values.items[i] };
                    if (table.pruneCopies(self.store.allocator, entry)) self.store.revision +%= 1;
                } else if (table.paths.items[values.items[i].file].path == null) {
                    table.removeRef(keys.items[i]);
                }
            }
            cursor.* = end;
            return end < map.capacity();
        }

        fn shrinkMap(self: Target, comptime field: Table.MapField) void {
            const Map = @FieldType(Table, @tagName(field));
            // Values (including alternate lists) and string keys are borrowed
            // until the swap. Deinit frees only the map's backing allocation.
            var replacement: Map = .empty;
            defer replacement.deinit(self.store.allocator);
            var cursor: u32 = 0;
            var start_count: usize = 0;
            while (self.shrinkMapBatch(field, &replacement, &cursor, &start_count)) {}
        }

        fn shrinkMapBatch(
            self: Target,
            comptime field: Table.MapField,
            replacement: *@FieldType(Table, @tagName(field)),
            cursor: *u32,
            start_count: *usize,
        ) bool {
            self.store.mutex.lock();
            defer self.store.mutex.unlock();
            const table = self.tableLocked() catch return false;
            const map = &@field(table, @tagName(field));
            if (cursor.* == 0) {
                if (map.count() >= map.capacity() / Table.shrink_divisor) return false;
                replacement.ensureTotalCapacity(self.store.allocator, map.count()) catch return false;
                start_count.* = map.count();
            } else if (map.count() != start_count.*) {
                // Another writer changed the map between batches: an entry
                // in a copied bucket would be lost at the swap. Try next sweep.
                return false;
            }
            if (map.count() > 0) {
                // Bound the lock hold by buckets even if the old map is sparse.
                const end = cursor.* + @min(batch_size, map.capacity() - cursor.*);
                const keys = map.keyIterator();
                const values = map.valueIterator();
                for (cursor.*..end) |i| {
                    if (!keys.metadata[i].isUsed()) continue;
                    replacement.putAssumeCapacityNoClobber(keys.items[i], values.items[i]);
                }
                cursor.* = end;
                if (replacement.count() < map.count()) {
                    std.debug.assert(end < map.capacity());
                    return true;
                }
            }
            std.debug.assert(replacement.capacity() < map.capacity());
            std.mem.swap(@TypeOf(replacement.*), replacement, map);
            switch (field) {
                .refs => table.refs_removed = 0,
                .copies => table.copies_removed = 0,
                .by_path => table.paths_removed = 0,
            }
            table.countShrink();
            return false;
        }
    };

    /// Adapter for StorageEngine.external.
    pub fn external(self: *Filestore) storage.engine.StorageEngine.External {
        return .{ .ctx = self, .getFn = getErased, .hasFn = hasErased };
    }

    const Located = struct {
        path_buf: [std.fs.max_path_bytes]u8,
        path_len: usize,
        ref: Ref,

        fn path(self: *const Located) []const u8 {
            return self.path_buf[0..self.path_len];
        }
    };

    const Cursor = struct {
        table: u32 = 0,
        location: usize = 0,
        revision: ?u64 = null,
        restarts: u8 = 0,

        /// Each restart follows a promotion; tried copies are skipped, so
        /// this only bounds a chunk with many stale copies during sweeps.
        const max_restarts = 64;
    };

    fn locate(self: *Filestore, cid: *const Cid, cursor: *Cursor, attempted: ?*const Attempt.Set) ?Located {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (cursor.revision != null and cursor.revision.? != self.revision) {
            // A promotion can move an untried copy ahead of the cursor.
            // A share insertion can also move tables to new buckets.
            if (cursor.restarts == Cursor.max_restarts) return null;
            cursor.* = .{ .restarts = cursor.restarts + 1 };
        }
        cursor.revision = self.revision;
        var it = self.tables.iterator();
        it.index = cursor.table;
        while (it.next()) |entry| {
            const table = entry.value_ptr;
            while (table.location(cid.*, &cursor.location)) |at| {
                if (attempted) |tried| {
                    if (tried.contains(.{ .path = at.path, .offset = at.ref.offset, .len = at.ref.len })) continue;
                }
                var out = Located{ .path_buf = undefined, .path_len = at.path.len, .ref = at.ref };
                if (at.path.len > out.path_buf.len) continue;
                @memcpy(out.path_buf[0..at.path.len], at.path);
                cursor.table = it.index - 1;
                return out;
            }
            cursor.location = 0;
        }
        return null;
    }

    pub const Stats = struct { chunks: usize, chunk_slots: usize, duplicates: usize, duplicate_slots: usize };

    /// Sizes of `share`'s index, for logs.
    pub fn stats(self: *Filestore, share: []const u8) ?Stats {
        self.mutex.lock();
        defer self.mutex.unlock();
        const table = self.tables.getPtr(share) orelse return null;
        return .{
            .chunks = table.refs.count(),
            .chunk_slots = table.refs.capacity(),
            .duplicates = table.copies.count(),
            .duplicate_slots = table.copies.capacity(),
        };
    }

    pub fn has(self: *Filestore, cid: *const Cid) bool {
        var cursor: Cursor = .{};
        return self.locate(cid, &cursor, null) != null;
    }

    /// The leaf block (tag byte + data) read back from a shared file.
    /// Try other copies when a file is gone or its bytes no longer match.
    pub fn get(self: *Filestore, cid: *const Cid, allocator: std.mem.Allocator) !?[]u8 {
        return self.getWithReader(cid, allocator, self);
    }

    const Attempt = struct {
        path: []const u8,
        offset: u64,
        len: u32,

        const Set = std.HashMapUnmanaged(Attempt, void, Context, std.hash_map.default_max_load_percentage);

        const Context = struct {
            pub fn hash(_: Context, key: Attempt) u64 {
                return std.hash.Wyhash.hash(key.offset ^ key.len, key.path);
            }

            pub fn eql(_: Context, a: Attempt, b: Attempt) bool {
                return a.offset == b.offset and a.len == b.len and std.mem.eql(u8, a.path, b.path);
            }
        };
    };

    fn getWithReader(self: *Filestore, cid: *const Cid, allocator: std.mem.Allocator, reader: anytype) !?[]u8 {
        var cursor: Cursor = .{};
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const scratch = arena.allocator();
        var attempted: Attempt.Set = .empty;

        while (self.locate(cid, &cursor, if (attempted.count() == 0) null else &attempted)) |at| {
            if (try reader.readAt(cid, &at, allocator)) |block| return block;
            // Out of memory: carry on without recording; restarts stay bounded.
            const path = scratch.dupe(u8, at.path()) catch continue;
            attempted.put(scratch, .{ .path = path, .offset = at.ref.offset, .len = at.ref.len }, {}) catch {};
        }
        return null;
    }

    fn readAt(self: *Filestore, cid: *const Cid, at: *const Located, allocator: std.mem.Allocator) !?[]u8 {
        const path = at.path();

        var file = openRegular(self.io, std.Io.Dir.cwd(), path) catch return null;
        defer file.close(self.io);
        const block = try allocator.alloc(u8, 1 + @as(usize, at.ref.len));
        errdefer allocator.free(block);
        block[0] = @intFromEnum(codec.Tag.leaf);
        const n = file.readPositionalAll(self.io, block[1..], at.ref.offset) catch {
            allocator.free(block);
            return null;
        };

        var hash: Cid = undefined;
        std.crypto.hash.sha2.Sha256.hash(block, &hash, .{});
        if (n != at.ref.len or !std.mem.eql(u8, &hash, cid)) {
            allocator.free(block);
            return null; // edited since the scan
        }
        return block;
    }

    fn getErased(ctx: *anyopaque, cid: *const [32]u8, allocator: std.mem.Allocator) anyerror!?[]u8 {
        const self: *Filestore = @ptrCast(@alignCast(ctx));
        return self.get(cid, allocator);
    }

    fn hasErased(ctx: *anyopaque, cid: *const [32]u8) bool {
        const self: *Filestore = @ptrCast(@alignCast(ctx));
        return self.has(cid);
    }
};

/// Do not follow a swapped-in symlink or wait for a FIFO writer.
pub fn openRegular(io: std.Io, dir: std.Io.Dir, path: []const u8) !std.Io.File {
    var file: std.Io.File = if (@import("builtin").os.tag == .windows)
        try openChecked(io, dir, path, .read_only)
    else
        .{
            .handle = try std.posix.openat(dir.handle, path, .{ .ACCMODE = .RDONLY, .NOFOLLOW = true, .NONBLOCK = true, .CLOEXEC = true }, 0),
            .flags = .{ .nonblocking = true },
        };
    errdefer file.close(io);
    if ((try file.stat(io)).kind != .file) return error.NotRegularFile;
    return file;
}

/// Opens `path` without following a link: error.SymLinkLoop when it is one.
/// Windows goes through `openChecked`: std's no-follow open there hands out
/// an overlapped handle marked blocking, and a positional read or write on
/// it that has to wait is a crash.
pub fn openNoFollow(io: std.Io, dir: std.Io.Dir, path: []const u8, mode: std.Io.File.OpenMode) !std.Io.File {
    if (@import("builtin").os.tag != .windows) return dir.openFile(io, path, .{ .mode = mode, .follow_symlinks = false });
    return openChecked(io, dir, path, mode);
}

/// Looks at `path` without following it, refuses a link (or any other
/// reparse point), opens it the ordinary way, and refuses again when what
/// was opened is not what was looked at (a link swapped in between).
pub fn openChecked(io: std.Io, dir: std.Io.Dir, path: []const u8, mode: std.Io.File.OpenMode) !std.Io.File {
    const seen = try dir.statFile(io, path, .{ .follow_symlinks = false });
    if (seen.kind == .sym_link or seen.kind == .unknown) return error.SymLinkLoop;
    const file = try dir.openFile(io, path, .{ .mode = mode });
    errdefer file.close(io);
    const opened = try file.stat(io);
    if (opened.inode != seen.inode or opened.kind != seen.kind) return error.SymLinkLoop;
    return file;
}

test "openChecked opens a file and refuses a link to one" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "real.txt", .data = "bytes" });
    try tmp.dir.symLink(io, "real.txt", "link.txt", .{});

    const file = try openChecked(io, tmp.dir, "real.txt", .read_only);
    defer file.close(io);
    var buf: [8]u8 = undefined;
    try std.testing.expectEqualStrings("bytes", buf[0..try file.readPositionalAll(io, &buf, 0)]);

    try std.testing.expectError(error.SymLinkLoop, openChecked(io, tmp.dir, "link.txt", .read_only));
    try std.testing.expectError(error.SymLinkLoop, openNoFollow(io, tmp.dir, "link.txt", .read_only));
    try std.testing.expectError(error.FileNotFound, openChecked(io, tmp.dir, "missing.txt", .read_only));
}

test "filestore: a failed replacement keeps the previous file indexed" {
    const Case = struct {
        fn run(allocator: std.mem.Allocator) !void {
            var store = Filestore.init(allocator, std.testing.io);
            defer store.deinit();
            const target = try store.prepare("share", 1);
            const old = [_]u8{1} ** 32;
            const shared = [_]u8{2} ** 32;
            const fresh = [_]u8{3} ** 32;
            try target.setFile("/file", old, 1, &.{
                .{ .cid = old, .offset = 0, .len = 1 },
                .{ .cid = shared, .offset = 1, .len = 1 },
            });
            try target.setFile("/other", shared, 1, &.{.{ .cid = shared, .offset = 0, .len = 1 }});
            target.setFile("/file", fresh, 2, &.{
                .{ .cid = fresh, .offset = 0, .len = 1 },
                .{ .cid = old, .offset = 1, .len = 1 },
                .{ .cid = shared, .offset = 2, .len = 1 },
            }) catch |err| {
                try std.testing.expect(store.has(&old));
                try std.testing.expect(store.has(&shared));
                try std.testing.expect(!store.has(&fresh));
                try std.testing.expectEqual(@as(u32, 1), store.tables.get("share").?.copies.count());
                return err;
            };
            target.sweep();
            try std.testing.expect(store.has(&fresh));
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Case.run, .{});
}

fn testCid(index: usize) Cid {
    var cid = [_]u8{0} ** 32;
    std.mem.writeInt(u64, cid[0..8], index, .little);
    return cid;
}

fn expectLeaf(store: *Filestore, cid: *const Cid, expected: []const u8) !void {
    const block = (try store.get(cid, std.testing.allocator)) orelse return error.MissingLeaf;
    defer std.testing.allocator.free(block);
    try std.testing.expectEqualSlices(u8, expected, block);
}

test "filestore: get survives unrelated updates and promotion between reads" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "b", .data = "chunk" });
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const base = path_buf[0..try tmp.dir.realPath(io, &path_buf)];
    const survivor = try std.fs.path.join(allocator, &.{ base, "b" });
    defer allocator.free(survivor);

    const missing_a = try std.fs.path.join(allocator, &.{ base, "a" });
    defer allocator.free(missing_a);
    const missing_middle = try std.fs.path.join(allocator, &.{ base, "middle" });
    defer allocator.free(missing_middle);

    var store = Filestore.init(allocator, io);
    defer store.deinit();
    const target = try store.prepare("share", 1);
    const cid = storage.block.Block.new("\x00chunk").cid;
    const leaves = [_]Leaf{.{ .cid = cid, .offset = 0, .len = 5 }};
    try target.setFile(missing_a, cid, 1, &leaves);
    try target.setFile(missing_middle, cid, 1, &leaves);
    try target.setFile(survivor, cid, 2, &leaves);

    const Reader = struct {
        store: *Filestore,
        target: Filestore.Target,
        calls: u8 = 0,

        fn readAt(self: *@This(), key: *const Cid, at: *const Filestore.Located, alloc: std.mem.Allocator) !?[]u8 {
            self.calls += 1;
            switch (self.calls) {
                1 => {
                    try std.testing.expectEqualStrings("a", std.fs.path.basename(at.path()));
                    const revision = self.store.revision;
                    try self.target.setFile("/unrelated", testCid(10), 2, &.{});
                    try std.testing.expectEqual(revision, self.store.revision);
                },
                2 => {
                    try std.testing.expectEqualStrings("middle", std.fs.path.basename(at.path()));
                    try self.target.forgetUnseen(2);
                    self.target.sweep();
                    try std.testing.expectEqual(@as(u32, 1), self.store.tables.get("share").?.copies.count());
                    var cursor: Filestore.Cursor = .{};
                    const live = self.store.locate(key, &cursor, null).?;
                    try std.testing.expectEqualStrings("b", std.fs.path.basename(live.path()));
                    try std.testing.expectEqual(null, self.store.locate(key, &cursor, null));
                    self.target.forceSweep();
                    try std.testing.expectEqual(@as(u32, 0), self.store.tables.get("share").?.copies.count());
                },
                else => {},
            }
            return self.store.readAt(key, at, alloc);
        }
    };

    var reader: Reader = .{ .store = &store, .target = target };
    const block = (try store.getWithReader(&cid, allocator, &reader)) orelse return error.MissingLeaf;
    defer allocator.free(block);
    try std.testing.expectEqualStrings("\x00chunk", block);
    try std.testing.expectEqual(@as(u8, 3), reader.calls);
    try expectLeaf(&store, &cid, "\x00chunk");
}

test "filestore: get skips attempted locations after table growth" {
    const allocator = std.testing.allocator;
    var store = Filestore.init(allocator, std.testing.io);
    defer store.deinit();
    const target = try store.prepare("original", 1);
    const cid = testCid(1);
    const leaves = [_]Leaf{.{ .cid = cid, .offset = 0, .len = 1 }};
    try target.setFile("/first", cid, 1, &leaves);
    try target.setFile("/second", cid, 1, &leaves);

    const Reader = struct {
        store: *Filestore,
        calls: u8 = 0,

        fn readAt(self: *@This(), _: *const Cid, at: *const Filestore.Located, _: std.mem.Allocator) !?[]u8 {
            self.calls += 1;
            if (self.calls == 1) {
                try std.testing.expectEqualStrings("/first", at.path());
                const capacity = self.store.tables.capacity();
                for (0..capacity) |i| {
                    var name: [20]u8 = undefined;
                    _ = try self.store.prepare(try std.fmt.bufPrint(&name, "share-{d}", .{i}), 1);
                }
                try std.testing.expect(self.store.tables.capacity() > capacity);
            } else {
                try std.testing.expectEqualStrings("/second", at.path());
            }
            return null;
        }
    };
    var reader: Reader = .{ .store = &store };
    try std.testing.expectEqual(null, try store.getWithReader(&cid, allocator, &reader));
    try std.testing.expectEqual(@as(u8, 2), reader.calls);
}

test "filestore: shares with equal generations both serve their primary" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const base = path_buf[0..try tmp.dir.realPath(io, &path_buf)];
    const a = try std.fs.path.join(allocator, &.{ base, "a" });
    defer allocator.free(a);
    const b = try std.fs.path.join(allocator, &.{ base, "b" });
    defer allocator.free(b);

    var store = Filestore.init(allocator, io);
    defer store.deinit();
    const share_a = try store.prepare("a", 1);
    const share_b = try store.prepare("b", 1);
    const cid = storage.block.Block.new("\x00chunk").cid;
    const leaves = [_]Leaf{.{ .cid = cid, .offset = 0, .len = 5 }};
    try share_a.setFile(a, cid, 1, &leaves);
    try share_b.setFile(b, cid, 1, &leaves);

    // Leave the first primary missing so get has to try the second table.
    var cursor: Filestore.Cursor = .{};
    const first = store.locate(&cid, &cursor, null).?;
    const second_name = if (std.mem.eql(u8, first.path(), a)) "b" else "a";
    try tmp.dir.writeFile(io, .{ .sub_path = second_name, .data = "chunk" });
    try expectLeaf(&store, &cid, "\x00chunk");
    try tmp.dir.deleteFile(io, second_name);
    try tmp.dir.writeFile(io, .{ .sub_path = std.fs.path.basename(first.path()), .data = "chunk" });
    try expectLeaf(&store, &cid, "\x00chunk");
}

test "filestore: steady churn rehashes all three maps in place" {
    var store = Filestore.init(std.testing.allocator, std.testing.io);
    defer store.deinit();
    const target = try store.prepare("share", 1);
    const table = store.tables.getPtr("share").?;
    const stable = testCid(0);
    const stable_leaves = [_]Leaf{.{ .cid = stable, .offset = 0, .len = 1 }};
    try target.setFile("/stable", stable, 0, &stable_leaves);
    try target.setFile("/stable-copy", stable, 0, &stable_leaves);
    const copies_capacity = table.copies.capacity();
    const refs_capacity = table.refs.capacity();
    const paths_capacity = table.by_path.capacity();
    var rehashes: usize = 0;
    for (1..65) |i| {
        const cid = testCid(i);
        var path: [32]u8 = undefined;
        const name = try std.fmt.bufPrint(&path, "/transient-{d}", .{i});
        const leaves = [_]Leaf{.{ .cid = cid, .offset = 0, .len = 1 }};
        try target.setFile(name, cid, 1, &leaves);
        try target.setFile("/transient-copy", cid, 1, &leaves);
        try target.forgetUnseen(0);
        const will_rehash = table.refs_removed + 1 >= refs_capacity / Table.rehash_divisor;
        target.forceSweep();
        if (will_rehash) {
            try std.testing.expectEqual(@as(u32, 0), table.refs_removed);
            try std.testing.expectEqual(@as(u32, 0), table.copies_removed);
            rehashes += 1;
        }
        try std.testing.expect(table.copies_removed < copies_capacity / Table.rehash_divisor);
        try std.testing.expect(table.refs_removed < refs_capacity / Table.rehash_divisor);
        try std.testing.expect(table.paths_removed < paths_capacity / Table.rehash_divisor);
        try std.testing.expectEqual(refs_capacity, table.refs.capacity());
        try std.testing.expectEqual(paths_capacity, table.by_path.capacity());
        try std.testing.expectEqual(copies_capacity, table.copies.capacity());
        try std.testing.expectEqual(@as(usize, 4), table.paths.items.len);
        try std.testing.expectEqual(@as(u32, 1), table.copies.count());
        try std.testing.expect(store.has(&stable));
        try std.testing.expect(!store.has(&cid));
    }
    try std.testing.expect(rehashes > 1);
}

test "filestore: retire and sweep across batch boundaries and free empty copies" {
    const allocator = std.testing.allocator;
    var store = Filestore.init(allocator, std.testing.io);
    defer store.deinit();
    const target = try store.prepare("share", 1);
    const count = Filestore.Target.batch_size + 1;
    const leaves = try allocator.alloc(Leaf, count);
    defer allocator.free(leaves);
    for (leaves, 0..) |*leaf, i| leaf.* = .{ .cid = testCid(i), .offset = i, .len = 1 };

    try target.setFile("/primary", testCid(count), 1, leaves);
    try target.setFile("/alternate", testCid(count + 1), 1, leaves);
    for (0..count) |i| {
        var path: [24]u8 = undefined;
        try target.setFile(try std.fmt.bufPrint(&path, "/empty-{d}", .{i}), testCid(i), 1, &.{});
    }

    const table = store.tables.getPtr("share").?;
    try std.testing.expectEqual(count, table.refs.count());
    try std.testing.expectEqual(count, table.copies.count());
    try target.forgetUnseen(2);
    try std.testing.expectEqual(@as(u32, 0), table.by_path.count());
    target.sweep();
    try std.testing.expectEqual(@as(u32, 0), table.refs.count());
    try std.testing.expectEqual(@as(u32, 0), table.copies.capacity());
    try std.testing.expectEqual(null, table.retired);
    for (0..count + 2) |i| {
        var path: [24]u8 = undefined;
        try target.setFile(try std.fmt.bufPrint(&path, "/new-{d}", .{i}), testCid(i), 2, &.{});
    }
    try std.testing.expectEqual(count + 2, table.paths.items.len);
    try std.testing.expectEqual(null, table.free);
}

test "filestore: two replacements before one sweep recycle both old slots" {
    var store = Filestore.init(std.testing.allocator, std.testing.io);
    defer store.deinit();
    const target = try store.prepare("share", 1);
    for (1..4) |i| {
        const cid = testCid(i);
        try target.setFile("/file", cid, @intCast(i), &.{.{ .cid = cid, .offset = 0, .len = 1 }});
    }
    target.forceSweep();
    try std.testing.expect(!store.has(&testCid(1)));
    try std.testing.expect(!store.has(&testCid(2)));
    try std.testing.expect(store.has(&testCid(3)));
    const table = store.tables.getPtr("share").?;
    try std.testing.expectEqual(@as(u32, 1), table.refs.count());
    try target.setFile("/new-a", testCid(4), 3, &.{});
    try target.setFile("/new-b", testCid(5), 3, &.{});
    try std.testing.expectEqual(@as(usize, 3), table.paths.items.len);
}

test "filestore: alternate lists shrink and repeated chunks use one ref per file" {
    var store = Filestore.init(std.testing.allocator, std.testing.io);
    defer store.deinit();
    const target = try store.prepare("share", 1);
    const cid = testCid(0);
    const leaves = [_]Leaf{
        .{ .cid = cid, .offset = 0, .len = 1 },
        .{ .cid = cid, .offset = 42, .len = 1 },
    };
    const table = store.tables.getPtr("share").?;
    try target.setFile("/primary", cid, 1, &leaves);
    try std.testing.expectEqual(@as(u64, 0), table.refs.get(cid).?.offset);
    try std.testing.expectEqual(@as(u32, 0), table.copies.count());

    for (0..32) |i| {
        var path_buf: [24]u8 = undefined;
        const path = try std.fmt.bufPrint(&path_buf, "/copy-{d}", .{i});
        try target.setFile(path, cid, if (i < 3) 2 else 1, &leaves);
        if (i == 0) try std.testing.expectEqual(@as(u64, 0), table.copies.get(cid).?.one.offset);
    }
    const many = table.copies.get(cid).?.many;
    try std.testing.expectEqual(@as(usize, 32), many.items.len);
    try target.forgetUnseen(2);
    target.forceSweep();
    const shrunk = table.copies.get(cid).?.many;
    try std.testing.expectEqual(@as(usize, 2), shrunk.items.len);
    try std.testing.expect(shrunk.capacity < many.capacity);

    try std.testing.expect(try target.reuseFile("/copy-0", cid, 3));
    try std.testing.expect(try target.reuseFile("/copy-1", cid, 3));
    try target.forgetUnseen(3);
    target.forceSweep();
    try std.testing.expectEqual(@as(u64, 0), table.copies.get(cid).?.one.offset);
    try std.testing.expectEqual(@as(u64, 0), table.refs.get(cid).?.offset);
}

test "filestore: chunk threshold amortizes sweeps and retired chunks are invisible" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "changing", .data = "old" });
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const base = path_buf[0..try tmp.dir.realPath(io, &path_buf)];
    const path = try std.fs.path.join(allocator, &.{ base, "changing" });
    defer allocator.free(path);

    var store = Filestore.init(allocator, io);
    defer store.deinit();
    const target = try store.prepare("share", 1);
    const table = store.tables.getPtr("share").?;
    const stable = try allocator.alloc(Leaf, 2048);
    defer allocator.free(stable);
    for (stable, 0..) |*leaf, i| leaf.* = .{ .cid = testCid(i), .offset = i, .len = 1 };
    try target.setFile("/stable", testCid(stable.len), 1, stable);

    const old = storage.block.Block.new("\x00old").cid;
    var changing: [32]Leaf = undefined;
    for (&changing, 0..) |*leaf, i| leaf.* = .{ .cid = testCid(stable.len + 1 + i), .offset = i, .len = 1 };
    changing[0] = .{ .cid = old, .offset = 0, .len = 3 };
    try target.setFile(path, old, 1, &changing);
    try expectLeaf(&store, &old, "\x00old");

    for (1..Table.sweep_slot_floor) |version| {
        for (&changing, 0..) |*leaf, i| {
            leaf.* = .{ .cid = testCid(stable.len + 1 + version * changing.len + i), .offset = i, .len = 1 };
        }
        try target.setFile(path, changing[0].cid, 1, &changing);
        target.sweep();
        try std.testing.expect(!store.has(&old));
        if (version == 1) {
            try std.testing.expectEqual(null, try store.get(&old, allocator));
            try std.testing.expect(table.refs.contains(old));
            try std.testing.expectEqual(changing.len, table.retired_chunks);
            try std.testing.expectEqual(@as(usize, 1), table.retired_slots);
        }
        if (table.retired == null) {
            try std.testing.expectEqual(@as(u64, 0), table.retired_chunks);
            try std.testing.expectEqual(@as(usize, 0), table.retired_slots);
            try std.testing.expectEqual(stable.len + changing.len, table.refs.count());
            try std.testing.expect(!table.refs.contains(old));
            try std.testing.expect(store.has(&changing[0].cid));
            return;
        }
    }
    return error.ChunkThresholdDidNotSweep;
}

test "filestore: the slot threshold bounds path growth for a changing empty file" {
    var store = Filestore.init(std.testing.allocator, std.testing.io);
    defer store.deinit();
    const target = try store.prepare("share", 1);
    const table = store.tables.getPtr("share").?;
    var sweeps: usize = 0;
    for (0..256) |i| {
        try target.setFile("/empty", testCid(i), 1, &.{});
        target.sweep();
        try std.testing.expectEqual(@as(u64, 0), table.retired_chunks);
        try std.testing.expect(table.paths.items.len <= 1 + Table.sweep_slot_floor);
        if (i > 0 and table.retired_slots == 0) sweeps += 1;
    }
    try std.testing.expect(sweeps > 1);
}

test "filestore: sweeping shrinks sparse maps and free path tails, then grows again" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const base = path_buf[0..try tmp.dir.realPath(io, &path_buf)];

    var failing = std.testing.FailingAllocator.init(allocator, .{});
    var store = Filestore.init(failing.allocator(), io);
    defer store.deinit();
    const target = try store.prepare("share", 1);
    const table = store.tables.getPtr("share").?;
    try target.setFile("/hole", testCid(0), 1, &.{});
    const live_count = 4;
    const copies_per_chunk = 3;
    for (0..live_count) |i| {
        const block = [_]u8{ 0, @intCast(i) };
        const cid = storage.block.Block.new(&block).cid;
        for (0..copies_per_chunk) |j| {
            var name_buf: [32]u8 = undefined;
            const name = try std.fmt.bufPrint(&name_buf, "live-{d}-{d}", .{ i, j });
            try tmp.dir.writeFile(io, .{ .sub_path = name, .data = block[1..] });
            const path = try std.fs.path.join(allocator, &.{ base, name });
            defer allocator.free(path);
            try target.setFile(path, cid, 2, &.{.{ .cid = cid, .offset = 0, .len = 1 }});
        }
    }
    for (1..1025) |i| {
        for (0..2) |j| {
            var path: [32]u8 = undefined;
            const name = try std.fmt.bufPrint(&path, "/retire-{d}-{d}", .{ i, j });
            const cid = testCid(i);
            try target.setFile(name, cid, 1, &.{.{ .cid = cid, .offset = 0, .len = 1 }});
        }
    }

    const refs_capacity = table.refs.capacity();
    const copies_capacity = table.copies.capacity();
    const by_path_capacity = table.by_path.capacity();
    const paths_capacity = table.paths.capacity;
    try target.forgetUnseen(2);
    failing.fail_index = failing.alloc_index;
    failing.resize_fail_index = failing.resize_index;
    target.forceSweep();
    try std.testing.expect(failing.has_induced_failure);
    try std.testing.expectEqual(@as(u64, 0), table.shrinks);
    try std.testing.expectEqual(refs_capacity, table.refs.capacity());
    try std.testing.expectEqual(copies_capacity, table.copies.capacity());
    try std.testing.expectEqual(by_path_capacity, table.by_path.capacity());
    try std.testing.expectEqual(paths_capacity, table.paths.capacity);
    try std.testing.expectEqual(@as(?u32, 0), table.free);
    try std.testing.expect(!store.has(&testCid(1024)));

    failing.fail_index = std.math.maxInt(usize);
    failing.resize_fail_index = std.math.maxInt(usize);
    target.forceSweep();
    try std.testing.expectEqual(@as(u64, 4), table.shrinks);
    try std.testing.expect(table.refs.capacity() < refs_capacity);
    try std.testing.expect(table.copies.capacity() < copies_capacity);
    try std.testing.expect(table.by_path.capacity() < by_path_capacity);
    try std.testing.expect(table.paths.capacity < paths_capacity);
    try std.testing.expectEqual(1 + live_count * copies_per_chunk, table.paths.items.len);
    try std.testing.expectEqual(@as(?u32, 0), table.free);

    const small_refs = table.refs.capacity();
    const small_copies = table.copies.capacity();
    const small_by_path = table.by_path.capacity();
    const small_paths = table.paths.capacity;
    for (1..65) |i| {
        for (0..2) |j| {
            var path: [32]u8 = undefined;
            const name = try std.fmt.bufPrint(&path, "/grown-{d}-{d}", .{ i, j });
            const cid = testCid(i);
            try target.setFile(name, cid, 2, &.{.{ .cid = cid, .offset = 0, .len = 1 }});
        }
    }
    try std.testing.expectEqual(@as(u32, 0), table.by_path.get("/grown-1-0").?);
    try std.testing.expect(table.refs.capacity() > small_refs);
    try std.testing.expect(table.copies.capacity() > small_copies);
    try std.testing.expect(table.by_path.capacity() > small_by_path);
    try std.testing.expect(table.paths.capacity > small_paths);
    for (0..live_count) |i| {
        const block = [_]u8{ 0, @intCast(i) };
        const cid = storage.block.Block.new(&block).cid;
        try std.testing.expectEqual(1 + i * copies_per_chunk, table.refs.get(cid).?.file);
        try std.testing.expectEqual(@as(usize, copies_per_chunk - 1), table.copies.get(cid).?.many.items.len);
        try expectLeaf(&store, &cid, &block);
    }
    try std.testing.expect(store.has(&testCid(64)));
}
