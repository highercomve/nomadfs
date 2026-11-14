//! Bounded XML parsing for S3 responses. DTDs and external entities are rejected.
const std = @import("std");
const Allocator = std.mem.Allocator;
pub const Error = error{ OutOfMemory, InvalidXml };

pub const Node = struct {
    name: []const u8,
    parent: ?usize,
    text: std.ArrayList(u8) = .empty,

    pub fn value(self: Node) []const u8 {
        return self.text.items;
    }

    pub fn isNamed(self: Node, name: []const u8) bool {
        return std.mem.eql(u8, localName(self.name), name);
    }
};

/// All names and values remain valid until deinit. Input is not borrowed.
pub const Document = struct {
    arena: std.heap.ArenaAllocator,
    nodes: []const Node,

    pub fn deinit(self: *Document) void {
        self.arena.deinit();
        self.* = undefined;
    }

    pub fn child(self: Document, parent: usize, name: []const u8) ?usize {
        for (self.nodes, 0..) |node, i| {
            if (node.parent == parent and std.mem.eql(u8, localName(node.name), name)) return i;
        }
        return null;
    }

    pub fn text(self: Document, parent: usize, name: []const u8) ?[]const u8 {
        const index = self.child(parent, name) orelse return null;
        return self.nodes[index].value();
    }

    pub fn rootIs(self: Document, name: []const u8) bool {
        return self.nodes.len > 0 and std.mem.eql(u8, localName(self.nodes[0].name), name);
    }
};

fn localName(name: []const u8) []const u8 {
    return if (std.mem.lastIndexOfScalar(u8, name, ':')) |colon| name[colon + 1 ..] else name;
}

fn validCodepoint(c: u21) bool {
    return c == 9 or c == 10 or c == 13 or
        (c >= 0x20 and c <= 0xd7ff) or (c >= 0xe000 and c <= 0xfffd) or c >= 0x10000;
}

fn decode(allocator: Allocator, output: *std.ArrayList(u8), raw: []const u8) Error!void {
    var position: usize = 0;
    while (position < raw.len) {
        if (raw[position] != '&') {
            if (raw[position] < 32 and raw[position] != 9 and raw[position] != 10 and raw[position] != 13)
                return error.InvalidXml;
            try output.append(allocator, raw[position]);
            position += 1;
            continue;
        }
        const end = std.mem.indexOfScalarPos(u8, raw, position, ';') orelse return error.InvalidXml;
        const entity = raw[position + 1 .. end];
        const named = [_][]const u8{ "amp", "lt", "gt", "quot", "apos" };
        const chars = "&<>\"'";
        var found = false;
        for (named, chars) |name, char| {
            if (std.mem.eql(u8, entity, name)) {
                try output.append(allocator, char);
                found = true;
                break;
            }
        }
        if (!found) {
            if (entity.len < 2 or entity[0] != '#') return error.InvalidXml;
            const hex = entity.len > 2 and entity[1] == 'x';
            const c = std.fmt.parseInt(u21, entity[if (hex) 2 else 1..], if (hex) 16 else 10) catch
                return error.InvalidXml;
            if (!validCodepoint(c)) return error.InvalidXml;
            var encoded: [4]u8 = undefined;
            const n = std.unicode.utf8Encode(c, &encoded) catch return error.InvalidXml;
            try output.appendSlice(allocator, encoded[0..n]);
        }
        position = end + 1;
    }
}

const Parser = struct {
    allocator: Allocator,
    source: []const u8,
    nodes: std.ArrayList(Node) = .empty,
    stack: [32]usize = undefined,
    depth: usize = 0,
    position: usize = 0,

    fn parse(self: *Parser) Error!void {
        while (self.position < self.source.len) {
            const raw = self.source[self.position..];
            if (raw[0] != '<') {
                const n = std.mem.indexOfScalar(u8, raw, '<') orelse raw.len;
                if (self.depth == 0) {
                    if (std.mem.trim(u8, raw[0..n], " \r\n\t").len != 0) return error.InvalidXml;
                } else {
                    try decode(self.allocator, &self.nodes.items[self.stack[self.depth - 1]].text, raw[0..n]);
                }
                self.position += n;
            } else if (std.mem.startsWith(u8, raw, "<!--")) {
                const end = std.mem.indexOf(u8, raw[4..], "-->") orelse return error.InvalidXml;
                self.position += end + 7;
            } else if (std.mem.startsWith(u8, raw, "<?")) {
                const end = std.mem.indexOf(u8, raw, "?>") orelse return error.InvalidXml;
                self.position += end + 2;
            } else if (std.mem.startsWith(u8, raw, "<![CDATA[")) {
                if (self.depth == 0) return error.InvalidXml;
                const end = std.mem.indexOf(u8, raw[9..], "]]>") orelse return error.InvalidXml;
                try self.nodes.items[self.stack[self.depth - 1]].text.appendSlice(self.allocator, raw[9 .. 9 + end]);
                self.position += end + 12;
            } else {
                try self.tag();
            }
        }
        if (self.depth != 0 or self.nodes.items.len == 0) return error.InvalidXml;
    }

    fn tag(self: *Parser) Error!void {
        const raw = self.source[self.position..];
        if (raw.len < 3 or raw[1] == '!') return error.InvalidXml;
        var end: usize = 1;
        var quote: u8 = 0;
        while (end < raw.len) : (end += 1) {
            const c = raw[end];
            if (quote != 0) {
                if (c == quote) quote = 0;
            } else if (c == '\'' or c == '"') {
                quote = c;
            } else if (c == '>') break;
        }
        if (end == raw.len) return error.InvalidXml;
        const closing = raw[1] == '/';
        const empty = raw[end - 1] == '/';
        const contents = std.mem.trim(u8, raw[if (closing) 2 else 1..if (empty) end - 1 else end], " \r\n\t");
        const name_end = std.mem.indexOfAny(u8, contents, " \r\n\t") orelse contents.len;
        const name = contents[0..name_end];
        if (name.len == 0) return error.InvalidXml;
        for (name) |c| {
            if (!std.ascii.isAlphanumeric(c) and std.mem.indexOfScalar(u8, "_:.-", c) == null)
                return error.InvalidXml;
        }
        if (closing) {
            if (empty or name_end != contents.len or self.depth == 0) return error.InvalidXml;
            const node = self.nodes.items[self.stack[self.depth - 1]];
            if (!std.mem.eql(u8, name, node.name)) return error.InvalidXml;
            self.depth -= 1;
        } else {
            if (self.depth == self.stack.len or (self.depth == 0 and self.nodes.items.len > 0)) return error.InvalidXml;
            const index = self.nodes.items.len;
            try self.nodes.append(self.allocator, .{
                .name = name,
                .parent = if (self.depth == 0) null else self.stack[self.depth - 1],
            });
            if (!empty) {
                self.stack[self.depth] = index;
                self.depth += 1;
            }
        }
        self.position += end + 1;
    }
};

