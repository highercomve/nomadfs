const std = @import("std");

pub const NodeID = struct {
    bytes: [32]u8,

    pub fn random() NodeID {
        var id: NodeID = undefined;
        std.crypto.random.bytes(&id.bytes);
        return id;
    }

    pub fn fromData(data: []const u8) NodeID {
        var id: NodeID = undefined;
        std.crypto.hash.sha2.Sha256.hash(data, &id.bytes);
        return id;
    }

    pub fn eql(self: NodeID, other: NodeID) bool {
        return std.mem.eql(u8, &self.bytes, &other.bytes);
    }

    /// Calculates the XOR distance between two NodeIDs.
    /// Returns a new NodeID representing the distance.
    pub fn distance(self: NodeID, other: NodeID) NodeID {
        var result: NodeID = undefined;
        for (0..32) |i| {
            result.bytes[i] = self.bytes[i] ^ other.bytes[i];
        }
        return result;
    }

    /// Returns the number of leading zero bits in the XOR distance (common prefix length).
    pub fn commonPrefixLen(self: NodeID, other: NodeID) u8 {
        const dist = self.distance(other);
        var zeros: u8 = 0;
        for (dist.bytes) |byte| {
            if (byte == 0) {
                zeros += 8;
            } else {
                zeros += @as(u8, @intCast(@clz(byte))) - 24; // @clz returns u32/u64 count
                break;
            }
        }
        return zeros;
    }

    pub fn format(
        self: NodeID,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = fmt;
        _ = options;
        try writer.print("{s}", .{std.fmt.fmtSliceHexLower(&self.bytes)});
    }
};
