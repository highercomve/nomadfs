//! What kind of picture or film a file is: from its name (the timeline,
//! with no bytes read) or from its first bytes (`sniff`, before decoding).
//! The name lists are the app's (nomadfs-gui/frontend/file-types.js and
//! preview.js), with HEIC and camera RAW apart: no decoder here reads them.

const std = @import("std");

pub const Kind = enum {
    photo,
    video,
    heic,
    raw,
    other,

    /// A kind the timeline shows.
    pub fn isMedia(self: Kind) bool {
        return self != .other;
    }
};

const photo_ext = [_][]const u8{ "jpg", "jpeg", "png", "gif", "webp", "avif", "bmp", "svg", "tif", "tiff" };
const heic_ext = [_][]const u8{ "heic", "heif" };
const raw_ext = [_][]const u8{ "dng", "raw", "cr2", "nef", "arw" };
// Not "ts": TypeScript sources share it; camcorder streams are .mts/.m2ts.
const video_ext = [_][]const u8{ "mp4", "mov", "m4v", "mkv", "webm", "avi", "3gp", "wmv", "flv", "mts", "m2ts", "mpg", "mpeg", "mxf", "ogv", "vob" };

/// The longest extension in the lists above.
const max_ext = 4;

/// The kind a file name says, by its extension (any case).
pub fn kindOfName(name: []const u8) Kind {
    const dot = std.mem.lastIndexOfScalar(u8, name, '.') orelse return .other;
    const ext = name[dot + 1 ..];
    if (ext.len == 0 or ext.len > max_ext) return .other;
    var buf: [max_ext]u8 = undefined;
    const lower = std.ascii.lowerString(&buf, ext);
    if (inList(&photo_ext, lower)) return .photo;
    if (inList(&heic_ext, lower)) return .heic;
    if (inList(&raw_ext, lower)) return .raw;
    if (inList(&video_ext, lower)) return .video;
    return .other;
}

fn inList(list: []const []const u8, ext: []const u8) bool {
    for (list) |e| if (std.mem.eql(u8, e, ext)) return true;
    return false;
}

/// How many leading bytes `sniff` looks at.
pub const sniff_len = 16;

/// The kind a file's first bytes say (`head`: up to `sniff_len` of them).
pub fn sniff(head: []const u8) Kind {
    if (std.mem.startsWith(u8, head, "\xFF\xD8\xFF")) return .photo; // JPEG
    if (std.mem.startsWith(u8, head, "II*\x00") or std.mem.startsWith(u8, head, "MM\x00*")) return .raw; // TIFF RAW
    if (std.mem.startsWith(u8, head, "\x89PNG\r\n\x1a\n")) return .photo;
    if (std.mem.startsWith(u8, head, "GIF87a") or std.mem.startsWith(u8, head, "GIF89a")) return .photo;
    if (std.mem.startsWith(u8, head, "BM") and head.len >= 14) return .photo;
    if (std.mem.startsWith(u8, head, "\x1A\x45\xDF\xA3")) return .video; // EBML: Matroska, WebM
    if (head.len >= 12 and std.mem.eql(u8, head[0..4], "RIFF")) {
        if (std.mem.eql(u8, head[8..12], "AVI ")) return .video;
        if (std.mem.eql(u8, head[8..12], "WEBP")) return .photo;
        return .other;
    }
    if (head.len >= 12 and std.mem.eql(u8, head[4..8], "ftyp")) return ftypKind(head[8..12]);
    return .other;
}

/// An ISO base media file by its major brand: HEIF stills, AVIF, or a
/// film (MP4, QuickTime, 3GP and the rest).
fn ftypKind(brand: []const u8) Kind {
    const heif = [_][]const u8{ "heic", "heix", "heim", "heis", "hevc", "hevx", "mif1", "msf1" };
    if (inList(&heif, brand)) return .heic;
    if (std.mem.eql(u8, brand, "avif") or std.mem.eql(u8, brand, "avis")) return .photo;
    return .video;
}

