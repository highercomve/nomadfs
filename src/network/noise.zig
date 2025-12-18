const std = @import("std");
const network = @import("mod.zig");

const Hash = std.crypto.hash.blake2.Blake2s256;
const Hmac = std.crypto.auth.hmac.Hmac(Hash);
const Hkdf = std.crypto.kdf.hkdf.Hkdf(Hmac);
const Aead = std.crypto.aead.chacha_poly.ChaCha20Poly1305;
const X25519 = std.crypto.dh.X25519;

pub const KeyPair = struct {
    public_key: [32]u8,
    private_key: [32]u8,

    pub fn generate() KeyPair {
        const kp = X25519.KeyPair.generate();
        return .{
            .public_key = kp.public_key,
            .private_key = kp.secret_key,
        };
    }

    pub fn loadFromFile(path: []const u8) !KeyPair {
        const file = if (std.fs.path.isAbsolute(path))
            try std.fs.openFileAbsolute(path, .{})
        else
            try std.fs.cwd().openFile(path, .{});
        defer file.close();

        var kp: KeyPair = undefined;
        const bytes_read = try file.readAll(std.mem.asBytes(&kp));
        if (bytes_read != @sizeOf(KeyPair)) return error.InvalidKeyFile;
        return kp;
    }

    pub fn saveToFile(self: KeyPair, path: []const u8) !void {
        const file = if (std.fs.path.isAbsolute(path))
            try std.fs.createFileAbsolute(path, .{})
        else
            try std.fs.cwd().createFile(path, .{});
        defer file.close();

        try file.writeAll(std.mem.asBytes(&self));
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

    pub fn encryptWithAd(self: *CipherState, ad: []const u8, plaintext: []const u8, out: []u8) void {
        if (!self.has_key) {
            @memcpy(out[0..plaintext.len], plaintext);
            return;
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
            @memcpy(out[0..ciphertext.len], ciphertext);
            return;
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

    pub fn encryptAndHash(self: *SymmetricState, plaintext: []const u8, out: []u8) void {
        self.cipher_state.encryptWithAd(&self.h, plaintext, out);
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

    pub fn init(initiator: bool, static_key: KeyPair, swarm_key: [32]u8) HandshakeState {
        return .{
            .symmetric = SymmetricState.init("Noise_XXpsk3_25519_ChaChaPoly_BLAKE2s"),
            .s = static_key,
            .e = null,
            .rs = null,
            .re = null,
            .psk = swarm_key,
            .initiator = initiator,
        };
    }
};

pub const NoiseStream = struct {
    inner: network.Stream,
    send_cipher: CipherState,
    recv_cipher: CipherState,
    remote_static: [32]u8,

    pub fn handshake(inner: network.Stream, swarm_key_bytes: []const u8, static_key: KeyPair, initiator: bool) !NoiseStream {
        const role = if (initiator) "Initiator" else "Responder";
        std.debug.print("* Noise_XXpsk3 handshake start ({s})\n", .{role});

        if (swarm_key_bytes.len != 32) return error.InvalidSwarmKey;
        var swarm_key: [32]u8 = undefined;
        @memcpy(&swarm_key, swarm_key_bytes);

        var hs = HandshakeState.init(initiator, static_key, swarm_key);

        const result = try_handshake_steps(inner, &hs, initiator);
        if (result) |ns| {
            std.debug.print("* Noise Handshake complete\n", .{});
            return ns;
        } else |err| {
            std.debug.print("* Noise Handshake FAILED ({s}): {}\n", .{ role, err });
            return err;
        }
    }

    fn try_handshake_steps(inner: network.Stream, hs: *HandshakeState, initiator: bool) !NoiseStream {
        // Message 1: -> e
        if (initiator) {
            std.debug.print("* Noise (OUT): Message 1 -> sending ephemeral public key (e)\n", .{});
            hs.e = KeyPair.generate();
            hs.symmetric.mixHash(&hs.e.?.public_key);
            writeHandshakeMessage(inner, &hs.e.?.public_key) catch |err| return logError("Message 1 write", err);
        } else {
            var re: [32]u8 = undefined;
            readHandshakeMessage(inner, &re) catch |err| return logError("Message 1 read", err);
            std.debug.print("* Noise (IN):  Message 1 <- received ephemeral public key (e)\n", .{});
            hs.re = re;
            hs.symmetric.mixHash(&re);
        }

        // Message 2: <- e, ee, s, es
        if (initiator) {
            var buf: [32 + 48]u8 = undefined; // re, rs (encrypted)
            readHandshakeMessage(inner, &buf) catch |err| return logError("Message 2 read", err);
            std.debug.print("* Noise (IN):  Message 2 <- received ephemeral (e) and static (s) keys (encrypted)\n", .{});

            // e
            var re: [32]u8 = undefined;
            @memcpy(&re, buf[0..32]);
            hs.re = re;
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
        } else {
            std.debug.print("* Noise (OUT): Message 2 -> sending ephemeral (e) and static (s) keys (encrypted)\n", .{});
            hs.e = KeyPair.generate();
            hs.symmetric.mixHash(&hs.e.?.public_key);

            // ee
            const ee = X25519.scalarmult(hs.e.?.private_key, hs.re.?) catch |err| return logError("Message 2 DH (ee)", err);
            hs.symmetric.mixKey(&ee);

            // s
            var s_ct: [32 + 16]u8 = undefined;
            hs.symmetric.encryptAndHash(&hs.s.public_key, &s_ct);

            // es
            const es = X25519.scalarmult(hs.s.private_key, hs.re.?) catch |err| return logError("Message 2 DH (es)", err);
            hs.symmetric.mixKey(&es);

            var msg2: [32 + 48]u8 = undefined;
            @memcpy(msg2[0..32], &hs.e.?.public_key);
            @memcpy(msg2[32..80], &s_ct);
            writeHandshakeMessage(inner, &msg2) catch |err| return logError("Message 2 write", err);
        }

        // Message 3: -> s, se, psk
        if (initiator) {
            std.debug.print("* Noise (OUT): Message 3 -> sending static key (s) and PSK authentication\n", .{});
            // s
            var s_ct: [32 + 16]u8 = undefined;
            hs.symmetric.encryptAndHash(&hs.s.public_key, &s_ct);

            // se
            const se = X25519.scalarmult(hs.s.private_key, hs.re.?) catch |err| return logError("Message 3 DH (se)", err);
            hs.symmetric.mixKey(&se);

            // psk
            hs.symmetric.mixKeyAndHash(&hs.psk);

            // Final message has s_ct and an empty payload encrypted (just a tag)
            var payload_ct: [16]u8 = undefined;
            hs.symmetric.encryptAndHash(&[_]u8{}, &payload_ct);

            var msg3: [48 + 16]u8 = undefined;
            @memcpy(msg3[0..48], &s_ct);
            @memcpy(msg3[48..64], &payload_ct);
            writeHandshakeMessage(inner, &msg3) catch |err| return logError("Message 3 write", err);
        } else {
            var buf: [48 + 16]u8 = undefined;
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

            // payload
            var payload: [0]u8 = undefined;
            hs.symmetric.decryptAndHash(buf[48..64], &payload) catch |err| return logError("Message 3 Decrypt (payload/psk verify)", err);
        }

        const ciphers = hs.symmetric.split();
        return NoiseStream{
            .inner = inner,
            .send_cipher = if (initiator) ciphers[0] else ciphers[1],
            .recv_cipher = if (initiator) ciphers[1] else ciphers[0],
            .remote_static = hs.rs.?,
        };
    }

    fn logError(step: []const u8, err: anyerror) anyerror {
        std.debug.print("* Noise Error at step '{s}': {}\n", .{ step, err });
        return err;
    }

    fn writeHandshakeMessage(inner: network.Stream, msg: []const u8) !void {
        var len_buf: [2]u8 = undefined;
        std.mem.writeInt(u16, &len_buf, @intCast(msg.len), .big);
        _ = try inner.write(&len_buf);
        _ = try inner.write(msg);
    }

    fn readHandshakeMessage(inner: network.Stream, out: []u8) !void {
        var len_buf: [2]u8 = undefined;
        try readFull(inner, &len_buf);
        const len = std.mem.readInt(u16, &len_buf, .big);
        if (len != out.len) return error.HandshakeFailed;
        try readFull(inner, out);
    }

    pub fn stream(self: *NoiseStream) network.Stream {
        return .{
            .ptr = self,
            .vtable = &network.Stream.StreamVTable{
                .read = read,
                .write = write,
                .close = close,
            },
        };
    }

    fn read(ptr: *anyopaque, buffer: []u8) anyerror!usize {
        const self: *NoiseStream = @ptrCast(@alignCast(ptr));

        var len_buf: [2]u8 = undefined;
        try readFull(self.inner, &len_buf);
        const len = std.mem.readInt(u16, &len_buf, .big);

        if (len < 16) return error.PacketTooSmall;
        const msg_len = len - 16;
        if (msg_len > buffer.len) return error.BufferTooSmall;

        // Use a stack buffer for small packets or allocate?
        // Noise max packet is 65535.
        // For now, let's use a fixed buffer on stack for MVP or allocate if needed.
        var temp: [2048]u8 = undefined;
        if (len > temp.len) return error.PacketTooLarge;

        try readFull(self.inner, temp[0..len]);

        try self.recv_cipher.decryptWithAd(&[_]u8{}, temp[0..len], buffer[0..msg_len]);
        return msg_len;
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
            self.send_cipher.encryptWithAd(&[_]u8{}, buffer[i .. i + chunk_len], &temp);

            var len_buf: [2]u8 = undefined;
            std.mem.writeInt(u16, &len_buf, @intCast(packet_len), .big);
            _ = try self.inner.write(&len_buf);
            _ = try self.inner.write(temp[0..packet_len]);

            i += chunk_len;
        }

        return buffer.len;
    }

    fn close(ptr: *anyopaque) void {
        const self: *NoiseStream = @ptrCast(@alignCast(ptr));
        self.inner.close();
    }
};
