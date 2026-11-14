//! Deterministic AWS Signature Version 4 header authentication for S3.
const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Credentials = struct {
    access_key_id: []const u8,
    secret_access_key: []const u8,
};

pub const Header = std.http.Header;
pub const Parameter = struct { name: []const u8, value: []const u8 };
pub const Error = Allocator.Error || error{InvalidInput};
pub const unsigned_payload = "UNSIGNED-PAYLOAD";

pub const Options = struct {
    method: []const u8,
    /// Unencoded absolute path. Slashes and dot segments are preserved.
    path: []const u8,
    host: []const u8,
    region: []const u8,
    /// UTC basic ISO 8601, for example 20130524T000000Z.
    timestamp: []const u8,
    payload_hash: []const u8,
    query: []const Parameter = &.{},
    /// Host, x-amz-date, and x-amz-content-sha256 are added automatically.
    headers: []const Header = &.{},
};

pub fn hashPayload(bytes: []const u8) [64]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    return std.fmt.bytesToHex(digest, .lower);
}

/// Returns an owned RFC 3986 encoding of raw bytes, including UTF-8 bytes.
pub fn uriEncode(allocator: Allocator, raw: []const u8, keep_slashes: bool) Error![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    const hex = "0123456789ABCDEF";
    for (raw) |byte| {
        if (std.ascii.isAlphanumeric(byte) or std.mem.indexOfScalar(u8, "-._~", byte) != null or
            (keep_slashes and byte == '/'))
        {
            out.writer.writeByte(byte) catch return error.OutOfMemory;
        } else {
            out.writer.writeAll(&.{ '%', hex[byte >> 4], hex[byte & 15] }) catch return error.OutOfMemory;
        }
    }
    return out.toOwnedSlice();
}

fn parameterLess(_: void, a: Parameter, b: Parameter) bool {
    const order = std.mem.order(u8, a.name, b.name);
    return order == .lt or (order == .eq and std.mem.lessThan(u8, a.value, b.value));
}

/// Encodes before sorting, including repeated names and empty values.
pub fn canonicalQuery(allocator: Allocator, parameters: []const Parameter) Error![]u8 {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const scratch = arena.allocator();
    const encoded = try scratch.alloc(Parameter, parameters.len);
    for (parameters, encoded) |raw, *item| item.* = .{
        .name = try uriEncode(scratch, raw.name, false),
        .value = try uriEncode(scratch, raw.value, false),
    };
    std.mem.sort(Parameter, encoded, {}, parameterLess);
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    for (encoded, 0..) |item, i| {
        if (i > 0) out.writer.writeByte('&') catch return error.OutOfMemory;
        out.writer.print("{s}={s}", .{ item.name, item.value }) catch return error.OutOfMemory;
    }
    return out.toOwnedSlice();
}

fn headerLess(_: void, a: Header, b: Header) bool {
    return std.mem.lessThan(u8, a.name, b.name);
}

/// Rejects header injection before passing values to std.http.Client.
pub fn validateHeader(header: Header) error{InvalidInput}!void {
    if (header.name.len == 0) return error.InvalidInput;
    for (header.name) |c| {
        if (!std.ascii.isAlphanumeric(c) and std.mem.indexOfScalar(u8, "!#$%&'*+-.^_`|~", c) == null)
            return error.InvalidInput;
    }
    for (header.value) |c| {
        if ((c < 32 and c != '\t') or c == 127) return error.InvalidInput;
    }
}

fn normalizeHeader(allocator: Allocator, raw: Header) Error!Header {
    try validateHeader(raw);
    const name = try allocator.dupe(u8, raw.name);
    for (name) |*c| c.* = std.ascii.toLower(c.*);
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    var parts = std.mem.tokenizeAny(u8, raw.value, " \t");
    var first = true;
    while (parts.next()) |part| {
        if (!first) out.writer.writeByte(' ') catch return error.OutOfMemory;
        out.writer.writeAll(part) catch return error.OutOfMemory;
        first = false;
    }
    return .{ .name = name, .value = try out.toOwnedSlice() };
}

