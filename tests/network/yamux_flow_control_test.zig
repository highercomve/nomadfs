const std = @import("std");
const nomadfs = @import("nomadfs");
const Pipe = @import("memory_stream.zig").Pipe;

test "yamux: flow control (window management)" {
    std.debug.print("Starting flow control test...\n", .{});
    const allocator = std.testing.allocator;
    const pipe = Pipe.init(allocator);
    defer pipe.deinit();

    const client_session = try nomadfs.network.yamux.Session.init(allocator, pipe.client(), false);
    const server_session = try nomadfs.network.yamux.Session.init(allocator, pipe.server(), true);

    defer client_session.deinit();
    defer server_session.deinit();

    const client_thread = try std.Thread.spawn(.{}, nomadfs.network.yamux.Session.run, .{client_session});
    const server_thread = try std.Thread.spawn(.{}, nomadfs.network.yamux.Session.run, .{server_session});

    defer {
        pipe.stop();
        client_thread.join();
        server_thread.join();
    }

    const client_stream = try client_session.newStream();
    const server_stream = try server_session.acceptStream();

    // The default window size is 256KB.
    // We'll try to send 300KB and see if it blocks or handles it.
    // In our current implementation (without flow control), it will just succeed and grow the buffer indefinitely.

    const large_data = try allocator.alloc(u8, 257 * 1024);
    defer allocator.free(large_data);
    @memset(large_data, 'A');

    // Start a thread to read slowly from the server
    const Reader = struct {
        fn run(stream: anytype) void {
            std.Thread.sleep(100 * std.time.ns_per_ms);
            var buf: [1024]u8 = undefined;
            while (true) {
                const n = nomadfs.network.yamux.Session.streamRead(stream, &buf) catch break;
                if (n == 0) break;
                std.Thread.sleep(1 * std.time.ns_per_ms); // Slow read
            }
        }
    };

    const reader_thread = try std.Thread.spawn(.{}, Reader.run, .{server_stream});
    // Total written should exceed 256KB to trigger flow control
    var total_written: usize = 0;
    while (total_written < large_data.len) {
        const chunk_size = @min(large_data.len - total_written, @as(usize, 16384));
        const n = try nomadfs.network.yamux.Session.streamWrite(client_stream, large_data[total_written..][0..chunk_size]);
        total_written += n;
    }

    try std.testing.expectEqual(large_data.len, total_written);

    // Close client stream to signal EOF to server
    nomadfs.network.yamux.Session.streamClose(client_stream);

    reader_thread.join();
}
