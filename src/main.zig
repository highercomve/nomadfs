const std = @import("std");
const nomadfs = @import("nomadfs");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const config = try nomadfs.config.parseConfig(allocator, "roaming.conf");
    var cfg = config;
    defer cfg.deinit(allocator);

    std.debug.print("NomadFS Node: {s} (Storage: {})\n", .{ cfg.node.nickname, cfg.storage.enabled });
    std.debug.print("Listening on port: {d}\n", .{cfg.network.port});

    if (cfg.storage.enabled) {
        // Init DHT
        const my_id = nomadfs.dht.id.NodeID.random();
        var routing_table = nomadfs.dht.kbucket.RoutingTable.init(allocator, my_id);
        defer routing_table.deinit();

        std.debug.print("DHT Initialized. Local ID: {any}\n", .{my_id});

        // Init Ring
        var ring = nomadfs.dist.ring.HashRing.init(allocator);
        defer ring.deinit();
        try ring.addNode(my_id, 10);
        std.debug.print("Hash Ring Initialized with 10 virtual nodes.\n", .{});

        try nomadfs.network.tcp.listen(allocator, cfg.network.port, null, null);
    } else {
        std.debug.print("Node running in Client-Only mode.\n", .{});
        // Clients might still dial bootstrap peers
    }
}

test "simple test" {
    const gpa = std.testing.allocator;
    var list: std.ArrayList(i32) = .empty;
    defer list.deinit(gpa); // Try commenting this out and see if zig detects the memory leak!
    try list.append(gpa, 42);
    try std.testing.expectEqual(@as(i32, 42), list.pop());
}

test "fuzz example" {
    const Context = struct {
        fn testOne(context: @This(), input: []const u8) anyerror!void {
            _ = context;
            // Try passing `--fuzz` to `zig build test` and see if it manages to fail this test case!
            try std.testing.expect(!std.mem.eql(u8, "canyoufindme", input));
        }
    };
    try std.testing.fuzz(Context{}, Context.testOne, .{});
}
