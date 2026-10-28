const std = @import("std");
const builtin = @import("builtin");
const network = @import("mod.zig");
const compat = @import("../compat.zig");
const local_addrs = @import("../local_addrs.zig");
const sync = @import("../../sync.zig");

const posix = std.posix;
const system = posix.system;

fn createSocket(domain: u32, sock_type: u32, protocol: u32) !posix.socket_t {
    while (true) {
        const rc = system.socket(domain, sock_type, protocol);
        if (posix.errno(rc) == .INTR) continue;
        return switch (posix.errno(rc)) {
            .SUCCESS => @intCast(rc),
            else => |err| posix.unexpectedErrno(err),
        };
    }
}

fn closeSocket(s: posix.socket_t) void {
    _ = system.close(@intCast(s));
}

fn sendtoSocket(s: posix.socket_t, buf: []const u8, flags: u32, addr: ?*const posix.sockaddr, alen: posix.socklen_t) !usize {
    while (true) {
        const rc = system.sendto(@intCast(s), buf.ptr, buf.len, flags, addr, alen);
        if (posix.errno(rc) == .INTR) continue;
        return switch (posix.errno(rc)) {
            .SUCCESS => @intCast(rc),
            else => |err| posix.unexpectedErrno(err),
        };
    }
}

fn recvfromSocket(s: posix.socket_t, buf: []u8, flags: u32, addr: ?*posix.sockaddr, alen: ?*posix.socklen_t) !usize {
    while (true) {
        const rc = system.recvfrom(@intCast(s), buf.ptr, buf.len, flags, addr, alen);
        if (posix.errno(rc) == .INTR) continue;
        return switch (posix.errno(rc)) {
            .SUCCESS => @intCast(rc),
            .AGAIN => error.WouldBlock,
            else => |err| posix.unexpectedErrno(err),
        };
    }
}

pub const nat_lease_seconds: u32 = 3600;
pub const nat_renew_after_seconds: u32 = 1800;
pub const nat_ssdp_window_ms: u32 = 3000;
pub const nat_http_timeout_ms: u32 = 5000;
pub const nat_max_url_len: usize = 256;
pub const nat_max_description_len: usize = 64 * 1024;
pub const nat_rediscover_after_failures: usize = 3;

pub const lease_seconds = nat_lease_seconds;
pub const renew_after_seconds = nat_renew_after_seconds;
pub const ssdp_window_ms = nat_ssdp_window_ms;
pub const http_timeout_ms = nat_http_timeout_ms;
pub const max_url_len = nat_max_url_len;
pub const max_description_len = nat_max_description_len;
pub const rediscover_after_failures = nat_rediscover_after_failures;

/// Connects to the gateway and bounds every later read/write on the stream.
fn connectGateway(addr: compat.Address) !compat.Stream {
    const stream = try compat.tcpConnectToAddressTimeout(addr, nat_http_timeout_ms);
    errdefer stream.close();
    try stream.setTimeout(nat_http_timeout_ms);
    return stream;
}

/// Reads an HTTP response (until EOF) into `out`, capped at max_description_len.
fn readResponse(allocator: std.mem.Allocator, stream: compat.Stream, out: *std.ArrayList(u8)) !void {
    var read_buf: [1024]u8 = undefined;
    while (out.items.len <= nat_max_description_len) {
        const n = stream.read(&read_buf) catch break;
        if (n == 0) break;
        try out.appendSlice(allocator, read_buf[0..n]);
    }
}

pub fn parseIpv4Literal(s: []const u8) ?[4]u8 {
    var it = std.mem.splitScalar(u8, s, '.');
    var octets: [4]u8 = undefined;
    var count: usize = 0;
    while (it.next()) |part| {
        if (count >= 4) return null;
        if (part.len == 0 or part.len > 3) return null;
        for (part) |c| {
            if (c < '0' or c > '9') return null;
        }
        const val = std.fmt.parseInt(u8, part, 10) catch return null;
        octets[count] = val;
        count += 1;
    }
    if (count != 4) return null;
    return octets;
}

pub const Reply = struct {
    location: []const u8,
};

pub const Location = struct {
    ip: [4]u8,
    port: u16,
    path: []const u8,
};

pub const ControlTarget = struct {
    port: u16,
    path: []const u8,
    service_type: []const u8,
};

pub const Candidate = struct {
    ip: [4]u8,
    port: u16,
    path: []const u8,
    path_len: usize = 0,
};

pub const SoapResult = union(enum) {
    ok: void,
    fault: u16,
    err: void,

    pub fn isOk(self: SoapResult) bool {
        return self == .ok;
    }

    pub fn errorCode(self: SoapResult) ?u16 {
        return switch (self) {
            .fault => |code| code,
            else => null,
        };
    }
};

pub fn nat_validUrlBytes(s: []const u8) bool {
    if (s.len < 1 or s.len > nat_max_url_len) return false;
    for (s) |b| {
        if (b < 0x21 or b > 0x7e or b == '\\') return false;
    }
    return true;
}
pub const validUrlBytes = nat_validUrlBytes;

pub fn nat_parseSsdpReply(allocator: ?std.mem.Allocator, datagram: []const u8, expected_st: []const u8) ?Reply {
    var it = std.mem.splitScalar(u8, datagram, '\n');
    var found_st = false;
    var found_usn = false;
    var location: ?[]const u8 = null;

    while (it.next()) |raw_line| {
        const line = std.mem.trimEnd(u8, raw_line, "\r");
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const name = std.mem.trim(u8, line[0..colon], " \t");
        const val = std.mem.trim(u8, line[colon + 1 ..], " \t");

        if (std.ascii.eqlIgnoreCase(name, "ST")) {
            if (std.mem.eql(u8, val, expected_st)) {
                found_st = true;
            }
        } else if (std.ascii.eqlIgnoreCase(name, "USN")) {
            if (val.len > 0) {
                found_usn = true;
            }
        } else if (std.ascii.eqlIgnoreCase(name, "LOCATION")) {
            if (location == null and nat_validUrlBytes(val)) {
                location = val;
            }
        }
    }

    if (found_st and found_usn and location != null) {
        if (allocator) |a| {
            const duped = a.dupe(u8, location.?) catch return null;
            return Reply{ .location = duped };
        } else {
            return Reply{ .location = location.? };
        }
    }
    return null;
}
pub const parseSsdpReply = nat_parseSsdpReply;

