//! Path-style S3 operations. Configuration, credentials, and transport are borrowed.
const std = @import("std");
pub const sigv4 = @import("sigv4.zig");
pub const http = @import("transport.zig");
const xml = @import("xml.zig");
const Allocator = std.mem.Allocator;

pub const Credentials = sigv4.Credentials;
pub const Body = http.Body;
pub const Response = http.Response;
pub const Transport = http.Transport;
pub const HttpTransport = http.HttpTransport;
pub const Error = http.Error || sigv4.Error || xml.Error || error{
    InvalidEndpoint,
    NotFound,
    PreconditionFailed,
    AccessDenied,
    InvalidCredentials,
    InvalidRange,
    Conflict,
    RestoreAlreadyInProgress,
    InvalidObjectState,
    NoSuchUpload,
    NotImplemented,
    Throttled,
    ServiceUnavailable,
    Redirect,
    BadRequest,
    S3Error,
};

pub const Retry = struct {
    max_attempts: u8 = 3,
    base_delay_ms: u32 = 100,
    max_delay_ms: u32 = 5000,
};

pub const Config = struct {
    /// An HTTPS origin, or HTTP for a local MinIO installation. No base path.
    endpoint: []const u8,
    bucket: []const u8,
    region: []const u8 = "auto",
    retry: Retry = .{},
    max_response_bytes: usize = 64 * 1024 * 1024,
};

pub const Condition = union(enum) { none, if_none_match, if_match: []const u8 };
pub const PutOptions = struct {
    condition: Condition = .none,
    content_type: ?[]const u8 = null,
    /// Streaming bodies always use UNSIGNED-PAYLOAD and must be replayable.
    unsigned_payload: bool = false,
    /// Sent as a signed x-amz-storage-class; null leaves the bucket default.
    storage_class: ?[]const u8 = null,
};
pub const MultipartOptions = struct { storage_class: ?[]const u8 = null };
/// Retrieval speed of an archived object: Bulk is cheapest and slowest.
pub const RestoreTier = enum { Bulk, Standard, Expedited };
pub const RestoreOptions = struct {
    /// How long the readable copy stays available.
    days: u16 = 7,
    tier: RestoreTier = .Bulk,
};
/// The x-amz-restore header of a HEAD: no request yet, in progress, or readable.
pub const RestoreState = union(enum) {
    none,
    ongoing,
    /// The expiry-date text of the readable copy ("" when the server sent none).
    ready: []const u8,
};
/// What a HEAD says about an object. Slices borrow from the response.
pub const ObjectState = struct {
    size: ?u64,
    /// "STANDARD" when the server sends no x-amz-storage-class.
    storage_class: []const u8,
    restore: RestoreState,
};
/// Reads size, storage class and thaw progress from a headObject response.
pub fn objectState(response: *const Response) ObjectState {
    const length = response.header("content-length");
    return .{
        .size = if (length) |text| std.fmt.parseInt(u64, std.mem.trim(u8, text, " \t"), 10) catch null else null,
        .storage_class = response.header("x-amz-storage-class") orelse "STANDARD",
        .restore = parseRestore(response.header("x-amz-restore")),
    };
}
fn parseRestore(header: ?[]const u8) RestoreState {
    const text = header orelse return .none;
    if (std.mem.indexOf(u8, text, "ongoing-request=\"true\"") != null) return .ongoing;
    if (std.mem.indexOf(u8, text, "ongoing-request=\"false\"") == null) return .none;
    const mark = "expiry-date=\"";
    const start = (std.mem.indexOf(u8, text, mark) orelse return .{ .ready = "" }) + mark.len;
    const end = std.mem.indexOfScalarPos(u8, text, start, '"') orelse return .{ .ready = "" };
    return .{ .ready = text[start..end] };
}
pub const Range = struct {
    start: u64,
    /// Inclusive. Null means all remaining bytes.
    end: ?u64 = null,
};
pub const ListOptions = struct {
    prefix: []const u8 = "",
    continuation_token: ?[]const u8 = null,
    max_keys: u16 = 1000,
};
pub const Object = struct {
    key: []const u8,
    size: u64,
    etag: []const u8,
    /// LastModified as Unix seconds; 0 when the server sent none.
    last_modified: u64 = 0,
};
pub const ListResult = struct {
    arena: std.heap.ArenaAllocator,
    objects: []const Object,
    is_truncated: bool,
    next_continuation_token: ?[]const u8,

    pub fn deinit(self: *ListResult) void {
        self.arena.deinit();
        self.* = undefined;
    }
};
pub const Versioning = xml.Versioning;
pub const CompletedPart = struct { part_number: u16, etag: []const u8 };

const Operation = struct {
    method: std.http.Method,
    key: ?[]const u8,
    query: []const sigv4.Parameter = &.{},
    headers: []const sigv4.Header = &.{},
    body: Body = .{ .bytes = "" },
    unsigned_payload: bool = false,
    xml_root: ?[]const u8 = null,
};

