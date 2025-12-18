const std = @import("std");
const Block = @import("block.zig").Block;

pub const Link = struct {
    name: []const u8, // e.g., filename or "parent"
    cid: [32]u8,
    size: u64,
};

pub const DagNode = struct {
    data: []const u8,
    links: []Link,

    pub fn encode(self: DagNode, allocator: std.mem.Allocator) ![]const u8 {
        // Simple serialization format:
        // [num_links: u32]
        // [link 1] ...
        // [data_len: u32]
        // [data]
        // This is a placeholder. Real implementation might use Protobuf or IPLD (CBOR).
        
        var list = std.ArrayList(u8).init(allocator);
        
        // Write num_links
        try list.writer().writeInt(u32, @intCast(self.links.len), .little);

        for (self.links) |link| {
            try list.writer().writeInt(u32, @intCast(link.name.len), .little);
            try list.writer().writeAll(link.name);
            try list.writer().writeAll(&link.cid);
            try list.writer().writeInt(u64, link.size, .little);
        }

        try list.writer().writeInt(u32, @intCast(self.data.len), .little);
        try list.writer().writeAll(self.data);

        return list.toOwnedSlice();
    }

    pub fn decode(buffer: []const u8, allocator: std.mem.Allocator) !DagNode {
        var fbs = std.io.fixedBufferStream(buffer);
        var reader = fbs.reader();

        const num_links = try reader.readInt(u32, .little);
        var links = try allocator.alloc(Link, num_links);

        for (0..num_links) |i| {
            const name_len = try reader.readInt(u32, .little);
            const name = try allocator.alloc(u8, name_len);
            try reader.readNoEof(name);
            
            var cid: [32]u8 = undefined;
            try reader.readNoEof(&cid);
            
            const size = try reader.readInt(u64, .little);
            
            links[i] = Link{ .name = name, .cid = cid, .size = size };
        }

        const data_len = try reader.readInt(u32, .little);
        const data = try allocator.alloc(u8, data_len);
        try reader.readNoEof(data);

        return DagNode{
            .data = data,
            .links = links,
        };
    }
    
    pub fn deinit(self: *DagNode, allocator: std.mem.Allocator) void {
        allocator.free(self.data);
        for (self.links) |link| {
            allocator.free(link.name);
        }
        allocator.free(self.links);
    }
};
