//! Long-lived device identity keyed by Ed25519.
//!
//! The X25519 key used for Noise transport is ephemeral to the transport
//! layer; this key is what peers remember across sessions. It is stored as
//! `NMDFSID1` followed by the 32-byte RFC 8032 seed, which keeps the on-disk
//! format small enough to paste into a backup and stable across Zig versions.

const std = @import("std");
const builtin = @import("builtin");
const Ed25519 = std.crypto.sign.Ed25519;
const NodeID = @import("../net/id.zig").NodeID;

pub const magic = "NMDFSID1";
pub const seed_len = Ed25519.KeyPair.seed_length;
/// 8-byte magic plus the 32-byte seed.
pub const file_len = magic.len + seed_len;

pub const Identity = struct {
    key_pair: Ed25519.KeyPair,

    pub fn generate() Identity {
        const io = std.Io.Threaded.global_single_threaded.io();
        return .{ .key_pair = Ed25519.KeyPair.generate(io) };
    }

    /// Deterministic construction, used for tests and for rehydrating a seed
    /// loaded from disk.
    pub fn fromSeed(seed_bytes: [seed_len]u8) !Identity {
        const key_pair = try Ed25519.KeyPair.generateDeterministic(seed_bytes);
        return .{ .key_pair = key_pair };
    }

    pub fn seed(self: Identity) [seed_len]u8 {
        return self.key_pair.secret_key.seed();
    }

    pub fn publicKey(self: Identity) [Ed25519.PublicKey.encoded_length]u8 {
        return self.key_pair.public_key.toBytes();
    }

    /// Stable identifier peers use to recognise this device. Derived from the
    /// public key so a ticket never has to carry it separately.
    pub fn deviceId(self: Identity) NodeID {
        return NodeID.fromPublicKey(self.publicKey());
    }

    /// Deterministic signatures keep tickets and tests reproducible; there is
    /// no fault-attack threat model here that would need fresh randomness.
    pub fn sign(self: Identity, message: []const u8) ![Ed25519.Signature.encoded_length]u8 {
        const signature = try self.key_pair.sign(message, null);
        return signature.toBytes();
    }

    pub fn verify(
        public_key: [Ed25519.PublicKey.encoded_length]u8,
        message: []const u8,
        signature: [Ed25519.Signature.encoded_length]u8,
    ) !void {
        const key = try Ed25519.PublicKey.fromBytes(public_key);
        const sig = Ed25519.Signature.fromBytes(signature);
        try sig.verify(message, key);
    }

    /// Short, human-comparable digest of the public key. Not a security
    /// boundary on its own - the signature check is.
    pub const fingerprint_len = 8;

    pub fn fingerprint(self: Identity) [fingerprint_len]u8 {
        return fingerprintOf(self.publicKey());
    }

    pub fn fingerprintOf(public_key: [Ed25519.PublicKey.encoded_length]u8) [fingerprint_len]u8 {
        var digest: [32]u8 = undefined;
        std.crypto.hash.blake2.Blake2s256.hash(&public_key, &digest, .{});
        return digest[0..fingerprint_len].*;
    }

    /// Renders a fingerprint as `aaaa-bbbb-cccc-dddd` for read-aloud
    /// comparison during out-of-band pairing.
    pub fn formatFingerprint(fp: [fingerprint_len]u8, out: *[19]u8) []const u8 {
        const hex = "0123456789abcdef";
        var written: usize = 0;
        for (fp, 0..) |byte, i| {
            if (i != 0 and i % 2 == 0) {
                out[written] = '-';
                written += 1;
            }
            out[written] = hex[byte >> 4];
            out[written + 1] = hex[byte & 0x0f];
            written += 2;
        }
        return out[0..written];
    }

    /// Owner-only: the file holds the device's private seed.
    const key_file_permissions: std.Io.File.Permissions =
        if (builtin.os.tag == .windows) .default_file else @enumFromInt(0o600);

    /// Loads the identity at `path`, creating one only when the file does not
    /// exist. An existing but unusable file is reported, never replaced.
    pub fn loadOrCreate(path: []const u8) !Identity {
        if (loadFromFile(path)) |loaded| return loaded else |err| switch (err) {
            error.FileNotFound => {},
            else => {
                std.debug.print("Refusing to replace unusable identity file '{s}': {any}\n", .{ path, err });
                return err;
            },
        }

        const created = generate();
        created.saveToFile(path) catch |err| switch (err) {
            error.PathAlreadyExists => return loadFromFile(path),
            else => return err,
        };
        return created;
    }

    /// Loads the identity, treating `error.FileNotFound` as "no identity yet".
    /// Any other error means a file exists but cannot be trusted and must not
    /// be silently replaced.
    pub fn loadFromFile(path: []const u8) !Identity {
        const io = std.Io.Threaded.global_single_threaded.io();
        var file = try std.Io.Dir.cwd().openFile(io, path, .{});
        defer file.close(io);

        if ((try file.stat(io)).size != file_len) return error.InvalidKeyFile;
        var buf: [file_len]u8 = undefined;
        defer std.crypto.secureZero(u8, &buf);
        if (try file.readPositionalAll(io, &buf, 0) != file_len) return error.InvalidKeyFile;
        if (!std.mem.eql(u8, buf[0..magic.len], magic)) return error.InvalidKeyFile;

        var seed_bytes: [seed_len]u8 = undefined;
        defer std.crypto.secureZero(u8, &seed_bytes);
        @memcpy(&seed_bytes, buf[magic.len..]);
        return fromSeed(seed_bytes) catch error.InvalidKeyFile;
    }

    /// Writes a new identity. Never overwrites an existing one, and never
    /// leaves a partial file under `path`: the bytes go to `<path>.tmp`,
    /// are synced, and are renamed into place only if `path` doesn't exist.
    /// (Not O_TMPFILE + linkat: Android's SELinux denies apps `link`.)
    pub fn saveToFile(self: Identity, path: []const u8) !void {
        const io = std.Io.Threaded.global_single_threaded.io();
        const cwd = std.Io.Dir.cwd();
        var tmp_buf: [std.fs.max_path_bytes]u8 = undefined;
        const tmp_path = try std.fmt.bufPrint(&tmp_buf, "{s}.tmp", .{path});

        var buf: [file_len]u8 = undefined;
        defer std.crypto.secureZero(u8, &buf);
        @memcpy(buf[0..magic.len], magic);
        buf[magic.len..].* = self.seed();
        {
            var file = try cwd.createFile(io, tmp_path, .{ .truncate = true, .permissions = key_file_permissions });
            defer file.close(io);
            errdefer cwd.deleteFile(io, tmp_path) catch {};
            try file.setPermissions(io, key_file_permissions);
            try file.writePositionalAll(io, &buf, 0);
            try file.sync(io);
        }
        errdefer cwd.deleteFile(io, tmp_path) catch {};
        try publishNoReplace(io, tmp_path, path);
    }
};