pub const Client = struct {
    allocator: Allocator,
    config: Config,
    credentials: Credentials,
    transport: Transport,

    pub fn init(allocator: Allocator, config: Config, credentials: Credentials, transport: Transport) Error!Client {
        const uri = std.Uri.parse(config.endpoint) catch return error.InvalidEndpoint;
        if ((!std.mem.eql(u8, uri.scheme, "https") and !std.mem.eql(u8, uri.scheme, "http")) or
            uri.host == null or uri.user != null or uri.password != null or uri.query != null or uri.fragment != null)
            return error.InvalidEndpoint;
        const path = uri.path.percent_encoded;
        if (path.len > 0 and !std.mem.eql(u8, path, "/")) return error.InvalidEndpoint;
        if (config.bucket.len == 0 or config.bucket.len > 255 or config.region.len == 0 or
            config.retry.max_attempts == 0 or config.max_response_bytes == 0) return error.InvalidInput;
        for (config.bucket) |c| {
            if (!std.ascii.isAlphanumeric(c) and std.mem.indexOfScalar(u8, ".-_", c) == null)
                return error.InvalidInput;
        }
        return .{ .allocator = allocator, .config = config, .credentials = credentials, .transport = transport };
    }

    /// The response owns its body and headers, including the ETag used by a lease.
    pub fn putObject(self: *Client, key: []const u8, body: Body, options: PutOptions, timestamp: []const u8) Error!Response {
        var headers: [3]sigv4.Header = undefined;
        var count: usize = 0;
        if (options.storage_class) |class| {
            if (class.len == 0) return error.InvalidInput;
            headers[count] = .{ .name = "x-amz-storage-class", .value = class };
            count += 1;
        }
        switch (options.condition) {
            .none => {},
            .if_none_match => {
                headers[count] = .{ .name = "if-none-match", .value = "*" };
                count += 1;
            },
            .if_match => |etag| {
                if (etag.len == 0) return error.InvalidInput;
                headers[count] = .{ .name = "if-match", .value = etag };
                count += 1;
            },
        }
        if (options.content_type) |value| {
            headers[count] = .{ .name = "content-type", .value = value };
            count += 1;
        }
        return self.execute(.{ .method = .PUT, .key = key, .body = body, .headers = headers[0..count], .unsigned_payload = options.unsigned_payload }, timestamp);
    }

    pub fn getObject(self: *Client, key: []const u8, range: ?Range, timestamp: []const u8) Error!Response {
        var buffer: [64]u8 = undefined;
        var headers: [1]sigv4.Header = undefined;
        if (range) |value| {
            if (value.end) |end| if (end < value.start) return error.InvalidRange;
            const text = if (value.end) |end|
                std.fmt.bufPrint(&buffer, "bytes={d}-{d}", .{ value.start, end }) catch unreachable
            else
                std.fmt.bufPrint(&buffer, "bytes={d}-", .{value.start}) catch unreachable;
            headers[0] = .{ .name = "range", .value = text };
        }
        return self.execute(.{ .method = .GET, .key = key, .headers = if (range != null) &headers else &.{} }, timestamp);
    }

    /// Content-Length and ETag are exposed by Response.header; objectState
    /// reads the storage class and the x-amz-restore thaw progress.
    pub fn headObject(self: *Client, key: []const u8, timestamp: []const u8) Error!Response {
        return self.execute(.{ .method = .HEAD, .key = key }, timestamp);
    }

    pub fn deleteObject(self: *Client, key: []const u8, timestamp: []const u8) Error!void {
        var response = try self.execute(.{ .method = .DELETE, .key = key }, timestamp);
        response.deinit();
    }

    /// Asks for a temporary readable copy of an archived object. A thaw that
    /// is already running (409 RestoreAlreadyInProgress) counts as success.
    pub fn restoreObject(self: *Client, key: []const u8, options: RestoreOptions, timestamp: []const u8) Error!void {
        if (options.days == 0 or options.days > 365) return error.InvalidInput;
        var buffer: [256]u8 = undefined;
        const body = std.fmt.bufPrint(&buffer, "<RestoreRequest xmlns=\"http://s3.amazonaws.com/doc/2006-03-01/\"><Days>{d}</Days>" ++
            "<GlacierJobParameters><Tier>{s}</Tier></GlacierJobParameters></RestoreRequest>", .{ options.days, @tagName(options.tier) }) catch unreachable;
        var response = self.execute(.{ .method = .POST, .key = key, .body = .{ .bytes = body }, .headers = &.{.{ .name = "content-type", .value = "application/xml" }}, .query = &.{.{ .name = "restore", .value = "" }} }, timestamp) catch |err| switch (err) {
            error.RestoreAlreadyInProgress => return,
            else => return err,
        };
        response.deinit();
    }

    /// Whether the bucket keeps old versions of deleted objects. A store
    /// without versioning (no Status, or the request is not implemented) is off.
    pub fn getBucketVersioning(self: *Client, timestamp: []const u8) Error!Versioning {
        var response = self.execute(.{ .method = .GET, .key = null, .query = &.{.{ .name = "versioning", .value = "" }}, .xml_root = "VersioningConfiguration" }, timestamp) catch |err| switch (err) {
            error.NotImplemented => return .off,
            else => return err,
        };
        defer response.deinit();
        return xml.parseVersioning(self.allocator, response.body) catch |err| switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.InvalidXml => error.InvalidResponse,
        };
    }

    /// Returns one page. Pass next_continuation_token to the next call.
    pub fn listObjectsV2(self: *Client, options: ListOptions, timestamp: []const u8) Error!ListResult {
        if (options.max_keys == 0 or options.max_keys > 1000) return error.InvalidInput;
        var buffer: [5]u8 = undefined;
        const max_keys = std.fmt.bufPrint(&buffer, "{d}", .{options.max_keys}) catch unreachable;
        var query = [_]sigv4.Parameter{
            .{ .name = "list-type", .value = "2" },
            .{ .name = "prefix", .value = options.prefix },
            .{ .name = "max-keys", .value = max_keys },
            .{ .name = "continuation-token", .value = options.continuation_token orelse "" },
        };
        var response = try self.execute(.{ .method = .GET, .key = null, .query = query[0..if (options.continuation_token != null) 4 else 3], .xml_root = "ListBucketResult" }, timestamp);
        defer response.deinit();
        return parseList(self.allocator, response.body);
    }

    /// Returns an owned upload ID, freed with the client's allocator.
    pub fn createMultipartUpload(self: *Client, key: []const u8, options: MultipartOptions, timestamp: []const u8) Error![]u8 {
        var headers: [1]sigv4.Header = undefined;
        if (options.storage_class) |class| {
            if (class.len == 0) return error.InvalidInput;
            headers[0] = .{ .name = "x-amz-storage-class", .value = class };
        }
        var response = try self.execute(.{ .method = .POST, .key = key, .headers = if (options.storage_class != null) &headers else &.{}, .query = &.{.{ .name = "uploads", .value = "" }}, .xml_root = "InitiateMultipartUploadResult" }, timestamp);
        defer response.deinit();
        var document = try xml.parse(self.allocator, response.body);
        defer document.deinit();
        const upload_id = document.text(0, "UploadId") orelse return error.InvalidResponse;
        if (upload_id.len == 0) return error.InvalidResponse;
        return self.allocator.dupe(u8, upload_id);
    }

    /// Retain the response's ETag for completeMultipartUpload.
    pub fn uploadPart(self: *Client, key: []const u8, upload_id: []const u8, part_number: u16, body: Body, timestamp: []const u8) Error!Response {
        if (part_number == 0 or part_number > 10000 or upload_id.len == 0) return error.InvalidInput;
        var buffer: [5]u8 = undefined;
        const part = std.fmt.bufPrint(&buffer, "{d}", .{part_number}) catch unreachable;
        return self.execute(.{ .method = .PUT, .key = key, .body = body, .query = &.{
            .{ .name = "partNumber", .value = part }, .{ .name = "uploadId", .value = upload_id },
        } }, timestamp);
    }

    /// `if_none_match` refuses to replace an object that already has the name.
    pub fn completeMultipartUpload(self: *Client, key: []const u8, upload_id: []const u8, parts: []const CompletedPart, condition: Condition, timestamp: []const u8) Error!Response {
        if (upload_id.len == 0 or parts.len == 0 or parts.len > 10000) return error.InvalidInput;
        const body = try completionXml(self.allocator, parts);
        defer self.allocator.free(body);
        var headers: [2]sigv4.Header = undefined;
        headers[0] = .{ .name = "content-type", .value = "application/xml" };
        var count: usize = 1;
        switch (condition) {
            .none => {},
            .if_none_match => {
                headers[count] = .{ .name = "if-none-match", .value = "*" };
                count += 1;
            },
            .if_match => |etag| {
                if (etag.len == 0) return error.InvalidInput;
                headers[count] = .{ .name = "if-match", .value = etag };
                count += 1;
            },
        }
        return self.execute(.{ .method = .POST, .key = key, .body = .{ .bytes = body }, .headers = headers[0..count], .query = &.{.{ .name = "uploadId", .value = upload_id }}, .xml_root = "CompleteMultipartUploadResult" }, timestamp);
    }

    pub fn abortMultipartUpload(self: *Client, key: []const u8, upload_id: []const u8, timestamp: []const u8) Error!void {
        if (upload_id.len == 0) return error.InvalidInput;
        var response = try self.execute(.{ .method = .DELETE, .key = key, .query = &.{.{ .name = "uploadId", .value = upload_id }} }, timestamp);
        response.deinit();
    }

    fn build(self: *Client, allocator: Allocator, operation: Operation, timestamp: []const u8) Error!http.Request {
        if (operation.key) |key| if (key.len == 0 or key.len > 1024) return error.InvalidInput;
        const endpoint = std.mem.trimEnd(u8, self.config.endpoint, "/");
        const authority_start = (std.mem.indexOf(u8, endpoint, "://") orelse return error.InvalidEndpoint) + 3;
        const host = endpoint[authority_start..];
        const raw_path = if (operation.key) |key|
            try std.fmt.allocPrint(allocator, "/{s}/{s}", .{ self.config.bucket, key })
        else
            try std.fmt.allocPrint(allocator, "/{s}", .{self.config.bucket});
        const path = try sigv4.uriEncode(allocator, raw_path, true);
        const query = try sigv4.canonicalQuery(allocator, operation.query);
        const hash = sigv4.hashPayload(switch (operation.body) {
            .bytes => |b| b,
            .stream => "",
        });
        const payload_hash = if (operation.unsigned_payload or operation.body == .stream) sigv4.unsigned_payload else &hash;
        const authorization = try sigv4.sign(allocator, self.credentials, .{
            .method = @tagName(operation.method),
            .path = raw_path,
            .host = host,
            .region = self.config.region,
            .timestamp = timestamp,
            .payload_hash = payload_hash,
            .headers = operation.headers,
            .query = operation.query,
        });
        const headers = try allocator.alloc(sigv4.Header, operation.headers.len + 4);
        @memcpy(headers[0..operation.headers.len], operation.headers);
        @memcpy(headers[operation.headers.len..], &[_]sigv4.Header{
            .{ .name = "host", .value = host },                                                 .{ .name = "x-amz-date", .value = timestamp },
            .{ .name = "x-amz-content-sha256", .value = try allocator.dupe(u8, payload_hash) }, .{ .name = "authorization", .value = authorization },
        });
        const url = try std.fmt.allocPrint(allocator, "{s}{s}{s}{s}", .{
            endpoint, path, if (query.len == 0) "" else "?", query,
        });
        return .{ .method = operation.method, .url = url, .headers = headers, .body = operation.body, .max_response_bytes = self.config.max_response_bytes };
    }

    fn execute(self: *Client, operation: Operation, timestamp: []const u8) Error!Response {
        std.debug.assert(@intFromPtr(self.transport.context) != 0);
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const request = try self.build(arena.allocator(), operation, timestamp);
        var attempt: u8 = 0;
        var delay_ms: u64 = @min(self.config.retry.base_delay_ms, self.config.retry.max_delay_ms);
        while (attempt < self.config.retry.max_attempts) : (attempt += 1) {
            var response = self.transport.send(self.transport.context, self.allocator, request) catch |err| {
                if (err != error.NetworkFailure or attempt + 1 == self.config.retry.max_attempts) return err;
                try self.backoff(&delay_ms);
                continue;
            };
            const failure = responseError(self.allocator, &response, operation.xml_root) catch |err| {
                response.deinit();
                return err;
            };
            if (failure == null) return response;
            const retry = response.status == 429 or (response.status >= 500 and response.status < 600 and response.status != 501) or
                (response.status == 200 and (failure.? == error.ServiceUnavailable or failure.? == error.Throttled));
            response.deinit();
            if (!retry or attempt + 1 == self.config.retry.max_attempts) return failure.?;
            try self.backoff(&delay_ms);
        }
        unreachable;
    }

    fn backoff(self: *Client, delay_ms: *u64) Error!void {
        try self.transport.sleep(self.transport.context, delay_ms.*);
        delay_ms.* = @min(delay_ms.* * 2, self.config.retry.max_delay_ms);
    }
};

