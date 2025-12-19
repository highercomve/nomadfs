const std = @import("std");
const network = @import("nomadfs").network;
const yamux = network.yamux;
const Pipe = @import("memory_stream.zig").Pipe;

test "yamux: multiple streams over single connection" {
    std.debug.print("\n=== Running Test: yamux: multiple streams over single connection ===\n", .{});
    const allocator = std.testing.allocator;

    // 1. Setup Pipe
    const pipe = Pipe.init(allocator);
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