pub fn nat_locationHost(location: []const u8) ?Location {
    if (!nat_validUrlBytes(location)) return null;

    if (!std.mem.startsWith(u8, location, "http://")) return null;
    const rest = location["http://".len..];

    const slash_idx = std.mem.indexOfScalar(u8, rest, '/');
    const authority = if (slash_idx) |idx| rest[0..idx] else rest;
    const path = if (slash_idx) |idx| rest[idx..] else "/";

    if (authority.len == 0) return null;
    if (std.mem.indexOfScalar(u8, authority, '@') != null) return null;

    var host_str: []const u8 = authority;
    var port: u16 = 80;

    if (std.mem.indexOfScalar(u8, authority, ':')) |colon| {
        host_str = authority[0..colon];
        const port_str = authority[colon + 1 ..];
        port = std.fmt.parseInt(u16, port_str, 10) catch return null;
        if (port == 0) return null;
    }

    const ip = parseIpv4Literal(host_str) orelse return null;

    return Location{
        .ip = ip,
        .port = port,
        .path = path,
    };
}
pub const locationHost = nat_locationHost;

pub fn nat_acceptResponder(src: [4]u8, loc_ip: [4]u8, local_nets: []const local_addrs.Net, gateway: ?[4]u8) bool {
    _ = gateway;
    // 1. loc_ip == src (a responder may only name itself)
    if (!std.mem.eql(u8, &src, &loc_ip)) return false;

    // 2. src is not loopback, unspecified, multicast, or broadcast
    if (src[0] == 0) return false;
    if (src[0] == 127) return false;
    if (src[0] >= 224) return false;
    if (src[0] == 255 and src[1] == 255 and src[2] == 255 and src[3] == 255) return false;

    // 3. on-link check
    if (local_nets.len > 0) {
        for (local_nets) |net| {
            if (net.contains(src)) return true;
        }
        return false;
    } else {
        const is_rfc1918 = (src[0] == 10) or
            (src[0] == 172 and src[1] >= 16 and src[1] <= 31) or
            (src[0] == 192 and src[1] == 168);
        const is_cgnat = (src[0] == 100 and (src[1] & 0xC0) == 64);
        const is_link_local = (src[0] == 169 and src[1] == 254);
        return (is_rfc1918 or is_cgnat or is_link_local);
    }
}
pub const acceptResponder = nat_acceptResponder;

pub fn nat_selectBestCandidate(candidates: []const Candidate, gateway: ?[4]u8) ?Candidate {
    if (candidates.len == 0) return null;
    if (gateway) |gw| {
        for (candidates) |cand| {
            if (std.mem.eql(u8, &cand.ip, &gw)) return cand;
        }
    }
    return candidates[0];
}
pub const selectBestCandidate = nat_selectBestCandidate;

pub fn nat_parseControlUrl(allocator: std.mem.Allocator, xml: []const u8, loc_ip: [4]u8, loc_port: u16, loc_path: []const u8) !ControlTarget {
    const supported_services = [_][]const u8{
        "urn:schemas-upnp-org:service:WANIPConnection:1",
        "urn:schemas-upnp-org:service:WANIPConnection:2",
        "urn:schemas-upnp-org:service:WANPPPConnection:1",
    };

    var search_pos: usize = 0;
    while (search_pos < xml.len) {
        const service_open = "<service>";
        const service_close = "</service>";

        const start_idx = std.mem.indexOfPos(u8, xml, search_pos, service_open) orelse break;
        const end_idx = std.mem.indexOfPos(u8, xml, start_idx, service_close) orelse break;
        search_pos = end_idx + service_close.len;

        const block = xml[start_idx + service_open.len .. end_idx];

        const st_open = "<serviceType>";
        const st_close = "</serviceType>";
        const st_start = std.mem.indexOf(u8, block, st_open) orelse continue;
        const st_end = std.mem.indexOfPos(u8, block, st_start, st_close) orelse continue;
        const raw_st = std.mem.trim(u8, block[st_start + st_open.len .. st_end], " \t\r\n");

        var matched_st: ?[]const u8 = null;
        for (supported_services) |svc| {
            if (std.mem.eql(u8, raw_st, svc)) {
                matched_st = svc;
                break;
            }
        }
        if (matched_st == null) continue;

        const ctl_open = "<controlURL>";
        const ctl_close = "</controlURL>";
        const ctl_start = std.mem.indexOf(u8, block, ctl_open) orelse continue;
        const ctl_end = std.mem.indexOfPos(u8, block, ctl_start, ctl_close) orelse continue;
        const raw_ctl = std.mem.trim(u8, block[ctl_start + ctl_open.len .. ctl_end], " \t\r\n");

        if (!nat_validUrlBytes(raw_ctl)) return error.InvalidControlUrl;
        if (std.mem.indexOf(u8, raw_ctl, "/../") != null) return error.InvalidControlUrl;

        if (std.mem.startsWith(u8, raw_ctl, "/")) {
            const path = try allocator.dupe(u8, raw_ctl);
            return ControlTarget{
                .port = loc_port,
                .path = path,
                .service_type = matched_st.?,
            };
        } else if (std.mem.startsWith(u8, raw_ctl, "http://")) {
            const parsed = nat_locationHost(raw_ctl) orelse return error.InvalidControlUrl;
            if (!std.mem.eql(u8, &parsed.ip, &loc_ip)) return error.HostMismatch;
            const path = try allocator.dupe(u8, parsed.path);
            return ControlTarget{
                .port = parsed.port,
                .path = path,
                .service_type = matched_st.?,
            };
        } else {
            const last_slash = std.mem.lastIndexOfScalar(u8, loc_path, '/') orelse 0;
            const dir = loc_path[0 .. last_slash + 1];
            const joined = try std.fmt.allocPrint(allocator, "{s}{s}", .{ dir, raw_ctl });
            if (!nat_validUrlBytes(joined) or std.mem.indexOf(u8, joined, "/../") != null) {
                allocator.free(joined);
                return error.InvalidControlUrl;
            }
            return ControlTarget{
                .port = loc_port,
                .path = joined,
                .service_type = matched_st.?,
            };
        }
    }

    return error.ControlUrlNotFound;
}
pub const parseControlUrl = nat_parseControlUrl;

