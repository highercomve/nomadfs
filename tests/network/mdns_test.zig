const std = @import("std");
const network = @import("nomadfs").net.transport;
const id = @import("nomadfs").net.id;

const TestCtx = struct {

    target_id: id.NodeID,

    found: bool = false,

};



fn onDiscovery(ctx: ?*anyopaque, peer_id: id.NodeID, addr: std.net.Address) void {

    const t_ctx: *TestCtx = @ptrCast(@alignCast(ctx.?));

    if (peer_id.eql(t_ctx.target_id)) {

        t_ctx.found = true;

    }

    _ = addr;

}



test "network: mDNS local discovery" {

    const allocator = std.testing.allocator;



    const peer1_id = id.NodeID.generate();

    const peer2_id = id.NodeID.generate();



    var ctx1 = TestCtx{ .target_id = peer2_id };

    var ctx2 = TestCtx{ .target_id = peer1_id };



                var mdns1 = network.mdns.MDNS.init(allocator, peer1_id, 9001, 5354, onDiscovery, &ctx1);



                defer mdns1.deinit();



            



                var mdns2 = network.mdns.MDNS.init(allocator, peer2_id, 9002, 5354, onDiscovery, &ctx2);



                defer mdns2.deinit();



            



        



    



    try mdns1.start();

    try mdns2.start();



    var i: usize = 0;

    while (i < 150) : (i += 1) { // Wait up to 15s

        if (ctx1.found and ctx2.found) break;

        std.Thread.sleep(100 * std.time.ns_per_ms);

    }



    if (!ctx1.found or !ctx2.found) {

        std.debug.print("mDNS discovery failed. peer1 found peer2: {any}, peer2 found peer1: {any}\n", .{ ctx1.found, ctx2.found });

    }



    try std.testing.expect(ctx1.found);

    try std.testing.expect(ctx2.found);

}
