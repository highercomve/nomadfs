const std = @import("std");
const nomadfs = @import("nomadfs");
const compat = nomadfs.net.compat;
const UPnP = @TypeOf(@as(nomadfs.net.transport.manager.ConnectionManager, undefined).upnp);
const local_addrs = nomadfs.net.local_addrs;
const sync = nomadfs.sync;

const FakeIgdServer = struct {
    server: compat.Server,
    thread: ?std.Thread = null,
    running: std.atomic.Value(bool) = std.atomic.Value(bool).init(true),
    port: u16,

    get_count: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    add_count: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    delete_count: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),

    desc_xml: []const u8,
    reject_lease_3600_with_725: bool = false,
    external_ip_response: ?[]const u8 = null,

    pub fn start(port: u16, desc_xml: []const u8) !*FakeIgdServer {
        const self = try std.testing.allocator.create(FakeIgdServer);
        self.* = .{
            .server = try compat.listen(port),
            .port = port,
            .desc_xml = desc_xml,
        };
        self.thread = try std.Thread.spawn(.{}, run, .{self});
        return self;
    }

    pub fn stop(self: *FakeIgdServer) void {
        self.running.store(false, .release);
        self.server.deinit();
        if (self.thread) |t| {
            t.join();
            self.thread = null;
        }
        std.testing.allocator.destroy(self);
    }

    fn run(self: *FakeIgdServer) void {
        while (self.running.load(.acquire)) {
            const conn = self.server.accept() catch break;
            defer conn.stream.close();

            var buf: [4096]u8 = undefined;
            var total: usize = 0;
            while (total < buf.len) {
                const n = conn.stream.read(buf[total..]) catch break;
                if (n == 0) break;
                total += n;
                if (std.mem.indexOf(u8, buf[0..total], "\r\n\r\n")) |header_end| {
                    const headers = buf[0..header_end];
                    if (std.mem.indexOf(u8, headers, "Content-Length:")) |cl_idx| {
                        const cl_rest = headers[cl_idx + "Content-Length:".len ..];
                        const line_end = std.mem.indexOfAny(u8, cl_rest, "\r\n") orelse cl_rest.len;
                        const cl_val = std.fmt.parseInt(usize, std.mem.trim(u8, cl_rest[0..line_end], " \t"), 10) catch 0;
                        const body_read = total - (header_end + 4);
                        if (body_read < cl_val) continue;
                    }
                    break;
                }
            }

            const req = buf[0..total];
            if (std.mem.startsWith(u8, req, "GET ")) {
                _ = self.get_count.fetchAdd(1, .monotonic);
                var resp_buf: [4096]u8 = undefined;
                const resp = std.fmt.bufPrint(&resp_buf, "HTTP/1.0 200 OK\r\nContent-Type: text/xml\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n{s}", .{ self.desc_xml.len, self.desc_xml }) catch continue;
                conn.stream.writeAll(resp) catch {};
            } else if (std.mem.startsWith(u8, req, "POST ")) {
                if (std.mem.indexOf(u8, req, "AddPortMapping") != null) {
                    _ = self.add_count.fetchAdd(1, .monotonic);
                    if (self.reject_lease_3600_with_725 and std.mem.indexOf(u8, req, "<NewLeaseDuration>3600</NewLeaseDuration>") != null) {
                        const fault_body =
                            "<s:Envelope xmlns:s=\"http://schemas.xmlsoap.org/soap/envelope/\">" ++
                            "<s:Body><s:Fault><errorCode>725</errorCode></s:Fault></s:Body></s:Envelope>";
                        var resp_buf: [1024]u8 = undefined;
                        const resp = std.fmt.bufPrint(&resp_buf, "HTTP/1.0 500 Internal Server Error\r\nContent-Type: text/xml\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n{s}", .{ fault_body.len, fault_body }) catch continue;
                        conn.stream.writeAll(resp) catch {};
                    } else {
                        const ok_body =
                            "<s:Envelope xmlns:s=\"http://schemas.xmlsoap.org/soap/envelope/\">" ++
                            "<s:Body><u:AddPortMappingResponse xmlns:u=\"urn:schemas-upnp-org:service:WANIPConnection:1\"/>" ++
                            "</s:Body></s:Envelope>";
                        var resp_buf: [1024]u8 = undefined;
                        const resp = std.fmt.bufPrint(&resp_buf, "HTTP/1.0 200 OK\r\nContent-Type: text/xml\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n{s}", .{ ok_body.len, ok_body }) catch continue;
                        conn.stream.writeAll(resp) catch {};
                    }
                } else if (std.mem.indexOf(u8, req, "DeletePortMapping") != null) {
                    _ = self.delete_count.fetchAdd(1, .monotonic);
                    const ok_body =
                        "<s:Envelope xmlns:s=\"http://schemas.xmlsoap.org/soap/envelope/\">" ++
                        "<s:Body><u:DeletePortMappingResponse xmlns:u=\"urn:schemas-upnp-org:service:WANIPConnection:1\"/>" ++
                        "</s:Body></s:Envelope>";
                    var resp_buf: [1024]u8 = undefined;
                    const resp = std.fmt.bufPrint(&resp_buf, "HTTP/1.0 200 OK\r\nContent-Type: text/xml\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n{s}", .{ ok_body.len, ok_body }) catch continue;
                    conn.stream.writeAll(resp) catch {};
                } else if (std.mem.indexOf(u8, req, "GetExternalIPAddress") != null) {
                    const ext_ip = self.external_ip_response orelse "198.51.100.1";
                    var body_buf: [512]u8 = undefined;
                    const ok_body = std.fmt.bufPrint(&body_buf, "<s:Envelope xmlns:s=\"http://schemas.xmlsoap.org/soap/envelope/\">" ++
                        "<s:Body><u:GetExternalIPAddressResponse xmlns:u=\"urn:schemas-upnp-org:service:WANIPConnection:1\">" ++
                        "<NewExternalIPAddress>{s}</NewExternalIPAddress>" ++
                        "</u:GetExternalIPAddressResponse></s:Body></s:Envelope>", .{ext_ip}) catch continue;
                    var resp_buf: [1024]u8 = undefined;
                    const resp = std.fmt.bufPrint(&resp_buf, "HTTP/1.0 200 OK\r\nContent-Type: text/xml\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n{s}", .{ ok_body.len, ok_body }) catch continue;
                    conn.stream.writeAll(resp) catch {};
                }
            }
        }
    }
};