pub fn nat_parseSoapErrorCode(response: []const u8) ?u16 {
    const err_open = "<errorCode>";
    const err_close = "</errorCode>";
    const start = std.mem.indexOf(u8, response, err_open) orelse return null;
    const end = std.mem.indexOfPos(u8, response, start, err_close) orelse return null;
    const code_str = std.mem.trim(u8, response[start + err_open.len .. end], " \t\r\n");
    return std.fmt.parseInt(u16, code_str, 10) catch null;
}
pub const parseSoapErrorCode = nat_parseSoapErrorCode;

pub fn nat_soapStatusOk(response: []const u8) SoapResult {
    const newline = std.mem.indexOfAny(u8, response, "\r\n") orelse response.len;
    const first_line = response[0..newline];

    if (std.mem.startsWith(u8, first_line, "HTTP/1.") and std.mem.indexOf(u8, first_line, " 200") != null) {
        return SoapResult{ .ok = {} };
    }

    if (nat_parseSoapErrorCode(response)) |code| {
        return SoapResult{ .fault = code };
    }

    return SoapResult{ .err = {} };
}
pub const soapStatusOk = nat_soapStatusOk;

pub fn nat_buildAddPortMapping(buf: []u8, service_type: []const u8, port: u16, proto: []const u8, internal_client: []const u8, lease: u32) ![]u8 {
    return try std.fmt.bufPrint(buf,
        \\<?xml version="1.0"?>
        \\<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">
        \\<s:Body>
        \\<u:AddPortMapping xmlns:u="{s}">
        \\<NewRemoteHost></NewRemoteHost>
        \\<NewExternalPort>{d}</NewExternalPort>
        \\<NewProtocol>{s}</NewProtocol>
        \\<NewInternalPort>{d}</NewInternalPort>
        \\<NewInternalClient>{s}</NewInternalClient>
        \\<NewEnabled>1</NewEnabled>
        \\<NewPortMappingDescription>NomadFS</NewPortMappingDescription>
        \\<NewLeaseDuration>{d}</NewLeaseDuration>
        \\</u:AddPortMapping>
        \\</s:Body>
        \\</s:Envelope>
    , .{ service_type, port, proto, port, internal_client, lease });
}
pub const buildAddPortMapping = nat_buildAddPortMapping;

pub fn nat_buildDeletePortMapping(buf: []u8, service_type: []const u8, port: u16, proto: []const u8) ![]u8 {
    return try std.fmt.bufPrint(buf,
        \\<?xml version="1.0"?>
        \\<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">
        \\<s:Body>
        \\<u:DeletePortMapping xmlns:u="{s}">
        \\<NewRemoteHost></NewRemoteHost>
        \\<NewExternalPort>{d}</NewExternalPort>
        \\<NewProtocol>{s}</NewProtocol>
        \\</u:DeletePortMapping>
        \\</s:Body>
        \\</s:Envelope>
    , .{ service_type, port, proto });
}
pub const buildDeletePortMapping = nat_buildDeletePortMapping;

pub fn parseDefaultGatewayRoute(content: []const u8) ?[4]u8 {
    var lines = std.mem.splitScalar(u8, content, '\n');
    _ = lines.next(); // Skip header line
    while (lines.next()) |line| {
        var it = std.mem.tokenizeAny(u8, line, " \t\r");
        _ = it.next() orelse continue; // Iface
        const dest = it.next() orelse continue; // Destination
        const gw_hex = it.next() orelse continue; // Gateway
        const flags_hex = it.next() orelse continue; // Flags

        if (!std.mem.eql(u8, dest, "00000000")) continue;

        const flags = std.fmt.parseInt(u16, flags_hex, 16) catch continue;
        const RTF_GATEWAY: u16 = 0x0002;
        if ((flags & RTF_GATEWAY) == 0) continue;

        const gw_val = std.fmt.parseInt(u32, gw_hex, 16) catch continue;
        if (gw_val == 0) continue;

        const ip: [4]u8 = .{
            @truncate(gw_val),
            @truncate(gw_val >> 8),
            @truncate(gw_val >> 16),
            @truncate(gw_val >> 24),
        };
        return ip;
    }
    return null;
}

pub fn getDefaultGateway() ?[4]u8 {
    if (builtin.os.tag != .linux) return null;
    const io = std.Io.Threaded.global_single_threaded.io();
    var file = std.Io.Dir.cwd().openFile(io, "/proc/net/route", .{}) catch return null;
    defer file.close(io);
    var buf: [4096]u8 = undefined;
    const len = file.readPositionalAll(io, &buf, 0) catch return null;
    return parseDefaultGatewayRoute(buf[0..len]);
}

