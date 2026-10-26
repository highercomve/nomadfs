const std = @import("std");
const nomadfs = @import("nomadfs");
const TestPeer = @import("test_helpers").TestPeer;
const DhtNode = nomadfs.net.discovery.Node;
const Identity = nomadfs.device.identity.Identity;
const TrustStore = nomadfs.device.trust.Store;
const Ticket = nomadfs.device.pairing.Ticket;

fn identityWith(seed_byte: u8) !Identity {
    return Identity.fromSeed([_]u8{seed_byte} ** nomadfs.device.identity.seed_len);
}

/// A ticket the receiver would have accepted during pairing.
fn ticketFor(identity: Identity, label: []const u8) !Ticket {
    return Ticket.init(identity, [_]u8{0x11} ** 32, label, "192.168.1.5:4001", 1_800_000_000);
}

test "cluster: revocations require a verified signature from a trusted device" {
    std.debug.print("\n=== Running Test: cluster: revocation propagation ===\n", .{});
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();

    const admin = try identityWith(0x81);
    const phone = try identityWith(0x82);
    const stranger = try identityWith(0x83);

    const store_path = "test_revocation.store";
    std.Io.Dir.cwd().deleteFile(io, store_path) catch {};
    defer std.Io.Dir.cwd().deleteFile(io, store_path) catch {};

    var receiver_store = try TrustStore.load(allocator, store_path);
    defer receiver_store.deinit();
    _ = try receiver_store.trustTicket(try ticketFor(admin, "admin"), 1);
    _ = try receiver_store.trustTicket(try ticketFor(phone, "phone"), 2);
    try std.testing.expect(receiver_store.isTrusted(phone.deviceId()));

    var peer_admin = try TestPeer.init(allocator, 13120);
    defer peer_admin.deinit();
    var peer_receiver = try TestPeer.init(allocator, 13121);
    defer peer_receiver.deinit();
    // The DHT nodes must outlive the peers' serve loops; stop networking
    // before tearing them down.
    defer peer_admin.stop();
    defer peer_receiver.stop();

    var dht_admin = DhtNode.init(allocator, peer_admin.manager, peer_admin.config.node.swarm_key);
    defer dht_admin.deinit();
    var dht_receiver = DhtNode.init(allocator, peer_receiver.manager, peer_receiver.config.node.swarm_key);
    defer dht_receiver.deinit();
    dht_admin.device_identity = admin;
    dht_receiver.trust_store = &receiver_store;
    peer_admin.manager.setConnectionHandler(&dht_admin, DhtNode.serve);
    peer_receiver.manager.setConnectionHandler(&dht_receiver, DhtNode.serve);

    try peer_admin.start();
    try peer_receiver.start();
    nomadfs.sync.sleep(100 * std.time.ns_per_ms);

    {
        const conn = try peer_admin.manager.connectToPeer(
            peer_receiver.listen_addr,
            peer_admin.config.node.swarm_key,
            peer_receiver.manager.node_id,
        );
        defer conn.deinit();

        // A trusted device's signed revocation takes the entry out.
        try std.testing.expect(try dht_admin.sendRevoke(conn, phone.deviceId()));
        try std.testing.expect(receiver_store.isRevoked(phone.deviceId()));
        try std.testing.expect(!receiver_store.isTrusted(phone.deviceId()));

        // Without a trust store on the receiving side, nothing is honored.
        dht_receiver.trust_store = null;
        try std.testing.expect(!try dht_admin.sendRevoke(conn, admin.deviceId()));
    }

    // Restore the receiver's store; now present revocations signed by a
    // device that is not trusted here - the signature is valid, but the
    // signer has no standing and nothing changes.
    dht_receiver.trust_store = &receiver_store;
    const entries_before = receiver_store.count();
    {
        const conn = try peer_admin.manager.connectToPeer(
            peer_receiver.listen_addr,
            peer_admin.config.node.swarm_key,
            peer_receiver.manager.node_id,
        );
        defer conn.deinit();

        dht_admin.device_identity = stranger;
        try std.testing.expect(!try dht_admin.sendRevoke(conn, phone.deviceId()));
        try std.testing.expectEqual(entries_before, receiver_store.count());

        // The revoked device cannot order its own removal either.
        dht_admin.device_identity = phone;
        try std.testing.expect(!try dht_admin.sendRevoke(conn, phone.deviceId()));
        try std.testing.expectEqual(entries_before, receiver_store.count());
        try std.testing.expect(receiver_store.isRevoked(phone.deviceId()));
    }
}
