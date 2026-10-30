const std = @import("std");

/// Reads a file from `offset` on, for the chunker and the DAG builder.
pub const FileReader = struct {
    io: std.Io,
    file: std.Io.File,
    offset: u64 = 0,

    pub fn read(self: *FileReader, dest: []u8) std.Io.File.ReadPositionalError!usize {
        if (dest.len == 0) return 0;
        const n = try self.file.readPositional(self.io, &.{dest}, self.offset);
        self.offset += n;
        return n;
    }
};