fn validate(options: Options) Error!void {
    if (options.path.len == 0 or options.path[0] != '/' or options.host.len == 0 or
        options.region.len == 0 or options.timestamp.len != 16) return error.InvalidInput;
    for (options.timestamp, 0..) |c, i| {
        if (i == 8) {
            if (c != 'T') return error.InvalidInput;
        } else if (i == 15) {
            if (c != 'Z') return error.InvalidInput;
        } else if (!std.ascii.isDigit(c)) return error.InvalidInput;
    }
    if (!std.mem.eql(u8, options.payload_hash, unsigned_payload)) {
        if (options.payload_hash.len != 64) return error.InvalidInput;
        for (options.payload_hash) |c| if (!std.ascii.isHex(c)) return error.InvalidInput;
    }
    for (options.method) |c| if (c < 'A' or c > 'Z') return error.InvalidInput;
    if (options.method.len == 0) return error.InvalidInput;
    try validateHeader(.{ .name = "host", .value = options.host });
    for (options.region) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '-') return error.InvalidInput;
    }
}

const Canonical = struct { request: []const u8, names: []const u8 };

fn canonical(allocator: Allocator, options: Options) Error!Canonical {
    try validate(options);
    const headers = try allocator.alloc(Header, options.headers.len + 3);
    headers[0] = .{ .name = "host", .value = options.host };
    headers[1] = .{ .name = "x-amz-content-sha256", .value = options.payload_hash };
    headers[2] = .{ .name = "x-amz-date", .value = options.timestamp };
    for (options.headers, headers[3..]) |raw, *header| {
        header.* = try normalizeHeader(allocator, raw);
        for (headers[0..3]) |reserved| {
            if (std.mem.eql(u8, header.name, reserved.name)) return error.InvalidInput;
        }
        if (std.mem.eql(u8, header.name, "authorization")) return error.InvalidInput;
    }
    // Stable sorting preserves the order of duplicate header values.
    std.mem.sort(Header, headers, {}, headerLess);
    var values: std.Io.Writer.Allocating = .init(allocator);
    var names: std.Io.Writer.Allocating = .init(allocator);
    for (headers, 0..) |header, i| {
        const duplicate = i > 0 and std.mem.eql(u8, headers[i - 1].name, header.name);
        if (duplicate) {
            values.writer.print(",{s}", .{header.value}) catch return error.OutOfMemory;
        } else {
            if (i > 0) {
                values.writer.writeByte('\n') catch return error.OutOfMemory;
                names.writer.writeByte(';') catch return error.OutOfMemory;
            }
            values.writer.print("{s}:{s}", .{ header.name, header.value }) catch return error.OutOfMemory;
            names.writer.writeAll(header.name) catch return error.OutOfMemory;
        }
    }
    values.writer.writeByte('\n') catch return error.OutOfMemory;
    const path = try uriEncode(allocator, options.path, true);
    const query = try canonicalQuery(allocator, options.query);
    return .{
        .request = try std.fmt.allocPrint(allocator, "{s}\n{s}\n{s}\n{s}\n{s}\n{s}", .{
            options.method, path, query, values.written(), names.written(), options.payload_hash,
        }),
        .names = names.written(),
    };
}

fn hmac(key: []const u8, message: []const u8) [32]u8 {
    var result: [32]u8 = undefined;
    std.crypto.auth.hmac.sha2.HmacSha256.create(&result, message, key);
    return result;
}

/// Returns an owned Authorization header. The clock is supplied by the caller.
pub fn sign(allocator: Allocator, credentials: Credentials, options: Options) Error![]u8 {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const scratch = arena.allocator();
    const request = try canonical(scratch, options);
    if (credentials.access_key_id.len == 0 or credentials.secret_access_key.len == 0)
        return error.InvalidInput;
    for (credentials.access_key_id) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '-' and c != '_') return error.InvalidInput;
    }
    const scope = try std.fmt.allocPrint(scratch, "{s}/{s}/s3/aws4_request", .{ options.timestamp[0..8], options.region });
    const request_hash = hashPayload(request.request);
    const to_sign = try std.fmt.allocPrint(scratch, "AWS4-HMAC-SHA256\n{s}\n{s}\n{s}", .{
        options.timestamp, scope, request_hash,
    });
    const secret = try std.mem.concat(scratch, u8, &.{ "AWS4", credentials.secret_access_key });
    const date_key = hmac(secret, options.timestamp[0..8]);
    const region_key = hmac(&date_key, options.region);
    const service_key = hmac(&region_key, "s3");
    const signing_key = hmac(&service_key, "aws4_request");
    const signature = std.fmt.bytesToHex(hmac(&signing_key, to_sign), .lower);
    return std.fmt.allocPrint(allocator, "AWS4-HMAC-SHA256 Credential={s}/{s},SignedHeaders={s},Signature={s}", .{
        credentials.access_key_id, scope, request.names, signature,
    });
}

