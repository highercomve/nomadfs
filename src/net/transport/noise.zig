const std = @import("std");
const builtin = @import("builtin");
const network = @import("interface.zig");
const compat = @import("../compat.zig");
const device_auth = @import("../../device/auth.zig");
const identity_mod = @import("../../device/identity.zig");
const NodeID = @import("../id.zig").NodeID;

const Hash = std.crypto.hash.blake2.Blake2s256;
const Hmac = std.crypto.auth.hmac.Hmac(Hash);
const Hkdf = std.crypto.kdf.hkdf.Hkdf(Hmac);
const Aead = std.crypto.aead.chacha_poly.ChaCha20Poly1305;
const X25519 = std.crypto.dh.X25519;

pub const prologue_v2 = "nomadfs-noise-v2";

pub const KeyPair = struct {
    public_key: [32]u8,
    private_key: [32]u8,

    /// Legacy node.key layout: public key followed by private key, 32 bytes each.
    pub fn encode(self: KeyPair) [64]u8 {
        return self.public_key ++ self.private_key;
    }

    pub fn decode(bytes: [64]u8) KeyPair {
        return .{ .public_key = bytes[0..32].*, .private_key = bytes[32..64].* };
    }

    pub fn generate() KeyPair {
        const io = std.Io.Threaded.global_single_threaded.io();
        var kp = X25519.KeyPair.generate(io);
        defer std.crypto.secureZero(u8, &kp.secret_key);
        return .{
            .public_key = kp.public_key,
            .private_key = kp.secret_key,
        };
    }

    /// Loads and validates a key file. error.FileNotFound means there is no
    /// key yet; any other error means an existing key is unusable and must
    /// not be silently replaced.
    pub fn loadFromFile(path: []const u8) !KeyPair {
        const io = std.Io.Threaded.global_single_threaded.io();
        var file = try std.Io.Dir.cwd().openFile(io, path, .{});
        defer file.close(io);

        if ((try file.stat(io)).size != 64) return error.InvalidKeyFile;
        var bytes: [64]u8 = undefined;
        defer std.crypto.secureZero(u8, &bytes);
        const bytes_read = try file.readPositionalAll(io, &bytes, 0);
        if (bytes_read != 64) return error.InvalidKeyFile;
        var kp = decode(bytes);
        errdefer std.crypto.secureZero(u8, &kp.private_key);

        const derived = X25519.recoverPublicKey(kp.private_key) catch return error.InvalidKeyFile;
        if (!std.mem.eql(u8, &derived, &kp.public_key)) return error.InvalidKeyFile;
        return kp;
    }

    /// Owner-only: the file holds the node's private key.
    const key_file_permissions: std.Io.File.Permissions =
        if (builtin.os.tag == .windows) .default_file else @enumFromInt(0o600);

    /// Writes a new key file. Never overwrites an existing one.
    pub fn saveToFile(self: KeyPair, path: []const u8) !void {
        const io = std.Io.Threaded.global_single_threaded.io();
        var file = try std.Io.Dir.cwd().createFile(io, path, .{
            .exclusive = true,
            .permissions = key_file_permissions,
        });
        defer file.close(io);

        var bytes = self.encode();
        defer std.crypto.secureZero(u8, &bytes);
        try file.writePositionalAll(io, &bytes, 0);
    }
};

pub const CipherState = struct {
    k: [32]u8,
    n: u64,
    has_key: bool,

    pub fn init() CipherState {
        return .{
            .k = [_]u8{0} ** 32,
            .n = 0,
            .has_key = false,
        };
    }

    pub fn initializeKey(self: *CipherState, key: [32]u8) void {
        self.k = key;
        self.n = 0;
        self.has_key = true;
    }

    pub fn encryptWithAd(self: *CipherState, ad: []const u8, plaintext: []const u8, out: []u8) !void {
        if (!self.has_key) {
            return error.EncryptionNotReady;
        }

        if (self.n == std.math.maxInt(u64)) return error.NonceExhausted;
        var nonce = [_]u8{0} ** 12;
        std.mem.writeInt(u64, nonce[4..12], self.n, .little);

        var tag: [16]u8 = undefined;
        Aead.encrypt(out[0..plaintext.len], &tag, plaintext, ad, nonce, self.k);
        @memcpy(out[plaintext.len..][0..16], &tag);

        self.n += 1;
    }

    pub fn decryptWithAd(self: *CipherState, ad: []const u8, ciphertext: []const u8, out: []u8) !void {
        if (!self.has_key) {
            return error.EncryptionNotReady;
        }

        if (ciphertext.len < 16) return error.DecryptionFailed;
        const msg_len = ciphertext.len - 16;

        if (self.n == std.math.maxInt(u64)) return error.NonceExhausted;
        var nonce = [_]u8{0} ** 12;
        std.mem.writeInt(u64, nonce[4..12], self.n, .little);

        var tag: [16]u8 = undefined;
        @memcpy(&tag, ciphertext[msg_len..]);

        try Aead.decrypt(out[0..msg_len], ciphertext[0..msg_len], tag, ad, nonce, self.k);

        self.n += 1;
    }
};

