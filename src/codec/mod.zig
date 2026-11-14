//! Codecs: turning a picture's bytes into a small JPEG (image.zig) and the
//! little it reads from EXIF on the way (exif.zig), and a film's frame
//! into one by running ffmpeg (video.zig). The layer sits below fs and
//! knows nothing of NomadFS: bytes in, bytes out. It uses std and the
//! vendored stb headers (stb/), whose memory is capped per call (budget.zig).

pub const image = @import("image.zig");
pub const exif = @import("exif.zig");
pub const raw = @import("raw.zig");
pub const video = @import("video.zig");
/// The memory cap on stb, and the allocator functions stb links against.
pub const budget = @import("budget.zig");

pub const Dims = image.Dims;
