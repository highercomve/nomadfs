const std = @import("std");
const nomadfs = @import("nomadfs");
const TestPeer = @import("test_helpers").TestPeer;
const Identity = nomadfs.device.identity.Identity;
const Ticket = nomadfs.device.pairing.Ticket;
const invite = nomadfs.device.invite;

const EchoIdentity = struct {
    fn serve(_: *@This(), conn: nomadfs.net.transport.Connection) anyerror!void {
        const stream = try conn.acceptStream();
        defer stream.close();
        const remote = conn.getRemoteDeviceID() orelse return error.MissingIdentity;
        try stream.writer().writeAll(&remote.bytes);
    }
};

test "cluster: invite identities and transport rotation resist stale ticket rollback" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const now: u64 = @intCast(@divFloor(std.Io.Clock.real.now(io).nanoseconds, std.time.ns_per_s));
    const a = Identity.generate();
    const b = Identity.generate();
    const key = [_]u8{0x5b} ** 32;
    var peer_a = try TestPeer.init(allocator, 13241);
    defer peer_a.deinit();
    var peer_b = try TestPeer.init(allocator, 13242);
    defer peer_b.deinit();
    peer_a.config.node.swarm_key = &key;
    peer_b.config.node.swarm_key = &key;
    const a_ticket = try Ticket.init(a, peer_a.manager.identity_key.public_key, "a", "127.0.0.1:13241", now + 86400);
    const b_old = try Ticket.init(b, peer_b.manager.identity_key.public_key, "b", "127.0.0.1:13242", now + 86400);
    var a_buf: [nomadfs.device.pairing.max_uri_len]u8 = undefined;
    var b_buf: [nomadfs.device.pairing.max_uri_len]u8 = undefined;
    const host = try invite.Host.start(allocator, .{ .identity = a, .swarm_key = key, .node_port = 13241, .ticket_uri = try a_ticket.toUri(&a_buf) }, 13240, 60, now);
    defer host.destroy();
    var code_buf: [128]u8 = undefined;
    var joined = try invite.join(allocator, try host.code("127.0.0.1", &code_buf), try b_old.toUri(&b_buf), b);
    defer joined.deinit(allocator);
    try std.testing.expect((try Ticket.parse(joined.ticket_uri)).deviceId().eql(a.deviceId()));
    try std.testing.expectEqualSlices(u8, &key, &joined.swarm_key);
    const seen = (try host.joinedTicket(allocator)).?;
    defer allocator.free(seen);
    try std.testing.expect((try Ticket.parse(seen)).deviceId().eql(b.deviceId()));

    const path = "test_cluster_tickets.store";
    std.Io.Dir.cwd().deleteFile(io, path) catch {};
    defer std.Io.Dir.cwd().deleteFile(io, path) catch {};
    var store = try nomadfs.device.trust.Store.load(allocator, path, null);
    defer store.deinit();
    _ = try store.trustTicket(try Ticket.parse(seen), now);
    // Rotate B's actual transport key before its normal node listener starts.
    peer_b.manager.identity_key = nomadfs.net.transport.noise.KeyPair.generate();
    peer_b.manager.node_id = nomadfs.net.id.NodeID.fromPublicKey(peer_b.manager.identity_key.public_key);
    const b_new = try Ticket.init(b, peer_b.manager.identity_key.public_key, "b", "127.0.0.1:13242", now + 86401);
    _ = try store.trustTicket(b_new, now + 1);
    try std.testing.expectError(error.StaleTicket, store.trustTicket(b_old, now + 2));
    peer_a.manager.setDeviceAuthenticator(.{ .identity = a, .trust = &store, .require_trusted = true });
    peer_b.manager.setDeviceAuthenticator(.{ .identity = b });
    var handler = EchoIdentity{};
    peer_a.manager.setConnectionHandler(&handler, EchoIdentity.serve);
    try peer_a.start();
    defer peer_a.stop();
    const conn = try peer_b.manager.connectToPeer(peer_a.listen_addr, &joined.swarm_key, peer_a.manager.node_id);
    defer conn.deinit();
    try std.testing.expect(conn.getRemoteDeviceID().?.eql(a.deviceId()));
    const stream = try conn.openStream();
    defer stream.close();
    stream.setTimeout(5000);
    var remote: [32]u8 = undefined;
    try stream.reader().readNoEof(&remote);
    try std.testing.expectEqualSlices(u8, &b.deviceId().bytes, &remote);
}
