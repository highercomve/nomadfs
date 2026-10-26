const std = @import("std");
const nomadfs = @import("nomadfs");
const Pipe = @import("memory_stream.zig").Pipe;

test "network: connection manager lifecycle (reaping)" {
    const allocator = std.testing.allocator;

    var manager = nomadfs.net.transport.manager.ConnectionManager.initExplicit(allocator, .tcp, nomadfs.net.transport.noise.KeyPair.generate());
    defer manager.deinit();

    manager.reap_interval_ms = 100;
    manager.idle_timeout = 1; // 1 second

    try manager.start();

    var pipe1 = Pipe.init(allocator);
    // defer pipe1.deinit(); // Manager will reap and deinit this
    const conn1 = pipe1.connection();

    try manager.addConnection(conn1);
    try std.testing.expectEqual(@as(usize, 1), manager.getConnectionsCount());

    // 1. Test reaping of closed connection
    pipe1.stop();

    // Wait for reaper
    var retries: usize = 0;
    while (manager.getConnectionsCount() > 0) {
        if (retries > 20) return error.TestTimeout;
        nomadfs.sync.sleep(50 * std.time.ns_per_ms);
        retries += 1;
    }
    try std.testing.expectEqual(@as(usize, 0), manager.getConnectionsCount());

    // 2. Test reaping of idle connection
    var pipe2 = Pipe.init(allocator);
    // defer pipe2.deinit(); // Manager will reap and deinit this
    const conn2 = pipe2.connection();
    try manager.addConnection(conn2);
    try std.testing.expectEqual(@as(usize, 1), manager.getConnectionsCount());

    // Wait for idle timeout (1s)
    nomadfs.sync.sleep(1500 * std.time.ns_per_ms);

    retries = 0;
    while (manager.getConnectionsCount() > 0) {
        if (retries > 20) return error.TestTimeout;
        nomadfs.sync.sleep(50 * std.time.ns_per_ms);
        retries += 1;
    }
    try std.testing.expectEqual(@as(usize, 0), manager.getConnectionsCount());
}

test "network: failed registration leaves the connection with the caller" {
    const keypair = nomadfs.net.transport.noise.KeyPair.generate();

    // 1. Allocation failure while registering.
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    var manager = nomadfs.net.transport.manager.ConnectionManager.initExplicit(failing.allocator(), .tcp, keypair);
    defer manager.deinit();

    var pipe = Pipe.init(std.testing.allocator);
    defer pipe.deinit();

    try std.testing.expectError(error.OutOfMemory, manager.addConnection(pipe.connection()));
    try std.testing.expectEqual(@as(usize, 0), manager.getConnectionsCount());

    // 2. Registration after stop() is refused without consuming the connection.
    manager.stop();
    try std.testing.expectError(error.ManagerStopping, manager.addConnection(pipe.connection()));
    try std.testing.expectEqual(@as(usize, 0), manager.getConnectionsCount());
}

test "network: idle reaper keeps connections that are in use" {
    const allocator = std.testing.allocator;

    var manager = nomadfs.net.transport.manager.ConnectionManager.initExplicit(allocator, .tcp, nomadfs.net.transport.noise.KeyPair.generate());
    defer manager.deinit();
    manager.reap_interval_ms = 100;
    manager.idle_timeout = 1; // 1 second
    try manager.start();

    var pipe = Pipe.init(allocator);
    pipe.setInUse(true);
    try manager.addConnection(pipe.connection());

    // Well past the idle timeout, but still in use: must survive.
    nomadfs.sync.sleep(2500 * std.time.ns_per_ms);
    try std.testing.expectEqual(@as(usize, 1), manager.getConnectionsCount());

    // Once released, it becomes idle and is reaped (manager deinits the pipe).
    pipe.setInUse(false);
    var retries: usize = 0;
    while (manager.getConnectionsCount() > 0) {
        if (retries > 60) return error.TestTimeout;
        nomadfs.sync.sleep(50 * std.time.ns_per_ms);
        retries += 1;
    }
}
