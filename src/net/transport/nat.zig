const std = @import("std");
const network = @import("mod.zig");
const compat = @import("../compat.zig");

const posix = std.posix;
const system = posix.system;

fn createSocket(domain: u32, sock_type: u32, protocol: u32) !posix.socket_t {
    const rc = system.socket(domain, sock_type, protocol);
    return switch (posix.errno(rc)) {
        .SUCCESS => @intCast(rc),
        else => |err| posix.unexpectedErrno(err),
    };
}

fn closeSocket(s: posix.socket_t) void {
    _ = system.close(@intCast(s));
}

fn sendtoSocket(s: posix.socket_t, buf: []const u8, flags: u32, addr: ?*const posix.sockaddr, alen: posix.socklen_t) !usize {
    const rc = system.sendto(@intCast(s), buf.ptr, buf.len, flags, addr, alen);
    return switch (posix.errno(rc)) {
        .SUCCESS => rc,
        else => |err| posix.unexpectedErrno(err),
    };
}

fn recvfromSocket(s: posix.socket_t, buf: []u8, flags: u32, addr: ?*posix.sockaddr, alen: ?*posix.socklen_t) !usize {
    const rc = system.recvfrom(@intCast(s), buf.ptr, buf.len, flags, addr, alen);
    return switch (posix.errno(rc)) {
        .SUCCESS => rc,
        .AGAIN => error.WouldBlock,
        else => |err| posix.unexpectedErrno(err),
    };
}

