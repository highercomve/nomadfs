//! Browsing another device's shares. A Remote is a tree.Loader that serves
//! blocks from the local store and fetches missing ones from the device on
//! first use, verifying each against its CID before keeping it. The local
//! store is therefore the cache: a file read once reads offline afterwards.

const std = @import("std");
const cluster = @import("../cluster/mod.zig");
const fetcher_mod = @import("../cluster/fetcher.zig");
const NodeID = @import("../net/id.zig").NodeID;
const storage = @import("../storage/mod.zig");
const sync = @import("../sync.zig");
const tree = @import("tree.zig");
const readahead_mod = @import("readahead.zig");
const device_trust = @import("../device/trust.zig");
const device_names = @import("device_names.zig");

/// A tree.Loader over the cluster layer's fetcher (cluster/fetcher.zig):
/// the blocks of the file `root` from `holders`, best first. This module
/// says which file and who may hold it; the fetcher says where each block
/// comes from. Without a block manager (a mount device never connected)
/// every load fails at once with error.PeerDown.
pub const Source = struct {
    block_manager: ?*cluster.BlockManager,
    /// The file being read; misses are remembered per file. Null: each
    /// block counts as its own file.
    root: ?tree.Cid = null,
    holders: []const NodeID,

    pub fn loader(self: *Source) tree.Loader {
        return .{ .ctx = self, .loadFn = load };
    }

    fn load(ctx: *anyopaque, cid: *const tree.Cid, allocator: std.mem.Allocator) anyerror![]u8 {
        const self: *Source = @ptrCast(@alignCast(ctx));
        return fetchFrom(self.block_manager, self.root, cid, self.holders, allocator);
    }
};

fn fetchFrom(block_manager: ?*cluster.BlockManager, root: ?tree.Cid, cid: *const tree.Cid, holders: []const NodeID, allocator: std.mem.Allocator) ![]u8 {
    const bm = block_manager orelse return error.PeerDown;
    const fetcher = &(bm.fetcher orelse return error.StorageDisabled);
    return fetcher.fetch(&(root orelse cid.*), cid, holders, allocator);
}

/// Another device: its shares (GET_SHARES, meaning, so it is asked here),
/// and a loader for its blocks, through the fetcher.
pub const Remote = struct {
    block_manager: ?*cluster.BlockManager,
    peer: NodeID,
    /// The file being read, when known: the fetcher remembers misses per
    /// file.
    root: ?tree.Cid = null,

    pub fn loader(self: *Remote) tree.Loader {
        return .{ .ctx = self, .loadFn = load };
    }

    fn load(ctx: *anyopaque, cid: *const tree.Cid, allocator: std.mem.Allocator) anyerror![]u8 {
        const self: *Remote = @ptrCast(@alignCast(ctx));
        return fetchFrom(self.block_manager, self.root, cid, (&self.peer)[0..1], allocator);
    }

    pub const Shares = struct {
        nickname: []u8,
        listing: tree.Listing,
        device_id: ?NodeID = null,

        pub fn deinit(self: Shares, allocator: std.mem.Allocator) void {
            allocator.free(self.nickname);
            self.listing.deinit();
        }
    };

    /// The device's nickname and current shares (each entry's cid is that
    /// share's root dir).
    pub fn shares(self: *Remote, allocator: std.mem.Allocator) !Shares {
        const bm = self.block_manager orelse return error.PeerDown;
        const reply = try bm.shares(allocator, self.peer);
        defer allocator.free(reply.listing);
        errdefer allocator.free(reply.nickname);
        return .{
            .nickname = reply.nickname,
            .listing = try tree.decodeListing(allocator, reply.listing),
            .device_id = reply.device_id,
        };
    }
};

/// A holder list the size of the fetcher's, ready to fill.
pub fn holdersBuffer() [fetcher_mod.max_holders]NodeID {
    return [_]NodeID{.{ .bytes = [_]u8{0} ** 32 }} ** fetcher_mod.max_holders;
}

