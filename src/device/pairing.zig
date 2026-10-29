//! Self-signed pairing tickets carried as `nomadfs://pair?...` URIs.
//!
//! A ticket binds a device's long-lived Ed25519 identity to the X25519 key it
//! is currently using for Noise. The payload is signed by the identity key, so
//! a peer that already trusts an identity only needs the URI text - no server
//! round trip. Addresses and expiration are advisory metadata carried inside
//! the signed payload.
//!
//! Canonical form: the URI with fixed field order `v,p,k,n,a,e` and strict
//! percent-encoding of `n`/`a`. The signature (`s`) covers everything before
//! it, so parsing decodes the fields, re-encodes them canonically and verifies
//! against that reconstruction.

const std = @import("std");
const identity_mod = @import("identity.zig");
const qr = @import("qr.zig");
const NodeID = @import("../net/id.zig").NodeID;

const Ed25519 = std.crypto.sign.Ed25519;

pub const uri_prefix = "nomadfs://pair?";
pub const max_nickname_len = 64;
pub const max_addresses_len = 512;
pub const max_address_count = 8;
pub const max_uri_len = 2048;

pub const Error = error{
    InvalidTicket,
    ExpiredTicket,
};

pub const Ticket = struct {
    identity_public_key: [Ed25519.PublicKey.encoded_length]u8,
    transport_public_key: [32]u8,
    nickname: [max_nickname_len]u8,
    nickname_len: u8,
    addresses: [max_addresses_len]u8,
    addresses_len: u16,
    expires_at: u64,
    signature: [Ed25519.Signature.encoded_length]u8,

    /// Builds and signs a ticket after validating every human-provided field.
    pub fn init(
        identity: identity_mod.Identity,
        transport_public_key: [32]u8,
        nickname: []const u8,
        addresses: []const u8,
        expires_at: u64,
    ) !Ticket {
        try validateNickname(nickname);
        try validateAddresses(addresses);
        if (expires_at == 0) return Error.InvalidTicket;

        var ticket: Ticket = .{
            .identity_public_key = identity.publicKey(),
            .transport_public_key = transport_public_key,
            .nickname = undefined,
            .nickname_len = @intCast(nickname.len),
            .addresses = undefined,
            .addresses_len = @intCast(addresses.len),
            .expires_at = expires_at,
            .signature = undefined,
        };
        @memcpy(ticket.nickname[0..nickname.len], nickname);
        @memcpy(ticket.addresses[0..addresses.len], addresses);

        var canonical_buf: [max_uri_len]u8 = undefined;
        var writer = std.Io.Writer.fixed(&canonical_buf);
        try ticket.writeCanonical(&writer);
        ticket.signature = try identity.sign(writer.buffered());
        return ticket;
    }

    pub fn nicknameSlice(self: *const Ticket) []const u8 {
        return self.nickname[0..self.nickname_len];
    }

    pub fn addressesSlice(self: *const Ticket) []const u8 {
        return self.addresses[0..self.addresses_len];
    }

    /// Device identity derived from the ticket's public key, mirroring
    /// `Identity.deviceId`.
    pub fn deviceId(self: Ticket) NodeID {
        return NodeID.fromPublicKey(self.identity_public_key);
    }

    pub fn fingerprint(self: Ticket) [identity_mod.Identity.fingerprint_len]u8 {
        return identity_mod.Identity.fingerprintOf(self.identity_public_key);
    }

    /// `expires_at` is a Unix timestamp in seconds; a fresh ticket is valid
    /// while `now <= expires_at`.
    pub fn isExpired(self: Ticket, now: u64) bool {
        return now > self.expires_at;
    }

    /// Verifies the self-signature. Parsing already does this; callers that
    /// received the struct through another channel can double-check.
    pub fn verify(self: Ticket) !void {
        var canonical_buf: [max_uri_len]u8 = undefined;
        var writer = std.Io.Writer.fixed(&canonical_buf);
        try self.writeCanonical(&writer);
        try identity_mod.Identity.verify(self.identity_public_key, writer.buffered(), self.signature);
    }

    /// Canonical signed portion: `nomadfs://pair?v=1&p=..&k=..&n=..&a=..&e=..`.
    fn writeCanonical(self: Ticket, writer: *std.Io.Writer) !void {
        try writer.writeAll(uri_prefix ++ "v=1&p=");
        try writeBase64(writer, &self.identity_public_key);
        try writer.writeAll("&k=");
        try writeBase64(writer, &self.transport_public_key);
        try writer.writeAll("&n=");
        try percentEncode(writer, self.nicknameSlice());
        try writer.writeAll("&a=");
        try percentEncode(writer, self.addressesSlice());
        try writer.print("&e={d}", .{self.expires_at});
    }

    /// Full URI including the signature, for QR codes and clipboard sharing.
    pub fn write(self: Ticket, writer: *std.Io.Writer) !void {
        try self.writeCanonical(writer);
        try writer.writeAll("&s=");
        try writeBase64(writer, &self.signature);
    }

    pub fn toUri(self: Ticket, buf: []u8) ![]const u8 {
        var writer = std.Io.Writer.fixed(buf);
        try self.write(&writer);
        return writer.buffered();
    }

    pub fn qrMatrix(self: Ticket, allocator: std.mem.Allocator, ec: qr.EcLevel) !qr.Matrix {
        var buf: [max_uri_len]u8 = undefined;
        const uri = try self.toUri(&buf);
        return qr.encode(allocator, uri, ec);
    }

    /// Parses and self-verifies a ticket URI. Expiry is checked separately so
    /// callers can display an expired ticket before discarding it.
    pub fn parse(uri: []const u8) !Ticket {
        var ticket = try parseFields(uri);
        try ticket.verify();
        return ticket;
    }

    /// Like `parse`, but rejects tickets older than `now`.
    pub fn parseAt(uri: []const u8, now: u64) !Ticket {
        const ticket = try parse(uri);
        if (ticket.isExpired(now)) return Error.ExpiredTicket;
        return ticket;
    }
};