/// Renames `tmp_path` to `path`, failing with error.PathAlreadyExists when
/// `path` exists, so a concurrent first run can't replace an identity.
fn publishNoReplace(io: std.Io, tmp_path: []const u8, path: []const u8) !void {
    if (builtin.os.tag == .linux) {
        const linux = std.os.linux;
        var from: [std.fs.max_path_bytes:0]u8 = undefined;
        var to: [std.fs.max_path_bytes:0]u8 = undefined;
        const from_z = try std.fmt.bufPrintZ(&from, "{s}", .{tmp_path});
        const to_z = try std.fmt.bufPrintZ(&to, "{s}", .{path});
        const rc = linux.renameat2(linux.AT.FDCWD, from_z.ptr, linux.AT.FDCWD, to_z.ptr, .{ .NOREPLACE = true });
        switch (linux.errno(rc)) {
            .SUCCESS => return,
            .EXIST => return error.PathAlreadyExists,
            // Old kernels and some filesystems lack renameat2: check, then rename.
            .NOSYS, .INVAL => {},
            else => return error.Unexpected,
        }
    }
    const cwd = std.Io.Dir.cwd();
    if (cwd.access(io, path, .{})) |_| return error.PathAlreadyExists else |_| {}
    try cwd.rename(tmp_path, cwd, path, io);
}

