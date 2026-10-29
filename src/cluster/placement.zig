//! Which devices keep a copy of a swarm folder file, besides its author and
//! the swarm backup devices: the `copies - 1` members that accept copies
//! with the highest rendezvous score `blake2s(root ‖ node id)`.
//!
//! It depends only on the trust store (membership), the signed policy
//! (`copies`, who accepts) and the file, never on what a device happened to
//! hear, so every device computes the same holders without asking. Adding or
//! removing a member moves only the files it wins or held.

const std = @import("std");
const NodeID = @import("../net/id.zig").NodeID;
const trust_mod = @import("../device/trust.zig");
const policy_mod = @import("../device/policy.zig");

pub const Cid = [32]u8;

fn score(root: *const Cid, id: NodeID) [32]u8 {
    var h = std.crypto.hash.blake2.Blake2s256.init(.{});
    h.update(root);
    h.update(&id.bytes);
    var out: [32]u8 = undefined;
    h.final(&out);
    return out;
}

fn listed(ids: []const NodeID, id: NodeID) bool {
    for (ids) |x| if (x.eql(id)) return true;
    return false;
}

/// The replica holders of `root` among `members`, best first, at most
/// `copies - 1` and never the author; written to `out` (which bounds them).
pub fn replicaHolders(root: *const Cid, author: NodeID, copies: u8, members: []const NodeID, out: []NodeID) []NodeID {
    const want = @min(@as(usize, copies) -| 1, out.len);
    var scores: [policy_mod.max_copies][32]u8 = undefined;
    var n: usize = 0;
    for (members) |c| {
        if (c.eql(author)) continue;
        if (listed(out[0..n], c)) continue; // listed twice
        const s = score(root, c);
        // Insertion into the top `want`, highest score first.
        var i: usize = n;
        while (i > 0 and std.mem.order(u8, &s, &scores[i - 1]) == .gt) : (i -= 1) {}
        if (i >= want) continue;
        var j: usize = @min(n, want - 1);
        while (j > i) : (j -= 1) {
            out[j] = out[j - 1];
            scores[j] = scores[j - 1];
        }
        out[i] = c;
        scores[i] = s;
        n = @min(n + 1, want);
    }
    return out[0..n];
}

/// The members placement chooses from: this device (when it accepts copies)
/// and every trusted member with a transport key that accepts copies, as
/// transport node IDs. Caller frees.
pub fn candidates(allocator: std.mem.Allocator, trust: *trust_mod.Store, policy: *policy_mod.Policy, self_node: NodeID, self_device: NodeID) ![]NodeID {
    const entries = try trust.copyEntries(allocator);
    defer allocator.free(entries);
    var out: std.ArrayList(NodeID) = .empty;
    errdefer out.deinit(allocator);
    if (policy.acceptsCopies(self_device)) try out.append(allocator, self_node);
    for (entries) |e| {
        if (std.mem.eql(u8, &e.transport_key, &trust_mod.no_transport_key)) continue;
        if (!policy.acceptsCopies(e.device_id)) continue;
        try out.append(allocator, NodeID.fromPublicKey(e.transport_key));
    }
    return out.toOwnedSlice(allocator);
}

// ---- Tests ----

const testing = std.testing;

fn node(b: u8) NodeID {
    return .{ .bytes = [_]u8{b} ** 32 };
}

test "placement: the same holders whatever the order, never the author, bounded" {
    const root = [_]u8{0xAB} ** 32;
    const a = [_]NodeID{ node(1), node(2), node(3), node(4), node(5) };
    const b = [_]NodeID{ node(5), node(3), node(1), node(4), node(2), node(3) };
    var out1: [8]NodeID = undefined;
    var out2: [8]NodeID = undefined;
    const h1 = replicaHolders(&root, node(2), 3, &a, &out1);
    const h2 = replicaHolders(&root, node(2), 3, &b, &out2);
    try testing.expectEqual(@as(usize, 2), h1.len);
    try testing.expectEqualSlices(NodeID, h1, h2);
    for (h1) |h| try testing.expect(!h.eql(node(2)));
    try testing.expect(!h1[0].eql(h1[1]));
    // copies = 1: nobody besides the author.
    try testing.expectEqual(@as(usize, 0), replicaHolders(&root, node(2), 1, &a, &out1).len);
    // More copies than members: everyone but the author.
    try testing.expectEqual(@as(usize, 4), replicaHolders(&root, node(2), 8, &a, &out1).len);
}

test "placement: a new member takes over only the files it wins" {
    const before = [_]NodeID{ node(1), node(2), node(3), node(4) };
    const after = [_]NodeID{ node(1), node(2), node(3), node(4), node(9) };
    var moved: usize = 0;
    const files = 400;
    for (0..files) |i| {
        var root: Cid = [_]u8{0} ** 32;
        std.mem.writeInt(u32, root[0..4], @intCast(i), .little);
        var o1: [8]NodeID = undefined;
        var o2: [8]NodeID = undefined;
        const h1 = replicaHolders(&root, node(1), 2, &before, &o1);
        const h2 = replicaHolders(&root, node(1), 2, &after, &o2);
        if (!h1[0].eql(h2[0])) {
            moved += 1;
            try testing.expect(h2[0].eql(node(9))); // only to the newcomer
        }
    }
    // About a quarter of the files (1 of 4 candidates besides the author).
    try testing.expect(moved > files / 8 and moved < files / 2);
}
