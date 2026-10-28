const std = @import("std");
const nomadfs = @import("nomadfs");
const noise = nomadfs.net.transport.noise;
const Pipe = @import("memory_stream.zig").Pipe;
const MemoryStream = @import("memory_stream.zig").MemoryStream;
const TestPeer = @import("test_helpers").TestPeer;

const Context = struct {
    pipe: *Pipe,
    initiator: bool,
    key: [32]u8,
    hash: ?[32]u8 = null,
    failure: ?anyerror = null,

    fn run(self: *Context) void {
        self.runInner() catch |err| {
            self.failure = err;
            self.pipe.stop();
        };
    }

    fn runInner(self: *Context) !void {
        var stream = try noise.NoiseStream.handshake(
            std.testing.allocator,
            if (self.initiator) self.pipe.client() else self.pipe.server(),
            &self.key,
            noise.KeyPair.generate(),
            self.initiator,
            null,
        );
        defer stream.deinit();
        self.hash = stream.handshake_hash;
        // Confirm both sides derived matching transport keys in both directions.
        var buf: [4]u8 = undefined;
        if (self.initiator) {
            _ = try stream.stream().write("ping");
            const n = try stream.stream().read(&buf);
            try std.testing.expectEqualStrings("pong", buf[0..n]);
        } else {
            const n = try stream.stream().read(&buf);
            try std.testing.expectEqualStrings("ping", buf[0..n]);
            _ = try stream.stream().write("pong");
        }
    }
};

test "noise v2: paired transcripts and wrong PSK rejection" {
    for ([_]bool{ false, true }) |wrong_psk| {
        var pipe = Pipe.init(std.testing.allocator);
        defer pipe.deinit();
        var client: Context = .{ .pipe = &pipe, .initiator = true, .key = .{0x41} ** 32 };
        var server: Context = .{ .pipe = &pipe, .initiator = false, .key = [_]u8{if (wrong_psk) 0x42 else 0x41} ** 32 };
        const thread = try std.Thread.spawn(.{}, Context.run, .{&client});
        server.run();
        thread.join();
        if (wrong_psk) {
            try std.testing.expectEqual(@as(?anyerror, error.AuthenticationFailed), server.failure);
            try std.testing.expect(server.hash == null);
        } else {
            try std.testing.expectEqual(@as(?anyerror, null), client.failure);
            try std.testing.expectEqual(@as(?anyerror, null), server.failure);
            try std.testing.expectEqualSlices(u8, &client.hash.?, &server.hash.?);
            try std.testing.expectEqual(@as(u16, 48), std.mem.readInt(u16, pipe.buffer_a_to_b.items[0..2], .big));
        }
    }
}

test "noise v2: framed legacy message 1 is rejected" {
    var wire = MemoryStream.init(std.testing.allocator);
    defer wire.deinit();
    _ = try wire.stream().write(&(.{ 0, 32 } ++ .{0} ** 32));
    try std.testing.expectError(error.HandshakeFailed, noise.NoiseStream.handshake(
        std.testing.allocator,
        wire.stream(),
        &(.{0x41} ** 32),
        noise.KeyPair.generate(),
        false,
        null,
    ));
}

test "noise v2: three loopback peers exchange encrypted streams" {
    // Dedicated ports for this test; there is no legacy or runtime version override.
    var a = try TestPeer.init(std.testing.allocator, 13470);
    defer a.deinit();
    var b = try TestPeer.init(std.testing.allocator, 13471);
    defer b.deinit();
    var c = try TestPeer.init(std.testing.allocator, 13472);
    defer c.deinit();
    try a.start();
    try b.start();
    try c.start();
    const ab = try b.connect(&a);
    defer ab.close();
    _ = try ab.write("v2 a-b");
    var attempts: usize = 0;
    while (a.manager.getConnectionsCount() < 1 and attempts < 40) : (attempts += 1) {
        nomadfs.sync.sleep(25 * std.time.ns_per_ms);
    }
    try std.testing.expectEqual(@as(usize, 1), a.manager.getConnectionsCount());
    const ac = try c.connect(&a);
    defer ac.close();
    _ = try ac.write("v2 a-c");
    attempts = 0;
    while (a.manager.getConnectionsCount() < 2 and attempts < 40) : (attempts += 1) {
        nomadfs.sync.sleep(25 * std.time.ns_per_ms);
    }
    try std.testing.expectEqual(@as(usize, 2), a.manager.getConnectionsCount());
    for ([_][]const u8{ "v2 a-b", "v2 a-c" }, 0..) |expected, index| {
        const conn = a.manager.getConnection(index).?;
        defer conn.deinit();
        const incoming = try conn.acceptStream();
        defer incoming.close();
        var buf: [16]u8 = undefined;
        const n = try incoming.read(&buf);
        try std.testing.expectEqualStrings(expected, buf[0..n]);
    }
}
