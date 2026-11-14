//! Backup key generation and envelope wrapping for devices and recovery phrases.
//!
//! A bucket uses a random 32-byte backup key identified by the first 8 bytes
//! of its SHA-256 digest. The backup key is wrapped in two ways:
//!
//! 1. Device wrap (`NBDW`, 117 bytes): an X25519 sealed box to a trusted
//!    device's static X25519 public key (ephemeral X25519 key pair +
//!    HKDF-SHA256 + XChaCha20-Poly1305).
//!    Layout: `[4 magic "NBDW"][1 version][8 key_id][32 ephemeral_pk][24 nonce][32 ct][16 tag]`.
//!
//! 2. Recovery wrap (`NBRW`, 101 bytes): derived from a 24-word BIP-39
//!    recovery phrase via Argon2id (`t = 2, m = 19 MiB, p = 1`, OWASP 2id
//!    profile suitable for phones) + XChaCha20-Poly1305.
//!    Layout: `[4 magic "NBRW"][1 version][8 key_id][16 salt][24 nonce][32 ct][16 tag]`.

const std = @import("std");
const recovery_words = @import("recovery_words.zig");

const Sha256 = std.crypto.hash.sha2.Sha256;
const X25519 = std.crypto.dh.X25519;
const HkdfSha256 = std.crypto.kdf.hkdf.HkdfSha256;
const XChaCha20Poly1305 = std.crypto.aead.chacha_poly.XChaCha20Poly1305;
const argon2 = std.crypto.pwhash.argon2;

pub const key_len = 32;
pub const key_id_len = 8;
pub const salt_len = 16;
pub const nonce_len = XChaCha20Poly1305.nonce_length;
pub const tag_len = XChaCha20Poly1305.tag_length;
pub const ciphertext_len = key_len + tag_len;

pub const wrap_version: u8 = 1;
pub const device_wrap_magic = "NBDW".*;
pub const recovery_wrap_magic = "NBRW".*;

const header_prefix_len = 4 + 1 + key_id_len;
const device_header_len = header_prefix_len + X25519.public_length + nonce_len;
const recovery_header_len = header_prefix_len + salt_len + nonce_len;

/// Total encoded size of a device key wrap blob (117 bytes).
pub const device_wrap_len = device_header_len + ciphertext_len;

/// Total encoded size of a recovery key wrap blob (101 bytes).
pub const recovery_wrap_len = recovery_header_len + ciphertext_len;

/// HKDF context string binding the device wrap version and purpose.
pub const device_wrap_hkdf_info = "nomadfs-backup-device-wrap-v1";

/// Fixed Argon2id parameters suitable for mobile devices (2 passes, 19 MiB
/// memory, 1 lane).
pub const recovery_argon2_params: argon2.Params = argon2.Params.owasp_2id;

pub const Key = [key_len]u8;
pub const KeyId = [key_id_len]u8;
pub const DeviceWrap = [device_wrap_len]u8;
pub const RecoveryWrap = [recovery_wrap_len]u8;

pub const Error = error{
    InvalidWrapMagic,
    UnsupportedWrapVersion,
    InvalidWrapLength,
    KeyIdMismatch,
    AuthenticationFailed,
    WeakPublicKey,
} || recovery_words.Error;

/// A 32-byte symmetric backup key.
pub const BackupKey = struct {
    bytes: Key,

    /// Generates a fresh 32-byte random backup key from OS CSPRNG.
    pub fn generate() !BackupKey {
        return .{ .bytes = try generateKey() };
    }

    pub fn fromBytes(bytes: Key) BackupKey {
        return .{ .bytes = bytes };
    }

    pub fn id(self: BackupKey) KeyId {
        return keyId(self.bytes);
    }

    pub fn deinit(self: *BackupKey) void {
        std.crypto.secureZero(u8, &self.bytes);
    }
};

/// Generates a fresh 32-byte random backup key.
pub fn generateKey() !Key {
    var key: Key = undefined;
    try std.Io.Threaded.global_single_threaded.io().randomSecure(&key);
    return key;
}

