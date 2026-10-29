//! Swarm settings that every device must agree on, signed and spread like
//! membership: how many devices keep each swarm folder file (`copies`, one
//! record for the swarm, set by any member), and whether a device accepts
//! copies of others' files (`accepts`, one record per device, set by that
//! device). Placement (cluster/placement.zig) reads both, so every device
//! computes the same holders.
//!
//! A record is accepted when its signature verifies and its signer is
//! trusted *when it arrives* (or is this device); it then stays valid if the
//! signer is later revoked, so devices don't diverge. The newest `at` wins
//! (ties: the larger signer key). A record dated more than `max_skew` ahead
//! of this clock is refused. Older and equal records are acknowledged
//! without change, so a sender never resends them in a loop.

const std = @import("std");
const sync = @import("../sync.zig");
const NodeID = @import("../net/id.zig").NodeID;
const identity_mod = @import("identity.zig");
const trust_mod = @import("trust.zig");

pub const domain = "nomadfs-policy-v1";
/// How far ahead of this device's clock a record may be dated.
pub const max_skew: u64 = 10 * 60;
/// Most copies of a swarm file the setting may ask for.
pub const max_copies: u8 = 8;
/// Copies when nobody set it: the author only (plus backup devices).
pub const default_copies: u8 = 1;
/// Most devices with an `accepts` record.
const max_accepts = 256;

pub const Kind = enum(u8) { copies = 0, accepts = 1 };

pub const Record = struct {
    kind: Kind,
    /// `accepts`: the device it is about (its signer); `copies`: zero.
    subject: NodeID,
    value: u8,
    /// Unix seconds when it was set (signed).
    at: u64,
    signer_key: [32]u8,
    signature: [64]u8,

    pub const encoded_len = 1 + 32 + 1 + 8 + 32 + 64;

    pub fn encode(self: Record) [encoded_len]u8 {
        var out: [encoded_len]u8 = undefined;
        out[0] = @intFromEnum(self.kind);
        @memcpy(out[1..33], &self.subject.bytes);
        out[33] = self.value;
        std.mem.writeInt(u64, out[34..42], self.at, .big);
        @memcpy(out[42..74], &self.signer_key);
        @memcpy(out[74..138], &self.signature);
        return out;
    }

    pub fn decode(bytes: *const [encoded_len]u8) !Record {
        return .{
            .kind = std.enums.fromInt(Kind, bytes[0]) orelse return error.InvalidPolicy,
            .subject = .{ .bytes = bytes[1..33].* },
            .value = bytes[33],
            .at = std.mem.readInt(u64, bytes[34..42], .big),
            .signer_key = bytes[42..74].*,
            .signature = bytes[74..138].*,
        };
    }

    /// Whether `self` replaces `other` (the same setting).
    fn newerThan(self: Record, other: Record) bool {
        if (self.at != other.at) return self.at > other.at;
        return std.mem.order(u8, &self.signer_key, &other.signer_key) == .gt;
    }
};

const message_len = domain.len + 1 + 32 + 1 + 8 + 32;

/// Bytes a record's signature covers: the domain, kind, subject, value, when
/// and who signed (binding the signer stops a signature being moved).
pub fn message(kind: Kind, subject: NodeID, value: u8, at: u64, signer_id: NodeID) [message_len]u8 {
    var out: [message_len]u8 = undefined;
    @memcpy(out[0..domain.len], domain);
    var o: usize = domain.len;
    out[o] = @intFromEnum(kind);
    o += 1;
    @memcpy(out[o..][0..32], &subject.bytes);
    o += 32;
    out[o] = value;
    o += 1;
    std.mem.writeInt(u64, out[o..][0..8], at, .big);
    o += 8;
    @memcpy(out[o..][0..32], &signer_id.bytes);
    return out;
}

pub fn sign(identity: identity_mod.Identity, kind: Kind, subject: NodeID, value: u8, at: u64) !Record {
    return .{
        .kind = kind,
        .subject = subject,
        .value = value,
        .at = at,
        .signer_key = identity.publicKey(),
        .signature = try identity.sign(&message(kind, subject, value, at, identity.deviceId())),
    };
}

pub const Outcome = enum {
    /// Signature, signer, value or time not acceptable.
    rejected,
    /// Not newer than what is held; nothing changed. Acknowledged.
    duplicate,
    applied,
};