test "identity: seed round-trips and signatures verify" {
    const seed = [_]u8{0x42} ** seed_len;
    const identity = try Identity.fromSeed(seed);
    try std.testing.expectEqual(seed, identity.seed());

    const message = "nomadfs pairing ticket";
    const signature = try identity.sign(message);
    try Identity.verify(identity.publicKey(), message, signature);

    try std.testing.expectError(
        error.SignatureVerificationFailed,
        Identity.verify(identity.publicKey(), "different message", signature),
    );

    // A different key must not validate the same signature.
    const other = try Identity.fromSeed([_]u8{0x43} ** seed_len);
    try std.testing.expect(!std.mem.eql(u8, &identity.publicKey(), &other.publicKey()));
}

test "identity: device id is derived, not stored" {
    const identity = try Identity.fromSeed([_]u8{0x11} ** seed_len);
    const expected = NodeID.fromPublicKey(identity.publicKey());
    try std.testing.expect(identity.deviceId().eql(expected));

    const duplicate = try Identity.fromSeed([_]u8{0x11} ** seed_len);
    try std.testing.expect(identity.deviceId().eql(duplicate.deviceId()));
}

test "identity: fingerprint formatting is stable" {
    var out: [19]u8 = undefined;
    const text = Identity.formatFingerprint(.{ 0xab, 0xcd, 0x01, 0x23, 0x45, 0x67, 0x89, 0xef }, &out);
    try std.testing.expectEqualStrings("abcd-0123-4567-89ef", text);
}

test "identity: loadOrCreate keeps one identity across runs" {
    const io = std.Io.Threaded.global_single_threaded.io();
    const path = "test_device_load_or_create.key";
    std.Io.Dir.cwd().deleteFile(io, path) catch {};
    defer std.Io.Dir.cwd().deleteFile(io, path) catch {};

    const first = try Identity.loadOrCreate(path);
    const second = try Identity.loadOrCreate(path);
    try std.testing.expectEqual(first.publicKey(), second.publicKey());

    // A corrupt file must not be replaced by a new identity.
    std.Io.Dir.cwd().deleteFile(io, path) catch {};
    {
        var file = try std.Io.Dir.cwd().createFile(io, path, .{});
        defer file.close(io);
        try file.writePositionalAll(io, "garbage!", 0);
    }
    try std.testing.expectError(error.InvalidKeyFile, Identity.loadOrCreate(path));
}

test "identity: key files are private and never silently replaced" {
    const io = std.Io.Threaded.global_single_threaded.io();
    const path = "test_device_identity.key";
    std.Io.Dir.cwd().deleteFile(io, path) catch {};
    defer std.Io.Dir.cwd().deleteFile(io, path) catch {};

    const identity = try Identity.fromSeed([_]u8{0x7f} ** seed_len);
    try identity.saveToFile(path);

    const loaded = try Identity.loadFromFile(path);
    try std.testing.expectEqual(identity.publicKey(), loaded.publicKey());
    try std.testing.expectEqual(identity.seed(), loaded.seed());

    if (builtin.os.tag != .windows) {
        var file = try std.Io.Dir.cwd().openFile(io, path, .{});
        defer file.close(io);
        const mode = @intFromEnum((try file.stat(io)).permissions);
        try std.testing.expectEqual(@as(@TypeOf(mode), 0), mode & 0o077);
    }

    // Never clobber an existing identity.
    try std.testing.expectError(error.PathAlreadyExists, Identity.generate().saveToFile(path));

    // A missing file is distinct from an unusable one.
    try std.testing.expectError(error.FileNotFound, Identity.loadFromFile("test_device_missing.key"));

    std.Io.Dir.cwd().deleteFile(io, path) catch {};
    {
        var file = try std.Io.Dir.cwd().createFile(io, path, .{});
        defer file.close(io);
        try file.writePositionalAll(io, "NMDFSID1short", 0);
    }
    try std.testing.expectError(error.InvalidKeyFile, Identity.loadFromFile(path));

    // Correct length but wrong magic.
    std.Io.Dir.cwd().deleteFile(io, path) catch {};
    {
        var file = try std.Io.Dir.cwd().createFile(io, path, .{});
        defer file.close(io);
        const junk = [_]u8{0} ** file_len;
        try file.writePositionalAll(io, &junk, 0);
    }
    try std.testing.expectError(error.InvalidKeyFile, Identity.loadFromFile(path));
}