pub const SymmetricState = struct {
    cipher_state: CipherState,
    ck: [32]u8,
    h: [32]u8,

    pub fn init(protocol_name: []const u8) SymmetricState {
        var h: [32]u8 = undefined;
        if (protocol_name.len <= 32) {
            @memset(&h, 0);
            @memcpy(h[0..protocol_name.len], protocol_name);
        } else {
            Hash.hash(protocol_name, &h, .{});
        }

        return .{
            .cipher_state = CipherState.init(),
            .ck = h,
            .h = h,
        };
    }

    pub fn mixKey(self: *SymmetricState, ikm: []const u8) void {
        var output: [64]u8 = undefined;
        defer std.crypto.secureZero(u8, &output);
        var prk = Hkdf.extract(&self.ck, ikm);
        defer std.crypto.secureZero(u8, &prk);
        Hkdf.expand(&output, &[_]u8{}, prk);

        self.ck = output[0..32].*;
        self.cipher_state.initializeKey(output[32..64].*);
    }

    pub fn mixHash(self: *SymmetricState, data: []const u8) void {
        var hasher = Hash.init(.{});
        hasher.update(&self.h);
        hasher.update(data);
        hasher.final(&self.h);
    }

    pub fn mixKeyAndHash(self: *SymmetricState, psk: []const u8) void {
        var output: [96]u8 = undefined;
        defer std.crypto.secureZero(u8, &output);
        var prk = Hkdf.extract(&self.ck, psk);
        defer std.crypto.secureZero(u8, &prk);
        Hkdf.expand(&output, &[_]u8{}, prk);

        self.ck = output[0..32].*;
        self.mixHash(output[32..64][0..32]);
        self.cipher_state.initializeKey(output[64..96].*);
    }

    pub fn encryptAndHash(self: *SymmetricState, plaintext: []const u8, out: []u8) !void {
        if (self.cipher_state.has_key) {
            try self.cipher_state.encryptWithAd(&self.h, plaintext, out);
        } else {
            @memcpy(out[0..plaintext.len], plaintext);
        }
        const ct_len = if (self.cipher_state.has_key) plaintext.len + 16 else plaintext.len;
        self.mixHash(out[0..ct_len]);
    }

    pub fn decryptAndHash(self: *SymmetricState, ciphertext: []const u8, out: []u8) !void {
        if (self.cipher_state.has_key) {
            try self.cipher_state.decryptWithAd(&self.h, ciphertext, out);
        } else {
            @memcpy(out[0..ciphertext.len], ciphertext);
        }
        self.mixHash(ciphertext);
    }

    pub fn split(self: *SymmetricState) [2]CipherState {
        var output: [64]u8 = undefined;
        defer std.crypto.secureZero(u8, &output);
        var prk = Hkdf.extract(&self.ck, &[_]u8{});
        defer std.crypto.secureZero(u8, &prk);
        Hkdf.expand(&output, &[_]u8{}, prk);

        var c1 = CipherState.init();
        c1.initializeKey(output[0..32].*);
        var c2 = CipherState.init();
        c2.initializeKey(output[32..64].*);

        return .{ c1, c2 };
    }
};

