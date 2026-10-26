const std = @import("std");
const nomadfs = @import("nomadfs");
const noise = nomadfs.net.transport.noise;
const TestPeer = @import("test_helpers").TestPeer;
const MemoryStream = @import("memory_stream.zig").MemoryStream;
const Pipe = @import("memory_stream.zig").Pipe;
const identity_mod = nomadfs.device.identity;

test "security: noise handshake and data transfer" {
    std.debug.print("\n=== Running Test: security: noise handshake and data transfer ===\n", .{});
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
    nomadfs.sync.sleep(100 * std.time.ns_per_ms);

    // 3. Connect peer2 to peer1
    const stream = try peer2.connect(&peer1);
    defer stream.close();

    const msg = "Secret Message over Noise";
    _ = try stream.write(msg);

    // 4. Server side verification
    var retries: usize = 0;
    while (peer1.manager.getConnectionsCount() == 0) {
        if (retries > 10) return error.TestTimeout;
        nomadfs.sync.sleep(50 * std.time.ns_per_ms);
        retries += 1;
    }

    const server_conn = peer1.manager.getConnection(0).?;
    defer server_conn.deinit();
    const server_stream = try server_conn.acceptStream();
    defer server_stream.close();

    var recv_buf: [64]u8 = undefined;
    const recv_len = try server_stream.read(&recv_buf);

    try std.testing.expectEqualStrings(msg, recv_buf[0..recv_len]);
}

test "security: noise handshake fails with wrong swarm key" {
    std.debug.print("\n=== Running Test: security: noise handshake fails with wrong swarm key ===\n", .{});
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
    nomadfs.sync.sleep(100 * std.time.ns_per_ms);

    // 3. Connect peer2 to peer1 - this should fail during handshake
    const conn_result = peer2.connect(&peer1);

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
    std.debug.print("\n=== Running Test: security: connection drop during handshake ===\n", .{});
    const allocator = std.testing.allocator;
    const swarm_key = "correct_swarm_key_32_bytes_long_";

    // Create a memory stream that acts as the wire
    var mem_stream = MemoryStream.init(allocator);
    defer mem_stream.deinit();

    // Case 1: Stream is empty (Immediate EOF)
    const err1 = noise.NoiseStream.handshake(allocator, mem_stream.stream(), swarm_key, noise.KeyPair.generate(), false, null);
    try std.testing.expectError(error.EndOfStream, err1);

    // Case 2: Partial Header (EOF in header)
    _ = try mem_stream.stream().write(&[_]u8{0x00}); // Just 1 byte
    // We need to reset read_pos because write didn't advance it (same stream instance)
    // But wait, MemoryStream append doesn't move read_pos.
    // So if we read now, we read what we wrote.
    const err2 = noise.NoiseStream.handshake(allocator, mem_stream.stream(), swarm_key, noise.KeyPair.generate(), false, null);
    // Depending on readFull impl, could be EndOfStream or similar.
    try std.testing.expectError(error.EndOfStream, err2);
}

// Shared context for threads
const Context = struct {
    pipe: *Pipe,
    key: []const u8,
    allocator: std.mem.Allocator,

    fn runClient(ctx: @This()) !void {
        var ns = try noise.NoiseStream.handshake(ctx.allocator, ctx.pipe.client(), ctx.key, noise.KeyPair.generate(), true, null);
        defer ns.deinit();

        const msg = "Super Secret Plaintext";
        _ = try ns.stream().write(msg);

        // Read response
        var buf: [1024]u8 = undefined;
        const n = try ns.stream().read(&buf);
        try std.testing.expectEqualStrings("Server Reply", buf[0..n]);
    }

    fn runServer(ctx: @This()) !void {
        var ns = try noise.NoiseStream.handshake(ctx.allocator, ctx.pipe.server(), ctx.key, noise.KeyPair.generate(), false, null);
        defer ns.deinit();

        // Read client message
        var buf: [1024]u8 = undefined;
        const n = try ns.stream().read(&buf);
        try std.testing.expectEqualStrings("Super Secret Plaintext", buf[0..n]);

        // Send reply
        _ = try ns.stream().write("Server Reply");
    }
};