fn codeError(code: []const u8) Error {
    if (std.mem.eql(u8, code, "NoSuchUpload")) return error.NoSuchUpload;
    if (std.mem.eql(u8, code, "NoSuchKey") or std.mem.eql(u8, code, "NoSuchBucket")) return error.NotFound;
    if (std.mem.eql(u8, code, "AccessDenied")) return error.AccessDenied;
    if (std.mem.eql(u8, code, "InvalidAccessKeyId") or std.mem.eql(u8, code, "SignatureDoesNotMatch"))
        return error.InvalidCredentials;
    if (std.mem.eql(u8, code, "PreconditionFailed")) return error.PreconditionFailed;
    if (std.mem.eql(u8, code, "RestoreAlreadyInProgress")) return error.RestoreAlreadyInProgress;
    if (std.mem.eql(u8, code, "InvalidObjectState")) return error.InvalidObjectState;
    if (std.mem.eql(u8, code, "NotImplemented")) return error.NotImplemented;
    if (std.mem.eql(u8, code, "SlowDown") or std.mem.eql(u8, code, "Throttling")) return error.Throttled;
    if (std.mem.eql(u8, code, "InternalError") or std.mem.eql(u8, code, "ServiceUnavailable"))
        return error.ServiceUnavailable;
    return error.S3Error;
}

fn statusError(status: u16) Error {
    return switch (status) {
        400 => error.BadRequest,
        401 => error.InvalidCredentials,
        403 => error.AccessDenied,
        404 => error.NotFound,
        409 => error.Conflict,
        412 => error.PreconditionFailed,
        416 => error.InvalidRange,
        429 => error.Throttled,
        501 => error.NotImplemented,
        300...399 => error.Redirect,
        500, 502...599 => error.ServiceUnavailable,
        else => error.S3Error,
    };
}

