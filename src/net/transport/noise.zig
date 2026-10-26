const std = @import("std");
const builtin = @import("builtin");
const network = @import("mod.zig");
const device_auth = @import("../../device/auth.zig");
const identity_mod = @import("../../device/identity.zig");
const NodeID = @import("../id.zig").NodeID;

const Hash = std.crypto.hash.blake2.Blake2s256;
const Hmac = std.crypto.auth.hmac.Hmac(Hash);
const Hkdf = std.crypto.kdf.hkdf.Hkdf(Hmac);
const Aead = std.crypto.aead.chacha_poly.ChaCha20Poly1305;
const X25519 = std.crypto.dh.X25519;

pub const KeyPair = struct {
    public_key: [32]u8,
    private_key: [32]u8,

    pub fn generate() KeyPair {
        const io = std.Io.Threaded.global_single_threaded.io();
        const kp = X25519.KeyPair.generate(io);
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

        if ((try file.stat(io)).size != @sizeOf(KeyPair)) return error.InvalidKeyFile;
        var kp: KeyPair = undefined;
        const bytes_read = try file.readPositionalAll(io, std.mem.asBytes(&kp), 0);
        if (bytes_read != @sizeOf(KeyPair)) return error.InvalidKeyFile;

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

        try file.writePositionalAll(io, std.mem.asBytes(&self), 0);
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

        var nonce = [_]u8{0} ** 12;
        std.mem.writeInt(u64, nonce[4..12], self.n, .little);

        var tag: [16]u8 = undefined;
        @memcpy(&tag, ciphertext[msg_len..]);

        try Aead.decrypt(out[0..msg_len], ciphertext[0..msg_len], tag, ad, nonce, self.k);

        self.n += 1;
    }

    pub fn rekey(self: *CipherState) void {
        var out = [_]u8{0} ** 64;
        const nonce = [_]u8{0xff} ** 12; // Use max nonce for rekey
        const zeros = [_]u8{0} ** 32;
        var tag: [16]u8 = undefined;
        Aead.encrypt(out[0..32], &tag, zeros[0..], &[_]u8{}, nonce, self.k);
        // Standard Noise rekey just takes the first 32 bytes of encryption of zeros
        self.k = out[0..32].*;
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
        const prk = Hkdf.extract(&self.ck, ikm);
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
        const prk = Hkdf.extract(&self.ck, psk);
        Hkdf.expand(&output, &[_]u8{}, prk);

        self.ck = output[0..32].*;
        self.mixHash(output[32..64][0..32]);
        self.cipher_state.initializeKey(output[64..96].*);
    }

    pub fn encryptAndHash(self: *SymmetricState, plaintext: []const u8, out: []u8) !void {
        try self.cipher_state.encryptWithAd(&self.h, plaintext, out);
        const ct_len = if (self.cipher_state.has_key) plaintext.len + 16 else plaintext.len;
        self.mixHash(out[0..ct_len]);
    }

    pub fn decryptAndHash(self: *SymmetricState, ciphertext: []const u8, out: []u8) !void {
        try self.cipher_state.decryptWithAd(&self.h, ciphertext, out);
        self.mixHash(ciphertext);
    }

    pub fn split(self: *SymmetricState) [2]CipherState {
        var output: [64]u8 = undefined;
        const prk = Hkdf.extract(&self.ck, &[_]u8{});
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

    pub fn init(initiator: bool, static_key: KeyPair, swarm_key: [32]u8, auth: *const device_auth.Authenticator) HandshakeState {
        return .{
            .symmetric = SymmetricState.init("Noise_XXpsk3_25519_ChaChaPoly_BLAKE2s"),
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
    remote_static: [32]u8,
    remote_device_id: NodeID,
    read_buffer: []u8,
    read_pos: usize = 0,
    read_end: usize = 0,
    allocator: std.mem.Allocator,

    pub fn handshake(
        allocator: std.mem.Allocator,
        inner: network.Stream,
        swarm_key_bytes: []const u8,
        static_key: KeyPair,
        initiator: bool,
        auth: ?*const device_auth.Authenticator,
    ) !NoiseStream {
        const role = if (initiator) "Initiator" else "Responder";
        std.debug.print("* Noise_XXpsk3 handshake start ({s})\n", .{role});

        if (swarm_key_bytes.len != 32) return error.InvalidSwarmKey;
        var swarm_key: [32]u8 = undefined;
        @memcpy(&swarm_key, swarm_key_bytes);

        // Callers that have no device identity yet (tests, embedded use) still
        // take part in the identity exchange with an in-memory key.
        var fallback_auth: device_auth.Authenticator = undefined;
        const auth_ptr = auth orelse blk: {
            fallback_auth = .{ .identity = identity_mod.Identity.generate() };
            break :blk &fallback_auth;
        };

        var hs = HandshakeState.init(initiator, static_key, swarm_key, auth_ptr);

        const result = runHandshakeSteps(allocator, inner, &hs, initiator);
        if (result) |ns| {
            std.debug.print("* Noise Handshake complete\n", .{});
            return ns;
        } else |err| {
            std.debug.print("* Noise Handshake FAILED ({s}): {}\n", .{ role, err });
            return err;
        }
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

        const ciphers = hs.symmetric.split();
        const read_buf = try allocator.alloc(u8, 65535 + 16);
        errdefer allocator.free(read_buf);

        return NoiseStream{
            .inner = inner,
            .send_cipher = if (initiator) ciphers[0] else ciphers[1],
            .recv_cipher = if (initiator) ciphers[1] else ciphers[0],
            .remote_static = hs.rs.?,
            .remote_device_id = hs.remote_device_id.?,
            .read_buffer = read_buf,
            .read_pos = 0,
            .read_end = 0,
            .allocator = allocator,
        };
    }

    /// Message 1 (initiator): -> e
    fn writeMessage1(inner: network.Stream, hs: *HandshakeState) !void {
        std.debug.print("* Noise (OUT): Message 1 -> sending ephemeral public key (e)\n", .{});
        hs.e = KeyPair.generate();
        hs.symmetric.mixHash(&hs.e.?.public_key);
        writeHandshakeMessage(inner, &hs.e.?.public_key) catch |err| return logError("Message 1 write", err);
    }

    /// Message 1 (responder): -> e
    fn readMessage1(inner: network.Stream, hs: *HandshakeState) !void {
        var re: [32]u8 = undefined;
        readHandshakeMessage(inner, &re) catch |err| return logError("Message 1 read", err);
        std.debug.print("* Noise (IN):  Message 1 <- received ephemeral public key (e)\n", .{});
        hs.re = re;
        hs.symmetric.mixHash(&re);
    }

    /// Message 2 (responder): <- e, ee, s, es
    fn writeMessage2(inner: network.Stream, hs: *HandshakeState) !void {
        std.debug.print("* Noise (OUT): Message 2 -> sending ephemeral (e) and static (s) keys (encrypted)\n", .{});
        hs.e = KeyPair.generate();
        hs.symmetric.mixHash(&hs.e.?.public_key);

        // ee
        const ee = X25519.scalarmult(hs.e.?.private_key, hs.re.?) catch |err| return logError("Message 2 DH (ee)", err);
        hs.symmetric.mixKey(&ee);

        // s
        var s_ct: [32 + 16]u8 = undefined;
        try hs.symmetric.encryptAndHash(&hs.s.public_key, &s_ct);

        // es
        const es = X25519.scalarmult(hs.s.private_key, hs.re.?) catch |err| return logError("Message 2 DH (es)", err);
        hs.symmetric.mixKey(&es);

        const hello = try hs.auth.createHello(hs.symmetric.h);
        var payload_ct: [device_auth.hello_len + 16]u8 = undefined;
        try hs.symmetric.encryptAndHash(&hello, &payload_ct);

        var msg2: [32 + 48 + device_auth.hello_len + 16]u8 = undefined;
        @memcpy(msg2[0..32], &hs.e.?.public_key);
        @memcpy(msg2[32..80], &s_ct);
        @memcpy(msg2[80..], &payload_ct);
        writeHandshakeMessage(inner, &msg2) catch |err| return logError("Message 2 write", err);
    }

    /// Message 2 (initiator): <- e, ee, s, es
    fn readMessage2(inner: network.Stream, hs: *HandshakeState) !void {
        var buf: [32 + 48 + device_auth.hello_len + 16]u8 = undefined; // re, rs (encrypted), device hello
        readHandshakeMessage(inner, &buf) catch |err| return logError("Message 2 read", err);
        std.debug.print("* Noise (IN):  Message 2 <- received ephemeral (e) and static (s) keys (encrypted)\n", .{});

        // e
        hs.re = buf[0..32].*;
        hs.symmetric.mixHash(buf[0..32]);

        // ee
        const ee = X25519.scalarmult(hs.e.?.private_key, hs.re.?) catch |err| return logError("Message 2 DH (ee)", err);
        hs.symmetric.mixKey(&ee);

        // s
        var rs: [32]u8 = undefined;
        hs.symmetric.decryptAndHash(buf[32..80], &rs) catch |err| return logError("Message 2 Decrypt (s)", err);
        hs.rs = rs;

        // es
        const es = X25519.scalarmult(hs.e.?.private_key, hs.rs.?) catch |err| return logError("Message 2 DH (es)", err);
        hs.symmetric.mixKey(&es);

        // Device identity, signed over the handshake hash that also
        // authenticates this payload.
        const transcript = hs.symmetric.h;
        var hello: [device_auth.hello_len]u8 = undefined;
        hs.symmetric.decryptAndHash(buf[80..], &hello) catch |err| return logError("Message 2 Decrypt (device hello)", err);
        hs.remote_device_id = hs.auth.verifyHello(&hello, transcript) catch |err| return logError("Message 2 device identity", err);
    }

    /// Message 3 (initiator): -> s, se, psk
    fn writeMessage3(inner: network.Stream, hs: *HandshakeState) !void {
        std.debug.print("* Noise (OUT): Message 3 -> sending static key (s) and PSK authentication\n", .{});
        // s
        var s_ct: [32 + 16]u8 = undefined;
        try hs.symmetric.encryptAndHash(&hs.s.public_key, &s_ct);

        // se
        const se = X25519.scalarmult(hs.s.private_key, hs.re.?) catch |err| return logError("Message 3 DH (se)", err);
        hs.symmetric.mixKey(&se);

        // psk
        hs.symmetric.mixKeyAndHash(&hs.psk);

        // Payload: device identity, signed over the psk-mixed handshake hash.
        const hello = try hs.auth.createHello(hs.symmetric.h);
        var payload_ct: [device_auth.hello_len + 16]u8 = undefined;
        try hs.symmetric.encryptAndHash(&hello, &payload_ct);

        var msg3: [48 + device_auth.hello_len + 16]u8 = undefined;
        @memcpy(msg3[0..48], &s_ct);
        @memcpy(msg3[48..], &payload_ct);
        writeHandshakeMessage(inner, &msg3) catch |err| return logError("Message 3 write", err);
    }

    /// Message 3 (responder): -> s, se, psk
    fn readMessage3(inner: network.Stream, hs: *HandshakeState) !void {
        var buf: [48 + device_auth.hello_len + 16]u8 = undefined;
        readHandshakeMessage(inner, &buf) catch |err| return logError("Message 3 read", err);
        std.debug.print("* Noise (IN):  Message 3 <- received static key (s) and PSK authentication\n", .{});

        // s
        var rs: [32]u8 = undefined;
        hs.symmetric.decryptAndHash(buf[0..48], &rs) catch |err| return logError("Message 3 Decrypt (s)", err);
        hs.rs = rs;

        // se
        const se = X25519.scalarmult(hs.e.?.private_key, hs.rs.?) catch |err| return logError("Message 3 DH (se)", err);
        hs.symmetric.mixKey(&se);

        // psk
        hs.symmetric.mixKeyAndHash(&hs.psk);

        // payload: device identity (also verifies the PSK-derived key)
        const transcript = hs.symmetric.h;
        var hello: [device_auth.hello_len]u8 = undefined;
        hs.symmetric.decryptAndHash(buf[48..], &hello) catch |err| return logError("Message 3 Decrypt (payload/psk verify)", err);
        hs.remote_device_id = hs.auth.verifyHello(&hello, transcript) catch |err| return logError("Message 3 device identity", err);
    }

    fn logError(step: []const u8, err: anyerror) anyerror {
        std.debug.print("* Noise Error at step '{s}': {}\n", .{ step, err });
        return err;
    }

    fn writeHandshakeMessage(inner: network.Stream, msg: []const u8) !void {
        var len_buf: [2]u8 = undefined;
        std.mem.writeInt(u16, &len_buf, @intCast(msg.len), .big);
        try writeFull(inner, &len_buf);
        try writeFull(inner, msg);
    }

    /// Writes all of `buffer`; a short write would desynchronize the framing.
    fn writeFull(stream_obj: network.Stream, buffer: []const u8) !void {
        var total_written: usize = 0;
        while (total_written < buffer.len) {
            const n = try stream_obj.write(buffer[total_written..]);
            if (n == 0) return error.WriteZero;
            total_written += n;
        }
    }

    fn readHandshakeMessage(inner: network.Stream, out: []u8) !void {
        var len_buf: [2]u8 = undefined;
        try readFull(inner, &len_buf);
        const len = std.mem.readInt(u16, &len_buf, .big);
        if (len != out.len) return error.HandshakeFailed;
        try readFull(inner, out);
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
        try readFull(self.inner, &len_buf);
        const len = std.mem.readInt(u16, &len_buf, .big);

        if (len < 16) return error.PacketTooSmall;
        const msg_len = len - 16;

        if (len > self.read_buffer.len) return error.PacketTooLarge;

        try readFull(self.inner, self.read_buffer[0..len]);

        try self.recv_cipher.decryptWithAd(&[_]u8{}, self.read_buffer[0..len], self.read_buffer[0..msg_len]);

        self.read_pos = 0;
        self.read_end = msg_len;

        // Now copy to user buffer
        const to_copy = @min(buffer.len, msg_len);
        @memcpy(buffer[0..to_copy], self.read_buffer[0..to_copy]);
        self.read_pos += to_copy;

        return to_copy;
    }

    fn readFull(stream_obj: network.Stream, buffer: []u8) !void {
        var total_read: usize = 0;
        while (total_read < buffer.len) {
            const n = try stream_obj.read(buffer[total_read..]);
            if (n == 0) return error.EndOfStream;
            total_read += n;
        }
    }

    fn write(ptr: *anyopaque, buffer: []const u8) anyerror!usize {
        const self: *NoiseStream = @ptrCast(@alignCast(ptr));

        const max_payload = 1024;
        var i: usize = 0;
        while (i < buffer.len) {
            const chunk_len = @min(buffer.len - i, max_payload);
            const packet_len = chunk_len + 16;

            var temp: [max_payload + 16]u8 = undefined;
            try self.send_cipher.encryptWithAd(&[_]u8{}, buffer[i .. i + chunk_len], &temp);

            var len_buf: [2]u8 = undefined;
            std.mem.writeInt(u16, &len_buf, @intCast(packet_len), .big);
            try writeFull(self.inner, &len_buf);
            try writeFull(self.inner, temp[0..packet_len]);

            i += chunk_len;
        }

        return buffer.len;
    }

    pub fn deinit(self: *NoiseStream) void {
        self.close();
        self.allocator.free(self.read_buffer);
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