pub const UPnP = struct {
    allocator: std.mem.Allocator,
    gateway_url: ?[]const u8,
    local_ip: ?[]const u8,
    mapped_port: ?u16,

    gateway_ip: ?[4]u8,
    gateway_port: u16,
    location_path: ?[]const u8,
    control_port: u16,
    control_path: ?[]const u8,
    service_type: ?[]const u8,
    permanent_only: bool,
    external_ip: ?[4]u8,

    renew_after_seconds: u32,
    running: std.atomic.Value(bool),
    renewal_thread: ?std.Thread,
    renewal_port: u16,
    renewal_proto: [8]u8,
    renewal_proto_len: usize,
    renewal_client: [64]u8,
    renewal_client_len: usize,

    pub const lease_seconds = nat_lease_seconds;
    pub const ssdp_window_ms = nat_ssdp_window_ms;
    pub const http_timeout_ms = nat_http_timeout_ms;
    pub const max_url_len = nat_max_url_len;
    pub const max_description_len = nat_max_description_len;
    pub const rediscover_after_failures = nat_rediscover_after_failures;

    pub const validUrlBytes = nat_validUrlBytes;
    pub const parseSsdpReply = nat_parseSsdpReply;
    pub const locationHost = nat_locationHost;
    pub const acceptResponder = nat_acceptResponder;
    pub const selectBestCandidate = nat_selectBestCandidate;
    pub const parseControlUrl = nat_parseControlUrl;
    pub const soapStatusOk = nat_soapStatusOk;
    pub const parseSoapErrorCode = nat_parseSoapErrorCode;
    pub const buildAddPortMapping = nat_buildAddPortMapping;
    pub const buildDeletePortMapping = nat_buildDeletePortMapping;

    pub fn init(allocator: std.mem.Allocator) UPnP {
        return .{
            .allocator = allocator,
            .gateway_url = null,
            .local_ip = null,
            .mapped_port = null,
            .gateway_ip = null,
            .gateway_port = 0,
            .location_path = null,
            .control_port = 0,
            .control_path = null,
            .service_type = null,
            .permanent_only = false,
            .external_ip = null,
            .renew_after_seconds = nat_renew_after_seconds,
            .running = std.atomic.Value(bool).init(true),
            .renewal_thread = null,
            .renewal_port = 0,
            .renewal_proto = undefined,
            .renewal_proto_len = 0,
            .renewal_client = undefined,
            .renewal_client_len = 0,
        };
    }

    pub fn initForTest(allocator: std.mem.Allocator, ip: [4]u8, port: u16, path: []const u8) !UPnP {
        var u = init(allocator);
        u.gateway_ip = ip;
        u.gateway_port = port;
        u.location_path = try allocator.dupe(u8, path);
        u.gateway_url = try std.fmt.allocPrint(allocator, "http://{d}.{d}.{d}.{d}:{d}{s}", .{ ip[0], ip[1], ip[2], ip[3], port, path });
        return u;
    }

    pub fn deinit(self: *UPnP) void {
        self.stop();
        if (self.gateway_url) |url| self.allocator.free(url);
        if (self.local_ip) |ip| self.allocator.free(ip);
        if (self.location_path) |p| self.allocator.free(p);
        if (self.control_path) |p| self.allocator.free(p);
    }

    pub fn stop(self: *UPnP) void {
        self.running.store(false, .release);
        if (self.renewal_thread) |t| {
            t.join();
            self.renewal_thread = null;
        }
    }

    pub fn discoverGateway(self: *UPnP) !void {
        if (builtin.os.tag == .windows) return error.Unsupported else return self.discoverGatewayPosix();
    }

    fn discoverGatewayPosix(self: *UPnP) !void {
        var nets_buf: [32]local_addrs.Net = undefined;
        const num_nets = local_addrs.listNets(&nets_buf);
        const local_nets = nets_buf[0..num_nets];
        const default_gw = getDefaultGateway();

        const socket = try createSocket(posix.AF.INET, posix.SOCK.DGRAM, 0);
        defer closeSocket(socket);

        const timeout = posix.timeval{ .sec = 0, .usec = 200_000 };
        posix.setsockopt(socket, posix.SOL.SOCKET, posix.SO.RCVTIMEO, std.mem.asBytes(&timeout)) catch {};

        const dest_addr = try compat.Address.parseIp("239.255.255.250", 1900);
        const dest_sa = dest_addr.toPosix();

        const st_igd1 = "urn:schemas-upnp-org:device:InternetGatewayDevice:1";
        const st_igd2 = "urn:schemas-upnp-org:device:InternetGatewayDevice:2";

        var ssdp_buf: [512]u8 = undefined;
        const msg1 = try std.fmt.bufPrint(&ssdp_buf, "M-SEARCH * HTTP/1.1\r\n" ++
            "HOST: 239.255.255.250:1900\r\n" ++
            "MAN: \"ssdp:discover\"\r\n" ++
            "MX: 2\r\n" ++
            "ST: {s}\r\n\r\n", .{st_igd1});
        _ = sendtoSocket(socket, msg1, 0, @ptrCast(&dest_sa), dest_sa.len()) catch {};

        const msg2 = try std.fmt.bufPrint(&ssdp_buf, "M-SEARCH * HTTP/1.1\r\n" ++
            "HOST: 239.255.255.250:1900\r\n" ++
            "MAN: \"ssdp:discover\"\r\n" ++
            "MX: 2\r\n" ++
            "ST: {s}\r\n\r\n", .{st_igd2});
        _ = sendtoSocket(socket, msg2, 0, @ptrCast(&dest_sa), dest_sa.len()) catch {};

        var candidates: [4]Candidate = undefined;
        var candidate_paths: [4][nat_max_url_len]u8 = undefined;
        var candidate_count: usize = 0;

        const deadline = sync.monotonicMillis() + nat_ssdp_window_ms;
        var buf: [4096]u8 = undefined;

        while (sync.monotonicMillis() < deadline and candidate_count < candidates.len) {
            var src_sa: posix.sockaddr.in = undefined;
            var src_len: posix.socklen_t = @sizeOf(posix.sockaddr.in);
            const len = recvfromSocket(socket, &buf, 0, @ptrCast(&src_sa), &src_len) catch |err| {
                if (err == error.WouldBlock) continue;
                return err;
            };

            const response = buf[0..len];
            const src_ip = @as([4]u8, @bitCast(src_sa.addr));

            const reply = nat_parseSsdpReply(null, response, st_igd1) orelse
                nat_parseSsdpReply(null, response, st_igd2) orelse continue;

            const loc = nat_locationHost(reply.location) orelse continue;

            if (!nat_acceptResponder(src_ip, loc.ip, local_nets, default_gw)) continue;

            var duplicate = false;
            for (candidates[0..candidate_count]) |cand| {
                if (std.mem.eql(u8, &cand.ip, &src_ip) and cand.port == loc.port) {
                    duplicate = true;
                    break;
                }
            }
            if (duplicate) continue;

            @memcpy(candidate_paths[candidate_count][0..loc.path.len], loc.path);
            candidates[candidate_count] = .{
                .ip = src_ip,
                .port = loc.port,
                .path = candidate_paths[candidate_count][0..loc.path.len],
                .path_len = loc.path.len,
            };
            candidate_count += 1;
        }

        if (candidate_count == 0) return error.GatewayNotFound;

        const chosen = nat_selectBestCandidate(candidates[0..candidate_count], default_gw).?;

        self.gateway_ip = chosen.ip;
        self.gateway_port = chosen.port;
        if (self.location_path) |p| self.allocator.free(p);
        self.location_path = try self.allocator.dupe(u8, chosen.path);

        if (self.gateway_url) |u| self.allocator.free(u);
        self.gateway_url = try std.fmt.allocPrint(self.allocator, "http://{d}.{d}.{d}.{d}:{d}{s}", .{ chosen.ip[0], chosen.ip[1], chosen.ip[2], chosen.ip[3], chosen.port, chosen.path });

        std.log.info("UPnP: Found gateway at {d}.{d}.{d}.{d}:{d}", .{ chosen.ip[0], chosen.ip[1], chosen.ip[2], chosen.ip[3], chosen.port });

        try self.fetchAndCacheDescription();
    }

    fn fetchAndCacheDescription(self: *UPnP) !void {
        if (self.gateway_ip == null or self.location_path == null) return error.NoGateway;

        const addr = compat.Address.initIp4(self.gateway_ip.?, self.gateway_port);
        const stream = try connectGateway(addr);
        defer stream.close();

        var req_buf: [512]u8 = undefined;
        const req = try std.fmt.bufPrint(&req_buf, "GET {s} HTTP/1.0\r\nHost: {d}.{d}.{d}.{d}:{d}\r\nConnection: close\r\n\r\n", .{ self.location_path.?, self.gateway_ip.?[0], self.gateway_ip.?[1], self.gateway_ip.?[2], self.gateway_ip.?[3], self.gateway_port });
        try stream.writeAll(req);

        var body_list: std.ArrayList(u8) = .empty;
        defer body_list.deinit(self.allocator);
        try readResponse(self.allocator, stream, &body_list);
        const body = body_list.items;

        const header_end = std.mem.indexOf(u8, body, "\r\n\r\n") orelse return error.InvalidResponse;
        const xml_body = body[header_end + 4 ..];

        const target = try nat_parseControlUrl(self.allocator, xml_body, self.gateway_ip.?, self.gateway_port, self.location_path.?);

        if (self.control_path) |old| self.allocator.free(old);
        self.control_port = target.port;
        self.control_path = target.path;
        self.service_type = target.service_type;
    }

    pub fn fetchControlUrl(self: *UPnP) ![]const u8 {
        if (self.gateway_ip == null) return error.NoGateway;
        if (self.control_path == null) {
            try self.fetchAndCacheDescription();
        }
        return try std.fmt.allocPrint(self.allocator, "http://{d}.{d}.{d}.{d}:{d}{s}", .{ self.gateway_ip.?[0], self.gateway_ip.?[1], self.gateway_ip.?[2], self.gateway_ip.?[3], self.control_port, self.control_path.? });
    }

    pub fn getLocalIP(self: *UPnP) ![]const u8 {
        if (builtin.os.tag == .windows) return error.Unsupported else return self.getLocalIPPosix();
    }

    fn getLocalIPPosix(self: *UPnP) ![]const u8 {
        const gw_ip = self.gateway_ip orelse {
            if (self.gateway_url) |url| {
                const loc = nat_locationHost(url) orelse return error.NoGateway;
                return self.getLocalIpFor(loc.ip);
            }
            return error.NoGateway;
        };
        return self.getLocalIpFor(gw_ip);
    }

    fn getLocalIpFor(self: *UPnP, gw_ip: [4]u8) ![]const u8 {
        const gateway_addr = compat.Address.initIp4(gw_ip, 0);

        const socket = try createSocket(posix.AF.INET, posix.SOCK.DGRAM, 0);
        defer closeSocket(socket);
        const gw_sa = gateway_addr.toPosix();
        const rc = while (true) {
            const result = system.connect(@intCast(socket), @ptrCast(&gw_sa), gw_sa.len());
            if (posix.errno(result) != .INTR) break result;
        };
        _ = switch (posix.errno(rc)) {
            .SUCCESS => {},
            else => |err| return posix.unexpectedErrno(err),
        };

        var local_sa: posix.sockaddr.in = undefined;
        var len: posix.socklen_t = @sizeOf(posix.sockaddr.in);
        const rc_name = while (true) {
            const result = system.getsockname(@intCast(socket), @ptrCast(&local_sa), &len);
            if (posix.errno(result) != .INTR) break result;
        };
        _ = switch (posix.errno(rc_name)) {
            .SUCCESS => {},
            else => |err| return posix.unexpectedErrno(err),
        };

        const bytes = @as([4]u8, @bitCast(local_sa.addr));
        return try std.fmt.allocPrint(self.allocator, "{d}.{d}.{d}.{d}", .{ bytes[0], bytes[1], bytes[2], bytes[3] });
    }

    fn sendSoapRequest(self: *UPnP, action: []const u8, soap_body: []const u8) !SoapResult {
        const addr = compat.Address.initIp4(self.gateway_ip.?, self.control_port);
        const stream = try connectGateway(addr);
        defer stream.close();

        var req_header: [1024]u8 = undefined;
        const header = try std.fmt.bufPrint(&req_header, "POST {s} HTTP/1.0\r\nHost: {d}.{d}.{d}.{d}:{d}\r\nContent-Length: {d}\r\nContent-Type: text/xml\r\nSOAPAction: \"{s}#{s}\"\r\nConnection: close\r\n\r\n", .{ self.control_path.?, self.gateway_ip.?[0], self.gateway_ip.?[1], self.gateway_ip.?[2], self.gateway_ip.?[3], self.control_port, soap_body.len, self.service_type.?, action });
        try stream.writeAll(header);
        try stream.writeAll(soap_body);

        var body_list: std.ArrayList(u8) = .empty;
        defer body_list.deinit(self.allocator);
        try readResponse(self.allocator, stream, &body_list);
        return nat_soapStatusOk(body_list.items);
    }

    fn checkExternalIp(self: *UPnP) !void {
        if (self.gateway_ip == null or self.control_path == null) return;
        var soap_buf: [1024]u8 = undefined;
        const soap_body = try std.fmt.bufPrint(&soap_buf,
            \\<?xml version="1.0"?>
            \\<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">
            \\<s:Body>
            \\<u:GetExternalIPAddress xmlns:u="{s}">
            \\</u:GetExternalIPAddress>
            \\</s:Body>
            \\</s:Envelope>
        , .{self.service_type.?});

        const addr = compat.Address.initIp4(self.gateway_ip.?, self.control_port);
        const stream = connectGateway(addr) catch return;
        defer stream.close();

        var req_header: [1024]u8 = undefined;
        const header = try std.fmt.bufPrint(&req_header, "POST {s} HTTP/1.0\r\nHost: {d}.{d}.{d}.{d}:{d}\r\nContent-Length: {d}\r\nContent-Type: text/xml\r\nSOAPAction: \"{s}#GetExternalIPAddress\"\r\nConnection: close\r\n\r\n", .{ self.control_path.?, self.gateway_ip.?[0], self.gateway_ip.?[1], self.gateway_ip.?[2], self.gateway_ip.?[3], self.control_port, soap_body.len, self.service_type.? });
        stream.writeAll(header) catch return;
        stream.writeAll(soap_body) catch return;

        var body_list: std.ArrayList(u8) = .empty;
        defer body_list.deinit(self.allocator);
        readResponse(self.allocator, stream, &body_list) catch return;
        const response = body_list.items;

        const tag_open = "<NewExternalIPAddress>";
        const tag_close = "</NewExternalIPAddress>";
        const start = std.mem.indexOf(u8, response, tag_open) orelse return;
        const end = std.mem.indexOfPos(u8, response, start, tag_close) orelse return;
        const ip_str = std.mem.trim(u8, response[start + tag_open.len .. end], " \t\r\n");

        const ip = parseIpv4Literal(ip_str) orelse return;
        self.external_ip = ip;

        const is_rfc1918 = (ip[0] == 10) or
            (ip[0] == 172 and ip[1] >= 16 and ip[1] <= 31) or
            (ip[0] == 192 and ip[1] == 168);
        const is_cgnat = (ip[0] == 100 and (ip[1] & 0xC0) == 64);
        const is_loopback = (ip[0] == 127);
        const is_link_local = (ip[0] == 169 and ip[1] == 254);

        if (is_rfc1918 or is_cgnat or is_loopback or is_link_local) {
            std.log.warn("behind carrier-grade or double NAT: UPnP cannot make this device reachable (external IP: {s})", .{ip_str});
            if (self.mapped_port) |p| {
                var del_buf: [1024]u8 = undefined;
                const del_body = nat_buildDeletePortMapping(&del_buf, self.service_type.?, p, "TCP") catch return error.DoubleNat;
                _ = self.sendSoapRequest("DeletePortMapping", del_body) catch {};
                self.mapped_port = null;
            }
            return error.DoubleNat;
        }
    }

    pub fn mapPort(self: *UPnP, port: u16, protocol: []const u8, local_ip_str: []const u8) !void {
        try self.mapPortLease(port, protocol, local_ip_str, nat_lease_seconds);
        if (!self.permanent_only and self.renewal_thread == null) {
            try self.startRenewal(port, protocol, local_ip_str);
        }
    }

    pub fn mapPortLease(self: *UPnP, port: u16, protocol: []const u8, local_ip_str: []const u8, lease: u32) !void {
        if (self.gateway_ip == null) return error.NoGateway;
        if (self.control_path == null) {
            try self.fetchAndCacheDescription();
        }

        var soap_buf: [2048]u8 = undefined;
        const soap_body = try nat_buildAddPortMapping(&soap_buf, self.service_type.?, port, protocol, local_ip_str, lease);

        const status = try self.sendSoapRequest("AddPortMapping", soap_body);
        switch (status) {
            .ok => {
                self.mapped_port = port;
                std.log.info("UPnP: Successfully mapped port {d} (lease {d}s)", .{ port, lease });
            },
            .fault => |code| {
                if (code == 725 and lease != 0) {
                    std.log.warn("router only supports permanent UPnP leases; the mapping stays until NomadFS exits cleanly", .{});
                    self.permanent_only = true;
                    return self.mapPortLease(port, protocol, local_ip_str, 0);
                } else if (code == 718) {
                    std.log.warn("UPnP: Port mapping conflict (error 718) for port {d}", .{port});
                    return error.ConflictInMappingEntry;
                } else {
                    std.log.warn("UPnP: SOAP fault {d} on AddPortMapping", .{code});
                    return error.SoapError;
                }
            },
            .err => {
                return error.SoapError;
            },
        }

        self.checkExternalIp() catch {};
    }

    pub fn deletePortMap(self: *UPnP, port: u16, protocol: []const u8) !void {
        self.stop();

        if (self.gateway_ip == null or self.control_path == null) return;

        var soap_buf: [1024]u8 = undefined;
        const soap_body = try nat_buildDeletePortMapping(&soap_buf, self.service_type.?, port, protocol);

        const status = try self.sendSoapRequest("DeletePortMapping", soap_body);
        switch (status) {
            .ok => {
                self.mapped_port = null;
                std.log.info("UPnP: Successfully deleted port mapping for {d}", .{port});
            },
            else => return error.SoapError,
        }
    }

    pub fn startRenewal(self: *UPnP, port: u16, protocol: []const u8, local_ip_str: []const u8) !void {
        if (self.renewal_thread != null or self.permanent_only) return;
        self.running.store(true, .release);
        self.renewal_port = port;
        const plen = @min(protocol.len, self.renewal_proto.len);
        @memcpy(self.renewal_proto[0..plen], protocol[0..plen]);
        self.renewal_proto_len = plen;
        const clen = @min(local_ip_str.len, self.renewal_client.len);
        @memcpy(self.renewal_client[0..clen], local_ip_str[0..clen]);
        self.renewal_client_len = clen;

        self.renewal_thread = try std.Thread.spawn(.{}, runRenewal, .{self});
    }

    fn runRenewal(self: *UPnP) void {
        const port = self.renewal_port;
        const proto = self.renewal_proto[0..self.renewal_proto_len];
        const client = self.renewal_client[0..self.renewal_client_len];

        while (self.running.load(.acquire)) {
            const sleep_total_ms = @as(u64, self.renew_after_seconds) * 1000;
            var elapsed_ms: u64 = 0;
            while (elapsed_ms < sleep_total_ms and self.running.load(.acquire)) {
                sync.sleep(50 * std.time.ns_per_ms);
                elapsed_ms += 50;
            }
            if (!self.running.load(.acquire)) break;

            self.mapPortLease(port, proto, client, nat_lease_seconds) catch |err| {
                std.log.warn("UPnP renewal failed: {any}", .{err});
            };
        }
    }
};