fn responseError(allocator: Allocator, response: *const Response, expected_root: ?[]const u8) Error!?Error {
    const success = response.status >= 200 and response.status < 300;
    if (success and expected_root == null) return null;
    // HTTP status remains authoritative for lease failures, even with a proxy's HTML body.
    if (response.status == 412) return @as(?Error, error.PreconditionFailed);
    var document = xml.parse(allocator, response.body) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        if (success) return error.InvalidResponse;
        return @as(?Error, statusError(response.status));
    };
    defer document.deinit();
    if (document.rootIs("Error")) {
        const failure = codeError(document.text(0, "Code") orelse "");
        return @as(?Error, if (failure == error.S3Error and !success) statusError(response.status) else failure);
    }
    if (!success) return @as(?Error, statusError(response.status));
    if (!document.rootIs(expected_root.?)) return error.InvalidResponse;
    return null;
}

fn parseList(allocator: Allocator, source: []const u8) Error!ListResult {
    var document = try xml.parse(allocator, source);
    defer document.deinit();
    if (!document.rootIs("ListBucketResult")) return error.InvalidResponse;
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const a = arena.allocator();
    var objects: std.ArrayList(Object) = .empty;
    for (document.nodes, 0..) |node, i| {
        if (node.parent != 0 or !node.isNamed("Contents")) continue;
        if (objects.items.len == 1000) return error.InvalidResponse;
        const key = document.text(i, "Key") orelse return error.InvalidResponse;
        const size = document.text(i, "Size") orelse return error.InvalidResponse;
        const etag = document.text(i, "ETag") orelse return error.InvalidResponse;
        const modified = if (document.text(i, "LastModified")) |text| parseTime(std.mem.trim(u8, text, " \r\n\t")) orelse return error.InvalidResponse else 0;
        try objects.append(a, .{ .key = try a.dupe(u8, key), .etag = try a.dupe(u8, etag), .last_modified = modified, .size = std.fmt.parseInt(u64, std.mem.trim(u8, size, " \r\n\t"), 10) catch return error.InvalidResponse });
    }
    const truncated = std.mem.trim(u8, document.text(0, "IsTruncated") orelse return error.InvalidResponse, " \r\n\t");
    const is_truncated = std.mem.eql(u8, truncated, "true");
    if (!is_truncated and !std.mem.eql(u8, truncated, "false")) return error.InvalidResponse;
    const token = document.text(0, "NextContinuationToken");
    if (is_truncated and (token == null or token.?.len == 0)) return error.InvalidResponse;
    const copied_token = if (token) |value| try a.dupe(u8, value) else null;
    return .{ .arena = arena, .objects = objects.items, .is_truncated = is_truncated, .next_continuation_token = copied_token };
}

/// "2009-10-12T17:50:30.000Z" (ISO 8601, UTC) as Unix seconds.
fn parseTime(text: []const u8) ?u64 {
    if (text.len < 20 or text[4] != '-' or text[7] != '-' or text[10] != 'T' or text[13] != ':' or text[16] != ':' or text[text.len - 1] != 'Z') return null;
    const year = std.fmt.parseInt(u16, text[0..4], 10) catch return null;
    const month = std.fmt.parseInt(u8, text[5..7], 10) catch return null;
    const day = std.fmt.parseInt(u8, text[8..10], 10) catch return null;
    const hour = std.fmt.parseInt(u8, text[11..13], 10) catch return null;
    const minute = std.fmt.parseInt(u8, text[14..16], 10) catch return null;
    const second = std.fmt.parseInt(u8, text[17..19], 10) catch return null;
    if (year < 1970 or month == 0 or month > 12 or day == 0 or hour > 23 or minute > 59 or second > 60) return null;
    if (day > std.time.epoch.getDaysInMonth(year, @enumFromInt(month))) return null;
    var days: u64 = day - 1;
    for (1970..year) |y| days += std.time.epoch.getDaysInYear(@intCast(y));
    for (1..month) |m| days += std.time.epoch.getDaysInMonth(year, @enumFromInt(m));
    return days * 86400 + @as(u64, hour) * 3600 + @as(u64, minute) * 60 + second;
}

fn completionXml(allocator: Allocator, parts: []const CompletedPart) Error![]u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    output.writer.writeAll("<CompleteMultipartUpload>") catch return error.OutOfMemory;
    var previous: u16 = 0;
    for (parts) |part| {
        if (part.part_number <= previous or part.part_number > 10000 or part.etag.len == 0) return error.InvalidInput;
        const etag = try xml.escape(allocator, part.etag);
        defer allocator.free(etag);
        output.writer.print("<Part><PartNumber>{d}</PartNumber><ETag>{s}</ETag></Part>", .{ part.part_number, etag }) catch return error.OutOfMemory;
        previous = part.part_number;
    }
    output.writer.writeAll("</CompleteMultipartUpload>") catch return error.OutOfMemory;
    return output.toOwnedSlice();
}

const testing = std.testing;
const test_timestamp = "20130524T000000Z";
const test_credentials: Credentials = .{ .access_key_id = "test", .secret_access_key = "test-secret" };

const Fake = struct {
    const Step = struct {
        method: std.http.Method,
        url: []const u8,
        status: u16 = 200,
        body: []const u8 = "",
        response_headers: []const http.Header = &.{},
        request_headers: []const http.Header = &.{},
        request_body: ?[]const u8 = null,
        failure: ?http.Error = null,
    };
    steps: []const Step,
    calls: usize = 0,
    delays: [16]u64 = undefined,
    sleeps: usize = 0,

    fn transport(self: *Fake) Transport {
        return .{ .context = self, .send = send, .sleep = sleep };
    }
    fn send(context: *anyopaque, allocator: Allocator, request: http.Request) http.Error!Response {
        const self: *Fake = @ptrCast(@alignCast(context));
        std.debug.assert(self.calls < self.steps.len);
        const step = self.steps[self.calls];
        self.calls += 1;
        std.debug.assert(step.method == request.method);
        std.debug.assert(std.mem.eql(u8, step.url, request.url));
        for (step.request_headers) |wanted| {
            var found = false;
            for (request.headers) |header| {
                if (std.ascii.eqlIgnoreCase(wanted.name, header.name)) {
                    std.debug.assert(std.mem.eql(u8, wanted.value, header.value));
                    found = true;
                }
            }
            std.debug.assert(found);
        }
        if (step.request_body) |expected| {
            switch (request.body) {
                .bytes => |bytes| std.debug.assert(std.mem.eql(u8, expected, bytes)),
                .stream => |stream| {
                    var buffer: [128]u8 = undefined;
                    const n = try stream.read_at(stream.context, 0, &buffer);
                    std.debug.assert(std.mem.eql(u8, expected, buffer[0..n]));
                },
            }
        }
        if (step.failure) |failure| return failure;
        return Response.init(allocator, step.status, step.response_headers, step.body);
    }
    fn sleep(context: *anyopaque, delay_ms: u64) http.Error!void {
        const self: *Fake = @ptrCast(@alignCast(context));
        std.debug.assert(self.sleeps < self.delays.len);
        self.delays[self.sleeps] = delay_ms;
        self.sleeps += 1;
    }
    fn client(self: *Fake) !Client {
        return Client.init(testing.allocator, .{
            .endpoint = "https://endpoint",
            .bucket = "bucket",
        }, test_credentials, self.transport());
    }
};

