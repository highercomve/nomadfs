const std = @import("std");

pub const NodeID = struct {
    bytes: [32]u8,

    pub fn fromPublicKey(public_key: [32]u8) NodeID {
        var id: NodeID = undefined;
        // In a real-world scenario, we might use a hash of the public key (e.g., Blake2b-256)
        // For simplicity in the MVP, we use the public key directly if it's already 32 bytes
        // or hash it if we want to ensure uniform distribution.
        std.crypto.hash.blake2.Blake2s256.hash(&public_key, &id.bytes, .{});
        return id;
    }

    pub fn generate() NodeID {
        var id: NodeID = undefined;
        std.crypto.random.bytes(&id.bytes);
        return id;
    }

    pub fn fromData(data: []const u8) NodeID {
        var id: NodeID = undefined;
        std.crypto.hash.sha2.Sha256.hash(data, &id.bytes, .{});
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
                zeros += @intCast(@clz(byte));
                break;
            }
        }
        std.debug.assert(zeros <= 256);
        return zeros;
    }

    pub fn format(
        self: NodeID,
        writer: anytype,
    ) !void {
        try writer.print("{x}", .{self.bytes});
    }

    pub fn randomIdInBucket(self: NodeID, bucket_index: usize) NodeID {
        var new_id = self;
        // Bucket index i corresponds to CPL = i.
        // We need to flip the bit at index i (0-based from MSB)
        // and randomize all bits after it.
        
        const byte_idx = bucket_index / 8;
        const bit_offset = bucket_index % 8;
        const bit_mask = @as(u8, 1) << @intCast(7 - bit_offset);

        // Flip the determining bit
        new_id.bytes[byte_idx] ^= bit_mask;

        // Randomize remaining bits in this byte
        // Mask of bits to randomize (those to the right of bit_offset)
        const rand_mask = bit_mask - 1;
        if (rand_mask > 0) {
            var rand_byte: u8 = undefined;
            std.crypto.random.bytes(std.mem.asBytes(&rand_byte));
            new_id.bytes[byte_idx] &= ~rand_mask; // Clear random bits
            new_id.bytes[byte_idx] |= (rand_byte & rand_mask); // Set new random bits
        }

        // Randomize all subsequent bytes
        if (byte_idx + 1 < 32) {
            std.crypto.random.bytes(new_id.bytes[byte_idx + 1 ..]);
        }

        return new_id;
    }
};

test "id: commonPrefixLen" {
    var id1 = NodeID{ .bytes = [_]u8{0} ** 32 };
    var id2 = NodeID{ .bytes = [_]u8{0} ** 32 };

    // Identical
    try std.testing.expectEqual(@as(u8, 256), id1.commonPrefixLen(id2));

    // Differ in last bit
    id2.bytes[31] = 1;
    try std.testing.expectEqual(@as(u8, 255), id1.commonPrefixLen(id2));

    // Differ in first bit
    id2.bytes[31] = 0;
    id2.bytes[0] = 0x80;
    try std.testing.expectEqual(@as(u8, 0), id1.commonPrefixLen(id2));

    // Differ in second bit
    id2.bytes[0] = 0x40;
    try std.testing.expectEqual(@as(u8, 1), id1.commonPrefixLen(id2));

    // One byte identical, then differ
    id2.bytes[0] = 0;
    id2.bytes[1] = 0x80;
    try std.testing.expectEqual(@as(u8, 8), id1.commonPrefixLen(id2));
}
