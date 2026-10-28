//! Deterministic device folder naming for the mount and presentation layers.
//!
//! Properties:
//! - The result for a given entry does not depend on slice order.
//! - A trusted entry's name never depends on any untrusted entry.
//! - Adding/removing an untrusted entry never changes another untrusted entry's
//!   name except in the 2^-32 case where two have the same nickname and the same fp8.

const std = @import("std");

pub const max_base: usize = 48;

pub const TrustedInfo = struct {
    label: []const u8,
    added_at: u64,
};

pub const Entry = struct {
    device_id: [32]u8,
    /// Trust-store label and added_at when the device is paired, else null.
    trusted: ?TrustedInfo = null,
    /// What the peer says it is called (SHARES). Untrusted input.
    nickname: []const u8 = "",
};

pub const reserved = [_][]const u8{ "Swarm", ".", ".." };

/// Sanitizes a label or nickname into a path-safe base name:
/// - truncated to `max_base` (48 bytes)
/// - every byte < 0x20, 0x7f, '/', '\\', NUL replaced by '_'
/// - valid UTF-8 sequences preserved, invalid bytes replaced by '_'
/// - leading '.' or '-' replaced by '_'
/// - result empty -> "device"
pub fn sanitize(in: []const u8, out: *[max_base]u8) []const u8 {
    const raw = in[0..@min(in.len, max_base)];
    var len: usize = 0;
    var i: usize = 0;
    while (i < raw.len) {
        const b = raw[i];
        if (b < 0x80) {
            if (b < 0x20 or b == 0x7f or b == '/' or b == '\\' or b == 0) {
                out[len] = '_';
            } else {
                out[len] = b;
            }
            len += 1;
            i += 1;
        } else {
            const seq_len = std.unicode.utf8ByteSequenceLength(b) catch {
                out[len] = '_';
                len += 1;
                i += 1;
                continue;
            };
            if (i + seq_len <= raw.len and std.unicode.utf8ValidateSlice(raw[i .. i + seq_len])) {
                @memcpy(out[len .. len + seq_len], raw[i .. i + seq_len]);
                len += seq_len;
                i += seq_len;
            } else {
                out[len] = '_';
                len += 1;
                i += 1;
            }
        }
    }
    if (len == 0) {
        @memcpy(out[0..6], "device");
        return out[0..6];
    }
    if (out[0] == '.' or out[0] == '-') {
        out[0] = '_';
    }
    return out[0..len];
}

fn formatCand(buf: []u8, base: []const u8, device_id: *const [32]u8, level: u3) []const u8 {
    return switch (level) {
        0 => base,
        1 => std.fmt.bufPrint(buf, "{s}-{s}", .{ base, std.fmt.bytesToHex(device_id[0..4], .lower) }) catch unreachable,
        2 => std.fmt.bufPrint(buf, "{s}-{s}", .{ base, std.fmt.bytesToHex(device_id[0..8], .lower) }) catch unreachable,
        3 => std.fmt.bufPrint(buf, "{s}-{s}", .{ base, std.fmt.bytesToHex(device_id[0..16], .lower) }) catch unreachable,
        4 => std.fmt.bufPrint(buf, "{s}-{s}", .{ base, std.fmt.bytesToHex(device_id[0..32], .lower) }) catch unreachable,
        else => unreachable,
    };
}

const SortAContext = struct {
    entries: []const Entry,
    pub fn lessThan(ctx: @This(), a: usize, b: usize) bool {
        const ta = ctx.entries[a].trusted.?;
        const tb = ctx.entries[b].trusted.?;
        if (ta.added_at != tb.added_at) {
            return ta.added_at < tb.added_at;
        }
        return std.mem.order(u8, &ctx.entries[a].device_id, &ctx.entries[b].device_id) == .lt;
    }
};

const SortBContext = struct {
    entries: []const Entry,
    pub fn lessThan(ctx: @This(), a: usize, b: usize) bool {
        return std.mem.order(u8, &ctx.entries[a].device_id, &ctx.entries[b].device_id) == .lt;
    }
};