/// Computes the 8-byte key identifier: the first 8 bytes of SHA-256(key).
pub fn keyId(key: Key) KeyId {
    var digest: [Sha256.digest_length]u8 = undefined;
    Sha256.hash(&key, &digest, .{});
    defer std.crypto.secureZero(u8, &digest);
    return digest[0..key_id_len].*;
}

/// Reads the 8-byte key ID from either a device wrap or recovery wrap blob
/// without decrypting it.
pub fn wrappedKeyId(blob: []const u8) Error!KeyId {
    if (blob.len < header_prefix_len) return Error.InvalidWrapLength;
    const magic = blob[0..4];
    if (std.mem.eql(u8, magic, &device_wrap_magic)) {
        if (blob.len != device_wrap_len) return Error.InvalidWrapLength;
    } else if (std.mem.eql(u8, magic, &recovery_wrap_magic)) {
        if (blob.len != recovery_wrap_len) return Error.InvalidWrapLength;
    } else {
        return Error.InvalidWrapMagic;
    }
    if (blob[4] != wrap_version) return Error.UnsupportedWrapVersion;
    return blob[5..header_prefix_len].*;
}

/// Seals `backup_key` to `device_public_key` using a fresh ephemeral X25519
/// key pair, HKDF-SHA256, and XChaCha20-Poly1305.
pub fn wrapForDevice(
    backup_key: Key,
    device_public_key: [X25519.public_length]u8,
) !DeviceWrap {
    const io = std.Io.Threaded.global_single_threaded.io();
    var ephemeral_seed: [X25519.seed_length]u8 = undefined;
    defer std.crypto.secureZero(u8, &ephemeral_seed);
    var nonce: [nonce_len]u8 = undefined;
    try io.randomSecure(&nonce);

    // Bounded retry in the astronomically unlikely case of a weak random seed.
    for (0..8) |_| {
        try io.randomSecure(&ephemeral_seed);
        return wrapForDeviceDeterministic(backup_key, device_public_key, ephemeral_seed, nonce) catch |err| switch (err) {
            Error.WeakPublicKey => continue,
            else => return err,
        };
    }
    return Error.WeakPublicKey;
}

/// Deterministic variant of `wrapForDevice` for reproducible test vectors.
pub fn wrapForDeviceDeterministic(
    backup_key: Key,
    device_public_key: [X25519.public_length]u8,
    ephemeral_seed: [X25519.seed_length]u8,
    nonce: [nonce_len]u8,
) Error!DeviceWrap {
    var ephemeral = X25519.KeyPair.generateDeterministic(ephemeral_seed) catch return Error.WeakPublicKey;
    defer std.crypto.secureZero(u8, &ephemeral.secret_key);

    var shared: [X25519.shared_length]u8 = X25519.scalarmult(ephemeral.secret_key, device_public_key) catch return Error.WeakPublicKey;
    defer std.crypto.secureZero(u8, &shared);

    var wrap_key = deriveDeviceWrappingKey(shared, ephemeral.public_key, device_public_key);
    defer std.crypto.secureZero(u8, &wrap_key);

    var out: DeviceWrap = undefined;
    @memcpy(out[0..4], &device_wrap_magic);
    out[4] = wrap_version;
    const id = keyId(backup_key);
    @memcpy(out[5..header_prefix_len], &id);
    @memcpy(out[header_prefix_len .. header_prefix_len + X25519.public_length], &ephemeral.public_key);
    @memcpy(out[header_prefix_len + X25519.public_length .. device_header_len], &nonce);

    const ad = out[0..device_header_len];
    var tag: [tag_len]u8 = undefined;
    XChaCha20Poly1305.encrypt(
        out[device_header_len .. device_header_len + key_len],
        &tag,
        &backup_key,
        ad,
        nonce,
        wrap_key,
    );
    @memcpy(out[device_header_len + key_len .. device_wrap_len], &tag);
    return out;
}

