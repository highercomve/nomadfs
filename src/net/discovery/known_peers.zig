//! The devices this one has met, with every address each announced (LAN,
//! Tailscale, ...), kept on disk. The routing table forgets everything on a
//! restart and only knows addresses seen on the current network; this lets a
//! phone that left home dial the desktop over Tailscale, and lets any device
//! find the swarm again without its bootstrap peers.
//!
//! File: one device per line, `<node id hex> <last seen> <ip:port>...`.

const std = @import("std");
const kbucket = @import("kbucket.zig");
const NodeID = @import("../id.zig").NodeID;
const Address = @import("../compat.zig").Address;

pub const Entry = struct {
    id: NodeID,
    last_seen: i64,
    addrs: [kbucket.MAX_PEER_ADDRESSES]Address = undefined,
    count: u8 = 0,

    pub fn slice(self: *const Entry) []const Address {
        return self.addrs[0..self.count];
    }
};

pub const KnownPeers = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []u8,
    entries: std.ArrayList(Entry) = .empty,

    /// Devices remembered; the least recently seen go first.
    pub const max_entries = 64;

    /// Loads `path` (a missing or unreadable file is an empty list).
    pub fn load(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !KnownPeers {
        var self = KnownPeers{ .allocator = allocator, .io = io, .path = try allocator.dupe(u8, path) };
        errdefer self.deinit();
        const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(1 << 20)) catch return self;
        defer allocator.free(bytes);
        var lines = std.mem.splitScalar(u8, bytes, '\n');
        while (lines.next()) |line| {
            const entry = parseLine(line) orelse continue;
            if (self.entries.items.len >= max_entries) break;
            try self.entries.append(allocator, entry);
        }
        return self;
    }

    pub fn deinit(self: *KnownPeers) void {
        self.entries.deinit(self.allocator);
        self.allocator.free(self.path);
    }

    /// Adds or refreshes these devices (addresses merged, newest first).
    /// Returns whether anything changed.
    pub fn merge(self: *KnownPeers, peers: []const kbucket.PeerInfo) !bool {
        var changed = false;
        for (peers) |p| {
            if (p.addrs_count == 0) continue;
            const entry = for (self.entries.items) |*e| {
                if (e.id.eql(p.id)) break e;
            } else blk: {
                if (self.entries.items.len >= max_entries) self.dropOldest();
                try self.entries.append(self.allocator, .{ .id = p.id, .last_seen = p.last_seen });
                changed = true;
                break :blk &self.entries.items[self.entries.items.len - 1];
            };
            // The addresses seen now come first; older ones fill what's left.
            var fresh: Entry = .{ .id = p.id, .last_seen = @max(entry.last_seen, p.last_seen) };
            for (p.addresses[0..p.addrs_count]) |a| addAddr(&fresh, a);
            for (entry.slice()) |a| addAddr(&fresh, a);
            if (fresh.count != entry.count or !sameAddrs(fresh, entry.*)) changed = true;
            entry.* = fresh;
        }
        return changed;
    }

    fn dropOldest(self: *KnownPeers) void {
        var oldest: usize = 0;
        for (self.entries.items, 0..) |e, i| {
            if (e.last_seen < self.entries.items[oldest].last_seen) oldest = i;
        }
        _ = self.entries.swapRemove(oldest);
    }

    /// Writes the list (temp file, then rename).
    pub fn save(self: *KnownPeers) !void {
        var out: std.Io.Writer.Allocating = .init(self.allocator);
        defer out.deinit();
        for (self.entries.items) |e| {
            try out.writer.print("{x} {d}", .{ e.id.bytes, e.last_seen });
            for (e.slice()) |a| try out.writer.print(" {f}", .{a});
            try out.writer.writeByte('\n');
        }
        const tmp = try std.fmt.allocPrint(self.allocator, "{s}.tmp", .{self.path});
        defer self.allocator.free(tmp);
        {
            var file = try std.Io.Dir.cwd().createFile(self.io, tmp, .{ .truncate = true });
            defer file.close(self.io);
            try file.writePositionalAll(self.io, out.written(), 0);
        }
        try std.Io.Dir.cwd().rename(tmp, std.Io.Dir.cwd(), self.path, self.io);
    }
};

fn addAddr(e: *Entry, a: Address) void {
    for (e.slice()) |have| if (have.eql(a)) return;
    if (e.count == e.addrs.len) return;
    e.addrs[e.count] = a;
    e.count += 1;
}

fn sameAddrs(a: Entry, b: Entry) bool {
    if (a.count != b.count) return false;
    for (a.slice(), b.slice()) |x, y| if (!x.eql(y)) return false;
    return true;
}

fn parseLine(line: []const u8) ?Entry {
    var it = std.mem.tokenizeScalar(u8, std.mem.trim(u8, line, " \r\t"), ' ');
    const hex = it.next() orelse return null;
    if (hex.len != 64) return null;
    var e: Entry = .{ .id = undefined, .last_seen = 0 };
    _ = std.fmt.hexToBytes(&e.id.bytes, hex) catch return null;
    e.last_seen = std.fmt.parseInt(i64, it.next() orelse return null, 10) catch return null;
    while (it.next()) |tok| {
        const colon = std.mem.lastIndexOfScalar(u8, tok, ':') orelse continue;
        const port = std.fmt.parseInt(u16, tok[colon + 1 ..], 10) catch continue;
        const a = Address.parseIp(tok[0..colon], port) catch continue;
        addAddr(&e, a);
    }
    dropStrayPorts(&e);
    if (e.count == 0) return null;
    return e;
}