pub const HandshakeState = struct {
    symmetric: SymmetricState,
    s: KeyPair, // Local static key pair
    e: ?KeyPair, // Local ephemeral key pair (generated during handshake)
    rs: ?[32]u8, // Remote party's static public key (received during handshake)
    re: ?[32]u8, // Remote party's ephemeral public key (received during handshake)
    psk: [32]u8, // Pre-shared key
    initiator: bool,
    auth: *const device_auth.Authenticator,
    remote_device_id: ?NodeID = null,

    fixed_e: ?KeyPair = null, // Deterministic test input; production generates a fresh key.

    pub fn init(initiator: bool, static_key: KeyPair, swarm_key: [32]u8, auth: *const device_auth.Authenticator) HandshakeState {
        var symmetric = SymmetricState.init("Noise_XXpsk3_25519_ChaChaPoly_BLAKE2s");
        symmetric.mixHash(prologue_v2);
        return .{
            .symmetric = symmetric,
            .s = static_key,
            .e = null,
            .rs = null,
            .re = null,
            .psk = swarm_key,
            .initiator = initiator,
            .auth = auth,
        };
    }
};

pub const NoiseStream = struct {
    inner: network.Stream,
    send_cipher: CipherState,
    recv_cipher: CipherState,
    handshake_hash: [32]u8,
    remote_static: [32]u8,
    remote_device_id: NodeID,
    read_buffer: []u8,
    read_pos: usize = 0,
    read_end: usize = 0,
    /// One outgoing packet: the length prefix and the ciphertext, sent in a
    /// single write. Writers are serialized by the Yamux session.
    write_buffer: []u8,
    allocator: std.mem.Allocator,

    /// Largest plaintext in one transport message: Noise caps a message at
    /// 65535 bytes, the AEAD tag takes 16.
    pub const max_payload = 65535 - 16;

    pub fn handshake(
        allocator: std.mem.Allocator,
        inner: network.Stream,
        swarm_key_bytes: []const u8,
        static_key: KeyPair,
        initiator: bool,
        auth: ?*const device_auth.Authenticator,
    ) !NoiseStream {
        if (swarm_key_bytes.len != 32) return error.InvalidSwarmKey;
        var swarm_key: [32]u8 = undefined;
        defer std.crypto.secureZero(u8, &swarm_key);
        @memcpy(&swarm_key, swarm_key_bytes);

        // Callers that have no device identity yet (tests, embedded use) still
        // take part in the identity exchange with an in-memory key.
        var fallback_auth: device_auth.Authenticator = undefined;
        const auth_ptr = auth orelse blk: {
            fallback_auth = .{ .identity = identity_mod.Identity.generate() };
            break :blk &fallback_auth;
        };

        var hs = HandshakeState.init(initiator, static_key, swarm_key, auth_ptr);

        defer std.crypto.secureZero(u8, std.mem.asBytes(&hs));
        defer std.crypto.secureZero(u8, std.mem.asBytes(&fallback_auth));
        return runHandshakeSteps(allocator, inner, &hs, initiator);
    }

    fn runHandshakeSteps(allocator: std.mem.Allocator, inner: network.Stream, hs: *HandshakeState, initiator: bool) !NoiseStream {
        if (initiator) {
            try writeMessage1(inner, hs);
            try readMessage2(inner, hs);
            try writeMessage3(inner, hs);
        } else {
            try readMessage1(inner, hs);
            try writeMessage2(inner, hs);
            try readMessage3(inner, hs);
        }

        var ciphers = hs.symmetric.split();
        defer std.crypto.secureZero(u8, std.mem.asBytes(&ciphers));
        const read_buf = try allocator.alloc(u8, 65535 + 16);
        errdefer allocator.free(read_buf);
        const write_buf = try allocator.alloc(u8, 2 + 65535);
        errdefer allocator.free(write_buf);

        return NoiseStream{
            .inner = inner,
            .send_cipher = if (initiator) ciphers[0] else ciphers[1],
            .recv_cipher = if (initiator) ciphers[1] else ciphers[0],
            .handshake_hash = hs.symmetric.h,
            .remote_static = hs.rs.?,
            .remote_device_id = hs.remote_device_id.?,
            .read_buffer = read_buf,
            .read_pos = 0,
            .read_end = 0,
            .write_buffer = write_buf,
            .allocator = allocator,
        };
    }

    fn mixE(hs: *HandshakeState, public_key: []const u8) void {
        hs.symmetric.mixHash(public_key);
        hs.symmetric.mixKey(public_key);
    }

    fn buildMessage1(hs: *HandshakeState, payload: []const u8, out: []u8) ![]u8 {
        hs.e = hs.fixed_e orelse KeyPair.generate();
        mixE(hs, &hs.e.?.public_key);
        @memcpy(out[0..32], &hs.e.?.public_key);
        try hs.symmetric.encryptAndHash(payload, out[32..]);
        return out[0 .. 48 + payload.len];
    }

    fn consumeMessage1(hs: *HandshakeState, msg: []const u8, payload: []u8) !void {
        if (msg.len != 48 + payload.len) return error.HandshakeFailed;
        hs.re = msg[0..32].*;
        mixE(hs, msg[0..32]);
        try hs.symmetric.decryptAndHash(msg[32..], payload);
    }

    /// Message 1: -> e, encrypted empty payload (48 bytes).
    fn writeMessage1(inner: network.Stream, hs: *HandshakeState) !void {
        var buf: [48]u8 = undefined;
        try writeHandshakeMessage(inner, try buildMessage1(hs, "", &buf));
    }

    fn readMessage1(inner: network.Stream, hs: *HandshakeState) !void {
        var buf: [48]u8 = undefined;
        try readHandshakeMessage(inner, &buf);
        try consumeMessage1(hs, &buf, &.{});
    }

    /// Message 2 (responder): <- e, ee, s, es
    fn writeMessage2(inner: network.Stream, hs: *HandshakeState) !void {
        var msg2: [32 + 48 + device_auth.hello_len + 16]u8 = undefined;
        try buildMessage2Prefix(hs, &msg2);
        const hello = try hs.auth.createHello(hs.symmetric.h);
        var payload_ct: [device_auth.hello_len + 16]u8 = undefined;
        try hs.symmetric.encryptAndHash(&hello, &payload_ct);

        @memcpy(msg2[80..], &payload_ct);
        writeHandshakeMessage(inner, &msg2) catch |err| return logError("Message 2 write", err);
    }

    fn buildMessage2Prefix(hs: *HandshakeState, out: []u8) !void {
        hs.e = hs.fixed_e orelse KeyPair.generate();
        mixE(hs, &hs.e.?.public_key);

        // ee
        var ee = X25519.scalarmult(hs.e.?.private_key, hs.re.?) catch |err| return logError("Message 2 DH (ee)", err);
        defer std.crypto.secureZero(u8, &ee);
        hs.symmetric.mixKey(&ee);

        // s
        try hs.symmetric.encryptAndHash(&hs.s.public_key, out[32..80]);

        // es
        var es = X25519.scalarmult(hs.s.private_key, hs.re.?) catch |err| return logError("Message 2 DH (es)", err);
        defer std.crypto.secureZero(u8, &es);
        hs.symmetric.mixKey(&es);

        @memcpy(out[0..32], &hs.e.?.public_key);
    }

    /// Message 2 (initiator): <- e, ee, s, es
    fn readMessage2(inner: network.Stream, hs: *HandshakeState) !void {
        var buf: [32 + 48 + device_auth.hello_len + 16]u8 = undefined; // re, rs (encrypted), device hello
        readHandshakeMessage(inner, &buf) catch |err| return logError("Message 2 read", err);

        try consumeMessage2Prefix(hs, &buf);

        // Device identity, signed over the handshake hash that also
        // authenticates this payload.
        try readDeviceHello(hs, buf[80..], "Message 2 Decrypt (device hello)", "Message 2 device identity");
    }

    /// Decrypts the device hello that ends message 2 or 3 and verifies it
    /// against the handshake hash up to the hello.
    fn readDeviceHello(hs: *HandshakeState, ciphertext: []const u8, decrypt_step: []const u8, identity_step: []const u8) !void {
        const transcript = hs.symmetric.h;
        var hello: [device_auth.hello_len]u8 = undefined;
        hs.symmetric.decryptAndHash(ciphertext, &hello) catch |err| return logError(decrypt_step, err);
        hs.remote_device_id = hs.auth.verifyHello(&hello, transcript, hs.rs.?) catch |err| return logError(identity_step, err);
    }

    fn consumeMessage2Prefix(hs: *HandshakeState, buf: []const u8) !void {
        // e
        hs.re = buf[0..32].*;
        mixE(hs, buf[0..32]);

        // ee
        var ee = X25519.scalarmult(hs.e.?.private_key, hs.re.?) catch |err| return logError("Message 2 DH (ee)", err);
        defer std.crypto.secureZero(u8, &ee);
        hs.symmetric.mixKey(&ee);

        // s
        var rs: [32]u8 = undefined;
        hs.symmetric.decryptAndHash(buf[32..80], &rs) catch |err| return logError("Message 2 Decrypt (s)", err);
        hs.rs = rs;

        // es
        var es = X25519.scalarmult(hs.e.?.private_key, hs.rs.?) catch |err| return logError("Message 2 DH (es)", err);
        defer std.crypto.secureZero(u8, &es);
        hs.symmetric.mixKey(&es);
    }

    /// Message 3 (initiator): -> s, se, psk
    fn writeMessage3(inner: network.Stream, hs: *HandshakeState) !void {
        var msg3: [48 + device_auth.hello_len + 16]u8 = undefined;
        try buildMessage3Prefix(hs, &msg3);

        // Payload: device identity, signed over the psk-mixed handshake hash.
        const hello = try hs.auth.createHello(hs.symmetric.h);
        var payload_ct: [device_auth.hello_len + 16]u8 = undefined;
        try hs.symmetric.encryptAndHash(&hello, &payload_ct);

        @memcpy(msg3[48..], &payload_ct);
        writeHandshakeMessage(inner, &msg3) catch |err| return logError("Message 3 write", err);
    }

    fn buildMessage3Prefix(hs: *HandshakeState, out: []u8) !void {
        // s
        try hs.symmetric.encryptAndHash(&hs.s.public_key, out[0..48]);

        // se
        var se = X25519.scalarmult(hs.s.private_key, hs.re.?) catch |err| return logError("Message 3 DH (se)", err);
        defer std.crypto.secureZero(u8, &se);
        hs.symmetric.mixKey(&se);

        // psk
        hs.symmetric.mixKeyAndHash(&hs.psk);
    }

    /// Message 3 (responder): -> s, se, psk
    fn readMessage3(inner: network.Stream, hs: *HandshakeState) !void {
        var buf: [48 + device_auth.hello_len + 16]u8 = undefined;
        readHandshakeMessage(inner, &buf) catch |err| return logError("Message 3 read", err);

        try consumeMessage3Prefix(hs, &buf);

        // payload: device identity (also verifies the PSK-derived key)
        try readDeviceHello(hs, buf[48..], "Message 3 Decrypt (payload/psk verify)", "Message 3 device identity");
    }

    fn consumeMessage3Prefix(hs: *HandshakeState, buf: []const u8) !void {
        // s
        var rs: [32]u8 = undefined;
        hs.symmetric.decryptAndHash(buf[0..48], &rs) catch |err| return logError("Message 3 Decrypt (s)", err);
        hs.rs = rs;

        // se
        var se = X25519.scalarmult(hs.e.?.private_key, hs.rs.?) catch |err| return logError("Message 3 DH (se)", err);
        defer std.crypto.secureZero(u8, &se);
        hs.symmetric.mixKey(&se);

        // psk
        hs.symmetric.mixKeyAndHash(&hs.psk);
    }

    fn logError(step: []const u8, err: anyerror) anyerror {
        _ = step;

        return err;
    }

    fn writeHandshakeMessage(inner: network.Stream, msg: []const u8) !void {
        var len_buf: [2]u8 = undefined;
        std.mem.writeInt(u16, &len_buf, @intCast(msg.len), .big);
        try compat.writeFull(inner, &len_buf);
        try compat.writeFull(inner, msg);
    }

    fn readHandshakeMessage(inner: network.Stream, out: []u8) !void {
        var len_buf: [2]u8 = undefined;
        try compat.readFull(inner, &len_buf);
        const len = std.mem.readInt(u16, &len_buf, .big);
        if (len != out.len) return error.HandshakeFailed;
        try compat.readFull(inner, out);
    }

    pub fn stream(self: *NoiseStream) network.Stream {
        return network.Stream.init(self, &noise_stream_vtable);
    }

    fn read(ptr: *anyopaque, buffer: []u8) anyerror!usize {
        const self: *NoiseStream = @ptrCast(@alignCast(ptr));

        // If we have buffered data, use it first
        if (self.read_pos < self.read_end) {
            const available = self.read_end - self.read_pos;
            const to_copy = @min(buffer.len, available);
            @memcpy(buffer[0..to_copy], self.read_buffer[self.read_pos .. self.read_pos + to_copy]);
            self.read_pos += to_copy;
            return to_copy;
        }

        // Buffer is empty, read next packet
        var len_buf: [2]u8 = undefined;
        try compat.readFull(self.inner, &len_buf);
        const len = std.mem.readInt(u16, &len_buf, .big);

        if (len < 16) return error.PacketTooSmall;
        const msg_len = len - 16;

        if (len > self.read_buffer.len) return error.PacketTooLarge;

        try compat.readFull(self.inner, self.read_buffer[0..len]);

        try self.recv_cipher.decryptWithAd(&[_]u8{}, self.read_buffer[0..len], self.read_buffer[0..msg_len]);

        self.read_pos = 0;
        self.read_end = msg_len;

        // Now copy to user buffer
        const to_copy = @min(buffer.len, msg_len);
        @memcpy(buffer[0..to_copy], self.read_buffer[0..to_copy]);
        self.read_pos += to_copy;

        return to_copy;
    }

    fn write(ptr: *anyopaque, buffer: []const u8) anyerror!usize {
        const self: *NoiseStream = @ptrCast(@alignCast(ptr));

        var i: usize = 0;
        while (i < buffer.len) {
            // usize: @min with the constant would narrow it to u16.
            const chunk_len: usize = @min(buffer.len - i, max_payload);
            const packet_len: usize = chunk_len + 16;
            const packet = self.write_buffer[0 .. 2 + packet_len];
            std.mem.writeInt(u16, packet[0..2], @intCast(packet_len), .big);
            try self.send_cipher.encryptWithAd(&[_]u8{}, buffer[i .. i + chunk_len], packet[2..]);
            try compat.writeFull(self.inner, packet);
            i += chunk_len;
        }

        return buffer.len;
    }

    pub fn deinit(self: *NoiseStream) void {
        self.close();
        std.crypto.secureZero(u8, &self.send_cipher.k);
        std.crypto.secureZero(u8, &self.recv_cipher.k);
        std.crypto.secureZero(u8, self.read_buffer);
        std.crypto.secureZero(u8, self.write_buffer);
        self.allocator.free(self.read_buffer);
        self.allocator.free(self.write_buffer);
    }

    pub fn close(self: *NoiseStream) void {
        self.inner.close();
    }

    fn closeVProxy(ptr: *anyopaque) void {
        const self: *NoiseStream = @ptrCast(@alignCast(ptr));
        self.close();
    }
};