const field_count = 7;

/// Extracts and validates fields, leaving signature verification to the caller.
fn parseFields(uri: []const u8) !Ticket {
    if (!std.ascii.startsWithIgnoreCase(uri, uri_prefix)) return Error.InvalidTicket;
    if (uri.len > max_uri_len) return Error.InvalidTicket;

    var values: [field_count]?[]const u8 = .{null} ** field_count;
    var query = std.mem.splitScalar(u8, uri[uri_prefix.len..], '&');
    var seen_fields: usize = 0;
    while (query.next()) |pair| {
        const eq = std.mem.indexOfScalar(u8, pair, '=') orelse return Error.InvalidTicket;
        const key = pair[0..eq];
        const value = pair[eq + 1 ..];
        if (key.len != 1) return Error.InvalidTicket;
        const index = fieldIndex(key[0]) orelse return Error.InvalidTicket;
        if (values[index] != null) return Error.InvalidTicket;
        values[index] = value;
        seen_fields += 1;
    }
    if (seen_fields != field_count) return Error.InvalidTicket;

    const version = values[0].?;
    if (!std.mem.eql(u8, version, "1")) return Error.InvalidTicket;

    var ticket: Ticket = .{
        .identity_public_key = undefined,
        .transport_public_key = undefined,
        .nickname = undefined,
        .nickname_len = 0,
        .addresses = undefined,
        .addresses_len = 0,
        .expires_at = 0,
        .signature = undefined,
    };

    var decode_buf: [3 * max_addresses_len]u8 = undefined;

    const encoded_p = try percentDecode(&decode_buf, values[1].?);
    try decodeBase64(&ticket.identity_public_key, encoded_p);

    const encoded_k = try percentDecode(&decode_buf, values[2].?);
    try decodeBase64(&ticket.transport_public_key, encoded_k);

    const nickname = try percentDecode(&decode_buf, values[3].?);
    try validateNickname(nickname);
    @memcpy(ticket.nickname[0..nickname.len], nickname);
    ticket.nickname_len = @intCast(nickname.len);

    const addresses = try percentDecode(&decode_buf, values[4].?);
    try validateAddresses(addresses);
    @memcpy(ticket.addresses[0..addresses.len], addresses);
    ticket.addresses_len = @intCast(addresses.len);

    ticket.expires_at = std.fmt.parseInt(u64, values[5].?, 10) catch return Error.InvalidTicket;
    if (ticket.expires_at == 0) return Error.InvalidTicket;

    const encoded_s = try percentDecode(&decode_buf, values[6].?);
    try decodeBase64(&ticket.signature, encoded_s);

    return ticket;
}

fn fieldIndex(key: u8) ?usize {
    return switch (key) {
        'v' => 0,
        'p' => 1,
        'k' => 2,
        'n' => 3,
        'a' => 4,
        'e' => 5,
        's' => 6,
        else => null,
    };
}

fn validateNickname(nickname: []const u8) !void {
    if (nickname.len == 0 or nickname.len > max_nickname_len) return Error.InvalidTicket;
    for (nickname) |byte| {
        // Printable ASCII keeps read-aloud and terminal output predictable.
        if (byte < 0x20 or byte > 0x7e) return Error.InvalidTicket;
    }
}

fn validateAddresses(addresses: []const u8) !void {
    if (addresses.len == 0 or addresses.len > max_addresses_len) return Error.InvalidTicket;

    var count: usize = 0;
    var entries = std.mem.splitScalar(u8, addresses, ',');
    while (entries.next()) |entry| {
        count += 1;
        if (count > max_address_count) return Error.InvalidTicket;
        try validateAddress(entry);
    }
}