test "upnp: lease 3600, mapped_port, deletePortMap, cached description" {
    const desc =
        \\<root>
        \\  <service>
        \\    <serviceType>urn:schemas-upnp-org:service:WANIPConnection:1</serviceType>
        \\    <controlURL>/ctl</controlURL>
        \\  </service>
        \\</root>
    ;
    const server = try FakeIgdServer.start(13501, desc);
    defer server.stop();

    var u = try UPnP.initForTest(std.testing.allocator, .{ 127, 0, 0, 1 }, 13501, "/desc.xml");
    defer u.deinit();

    try u.mapPort(9000, "TCP", "127.0.0.1");
    try std.testing.expectEqual(@as(?u16, 9000), u.mapped_port);

    try u.deletePortMap(9000, "TCP");
    try std.testing.expectEqual(@as(?u16, null), u.mapped_port);

    try std.testing.expectEqual(@as(usize, 1), server.get_count.load(.monotonic));
    try std.testing.expectEqual(@as(usize, 1), server.add_count.load(.monotonic));
    try std.testing.expectEqual(@as(usize, 1), server.delete_count.load(.monotonic));
}

test "upnp: error 725 retry with lease 0 and permanent_only flag" {
    const desc =
        \\<root>
        \\  <service>
        \\    <serviceType>urn:schemas-upnp-org:service:WANIPConnection:1</serviceType>
        \\    <controlURL>/ctl</controlURL>
        \\  </service>
        \\</root>
    ;
    const server = try FakeIgdServer.start(13502, desc);
    server.reject_lease_3600_with_725 = true;
    defer server.stop();

    var u = try UPnP.initForTest(std.testing.allocator, .{ 127, 0, 0, 1 }, 13502, "/desc.xml");
    defer u.deinit();

    try u.mapPort(9000, "TCP", "127.0.0.1");
    try std.testing.expect(u.permanent_only);
    try std.testing.expectEqual(@as(?u16, 9000), u.mapped_port);
    try std.testing.expectEqual(@as(usize, 2), server.add_count.load(.monotonic));
}