const noise_stream_vtable = network.Stream.StreamVTable{
    .read = NoiseStream.read,
    .write = NoiseStream.write,
    .close = NoiseStream.closeVProxy,
};

test "KeyPair files are private and never silently replaced" {
    const io = std.Io.Threaded.global_single_threaded.io();
    const path = "test_noise_keypair.key";
    std.Io.Dir.cwd().deleteFile(io, path) catch {};
    defer std.Io.Dir.cwd().deleteFile(io, path) catch {};

    const kp = KeyPair.generate();
    try kp.saveToFile(path);
    const loaded = try KeyPair.loadFromFile(path);
    try std.testing.expectEqualSlices(u8, &kp.private_key, &loaded.private_key);

    if (builtin.os.tag != .windows) {
        var file = try std.Io.Dir.cwd().openFile(io, path, .{});
        defer file.close(io);
        const mode = @intFromEnum((try file.stat(io)).permissions);
        try std.testing.expectEqual(@as(@TypeOf(mode), 0), mode & 0o077);
    }

    // Saving again must not clobber the existing identity.
    try std.testing.expectError(error.PathAlreadyExists, KeyPair.generate().saveToFile(path));

    // A truncated file is rejected rather than treated as missing.
    std.Io.Dir.cwd().deleteFile(io, path) catch {};
    {
        var file = try std.Io.Dir.cwd().createFile(io, path, .{});
        defer file.close(io);
        try file.writePositionalAll(io, "short", 0);
    }
    try std.testing.expectError(error.InvalidKeyFile, KeyPair.loadFromFile(path));
}