/// The likely holders of a share's files (cluster/holders.zig): the
/// sharing device, then devices noted as keeping copies of its owner's
/// folders; never empty (the peer alone when there's nothing noted, when
/// the peer is not this node).
pub fn holderListFor(block_manager: *cluster.BlockManager, peer: NodeID, out: *[fetcher_mod.max_holders]NodeID) []const NodeID {
    if (block_manager.holders) |*holds| {
        const list = holds.forOrigin(peer, out);
        if (list.len > 0) return list;
    }
    out[0] = peer;
    return out[0..1];
}

/// Reads part of a share's file from its likely holders: the sharing
/// device, then the devices the holder registry says keep copies of its
/// owner's folders (cluster/holders.zig); through a read-ahead when one is
/// attached. Directory listings stay with the sharing device (Remote).
pub fn readShareAt(
    allocator: std.mem.Allocator,
    block_manager: *cluster.BlockManager,
    read_ahead: ?*readahead_mod.ReadAhead,
    peer: NodeID,
    root: tree.Cid,
    offset: u64,
    dest: []u8,
) !usize {
    var buffer = holdersBuffer();
    const holders = holderListFor(block_manager, peer, &buffer);
    if (read_ahead) |ra| return ra.readAt(allocator, holders, root, offset, dest);
    var source = Source{ .block_manager = block_manager, .root = root, .holders = holders };
    return tree.readAt(allocator, source.loader(), root, offset, dest);
}

pub const Probed = struct {
    peer: NodeID,
    /// Null when the device didn't answer.
    shares: ?Remote.Shares = null,
};

/// Devices asked at once by sharesOfAll.
pub const max_parallel_probes = 16;

/// Asks every peer what it shares, all at once (in rounds of
/// max_parallel_probes threads), so devices that don't answer cost one
/// timeout in all instead of one each. `allocator` must be thread-safe;
/// free each `shares` with its deinit, and the slice.
pub fn sharesOfAll(allocator: std.mem.Allocator, block_manager: *cluster.BlockManager, peers: []const NodeID) ![]Probed {
    const out = try allocator.alloc(Probed, peers.len);
    for (peers, out) |p, *o| o.* = .{ .peer = p };
    const Probe = struct {
        fn run(a: std.mem.Allocator, bm: *cluster.BlockManager, slot: *Probed) void {
            var remote = Remote{ .block_manager = bm, .peer = slot.peer };
            slot.shares = remote.shares(a) catch |err| blk: {
                std.debug.print("shares: {x} unavailable: {any}\n", .{ slot.peer.bytes[0..4], err });
                break :blk null;
            };
        }
    };
    var start: usize = 0;
    while (start < out.len) : (start += max_parallel_probes) {
        const round = out[start..@min(out.len, start + max_parallel_probes)];
        var threads: [max_parallel_probes]?std.Thread = @splat(null);
        for (round, 0..) |*slot, i| {
            threads[i] = std.Thread.spawn(.{}, Probe.run, .{ allocator, block_manager, slot }) catch blk: {
                Probe.run(allocator, block_manager, slot); // no thread: ask inline
                break :blk null;
            };
        }
        for (threads[0..round.len]) |t| if (t) |th| th.join();
    }
    return out;
}

/// Every peer the routing table knows (caller frees).
pub fn knownPeers(block_manager: *cluster.BlockManager, allocator: std.mem.Allocator) ![]NodeID {
    return block_manager.knownPeers(allocator);
}


pub const DeviceShare = struct {
    name: []const u8,
    cid: [32]u8,
    size: u64,
    mtime: u64,
};

pub const Device = struct {
    peer: NodeID,
    device_id: ?NodeID,
    nickname: []const u8,
    shares: []DeviceShare,
    trusted: bool,
    label: []const u8,
    mount_name: []const u8,

    /// Its authenticated identity's fingerprint ("aaaa-bbbb-cccc-dddd",
    /// as the device list shows it), or "" when it presented none.
    pub fn fingerprint(self: *const Device, buf: *[19]u8) []const u8 {
        const did = self.device_id orelse return "";
        return @import("../device/identity.zig").Identity.formatFingerprint(did.bytes[0..8].*, buf);
    }

    pub fn deinit(self: Device, allocator: std.mem.Allocator) void {
        allocator.free(self.nickname);
        allocator.free(self.label);
        allocator.free(self.mount_name);
        for (self.shares) |s| allocator.free(s.name);
        allocator.free(self.shares);
    }
};