test "validUrlBytes rejects control characters and invalid lengths" {
    try std.testing.expect(!validUrlBytes("/a\r\nHost: x"));
    try std.testing.expect(!validUrlBytes("/a b"));
    try std.testing.expect(!validUrlBytes("/a\x00"));
    const long_url = "a" ** 257;
    try std.testing.expect(!validUrlBytes(long_url));
    try std.testing.expect(!validUrlBytes(""));
    try std.testing.expect(!validUrlBytes("/a\\b"));
    try std.testing.expect(validUrlBytes("/ctl/IPConn"));
}

test "parseSsdpReply headers and location extraction" {
    const expected_st = "urn:schemas-upnp-org:device:InternetGatewayDevice:1";

    // wrong ST dropped
    const wrong_st =
        "HTTP/1.1 200 OK\r\n" ++
        "ST: urn:schemas-upnp-org:device:OtherDevice:1\r\n" ++
        "USN: uuid:1234::urn:schemas-upnp-org:device:OtherDevice:1\r\n" ++
        "LOCATION: http://192.168.1.1:5000/desc.xml\r\n\r\n";
    try std.testing.expect(parseSsdpReply(null, wrong_st, expected_st) == null);

    // missing LOCATION dropped
    const missing_loc =
        "HTTP/1.1 200 OK\r\n" ++
        "ST: urn:schemas-upnp-org:device:InternetGatewayDevice:1\r\n" ++
        "USN: uuid:1234\r\n\r\n";
    try std.testing.expect(parseSsdpReply(null, missing_loc, expected_st) == null);

    // two LOCATION lines -> first
    const two_loc =
        "HTTP/1.1 200 OK\r\n" ++
        "ST: urn:schemas-upnp-org:device:InternetGatewayDevice:1\r\n" ++
        "USN: uuid:1234\r\n" ++
        "LOCATION: http://192.168.1.1:5000/first.xml\r\n" ++
        "LOCATION: http://192.168.1.1:5000/second.xml\r\n\r\n";
    const r1 = parseSsdpReply(null, two_loc, expected_st);
    try std.testing.expect(r1 != null);
    try std.testing.expectEqualStrings("http://192.168.1.1:5000/first.xml", r1.?.location);

    // lower-case header names accepted
    const lower_headers =
        "HTTP/1.1 200 OK\r\n" ++
        "st: urn:schemas-upnp-org:device:InternetGatewayDevice:1\r\n" ++
        "usn: uuid:1234\r\n" ++
        "location: http://192.168.1.1:5000/desc.xml\r\n\r\n";
    const r2 = parseSsdpReply(null, lower_headers, expected_st);
    try std.testing.expect(r2 != null);
    try std.testing.expectEqualStrings("http://192.168.1.1:5000/desc.xml", r2.?.location);
}

