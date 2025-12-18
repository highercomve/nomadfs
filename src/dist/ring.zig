const std = @import("std");
const NodeID = @import("../dht/id.zig").NodeID;

const Token = struct {
    hash: u64, // Virtual node position on the ring
    node_id: NodeID,
};

pub const HashRing = struct {
    tokens: std.ArrayListUnmanaged(Token),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) HashRing {
        return HashRing{
            .tokens = std.ArrayListUnmanaged(Token){},
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *HashRing) void {
        self.tokens.deinit(self.allocator);
    }

    // Add a node to the ring with 'weight' virtual nodes
    pub fn addNode(self: *HashRing, node_id: NodeID, weight: usize) !void {
        // Generate 'weight' tokens derived from node_id
        for (0..weight) |i| {
            var hasher = std.hash.Fnv1a_64.init();
            hasher.update(&node_id.bytes);
            hasher.update(std.mem.asBytes(&i));
            const hash = hasher.final();

            try self.tokens.append(self.allocator, Token{ .hash = hash, .node_id = node_id });
        }
        
        // Sort tokens by hash
        const Context = struct {
            pub fn lessThan(_: @This(), a: Token, b: Token) bool {
                return a.hash < b.hash;
            }
        };
        std.mem.sort(Token, self.tokens.items, Context{}, Context.lessThan);
    }

    // Find the node responsible for 'key'
    pub fn getNode(self: *HashRing, key: []const u8) ?NodeID {
        if (self.tokens.items.len == 0) return null;

        var hasher = std.hash.Fnv1a_64.init();
        hasher.update(key);
        const hash = hasher.final();

        // Binary search for the first token >= hash
        // Using explicit loop as std.sort.upperBound expects exact match logic sometimes or complex context
        var low: usize = 0;
        var high: usize = self.tokens.items.len;

        while (low < high) {
            const mid = low + (high - low) / 2;
            if (self.tokens.items[mid].hash < hash) {
                low = mid + 1;
            } else {
                high = mid;
            }
        }

        if (low == self.tokens.items.len) {
            // Wrap around to 0
            return self.tokens.items[0].node_id;
        }
        return self.tokens.items[low].node_id;
    }
};