pub fn deinitDevices(allocator: std.mem.Allocator, list: []Device) void {
    for (list) |d| d.deinit(allocator);
    allocator.free(list);
}

/// Discovers reachable peers, asks what they share in parallel, looks up their
/// trust status, and assigns collision-free mount folder names.
pub fn devices(
    allocator: std.mem.Allocator,
    block_manager: *cluster.BlockManager,
    trust_store: ?*device_trust.Store,
) ![]Device {
    const peers = try knownPeers(block_manager, allocator);
    defer allocator.free(peers);

    const probe_alloc = std.heap.smp_allocator;
    const probed = try sharesOfAll(probe_alloc, block_manager, peers);
    defer {
        for (probed) |p| if (p.shares) |sh| sh.deinit(probe_alloc);
        probe_alloc.free(probed);
    }

    var answering_count: usize = 0;
    for (probed) |p| {
        if (p.shares != null) answering_count += 1;
    }
    if (answering_count == 0) return allocator.alloc(Device, 0);

    const assign_entries = try allocator.alloc(device_names.Entry, answering_count);
    defer allocator.free(assign_entries);
    const mount_names = try allocator.alloc([]u8, answering_count);
    defer allocator.free(mount_names);
    const trust_entries = try allocator.alloc(device_trust.Entry, answering_count);
    defer allocator.free(trust_entries);
    const has_trust = try allocator.alloc(bool, answering_count);
    defer allocator.free(has_trust);
    @memset(has_trust, false);

    var idx: usize = 0;
    for (probed) |probe| {
        const shares_val = probe.shares orelse continue;
        const dev_id_bytes = if (shares_val.device_id) |did| did.bytes else probe.peer.bytes;
        var trusted_info: ?device_names.TrustedInfo = null;
        if (shares_val.device_id) |did| {
            if (trust_store) |ts| {
                if (ts.lookup(did)) |entry| {
                    trust_entries[idx] = entry;
                    has_trust[idx] = true;
                    trusted_info = .{
                        .label = trust_entries[idx].labelSlice(),
                        .added_at = trust_entries[idx].added_at,
                    };
                }
            }
        }
        assign_entries[idx] = .{
            .device_id = dev_id_bytes,
            .trusted = trusted_info,
            .nickname = shares_val.nickname,
        };
        idx += 1;
    }

    try device_names.assign(allocator, assign_entries, mount_names);

    const out = try allocator.alloc(Device, answering_count);
    var built: usize = 0;
    errdefer {
        for (out[0..built]) |d| d.deinit(allocator);
        allocator.free(out);
        for (mount_names[built..]) |m| allocator.free(m);
    }

    idx = 0;
    for (probed) |probe| {
        const shares_val = probe.shares orelse continue;
        const list = try allocator.alloc(DeviceShare, shares_val.listing.entries.len);
        var shares_built: usize = 0;
        errdefer {
            for (list[0..shares_built]) |s| allocator.free(s.name);
            allocator.free(list);
        }
        for (shares_val.listing.entries, list) |e, *s| {
            s.* = .{
                .name = try allocator.dupe(u8, e.name),
                .cid = e.cid,
                .size = e.size,
                .mtime = e.mtime,
            };
            shares_built += 1;
        }

        const label = if (has_trust[idx]) trust_entries[idx].labelSlice() else "";

        out[built] = .{
            .peer = probe.peer,
            .device_id = shares_val.device_id,
            .nickname = try allocator.dupe(u8, shares_val.nickname),
            .shares = list,
            .trusted = has_trust[idx],
            .label = try allocator.dupe(u8, label),
            .mount_name = mount_names[idx],
        };
        built += 1;
        idx += 1;
    }

    return out;
}
