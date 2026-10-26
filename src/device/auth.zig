//! Binds a Noise session to a device identity.
//!
//! Both sides send `version || Ed25519 public key || signature` inside an
//! encrypted Noise handshake payload. The signature covers a domain separator
//! and the handshake hash at the point the payload is encrypted, so it is
//! bound to the ephemeral keys, the static keys, the PSK and the messages
//! exchanged so far. A captured hello cannot be replayed into another session.
//!
//! Verification always happens; requiring the peer to be present in the trust
//! store is an explicit policy (`require_trusted`), because a fresh install has
//! an empty store and must still be able to pair.

const std = @import("std");
const identity_mod = @import("identity.zig");
const trust_mod = @import("trust.zig");
const NodeID = @import("../net/id.zig").NodeID;

pub const version: u8 = 1;
pub const domain = "nomadfs-device-auth-v1";
pub const hello_len = 1 + 32 + 64;

pub const Error = error{
    InvalidDeviceHello,
    UntrustedDevice,
};

pub const Authenticator = struct {
    identity: identity_mod.Identity,
    /// Read-only view of the trust store for the lifetime of a connection.
    trust: ?*trust_mod.Store = null,
    /// When true, unknown device identities are rejected outright.
    require_trusted: bool = false,

    /// Builds the hello payload for the current handshake hash.
    pub fn createHello(self: *const Authenticator, transcript: [32]u8) ![hello_len]u8 {
        var message: [domain.len + 32]u8 = undefined;
        @memcpy(message[0..domain.len], domain);
        @memcpy(message[domain.len..], &transcript);

        const signature = try self.identity.sign(&message);
        var hello: [hello_len]u8 = undefined;
        hello[0] = version;
        @memcpy(hello[1..33], &self.identity.publicKey());
        @memcpy(hello[33..], &signature);
        return hello;
    }

    /// Verifies the peer's hello and returns its device ID. The transcript must
    /// be the handshake hash captured before the payload was decrypted, i.e.
    /// the AD that authenticated it.
    pub fn verifyHello(self: *const Authenticator, hello: []const u8, transcript: [32]u8) !NodeID {
        if (hello.len != hello_len or hello[0] != version) return Error.InvalidDeviceHello;

        var public_key: [32]u8 = undefined;
        @memcpy(&public_key, hello[1..33]);
        var signature: [64]u8 = undefined;
        @memcpy(&signature, hello[33..]);

        var message: [domain.len + 32]u8 = undefined;
        @memcpy(message[0..domain.len], domain);
        @memcpy(message[domain.len..], &transcript);
        try identity_mod.Identity.verify(public_key, &message, signature);

        const device_id = NodeID.fromPublicKey(public_key);
        if (self.require_trusted) {
            const store = self.trust orelse return Error.UntrustedDevice;
            if (!store.isTrusted(device_id)) return Error.UntrustedDevice;
        }
        return device_id;
    }
};

const testing = std.testing;

fn identityWith(seed_byte: u8) !identity_mod.Identity {
    return identity_mod.Identity.fromSeed([_]u8{seed_byte} ** identity_mod.seed_len);
}

test "device auth: hello round-trips and identifies the sender" {
    const local = try identityWith(0x61);
    const remote = try identityWith(0x62);

    const local_auth: Authenticator = .{ .identity = local };
    const remote_auth: Authenticator = .{ .identity = remote };

    const transcript = [_]u8{0x5c} ** 32;
    const hello = try local_auth.createHello(transcript);
    const peer_id = try remote_auth.verifyHello(&hello, transcript);

    try testing.expect(peer_id.eql(local.deviceId()));
    try testing.expectEqual(hello_len, hello.len);
}

test "device auth: hello is bound to the handshake transcript" {
    const local = try identityWith(0x63);
    const remote = try identityWith(0x64);
    const auth: Authenticator = .{ .identity = local };
    const verifier: Authenticator = .{ .identity = remote };

    const hello = try auth.createHello([_]u8{0x11} ** 32);
    try testing.expectError(
        error.SignatureVerificationFailed,
        verifier.verifyHello(&hello, [_]u8{0x12} ** 32),
    );
}

test "device auth: hello rejection cases" {
    const local = try identityWith(0x65);
    const remote = try identityWith(0x66);
    const auth: Authenticator = .{ .identity = local };
    const verifier: Authenticator = .{ .identity = remote };
    const transcript = [_]u8{0x33} ** 32;

    var hello = try auth.createHello(transcript);

    // Wrong version byte.
    var bad_version = hello;
    bad_version[0] = 2;
    try testing.expectError(Error.InvalidDeviceHello, verifier.verifyHello(&bad_version, transcript));

    // Truncated payload.
    try testing.expectError(Error.InvalidDeviceHello, verifier.verifyHello(hello[0 .. hello.len - 1], transcript));

    // Substituted public key can no longer match the signature.
    var swapped = hello;
    swapped[1] ^= 0x01;
    try testing.expectError(error.SignatureVerificationFailed, verifier.verifyHello(&swapped, transcript));

    // Flipped signature bit.
    hello[33] ^= 0x01;
    try testing.expectError(error.SignatureVerificationFailed, verifier.verifyHello(&hello, transcript));
}

test "device auth: trust policy rejects unknown devices" {
    const path = "test_device_auth.store";
    const io = std.Io.Threaded.global_single_threaded.io();
    std.Io.Dir.cwd().deleteFile(io, path) catch {};
    defer std.Io.Dir.cwd().deleteFile(io, path) catch {};

    var store = try trust_mod.Store.load(testing.allocator, path);
    defer store.deinit();

    const known = try identityWith(0x67);
    const unknown = try identityWith(0x68);

    const auth: Authenticator = .{
        .identity = try identityWith(0x69),
        .trust = &store,
        .require_trusted = true,
    };
    const transcript = [_]u8{0x77} ** 32;

    // Fail closed with no store attached.
    const no_store: Authenticator = .{
        .identity = auth.identity,
        .require_trusted = true,
    };
    const known_auth: Authenticator = .{ .identity = known };
    const known_hello = try known_auth.createHello(transcript);
    try testing.expectError(Error.UntrustedDevice, no_store.verifyHello(&known_hello, transcript));

    // Unknown peer is rejected while the store is empty.
    try testing.expectError(Error.UntrustedDevice, auth.verifyHello(&known_hello, transcript));

    // Trusting the device key admits it.
    const ticket = try @import("pairing.zig").Ticket.init(
        known,
        [_]u8{0x11} ** 32,
        "known",
        "192.168.1.5:4001",
        1_800_000_000,
    );
    _ = try store.trustTicket(ticket, 1);
    const peer_id = try auth.verifyHello(&known_hello, transcript);
    try testing.expect(peer_id.eql(known.deviceId()));

    // A different identity is still rejected.
    const unknown_auth: Authenticator = .{ .identity = unknown };
    const unknown_hello = try unknown_auth.createHello(transcript);
    try testing.expectError(Error.UntrustedDevice, auth.verifyHello(&unknown_hello, transcript));
}
