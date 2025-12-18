const std = @import("std");
const network = @import("../network/mod.zig");
const dht = @import("../dht/mod.zig");
const storage = @import("../storage/mod.zig");

pub const BlockManager = struct {
    allocator: std.mem.Allocator,
    net: *network.manager.ConnectionManager,
    dht_node: *dht.Node,
    store: ?*storage.engine.StorageEngine, // Nullable for mobile

    pub const Config = struct {
        network: *network.manager.ConnectionManager,
        dht: *dht.Node,
        storage: ?*storage.engine.StorageEngine,
    };

    pub fn init(allocator: std.mem.Allocator, config: Config) !*BlockManager {
        const self = try allocator.create(BlockManager);
        self.* = .{
            .allocator = allocator,
            .net = config.network,
            .dht_node = config.dht,
            .store = config.storage,
        };
        return self;
    }

    pub fn deinit(self: *BlockManager) void {
        self.allocator.destroy(self);
    }

    // High-level operations will go here
    // pub fn put(self: *BlockManager, data: []const u8) !CID { ... }
    // pub fn get(self: *BlockManager, cid: CID) ![]u8 { ... }
};