test "path style Range GET encoding and HEAD metadata" {
    var fake: Fake = .{ .steps = &.{
        .{ .method = .GET, .url = "https://endpoint/bucket/packs/a%20%2B%252F//b", .status = 206, .body = "0123456789", .request_headers = &.{.{ .name = "range", .value = "bytes=0-9" }} },
        .{ .method = .HEAD, .url = "https://endpoint/bucket/key", .response_headers = &.{.{ .name = "Content-Length", .value = "32" }} },
    } };
    var client = try fake.client();
    var get = try client.getObject("packs/a +%2F//b", .{ .start = 0, .end = 9 }, test_timestamp);
    defer get.deinit();
    try testing.expectEqualStrings("0123456789", get.body);
    var head = try client.headObject("key", test_timestamp);
    defer head.deinit();
    try testing.expectEqualStrings("32", head.header("content-length").?);
    try testing.expectEqual(@as(usize, 2), fake.calls);
}

test "ListObjectsV2 XML pagination and opaque continuation tokens" {
    var fake: Fake = .{ .steps = &.{
        .{ .method = .GET, .url = "https://endpoint/bucket?list-type=2&max-keys=1000&prefix=packs%2F", .body = "<ListBucketResult xmlns=\"http://s3.amazonaws.com/doc/2006-03-01/\"><IsTruncated>true</IsTruncated>" ++
            "<Contents><Key>packs/a&amp;b</Key><Size>42</Size><ETag>&quot;abc&quot;</ETag></Contents>" ++
            "<NextContinuationToken>a+/=&amp;</NextContinuationToken></ListBucketResult>" },
        .{ .method = .GET, .url = "https://endpoint/bucket?continuation-token=a%2B%2F%3D%26&list-type=2&max-keys=1000&prefix=packs%2F", .body = "<ListBucketResult><IsTruncated>false</IsTruncated></ListBucketResult>" },
    } };
    var client = try fake.client();
    var first = try client.listObjectsV2(.{ .prefix = "packs/" }, test_timestamp);
    defer first.deinit();
    try testing.expect(first.is_truncated);
    try testing.expectEqualStrings("packs/a&b", first.objects[0].key);
    try testing.expectEqual(@as(u64, 42), first.objects[0].size);
    try testing.expectEqualStrings("\"abc\"", first.objects[0].etag);
    var second = try client.listObjectsV2(.{ .prefix = "packs/", .continuation_token = first.next_continuation_token }, test_timestamp);
    defer second.deinit();
    try testing.expect(!second.is_truncated);
    try testing.expectEqual(@as(usize, 0), second.objects.len);
    try testing.expectEqual(@as(usize, 2), fake.calls);
}

test "conditional PUT reports 412 without retry and supports If-Match" {
    var fake: Fake = .{ .steps = &.{
        .{ .method = .PUT, .url = "https://endpoint/bucket/lease", .status = 412, .body = "proxy error", .request_headers = &.{.{ .name = "If-None-Match", .value = "*" }} },
        .{ .method = .PUT, .url = "https://endpoint/bucket/lease", .request_headers = &.{.{ .name = "If-Match", .value = "\"v1\"" }}, .response_headers = &.{.{ .name = "ETag", .value = "\"v2\"" }} },
    } };
    var client = try fake.client();
    try testing.expectError(error.PreconditionFailed, client.putObject("lease", .{ .bytes = "data" }, .{ .condition = .if_none_match }, test_timestamp));
    var response = try client.putObject("lease", .{ .bytes = "data" }, .{ .condition = .{ .if_match = "\"v1\"" } }, test_timestamp);
    defer response.deinit();
    try testing.expectEqualStrings("\"v2\"", response.header("ETag").?);
    try testing.expectEqual(@as(usize, 0), fake.sleeps);
}

test "503 and 429 retry with exponential backoff then success" {
    var fake: Fake = .{ .steps = &.{
        .{ .method = .GET, .url = "https://endpoint/bucket/key", .status = 503 },
        .{ .method = .GET, .url = "https://endpoint/bucket/key", .status = 429 },
        .{ .method = .GET, .url = "https://endpoint/bucket/key", .body = "ok" },
    } };
    var client = try fake.client();
    var response = try client.getObject("key", null, test_timestamp);
    defer response.deinit();
    try testing.expectEqualStrings("ok", response.body);
    try testing.expectEqualSlices(u64, &.{ 100, 200 }, fake.delays[0..fake.sleeps]);
}

test "network retry and exhausted retry errors are distinct from 4xx" {
    var fake: Fake = .{ .steps = &.{
        .{ .method = .DELETE, .url = "https://endpoint/bucket/key", .failure = error.NetworkFailure },
        .{ .method = .DELETE, .url = "https://endpoint/bucket/key", .status = 204 },
        .{ .method = .HEAD, .url = "https://endpoint/bucket/key", .status = 404 },
        .{ .method = .HEAD, .url = "https://endpoint/bucket/key", .status = 403 },
    } };
    var client = try fake.client();
    try client.deleteObject("key", test_timestamp);
    try testing.expectError(error.NotFound, client.headObject("key", test_timestamp));
    try testing.expectError(error.AccessDenied, client.headObject("key", test_timestamp));
    try testing.expectEqual(@as(usize, 1), fake.sleeps);
}

