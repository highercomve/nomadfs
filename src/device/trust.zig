//! On-disk trust store for paired devices.
//!
//! Entries are keyed by the device identity (blake2s of the Ed25519 public
//! key), so a re-pairing with a fresh transport key updates one record instead
//! of adding another. The file is a small versioned text file written through
//! a temp file and renamed into place; it is owner-only.

const std = @import("std");
const builtin = @import("builtin");
const pairing = @import("pairing.zig");
const identity_mod = @import("identity.zig");
const NodeID = @import("../net/id.zig").NodeID;

pub const magic = "NMDFSTR1";
pub const max_entries = 64;
/// Header plus 64 worst-case entries of roughly 300 bytes.
pub const max_file_bytes = 32 * 1024;
pub const max_label_len = pairing.max_nickname_len;

pub const Error = error{
    CorruptTrustStore,
    TrustStoreFull,
};

pub const Entry = struct {
    device_id: NodeID,
    public_key: [32]u8,
    label: [max_label_len]u8,
    label_len: u8,
    added_at: u64,

    pub fn labelSlice(self: *const Entry) []const u8 {
        return self.label[0..self.label_len];
    }

    pub fn fingerprint(self: *const Entry) [identity_mod.Identity.fingerprint_len]u8 {
        return identity_mod.Identity.fingerprintOf(self.public_key);
    }
};

pub const Store = struct {
    allocator: std.mem.Allocator,
    path: []u8,
    entries: std.ArrayList(Entry),

    /// Loads the store at `path`. A missing file is an empty store; a file
    /// that exists but does not parse is an error, never silently discarded.
    pub fn load(allocator: std.mem.Allocator, path: []const u8) !Store {
        var store: Store = .{
            .allocator = allocator,
            .path = try allocator.dupe(u8, path),
            .entries = .empty,
        };
        errdefer store.deinit();

        const io = std.Io.Threaded.global_single_threaded.io();
        var file = std.Io.Dir.cwd().openFile(io, path, .{}) catch |err| switch (err) {
            error.FileNotFound => return store,
            else => return err,
        };
        defer file.close(io);

        const size = (try file.stat(io)).size;
        if (size > max_file_bytes) return Error.CorruptTrustStore;
        const content = try allocator.alloc(u8, size);
        defer allocator.free(content);
        if (try file.readPositionalAll(io, content, 0) != size) return Error.CorruptTrustStore;

        try store.parse(content);
        return store;
    }

    pub fn deinit(self: *Store) void {
        self.entries.deinit(self.allocator);
        self.allocator.free(self.path);
        self.* = undefined;
    }

    pub fn count(self: *const Store) usize {
        return self.entries.items.len;
    }

    pub fn list(self: *const Store) []const Entry {
        return self.entries.items;
    }

    pub fn find(self: *Store, device_id: NodeID) ?*Entry {
        for (self.entries.items) |*entry| {
            if (entry.device_id.eql(device_id)) return entry;
        }
        return null;
    }

    pub fn isTrusted(self: *Store, device_id: NodeID) bool {
        return self.find(device_id) != null;
    }

    /// Records a self-verified pairing ticket. Returns true when the device was
    /// not known before; an update keeps the original `added_at`.
    pub fn trustTicket(self: *Store, ticket: pairing.Ticket, now: u64) !bool {
        return self.upsertKey(ticket.identity_public_key, ticket.nicknameSlice(), now);
    }

    pub fn upsertKey(self: *Store, public_key: [32]u8, label: []const u8, now: u64) !bool {
        if (label.len == 0 or label.len > max_label_len) return pairing.Error.InvalidTicket;
        try validateLabel(label);

        const device_id = NodeID.fromPublicKey(public_key);
        if (self.find(device_id)) |entry| {
            @memset(&entry.label, 0);
            @memcpy(entry.label[0..label.len], label);
            entry.label_len = @intCast(label.len);
            return false;
        }

        if (self.entries.items.len >= max_entries) return Error.TrustStoreFull;

        var entry: Entry = .{
            .device_id = device_id,
            .public_key = public_key,
            .label = undefined,
            .label_len = @intCast(label.len),
            .added_at = now,
        };
        @memcpy(entry.label[0..label.len], label);
        try self.entries.append(self.allocator, entry);
        return true;
    }

    /// Removes a device. Returns whether it was present.
    pub fn revoke(self: *Store, device_id: NodeID) bool {
        for (self.entries.items, 0..) |entry, index| {
            if (!entry.device_id.eql(device_id)) continue;
            _ = self.entries.orderedRemove(index);
            return true;
        }
        return false;
    }

    /// Writes the store atomically: temp file in the same directory, then a
    /// rename. The original file stays intact if anything fails.
    pub fn save(self: *Store) !void {
        const io = std.Io.Threaded.global_single_threaded.io();
        const tmp_path = try std.fmt.allocPrint(self.allocator, "{s}.tmp", .{self.path});
        defer self.allocator.free(tmp_path);

        var out: std.Io.Writer.Allocating = .init(self.allocator);
        defer out.deinit();
        try out.writer.print("{s}\n", .{magic});
        for (self.entries.items) |entry| {
            try writeEntry(&out.writer, entry);
        }

        {
            var file = try std.Io.Dir.cwd().createFile(io, tmp_path, .{
                .permissions = store_permissions,
            });
            defer file.close(io);
            try file.writePositionalAll(io, out.written(), 0);
        }
        errdefer std.Io.Dir.cwd().deleteFile(io, tmp_path) catch {};

        std.Io.Dir.cwd().rename(tmp_path, std.Io.Dir.cwd(), self.path, io) catch |err| {
            // Windows refuses to replace an existing target; removing it is the
            // only option and is still crash-safe thanks to the temp file.
            const target_exists = blk: {
                _ = std.Io.Dir.cwd().statFile(io, self.path, .{}) catch break :blk false;
                break :blk true;
            };
            if (builtin.os.tag != .windows or !target_exists) return err;
            std.Io.Dir.cwd().deleteFile(io, self.path) catch {};
            try std.Io.Dir.cwd().rename(tmp_path, std.Io.Dir.cwd(), self.path, io);
        };
    }

    fn parse(self: *Store, content: []const u8) !void {
        var lines = std.mem.splitScalar(u8, content, '\n');
        const header = lines.next() orelse return Error.CorruptTrustStore;
        if (!std.mem.eql(u8, header, magic)) return Error.CorruptTrustStore;

        while (lines.next()) |line| {
            if (line.len == 0) continue;
            if (self.entries.items.len >= max_entries) return Error.CorruptTrustStore;
            const entry = try parseEntry(line);
            try self.entries.append(self.allocator, entry);
        }
    }

    const store_permissions: std.Io.File.Permissions =
        if (builtin.os.tag == .windows) .default_file else @enumFromInt(0o600);
};