test "locationHost url validation" {
    // http://192.168.1.1:5000/rootDesc.xml ok
    const loc1 = locationHost("http://192.168.1.1:5000/rootDesc.xml");
    try std.testing.expect(loc1 != null);
    try std.testing.expectEqual([4]u8{ 192, 168, 1, 1 }, loc1.?.ip);
    try std.testing.expectEqual(@as(u16, 5000), loc1.?.port);
    try std.testing.expectEqualStrings("/rootDesc.xml", loc1.?.path);

    // https:// rejected
    try std.testing.expect(locationHost("https://192.168.1.1:5000/rootDesc.xml") == null);

    // hostname rejected
    try std.testing.expect(locationHost("http://router.lan:5000/rootDesc.xml") == null);

    // http://u@192.168.1.1/ rejected
    try std.testing.expect(locationHost("http://u@192.168.1.1/") == null);

    // port 0 rejected
    try std.testing.expect(locationHost("http://192.168.1.1:0/desc.xml") == null);
}

test "acceptResponder: validation and selection" {
    const net1 = local_addrs.Net{ .addr = .{ 192, 168, 1, 10 }, .mask = .{ 255, 255, 255, 0 } };
    const nets = [_]local_addrs.Net{net1};
    const gw: [4]u8 = .{ 192, 168, 1, 1 };

    // LOCATION IP != datagram source rejected
    try std.testing.expect(!acceptResponder(.{ 192, 168, 1, 1 }, .{ 192, 168, 1, 2 }, &nets, gw));

    // 8.8.8.8 rejected
    try std.testing.expect(!acceptResponder(.{ 8, 8, 8, 8 }, .{ 8, 8, 8, 8 }, &nets, gw));

    // loopback rejected
    try std.testing.expect(!acceptResponder(.{ 127, 0, 0, 1 }, .{ 127, 0, 0, 1 }, &nets, gw));

    // on-link accepted
    try std.testing.expect(acceptResponder(.{ 192, 168, 1, 20 }, .{ 192, 168, 1, 20 }, &nets, gw));
    try std.testing.expect(acceptResponder(.{ 192, 168, 1, 1 }, .{ 192, 168, 1, 1 }, &nets, gw));

    // gateway preferred
    const cands = [_]Candidate{
        .{ .ip = .{ 192, 168, 1, 20 }, .port = 80, .path = "/ctl" },
        .{ .ip = .{ 192, 168, 1, 1 }, .port = 80, .path = "/ctl" },
    };
    const best = selectBestCandidate(&cands, gw);
    try std.testing.expect(best != null);
    try std.testing.expectEqual(gw, best.?.ip);
}