test "multipart create upload complete abort and XML escaping" {
    var fake: Fake = .{ .steps = &.{
        .{ .method = .POST, .url = "https://endpoint/bucket/pack?uploads=", .body = "<InitiateMultipartUploadResult><UploadId>a+/=</UploadId></InitiateMultipartUploadResult>" },
        .{ .method = .PUT, .url = "https://endpoint/bucket/pack?partNumber=1&uploadId=a%2B%2F%3D", .request_body = "part", .response_headers = &.{.{ .name = "ETag", .value = "\"a&b\"" }} },
        .{ .method = .POST, .url = "https://endpoint/bucket/pack?uploadId=a%2B%2F%3D", .request_headers = &.{.{ .name = "if-none-match", .value = "*" }}, .request_body = "<CompleteMultipartUpload><Part><PartNumber>1</PartNumber><ETag>&quot;a&amp;b&quot;</ETag></Part></CompleteMultipartUpload>", .body = "<CompleteMultipartUploadResult><ETag>&quot;done&quot;</ETag></CompleteMultipartUploadResult>" },
        .{ .method = .DELETE, .url = "https://endpoint/bucket/pack?uploadId=a%2B%2F%3D", .status = 204 },
    } };
    var client = try fake.client();
    const upload_id = try client.createMultipartUpload("pack", .{}, test_timestamp);
    defer testing.allocator.free(upload_id);
    var part = try client.uploadPart("pack", upload_id, 1, .{ .bytes = "part" }, test_timestamp);
    defer part.deinit();
    var complete = try client.completeMultipartUpload("pack", upload_id, &.{.{ .part_number = 1, .etag = part.header("etag").? }}, .if_none_match, test_timestamp);
    defer complete.deinit();
    try client.abortMultipartUpload("pack", upload_id, test_timestamp);
    try testing.expectEqual(@as(usize, 4), fake.calls);
}

test "GetBucketVersioning: enabled, suspended, never set, and a store without it" {
    const url = "https://endpoint/bucket?versioning=";
    var fake: Fake = .{ .steps = &.{
        .{ .method = .GET, .url = url, .body = "<VersioningConfiguration><Status>Enabled</Status></VersioningConfiguration>" },
        .{ .method = .GET, .url = url, .body = "<VersioningConfiguration><Status>Suspended</Status></VersioningConfiguration>" },
        .{ .method = .GET, .url = url, .body = "<VersioningConfiguration xmlns=\"http://s3.amazonaws.com/doc/2006-03-01/\"/>" },
        .{ .method = .GET, .url = url, .status = 501, .body = "<Error><Code>NotImplemented</Code></Error>" },
        .{ .method = .GET, .url = url, .status = 501 },
        .{ .method = .GET, .url = url, .body = "<VersioningConfiguration><Status>Other</Status></VersioningConfiguration>" },
        .{ .method = .GET, .url = url, .status = 403, .body = "<Error><Code>AccessDenied</Code></Error>" },
    } };
    var client = try fake.client();
    try testing.expectEqual(Versioning.enabled, try client.getBucketVersioning(test_timestamp));
    try testing.expectEqual(Versioning.suspended, try client.getBucketVersioning(test_timestamp));
    try testing.expectEqual(Versioning.off, try client.getBucketVersioning(test_timestamp));
    try testing.expectEqual(Versioning.off, try client.getBucketVersioning(test_timestamp));
    try testing.expectEqual(Versioning.off, try client.getBucketVersioning(test_timestamp));
    try testing.expectError(error.InvalidResponse, client.getBucketVersioning(test_timestamp));
    try testing.expectError(error.AccessDenied, client.getBucketVersioning(test_timestamp));
    // A 501 is an answer, not an outage: never retried.
    try testing.expectEqual(@as(usize, 0), fake.sleeps);
}

test "storage class is a signed header on PUT and CreateMultipartUpload only when asked" {
    const Check = struct {
        fn send(context: *anyopaque, allocator: Allocator, request: http.Request) http.Error!Response {
            const wanted: *const ?[]const u8 = @ptrCast(@alignCast(context));
            var class: ?[]const u8 = null;
            var signed = false;
            for (request.headers) |h| {
                if (std.ascii.eqlIgnoreCase(h.name, "x-amz-storage-class")) class = h.value;
                if (std.ascii.eqlIgnoreCase(h.name, "authorization")) signed = std.mem.indexOf(u8, h.value, ";x-amz-storage-class,") != null;
            }
            std.debug.assert((class == null) == (wanted.* == null));
            if (wanted.*) |w| std.debug.assert(std.mem.eql(u8, w, class.?));
            std.debug.assert(signed == (wanted.* != null));
            return Response.init(allocator, 200, &.{}, if (request.method == .POST) "<InitiateMultipartUploadResult><UploadId>id</UploadId></InitiateMultipartUploadResult>" else "");
        }
        fn sleep(_: *anyopaque, _: u64) http.Error!void {}
    };
    var wanted: ?[]const u8 = "DEEP_ARCHIVE";
    var client = try Client.init(testing.allocator, .{ .endpoint = "https://endpoint", .bucket = "bucket" }, test_credentials, .{ .context = &wanted, .send = Check.send, .sleep = Check.sleep });
    var cold = try client.putObject("packs/a", .{ .bytes = "data" }, .{ .storage_class = "DEEP_ARCHIVE", .condition = .if_none_match }, test_timestamp);
    cold.deinit();
    testing.allocator.free(try client.createMultipartUpload("packs/b", .{ .storage_class = "DEEP_ARCHIVE" }, test_timestamp));
    wanted = null;
    var plain = try client.putObject("index/a", .{ .bytes = "data" }, .{}, test_timestamp);
    plain.deinit();
    testing.allocator.free(try client.createMultipartUpload("packs/c", .{}, test_timestamp));
    try testing.expectError(error.InvalidInput, client.putObject("packs/a", .{ .bytes = "" }, .{ .storage_class = "" }, test_timestamp));
}

