const std = @import("std");
const nomadfs = @import("nomadfs");
const network = nomadfs.net.transport;
const yamux = network.yamux;
const Pipe = @import("memory_stream.zig").Pipe;

test "yamux: multiple streams over single connection" {
    std.debug.print("\n=== Running Test: yamux: multiple streams over single connection ===\n", .{});
    const allocator = std.testing.allocator;

    // 1. Setup Pipe
    var pipe = Pipe.init(allocator);
    defer pipe.deinit();

    // 2. Setup Sessions
    // Server Session
    // We pass pipe.server() which returns a Stream interface
    const server_session = try yamux.Session.init(allocator, pipe.server(), true);
    // server_session must be destroyed after threads join to ensure no UAF,
    // but threads use session.
    // Session.run uses session.
    // So we deinit after join.
    defer server_session.deinit();

    // Client Session
    const client_session = try yamux.Session.init(allocator, pipe.client(), false);
    defer client_session.deinit();

    // 3. Start Session Runners
    const server_thread = try std.Thread.spawn(.{}, yamux.Session.run, .{server_session});
    const client_thread = try std.Thread.spawn(.{}, yamux.Session.run, .{client_session});

    // 4. Open Streams (Client Side)
    const client_stream1 = try client_session.newStream();
    const client_stream2 = try client_session.newStream();

    // 5. Write Data
    const msg1 = "Stream 1 Data";
    const msg2 = "Stream 2 Data";

    // streamWrite takes *anyopaque, so we cast our *YamuxStream
    _ = try yamux.Session.streamWrite(client_stream1, msg1);
    _ = try yamux.Session.streamWrite(client_stream2, msg2);

    // 6. Accept Streams (Server Side)
    // Server accepts streams initiated by client
    const server_stream1 = try server_session.acceptStream();
    const server_stream2 = try server_session.acceptStream();

    // 7. Verify IDs
    // Client (is_server=false) creates streams 1, 3, 5...
    try std.testing.expectEqual(@as(u32, 1), client_stream1.id);
    try std.testing.expectEqual(@as(u32, 3), client_stream2.id);

    // Identify which server stream is which
    var s1_server: *yamux.YamuxStream = undefined;
    var s2_server: *yamux.YamuxStream = undefined;

    if (server_stream1.id == 1) {
        s1_server = server_stream1;
        s2_server = server_stream2;
    } else {
        s1_server = server_stream2;
        s2_server = server_stream1;
    }

    try std.testing.expectEqual(@as(u32, 1), s1_server.id);
    try std.testing.expectEqual(@as(u32, 3), s2_server.id);

    // 8. Read and Verify Data
    var buf1: [100]u8 = undefined;
    const n1 = try yamux.Session.streamRead(s1_server, &buf1);
    try std.testing.expectEqualStrings(msg1, buf1[0..n1]);

    var buf2: [100]u8 = undefined;
    const n2 = try yamux.Session.streamRead(s2_server, &buf2);
    try std.testing.expectEqualStrings(msg2, buf2[0..n2]);

    // 9. Cleanup
    // Close the pipe to signal EOF to Session.run loops
    // We can use the stream interface from one of the sessions to close it.
    // client_session.transport is a Stream.
    client_session.transport.close();

    // Wait for threads to finish
    server_thread.join();
    client_thread.join();
}

fn writeRawFrame(stream: nomadfs.net.transport.Stream, header: yamux.Header) !void {
    var buf: [12]u8 = undefined;
    header.encode(&buf);
    _ = try stream.write(&buf);
}

fn liveStreamCount(session: *yamux.Session) usize {
    session.mutex.lock();
    defer session.mutex.unlock();
    return session.streams.count();
}

/// The reader thread frees a closed stream only after the peer's FIN
/// arrives. Await (bounded) that drain so a round that is safe by protocol
/// does not fail on timing.
fn awaitFreeSlot(session: *yamux.Session) !void {
    var retries: usize = 0;
    while (liveStreamCount(session) >= yamux.MaxStreams) {
        if (retries >= 200) return error.TestTimeout;
        nomadfs.sync.sleep(5 * std.time.ns_per_ms);
        retries += 1;
    }
}

test "yamux: invalid frame type closes the session instead of panicking" {
    const allocator = std.testing.allocator;
    var pipe = Pipe.init(allocator);
    defer pipe.deinit();

    const server_session = try yamux.Session.init(allocator, pipe.server(), true);
    defer server_session.deinit();
    const server_thread = try std.Thread.spawn(.{}, yamux.Session.run, .{server_session});

    // Type byte 0x7f is not a valid yamux frame type.
    _ = try pipe.client().write(&[_]u8{ 0, 0x7f, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0 });

    server_thread.join();
    try std.testing.expect(server_session.isClosed());
}