/// Fills `out[i]` (allocated with `allocator`, caller frees) with the folder name of `entries[i]`.
pub fn assign(allocator: std.mem.Allocator, entries: []const Entry, out: [][]u8) !void {
    if (entries.len != out.len) return error.InvalidArgument;
    if (entries.len == 0) return;

    for (out) |*slot| slot.* = &[_]u8{};
    errdefer {
        for (out) |slot| {
            if (slot.len > 0) allocator.free(slot);
        }
    }

    const base_buffers = try allocator.alloc([max_base]u8, entries.len);
    defer allocator.free(base_buffers);
    const bases = try allocator.alloc([]const u8, entries.len);
    defer allocator.free(bases);

    var count_trusted: usize = 0;
    var count_untrusted: usize = 0;
    for (entries, 0..) |e, i| {
        if (e.trusted) |t| {
            bases[i] = sanitize(t.label, &base_buffers[i]);
            count_trusted += 1;
        } else {
            bases[i] = sanitize(e.nickname, &base_buffers[i]);
            count_untrusted += 1;
        }
    }

    const order_a = try allocator.alloc(usize, count_trusted);
    defer allocator.free(order_a);
    const order_b = try allocator.alloc(usize, count_untrusted);
    defer allocator.free(order_b);

    var idx_a: usize = 0;
    var idx_b: usize = 0;
    for (entries, 0..) |e, i| {
        if (e.trusted != null) {
            order_a[idx_a] = i;
            idx_a += 1;
        } else {
            order_b[idx_b] = i;
            idx_b += 1;
        }
    }

    std.mem.sort(usize, order_a, SortAContext{ .entries = entries }, SortAContext.lessThan);
    std.mem.sort(usize, order_b, SortBContext{ .entries = entries }, SortBContext.lessThan);

    var taken = std.StringHashMap(void).init(allocator);
    defer taken.deinit();

    for (reserved) |r| {
        try taken.put(r, {});
    }

    // Assign trusted entries (Order A)
    for (order_a) |idx| {
        var level: u3 = 0;
        while (true) {
            var cand_buf: [max_base + 1 + 64]u8 = undefined;
            const cand = formatCand(&cand_buf, bases[idx], &entries[idx].device_id, level);
            if (!taken.contains(cand)) {
                const duped = try allocator.dupe(u8, cand);
                errdefer allocator.free(duped);
                try taken.put(duped, {});
                out[idx] = duped;
                break;
            }
            if (level < 4) {
                level += 1;
            } else {
                return error.NameCollision;
            }
        }
    }

    // Assign untrusted entries (Order B: always start at level 1)
    for (order_b) |idx| {
        var level: u3 = 1;
        while (true) {
            var cand_buf: [max_base + 1 + 64]u8 = undefined;
            const cand = formatCand(&cand_buf, bases[idx], &entries[idx].device_id, level);
            if (!taken.contains(cand)) {
                const duped = try allocator.dupe(u8, cand);
                errdefer allocator.free(duped);
                try taken.put(duped, {});
                out[idx] = duped;
                break;
            }
            if (level < 4) {
                level += 1;
            } else {
                return error.NameCollision;
            }
        }
    }
}

// ---- Unit tests ----

test "device_names: 1. trusted and untrusted permutations invariant" {
    const allocator = std.testing.allocator;

    var dev1: [32]u8 = [_]u8{0x11} ** 32;
    var dev2: [32]u8 = [_]u8{0x22} ** 32;
    var dev3: [32]u8 = [_]u8{0x33} ** 32;

    const e1 = Entry{ .device_id = dev1, .trusted = .{ .label = "Laptop", .added_at = 100 }, .nickname = "" };
    const e2 = Entry{ .device_id = dev2, .trusted = null, .nickname = "Laptop" };
    const e3 = Entry{ .device_id = dev3, .trusted = null, .nickname = "Phone" };

    const perms = [_][3]Entry{
        .{ e1, e2, e3 },
        .{ e1, e3, e2 },
        .{ e2, e1, e3 },
        .{ e2, e3, e1 },
        .{ e3, e1, e2 },
        .{ e3, e2, e1 },
    };

    for (perms) |perm| {
        var out: [3][]u8 = undefined;
        try assign(allocator, &perm, &out);
        defer for (out) |s| allocator.free(s);

        for (perm, out) |e, name| {
            if (std.mem.eql(u8, &e.device_id, &dev1)) {
                try std.testing.expectEqualStrings("Laptop", name);
            } else if (std.mem.eql(u8, &e.device_id, &dev2)) {
                try std.testing.expectEqualStrings("Laptop-22222222", name);
            } else if (std.mem.eql(u8, &e.device_id, &dev3)) {
                try std.testing.expectEqualStrings("Phone-33333333", name);
            } else {
                unreachable;
            }
        }
    }
}