/// Parses at most 16 MiB with nesting limited to 32 levels.
pub fn parse(allocator: Allocator, source: []const u8) Error!Document {
    if (source.len > 16 * 1024 * 1024 or !std.unicode.utf8ValidateSlice(source)) return error.InvalidXml;
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const a = arena.allocator();
    var parser: Parser = .{ .allocator = a, .source = try a.dupe(u8, source) };
    try parser.parse();
    return .{ .arena = arena, .nodes = parser.nodes.items };
}

/// Whether a bucket keeps old versions of replaced and deleted objects.
pub const Versioning = enum { off, enabled, suspended };

/// Reads a GetBucketVersioning answer. A bucket that never had versioning
/// (and a store without it) sends no Status.
pub fn parseVersioning(allocator: Allocator, source: []const u8) Error!Versioning {
    var document = try parse(allocator, source);
    defer document.deinit();
    if (!document.rootIs("VersioningConfiguration")) return error.InvalidXml;
    const status = std.mem.trim(u8, document.text(0, "Status") orelse return .off, " \r\n\t");
    if (status.len == 0) return .off;
    if (std.mem.eql(u8, status, "Enabled")) return .enabled;
    if (std.mem.eql(u8, status, "Suspended")) return .suspended;
    return error.InvalidXml;
}

/// Returns owned XML character data suitable for an ETag in multipart completion.
pub fn escape(allocator: Allocator, source: []const u8) Error![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    for (source) |c| out.writer.writeAll(switch (c) {
        '&' => "&amp;",
        '<' => "&lt;",
        '>' => "&gt;",
        '"' => "&quot;",
        '\'' => "&apos;",
        else => &.{c},
    }) catch return error.OutOfMemory;
    return out.toOwnedSlice();
}

test "XML namespaces entities empty elements and CDATA" {
    var document = try parse(std.testing.allocator, "<?xml version=\"1.0\"?><s:Result xmlns:s=\"urn:test\"><Key>a&amp;&#xE9;&#47;<![CDATA[<b>]]></Key><Empty/></s:Result>");
    defer document.deinit();
    try std.testing.expect(document.rootIs("Result"));
    try std.testing.expectEqualStrings("a&é/<b>", document.text(0, "Key").?);
    try std.testing.expectEqualStrings("", document.text(0, "Empty").?);
}

test "XML bucket versioning status" {
    const cases = [_]struct { []const u8, Versioning }{
        .{ "<VersioningConfiguration xmlns=\"http://s3.amazonaws.com/doc/2006-03-01/\"/>", .off },
        .{ "<VersioningConfiguration><Status></Status></VersioningConfiguration>", .off },
        .{ "<VersioningConfiguration><Status>Enabled</Status></VersioningConfiguration>", .enabled },
        .{ "<VersioningConfiguration><Status>Suspended</Status><MfaDelete>Disabled</MfaDelete></VersioningConfiguration>", .suspended },
    };
    for (cases) |case| try std.testing.expectEqual(case[1], try parseVersioning(std.testing.allocator, case[0]));
    try std.testing.expectError(error.InvalidXml, parseVersioning(std.testing.allocator, "<VersioningConfiguration><Status>Maybe</Status></VersioningConfiguration>"));
    try std.testing.expectError(error.InvalidXml, parseVersioning(std.testing.allocator, "<ListBucketResult/>"));
}

test "XML rejects malformed responses and entity declarations" {
    for ([_][]const u8{ "<A><B></A>", "<A/ ><B/>", "<A>&unknown;</A>", "<!DOCTYPE x><A/>", "<A>", "" }) |raw|
        try std.testing.expectError(error.InvalidXml, parse(std.testing.allocator, raw));
}
