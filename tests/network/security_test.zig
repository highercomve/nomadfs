const std = @import("std");
const nomadfs = @import("nomadfs");
const noise = nomadfs.network.noise;
const TestPeer = @import("test_helpers").TestPeer;
const MemoryStream = @import("memory_stream.zig").MemoryStream;
const Pipe = @import("memory_stream.zig").Pipe;

test "security: noise handshake and data transfer" {
    const allocator = std.testing.allocator;

    // 1. Create two peers with SAME swarm key
    var peer1 = try TestPeer.init(allocator, 9005);
    defer peer1.deinit();
    peer1.config.node.swarm_key = "correct_swarm_key_32_bytes_long_";

    var peer2 = try TestPeer.init(allocator, 9006);
    defer peer2.deinit();
    peer2.config.node.swarm_key = "correct_swarm_key_32_bytes_long_";

    // 2. Start peer1 listener
    try peer1.start();
    std.Thread.sleep(100 * std.time.ns_per_ms);

    // 3. Connect peer2 to peer1
    const stream = try peer2.connect(peer1);
    defer stream.close();

    const msg = "Secret Message over Noise";
    _ = try stream.write(msg);

    // 4. Server side verification
    var retries: usize = 0;
    while (peer1.manager.connections.items.len == 0) {
        if (retries > 10) return error.TestTimeout;
        std.Thread.sleep(50 * std.time.ns_per_ms);
        retries += 1;
    }

    const server_conn = peer1.manager.connections.items[0];
    const server_stream = try server_conn.acceptStream();
    defer server_stream.close();

    var recv_buf: [64]u8 = undefined;
    const recv_len = try server_stream.read(&recv_buf);

    try std.testing.expectEqualStrings(msg, recv_buf[0..recv_len]);
}

test "security: noise handshake fails with wrong swarm key" {
    const allocator = std.testing.allocator;

    // 1. Create two peers with DIFFERENT swarm keys
    var peer1 = try TestPeer.init(allocator, 9007);
    defer peer1.deinit();
    peer1.config.node.swarm_key = "correct_swarm_key_32_bytes_long_";

    var peer2 = try TestPeer.init(allocator, 9008);
    defer peer2.deinit();
    peer2.config.node.swarm_key = "WRONG_swarm_key_32_bytes_long_!!";

    // 2. Start peer1 listener
    try peer1.start();
    std.Thread.sleep(100 * std.time.ns_per_ms);

    // 3. Connect peer2 to peer1 - this should fail during handshake
    const conn_result = peer2.connect(peer1);

    // Handshake should fail. Responder will close connection.
    // The initiator will likely see an error (either during handshake or when using it).
    // In our implementation, Message 3 is where PSK is mixed.
    // If PSK is wrong, responder fails to decrypt the payload in Message 3.
    // Initiator might finish writeMessage(msg3) and then return.
    // But then it tries to use it.
    _ = conn_result catch |err| {
        std.debug.print("Caught expected handshake error: {}\n", .{err});
        return;
    };

    // If it didn't fail yet, try to write and read something
    if (conn_result) |s| {
        defer s.close();
        _ = s.write("this should fail") catch {};

        var buf: [64]u8 = undefined;
        const n = s.read(&buf) catch |err| {
            std.debug.print("Caught expected error during read: {}\n", .{err});
            return;
        };
        if (n == 0) {
            std.debug.print("Caught expected EOF during read\n", .{});
            return;
        }
        return error.HandshakeShouldHaveFailed;
    } else |err| {
        std.debug.print("Caught expected handshake error (alternative path): {}\n", .{err});
    }
}

test "security: connection drop during handshake" {
    const allocator = std.testing.allocator;
    const swarm_key = "correct_swarm_key_32_bytes_long_";

    // Create a memory stream that acts as the wire
    var mem_stream = MemoryStream.init(allocator);
    defer mem_stream.deinit();

    // Case 1: Stream is empty (Immediate EOF)
    const err1 = noise.NoiseStream.handshake(mem_stream.stream(), swarm_key, noise.KeyPair.generate(), false);
    try std.testing.expectError(error.EndOfStream, err1);

    // Case 2: Partial Header (EOF in header)
    _ = try mem_stream.stream().write(&[_]u8{0x00}); // Just 1 byte
    // We need to reset read_pos because write didn't advance it (same stream instance)
    // But wait, MemoryStream append doesn't move read_pos.
    // So if we read now, we read what we wrote.
    const err2 = noise.NoiseStream.handshake(mem_stream.stream(), swarm_key, noise.KeyPair.generate(), false);
    // Depending on readFull impl, could be EndOfStream or similar.
    try std.testing.expectError(error.EndOfStream, err2);
}

test "security: data on wire is encrypted" {
    const allocator = std.testing.allocator;
    const swarm_key = "correct_swarm_key_32_bytes_long_";

    const pipe = Pipe.init(allocator);
    defer pipe.deinit();

    // Shared context for threads
    const Context = struct {
        pipe: *Pipe,
        key: []const u8,

        fn runClient(ctx: @This()) !void {
            var ns = try noise.NoiseStream.handshake(ctx.pipe.client(), ctx.key, noise.KeyPair.generate(), true);
            const msg = "Super Secret Plaintext";
            _ = try ns.stream().write(msg);

            // Read response
            var buf: [1024]u8 = undefined;
            const n = try ns.stream().read(&buf);
            try std.testing.expectEqualStrings("Server Reply", buf[0..n]);
        }

        fn runServer(ctx: @This()) !void {
            var ns = try noise.NoiseStream.handshake(ctx.pipe.server(), ctx.key, noise.KeyPair.generate(), false);

            // Read client message
            var buf: [1024]u8 = undefined;
            const n = try ns.stream().read(&buf);
            try std.testing.expectEqualStrings("Super Secret Plaintext", buf[0..n]);

            // Send reply
            _ = try ns.stream().write("Server Reply");
        }
    };

    const ctx = Context{ .pipe = pipe, .key = swarm_key };

    // Run client in a thread
    const client_thread = try std.Thread.spawn(.{}, Context.runClient, .{ctx});

    // Run server in main thread
    try ctx.runServer();

    client_thread.join();

    // Now inspect the wire!
    pipe.mutex.lock();
    defer pipe.mutex.unlock();

    const wire_data_1 = pipe.buffer_a_to_b.items;
    const wire_data_2 = pipe.buffer_b_to_a.items;

    // std.debug.print("wire_data_1: {s}\n", .{wire_data_1});
    // std.debug.print("wire_data_2: {s}\n", .{wire_data_2});

    // Ensure "Super Secret Plaintext" is NOT in the wire data
    try std.testing.expect(std.mem.indexOf(u8, wire_data_1, "Super Secret Plaintext") == null);
    try std.testing.expect(std.mem.indexOf(u8, wire_data_2, "Super Secret Plaintext") == null);

    // Ensure "Server Reply" is NOT in the wire data
    try std.testing.expect(std.mem.indexOf(u8, wire_data_1, "Server Reply") == null);
    try std.testing.expect(std.mem.indexOf(u8, wire_data_2, "Server Reply") == null);

    // Sanity check: ensure we actually transmitted something significant
    try std.testing.expect(wire_data_1.len > 50);
    try std.testing.expect(wire_data_2.len > 50);
}