fn validateAddress(entry: []const u8) !void {
    if (entry.len == 0 or entry.len > 128) return Error.InvalidTicket;

    const colon = std.mem.lastIndexOfScalar(u8, entry, ':') orelse return Error.InvalidTicket;
    const host = entry[0..colon];
    const port_text = entry[colon + 1 ..];
    if (host.len == 0 or port_text.len == 0) return Error.InvalidTicket;

    const port = std.fmt.parseInt(u16, port_text, 10) catch {
        return Error.InvalidTicket;
    };
    if (port == 0) return Error.InvalidTicket;

    // A bracketed IPv6 literal may contain colons; accept the usual hex,
    // colon and dot characters inside the brackets only.
    if (host[0] == '[') {
        if (host.len < 3 or host[host.len - 1] != ']') return Error.InvalidTicket;
        for (host[1 .. host.len - 1]) |byte| {
            if (!std.ascii.isHex(byte) and byte != ':' and byte != '.') return Error.InvalidTicket;
        }
        return;
    }

    for (host) |byte| {
        const safe = std.ascii.isAlphanumeric(byte) or byte == '.' or byte == '-' or byte == '_';
        if (!safe) return Error.InvalidTicket;
    }
}

fn isUnreserved(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or byte == '-' or byte == '.' or byte == '_' or byte == '~';
}

fn percentEncode(writer: *std.Io.Writer, bytes: []const u8) !void {
    const hex = "0123456789ABCDEF";
    for (bytes) |byte| {
        if (isUnreserved(byte)) {
            try writer.writeByte(byte);
        } else {
            try writer.writeAll(&[_]u8{ '%', hex[byte >> 4], hex[byte & 0x0f] });
        }
    }
}

fn percentDecode(dest: []u8, source: []const u8) ![]u8 {
    var out: usize = 0;
    var i: usize = 0;
    while (i < source.len) {
        if (out == dest.len) return Error.InvalidTicket;
        if (source[i] == '%') {
            if (i + 2 >= source.len) return Error.InvalidTicket;
            const hi = hexValue(source[i + 1]) orelse return Error.InvalidTicket;
            const lo = hexValue(source[i + 2]) orelse return Error.InvalidTicket;
            dest[out] = (hi << 4) | lo;
            i += 3;
        } else {
            dest[out] = source[i];
            i += 1;
        }
        out += 1;
    }
    return dest[0..out];
}

fn hexValue(char: u8) ?u8 {
    return switch (char) {
        '0'...'9' => char - '0',
        'a'...'f' => char - 'a' + 10,
        'A'...'F' => char - 'A' + 10,
        else => null,
    };
}

fn writeBase64(writer: *std.Io.Writer, bytes: []const u8) !void {
    // 64-byte signatures encode to 86 characters.
    var buf: [128]u8 = undefined;
    const encoded = std.base64.url_safe_no_pad.Encoder.encode(&buf, bytes);
    try writer.writeAll(encoded);
}

fn decodeBase64(dest: []u8, text: []const u8) !void {
    const decoder = std.base64.url_safe_no_pad.Decoder;
    const size = decoder.calcSizeForSlice(text) catch return Error.InvalidTicket;
    if (size != dest.len) return Error.InvalidTicket;
    decoder.decode(dest, text) catch return Error.InvalidTicket;
}

const testing = std.testing;

fn testTicket(nickname: []const u8, addresses: []const u8, expires_at: u64) !Ticket {
    const identity = try identity_mod.Identity.fromSeed([_]u8{0x5a} ** identity_mod.seed_len);
    return Ticket.init(identity, [_]u8{0x24} ** 32, nickname, addresses, expires_at);
}

test "pairing: ticket round-trips as a URI" {
    const original = try testTicket("Sergio Laptop", "192.168.1.5:4001,10.0.0.7:4001", 1_800_000_000);
    var buf: [max_uri_len]u8 = undefined;
    const uri = try original.toUri(&buf);

    try testing.expect(std.mem.startsWith(u8, uri, uri_prefix));

    const parsed = try Ticket.parse(uri);
    try testing.expectEqualSlices(u8, &original.identity_public_key, &parsed.identity_public_key);
    try testing.expectEqualSlices(u8, &original.transport_public_key, &parsed.transport_public_key);
    try testing.expectEqualStrings(original.nicknameSlice(), parsed.nicknameSlice());
    try testing.expectEqualStrings(original.addressesSlice(), parsed.addressesSlice());
    try testing.expectEqual(original.expires_at, parsed.expires_at);
    try testing.expectEqualSlices(u8, &original.signature, &parsed.signature);
    try testing.expect(original.deviceId().eql(parsed.deviceId()));
}