/// Older versions saved the random source port of connections a device
/// opened as if it were an address (`192.168.1.5:52738` next to the real
/// `192.168.1.5:7865`); dialing those always fails. A device listens on
/// one port, announced on every network it's on, so where one IP has
/// several ports only the port the entry uses most is kept (ties: one
/// outside the range Linux and Android pick source ports from, then the
/// first listed, the most recent).
fn dropStrayPorts(e: *Entry) void {
    var kept: Entry = .{ .id = e.id, .last_seen = e.last_seen };
    for (e.slice(), 0..) |a, i| {
        var best = a;
        var best_uses = portUses(e.*, a.getPort());
        for (e.slice()[i + 1 ..]) |b| {
            if (!sameHost(a, b)) continue;
            const uses = portUses(e.*, b.getPort());
            if (uses > best_uses or (uses == best_uses and isSourcePort(best.getPort()) and !isSourcePort(b.getPort()))) {
                best = b;
                best_uses = uses;
            }
        }
        if (!sameHost(a, best) or a.getPort() != best.getPort()) continue;
        var seen = false;
        for (kept.slice()) |k| seen = seen or sameHost(k, a);
        if (!seen) addAddr(&kept, a);
    }
    e.* = kept;
}

fn isSourcePort(port: u16) bool {
    return port >= 32768 and port <= 60999;
}

fn portUses(e: Entry, port: u16) usize {
    var n: usize = 0;
    for (e.slice()) |a| {
        if (a.getPort() == port) n += 1;
    }
    return n;
}

fn sameHost(a: Address, b: Address) bool {
    var x = a;
    x.setPort(b.getPort());
    return x.eql(b);
}

test "known peers: merge keeps every address and survives a reload" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = buf[0..try tmp.dir.realPath(io, &buf)];
    const path = try std.fs.path.join(allocator, &.{ dir, "known_peers" });
    defer allocator.free(path);

    var kp = try KnownPeers.load(allocator, io, path);
    defer kp.deinit();
    var p = kbucket.PeerInfo{ .id = .{ .bytes = [_]u8{7} ** 32 }, .last_seen = 100 };
    _ = p.addAddress(Address.initIp4(.{ 192, 168, 68, 128 }, 7865));
    try std.testing.expect(try kp.merge(&.{p}));
    // Away from home: the same device seen at its Tailscale address.
    var away = kbucket.PeerInfo{ .id = p.id, .last_seen = 200 };
    _ = away.addAddress(Address.initIp4(.{ 100, 114, 119, 39 }, 7865));
    try std.testing.expect(try kp.merge(&.{away}));
    try std.testing.expect(!try kp.merge(&.{away}));
    try kp.save();

    var again = try KnownPeers.load(allocator, io, path);
    defer again.deinit();
    try std.testing.expectEqual(@as(usize, 1), again.entries.items.len);
    const e = again.entries.items[0];
    try std.testing.expectEqual(@as(i64, 200), e.last_seen);
    try std.testing.expectEqual(@as(u8, 2), e.count);
    try std.testing.expect(e.addrs[0].eql(Address.initIp4(.{ 100, 114, 119, 39 }, 7865)));
    try std.testing.expect(e.addrs[1].eql(Address.initIp4(.{ 192, 168, 68, 128 }, 7865)));
}

test "known peers: a stray source port saved by older versions is dropped" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const id_hex = "51d647593011e46b8a907f94c331a941a64a8538c9f6d86b91c051fdd1667df9";
    try tmp.dir.writeFile(io, .{
        .sub_path = "known_peers",
        .data = id_hex ++ " 100 192.168.68.114:52738 192.168.68.114:7865 100.123.189.53:7865 192.168.68.114:40000\n",
    });
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = buf[0..try tmp.dir.realPath(io, &buf)];
    const path = try std.fs.path.join(allocator, &.{ dir, "known_peers" });
    defer allocator.free(path);

    var kp = try KnownPeers.load(allocator, io, path);
    defer kp.deinit();
    const e = kp.entries.items[0];
    try std.testing.expectEqual(@as(u8, 2), e.count);
    try std.testing.expect(e.addrs[0].eql(Address.initIp4(.{ 192, 168, 68, 114 }, 7865)));
    try std.testing.expect(e.addrs[1].eql(Address.initIp4(.{ 100, 123, 189, 53 }, 7865)));

    // One real port and one stray, each once: the stray is the source port.
    var tie: Entry = .{ .id = e.id, .last_seen = 1 };
    addAddr(&tie, Address.initIp4(.{ 192, 168, 68, 111 }, 46538));
    addAddr(&tie, Address.initIp4(.{ 192, 168, 68, 111 }, 14700));
    dropStrayPorts(&tie);
    try std.testing.expectEqual(@as(u8, 1), tie.count);
    try std.testing.expectEqual(@as(u16, 14700), tie.addrs[0].getPort());
}
