test {
    _ = @import("network/integration.zig");
    _ = @import("network/security_test.zig");
    _ = @import("network/manager_test.zig");
    _ = @import("network/mdns_test.zig");
    _ = @import("network/yamux_test.zig");
    _ = @import("network/yamux_flow_control_test.zig");
    _ = @import("dht/lookup_test.zig");
    _ = @import("dht/rpc_test.zig");
    _ = @import("dht/ping_test.zig");
    _ = @import("dht/store_test.zig");
    _ = @import("dht/discovery_test.zig");
    _ = @import("dht/churn_test.zig");
    _ = @import("dht/kbucket_standard_test.zig");
    _ = @import("dht/auth_test.zig");
    _ = @import("cluster/transfer_test.zig");
    _ = @import("cluster/revocation_test.zig");
    _ = @import("cluster/share_test.zig");
    _ = @import("cluster/swarm_test.zig");
    _ = @import("cluster/rotation_test.zig");
    _ = @import("cluster/swarm_backup_test.zig");
    _ = @import("cluster/readahead_test.zig");
}