test "KeyPair explicit encoding preserves legacy byte order" {
    const bytes = [_]u8{0x12} ** 32 ++ [_]u8{0x34} ** 32;
    const kp = KeyPair.decode(bytes);
    try std.testing.expectEqualSlices(u8, bytes[0..32], &kp.public_key);
    try std.testing.expectEqualSlices(u8, bytes[32..64], &kp.private_key);
    try std.testing.expectEqualSlices(u8, &bytes, &kp.encode());
    // This assertion guards compatibility with files written by the old struct dump.
    try std.testing.expectEqualSlices(u8, &bytes, std.mem.asBytes(&kp));
}

test "Noise refuses reserved exhausted nonce" {
    var cipher = CipherState.init();
    cipher.initializeKey(.{0} ** 32);
    cipher.n = std.math.maxInt(u64);
    var out: [16]u8 = undefined;
    try std.testing.expectError(error.NonceExhausted, cipher.encryptWithAd("", "", &out));
    try std.testing.expectError(error.NonceExhausted, cipher.decryptWithAd("", &out, &.{}));
}

fn testHex(comptime hex: []const u8) [hex.len / 2]u8 {
    var bytes: [hex.len / 2]u8 = undefined;
    _ = std.fmt.hexToBytes(&bytes, hex) catch unreachable;
    return bytes;
}

