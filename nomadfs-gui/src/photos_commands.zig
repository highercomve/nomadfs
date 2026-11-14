//! The Photos commands: thin wrappers over the timeline service
//! (src/fs/photos.zig), which the node owns (`node.photos`). What counts as
//! a photo, the order, dedupe and paging all live there; these parse the
//! page's arguments and hand back the shapes every front end uses.

const std = @import("std");
const nomadfs = @import("nomadfs");
const commands = @import("commands.zig");
const media = @import("media.zig");

const photos = nomadfs.fs.photos;

pub const PhotosArgs = struct {
    folder: []const u8 = "",
    /// "all", "photos" or "videos".
    kinds: []const u8 = "all",
    /// photos_page: the index's generation (0: as it is now).
    generation: u64 = 0,
    start: u32 = 0,
    count: u32 = 300,
};

/// The index plus where the page loads thumbnails from: it appends
/// `<author>/<cid>/t.jpg` (media.zig). "" when the media server couldn't
/// start: the page shows placeholders.
pub const IndexView = struct {
    generation: u64,
    total: u32,
    photos: u32,
    videos: u32,
    mtimes: []const u64,
    folders: []const photos.FolderCount,
    thumb_base: []const u8,
};

fn filter(args: PhotosArgs) !photos.Filter {
    return .{ .folder = args.folder, .kinds = photos.KindSet.parse(args.kinds) orelse return error.InvalidArgument };
}

pub fn index(gpa: std.mem.Allocator, args: PhotosArgs) !IndexView {
    const handle = commands.mediaAcquire() orelse return error.NotRunning;
    defer commands.mediaRelease();
    const value = try handle.node.photosIndex(gpa, try filter(args));
    return .{
        .generation = value.generation,
        .total = value.total,
        .photos = value.photos,
        .videos = value.videos,
        .mtimes = value.mtimes,
        .folders = value.folders,
        .thumb_base = media.thumbBase(gpa) catch "",
    };
}

/// error.Stale once the folder changed since `args.generation`: the page
/// loads the index again.
pub fn page(gpa: std.mem.Allocator, args: PhotosArgs) !photos.WirePage {
    const handle = commands.mediaAcquire() orelse return error.NotRunning;
    defer commands.mediaRelease();
    const value = try handle.node.photosPage(gpa, args.generation, try filter(args), args.start, args.count);
    return photos.wirePage(gpa, value);
}