test kindOfName {
    const cases = [_]struct { []const u8, Kind }{
        .{ "IMG_0001.JPG", .photo },
        .{ "a/b/pic.jpeg", .photo },
        .{ "shot.png", .photo },
        .{ "anim.gif", .photo },
        .{ "x.webp", .photo },
        .{ "scan.TIFF", .photo },
        .{ "IMG_1234.HEIC", .heic },
        .{ "photo.heif", .heic },
        .{ "PXL_2024.dng", .raw },
        .{ "canon.CR2", .raw },
        .{ "nikon.nef", .raw },
        .{ "sony.arw", .raw },
        .{ "clip.mp4", .video },
        .{ "clip.MOV", .video },
        .{ "film.mkv", .video },
        .{ "cam.m2ts", .video },
        .{ "app.ts", .other },
        .{ "notes.md", .other },
        .{ "README", .other },
        .{ "trailing.", .other },
        .{ "long.jpegxl", .other },
    };
    for (cases) |c| try std.testing.expectEqual(c[1], kindOfName(c[0]));
}

test sniff {
    const cases = [_]struct { []const u8, Kind }{
        .{ "\xFF\xD8\xFF\xE1\x00\x10Exif", .photo },
        .{ "\x89PNG\r\n\x1a\n\x00\x00\x00\x0dIHDR", .photo },
        .{ "GIF89a\x01\x00\x01\x00", .photo },
        .{ "BM\x36\x00\x00\x00\x00\x00\x00\x00\x36\x00\x00\x00", .photo },
        .{ "\x00\x00\x00\x18ftypheic\x00\x00\x00\x00", .heic },
        .{ "\x00\x00\x00\x18ftypmif1\x00\x00\x00\x00", .heic },
        .{ "\x00\x00\x00\x1cftypavif\x00\x00\x00\x00", .photo },
        .{ "\x00\x00\x00\x20ftypisom\x00\x00\x02\x00", .video },
        .{ "\x00\x00\x00\x14ftypqt  \x00\x00\x00\x00", .video },
        .{ "\x1A\x45\xDF\xA3\x9f\x42\x86\x81", .video },
        .{ "RIFF\x00\x00\x00\x00AVI LIST", .video },
        .{ "RIFF\x00\x00\x00\x00WEBPVP8 ", .photo },
        .{ "RIFF\x00\x00\x00\x00WAVEfmt ", .other },
        .{ "II*\x00\x08\x00\x00\x00", .raw },
        .{ "MM\x00*\x00\x00\x00\x08", .raw },
        .{ "%PDF-1.7", .other },
        .{ "BM", .other },
        .{ "", .other },
        .{ "\xFF\xD8", .other },
    };
    for (cases) |c| try std.testing.expectEqual(c[1], sniff(c[0]));
}

/// Seconds since the epoch (UTC) of a date in a camera-style file name:
/// `PXL_20250818_181036127.jpg`, `IMG_20170917_152554.jpg`,
/// `IMG-20220110-WA0025.jpg`, `Screenshot_2024-03-01-10-22-33.png`,
/// `VID_20180101_101010.mp4`. The time is taken when it follows the date,
/// else noon (UTC). Null when the name holds no plausible date (1990–2099).
pub fn nameDate(name: []const u8) ?u64 {
    const base = if (std.mem.lastIndexOfScalar(u8, name, '/')) |slash| name[slash + 1 ..] else name;
    var i: usize = 0;
    while (i < base.len) : (i += 1) {
        // A date starts a run of digits: "x20220110" yes, "1202201101" no.
        if (i > 0 and std.ascii.isDigit(base[i - 1])) continue;
        if (parseDate(base[i..])) |secs| return secs;
    }
    return null;
}