fn testKey(comptime hex: []const u8) !KeyPair {
    const secret = testHex(hex);
    return .{ .private_key = secret, .public_key = try X25519.recoverPublicKey(secret) };
}

test "noise v2: cacophony XXpsk3 vector" {
    // https://github.com/mcginty/snow/blob/main/tests/vectors/cacophony.txt
    const auth: device_auth.Authenticator = .{
        .identity = try identity_mod.Identity.fromSeed(.{0x31} ** 32),
    };
    const psk = testHex("54686973206973206d7920417573747269616e20706572737065637469766521");
    var initiator = HandshakeState.init(true, try testKey("e61ef9919cde45dd5f82166404bd08e38bceb5dfdfded0a34c8df7ed542214d1"), psk, &auth);
    var responder = HandshakeState.init(false, try testKey("4a3acbfdb163dec651dfa3194dece676d437029c62a408b4c5ea9114246e4893"), psk, &auth);
    initiator.fixed_e = try testKey("893e28b9dc6ca8d611ab664754b8ceb7bac5117349a4439a6b0569da977c464a");
    responder.fixed_e = try testKey("bbdb4cdbd309f1a1f2e1456967fe288cadd6f712d65dc7b7793d5e63da6b375b");
    // Replace the application's prologue with the published vector's prologue.
    initiator.symmetric = SymmetricState.init("Noise_XXpsk3_25519_ChaChaPoly_BLAKE2s");
    initiator.symmetric.mixHash("John Galt");
    responder.symmetric = initiator.symmetric;
    const payloads = .{ "Ludwig von Mises", "Murray Rothbard", "F. A. Hayek" };
    const expected = .{
        testHex("ca35def5ae56cec33dc2036731ab14896bc4c75dbb07a61f879f8e3afa4c7944325ea71699951ece20f284b6ad9604a029eb335bf84564c308b6ade90ae45078"),
        testHex("95ebc60d2b1fa672c1f46a8aa265ef51bfe38e7ccb39ec5be34069f1448088432645535233ffe1432564d66a85227b677ced6fc2730ae0998ff49aa1dc56b8186e31b16e416f5d9c03c71f6c34fd37ec013105020070a8b00c000ce7ed56629c119795f96463274bc05519d5c24dc1"),
        testHex("adf16c5375ec4172576783fd59f2bfa5c7a320d0a13b759592e1a2ddf5524cce59ccbb92ff5d321fced3bdb2840596df562c0e68aad41b090abd285f6d300130072e06964a6ba494e58d47"),
    };
    var out: [256]u8 = undefined;
    var plain: [32]u8 = undefined;
    const first = try NoiseStream.buildMessage1(&initiator, payloads[0], &out);
    try std.testing.expectEqualSlices(u8, &expected[0], first);
    try NoiseStream.consumeMessage1(&responder, first, plain[0..payloads[0].len]);
    try std.testing.expectEqualStrings(payloads[0], plain[0..payloads[0].len]);
    try NoiseStream.buildMessage2Prefix(&responder, &out);
    try responder.symmetric.encryptAndHash(payloads[1], out[80..]);
    try std.testing.expectEqualSlices(u8, &expected[1], out[0..expected[1].len]);
    try NoiseStream.consumeMessage2Prefix(&initiator, &out);
    try initiator.symmetric.decryptAndHash(out[80..expected[1].len], plain[0..payloads[1].len]);
    try std.testing.expectEqualStrings(payloads[1], plain[0..payloads[1].len]);
    try NoiseStream.buildMessage3Prefix(&initiator, &out);
    try initiator.symmetric.encryptAndHash(payloads[2], out[48..]);
    try std.testing.expectEqualSlices(u8, &expected[2], out[0..expected[2].len]);
    try NoiseStream.consumeMessage3Prefix(&responder, &out);
    try responder.symmetric.decryptAndHash(out[48..expected[2].len], plain[0..payloads[2].len]);
    try std.testing.expectEqualStrings(payloads[2], plain[0..payloads[2].len]);
    const hash = testHex("fc0819f08aebc23de9a783653d8d7d6395b7d243d9deec12f5d6fe2f4c206673");
    try std.testing.expectEqualSlices(u8, &hash, &initiator.symmetric.h);
    try std.testing.expectEqualSlices(u8, &hash, &responder.symmetric.h);
    var i_ciphers = initiator.symmetric.split();
    var r_ciphers = responder.symmetric.split();
    const transport = testHex("dcdc045c8e9ec36c8ea4078552e5849f87cb9bdfbd2a4eee3baaf6");
    // The responder sends the first transport message using Split's second key.
    try r_ciphers[1].encryptWithAd("", "Carl Menger", &out);
    try std.testing.expectEqualSlices(u8, &transport, out[0..transport.len]);
    try i_ciphers[1].decryptWithAd("", &transport, plain[0..11]);
    try std.testing.expectEqualStrings("Carl Menger", plain[0..11]);
}