test "parseControlUrl resolutions and restrictions" {
    const alloc = std.testing.allocator;
    const loc_ip: [4]u8 = .{ 192, 168, 1, 1 };
    const loc_port: u16 = 5000;
    const loc_path = "/upnp/desc.xml";

    // absolute path ok
    const xml1 =
        \\<root>
        \\  <service>
        \\    <serviceType>urn:schemas-upnp-org:service:WANIPConnection:1</serviceType>
        \\    <controlURL>/ctl/IPConn</controlURL>
        \\  </service>
        \\</root>
    ;
    const res1 = try parseControlUrl(alloc, xml1, loc_ip, loc_port, loc_path);
    defer alloc.free(res1.path);
    try std.testing.expectEqualStrings("/ctl/IPConn", res1.path);
    try std.testing.expectEqual(loc_port, res1.port);
    try std.testing.expectEqualStrings("urn:schemas-upnp-org:service:WANIPConnection:1", res1.service_type);

    // relative resolved against /upnp/desc.xml
    const xml2 =
        \\<root>
        \\  <service>
        \\    <serviceType>urn:schemas-upnp-org:service:WANIPConnection:1</serviceType>
        \\    <controlURL>ctl/IPConn</controlURL>
        \\  </service>
        \\</root>
    ;
    const res2 = try parseControlUrl(alloc, xml2, loc_ip, loc_port, loc_path);
    defer alloc.free(res2.path);
    try std.testing.expectEqualStrings("/upnp/ctl/IPConn", res2.path);

    // absolute URL with other host rejected
    const xml3 =
        \\<root>
        \\  <service>
        \\    <serviceType>urn:schemas-upnp-org:service:WANIPConnection:1</serviceType>
        \\    <controlURL>http://10.0.0.99:5000/ctl</controlURL>
        \\  </service>
        \\</root>
    ;
    try std.testing.expectError(error.HostMismatch, parseControlUrl(alloc, xml3, loc_ip, loc_port, loc_path));

    // controlURL with \r\n rejected
    const xml4 =
        "<root><service><serviceType>urn:schemas-upnp-org:service:WANIPConnection:1</serviceType>" ++
        "<controlURL>/ctl\r\nHost: evil.com</controlURL></service></root>";
    try std.testing.expectError(error.InvalidControlUrl, parseControlUrl(alloc, xml4, loc_ip, loc_port, loc_path));

    // controlURL belonging to a different <service> than the WAN one is not used
    const xml5 =
        \\<root>
        \\  <service>
        \\    <serviceType>urn:schemas-upnp-org:service:Layer3Forwarding:1</serviceType>
        \\    <controlURL>/ctl/L3</controlURL>
        \\  </service>
        \\  <service>
        \\    <serviceType>urn:schemas-upnp-org:service:WANIPConnection:1</serviceType>
        \\    <controlURL>/ctl/WAN</controlURL>
        \\  </service>
        \\</root>
    ;
    const res5 = try parseControlUrl(alloc, xml5, loc_ip, loc_port, loc_path);
    defer alloc.free(res5.path);
    try std.testing.expectEqualStrings("/ctl/WAN", res5.path);

    // WANIPConnection:2 and WANPPPConnection:1 accepted
    const xml_v2 =
        \\<root><service>
        \\  <serviceType>urn:schemas-upnp-org:service:WANIPConnection:2</serviceType>
        \\  <controlURL>/ctl/v2</controlURL>
        \\</service></root>
    ;
    const res_v2 = try parseControlUrl(alloc, xml_v2, loc_ip, loc_port, loc_path);
    defer alloc.free(res_v2.path);
    try std.testing.expectEqualStrings("urn:schemas-upnp-org:service:WANIPConnection:2", res_v2.service_type);

    const xml_ppp =
        \\<root><service>
        \\  <serviceType>urn:schemas-upnp-org:service:WANPPPConnection:1</serviceType>
        \\  <controlURL>/ctl/ppp</controlURL>
        \\</service></root>
    ;
    const res_ppp = try parseControlUrl(alloc, xml_ppp, loc_ip, loc_port, loc_path);
    defer alloc.free(res_ppp.path);
    try std.testing.expectEqualStrings("urn:schemas-upnp-org:service:WANPPPConnection:1", res_ppp.service_type);
}