test "RestoreObject request XML, 409 already in progress, and x-amz-restore from HEAD" {
    const body = "<RestoreRequest xmlns=\"http://s3.amazonaws.com/doc/2006-03-01/\"><Days>7</Days><GlacierJobParameters><Tier>Bulk</Tier></GlacierJobParameters></RestoreRequest>";
    const fast = "<RestoreRequest xmlns=\"http://s3.amazonaws.com/doc/2006-03-01/\"><Days>2</Days><GlacierJobParameters><Tier>Expedited</Tier></GlacierJobParameters></RestoreRequest>";
    var fake: Fake = .{ .steps = &.{
        .{ .method = .POST, .url = "https://endpoint/bucket/packs/a?restore=", .status = 202, .request_body = body, .request_headers = &.{.{ .name = "content-type", .value = "application/xml" }} },
        .{ .method = .POST, .url = "https://endpoint/bucket/packs/a?restore=", .status = 409, .request_body = fast, .body = "<Error><Code>RestoreAlreadyInProgress</Code></Error>" },
        .{ .method = .POST, .url = "https://endpoint/bucket/packs/a?restore=", .status = 409, .body = "<Error><Code>OperationAborted</Code></Error>" },
        .{ .method = .POST, .url = "https://endpoint/bucket/packs/a?restore=", .status = 403, .body = "<Error><Code>InvalidObjectState</Code></Error>" },
        .{ .method = .HEAD, .url = "https://endpoint/bucket/packs/a", .response_headers = &.{ .{ .name = "Content-Length", .value = "42" }, .{ .name = "x-amz-storage-class", .value = "DEEP_ARCHIVE" } } },
        .{ .method = .HEAD, .url = "https://endpoint/bucket/packs/a", .response_headers = &.{ .{ .name = "x-amz-storage-class", .value = "GLACIER" }, .{ .name = "x-amz-restore", .value = "ongoing-request=\"true\"" } } },
        .{ .method = .HEAD, .url = "https://endpoint/bucket/packs/a", .response_headers = &.{.{ .name = "X-Amz-Restore", .value = "ongoing-request=\"false\", expiry-date=\"Fri, 21 Dec 2012 00:00:00 GMT\"" }} },
    } };
    var client = try fake.client();
    try client.restoreObject("packs/a", .{}, test_timestamp);
    try client.restoreObject("packs/a", .{ .days = 2, .tier = .Expedited }, test_timestamp);
    try testing.expectError(error.Conflict, client.restoreObject("packs/a", .{}, test_timestamp));
    try testing.expectError(error.InvalidObjectState, client.restoreObject("packs/a", .{}, test_timestamp));
    try testing.expectError(error.InvalidInput, client.restoreObject("packs/a", .{ .days = 0 }, test_timestamp));
    var archived = try client.headObject("packs/a", test_timestamp);
    defer archived.deinit();
    const cold = objectState(&archived);
    try testing.expectEqual(@as(?u64, 42), cold.size);
    try testing.expectEqualStrings("DEEP_ARCHIVE", cold.storage_class);
    try testing.expect(cold.restore == .none);
    var thawing = try client.headObject("packs/a", test_timestamp);
    defer thawing.deinit();
    try testing.expect(objectState(&thawing).restore == .ongoing);
    var ready = try client.headObject("packs/a", test_timestamp);
    defer ready.deinit();
    const state = objectState(&ready);
    try testing.expectEqualStrings("STANDARD", state.storage_class);
    try testing.expectEqualStrings("Fri, 21 Dec 2012 00:00:00 GMT", state.restore.ready);
    try testing.expectEqual(@as(usize, 0), fake.sleeps);
}

test "ListObjectsV2 LastModified is Unix seconds and malformed dates are refused" {
    try testing.expectEqual(@as(?u64, 1255369830), parseTime("2009-10-12T17:50:30.000Z"));
    try testing.expectEqual(@as(?u64, 1709251200), parseTime("2024-03-01T00:00:00Z"));
    try testing.expectEqual(@as(?u64, null), parseTime("2024-02-30T00:00:00Z"));
    var list = try parseList(testing.allocator, "<ListBucketResult><IsTruncated>false</IsTruncated><Contents><Key>a</Key><LastModified>2024-03-01T00:00:01.000Z</LastModified><Size>1</Size><ETag>x</ETag></Contents></ListBucketResult>");
    defer list.deinit();
    try testing.expectEqual(@as(u64, 1709251201), list.objects[0].last_modified);
    try testing.expectError(error.InvalidResponse, parseList(testing.allocator, "<ListBucketResult><IsTruncated>false</IsTruncated><Contents><Key>a</Key><LastModified>yesterday</LastModified><Size>1</Size><ETag>x</ETag></Contents></ListBucketResult>"));
}

test "multipart embedded 200 error is retried" {
    var fake: Fake = .{ .steps = &.{
        .{ .method = .POST, .url = "https://endpoint/bucket/pack?uploadId=id", .body = " \n<Error><Code>InternalError</Code></Error>" },
        .{ .method = .POST, .url = "https://endpoint/bucket/pack?uploadId=id", .body = "<CompleteMultipartUploadResult/>" },
    } };
    var client = try fake.client();
    var response = try client.completeMultipartUpload("pack", "id", &.{.{ .part_number = 1, .etag = "etag" }}, .none, test_timestamp);
    defer response.deinit();
    try testing.expectEqual(@as(usize, 1), fake.sleeps);
}

test "streamed PUT replays after a network failure using UNSIGNED-PAYLOAD" {
    const Source = struct {
        reads: usize = 0,
        fn read(context: *anyopaque, offset: u64, buffer: []u8) http.Error!usize {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.reads += 1;
            const bytes = "streamed";
            if (offset > bytes.len) return error.BodyReadFailed;
            const remaining = bytes[@intCast(offset)..];
            const n = @min(buffer.len, remaining.len);
            @memcpy(buffer[0..n], remaining[0..n]);
            return n;
        }
    };
    const headers = &[_]http.Header{.{ .name = "x-amz-content-sha256", .value = "UNSIGNED-PAYLOAD" }};
    var fake: Fake = .{ .steps = &.{
        .{ .method = .PUT, .url = "https://endpoint/bucket/pack", .failure = error.NetworkFailure, .request_headers = headers, .request_body = "streamed" },
        .{ .method = .PUT, .url = "https://endpoint/bucket/pack", .request_headers = headers, .request_body = "streamed" },
    } };
    var source: Source = .{};
    var client = try fake.client();
    var response = try client.putObject("pack", .{ .stream = .{
        .context = &source,
        .length = 8,
        .read_at = Source.read,
    } }, .{}, test_timestamp);
    defer response.deinit();
    try testing.expectEqual(@as(usize, 2), source.reads);
    try testing.expectEqual(@as(usize, 1), fake.sleeps);
}

test "retry limit and delay cap are respected" {
    var fake: Fake = .{ .steps = &.{
        .{ .method = .HEAD, .url = "https://endpoint/bucket/key", .status = 503 },
        .{ .method = .HEAD, .url = "https://endpoint/bucket/key", .status = 503 },
        .{ .method = .HEAD, .url = "https://endpoint/bucket/key", .status = 503 },
    } };
    var client = try fake.client();
    client.config.retry.max_delay_ms = 150;
    try testing.expectError(error.ServiceUnavailable, client.headObject("key", test_timestamp));
    try testing.expectEqualSlices(u64, &.{ 100, 150 }, fake.delays[0..fake.sleeps]);
    try testing.expectEqual(@as(usize, 3), fake.calls);
}