/// Opens a device-wrapped backup key blob using the recipient device's X25519
/// secret key.
pub fn unwrapForDevice(
    blob: []const u8,
    device_secret_key: [X25519.secret_length]u8,
) Error!Key {
    if (blob.len < 4) return Error.InvalidWrapLength;
    if (!std.mem.eql(u8, blob[0..4], &device_wrap_magic)) return Error.InvalidWrapMagic;
    if (blob.len != device_wrap_len) return Error.InvalidWrapLength;
    if (blob[4] != wrap_version) return Error.UnsupportedWrapVersion;

    const expected_key_id = blob[5..header_prefix_len].*;
    const ephemeral_pk = blob[header_prefix_len .. header_prefix_len + X25519.public_length].*;
    const nonce = blob[header_prefix_len + X25519.public_length .. device_header_len].*;
    const ct = blob[device_header_len .. device_header_len + key_len];
    const tag = blob[device_header_len + key_len .. device_wrap_len].*;

    const device_pk = X25519.recoverPublicKey(device_secret_key) catch return Error.WeakPublicKey;
    var shared = X25519.scalarmult(device_secret_key, ephemeral_pk) catch return Error.AuthenticationFailed;
    defer std.crypto.secureZero(u8, &shared);

    var wrap_key = deriveDeviceWrappingKey(shared, ephemeral_pk, device_pk);
    defer std.crypto.secureZero(u8, &wrap_key);

    var backup_key: Key = undefined;
    errdefer std.crypto.secureZero(u8, &backup_key);

    const ad = blob[0..device_header_len];
    XChaCha20Poly1305.decrypt(&backup_key, ct, tag, ad, nonce, wrap_key) catch return Error.AuthenticationFailed;

    if (!std.crypto.timing_safe.eql(KeyId, keyId(backup_key), expected_key_id)) {
        return Error.KeyIdMismatch;
    }
    return backup_key;
}

fn deriveDeviceWrappingKey(
    shared_secret: [X25519.shared_length]u8,
    ephemeral_pk: [X25519.public_length]u8,
    recipient_pk: [X25519.public_length]u8,
) Key {
    var hkdf_salt: [X25519.public_length * 2]u8 = undefined;
    @memcpy(hkdf_salt[0..X25519.public_length], &ephemeral_pk);
    @memcpy(hkdf_salt[X25519.public_length..], &recipient_pk);

    var prk = HkdfSha256.extract(&hkdf_salt, &shared_secret);
    defer std.crypto.secureZero(u8, &prk);

    var out: Key = undefined;
    HkdfSha256.expand(&out, device_wrap_hkdf_info, prk);
    return out;
}

/// Validates a 24-word recovery phrase (including its BIP-39 checksum),
/// canonicalizes it to lowercase single-space-separated words, and derives a
/// 32-byte wrapping key using Argon2id.
pub fn deriveRecoveryKey(
    allocator: std.mem.Allocator,
    phrase: []const u8,
    salt: [salt_len]u8,
) !Key {
    var canonical_buf: [recovery_words.max_phrase_len]u8 = undefined;
    defer std.crypto.secureZero(u8, &canonical_buf);
    const canonical = try recovery_words.canonicalizePhrase(phrase, &canonical_buf);

    var derived: Key = undefined;
    errdefer std.crypto.secureZero(u8, &derived);

    const io = std.Io.Threaded.global_single_threaded.io();
    try argon2.kdf(
        allocator,
        &derived,
        canonical,
        &salt,
        recovery_argon2_params,
        .argon2id,
        io,
    );
    return derived;
}

/// Seals `backup_key` with a 24-word BIP-39 recovery phrase using a random
/// 16-byte Argon2id salt and 24-byte XChaCha20-Poly1305 nonce.
pub fn wrapWithRecovery(
    allocator: std.mem.Allocator,
    backup_key: Key,
    phrase: []const u8,
) !RecoveryWrap {
    const io = std.Io.Threaded.global_single_threaded.io();
    var salt: [salt_len]u8 = undefined;
    var nonce: [nonce_len]u8 = undefined;
    try io.randomSecure(&salt);
    try io.randomSecure(&nonce);
    return wrapWithRecoveryDeterministic(allocator, backup_key, phrase, salt, nonce);
}

