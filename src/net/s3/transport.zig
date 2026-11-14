//! A replayable HTTP transport and the std.http.Client implementation.
const std = @import("std");
const Allocator = std.mem.Allocator;
pub const Header = std.http.Header;

pub const Error = error{
    OutOfMemory,
    NetworkFailure,
    TlsFailure,
    Canceled,
    InvalidRequest,
    InvalidResponse,
    ResponseTooLarge,
    BodyReadFailed,
};

pub const Body = union(enum) {
    bytes: []const u8,
    /// read_at must reproduce the same bytes at each offset on every attempt.
    /// The context is borrowed until the operation returns.
    stream: Stream,

    pub const Stream = struct {
        context: *anyopaque,
        length: u64,
        read_at: *const fn (*anyopaque, u64, []u8) Error!usize,
    };

    pub fn length(self: Body) u64 {
        return switch (self) {
            .bytes => |bytes| bytes.len,
            .stream => |stream| stream.length,
        };
    }
};

pub const Request = struct {
    method: std.http.Method,
    url: []const u8,
    headers: []const Header,
    body: Body = .{ .bytes = "" },
    max_response_bytes: usize = 64 * 1024 * 1024,
};

/// All slices belong to the arena. The caller must call deinit on success.
pub const Response = struct {
    arena: std.heap.ArenaAllocator,
    status: u16,
    headers: []const Header,
    body: []const u8,

    pub fn init(allocator: Allocator, status: u16, headers: []const Header, body: []const u8) Error!Response {
        var arena = std.heap.ArenaAllocator.init(allocator);
        errdefer arena.deinit();
        const a = arena.allocator();
        const copied = try a.alloc(Header, headers.len);
        for (headers, copied) |source, *item| item.* = .{
            .name = try a.dupe(u8, source.name),
            .value = try a.dupe(u8, source.value),
        };
        const copied_body = try a.dupe(u8, body);
        return .{ .arena = arena, .status = status, .headers = copied, .body = copied_body };
    }

    pub fn header(self: *const Response, name: []const u8) ?[]const u8 {
        for (self.headers) |item| if (std.ascii.eqlIgnoreCase(item.name, name)) return item.value;
        return null;
    }

    pub fn deinit(self: *Response) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

/// Implementations return an owned response or release all allocations on error.
pub const Transport = struct {
    context: *anyopaque,
    send: *const fn (*anyopaque, Allocator, Request) Error!Response,
    /// Injectable backoff clock. Implementations must actually wait or cancel.
    sleep: *const fn (*anyopaque, u64) Error!void,
};

/// Initialize with a caller-owned std.http.Client. Its Io supplies TLS and sleep.
/// The HTTP client must outlive this adapter and all operations using it.
pub const HttpTransport = struct {
    client: *std.http.Client,

    pub fn transport(self: *HttpTransport) Transport {
        return .{ .context = self, .send = send, .sleep = sleep };
    }

    fn sleep(context: *anyopaque, delay_ms: u64) Error!void {
        const self: *HttpTransport = @ptrCast(@alignCast(context));
        std.debug.assert(@intFromPtr(context) != 0);
        try self.client.io.sleep(.fromMilliseconds(@intCast(delay_ms)), .awake);
    }

    fn send(context: *anyopaque, allocator: Allocator, input: Request) Error!Response {
        const self: *HttpTransport = @ptrCast(@alignCast(context));
        std.debug.assert(@intFromPtr(context) != 0);
        const uri = std.Uri.parse(input.url) catch return error.InvalidRequest;
        var request = self.client.request(input.method, uri, .{
            .redirect_behavior = .unhandled,
            .headers = .{ .host = .omit, .authorization = .omit, .accept_encoding = .omit },
            .extra_headers = input.headers,
        }) catch |err| return mapError(err);
        defer request.deinit();
        try sendBody(&request, input.body);
        var response = request.receiveHead(&.{}) catch |err| return mapError(err);
        var arena = std.heap.ArenaAllocator.init(allocator);
        errdefer arena.deinit();
        const a = arena.allocator();
        var headers: std.ArrayList(Header) = .empty;
        var iterator = response.head.iterateHeaders();
        while (iterator.next()) |item| {
            try headers.append(a, .{
                .name = try a.dupe(u8, item.name),
                .value = try a.dupe(u8, item.value),
            });
        }
        const status: u16 = @intFromEnum(response.head.status);
        var transfer_buffer: [8192]u8 = undefined;
        const body = if (input.method == .HEAD) "" else response.reader(&transfer_buffer).allocRemaining(a, .limited(input.max_response_bytes)) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.StreamTooLong => return error.ResponseTooLarge,
            else => return error.NetworkFailure,
        };
        return .{ .arena = arena, .status = status, .headers = headers.items, .body = body };
    }

    fn sendBody(request: *std.http.Client.Request, body: Body) Error!void {
        if (!request.method.requestHasBody()) {
            if (body.length() != 0) return error.InvalidRequest;
            return request.sendBodiless() catch |err| return mapError(err);
        }
        request.transfer_encoding = .{ .content_length = body.length() };
        var write_buffer: [8192]u8 = undefined;
        var writer = request.sendBody(&write_buffer) catch |err| return mapError(err);
        switch (body) {
            .bytes => |bytes| writer.writer.writeAll(bytes) catch |err| return mapError(err),
            .stream => |stream| {
                var buffer: [64 * 1024]u8 = undefined;
                var offset: u64 = 0;
                while (offset < stream.length) {
                    const wanted: usize = @intCast(@min(buffer.len, stream.length - offset));
                    const n = try stream.read_at(stream.context, offset, buffer[0..wanted]);
                    if (n == 0 or n > wanted) return error.BodyReadFailed;
                    writer.writer.writeAll(buffer[0..n]) catch |err| return mapError(err);
                    offset += n;
                }
            },
        }
        writer.end() catch |err| return mapError(err);
        request.connection.?.flush() catch |err| return mapError(err);
    }
};

fn mapError(err: anyerror) Error {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.Canceled => error.Canceled,
        error.TlsInitializationFailed, error.TlsCertificateNotVerified, error.CertificateBundleLoadFailure, error.TlsAlert => error.TlsFailure,
        else => error.NetworkFailure,
    };
}

test "owned response headers are case insensitive" {
    var response = try Response.init(std.testing.allocator, 200, &.{.{ .name = "ETag", .value = "\"abc\"" }}, "data");
    defer response.deinit();
    try std.testing.expectEqualStrings("\"abc\"", response.header("etag").?);
    try std.testing.expect(response.header("missing") == null);
}

test "HTTP adapter is compiled with TLS support" {
    std.testing.refAllDecls(HttpTransport);
    try std.testing.expect(!std.http.Client.disable_tls);
}