test "noise v2: message 1 rejects legacy lengths and tampered tags" {
    const auth: device_auth.Authenticator = .{
        .identity = try identity_mod.Identity.fromSeed(.{0x32} ** 32),
    };
    var initiator = HandshakeState.init(true, KeyPair.generate(), .{0} ** 32, &auth);
    var responder = HandshakeState.init(false, KeyPair.generate(), .{0} ** 32, &auth);
    var buf: [48]u8 = undefined;
    _ = try NoiseStream.buildMessage1(&initiator, "", &buf);
    try std.testing.expectError(error.HandshakeFailed, NoiseStream.consumeMessage1(&responder, buf[0..32], &.{}));
    try std.testing.expectError(error.HandshakeFailed, NoiseStream.consumeMessage1(&responder, buf[0..47], &.{}));
    buf[47] ^= 1;
    try std.testing.expectError(error.AuthenticationFailed, NoiseStream.consumeMessage1(&responder, &buf, &.{}));
}

test "noise symmetric state passes through unkeyed payloads" {
    var sender = SymmetricState.init("test");
    var receiver = sender;
    var out: [5]u8 = undefined;
    var plain: [5]u8 = undefined;
    try sender.encryptAndHash("hello", &out);
    try receiver.decryptAndHash(&out, &plain);
    try std.testing.expectEqualStrings("hello", &plain);
    try std.testing.expectEqualSlices(u8, &sender.h, &receiver.h);
}