pub const UPnP = struct {
    allocator: std.mem.Allocator,
    gateway_url: ?[]const u8,
    local_ip: ?[]const u8,
    mapped_port: ?u16,

    pub fn init(allocator: std.mem.Allocator) UPnP {
        return .{ 
            .allocator = allocator,
            .gateway_url = null,
            .local_ip = null,
            .mapped_port = null,
        };
    }

    pub fn deinit(self: *UPnP) void {
        if (self.gateway_url) |url| self.allocator.free(url);
        if (self.local_ip) |ip| self.allocator.free(ip);
    }

    pub fn discoverGateway(self: *UPnP) !void {
        const ssdp_msg =
            "M-SEARCH * HTTP/1.1\r\n" ++
            "HOST: 239.255.255.250:1900\r\n" ++
            "MAN: \"ssdp:discover\"\r\n" ++
            "MX: 2\r\n" ++
            "ST: urn:schemas-upnp-org:device:InternetGatewayDevice:1\r\n" ++
            "\r\n";

        const socket = try createSocket(posix.AF.INET, posix.SOCK.DGRAM, 0);
        defer closeSocket(socket);

        const timeout = posix.timeval{ .sec = 2, .usec = 0 };
        posix.setsockopt(socket, posix.SOL.SOCKET, posix.SO.RCVTIMEO, std.mem.asBytes(&timeout)) catch {};

        const dest_addr = try compat.Address.parseIp("239.255.255.250", 1900);
        const dest_sa = dest_addr.toPosix();
        _ = try sendtoSocket(socket, ssdp_msg, 0, @ptrCast(&dest_sa), @sizeOf(@TypeOf(dest_sa)));

        var buf: [4096]u8 = undefined;
        var attempts: usize = 0;
        
        while (attempts < 3) : (attempts += 1) {
            const len = recvfromSocket(socket, &buf, 0, null, null) catch |err| {
                if (err == error.WouldBlock) continue;
                return err;
            };

            const response = buf[0..len];
            if (parseLocation(response)) |location| {
                self.gateway_url = try self.allocator.dupe(u8, location);
                std.debug.print("UPnP: Found gateway at {s}\n", .{location});
                return;
            }
        }
        return error.GatewayNotFound;
    }

    fn parseLocation(response: []const u8) ?[]const u8 {
        var it = std.mem.tokenizeAny(u8, response, "\r\n");
        while (it.next()) |line| {
            if (std.ascii.startsWithIgnoreCase(line, "LOCATION:")) {
                var parts = std.mem.tokenizeAny(u8, line, " ");
                _ = parts.next(); // LOCATION:
                return parts.next();
            }
        }
        return null;
    }

    fn fetchControlUrl(self: *UPnP) ![]const u8 {
        if (self.gateway_url == null) return error.NoGateway;
        const url_str = self.gateway_url.?;
        const uri = try std.Uri.parse(url_str);

        const port = uri.port orelse 80;
        const host_comp = uri.host orelse return error.InvalidGatewayUrl;
        const host = host_comp.percent_encoded;

        const addr = try compat.Address.parseIp(host, port);
        const stream = try compat.tcpConnectToAddress(addr);
        defer stream.close();

        var req_buf: [1024]u8 = undefined;
        const req = try std.fmt.bufPrint(&req_buf, "GET {s} HTTP/1.0\r\nHost: {s}\r\nConnection: close\r\n\r\n", .{ uri.path.percent_encoded, host });
        try stream.writeAll(req);

        var body_list: std.ArrayList(u8) = .empty;
        defer body_list.deinit(self.allocator);
        var read_buf: [1024]u8 = undefined;
        while (true) {
            const n = stream.read(&read_buf) catch break;
            if (n == 0) break;
            try body_list.appendSlice(self.allocator, read_buf[0..n]);
            if (body_list.items.len > 64 * 1024) break;
        }
        const body = body_list.items;

        const header_end = std.mem.indexOf(u8, body, "\r\n\r\n");
        if (header_end == null) return error.InvalidResponse;
        const xml_body = body[header_end.? + 4 ..];

        if (std.mem.indexOf(u8, xml_body, "urn:schemas-upnp-org:service:WANIPConnection:1")) |_| {
            const service_type = "urn:schemas-upnp-org:service:WANIPConnection:1";
            const idx = std.mem.indexOf(u8, xml_body, service_type) orelse return error.ServiceNotFound;
            const remaining = xml_body[idx..];
            const start_tag = "<controlURL>";
            const end_tag = "</controlURL>";
            if (std.mem.indexOf(u8, remaining, start_tag)) |start| {
                if (std.mem.indexOf(u8, remaining[start..], end_tag)) |end| {
                    const relative_url = remaining[start + start_tag.len .. start + end];
                    if (std.mem.startsWith(u8, relative_url, "/")) {
                        return try std.fmt.allocPrint(self.allocator, "{s}://{s}:{d}{s}", .{ uri.scheme, host, port, relative_url });
                    } else {
                        return try std.fmt.allocPrint(self.allocator, "{s}{s}", .{ url_str, relative_url });
                    }
                }
            }
        }
        return error.ControlUrlNotFound;
    }

    pub fn getLocalIP(self: *UPnP) ![]const u8 {
        if (self.gateway_url == null) return error.NoGateway;
        const uri = try std.Uri.parse(self.gateway_url.?);
        const host_comp = uri.host orelse return error.InvalidGatewayUrl;
        const host = host_comp.percent_encoded;
        const gateway_addr = try compat.Address.parseIp(host, 0);

        const socket = try createSocket(posix.AF.INET, posix.SOCK.DGRAM, 0);
        defer closeSocket(socket);
        const gw_sa = gateway_addr.toPosix();
        const rc = system.connect(@intCast(socket), @ptrCast(&gw_sa), @sizeOf(@TypeOf(gw_sa)));
        _ = switch (posix.errno(rc)) {
            .SUCCESS => {},
            else => |err| return posix.unexpectedErrno(err),
        };

        var local_sa: posix.sockaddr.in = undefined;
        var len: posix.socklen_t = @sizeOf(posix.sockaddr.in);
        const rc_name = system.getsockname(@intCast(socket), @ptrCast(&local_sa), &len);
        _ = switch (posix.errno(rc_name)) {
            .SUCCESS => {},
            else => |err| return posix.unexpectedErrno(err),
        };

        const bytes = @as([4]u8, @bitCast(local_sa.addr));
        return try std.fmt.allocPrint(self.allocator, "{d}.{d}.{d}.{d}", .{ bytes[0], bytes[1], bytes[2], bytes[3] });
    }

    pub fn mapPort(self: *UPnP, port: u16, protocol: []const u8, local_ip_str: []const u8) !void {
        const control_url_str = try self.fetchControlUrl();
        defer self.allocator.free(control_url_str);

        const uri = try std.Uri.parse(control_url_str);
        const host_comp = uri.host orelse return error.InvalidGatewayUrl;
        const host = host_comp.percent_encoded;
        const port_num = uri.port orelse 80;

        const addr = try compat.Address.parseIp(host, port_num);
        const stream = try compat.tcpConnectToAddress(addr);
        defer stream.close();

        const soap_body = try std.fmt.allocPrint(self.allocator,
            \\<?xml version="1.0"?>
            \\<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">
            \\<s:Body>
            \\<u:AddPortMapping xmlns:u="urn:schemas-upnp-org:service:WANIPConnection:1">
            \\<NewRemoteHost></NewRemoteHost>
            \\<NewExternalPort>{d}</NewExternalPort>
            \\<NewProtocol>{s}</NewProtocol>
            \\<NewInternalPort>{d}</NewInternalPort>
            \\<NewInternalClient>{s}</NewInternalClient>
            \\<NewEnabled>1</NewEnabled>
            \\<NewPortMappingDescription>NomadFS</NewPortMappingDescription>
            \\<NewLeaseDuration>0</NewLeaseDuration>
            \\</u:AddPortMapping>
            \\</s:Body>
            \\</s:Envelope>
            ,
            .{ port, protocol, port, local_ip_str }
        );
        defer self.allocator.free(soap_body);

        var req_header: [512]u8 = undefined;
        const header = try std.fmt.bufPrint(&req_header, "POST {s} HTTP/1.0\r\nHost: {s}\r\nContent-Length: {d}\r\nContent-Type: text/xml\r\nSOAPAction: \"urn:schemas-upnp-org:service:WANIPConnection:1#AddPortMapping\"\r\nConnection: close\r\n\r\n", .{ uri.path.percent_encoded, host, soap_body.len });
        try stream.writeAll(header);
        try stream.writeAll(soap_body);

        var body_list: std.ArrayList(u8) = .empty;
        defer body_list.deinit(self.allocator);
        var read_buf: [1024]u8 = undefined;
        while (true) {
            const n = stream.read(&read_buf) catch break;
            if (n == 0) break;
            try body_list.appendSlice(self.allocator, read_buf[0..n]);
            if (body_list.items.len > 64 * 1024) break;
        }
        const response = body_list.items;

        if (std.mem.indexOf(u8, response, "200 OK") == null) {
            std.debug.print("UPnP Failed: {s}\n", .{response});
            return error.SoapError;
        }

        self.mapped_port = port;
        std.debug.print("UPnP: Successfully mapped port {d}\n", .{port});
    }

    pub fn deletePortMap(self: *UPnP, port: u16, protocol: []const u8) !void {
        const control_url_str = try self.fetchControlUrl();
        defer self.allocator.free(control_url_str);

        const uri = try std.Uri.parse(control_url_str);
        const host_comp = uri.host orelse return error.InvalidGatewayUrl;
        const host = host_comp.percent_encoded;
        const port_num = uri.port orelse 80;

        const addr = try compat.Address.parseIp(host, port_num);
        const stream = try compat.tcpConnectToAddress(addr);
        defer stream.close();

        const soap_body = try std.fmt.allocPrint(self.allocator,
            \\<?xml version="1.0"?>
            \\<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">
            \\<s:Body>
            \\<u:DeletePortMapping xmlns:u="urn:schemas-upnp-org:service:WANIPConnection:1">
            \\<NewRemoteHost></NewRemoteHost>
            \\<NewExternalPort>{d}</NewExternalPort>
            \\<NewProtocol>{s}</NewProtocol>
            \\</u:DeletePortMapping>
            \\</s:Body>
            \\</s:Envelope>
            ,
            .{ port, protocol }
        );
        defer self.allocator.free(soap_body);

        var req_header: [512]u8 = undefined;
        const header = try std.fmt.bufPrint(&req_header, "POST {s} HTTP/1.0\r\nHost: {s}\r\nContent-Length: {d}\r\nContent-Type: text/xml\r\nSOAPAction: \"urn:schemas-upnp-org:service:WANIPConnection:1#DeletePortMapping\"\r\nConnection: close\r\n\r\n", .{ uri.path.percent_encoded, host, soap_body.len });
        try stream.writeAll(header);
        try stream.writeAll(soap_body);

        var body_list: std.ArrayList(u8) = .empty;
        defer body_list.deinit(self.allocator);
        var read_buf: [1024]u8 = undefined;
        while (true) {
            const n = stream.read(&read_buf) catch break;
            if (n == 0) break;
            try body_list.appendSlice(self.allocator, read_buf[0..n]);
            if (body_list.items.len > 64 * 1024) break;
        }
        const response = body_list.items;

        if (std.mem.indexOf(u8, response, "200 OK") == null) {
            return error.SoapError;
        }

        self.mapped_port = null;
        std.debug.print("UPnP: Successfully deleted port mapping for {d}\n", .{port});
    }
};
