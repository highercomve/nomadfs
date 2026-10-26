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
const sync = @import("../sync.zig");
const NodeID = @import("../net/id.zig").NodeID;

pub const magic = "NMDFSTR1";
pub const max_entries = 64;
/// Header plus 64 worst-case entries of roughly 300 bytes.
pub const max_file_bytes = 32 * 1024;
pub const max_label_len = pairing.max_nickname_len;
/// Bound on tombstones so a swarm-wide revocation storm cannot grow the
/// store unbounded (roughly 32 KiB keeps the file cap honest).
pub const max_revocations = 256;
/// Signed revocations are bound to this domain; the payload names both the
/// revoked device and the signer, so a signature cannot be transplanted.
pub const revocation_domain = "nomadfs-revoke-v1";

pub const Error = error{
    CorruptTrustStore,
    TrustStoreFull,
    InvalidDeviceQuery,
    AmbiguousDeviceQuery,
    UnsignedTrustStore,
    BadStoreSignature,
};

/// Sentinel written when an entry has no recorded transport key (files saved
/// before transport-key pinning existed). An all-zero X25519 key is not a
/// real key, so it can never collide.
pub const no_transport_key: [32]u8 = [_]u8{0} ** 32;

pub const Entry = struct {
    device_id: NodeID,
    public_key: [32]u8,
    /// The X25519 transport key the pair presented when it was admitted.
    transport_key: [32]u8 = no_transport_key,
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

/// Lowercases a hex query and drops the decoration a user may paste from the
/// `--devices` listing: an `0x` prefix and `-`, `:` or whitespace separators.
fn normalizeHexQuery(query: []const u8, out: *[128]u8) ![]const u8 {
    var start: usize = 0;
    if (query.len >= 2 and query[0] == '0' and (query[1] == 'x' or query[1] == 'X')) start = 2;

    var written: usize = 0;
    for (query[start..]) |byte| {
        switch (byte) {
            '-', ':', ' ', '\t' => continue,
            else => {},
        }
        if (!std.ascii.isHex(byte) or written >= out.len) return Error.InvalidDeviceQuery;
        out[written] = std.ascii.toLower(byte);
        written += 1;
    }
    return out[0..written];
}

const revocation_msg_len = revocation_domain.len + NodeID.len * 2;

/// Bytes covered by a revocation signature: the domain, the revoked device
/// and the signer's device ID, so a signature cannot be transplanted to
/// another revoker or claim a different device.
pub fn revocationMessage(device_id: NodeID, signer_id: NodeID) [revocation_msg_len]u8 {
    var message: [revocation_msg_len]u8 = undefined;
    @memcpy(message[0..revocation_domain.len], revocation_domain);
    var offset = revocation_domain.len;
    @memcpy(message[offset..][0..32], &device_id.bytes);
    offset += 32;
    @memcpy(message[offset..][0..32], &signer_id.bytes);
    return message;
}

/// Verifies a revocation against `signer_key` and applies it: the signer
/// must not revoke itself, and only signers whose own device is trusted
/// locally are honored. Returns whether the revocation was accepted.
pub fn applyRevocation(
    store: *Store,
    device_id: NodeID,
    signer_key: [32]u8,
    signature: [64]u8,
    now: u64,
) !bool {
    const signer_id = NodeID.fromPublicKey(signer_key);
    try identity_mod.Identity.verify(signer_key, &revocationMessage(device_id, signer_id), signature);
    if (!store.isTrusted(signer_id)) return false;
    // The ack reports absorption, not entry removal: replaying a tombstone
    // the store already holds still counts as honored.
    _ = try store.revokeDevice(device_id, signer_id, now);
    return true;
}

/// Format marker of the trailing integrity line.
const signature_marker = "\nSIG ";
const signature_len = 64;

/// Verifies that `content` ends with a valid `SIG` line covering everything
/// above it, produced by the device owning `signing_seed`, and returns the
/// body to parse. Store files are local configuration, so the same device
/// that runs the node must be able to prove it wrote the file.
fn stripSignature(content: []const u8, signing_seed: [identity_mod.seed_len]u8) ![]const u8 {
    if (content.len == 0 or content[content.len - 1] != '\n') return Error.CorruptTrustStore;
    const pos = std.mem.lastIndexOf(u8, content, signature_marker) orelse return Error.UnsignedTrustStore;

    const body = content[0 .. pos + 1];
    const sig_text = content[pos + signature_marker.len .. content.len - 1];
    var signature: [signature_len]u8 = undefined;
    _ = std.fmt.hexToBytes(&signature, sig_text) catch return Error.CorruptTrustStore;

    const identity = identity_mod.Identity.fromSeed(signing_seed) catch return Error.CorruptTrustStore;
    identity_mod.Identity.verify(identity.publicKey(), body, signature) catch return Error.BadStoreSignature;
    return body;
}

/// Records that a device was ordered removed by a trusted signer. Kept so
/// the removal can be propagated again to peers that were not connected
/// when it happened; re-pairing clears it.
pub const Revocation = struct {
    device_id: NodeID,
    signer_id: NodeID,
    at: u64,
};

pub const Store = struct {
    allocator: std.mem.Allocator,
    path: []u8,
    entries: std.ArrayList(Entry),
    revocations: std.ArrayList(Revocation),
    /// Guards in-process readers against list mutation from revocation
    /// handlers; the CLI always runs as its own process.
    mutex: sync.Mutex = .{},
    /// Serializes save() so concurrent acceptances cannot interleave temp
    /// file writes at the same path.
    save_mutex: sync.Mutex = .{},
    /// When set, saves append a `SIG <hex>` line and loads demand it.
    signing_seed: ?[identity_mod.seed_len]u8 = null,

    /// Loads the store at `path`. A missing file is an empty store; a file
    /// that exists but does not parse is an error, never silently discarded.
    pub fn load(allocator: std.mem.Allocator, path: []const u8, signing_seed: ?[identity_mod.seed_len]u8) !Store {
        var store: Store = .{
            .allocator = allocator,
            .path = try allocator.dupe(u8, path),
            .entries = .empty,
            .revocations = .empty,
            .signing_seed = signing_seed,
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

        const body = if (signing_seed) |seed|
            try stripSignature(content, seed)
        else
            content;
        try store.parse(body);
        return store;
    }

    pub fn deinit(self: *Store) void {
        self.entries.deinit(self.allocator);
        self.revocations.deinit(self.allocator);
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

    /// Read-only lookup for verification paths that must not mutate. Copies
    /// the entry out, so the pointer into the store's array stays internal.
    pub fn lookup(self: *Store, device_id: NodeID) ?Entry {
        self.mutex.lock();
        defer self.mutex.unlock();
        for (self.entries.items) |entry| {
            if (entry.device_id.eql(device_id)) return entry;
        }
        return null;
    }

    pub fn isTrusted(self: *Store, device_id: NodeID) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        for (self.entries.items) |entry| {
            if (entry.device_id.eql(device_id)) return true;
        }
        return false;
    }

    /// Records a self-verified pairing ticket. Returns true when the device was
    /// not known before; an update keeps the original `added_at`.
    pub fn trustTicket(self: *Store, ticket: pairing.Ticket, now: u64) !bool {
        return self.upsert(ticket.identity_public_key, ticket.transport_public_key, ticket.nicknameSlice(), now);
    }

    /// Records a paired identity together with the transport key its ticket
    /// vouched for. A re-pairing updates both the label and the pinned
    /// transport key, letting a device rotate `node.key`.
    pub fn upsert(self: *Store, public_key: [32]u8, transport_key: [32]u8, label: []const u8, now: u64) !bool {
        if (label.len == 0 or label.len > max_label_len) return pairing.Error.InvalidTicket;
        try validateLabel(label);
        if (std.mem.eql(u8, &transport_key, &no_transport_key)) return pairing.Error.InvalidTicket;

        const device_id = NodeID.fromPublicKey(public_key);
        if (self.find(device_id)) |entry| {
            @memset(&entry.label, 0);
            @memcpy(entry.label[0..label.len], label);
            entry.label_len = @intCast(label.len);
            entry.transport_key = transport_key;
            return false;
        }

        self.clearRevocation(device_id);
        if (self.entries.items.len >= max_entries) return Error.TrustStoreFull;

        var entry: Entry = .{
            .device_id = device_id,
            .public_key = public_key,
            .transport_key = transport_key,
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

    pub fn isRevoked(self: *Store, device_id: NodeID) bool {
        self.mutex.lock();
        defer self.mutex.unlock();

        for (self.revocations.items) |r| {
            if (r.device_id.eql(device_id)) return true;
        }
        return false;
    }

    pub fn revocationsSlice(self: *Store) []const Revocation {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.revocations.items;
    }

    /// Copy for out-of-lock use, e.g. pushing tombstones over the network.
    pub fn copyRevocationIds(self: *Store, allocator: std.mem.Allocator) ![]NodeID {
        self.mutex.lock();
        defer self.mutex.unlock();
        const ids = try allocator.alloc(NodeID, self.revocations.items.len);
        for (self.revocations.items, 0..) |r, i| ids[i] = r.device_id;
        return ids;
    }

    /// Removes a device and records who ordered the removal. Recorded even
    /// for devices without a local entry: peers propagate revocations for
    /// content not paired here yet, and the tombstone travels onward.
    /// `signer_id` must not equal `device_id`.
    pub fn revokeDevice(self: *Store, device_id: NodeID, signer_id: NodeID, at: u64) !bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.revokeDeviceLocked(device_id, signer_id, at);
    }

    fn revokeDeviceLocked(self: *Store, device_id: NodeID, signer_id: NodeID, at: u64) !bool {
        if (signer_id.eql(device_id)) return Error.InvalidDeviceQuery;

        const removed = self.revoke(device_id);
        for (self.revocations.items) |*r| {
            if (!r.device_id.eql(device_id)) continue;
            r.signer_id = signer_id;
            r.at = at;
            return removed;
        }
        if (self.revocations.items.len >= max_revocations) return Error.TrustStoreFull;
        try self.revocations.append(self.allocator, .{
            .device_id = device_id,
            .signer_id = signer_id,
            .at = at,
        });
        return removed;
    }

    /// Re-pairing is an explicit human decision on a fresh ticket, so it
    /// overrides a propagated revocation instead of being blocked by one.
    fn clearRevocation(self: *Store, device_id: NodeID) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        for (self.revocations.items, 0..) |r, index| {
            if (!r.device_id.eql(device_id)) continue;
            _ = self.revocations.orderedRemove(index);
            return;
        }
    }

    /// Resolves a device ID (64 hex chars) or fingerprint (16 hex chars) as
    /// typed by a human: case-insensitive, `0x` prefix and `-`, `:` or space
    /// separators allowed. Returns null when nothing matches.
    pub fn resolve(self: *const Store, query: []const u8) !?NodeID {
        var query_buf: [128]u8 = undefined;
        const normalized = try normalizeHexQuery(query, &query_buf);
        if (normalized.len == 0) return null;

        var found: ?NodeID = null;
        for (self.entries.items) |entry| {
            var id_buf: [64]u8 = undefined;
            var fingerprint_buf: [identity_mod.Identity.fingerprint_len * 2]u8 = undefined;
            const id_hex = std.fmt.bufPrint(&id_buf, "{x}", .{entry.device_id.bytes}) catch unreachable;
            const fingerprint_hex = std.fmt.bufPrint(&fingerprint_buf, "{x}", .{entry.fingerprint()}) catch unreachable;
            if (!std.mem.eql(u8, normalized, id_hex) and !std.mem.eql(u8, normalized, fingerprint_hex)) continue;

            // A full ID is unique; two devices could in principle share a
            // truncated fingerprint, so never guess between them.
            if (found != null) return Error.AmbiguousDeviceQuery;
            found = entry.device_id;
        }
        return found;
    }

    /// Writes the store atomically: temp file in the same directory, then a
    /// rename. The original file stays intact if anything fails.
    pub fn save(self: *Store) !void {
        self.save_mutex.lock();
        defer self.save_mutex.unlock();
        const io = std.Io.Threaded.global_single_threaded.io();
        const tmp_path = try std.fmt.allocPrint(self.allocator, "{s}.tmp", .{self.path});
        defer self.allocator.free(tmp_path);

        var out: std.Io.Writer.Allocating = .init(self.allocator);
        defer out.deinit();
        try out.writer.print("{s}\n", .{magic});
        for (self.entries.items) |entry| {
            try writeEntry(&out.writer, entry);
        }
        for (self.revocations.items) |r| {
            try writeRevocation(&out.writer, r);
        }

        if (self.signing_seed) |seed| {
            const identity = try identity_mod.Identity.fromSeed(seed);
            const signature = try identity.sign(out.written());
            var sig_hex: [2 * signature_len]u8 = undefined;
            _ = std.fmt.bufPrint(&sig_hex, "{s}", .{std.fmt.bytesToHex(signature, .lower)}) catch unreachable;
            try out.writer.print("SIG {s}\n", .{sig_hex});
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
            if (line[0] == '@') {
                const r = try parseRevocation(line[1..]);
                try self.revocations.append(self.allocator, r);
            } else {
                if (self.entries.items.len >= max_entries) return Error.CorruptTrustStore;
                const entry = try parseEntry(line);
                try self.entries.append(self.allocator, entry);
            }
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

    var transport_buf: [64]u8 = undefined;
    try writer.print("\t{s}\n", .{std.base64.url_safe_no_pad.Encoder.encode(&transport_buf, &entry.transport_key)});
}

fn parseEntry(line: []const u8) !Entry {
    var fields = std.mem.splitScalar(u8, line, '\t');
    const decoder = std.base64.url_safe_no_pad.Decoder;
    const id_hex = fields.next() orelse return Error.CorruptTrustStore;
    const key_b64 = fields.next() orelse return Error.CorruptTrustStore;
    const added_text = fields.next() orelse return Error.CorruptTrustStore;
    const label_b64 = fields.next() orelse return Error.CorruptTrustStore;

    var entry: Entry = .{
        .device_id = undefined,
        .public_key = undefined,
        .label = undefined,
        .label_len = 0,
        .added_at = 0,
    };
    // Files saved before transport-key pinning store four fields; such an
    // entry stays in the store but is not pinned until it re-pairs.
    if (fields.peek()) |transport_b64| {
        _ = fields.next();
        if (fields.next() != null) return Error.CorruptTrustStore;
        const transport_size = decoder.calcSizeForSlice(transport_b64) catch return Error.CorruptTrustStore;
        if (transport_size != entry.transport_key.len) return Error.CorruptTrustStore;
        decoder.decode(&entry.transport_key, transport_b64) catch return Error.CorruptTrustStore;
    }

    if (id_hex.len != NodeID.len * 2) return Error.CorruptTrustStore;
    _ = std.fmt.hexToBytes(&entry.device_id.bytes, id_hex) catch return Error.CorruptTrustStore;

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

fn writeRevocation(writer: *std.Io.Writer, r: Revocation) !void {
    try writer.print("@{s}\t{s}\t{d}\n", .{
        std.fmt.bytesToHex(r.device_id.bytes, .lower),
        std.fmt.bytesToHex(r.signer_id.bytes, .lower),
        r.at,
    });
}

fn parseRevocation(rest: []const u8) !Revocation {
    var fields = std.mem.splitScalar(u8, rest, '\t');
    const device_hex = fields.next() orelse return Error.CorruptTrustStore;
    const signer_hex = fields.next() orelse return Error.CorruptTrustStore;
    const at_text = fields.next() orelse return Error.CorruptTrustStore;
    if (fields.next() != null) return Error.CorruptTrustStore;

    var r: Revocation = .{ .device_id = undefined, .signer_id = undefined, .at = 0 };
    if (device_hex.len != NodeID.len * 2 or signer_hex.len != NodeID.len * 2) return Error.CorruptTrustStore;
    _ = std.fmt.hexToBytes(&r.device_id.bytes, device_hex) catch return Error.CorruptTrustStore;
    _ = std.fmt.hexToBytes(&r.signer_id.bytes, signer_hex) catch return Error.CorruptTrustStore;
    r.at = std.fmt.parseInt(u64, at_text, 10) catch return Error.CorruptTrustStore;
    if (r.signer_id.eql(r.device_id)) return Error.CorruptTrustStore;
    return r;
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
    var store = try Store.load(testing.allocator, path, null);
    defer store.deinit();

    try testing.expectEqual(@as(usize, 0), store.count());
}

test "trust: pairing a ticket records and updates one entry" {
    const path = "test_trust_upsert.store";
    cleanup(path);
    defer cleanup(path);

    var store = try Store.load(testing.allocator, path, null);
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

    var store = try Store.load(testing.allocator, path, null);
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

test "trust: resolve accepts ids, fingerprints and pasted decoration" {
    const path = "test_trust_resolve.store";
    cleanup(path);
    defer cleanup(path);

    var store = try Store.load(testing.allocator, path, null);
    defer store.deinit();

    const laptop = try testTicket(0x51, "laptop");
    const phone = try testTicket(0x52, "phone");
    _ = try store.trustTicket(laptop, 1);
    _ = try store.trustTicket(phone, 2);

    var id_buf: [64]u8 = undefined;
    const id_hex = std.fmt.bufPrint(&id_buf, "{x}", .{laptop.deviceId().bytes}) catch unreachable;
    try testing.expect((try store.resolve(id_hex)).?.eql(laptop.deviceId()));

    // Uppercase, 0x prefix and the dashed fingerprint rendering all work.
    var fp_buf: [19]u8 = undefined;
    const fingerprint = identity_mod.Identity.formatFingerprint(phone.fingerprint(), &fp_buf);
    try testing.expect((try store.resolve(fingerprint)).?.eql(phone.deviceId()));
    var decorated_buf: [66]u8 = undefined;
    const decorated = std.fmt.bufPrint(&decorated_buf, "0x{s}", .{id_hex}) catch unreachable;
    try testing.expect((try store.resolve(decorated)).?.eql(laptop.deviceId()));

    try testing.expect((try store.resolve("00112233445566778899aabbccddeeff")) == null);
    try testing.expectError(Error.InvalidDeviceQuery, store.resolve("not-a-device"));
}

test "trust: save and load round-trip with private permissions" {
    const path = "test_trust_roundtrip.store";
    cleanup(path);
    defer cleanup(path);

    const alpha_ticket = try testTicket(0x41, "alpha");
    const beta_ticket = try testTicket(0x42, "beta");
    {
        var store = try Store.load(testing.allocator, path, null);
        defer store.deinit();
        _ = try store.trustTicket(alpha_ticket, 1000);
        _ = try store.trustTicket(beta_ticket, 2000);
        try store.save();
    }

    var store = try Store.load(testing.allocator, path, null);
    defer store.deinit();
    try testing.expectEqual(@as(usize, 2), store.count());

    const alpha = store.find(alpha_ticket.deviceId()).?;
    try testing.expectEqualStrings("alpha", alpha.labelSlice());
    try testing.expectEqual(@as(u64, 1000), alpha.added_at);
    try testing.expectEqualSlices(u8, &alpha_ticket.transport_public_key, &alpha.transport_key);

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
    var reloaded = try Store.load(testing.allocator, path, null);
    defer reloaded.deinit();
    try testing.expectEqual(@as(usize, 1), reloaded.count());
}

test "trust: a re-pairing rotates the pinned transport key" {
    const path = "test_trust_rotate.store";
    cleanup(path);
    defer cleanup(path);

    var store = try Store.load(testing.allocator, path, null);
    defer store.deinit();

    // The ticket's transport key is whatever node.key was at pairing time.
    const fresh = try pairing.Ticket.init(
        try identity_mod.Identity.fromSeed([_]u8{0x61} ** identity_mod.seed_len),
        [_]u8{0x11} ** 32,
        "laptop",
        "192.168.1.5:4001",
        1_800_000_000,
    );
    _ = try store.trustTicket(fresh, 1);

    const rotated = try pairing.Ticket.init(
        try identity_mod.Identity.fromSeed([_]u8{0x61} ** identity_mod.seed_len),
        [_]u8{0x22} ** 32,
        "laptop",
        "192.168.1.5:4001",
        1_800_000_000,
    );
    try testing.expect(!try store.trustTicket(rotated, 2));
    try testing.expectEqual(@as(usize, 1), store.count());

    const entry = store.find(fresh.deviceId()).?;
    try testing.expectEqual(@as(u64, 1), entry.added_at);
    try testing.expectEqualSlices(u8, &rotated.transport_public_key, &entry.transport_key);
}

test "trust: entries without a transport key stay unpinned" {
    // A file saved before transport-key pinning only has four fields; it must
    // still load, with no pinned key until the device re-pairs.
    const io = std.Io.Threaded.global_single_threaded.io();
    const path = "test_trust_legacy.store";
    cleanup(path);
    defer cleanup(path);

    const identity = try identity_mod.Identity.fromSeed([_]u8{0x63} ** identity_mod.seed_len);
    const device_id = identity.deviceId();
    var line_buf: [512]u8 = undefined;
    var key_buf: [64]u8 = undefined;
    var label_buf: [8]u8 = undefined;
    const line = try std.fmt.bufPrint(&line_buf, "{s}\t{s}\t{d}\t{s}", .{
        std.fmt.bytesToHex(device_id.bytes, .lower),
        std.base64.url_safe_no_pad.Encoder.encode(&key_buf, &identity.publicKey()),
        1234,
        std.base64.url_safe_no_pad.Encoder.encode(&label_buf, "legacy"),
    });
    const content = try std.fmt.allocPrint(testing.allocator, "{s}\n{s}\n", .{ magic, line });
    defer testing.allocator.free(content);
    {
        var file = try std.Io.Dir.cwd().createFile(io, path, .{});
        defer file.close(io);
        try file.writePositionalAll(io, content, 0);
    }

    var store = try Store.load(testing.allocator, path, null);
    defer store.deinit();

    try testing.expectEqual(@as(usize, 1), store.count());
    const entry = store.lookup(device_id).?;
    try testing.expectEqualStrings("legacy", entry.labelSlice());
    try testing.expectEqualSlices(u8, &no_transport_key, &entry.transport_key);

    // Re-pairing pins the key the new ticket carries.
    const ticket = try pairing.Ticket.init(identity, [_]u8{0x44} ** 32, "legacy", "192.168.1.5:4001", 1_800_000_000);
    try testing.expect(!try store.trustTicket(ticket, 2));
    try testing.expectEqualSlices(u8, &ticket.transport_public_key, &store.lookup(device_id).?.transport_key);
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
        try testing.expectError(Error.CorruptTrustStore, Store.load(testing.allocator, path, null));
    }
}

test "trust: capacity is bounded" {
    const path = "test_trust_full.store";
    cleanup(path);
    defer cleanup(path);

    var store = try Store.load(testing.allocator, path, null);
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

test "trust: revocation tombstones persist and are overridden by re-pairing" {
    const path = "test_trust_revocations.store";
    cleanup(path);
    defer cleanup(path);

    const operator = try testTicket(0x71, "admin");
    const phone = try testTicket(0x72, "phone");
    {
        var store = try Store.load(testing.allocator, path, null);
        defer store.deinit();

        _ = try store.trustTicket(operator, 1);
        _ = try store.trustTicket(phone, 2);

        // Removing a locally known device records who ordered it.
        try testing.expect(try store.revokeDevice(phone.deviceId(), operator.deviceId(), 1234));
        try testing.expect(store.isRevoked(phone.deviceId()));
        try testing.expect(!store.isTrusted(phone.deviceId()));
        try testing.expectEqual(@as(usize, 1), store.revocationsSlice().len);

        // A signer is never its own subject.
        try testing.expectError(Error.InvalidDeviceQuery, store.revokeDevice(operator.deviceId(), operator.deviceId(), 5));

        try store.save();
    }

    var reloaded = try Store.load(testing.allocator, path, null);
    defer reloaded.deinit();
    try testing.expect(reloaded.isRevoked(phone.deviceId()));
    try testing.expectEqual(@as(usize, 1), reloaded.revocationsSlice().len);

    // Pairing again with a fresh, human-scanned ticket clears the tombstone.
    _ = try reloaded.trustTicket(phone, 9999);
    try testing.expect(!reloaded.isRevoked(phone.deviceId()));
    try testing.expect(reloaded.isTrusted(phone.deviceId()));
}

test "trust: applied revocations verify the signer and its trust" {
    const path = "test_trust_apply_revoke.store";
    cleanup(path);
    defer cleanup(path);

    var store = try Store.load(testing.allocator, path, null);
    defer store.deinit();

    const admin = try identity_mod.Identity.fromSeed([_]u8{0x73} ** identity_mod.seed_len);
    const admin_ticket = try testTicket(0x73, "admin");
    const phone_ticket = try testTicket(0x74, "phone");
    const stranger = try identity_mod.Identity.fromSeed([_]u8{0x75} ** identity_mod.seed_len);
    _ = try store.trustTicket(admin_ticket, 1);
    _ = try store.trustTicket(phone_ticket, 2);

    // An untrusted signer's revocation verifies cryptographically but is
    // never applied.
    const stranger_message = revocationMessage(phone_ticket.deviceId(), stranger.deviceId());
    const stranger_signature = try stranger.sign(&stranger_message);
    try testing.expect(!try applyRevocation(&store, phone_ticket.deviceId(), stranger.publicKey(), stranger_signature, 41));
    try testing.expect(store.isTrusted(phone_ticket.deviceId()));

    // A trusted signer's revocation is applied and tombstoned.
    const message = revocationMessage(phone_ticket.deviceId(), admin.deviceId());
    const signature = try admin.sign(&message);
    try testing.expect(try applyRevocation(&store, phone_ticket.deviceId(), admin.publicKey(), signature, 42));
    try testing.expect(store.isRevoked(phone_ticket.deviceId()));
    try testing.expect(!store.isTrusted(phone_ticket.deviceId()));

    // A corrupted signature is refused even from a trusted signer.
    var bad = signature;
    bad[0] ^= 0x01;
    _ = try store.trustTicket(phone_ticket, 3);
    try testing.expectError(error.SignatureVerificationFailed, applyRevocation(&store, phone_ticket.deviceId(), admin.publicKey(), bad, 43));
    try testing.expect(store.isTrusted(phone_ticket.deviceId()));

    // The revoked device cannot vouch for its own removal.
    const phone_identity = try identity_mod.Identity.fromSeed([_]u8{0x74} ** identity_mod.seed_len);
    const self_message = revocationMessage(phone_ticket.deviceId(), phone_ticket.deviceId());
    const self_signature = try phone_identity.sign(&self_message);
    try testing.expectError(Error.InvalidDeviceQuery, applyRevocation(&store, phone_ticket.deviceId(), phone_identity.publicKey(), self_signature, 44));
    try testing.expect(store.isTrusted(phone_ticket.deviceId()));
}

test "trust: a signed store rejects unauthorized edits" {
    const path = "test_trust_signed.store";
    cleanup(path);
    defer cleanup(path);

    const seed = [_]u8{0x91} ** identity_mod.seed_len;
    {
        var store = try Store.load(testing.allocator, path, seed);
        defer store.deinit();
        _ = try store.trustTicket(try testTicket(0x92, "alpha"), 1);
        try store.save();

        // Round-trip keeps working; the signature is verified on load.
        var verify = try Store.load(testing.allocator, path, seed);
        defer verify.deinit();
        try testing.expect(verify.isTrusted((try testTicket(0x92, "alpha")).deviceId()));
    }

    // A hand edit to one byte of the body makes the load fail outright.
    const io = std.Io.Threaded.global_single_threaded.io();
    const size = blk: {
        var f = try std.Io.Dir.cwd().openFile(io, path, .{});
        defer f.close(io);
        break :blk (try f.stat(io)).size;
    };
    const content = try testing.allocator.alloc(u8, size);
    defer testing.allocator.free(content);
    {
        var f = try std.Io.Dir.cwd().openFile(io, path, .{});
        defer f.close(io);
        _ = try f.readPositionalAll(io, content, 0);
    }
    // Labels are base64-encoded on disk; flip a byte inside the encoding.
    const label_pos = std.mem.indexOf(u8, content, "YWxwaGE").?;
    content[label_pos + 3] ^= 0x01;
    {
        var f = try std.Io.Dir.cwd().createFile(io, path, .{});
        defer f.close(io);
        try f.writePositionalAll(io, content, 0);
    }

    try testing.expectError(Error.BadStoreSignature, Store.load(testing.allocator, path, seed));

    // Removing the signature line fundamentally is not a workaround either:
    // a signed-load config refuses an unsigned file.
    const body_end = std.mem.lastIndexOf(u8, content, "\nSIG ").?;
    {
        var f = try std.Io.Dir.cwd().createFile(io, path, .{});
        defer f.close(io);
        try f.writePositionalAll(io, content[0 .. body_end + 1], 0);
    }
    try testing.expectError(Error.UnsignedTrustStore, Store.load(testing.allocator, path, seed));
}

test "trust: unsigned stores stay usable without a signing seed" {
    const path = "test_trust_unsigned.store";
    cleanup(path);
    defer cleanup(path);

    {
        var store = try Store.load(testing.allocator, path, null);
        defer store.deinit();
        _ = try store.trustTicket(try testTicket(0x93, "alpha"), 1);
        try store.save(); // no signing seed, so no SIG line is written
    }

    const io = std.Io.Threaded.global_single_threaded.io();
    var file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    const size = (try file.stat(io)).size;
    const content = try testing.allocator.alloc(u8, size);
    defer testing.allocator.free(content);
    _ = try file.readPositionalAll(io, content, 0);
    try testing.expect(std.mem.lastIndexOf(u8, content, "\nSIG ") == null);

    var verify = try Store.load(testing.allocator, path, null);
    defer verify.deinit();
    try testing.expectEqual(@as(usize, 1), verify.count());
}
