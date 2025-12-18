const std = @import("std");
const network = @import("mod.zig");

pub const State = struct {
    key: [32]u8,
    nonce: [12]u8,
    
    enc_counter: u32 = 0,
    enc_buf: [64]u8 = undefined,
    enc_idx: usize = 64, // Start exhausted to trigger refill

    dec_counter: u32 = 0,
    dec_buf: [64]u8 = undefined,
    dec_idx: usize = 64,
};

/// Implementation of Noise_XXpsk3_25519_ChaChaPoly_BLAKE2b
/// For the MVP, we might start with a simpler handshake or use a library if available.
/// Since we want to stick to the spec, we define the handshake state machine here.
pub const NoiseStream = struct {
    inner: network.Stream,
    state: State,

    /// Perform the Noise_XXpsk3 handshake.
    /// In a real implementation, this would involve Diffie-Hellman key exchange and Chacha20Poly1305 encryption.
    /// For this MVP, we simulate the 3-way handshake to ensure the state machine is correct.
    pub fn handshake(inner: network.Stream, swarm_key: []const u8, initiator: bool) !NoiseStream {
        _ = swarm_key;
        
        // 1. Initiator sends 'e' (ephemeral public key)
        if (initiator) {
            try sendHandshakeMessage(inner, "e");
        } else {
            try receiveHandshakeMessage(inner, "e");
        }

        // 2. Responder sends 'e, ee, s, es'
        if (initiator) {
            try receiveHandshakeMessage(inner, "e, ee, s, es");
        } else {
            try sendHandshakeMessage(inner, "e, ee, s, es");
        }

        // 3. Initiator sends 's, se, psk'
        if (initiator) {
            try sendHandshakeMessage(inner, "s, se, psk");
        } else {
            try receiveHandshakeMessage(inner, "s, se, psk");
        }

        // Initialize Cipher State (Simulated Key Derivation)
        // In reality, this key comes from the handshake.
        var key: [32]u8 = undefined;
        @memset(&key, 0x42); // Dummy key
        const nonce = [_]u8{0} ** 12;
        
        return .{
            .inner = inner,
            .state = .{
                .key = key,
                .nonce = nonce,
            },
        };
    }

    fn sendHandshakeMessage(conn_stream: network.Stream, msg: []const u8) !void {
        // Send length-prefixed message
        var len_buf: [2]u8 = undefined;
        std.mem.writeInt(u16, &len_buf, @intCast(msg.len), .big);
        _ = try conn_stream.write(&len_buf);
        _ = try conn_stream.write(msg);
    }

    fn receiveHandshakeMessage(conn_stream: network.Stream, expected_msg: []const u8) !void {
        var len_buf: [2]u8 = undefined;
        if (try conn_stream.read(&len_buf) != 2) return error.HandshakeFailed;
        const len = std.mem.readInt(u16, &len_buf, .big);
        
        // For MVP validation
        if (len != expected_msg.len) return error.HandshakeFailed;

        var buf: [128]u8 = undefined;
        if (len > buf.len) return error.HandshakeFailed;
        if (try conn_stream.read(buf[0..len]) != len) return error.HandshakeFailed;
        
        if (!std.mem.eql(u8, buf[0..len], expected_msg)) return error.HandshakeFailed;
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
        const n = try self.inner.read(buffer);
        if (n == 0) return 0;
        
        for (buffer[0..n]) |*b| {
            if (self.state.dec_idx >= 64) {
                const zeros = [_]u8{0} ** 64;
                std.crypto.stream.chacha.ChaCha20IETF.xor(&self.state.dec_buf, &zeros, self.state.dec_counter, self.state.key, self.state.nonce);
                self.state.dec_counter += 1;
                self.state.dec_idx = 0;
            }
            b.* ^= self.state.dec_buf[self.state.dec_idx];
            self.state.dec_idx += 1;
        }
        return n;
    }

    fn write(ptr: *anyopaque, buffer: []const u8) anyerror!usize {
        const self: *NoiseStream = @ptrCast(@alignCast(ptr));
        
        // Allocate temp buffer for encryption
        // Ideally we'd loop with a fixed stack buffer for large writes
        var temp_buf: [4096]u8 = undefined;
        var total_written: usize = 0;
        
        var i: usize = 0;
        while (i < buffer.len) {
            const chunk_len = @min(buffer.len - i, temp_buf.len);
            
            for (0..chunk_len) |j| {
                if (self.state.enc_idx >= 64) {
                    const zeros = [_]u8{0} ** 64;
                    std.crypto.stream.chacha.ChaCha20IETF.xor(&self.state.enc_buf, &zeros, self.state.enc_counter, self.state.key, self.state.nonce);
                    self.state.enc_counter += 1;
                    self.state.enc_idx = 0;
                }
                temp_buf[j] = buffer[i + j] ^ self.state.enc_buf[self.state.enc_idx];
                self.state.enc_idx += 1;
            }
            
            _ = try self.inner.write(temp_buf[0..chunk_len]);
            total_written += chunk_len;
            i += chunk_len;
        }
        return total_written;
    }

    fn close(ptr: *anyopaque) void {
        const self: *NoiseStream = @ptrCast(@alignCast(ptr));
        self.inner.close();
    }
};