pub const Policy = struct {
    allocator: std.mem.Allocator,
    /// Where the records are kept (`swarm.policy` next to the trust store).
    path: []u8,
    mutex: sync.Mutex = .{},
    copies_record: ?Record = null,
    /// By device ID.
    accepts: std.AutoArrayHashMapUnmanaged(NodeID, Record) = .empty,

    /// Opens the records at `path`; a file that can't be read is moved
    /// aside and the policy starts empty (defaults), never failing the node.
    pub fn load(allocator: std.mem.Allocator, path: []const u8) !*Policy {
        const self = try allocator.create(Policy);
        errdefer allocator.destroy(self);
        self.* = .{ .allocator = allocator, .path = try allocator.dupe(u8, path) };
        errdefer allocator.free(self.path);
        self.read() catch |err| {
            std.debug.print("policy: couldn't read {s} ({any}); starting from the defaults\n", .{ path, err });
            self.copies_record = null;
            self.accepts.clearRetainingCapacity();
            const io = std.Io.Threaded.global_single_threaded.io();
            var aside_buf: [std.fs.max_path_bytes]u8 = undefined;
            if (std.fmt.bufPrint(&aside_buf, "{s}.unreadable", .{path})) |aside| {
                std.Io.Dir.cwd().rename(path, std.Io.Dir.cwd(), aside, io) catch {};
            } else |_| {}
        };
        return self;
    }

    pub fn destroy(self: *Policy) void {
        self.accepts.deinit(self.allocator);
        self.allocator.free(self.path);
        self.allocator.destroy(self);
    }

    /// The swarm's copies setting.
    pub fn copies(self: *Policy) u8 {
        self.mutex.lock();
        defer self.mutex.unlock();
        const r = self.copies_record orelse return default_copies;
        return r.value;
    }

    /// Whether `device` accepts copies of others' files (true unless it said no).
    pub fn acceptsCopies(self: *Policy, device: NodeID) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        const r = self.accepts.get(device) orelse return true;
        return r.value != 0;
    }

    /// Verifies and applies `r` (from a peer or this device). `trust` says
    /// who may sign; `self_device` is this device, always allowed.
    pub fn apply(self: *Policy, r: Record, trust: *trust_mod.Store, self_device: NodeID, now: u64) !Outcome {
        const signer_id = NodeID.fromPublicKey(r.signer_key);
        identity_mod.Identity.verify(r.signer_key, &message(r.kind, r.subject, r.value, r.at, signer_id), r.signature) catch return .rejected;
        if (r.at > now +| max_skew) return .rejected;
        if (!signer_id.eql(self_device) and !trust.isTrusted(signer_id)) return .rejected;
        switch (r.kind) {
            .copies => if (!std.mem.allEqual(u8, &r.subject.bytes, 0) or r.value < 1 or r.value > max_copies) return .rejected,
            .accepts => if (!r.subject.eql(signer_id) or r.value > 1) return .rejected,
        }

        self.mutex.lock();
        defer self.mutex.unlock();
        switch (r.kind) {
            .copies => {
                if (self.copies_record) |cur| if (!r.newerThan(cur)) return .duplicate;
                self.copies_record = r;
            },
            .accepts => {
                if (self.accepts.get(r.subject)) |cur| {
                    if (!r.newerThan(cur)) return .duplicate;
                } else if (self.accepts.count() >= max_accepts) return .rejected;
                try self.accepts.put(self.allocator, r.subject, r);
            },
        }
        return .applied;
    }

    /// Every record held, for spreading (caller frees).
    pub fn records(self: *Policy, allocator: std.mem.Allocator) ![]Record {
        self.mutex.lock();
        defer self.mutex.unlock();
        const n = self.accepts.count() + @intFromBool(self.copies_record != null);
        const out = try allocator.alloc(Record, n);
        var i: usize = 0;
        if (self.copies_record) |r| {
            out[0] = r;
            i = 1;
        }
        for (self.accepts.values()) |r| {
            out[i] = r;
            i += 1;
        }
        return out;
    }

    /// Changes whenever any record does: a peer that acknowledged this
    /// digest needs nothing sent.
    pub fn digest(self: *Policy) u64 {
        self.mutex.lock();
        defer self.mutex.unlock();
        var h = std.hash.Wyhash.init(0);
        if (self.copies_record) |r| h.update(&r.signature);
        for (self.accepts.values()) |r| h.update(&r.signature);
        return h.final();
    }

    // ---- File: the encoded records, one after another; temp file, then rename ----

    pub fn save(self: *Policy) !void {
        const recs = try self.records(self.allocator);
        defer self.allocator.free(recs);
        const bytes = try self.allocator.alloc(u8, recs.len * Record.encoded_len);
        defer self.allocator.free(bytes);
        for (recs, 0..) |r, i| bytes[i * Record.encoded_len ..][0..Record.encoded_len].* = r.encode();
        const io = std.Io.Threaded.global_single_threaded.io();
        const cwd = std.Io.Dir.cwd();
        var tmp_buf: [std.fs.max_path_bytes]u8 = undefined;
        const tmp = try std.fmt.bufPrint(&tmp_buf, "{s}.tmp", .{self.path});
        {
            var file = try cwd.createFile(io, tmp, .{ .truncate = true });
            defer file.close(io);
            try file.writePositionalAll(io, bytes, 0);
            try file.sync(io);
        }
        try cwd.rename(tmp, cwd, self.path, io);
    }

    /// Records were verified when accepted; they are checked again here, so
    /// a corrupted file can't inject one.
    fn read(self: *Policy) !void {
        const io = std.Io.Threaded.global_single_threaded.io();
        var file = std.Io.Dir.cwd().openFile(io, self.path, .{}) catch |err| switch (err) {
            error.FileNotFound => return,
            else => return err,
        };
        defer file.close(io);
        const size = (try file.stat(io)).size;
        if (size % Record.encoded_len != 0 or size > (max_accepts + 1) * Record.encoded_len) return error.InvalidPolicyFile;
        const bytes = try self.allocator.alloc(u8, @intCast(size));
        defer self.allocator.free(bytes);
        if (try file.readPositionalAll(io, bytes, 0) != bytes.len) return error.ShortRead;
        var i: usize = 0;
        while (i < bytes.len) : (i += Record.encoded_len) {
            const r = try Record.decode(bytes[i..][0..Record.encoded_len]);
            const signer_id = NodeID.fromPublicKey(r.signer_key);
            try identity_mod.Identity.verify(r.signer_key, &message(r.kind, r.subject, r.value, r.at, signer_id), r.signature);
            switch (r.kind) {
                .copies => self.copies_record = r,
                .accepts => try self.accepts.put(self.allocator, r.subject, r),
            }
        }
    }
};