test "upnp: renewal loop and fast stop" {
    const desc =
        \\<root>
        \\  <service>
        \\    <serviceType>urn:schemas-upnp-org:service:WANIPConnection:1</serviceType>
        \\    <controlURL>/ctl</controlURL>
        \\  </service>
        \\</root>
    ;
    const server = try FakeIgdServer.start(13503, desc);
    defer server.stop();

    var u = try UPnP.initForTest(std.testing.allocator, .{ 127, 0, 0, 1 }, 13503, "/desc.xml");
    defer u.deinit();

    u.renew_after_seconds = 1;
    try u.mapPort(9000, "TCP", "127.0.0.1");

    var iters: usize = 0;
    while (iters < 30) : (iters += 1) {
        if (server.add_count.load(.monotonic) >= 2) break;
        sync.sleep(100 * std.time.ns_per_ms);
    }
    try std.testing.expect(server.add_count.load(.monotonic) >= 2);

    const start_time = sync.monotonicMillis();
    u.stop();
    const elapsed = sync.monotonicMillis() - start_time;
    try std.testing.expect(elapsed < 1000);
}

test "upnp: rejection of controlURL with CR/LF" {
    const desc =
        "<root><service>" ++
        "<serviceType>urn:schemas-upnp-org:service:WANIPConnection:1</serviceType>" ++
        "<controlURL>/ctl\r\nX: y</controlURL>" ++
        "</service></root>";
    const server = try FakeIgdServer.start(13504, desc);
    defer server.stop();

    var u = try UPnP.initForTest(std.testing.allocator, .{ 127, 0, 0, 1 }, 13504, "/desc.xml");
    defer u.deinit();

    const err = u.mapPort(9000, "TCP", "127.0.0.1");
    try std.testing.expectError(error.InvalidControlUrl, err);
    try std.testing.expectEqual(@as(usize, 0), server.add_count.load(.monotonic));
}

test "upnp: stale datagram flood resilience" {
    const net1 = local_addrs.Net{ .addr = .{ 192, 168, 1, 10 }, .mask = .{ 255, 255, 255, 0 } };
    const nets = [_]local_addrs.Net{net1};
    const expected_st = "urn:schemas-upnp-org:device:InternetGatewayDevice:1";

    const junk1 = "NOT-HTTP\r\n\r\n";
    const junk2 = "HTTP/1.1 200 OK\r\nST: urn:schemas-upnp-org:device:Other:1\r\n\r\n";
    const junk3 = "HTTP/1.1 200 OK\r\nLOCATION: http://8.8.8.8:5000/desc.xml\r\n\r\n";
    const junk4 = "HTTP/1.1 200 OK\r\nST: urn:schemas-upnp-org:device:InternetGatewayDevice:1\r\nUSN: uuid:1\r\nLOCATION: http://192.168.1.1:5000/desc.xml\r\n\r\n";

    var i: usize = 0;
    while (i < 10) : (i += 1) {
        const j = if (i % 3 == 0) junk1 else if (i % 3 == 1) junk2 else junk3;
        const rep = UPnP.parseSsdpReply(null, j, expected_st);
        if (rep) |r| {
            if (UPnP.locationHost(r.location)) |loc| {
                _ = UPnP.acceptResponder(.{ 8, 8, 8, 8 }, loc.ip, &nets, null);
            }
        }
    }

    const rep_valid = UPnP.parseSsdpReply(null, junk4, expected_st);
    try std.testing.expect(rep_valid != null);
    const loc_valid = UPnP.locationHost(rep_valid.?.location);
    try std.testing.expect(loc_valid != null);
    try std.testing.expect(UPnP.acceptResponder(.{ 192, 168, 1, 1 }, loc_valid.?.ip, &nets, null));
}
