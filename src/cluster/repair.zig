const std = @import("std");
const network = @import("../net/transport/mod.zig");
const storage = @import("../storage/mod.zig");
const dag = storage.dag;

pub const RepairManager = struct {
    // Request missing blocks from a peer
    pub fn sync(peer: network.Connection, root_cid: []const u8) !void {
        std.debug.assert(peer.ptr != null);
        std.debug.assert(root_cid.len == 32);
        std.debug.assert(root_cid.len > 0);

        // 1. Send WANT list (root_cid)
        // 2. Peer sends DAG node
        // 3. Decode DAG node, find missing children
        // 4. Recursively fetch missing children

        return error.NotImplemented;
    }
};