fn writeEntry(writer: *std.Io.Writer, entry: Entry) !void {
    const hex = std.fmt.bytesToHex(entry.device_id.bytes, .lower);
    try writer.print("{s}\t", .{hex});

    var key_buf: [64]u8 = undefined;
    try writer.writeAll(std.base64.url_safe_no_pad.Encoder.encode(&key_buf, &entry.public_key));
    try writer.print("\t{d}\t", .{entry.added_at});

    var label_buf: [128]u8 = undefined;
    try writer.writeAll(std.base64.url_safe_no_pad.Encoder.encode(&label_buf, entry.labelSlice()));
    try writer.writeByte('\n');
}

fn parseEntry(line: []const u8) !Entry {
    var fields = std.mem.splitScalar(u8, line, '\t');
    const id_hex = fields.next() orelse return Error.CorruptTrustStore;
    const key_b64 = fields.next() orelse return Error.CorruptTrustStore;
    const added_text = fields.next() orelse return Error.CorruptTrustStore;
    const label_b64 = fields.next() orelse return Error.CorruptTrustStore;
    if (fields.next() != null) return Error.CorruptTrustStore;

    var entry: Entry = .{
        .device_id = undefined,
        .public_key = undefined,
        .label = undefined,
        .label_len = 0,
        .added_at = 0,
    };

    if (id_hex.len != NodeID.len * 2) return Error.CorruptTrustStore;
    _ = std.fmt.hexToBytes(&entry.device_id.bytes, id_hex) catch return Error.CorruptTrustStore;

    const decoder = std.base64.url_safe_no_pad.Decoder;
    const key_size = decoder.calcSizeForSlice(key_b64) catch return Error.CorruptTrustStore;
    if (key_size != entry.public_key.len) return Error.CorruptTrustStore;
    decoder.decode(&entry.public_key, key_b64) catch return Error.CorruptTrustStore;

    // The identifier must match the key; anything else means the file was
    // edited or written by an incompatible version.
    if (!NodeID.fromPublicKey(entry.public_key).eql(entry.device_id)) return Error.CorruptTrustStore;

    entry.added_at = std.fmt.parseInt(u64, added_text, 10) catch return Error.CorruptTrustStore;

    const label_size = decoder.calcSizeForSlice(label_b64) catch return Error.CorruptTrustStore;
    if (label_size == 0 or label_size > max_label_len) return Error.CorruptTrustStore;
    decoder.decode(entry.label[0..label_size], label_b64) catch return Error.CorruptTrustStore;
    try validateLabel(entry.label[0..label_size]);
    entry.label_len = @intCast(label_size);

    return entry;
}

fn validateLabel(label: []const u8) !void {
    for (label) |byte| {
        if (byte < 0x20 or byte > 0x7e) return Error.CorruptTrustStore;
    }
}

const testing = std.testing;

fn cleanup(path: []const u8) void {
    const io = std.Io.Threaded.global_single_threaded.io();
    std.Io.Dir.cwd().deleteFile(io, path) catch {};
    var buf: [128]u8 = undefined;
    const tmp = std.fmt.bufPrint(&buf, "{s}.tmp", .{path}) catch return;
    std.Io.Dir.cwd().deleteFile(io, tmp) catch {};
}