/// `YYYYMMDD` or `YYYY-MM-DD` / `YYYY_MM_DD` at the start of `s`, then an
/// optional `[_- T]HHMMSS` (or with `-`/`_`/`.` between the parts).
fn parseDate(s: []const u8) ?u64 {
    var pos: usize = 0;
    const year = digits(s, &pos, 4) orelse return null;
    const sep = pos < s.len and (s[pos] == '-' or s[pos] == '_');
    if (sep) pos += 1;
    const month = digits(s, &pos, 2) orelse return null;
    if (sep) {
        if (pos >= s.len or (s[pos] != '-' and s[pos] != '_')) return null;
        pos += 1;
    }
    const day = digits(s, &pos, 2) orelse return null;
    // The date's digits end here: "202201101" is no date.
    if (pos < s.len and std.ascii.isDigit(s[pos])) return null;
    if (year < 1990 or year > 2099 or month < 1 or month > 12 or day < 1 or day > daysIn(year, month)) return null;
    const midnight = daysFromCivil(year, month, day) * 86400;
    // A date alone: noon keeps it on that day in any time zone.
    var secs: u64 = midnight + 12 * 3600;

    if (pos < s.len and (s[pos] == '_' or s[pos] == '-' or s[pos] == ' ' or s[pos] == 'T')) {
        var t = pos + 1;
        const time_sep = t + 2 < s.len and !std.ascii.isDigit(s[t + 2]);
        if (digits(s, &t, 2)) |h| {
            if (time_sep and t < s.len) t += 1;
            if (digits(s, &t, 2)) |m| {
                if (time_sep and t < s.len) t += 1;
                if (digits(s, &t, 2)) |sec| {
                    // The phone's own clock (UTC for Pixel names): a few
                    // hours off at worst, which the 36-hour rule absorbs.
                    if (h < 24 and m < 60 and sec < 60) secs = midnight + h * 3600 + m * 60 + sec;
                }
            }
        }
    }
    return secs;
}

fn digits(s: []const u8, pos: *usize, n: usize) ?u64 {
    if (pos.* + n > s.len) return null;
    var v: u64 = 0;
    for (s[pos.* .. pos.* + n]) |c| {
        if (!std.ascii.isDigit(c)) return null;
        v = v * 10 + (c - '0');
    }
    pos.* += n;
    return v;
}

fn daysIn(year: u64, month: u64) u64 {
    const leap = (year % 4 == 0 and year % 100 != 0) or year % 400 == 0;
    const table = [_]u64{ 31, if (leap) 29 else 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };
    return table[month - 1];
}

/// Days since 1970-01-01 (Howard Hinnant's days_from_civil), year >= 1970.
fn daysFromCivil(year: u64, month: u64, day: u64) u64 {
    const y = if (month <= 2) year - 1 else year;
    const era = y / 400;
    const yoe = y - era * 400;
    const mp = (month + 9) % 12;
    const doy = (153 * mp + 2) / 5 + day - 1;
    const doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    return era * 146097 + doe - 719468;
}

/// When the photo or video was taken, as far as the listing can tell: a
/// date in its name when the file's modified time is more than 36 hours
/// from it (a copy or a backup that stamped the file when it arrived),
/// else the modified time, which is the more precise of the two.
pub fn takenTime(name: []const u8, mtime: u64) u64 {
    const from_name = nameDate(name) orelse return mtime;
    const gap = if (mtime > from_name) mtime - from_name else from_name - mtime;
    return if (gap > 36 * 3600) from_name else mtime;
}

test "nameDate: camera, WhatsApp and screenshot names" {
    const t = std.testing;
    try t.expectEqual(@as(?u64, 1641816000), nameDate("IMG-20220110-WA0025.jpg")); // 2022-01-10 12:00
    try t.expectEqual(@as(?u64, 1755540636), nameDate("Camera/PXL_20250818_181036127.RAW-01.COVER.jpg")); // 18:10:36
    try t.expectEqual(@as(?u64, 1505663154), nameDate("IMG_20170917_154554472_HDR.jpg"));
    try t.expectEqual(@as(?u64, 1709288553), nameDate("Screenshot_2024-03-01-10-22-33.png"));
    try t.expectEqual(@as(?u64, 1514801410), nameDate("VID_20180101_101010.mp4"));
    try t.expectEqual(@as(?u64, null), nameDate("1234567890.jpg"));
    try t.expectEqual(@as(?u64, null), nameDate("IMG_1234.jpg"));
    try t.expectEqual(@as(?u64, null), nameDate("photo_20221340.jpg")); // month 13
    try t.expectEqual(@as(?u64, null), nameDate("x202201101.jpg")); // 9 digits
}

test "takenTime: the name wins only when the file date is far from it" {
    const t = std.testing;
    // Backed up on 2026-10-29: the name's 2022 date wins.
    try t.expectEqual(@as(u64, 1641816000), takenTime("IMG-20220110-WA0025.jpg", 1793318400));
    // A camera file whose date agrees to the minute keeps its precise time.
    try t.expectEqual(@as(u64, 1755540662), takenTime("PXL_20250818_181036127.jpg", 1755540662));
    try t.expectEqual(@as(u64, 42), takenTime("holiday.jpg", 42));
}