test "yamux: frame larger than the receive window is rejected before allocating" {
    const allocator = std.testing.allocator;
    var pipe = Pipe.init(allocator);
    defer pipe.deinit();

    const server_session = try yamux.Session.init(allocator, pipe.server(), true);
    defer server_session.deinit();
    const server_thread = try std.Thread.spawn(.{}, yamux.Session.run, .{server_session});

    // Advertise a 4 GiB payload on a new stream. The session must fail the
    // window check instead of allocating or waiting for the payload.
    try writeRawFrame(pipe.client(), .{
        .type = .DATA,
        .flags = yamux.Flags.SYN,
        .stream_id = 1,
        .length = std.math.maxInt(u32),
    });

    server_thread.join();
    try std.testing.expect(server_session.isClosed());
}

test "yamux: incoming streams beyond MaxStreams are reset" {
    const allocator = std.testing.allocator;
    var pipe = Pipe.init(allocator);
    defer pipe.deinit();

    const server_session = try yamux.Session.init(allocator, pipe.server(), true);
    defer server_session.deinit();
    const server_thread = try std.Thread.spawn(.{}, yamux.Session.run, .{server_session});
    defer {
        pipe.stop();
        server_thread.join();
    }

    var i: u32 = 0;
    while (i <= yamux.MaxStreams) : (i += 1) {
        try writeRawFrame(pipe.client(), .{
            .type = .DATA,
            .flags = yamux.Flags.SYN,
            .stream_id = 2 * i + 1,
            .length = 0,
        });
    }

    // The only frame the server sends back is the RST for the extra stream.
    var buf: [12]u8 = undefined;
    var got: usize = 0;
    while (got < buf.len) got += try pipe.client().read(buf[got..]);
    const reply = try yamux.Header.decode(buf);
    try std.testing.expectEqual(yamux.Type.WINDOW_UPDATE, reply.type);
    try std.testing.expect(reply.flags & yamux.Flags.RST != 0);
    try std.testing.expectEqual(2 * yamux.MaxStreams + 1, reply.stream_id);
    try std.testing.expectEqual(@as(usize, yamux.MaxStreams), liveStreamCount(server_session));
}

test "yamux: streams are freed once both sides close" {
    const allocator = std.testing.allocator;
    var pipe = Pipe.init(allocator);
    defer pipe.deinit();

    const server_session = try yamux.Session.init(allocator, pipe.server(), true);
    defer server_session.deinit();
    const client_session = try yamux.Session.init(allocator, pipe.client(), false);
    defer client_session.deinit();

    const server_thread = try std.Thread.spawn(.{}, yamux.Session.run, .{server_session});
    const client_thread = try std.Thread.spawn(.{}, yamux.Session.run, .{client_session});
    defer {
        pipe.stop();
        server_thread.join();
        client_thread.join();
    }

    var round: usize = 0;
    while (round < 3 * yamux.MaxStreams) : (round += 1) {
        try awaitFreeSlot(client_session);
        const client_stream = try client_session.newStream();
        _ = try yamux.Session.streamWrite(client_stream, "ping");
        const server_stream = try server_session.acceptStream();

        var buf: [8]u8 = undefined;
        const n = try yamux.Session.streamRead(server_stream, &buf);
        try std.testing.expectEqualStrings("ping", buf[0..n]);

        yamux.Session.streamClose(client_stream);
        yamux.Session.streamClose(server_stream);
    }

    // Without reaping, opening 3 * MaxStreams streams would have failed.
    var retries: usize = 0;
    while (liveStreamCount(server_session) + liveStreamCount(client_session) > 0) {
        if (retries > 100) return error.TestTimeout;
        nomadfs.sync.sleep(10 * std.time.ns_per_ms);
        retries += 1;
    }
}

test "yamux: reads honour the stream deadline" {
    const allocator = std.testing.allocator;
    var pipe = Pipe.init(allocator);
    defer pipe.deinit();

    const server_session = try yamux.Session.init(allocator, pipe.server(), true);
    defer server_session.deinit();
    const client_session = try yamux.Session.init(allocator, pipe.client(), false);
    defer client_session.deinit();
    const server_thread = try std.Thread.spawn(.{}, yamux.Session.run, .{server_session});
    const client_thread = try std.Thread.spawn(.{}, yamux.Session.run, .{client_session});
    defer {
        pipe.stop();
        server_thread.join();
        client_thread.join();
    }

    const client_stream = try client_session.newStream();
    defer yamux.Session.streamClose(client_stream);
    yamux.Session.streamSetTimeout(client_stream, 100);

    // The peer never writes: the read must give up instead of blocking.
    var buf: [8]u8 = undefined;
    const started = nomadfs.sync.monotonicMillis();
    try std.testing.expectError(error.Timeout, yamux.Session.streamRead(client_stream, &buf));
    try std.testing.expect(nomadfs.sync.monotonicMillis() - started < 2000);
}
