const std = @import("std");
const nomadfs = @import("nomadfs");
const Pipe = @import("memory_stream.zig").Pipe;

test "network: connection manager lifecycle (reaping)" {
    const allocator = std.testing.allocator;

    var manager = nomadfs.network.manager.ConnectionManager.initExplicit(allocator, .tcp, nomadfs.network.noise.KeyPair.generate());
    defer manager.deinit();

    manager.reap_interval_ms = 100;
    manager.idle_timeout = 1; // 1 second

    try manager.start();

    const pipe1 = Pipe.init(allocator);
    defer pipe1.deinit();
    const conn1 = pipe1.connection();

    try manager.addConnection(conn1);
    try std.testing.expectEqual(@as(usize, 1), manager.getConnectionsCount());

    // 1. Test reaping of closed connection
    pipe1.stop();

    // Wait for reaper
    var retries: usize = 0;
    while (manager.getConnectionsCount() > 0) {
        if (retries > 20) return error.TestTimeout;
        std.Thread.sleep(50 * std.time.ns_per_ms);
        retries += 1;
    }
    try std.testing.expectEqual(@as(usize, 0), manager.getConnectionsCount());

    // 2. Test reaping of idle connection
    const pipe2 = Pipe.init(allocator);
    defer pipe2.deinit();
    const conn2 = pipe2.connection();
    try manager.addConnection(conn2);
    try std.testing.expectEqual(@as(usize, 1), manager.getConnectionsCount());

    // Wait for idle timeout (1s)
    std.Thread.sleep(1500 * std.time.ns_per_ms);

    retries = 0;
    while (manager.getConnectionsCount() > 0) {
        if (retries > 20) return error.TestTimeout;
        std.Thread.sleep(50 * std.time.ns_per_ms);
        retries += 1;
    }
    try std.testing.expectEqual(@as(usize, 0), manager.getConnectionsCount());
}
