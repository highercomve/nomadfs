const std = @import("std");
const nomadfs = @import("nomadfs");
const noise = nomadfs.network.noise;
const MemoryStream = @import("../memory_stream.zig").MemoryStream;
const TestPeer = @import("test_helpers").TestPeer;

test "security: noise stream encrypts data" {
    const allocator = std.testing.allocator;

    var mem_stream = MemoryStream.init(allocator);
    defer mem_stream.deinit();

    var key: [32]u8 = undefined;
    @memset(&key, 0x42);
    const nonce = [_]u8{0} ** 12;
    
    // Initialize state with fresh buffers
    var noise_stream = noise.NoiseStream{
        .inner = mem_stream.stream(),
        .state = .{
            .key = key,
            .nonce = nonce,
            .enc_counter = 0,
            .enc_buf = undefined,
            .enc_idx = 64, // Force refill
            .dec_counter = 0,
            .dec_buf = undefined,
            .dec_idx = 64,
        },
    };

    const plaintext = "Hello, world!";
    _ = try noise_stream.stream().write(plaintext);

    // Verify underlying memory stream does NOT contain plaintext
    const ciphertext = mem_stream.buffer.items;
    try std.testing.expect(!std.mem.eql(u8, ciphertext, plaintext));
    
    // Verify ciphertext is not empty
    try std.testing.expect(ciphertext.len == plaintext.len);

    // Now try to decrypt (read back)
    mem_stream.read_pos = 0;
    
    var read_buf: [64]u8 = undefined;
    const read_len = try noise_stream.stream().read(&read_buf);
    
    try std.testing.expectEqual(plaintext.len, read_len);
    try std.testing.expectEqualStrings(plaintext, read_buf[0..read_len]);
}

test "security: manager connection uses noise" {
    const allocator = std.testing.allocator;

    // 1. Create two peers
    var peer1 = try TestPeer.init(allocator, 9005);
    defer peer1.deinit();

    var peer2 = try TestPeer.init(allocator, 9006);
    defer peer2.deinit();

    // 2. Start peer1 listener
    try peer1.start();
    std.Thread.sleep(100 * std.time.ns_per_ms);

    // 3. Connect peer2 to peer1 via Manager
    const conn = try peer2.manager.connectToPeer(peer1.listen_addr);
    const stream = try conn.openStream();
    defer stream.close();

    const msg = "Secret Message over Manager";
    _ = try stream.write(msg);
    
    // Server side verification
    // Get the connection from peer1's manager (it should have accepted it)
    // We need to wait for accept? Thread.sleep handled it.
    
    // Access peer1 manager connections
    // peer1.manager.connections is ArrayListUnmanaged.
    // Wait for connection to be accepted
    var retries: usize = 0;
    while (peer1.manager.connections.items.len == 0) {
        if (retries > 10) return error.TestTimeout;
        std.Thread.sleep(50 * std.time.ns_per_ms);
        retries += 1;
    }
    
    const server_conn = peer1.manager.connections.items[0];
    
    // Accept stream on server connection
    const server_stream = try server_conn.acceptStream();
    defer server_stream.close();
    
    var recv_buf: [64]u8 = undefined;
    const recv_len = try server_stream.read(&recv_buf);
    
    std.debug.print("Server received: {s}\n", .{recv_buf[0..recv_len]});
    try std.testing.expectEqualStrings(msg, recv_buf[0..recv_len]);
}

