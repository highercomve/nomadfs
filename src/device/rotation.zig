//! Swarm key rotation. When the swarm key may have leaked, one device
//! generates a new key and hands it to every *paired* device it can reach,
//! inside the encrypted channel, signed with its device identity:
//!
//!   signed = "nomadfs-rotate-v1:" ++ epoch (u64, big-endian) ++ new_key
//!
//! A receiver accepts only when the signer is in its own trust store, the
//! signer is the device on the other end of this connection (checked in the
//! handshake), and the epoch is newer than its own, so an old rotation can't
//! be replayed. Devices that only knew the old key (never paired) do not get
//! the new one: that is the point of rotating.

const std = @import("std");
const NodeID = @import("../net/id.zig").NodeID;
const identity_mod = @import("identity.zig");
const trust_mod = @import("trust.zig");

pub const domain = "nomadfs-rotate-v1:";
pub const message_len = domain.len + 8 + 32;

pub fn message(epoch: u64, new_key: [32]u8) [message_len]u8 {
    var out: [message_len]u8 = undefined;
    @memcpy(out[0..domain.len], domain);
    std.mem.writeInt(u64, out[domain.len..][0..8], epoch, .big);
    @memcpy(out[domain.len + 8 ..], &new_key);
    return out;
}

pub const Rejection = error{ UntrustedSigner, SignerNotPeer, BadSignature, StaleEpoch };

/// Checks a received rotation. `peer_device` is the identity the handshake
/// proved for this connection; `current_epoch` is the receiver's own.
pub fn verify(
    trust: *trust_mod.Store,
    peer_device: ?NodeID,
    signer_key: [32]u8,
    signature: [64]u8,
    epoch: u64,
    new_key: [32]u8,
    current_epoch: u64,
) Rejection!void {
    const signer = NodeID.fromPublicKey(signer_key);
    if (!trust.isTrusted(signer)) return error.UntrustedSigner;
    const peer = peer_device orelse return error.SignerNotPeer;
    if (!peer.eql(signer)) return error.SignerNotPeer;
    const msg = message(epoch, new_key);
    identity_mod.Identity.verify(signer_key, &msg, signature) catch return error.BadSignature;
    if (epoch <= current_epoch) return error.StaleEpoch;
}

test "rotation: only a trusted signer on its own connection, with a newer epoch" {
    const allocator = std.testing.allocator;
    const alice = try identity_mod.Identity.fromSeed([_]u8{1} ** identity_mod.seed_len);
    const mallory = try identity_mod.Identity.fromSeed([_]u8{2} ** identity_mod.seed_len);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const base = path_buf[0..try tmp.dir.realPath(std.testing.io, &path_buf)];
    const trust_path = try std.fs.path.join(allocator, &.{ base, "trust" });
    defer allocator.free(trust_path);
    const me = try identity_mod.Identity.fromSeed([_]u8{3} ** identity_mod.seed_len);
    var store = try trust_mod.Store.load(allocator, trust_path, me.seed());
    defer store.deinit();
    _ = try store.upsert(alice.publicKey(), [_]u8{9} ** 32, "Alice", 1);

    const key = [_]u8{0x42} ** 32;
    const sig = try alice.sign(&message(5, key));
    try verify(&store, alice.deviceId(), alice.publicKey(), sig, 5, key, 4);
    try std.testing.expectError(error.StaleEpoch, verify(&store, alice.deviceId(), alice.publicKey(), sig, 5, key, 5));
    try std.testing.expectError(error.BadSignature, verify(&store, alice.deviceId(), alice.publicKey(), sig, 6, key, 4));
    // Relayed by another connection: refused.
    try std.testing.expectError(error.SignerNotPeer, verify(&store, mallory.deviceId(), alice.publicKey(), sig, 5, key, 4));
    // A signer this device never paired with: refused.
    const msig = try mallory.sign(&message(9, key));
    try std.testing.expectError(error.UntrustedSigner, verify(&store, mallory.deviceId(), mallory.publicKey(), msig, 9, key, 4));
}
