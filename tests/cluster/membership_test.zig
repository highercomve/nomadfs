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

fn ticketFor(identity: Identity, transport_byte: u8, label: []const u8) !Ticket {
    return Ticket.init(identity, [_]u8{transport_byte} ** 32, label, "192.168.1.5:4001", 1_800_000_000);
}

fn fresh(io: std.Io, path: []const u8) void {
    std.Io.Dir.cwd().deleteFile(io, path) catch {};
}

test "cluster: pairing with one member makes a device a member everywhere" {
    std.debug.print("\n=== Running Test: cluster: swarm membership spreads ===\n", .{});
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();

    const admin = try identityWith(0x91);
    const joiner = try identityWith(0x92);
    const phone = try identityWith(0x93);
    const laptop = try identityWith(0x94);
    const stranger = try identityWith(0x95);

    const a_path = "test_membership_admin.store";
    const b_path = "test_membership_joiner.store";
    fresh(io, a_path);
    fresh(io, b_path);
    defer fresh(io, a_path);
    defer fresh(io, b_path);

    // The admin knows the whole swarm; the joiner paired with the admin only,
    // and holds a revocation of the laptop newer than its admission.
    var store_a = try TrustStore.load(allocator, a_path, null);
    defer store_a.deinit();
    _ = try store_a.trustTicket(try ticketFor(phone, 0x21, "Phone"), 10);
    _ = try store_a.trustTicket(try ticketFor(laptop, 0x22, "Laptop"), 20);
    _ = try store_a.trustTicket(try ticketFor(joiner, 0x23, "Joiner"), 30);
    var store_b = try TrustStore.load(allocator, b_path, null);
    defer store_b.deinit();
    _ = try store_b.trustTicket(try ticketFor(admin, 0x24, "Admin"), 30);
    _ = try store_b.revokeDevice(laptop.deviceId(), admin.deviceId(), 25);

    var peer_a = try TestPeer.init(allocator, 13190);
    defer peer_a.deinit();
    var peer_b = try TestPeer.init(allocator, 13191);
    defer peer_b.deinit();
    defer peer_a.stop();
    defer peer_b.stop();

    var dht_a = DhtNode.init(allocator, peer_a.manager, peer_a.config.node.swarm_key);
    defer dht_a.deinit();
    var dht_b = DhtNode.init(allocator, peer_b.manager, peer_b.config.node.swarm_key);
    defer dht_b.deinit();
    dht_a.device_identity = admin;
    dht_a.trust_store = &store_a;
    dht_b.device_identity = joiner;
    dht_b.trust_store = &store_b;
    peer_a.manager.setConnectionHandler(&dht_a, DhtNode.serve);
    peer_b.manager.setConnectionHandler(&dht_b, DhtNode.serve);
    try peer_a.start();
    try peer_b.start();
    nomadfs.sync.sleep(100 * std.time.ns_per_ms);

    const conn = try peer_a.manager.connectToPeer(peer_b.listen_addr, peer_a.config.node.swarm_key, peer_b.manager.node_id);
    defer conn.deinit();

    // The joiner learns the phone with its label and pinned transport key;
    // the laptop stays out (revoked after it was admitted); the joiner's own
    // record is ignored.
    _ = try dht_a.pushAdmissions(conn);
    const got = store_b.lookup(phone.deviceId()) orelse return error.PhoneNotAdmitted;
    try std.testing.expectEqualStrings("Phone", got.labelSlice());
    try std.testing.expectEqual([_]u8{0x21} ** 32, got.transport_key);
    try std.testing.expectEqual(@as(u64, 10), got.added_at);
    try std.testing.expect(!store_b.isTrusted(laptop.deviceId()));
    try std.testing.expect(!store_b.isTrusted(joiner.deviceId()));
    try std.testing.expectEqual(@as(usize, 2), store_b.count());

    // Vouches from a device the joiner doesn't trust change nothing.
    dht_a.device_identity = stranger;
    _ = try store_a.trustTicket(try ticketFor(try identityWith(0x96), 0x25, "Tablet"), 40);
    _ = try dht_a.pushAdmissions(conn);
    try std.testing.expectEqual(@as(usize, 2), store_b.count());
}