test "soapStatusOk fault parsing and status check" {
    // HTTP/1.1 500 with body containing "200 OK" is a failure
    const resp_fail = "HTTP/1.1 500 Internal Server Error\r\n\r\nSome body containing 200 OK text";
    const res1 = soapStatusOk(resp_fail);
    try std.testing.expect(!res1.isOk());

    // fault with <errorCode>725</errorCode> returns 725
    const resp_725 = "HTTP/1.1 500 Internal Server Error\r\n\r\n<s:Fault><errorCode>725</errorCode></s:Fault>";
    const res2 = soapStatusOk(resp_725);
    try std.testing.expect(!res2.isOk());
    try std.testing.expectEqual(@as(?u16, 725), res2.errorCode());

    // 200 OK passes
    const resp_200 = "HTTP/1.1 200 OK\r\n\r\n<s:Envelope></s:Envelope>";
    const res3 = soapStatusOk(resp_200);
    try std.testing.expect(res3.isOk());
}

test "buildAddPortMapping duration and formatting" {
    var buf: [1024]u8 = undefined;
    const soap = try buildAddPortMapping(&buf, "urn:schemas-upnp-org:service:WANIPConnection:1", 9000, "TCP", "192.168.1.10", 3600);
    try std.testing.expect(std.mem.indexOf(u8, soap, "<NewLeaseDuration>3600</NewLeaseDuration>") != null);
    try std.testing.expect(std.mem.indexOf(u8, soap, "<NewExternalPort>9000</NewExternalPort>") != null);
}