/// Deterministic variant of `wrapWithRecovery` for reproducible tests.
pub fn wrapWithRecoveryDeterministic(
    allocator: std.mem.Allocator,
    backup_key: Key,
    phrase: []const u8,
    salt: [salt_len]u8,
    nonce: [nonce_len]u8,
) !RecoveryWrap {
    var wrap_key = try deriveRecoveryKey(allocator, phrase, salt);
    defer std.crypto.secureZero(u8, &wrap_key);

    var out: RecoveryWrap = undefined;
    @memcpy(out[0..4], &recovery_wrap_magic);
    out[4] = wrap_version;
    const id = keyId(backup_key);
    @memcpy(out[5..header_prefix_len], &id);
    @memcpy(out[header_prefix_len .. header_prefix_len + salt_len], &salt);
    @memcpy(out[header_prefix_len + salt_len .. recovery_header_len], &nonce);

    const ad = out[0..recovery_header_len];
    var tag: [tag_len]u8 = undefined;
    XChaCha20Poly1305.encrypt(
        out[recovery_header_len .. recovery_header_len + key_len],
        &tag,
        &backup_key,
        ad,
        nonce,
        wrap_key,
    );
    @memcpy(out[recovery_header_len + key_len .. recovery_wrap_len], &tag);
    return out;
}

/// Unwraps a recovery-wrapped backup key blob using the 24-word recovery
/// phrase. Rejects phrases with invalid words or a bad BIP-39 checksum before
/// running Argon2id.
pub fn unwrapWithRecovery(
    allocator: std.mem.Allocator,
    blob: []const u8,
    phrase: []const u8,
) !Key {
    if (blob.len < 4) return Error.InvalidWrapLength;
    if (!std.mem.eql(u8, blob[0..4], &recovery_wrap_magic)) return Error.InvalidWrapMagic;
    if (blob.len != recovery_wrap_len) return Error.InvalidWrapLength;
    if (blob[4] != wrap_version) return Error.UnsupportedWrapVersion;

    const expected_key_id = blob[5..header_prefix_len].*;
    const salt = blob[header_prefix_len .. header_prefix_len + salt_len].*;
    const nonce = blob[header_prefix_len + salt_len .. recovery_header_len].*;
    const ct = blob[recovery_header_len .. recovery_header_len + key_len];
    const tag = blob[recovery_header_len + key_len .. recovery_wrap_len].*;

    var wrap_key = try deriveRecoveryKey(allocator, phrase, salt);
    defer std.crypto.secureZero(u8, &wrap_key);

    var backup_key: Key = undefined;
    errdefer std.crypto.secureZero(u8, &backup_key);

    const ad = blob[0..recovery_header_len];
    XChaCha20Poly1305.decrypt(&backup_key, ct, tag, ad, nonce, wrap_key) catch return Error.AuthenticationFailed;

    if (!std.crypto.timing_safe.eql(KeyId, keyId(backup_key), expected_key_id)) {
        return Error.KeyIdMismatch;
    }
    return backup_key;
}

test "keys: backup key generation and keyId" {
    var k1 = try BackupKey.generate();
    defer k1.deinit();
    var k2 = try BackupKey.generate();
    defer k2.deinit();

    try std.testing.expect(!std.mem.eql(u8, &k1.bytes, &k2.bytes));

    var full_sha: [32]u8 = undefined;
    Sha256.hash(&k1.bytes, &full_sha, .{});
    try std.testing.expectEqualSlices(u8, full_sha[0..8], &k1.id());
}