test "device_names: 2. two trusted with same label" {
    const allocator = std.testing.allocator;

    const dev1 = [_]u8{0x01} ** 32;
    const dev2 = [_]u8{0x02} ** 32;

    // Earlier added_at bare, other suffixed
    {
        const entries = [_]Entry{
            .{ .device_id = dev2, .trusted = .{ .label = "Phone", .added_at = 200 } },
            .{ .device_id = dev1, .trusted = .{ .label = "Phone", .added_at = 100 } },
        };
        var out: [2][]u8 = undefined;
        try assign(allocator, &entries, &out);
        defer for (out) |s| allocator.free(s);

        try std.testing.expectEqualStrings("Phone-02020202", out[0]);
        try std.testing.expectEqualStrings("Phone", out[1]);
    }

    // Equal added_at tie-broken by device id
    {
        const entries = [_]Entry{
            .{ .device_id = dev2, .trusted = .{ .label = "Phone", .added_at = 100 } },
            .{ .device_id = dev1, .trusted = .{ .label = "Phone", .added_at = 100 } },
        };
        var out: [2][]u8 = undefined;
        try assign(allocator, &entries, &out);
        defer for (out) |s| allocator.free(s);

        // dev1 < dev2, so dev1 gets bare "Phone", dev2 gets suffixed
        try std.testing.expectEqualStrings("Phone-02020202", out[0]);
        try std.testing.expectEqualStrings("Phone", out[1]);
    }
}

test "device_names: 3. untrusted only always suffixed, empty nickname -> device-<fp8>" {
    const allocator = std.testing.allocator;

    const dev1 = [_]u8{0x12} ** 32;
    const dev2 = [_]u8{0x34} ** 32;

    const entries = [_]Entry{
        .{ .device_id = dev1, .trusted = null, .nickname = "MyPc" },
        .{ .device_id = dev2, .trusted = null, .nickname = "" },
    };
    var out: [2][]u8 = undefined;
    try assign(allocator, &entries, &out);
    defer for (out) |s| allocator.free(s);

    try std.testing.expectEqualStrings("MyPc-12121212", out[0]);
    try std.testing.expectEqualStrings("device-34343434", out[1]);
}

test "device_names: 4. mimic collision forces 16-hex suffix" {
    const allocator = std.testing.allocator;

    const dev_t = [_]u8{0x99} ** 32;
    var dev_u: [32]u8 = undefined;
    @memset(dev_u[0..4], 0xaa);
    @memset(dev_u[4..8], 0xbb);
    @memset(dev_u[8..], 0xcc);

    // Trusted has label "X-aaaaaaaa", untrusted claims nickname "X"
    // First suffix of untrusted would be "X-aaaaaaaa" (8 hex of dev_u[0..4]), which collides!
    const entries = [_]Entry{
        .{ .device_id = dev_t, .trusted = .{ .label = "X-aaaaaaaa", .added_at = 50 } },
        .{ .device_id = dev_u, .trusted = null, .nickname = "X" },
    };
    var out: [2][]u8 = undefined;
    try assign(allocator, &entries, &out);
    defer for (out) |s| allocator.free(s);

    try std.testing.expectEqualStrings("X-aaaaaaaa", out[0]);
    try std.testing.expectEqualStrings("X-aaaaaaaabbbbbbbb", out[1]);
}

