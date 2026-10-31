//! What the WebDAV server writes: hrefs, XML text, dates, content types.

const std = @import("std");

pub fn writeFileProps(w: *std.Io.Writer, name: []const u8, size: u64, mtime: u64, cid: [32]u8) !void {
    var date_buf: [40]u8 = undefined;
    const etag = std.fmt.bytesToHex(cid[0..8].*, .lower);
    try w.print("<D:resourcetype/><D:getcontentlength>{d}</D:getcontentlength><D:getlastmodified>{s}</D:getlastmodified>" ++
        "<D:getcontenttype>{s}</D:getcontenttype><D:getetag>\"{s}\"</D:getetag>", .{ size, httpDate(&date_buf, mtime), contentType(name), etag });
}

/// `<root>/seg/seg[/child]`, each segment percent-encoded. `root` is the
/// server's path prefix (`/<token>`).
pub fn writeHref(w: *std.Io.Writer, root: []const u8, segments: []const []const u8, child: ?[]const u8) !void {
    try w.writeAll(root);
    for (segments) |s| {
        try w.writeAll("/");
        try writeEncoded(w, s);
    }
    if (child) |c| {
        try w.writeAll("/");
        try writeEncoded(w, c);
    }
}

fn writeEncoded(w: *std.Io.Writer, s: []const u8) !void {
    for (s) |c| {
        if (std.ascii.isAlphanumeric(c) or c == '-' or c == '.' or c == '_' or c == '~') {
            try w.writeByte(c);
        } else try w.print("%{X:0>2}", .{c});
    }
}

pub fn writeEscaped(w: *std.Io.Writer, s: []const u8) !void {
    for (s) |c| switch (c) {
        '&' => try w.writeAll("&amp;"),
        '<' => try w.writeAll("&lt;"),
        '>' => try w.writeAll("&gt;"),
        '"' => try w.writeAll("&quot;"),
        else => try w.writeByte(c),
    };
}

pub fn validXmlName(s: []const u8) bool {
    if (s.len == 0 or s.len > 64) return false;
    for (s) |c| if (!(std.ascii.isAlphanumeric(c) or c == '_' or c == '-' or c == '.')) return false;
    return std.ascii.isAlphabetic(s[0]) or s[0] == '_';
}

/// RFC 1123: `Sat, 31 Oct 2026 12:00:00 GMT`.
pub fn httpDate(buf: *[40]u8, seconds: u64) []const u8 {
    const es = std.time.epoch.EpochSeconds{ .secs = seconds };
    const day = es.getEpochDay();
    const yd = day.calculateYearDay();
    const md = yd.calculateMonthDay();
    const ds = es.getDaySeconds();
    const weekdays = [_][]const u8{ "Thu", "Fri", "Sat", "Sun", "Mon", "Tue", "Wed" };
    const months = [_][]const u8{ "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" };
    return std.fmt.bufPrint(buf, "{s}, {d:0>2} {s} {d} {d:0>2}:{d:0>2}:{d:0>2} GMT", .{
        weekdays[@intCast(day.day % 7)], md.day_index + 1,        months[@intFromEnum(md.month) - 1], yd.year,
        ds.getHoursIntoDay(),            ds.getMinutesIntoHour(), ds.getSecondsIntoMinute(),
    }) catch "Thu, 01 Jan 1970 00:00:00 GMT";
}

pub fn contentType(name: []const u8) []const u8 {
    const ext = std.fs.path.extension(name);
    const map = [_][2][]const u8{
        .{ ".txt", "text/plain" },        .{ ".md", "text/markdown" }, .{ ".html", "text/html" },
        .{ ".pdf", "application/pdf" },   .{ ".jpg", "image/jpeg" },   .{ ".jpeg", "image/jpeg" },
        .{ ".png", "image/png" },         .{ ".gif", "image/gif" },    .{ ".webp", "image/webp" },
        .{ ".heic", "image/heic" },       .{ ".mp4", "video/mp4" },    .{ ".mov", "video/quicktime" },
        .{ ".mkv", "video/x-matroska" },  .{ ".webm", "video/webm" },  .{ ".mp3", "audio/mpeg" },
        .{ ".m4a", "audio/mp4" },         .{ ".flac", "audio/flac" },  .{ ".zip", "application/zip" },
        .{ ".json", "application/json" }, .{ ".csv", "text/csv" },
    };
    for (map) |m| if (std.ascii.eqlIgnoreCase(ext, m[0])) return m[1];
    return "application/octet-stream";
}

test httpDate {
    var buf: [40]u8 = undefined;
    try std.testing.expectEqualStrings("Thu, 01 Jan 1970 00:00:00 GMT", httpDate(&buf, 0));
    try std.testing.expectEqualStrings("Sat, 31 Oct 2026 12:34:56 GMT", httpDate(&buf, 1793450096));
}