test "pairing: signature covers every field" {
    const ticket = try testTicket("phone", "192.168.1.5:4001", 1_800_000_000);
    var buf: [max_uri_len]u8 = undefined;
    const uri = try ticket.toUri(&buf);

    // Rewriting the nickname invalidates the signature.
    const tampered = try std.mem.replaceOwned(u8, testing.allocator, uri, "phone", "ph0ne");
    defer testing.allocator.free(tampered);
    try testing.expectError(error.SignatureVerificationFailed, Ticket.parse(tampered));

    // So does a flipped signature byte.
    var broken: [max_uri_len]u8 = undefined;
    @memcpy(broken[0..uri.len], uri);
    const sig_start = std.mem.indexOf(u8, uri, "&s=").? + 3;
    broken[sig_start] = if (broken[sig_start] == 'A') 'B' else 'A';
    try testing.expectError(error.SignatureVerificationFailed, Ticket.parse(broken[0..uri.len]));
}

test "pairing: expired tickets are rejected only when asked" {
    const ticket = try testTicket("phone", "192.168.1.5:4001", 1_800_000_000);
    var buf: [max_uri_len]u8 = undefined;
    const uri = try ticket.toUri(&buf);

    const parsed = try Ticket.parse(uri);
    try testing.expect(!parsed.isExpired(1_800_000_000));
    try testing.expect(parsed.isExpired(1_800_000_001));

    try testing.expectError(Error.ExpiredTicket, Ticket.parseAt(uri, 1_800_000_001));
    _ = try Ticket.parseAt(uri, 1_799_999_999);
}

test "pairing: malformed tickets are rejected" {
    const ticket = try testTicket("phone", "192.168.1.5:4001", 1_800_000_000);
    var buf: [max_uri_len]u8 = undefined;
    const uri = try ticket.toUri(&buf);

    try testing.expectError(Error.InvalidTicket, Ticket.parse("http://pair?v=1"));
    try testing.expectError(Error.InvalidTicket, Ticket.parse(uri[0 .. uri.len - 1]));

    // Duplicate field.
    const dup = try std.fmt.allocPrint(testing.allocator, "{s}&n=again", .{uri});
    defer testing.allocator.free(dup);
    try testing.expectError(Error.InvalidTicket, Ticket.parse(dup));

    // Unknown field.
    const unknown = try std.fmt.allocPrint(testing.allocator, "{s}&x=1", .{uri});
    defer testing.allocator.free(unknown);
    try testing.expectError(Error.InvalidTicket, Ticket.parse(unknown));

    // Truncated percent escape.
    const bad_escape = try std.mem.replaceOwned(u8, testing.allocator, uri, "n=phone", "n=%4");
    defer testing.allocator.free(bad_escape);
    try testing.expectError(Error.InvalidTicket, Ticket.parse(bad_escape));
}

test "pairing: field validation rejects hostile input" {
    try testing.expectError(Error.InvalidTicket, testTicket("", "192.168.1.5:4001", 1_800_000_000));
    try testing.expectError(Error.InvalidTicket, testTicket("bad\nname", "192.168.1.5:4001", 1_800_000_000));
    try testing.expectError(Error.InvalidTicket, testTicket("phone", "", 1_800_000_000));
    try testing.expectError(Error.InvalidTicket, testTicket("phone", "192.168.1.5", 1_800_000_000));
    try testing.expectError(Error.InvalidTicket, testTicket("phone", "192.168.1.5:0", 1_800_000_000));
    try testing.expectError(Error.InvalidTicket, testTicket("phone", "192.168.1.5:99999", 1_800_000_000));
    try testing.expectError(Error.InvalidTicket, testTicket("phone", "host with space:4001", 1_800_000_000));
    try testing.expectError(Error.InvalidTicket, testTicket("phone", "192.168.1.5:4001", 0));

    const long_name = "n" ** (max_nickname_len + 1);
    try testing.expectError(Error.InvalidTicket, testTicket(long_name, "192.168.1.5:4001", 1_800_000_000));
}

test "pairing: tickets fit comfortably in a QR code" {
    const ticket = try testTicket("Sergio-Laptop", "192.168.1.5:4001,10.0.0.7:4001", 1_800_000_000);
    var buf: [max_uri_len]u8 = undefined;
    const uri = try ticket.toUri(&buf);
    try testing.expect(uri.len < 400);

    var matrix = try ticket.qrMatrix(testing.allocator, .medium);
    defer matrix.deinit();
    // A typical ticket should stay well below the 40-version ceiling; 16
    // (69x69 modules) still prints in about 35 terminal rows.
    try testing.expect(matrix.version <= 16);
}