test "device_names: 5. reserved names never produce Swarm, ., or .." {
    const allocator = std.testing.allocator;

    const dev1 = [_]u8{0x11} ** 32;
    const dev2 = [_]u8{0x22} ** 32;
    const dev3 = [_]u8{0x33} ** 32;
    const dev4 = [_]u8{0x44} ** 32;
    const dev5 = [_]u8{0x55} ** 32;
    const dev6 = [_]u8{0x66} ** 32;

    const entries = [_]Entry{
        .{ .device_id = dev1, .trusted = null, .nickname = "Swarm" },
        .{ .device_id = dev2, .trusted = null, .nickname = ".." },
        .{ .device_id = dev3, .trusted = null, .nickname = "." },
        .{ .device_id = dev4, .trusted = null, .nickname = "" },
        .{ .device_id = dev5, .trusted = null, .nickname = "/" },
        .{ .device_id = dev6, .trusted = .{ .label = "Swarm", .added_at = 1 } },
    };
    var out: [6][]u8 = undefined;
    try assign(allocator, &entries, &out);
    defer for (out) |s| allocator.free(s);

    for (out) |name| {
        try std.testing.expect(!std.mem.eql(u8, name, "Swarm"));
        try std.testing.expect(!std.mem.eql(u8, name, "."));
        try std.testing.expect(!std.mem.eql(u8, name, ".."));
    }
    // Trusted "Swarm" collided with reserved "Swarm", so got suffixed
    try std.testing.expectEqualStrings("Swarm-66666666", out[5]);
}

test "device_names: 6. sanitize behaviour" {
    var buf: [max_base]u8 = undefined;

    // Bad chars -> _
    try std.testing.expectEqualStrings("Bad_[31mNick_name", sanitize("Bad\x1b[31mNick\x7fname", &buf));
    try std.testing.expectEqualStrings("a_b_c_d", sanitize("a/b\\c\x00d", &buf));
    try std.testing.expectEqualStrings("line1_line2", sanitize("line1\nline2", &buf));

    // Leading . / - -> _
    try std.testing.expectEqualStrings("_hidden", sanitize(".hidden", &buf));
    try std.testing.expectEqualStrings("_flag", sanitize("-flag", &buf));

    // Empty -> "device"
    try std.testing.expectEqualStrings("device", sanitize("", &buf));

    // Truncation to 48
    const long_in = "a" ** 64;
    const trunc = sanitize(long_in, &buf);
    try std.testing.expectEqual(@as(usize, 48), trunc.len);

    // UTF-8 kept
    try std.testing.expectEqualStrings("Café", sanitize("Café", &buf));

    // Invalid UTF-8 byte -> _
    try std.testing.expectEqualStrings("ab_cd", sanitize("ab\xffcd", &buf));

    // Every output < 255 bytes
    try std.testing.expect(trunc.len < 255);
}

test "device_names: 7. revocation flip" {
    const allocator = std.testing.allocator;

    const dev = [_]u8{0x55} ** 32;

    // Trusted: bare name
    {
        const entries = [_]Entry{
            .{ .device_id = dev, .trusted = .{ .label = "Tablet", .added_at = 100 } },
        };
        var out: [1][]u8 = undefined;
        try assign(allocator, &entries, &out);
        defer allocator.free(out[0]);
        try std.testing.expectEqualStrings("Tablet", out[0]);
    }

    // Revoked (trusted = null): suffixed name
    {
        const entries = [_]Entry{
            .{ .device_id = dev, .trusted = null, .nickname = "Tablet" },
        };
        var out: [1][]u8 = undefined;
        try assign(allocator, &entries, &out);
        defer allocator.free(out[0]);
        try std.testing.expectEqualStrings("Tablet-55555555", out[0]);
    }
}

test "device_names: 8. leak check with empty, single and many entries" {
    const allocator = std.testing.allocator;

    var out0: [0][]u8 = undefined;
    try assign(allocator, &[_]Entry{}, &out0);

    var dev: [32]u8 = undefined;
    var entries: [20]Entry = undefined;
    for (&entries, 0..) |*e, i| {
        @memset(&dev, @intCast(i));
        e.* = .{
            .device_id = dev,
            .trusted = if (i % 2 == 0) .{ .label = "Node", .added_at = @intCast(i * 10) } else null,
            .nickname = "Node",
        };
    }
    var out: [20][]u8 = undefined;
    try assign(allocator, &entries, &out);
    defer for (out) |s| allocator.free(s);

    try std.testing.expectEqual(@as(usize, 20), out.len);
}