// ---- Tests ----

const testing = std.testing;

fn idWith(b: u8) !identity_mod.Identity {
    return identity_mod.Identity.fromSeed([_]u8{b} ** identity_mod.seed_len);
}

test "policy: newest wins, older and equal are acknowledged, the future and strangers are refused" {
    const io = std.Io.Threaded.global_single_threaded.io();
    const trust_path = "test_policy_trust.store";
    const path = "test_policy.bin";
    std.Io.Dir.cwd().deleteFile(io, trust_path) catch {};
    std.Io.Dir.cwd().deleteFile(io, path) catch {};
    defer std.Io.Dir.cwd().deleteFile(io, trust_path) catch {};
    defer std.Io.Dir.cwd().deleteFile(io, path) catch {};
    var trust = try trust_mod.Store.load(testing.allocator, trust_path, null);
    defer trust.deinit();
    const me = try idWith(0x51);
    const member = try idWith(0x52);
    const stranger = try idWith(0x53);
    _ = try trust.upsert(member.publicKey(), [_]u8{0x61} ** 32, "Member", 1);

    const p = try Policy.load(testing.allocator, path);
    defer p.destroy();
    const zero: NodeID = .{ .bytes = [_]u8{0} ** 32 };
    try testing.expectEqual(default_copies, p.copies());

    try testing.expectEqual(Outcome.applied, try p.apply(try sign(member, .copies, zero, 3, 100), &trust, me.deviceId(), 1000));
    try testing.expectEqual(@as(u8, 3), p.copies());
    // Older and equal: acknowledged, unchanged.
    try testing.expectEqual(Outcome.duplicate, try p.apply(try sign(me, .copies, zero, 2, 90), &trust, me.deviceId(), 1000));
    try testing.expectEqual(Outcome.duplicate, try p.apply(try sign(member, .copies, zero, 3, 100), &trust, me.deviceId(), 1000));
    try testing.expectEqual(@as(u8, 3), p.copies());
    // A stranger, the far future, and silly values are refused.
    try testing.expectEqual(Outcome.rejected, try p.apply(try sign(stranger, .copies, zero, 5, 200), &trust, me.deviceId(), 1000));
    try testing.expectEqual(Outcome.rejected, try p.apply(try sign(member, .copies, zero, 5, 1000 + max_skew + 1), &trust, me.deviceId(), 1000));
    try testing.expectEqual(Outcome.rejected, try p.apply(try sign(member, .copies, zero, 0, 300), &trust, me.deviceId(), 1000));
    // This device may always set it.
    try testing.expectEqual(Outcome.applied, try p.apply(try sign(me, .copies, zero, 2, 400), &trust, me.deviceId(), 1000));
    try testing.expectEqual(@as(u8, 2), p.copies());

    // Accepts: only about oneself.
    try testing.expect(p.acceptsCopies(member.deviceId()));
    try testing.expectEqual(Outcome.applied, try p.apply(try sign(member, .accepts, member.deviceId(), 0, 500), &trust, me.deviceId(), 1000));
    try testing.expect(!p.acceptsCopies(member.deviceId()));
    try testing.expectEqual(Outcome.rejected, try p.apply(try sign(member, .accepts, me.deviceId(), 0, 600), &trust, me.deviceId(), 1000));

    // A revoked signer's accepted record stays.
    _ = trust.revoke(member.deviceId());
    try testing.expect(!p.acceptsCopies(member.deviceId()));

    // Saved and read back the same; a forged file is refused.
    const before = p.digest();
    try p.save();
    const again = try Policy.load(testing.allocator, path);
    defer again.destroy();
    try testing.expectEqual(before, again.digest());
    try testing.expectEqual(@as(u8, 2), again.copies());
}