const example_credentials: Credentials = .{
    .access_key_id = "AKIAIOSFODNN7EXAMPLE",
    .secret_access_key = "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY",
};

// Published vectors: https://docs.aws.amazon.com/AmazonS3/latest/developerguide/sig-v4-header-based-auth.html
fn expectVector(method: []const u8, path: []const u8, body: []const u8, headers: []const Header, query: []const Parameter, names: []const u8, signature: []const u8) !void {
    const hash = hashPayload(body);
    const auth = try sign(std.testing.allocator, example_credentials, .{
        .method = method,
        .path = path,
        .host = "examplebucket.s3.amazonaws.com",
        .region = "us-east-1",
        .timestamp = "20130524T000000Z",
        .payload_hash = &hash,
        .headers = headers,
        .query = query,
    });
    defer std.testing.allocator.free(auth);
    const expected = try std.fmt.allocPrint(std.testing.allocator, "AWS4-HMAC-SHA256 Credential=AKIAIOSFODNN7EXAMPLE/20130524/us-east-1/s3/aws4_request,SignedHeaders={s},Signature={s}", .{ names, signature });
    defer std.testing.allocator.free(expected);
    try std.testing.expectEqualStrings(expected, auth);
}

test "AWS published GET object with Range Authorization" {
    try expectVector("GET", "/test.txt", "", &.{.{ .name = "Range", .value = "bytes=0-9" }}, &.{}, "host;range;x-amz-content-sha256;x-amz-date", "f0e8bdb87c964420e857bd35b5d6ed310bd44f0170aba48dd91039c6036bdb41");
}

test "AWS published PUT object Authorization" {
    try expectVector("PUT", "/test$file.text", "Welcome to Amazon S3.", &.{
        .{ .name = "Date", .value = "Fri, 24 May 2013 00:00:00 GMT" },
        .{ .name = "x-amz-storage-class", .value = "REDUCED_REDUNDANCY" },
    }, &.{}, "date;host;x-amz-content-sha256;x-amz-date;x-amz-storage-class", "98ad721746da40c64f1a55b78f14c238d841ea1380cd77a1b5971af0ece108bd");
}

test "AWS published list objects Authorization" {
    try expectVector("GET", "/", "", &.{}, &.{
        .{ .name = "prefix", .value = "J" }, .{ .name = "max-keys", .value = "2" },
    }, "host;x-amz-content-sha256;x-amz-date", "34b48302e7b5fa45bde8084f4b7868a86f0a534bc59db6670ed5711ef69dc6f7");
}

test "RFC 3986 encoding preserves raw object paths and sorts encoded query pairs" {
    const a = std.testing.allocator;
    const path = try uriEncode(a, "/bucket/a//../é +%2F", true);
    defer a.free(path);
    try std.testing.expectEqualStrings("/bucket/a//../%C3%A9%20%2B%252F", path);
    const query = try canonicalQuery(a, &.{
        .{ .name = "z", .value = "/ +" },
        .{ .name = "é", .value = "" },
        .{ .name = "a", .value = "2" },
        .{ .name = "a", .value = "1" },
    });
    defer a.free(query);
    try std.testing.expectEqualStrings("%C3%A9=&a=1&a=2&z=%2F%20%2B", query);
}

test "header validation rejects injection" {
    try std.testing.expectError(error.InvalidInput, validateHeader(.{ .name = "Range", .value = "x\r\nx:y" }));
}