fn testTicket(seed_byte: u8, nickname: []const u8) !pairing.Ticket {
    const identity = try identity_mod.Identity.fromSeed([_]u8{seed_byte} ** identity_mod.seed_len);
    return pairing.Ticket.init(identity, [_]u8{0x11} ** 32, nickname, "192.168.1.5:4001", 1_800_000_000);
}

test "trust: missing file loads as an empty store" {
    const path = "test_trust_missing.store";
    cleanup(path);
    var store = try Store.load(testing.allocator, path);
    defer store.deinit();

    try testing.expectEqual(@as(usize, 0), store.count());
}

test "trust: pairing a ticket records and updates one entry" {
    const path = "test_trust_upsert.store";
    cleanup(path);
    defer cleanup(path);

    var store = try Store.load(testing.allocator, path);
    defer store.deinit();

    const ticket = try testTicket(0x21, "phone");
    try testing.expect(try store.trustTicket(ticket, 100));
    try testing.expectEqual(@as(usize, 1), store.count());
    try testing.expect(store.isTrusted(ticket.deviceId()));

    const entry = store.find(ticket.deviceId()).?;
    try testing.expectEqualStrings("phone", entry.labelSlice());
    try testing.expectEqual(@as(u64, 100), entry.added_at);

    // Re-pairing the same identity updates the label without duplicating it.
    const renamed = try testTicket(0x21, "phone-2");
    try testing.expect(!try store.trustTicket(renamed, 200));
    try testing.expectEqual(@as(usize, 1), store.count());
    try testing.expectEqual(@as(u64, 100), store.find(ticket.deviceId()).?.added_at);
    try testing.expectEqualStrings("phone-2", store.find(ticket.deviceId()).?.labelSlice());
}

test "trust: revoke removes only the requested device" {
    const path = "test_trust_revoke.store";
    cleanup(path);
    defer cleanup(path);

    var store = try Store.load(testing.allocator, path);
    defer store.deinit();

    const first = try testTicket(0x31, "laptop");
    const second = try testTicket(0x32, "phone");
    _ = try store.trustTicket(first, 1);
    _ = try store.trustTicket(second, 2);

    try testing.expect(store.revoke(first.deviceId()));
    try testing.expect(!store.revoke(first.deviceId()));
    try testing.expectEqual(@as(usize, 1), store.count());
    try testing.expect(!store.isTrusted(first.deviceId()));
    try testing.expect(store.isTrusted(second.deviceId()));
}

test "trust: save and load round-trip with private permissions" {
    const path = "test_trust_roundtrip.store";
    cleanup(path);
    defer cleanup(path);

    {
        var store = try Store.load(testing.allocator, path);
        defer store.deinit();
        _ = try store.trustTicket(try testTicket(0x41, "alpha"), 1000);
        _ = try store.trustTicket(try testTicket(0x42, "beta"), 2000);
        try store.save();
    }

    var store = try Store.load(testing.allocator, path);
    defer store.deinit();
    try testing.expectEqual(@as(usize, 2), store.count());

    const alpha = store.find((try testTicket(0x41, "alpha")).deviceId()).?;
    try testing.expectEqualStrings("alpha", alpha.labelSlice());
    try testing.expectEqual(@as(u64, 1000), alpha.added_at);

    if (builtin.os.tag != .windows) {
        const io = std.Io.Threaded.global_single_threaded.io();
        var file = try std.Io.Dir.cwd().openFile(io, path, .{});
        defer file.close(io);
        const mode = @intFromEnum((try file.stat(io)).permissions);
        try testing.expectEqual(@as(@TypeOf(mode), 0), mode & 0o077);
    }

    // Saving again replaces the file without stale entries.
    _ = store.revoke(alpha.device_id);
    try store.save();
    var reloaded = try Store.load(testing.allocator, path);
    defer reloaded.deinit();
    try testing.expectEqual(@as(usize, 1), reloaded.count());
}

test "trust: corrupt files are rejected rather than discarded" {
    const io = std.Io.Threaded.global_single_threaded.io();
    const path = "test_trust_corrupt.store";
    cleanup(path);
    defer cleanup(path);

    const cases = [_][]const u8{
        "",
        "not-a-store\n",
        magic ++ "\n" ++ ("0" ** 63) ++ "\n",
        magic ++ "\n" ++ ("0" ** 64) ++ "\tAAAA\t1\tQQ\n",
    };
    for (cases) |content| {
        {
            var file = try std.Io.Dir.cwd().createFile(io, path, .{});
            defer file.close(io);
            try file.writePositionalAll(io, content, 0);
        }
        try testing.expectError(Error.CorruptTrustStore, Store.load(testing.allocator, path));
    }
}

test "trust: capacity is bounded" {
    const path = "test_trust_full.store";
    cleanup(path);
    defer cleanup(path);

    var store = try Store.load(testing.allocator, path);
    defer store.deinit();

    for (0..max_entries) |i| {
        const ticket = try testTicket(@intCast(i + 1), "device");
        try testing.expect(try store.trustTicket(ticket, i));
    }
    try testing.expectEqual(max_entries, store.count());

    const overflow = try testTicket(200, "overflow");
    try testing.expectError(Error.TrustStoreFull, store.trustTicket(overflow, 300));
    try testing.expectEqual(max_entries, store.count());
}
