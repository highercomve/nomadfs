const std = @import("std");
const network = @import("mod.zig");

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

        const socket = try std.posix.socket(std.posix.AF.INET, std.posix.SOCK.DGRAM, 0);
        defer std.posix.close(socket);

        const timeout = std.posix.timeval{ .sec = 2, .usec = 0 };
        try std.posix.setsockopt(socket, std.posix.SOL.SOCKET, std.posix.SO.RCVTIMEO, std.mem.asBytes(&timeout));

        const dest_addr = try std.net.Address.parseIp("239.255.255.250", 1900);
        _ = try std.posix.sendto(socket, ssdp_msg, 0, &dest_addr.any, dest_addr.getOsSockLen());

        var buf: [4096]u8 = undefined;
        var attempts: usize = 0;
        
        while (attempts < 3) : (attempts += 1) {
             const len = std.posix.recvfrom(socket, &buf, 0, null, null) catch |err| {
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

        const addr = try std.net.Address.parseIp(host, port);
        const stream = try std.net.tcpConnectToAddress(addr);
        defer stream.close();

        var write_buf: [4096]u8 = undefined;
        var writer = stream.writer(&write_buf);
        try writer.interface.print("GET {s} HTTP/1.0\r\n", .{uri.path.percent_encoded});
        try writer.interface.print("Host: {s}\r\n", .{host});
        try writer.interface.print("Connection: close\r\n\r\n", .{});

        var read_buf: [4096]u8 = undefined;
        var r = stream.reader(&read_buf);
        const body = try r.interface().allocRemaining(self.allocator, std.Io.Limit.limited(64 * 1024));
        defer self.allocator.free(body);

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
                         return try std.fmt.allocPrint(self.allocator, "{s}://{s}:{d}{s}", .{uri.scheme, host, port, relative_url});
                    } else {
                         return try std.fmt.allocPrint(self.allocator, "{s}{s}", .{url_str, relative_url});
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
        const gateway_addr = try std.net.Address.parseIp(host, 0);

        const socket = try std.posix.socket(gateway_addr.any.family, std.posix.SOCK.DGRAM, 0);
        defer std.posix.close(socket);
        try std.posix.connect(socket, &gateway_addr.any, gateway_addr.getOsSockLen());

        var local_addr: std.net.Address = undefined;
        var len: std.posix.socklen_t = @sizeOf(std.net.Address);
        try std.posix.getsockname(socket, &local_addr.any, &len);

        switch (local_addr.any.family) {
             std.posix.AF.INET => {
                 const bytes = std.mem.asBytes(&local_addr.in.sa.addr);
                 return try std.fmt.allocPrint(self.allocator, "{d}.{d}.{d}.{d}", .{bytes[0], bytes[1], bytes[2], bytes[3]});
             },
             else => return error.UnsupportedAddressFamily,
        }
    }

    pub fn mapPort(self: *UPnP, port: u16, protocol: []const u8, local_ip_str: []const u8) !void {
        const control_url_str = try self.fetchControlUrl();
        defer self.allocator.free(control_url_str);

        const uri = try std.Uri.parse(control_url_str);
        const host_comp = uri.host orelse return error.InvalidGatewayUrl;
        const host = host_comp.percent_encoded;
        const port_num = uri.port orelse 80;

        const addr = try std.net.Address.parseIp(host, port_num);
        const stream = try std.net.tcpConnectToAddress(addr);
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

        var write_buf: [4096]u8 = undefined;
        var writer = stream.writer(&write_buf);
        try writer.interface.print("POST {s} HTTP/1.0\r\n", .{uri.path.percent_encoded});
        try writer.interface.print("Host: {s}\r\n", .{host});
        try writer.interface.print("Content-Length: {d}\r\n", .{soap_body.len});
        try writer.interface.print("Content-Type: text/xml\r\n", .{});
        try writer.interface.print("SOAPAction: \"urn:schemas-upnp-org:service:WANIPConnection:1#AddPortMapping\"\r\n", .{});
        try writer.interface.print("Connection: close\r\n\r\n", .{});
        try writer.interface.writeAll(soap_body);

        var read_buf: [4096]u8 = undefined;
        var r = stream.reader(&read_buf);
        const response = try r.interface().allocRemaining(self.allocator, std.Io.Limit.limited(64 * 1024));
        defer self.allocator.free(response);

        if (std.mem.indexOf(u8, response, "200 OK") == null) {
             std.debug.print("UPnP Failed: {s}\n", .{response});
             return error.SoapError;
        }

        self.mapped_port = port;
        std.debug.print("UPnP: Successfully mapped port {d}\n", .{port});
    }
};