test "4xx never retries even if its XML code suggests a transient error" {
    var fake: Fake = .{ .steps = &.{
        .{ .method = .GET, .url = "https://endpoint/bucket/key", .status = 400, .body = "<Error><Code>SlowDown</Code></Error>" },
        .{ .method = .GET, .url = "https://endpoint/bucket/key", .failure = error.TlsFailure },
        .{ .method = .DELETE, .url = "https://endpoint/bucket/key?uploadId=id", .status = 404, .body = "<Error><Code>NoSuchUpload</Code></Error>" },
    } };
    var client = try fake.client();
    try testing.expectError(error.Throttled, client.getObject("key", null, test_timestamp));
    try testing.expectError(error.TlsFailure, client.getObject("key", null, test_timestamp));
    try testing.expectError(error.NoSuchUpload, client.abortMultipartUpload("key", "id", test_timestamp));
    try testing.expectEqual(@as(usize, 0), fake.sleeps);
}

test "malformed list and multipart input are rejected" {
    try testing.expectError(error.InvalidResponse, parseList(testing.allocator, "<ListBucketResult><IsTruncated>true</IsTruncated></ListBucketResult>"));
    try testing.expectError(error.InvalidResponse, parseList(testing.allocator, "<ListBucketResult><IsTruncated>false</IsTruncated><Contents><Key>a</Key><Size>-1</Size><ETag>x</ETag></Contents></ListBucketResult>"));
    try testing.expectError(error.InvalidInput, completionXml(testing.allocator, &.{
        .{ .part_number = 2, .etag = "b" }, .{ .part_number = 1, .etag = "a" },
    }));
}

fn allocationChecks(allocator: Allocator) !void {
    var list = try parseList(allocator, "<ListBucketResult><IsTruncated>true</IsTruncated><NextContinuationToken>next</NextContinuationToken>" ++
        "<Contents><Key>one&amp;two</Key><Size>12</Size><ETag>&quot;abc&quot;</ETag></Contents></ListBucketResult>");
    defer list.deinit();
    const completion = try completionXml(allocator, &.{.{ .part_number = 1, .etag = "\"etag\"" }});
    defer allocator.free(completion);
    var fake: Fake = .{ .steps = &.{.{ .method = .GET, .url = "https://endpoint/bucket/key", .body = "ok" }} };
    var client = try Client.init(allocator, .{ .endpoint = "https://endpoint", .bucket = "bucket" }, test_credentials, fake.transport());
    var response = try client.getObject("key", null, test_timestamp);
    defer response.deinit();
}

test "allocation failures clean up signing requests XML and owned results" {
    try testing.checkAllAllocationFailures(testing.allocator, allocationChecks, .{});
}

fn liveTimestamp() [16]u8 {
    const seconds = std.Io.Clock.real.now(testing.io).toSeconds();
    const epoch: std.time.epoch.EpochSeconds = .{ .secs = @intCast(seconds) };
    const year_day = epoch.getEpochDay().calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const day = epoch.getDaySeconds();
    var buffer: [16]u8 = undefined;
    _ = std.fmt.bufPrint(&buffer, "{d:0>4}{d:0>2}{d:0>2}T{d:0>2}{d:0>2}{d:0>2}Z", .{
        year_day.year,         month_day.month.numeric(), @as(u8, month_day.day_index) + 1,
        day.getHoursIntoDay(), day.getMinutesIntoHour(),  day.getSecondsIntoMinute(),
    }) catch unreachable;
    return buffer;
}

// Uses an already-existing bucket, and only touches a random test object.
test "optional live MinIO object operations" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const names = [_][]const u8{
        "NOMADFS_S3_TEST_ENDPOINT", "NOMADFS_S3_TEST_BUCKET", "NOMADFS_S3_TEST_KEY", "NOMADFS_S3_TEST_SECRET",
    };
    var values: [4][]const u8 = undefined;
    for (names, &values) |name, *value| {
        value.* = testing.environ.getAlloc(a, name) catch |err| switch (err) {
            error.EnvironmentVariableMissing => return error.SkipZigTest,
            else => return err,
        };
        if (value.len == 0) return error.SkipZigTest;
    }
    var http_client: std.http.Client = .{ .allocator = testing.allocator, .io = testing.io };
    defer http_client.deinit();
    var adapter: HttpTransport = .{ .client = &http_client };
    var client = try Client.init(testing.allocator, .{ .endpoint = values[0], .bucket = values[1], .region = "us-east-1" }, .{ .access_key_id = values[2], .secret_access_key = values[3] }, adapter.transport());
    var random: [16]u8 = undefined;
    testing.io.random(&random);
    const hex = std.fmt.bytesToHex(random, .lower);
    const key = try std.fmt.allocPrint(a, "nomadfs-s3-test/{s}/é +%.txt", .{hex});
    const timestamp = liveTimestamp();
    try liveObjectChecks(&client, key, &timestamp);
}

fn liveObjectChecks(client: *Client, key: []const u8, timestamp: []const u8) !void {
    var put = try client.putObject(key, .{ .bytes = "0123456789" }, .{ .condition = .if_none_match }, timestamp);
    defer put.deinit();
    defer client.deleteObject(key, timestamp) catch {};
    try testing.expect(put.header("etag") != null);
    try testing.expectError(error.PreconditionFailed, client.putObject(key, .{ .bytes = "duplicate" }, .{ .condition = .if_none_match }, timestamp));
    var get = try client.getObject(key, .{ .start = 2, .end = 5 }, timestamp);
    defer get.deinit();
    try testing.expectEqual(@as(u16, 206), get.status);
    try testing.expectEqualStrings("2345", get.body);
    var head = try client.headObject(key, timestamp);
    defer head.deinit();
    try testing.expectEqualStrings("10", head.header("content-length").?);
    var list = try client.listObjectsV2(.{ .prefix = key }, timestamp);
    defer list.deinit();
    try testing.expectEqual(@as(usize, 1), list.objects.len);
    try testing.expectEqualStrings(key, list.objects[0].key);
    try liveMultipartChecks(client, key, timestamp);
}

fn liveMultipartChecks(client: *Client, key: []const u8, timestamp: []const u8) !void {
    const upload_id = try client.createMultipartUpload(key, .{}, timestamp);
    defer client.allocator.free(upload_id);
    errdefer client.abortMultipartUpload(key, upload_id, timestamp) catch {};
    var part = try client.uploadPart(key, upload_id, 1, .{ .bytes = "multipart" }, timestamp);
    defer part.deinit();
    var complete = try client.completeMultipartUpload(key, upload_id, &.{.{ .part_number = 1, .etag = part.header("etag").? }}, .none, timestamp);
    defer complete.deinit();
    var get = try client.getObject(key, null, timestamp);
    defer get.deinit();
    try testing.expectEqualStrings("multipart", get.body);
    const abandoned = try client.createMultipartUpload(key, .{}, timestamp);
    defer client.allocator.free(abandoned);
    try client.abortMultipartUpload(key, abandoned, timestamp);
}