test "security: data on wire is encrypted" {
    std.debug.print("\n=== Running Test: security: data on wire is encrypted ===\n", .{});
    const allocator = std.testing.allocator;
    const swarm_key = "correct_swarm_key_32_bytes_long_";

    var pipe = Pipe.init(allocator);
    defer pipe.deinit();

    const ctx = Context{ .pipe = &pipe, .key = swarm_key, .allocator = allocator };

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

test "security: silent peer cannot stall the handshake or shutdown" {
    std.debug.print("\n=== Running Test: security: silent peer cannot stall the handshake or shutdown ===\n", .{});
    const allocator = std.testing.allocator;

    var peer1 = try TestPeer.init(allocator, 9009);
    defer peer1.deinit();
    peer1.manager.handshake_timeout_ms = 200;
    try peer1.start();
    nomadfs.sync.sleep(100 * std.time.ns_per_ms);

    // Connect and never send a byte.
    const silent = try nomadfs.net.compat.tcpConnectToAddress(peer1.listen_addr);
    defer silent.close();
    nomadfs.sync.sleep(100 * std.time.ns_per_ms);

    // stop() waits for in-flight handshakes; without the timeout it would hang.
    const started = nomadfs.sync.milliTimestamp();
    peer1.stop();
    const elapsed = nomadfs.sync.milliTimestamp() - started;
    try std.testing.expect(elapsed < 2000);
}

const DeviceContext = struct {
    pipe: *Pipe,
    key: []const u8,
    allocator: std.mem.Allocator,
    auth: *const nomadfs.device.auth.Authenticator,
    initiator: bool,
    remote: ?nomadfs.net.id.NodeID = null,
    failure: ?anyerror = null,
    /// Present when the test wants to check transport-key pinning.
    static_key: ?noise.KeyPair = null,

    fn run(ctx: *DeviceContext) void {
        ctx.runInner() catch |err| {
            ctx.failure = err;
        };
    }

    fn runInner(ctx: *DeviceContext) !void {
        const stream = if (ctx.initiator) ctx.pipe.client() else ctx.pipe.server();
        var ns = try noise.NoiseStream.handshake(
            ctx.allocator,
            stream,
            ctx.key,
            ctx.static_key orelse noise.KeyPair.generate(),
            ctx.initiator,
            ctx.auth,
        );
        defer ns.deinit();
        ctx.remote = ns.remote_device_id;
    }
};

const test_swarm_key = "correct_swarm_key_32_bytes_long_";

fn pairedStore(
    allocator: std.mem.Allocator,
    path: []const u8,
    identity: nomadfs.device.identity.Identity,
    transport: [32]u8,
) !nomadfs.device.trust.Store {
    const io = std.Io.Threaded.global_single_threaded.io();
    std.Io.Dir.cwd().deleteFile(io, path) catch {};

    var store = try nomadfs.device.trust.Store.load(allocator, path, null);
    errdefer store.deinit();

    const ticket = try nomadfs.device.pairing.Ticket.init(
        identity,
        transport,
        "peer",
        "192.168.1.5:4001",
        1_800_000_000,
    );
    _ = try store.trustTicket(ticket, 1);
    return store;
}

test "security: handshake binds the session to both device identities" {
    std.debug.print("\n=== Running Test: security: handshake binds the session to both device identities ===\n", .{});
    const allocator = std.testing.allocator;
    const swarm_key = "correct_swarm_key_32_bytes_long_";

    const client_identity = try identity_mod.Identity.fromSeed([_]u8{0x21} ** identity_mod.seed_len);
    const server_identity = try identity_mod.Identity.fromSeed([_]u8{0x22} ** identity_mod.seed_len);
    const client_auth: nomadfs.device.auth.Authenticator = .{ .identity = client_identity };
    const server_auth: nomadfs.device.auth.Authenticator = .{ .identity = server_identity };

    var pipe = Pipe.init(allocator);
    defer pipe.deinit();

    var client_ctx = DeviceContext{
        .pipe = &pipe,
        .key = swarm_key,
        .allocator = allocator,
        .auth = &client_auth,
        .initiator = true,
    };
    var server_ctx = DeviceContext{
        .pipe = &pipe,
        .key = swarm_key,
        .allocator = allocator,
        .auth = &server_auth,
        .initiator = false,
    };

    const client_thread = try std.Thread.spawn(.{}, DeviceContext.run, .{&client_ctx});
    server_ctx.run();
    client_thread.join();

    try std.testing.expect(server_ctx.failure == null);
    try std.testing.expect(client_ctx.failure == null);
    try std.testing.expect(server_ctx.remote.?.eql(client_identity.deviceId()));
    try std.testing.expect(client_ctx.remote.?.eql(server_identity.deviceId()));
}

test "security: handshake rejects an untrusted device under strict policy" {
    std.debug.print("\n=== Running Test: security: handshake rejects an untrusted device under strict policy ===\n", .{});
    const allocator = std.testing.allocator;
    const swarm_key = "correct_swarm_key_32_bytes_long_";

    const strict_auth: nomadfs.device.auth.Authenticator = .{
        .identity = try identity_mod.Identity.fromSeed([_]u8{0x23} ** identity_mod.seed_len),
        // No trust store attached, so every peer is unknown and must be rejected.
        .require_trusted = true,
    };
    const peer_auth: nomadfs.device.auth.Authenticator = .{
        .identity = try identity_mod.Identity.fromSeed([_]u8{0x24} ** identity_mod.seed_len),
    };

    var pipe = Pipe.init(allocator);
    defer pipe.deinit();

    var initiator_ctx = DeviceContext{
        .pipe = &pipe,
        .key = swarm_key,
        .allocator = allocator,
        .auth = &strict_auth,
        .initiator = true,
    };
    var responder_ctx = DeviceContext{
        .pipe = &pipe,
        .key = swarm_key,
        .allocator = allocator,
        .auth = &peer_auth,
        .initiator = false,
    };

    const responder_thread = try std.Thread.spawn(.{}, DeviceContext.run, .{&responder_ctx});
    initiator_ctx.run();
    // The initiator aborts before message 3; unblock the responder.
    pipe.stop();
    responder_thread.join();

    try std.testing.expectEqual(
        @as(?anyerror, nomadfs.device.auth.Error.UntrustedDevice),
        initiator_ctx.failure,
    );
    try std.testing.expectEqual(@as(?anyerror, error.EndOfStream), responder_ctx.failure);
    try std.testing.expect(initiator_ctx.remote == null);
}

test "security: a paired transport key is accepted when it matches" {
    std.debug.print("\n=== Running Test: security: a paired transport key is accepted when it matches ===\n", .{});
    const allocator = std.testing.allocator;
    const auth_mod = nomadfs.device.auth;
    const io = std.Io.Threaded.global_single_threaded.io();
    const store_path = "test_security_pin.store";
    defer std.Io.Dir.cwd().deleteFile(io, store_path) catch {};

    const client_identity = try identity_mod.Identity.fromSeed([_]u8{0x25} ** identity_mod.seed_len);
    const server_identity = try identity_mod.Identity.fromSeed([_]u8{0x26} ** identity_mod.seed_len);
    const server_static = noise.KeyPair.generate();

    var store = try pairedStore(allocator, store_path, server_identity, server_static.public_key);
    defer store.deinit();

    const client_auth: auth_mod.Authenticator = .{ .identity = client_identity, .trust = &store };
    const server_auth: auth_mod.Authenticator = .{ .identity = server_identity };

    var pipe = Pipe.init(allocator);
    defer pipe.deinit();

    var client_ctx = DeviceContext{
        .pipe = &pipe,
        .key = test_swarm_key,
        .allocator = allocator,
        .auth = &client_auth,
        .initiator = true,
        .static_key = noise.KeyPair.generate(),
    };
    var server_ctx = DeviceContext{
        .pipe = &pipe,
        .key = test_swarm_key,
        .allocator = allocator,
        .auth = &server_auth,
        .initiator = false,
        .static_key = server_static,
    };

    const client_thread = try std.Thread.spawn(.{}, DeviceContext.run, .{&client_ctx});
    server_ctx.run();
    client_thread.join();

    try std.testing.expect(server_ctx.failure == null);
    try std.testing.expect(client_ctx.failure == null);
    try std.testing.expect(server_ctx.remote.?.eql(client_identity.deviceId()));
    try std.testing.expect(client_ctx.remote.?.eql(server_identity.deviceId()));
}

test "security: a paired device cannot swap its transport key" {
    std.debug.print("\n=== Running Test: security: a paired device cannot swap its transport key ===\n", .{});
    const allocator = std.testing.allocator;
    const auth_mod = nomadfs.device.auth;
    const io = std.Io.Threaded.global_single_threaded.io();
    const store_path = "test_security_pin_mismatch.store";
    defer std.Io.Dir.cwd().deleteFile(io, store_path) catch {};

    const client_identity = try identity_mod.Identity.fromSeed([_]u8{0x27} ** identity_mod.seed_len);
    const server_identity = try identity_mod.Identity.fromSeed([_]u8{0x28} ** identity_mod.seed_len);

    // The store pins the server to a transport key it no longer presents.
    var store = try pairedStore(allocator, store_path, server_identity, [_]u8{0x99} ** 32);
    defer store.deinit();

    const client_auth: auth_mod.Authenticator = .{ .identity = client_identity, .trust = &store };
    const server_auth: auth_mod.Authenticator = .{ .identity = server_identity };

    var pipe = Pipe.init(allocator);
    defer pipe.deinit();

    var client_ctx = DeviceContext{
        .pipe = &pipe,
        .key = test_swarm_key,
        .allocator = allocator,
        .auth = &client_auth,
        .initiator = true,
    };
    var server_ctx = DeviceContext{
        .pipe = &pipe,
        .key = test_swarm_key,
        .allocator = allocator,
        .auth = &server_auth,
        .initiator = false,
    };

    const server_thread = try std.Thread.spawn(.{}, DeviceContext.run, .{&server_ctx});
    client_ctx.run();
    // The initiator aborts before message 3; unblock the responder.
    pipe.stop();
    server_thread.join();

    try std.testing.expectEqual(
        @as(?anyerror, auth_mod.Error.TransportKeyMismatch),
        client_ctx.failure,
    );
    try std.testing.expectEqual(@as(?anyerror, error.EndOfStream), server_ctx.failure);
    try std.testing.expect(client_ctx.remote == null);
}