test "keys: device wrap/unwrap round trip, wrong key, and tamper detection" {
    const io = std.Io.Threaded.global_single_threaded.io();
    var backup_key = try BackupKey.generate();
    defer backup_key.deinit();

    var recipient = X25519.KeyPair.generate(io);
    defer std.crypto.secureZero(u8, &recipient.secret_key);

    var other_device = X25519.KeyPair.generate(io);
    defer std.crypto.secureZero(u8, &other_device.secret_key);

    const wrapped = try wrapForDevice(backup_key.bytes, recipient.public_key);
    try std.testing.expectEqual(@as(usize, device_wrap_len), wrapped.len);
    try std.testing.expectEqualSlices(u8, &backup_key.id(), &(try wrappedKeyId(&wrapped)));

    // Round trip with recipient secret key.
    const unwrapped = try unwrapForDevice(&wrapped, recipient.secret_key);
    try std.testing.expectEqualSlices(u8, &backup_key.bytes, &unwrapped);

    // Wrong device secret key fails authentication.
    try std.testing.expectError(
        Error.AuthenticationFailed,
        unwrapForDevice(&wrapped, other_device.secret_key),
    );

    // Flipping any byte in the blob is rejected.
    for (0..wrapped.len) |i| {
        var tampered = wrapped;
        tampered[i] ^= 0x01;
        try std.testing.expect(if (unwrapForDevice(&tampered, recipient.secret_key)) |_| false else |_| true);
    }

    // Truncated blob is rejected.
    try std.testing.expectError(
        Error.InvalidWrapLength,
        unwrapForDevice(wrapped[0 .. wrapped.len - 1], recipient.secret_key),
    );
}

test "keys: recovery wrap/unwrap round trip, wrong phrase, bad checksum, and tamper detection" {
    const allocator = std.testing.allocator;
    var backup_key = try BackupKey.generate();
    defer backup_key.deinit();

    const entropy_a = [_]u8{0x00} ** 32;
    var phrase_a_buf: [recovery_words.max_phrase_len]u8 = undefined;
    const phrase_a = recovery_words.formatPhrase(entropy_a, &phrase_a_buf);

    const entropy_b = [_]u8{0xff} ** 32;
    var phrase_b_buf: [recovery_words.max_phrase_len]u8 = undefined;
    const phrase_b = recovery_words.formatPhrase(entropy_b, &phrase_b_buf);

    const wrapped = try wrapWithRecovery(allocator, backup_key.bytes, phrase_a);
    try std.testing.expectEqual(@as(usize, recovery_wrap_len), wrapped.len);
    try std.testing.expectEqualSlices(u8, &backup_key.id(), &(try wrappedKeyId(&wrapped)));

    // Round trip with uppercase and extra whitespace in the recovery phrase.
    const messy_phrase_a =
        "  ABANDON abandon   abandon abandon abandon abandon abandon abandon\n" ++
        "abandon abandon abandon abandon abandon abandon abandon abandon\t" ++
        "abandon abandon abandon abandon abandon abandon abandon ART ";
    const unwrapped = try unwrapWithRecovery(allocator, &wrapped, messy_phrase_a);
    try std.testing.expectEqualSlices(u8, &backup_key.bytes, &unwrapped);

    // Wrong recovery phrase (valid BIP-39 checksum, different key) fails AEAD decryption.
    try std.testing.expectError(
        Error.AuthenticationFailed,
        unwrapWithRecovery(allocator, &wrapped, phrase_b),
    );

    // Bad BIP-39 checksum in recovery phrase is rejected before decrypting.
    const bad_checksum_phrase = "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon";
    try std.testing.expectError(
        Error.ChecksumMismatch,
        unwrapWithRecovery(allocator, &wrapped, bad_checksum_phrase),
    );

    // Unknown word / typo in recovery phrase is rejected.
    const typo_phrase = "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon artt";
    try std.testing.expectError(
        Error.UnknownWord,
        unwrapWithRecovery(allocator, &wrapped, typo_phrase),
    );

    // Flipping bytes in header, salt, nonce, ciphertext, or tag is rejected.
    const offsets_to_tamper = [_]usize{ 0, 4, 5, 13, 29, 53, 85, recovery_wrap_len - 1 };
    for (offsets_to_tamper) |idx| {
        var tampered = wrapped;
        tampered[idx] ^= 0x80;
        try std.testing.expect(if (unwrapWithRecovery(allocator, &tampered, phrase_a)) |_| false else |_| true);
    }
}