test "noise v2: replayed first message cannot reuse an old session" {
    const auth: device_auth.Authenticator = .{
        .identity = try identity_mod.Identity.fromSeed(.{0x33} ** 32),
    };
    var initiator = HandshakeState.init(true, KeyPair.generate(), .{0x41} ** 32, &auth);
    var responder = HandshakeState.init(false, KeyPair.generate(), .{0x41} ** 32, &auth);
    var replay_target = responder;
    var first: [48]u8 = undefined;
    _ = try NoiseStream.buildMessage1(&initiator, "", &first);
    try NoiseStream.consumeMessage1(&responder, &first, &.{});
    try NoiseStream.consumeMessage1(&replay_target, &first, &.{});
    var second: [96]u8 = undefined;
    try NoiseStream.buildMessage2Prefix(&responder, &second);
    try responder.symmetric.encryptAndHash("", second[80..]);
    try NoiseStream.consumeMessage2Prefix(&initiator, &second);
    try initiator.symmetric.decryptAndHash(second[80..], &.{});
    var third: [64]u8 = undefined;
    try NoiseStream.buildMessage3Prefix(&initiator, &third);
    try initiator.symmetric.encryptAndHash("", third[48..]);
    try NoiseStream.consumeMessage3Prefix(&responder, &third);
    try responder.symmetric.decryptAndHash(third[48..], &.{});
    // A fresh responder uses its own ephemeral even when message 1 is replayed.
    try NoiseStream.buildMessage2Prefix(&replay_target, &second);
    try replay_target.symmetric.encryptAndHash("", second[80..]);
    try std.testing.expectError(error.AuthenticationFailed, NoiseStream.consumeMessage3Prefix(&replay_target, &third));
}
