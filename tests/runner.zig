test {
    _ = @import("network/integration.zig");
    _ = @import("network/security_test.zig");
    _ = @import("network/manager_test.zig");
    _ = @import("network/yamux_test.zig");
    _ = @import("network/yamux_flow_control_test.zig");
    _ = @import("dht/lookup_test.zig");
    _ = @import("dht/rpc_test.zig");
    _ = @import("dht/ping_test.zig");
    _ = @import("dht/store_test.zig");
    _ = @import("dht/discovery_test.zig");
    _ = @import("dht/churn_test.zig");
    _ = @import("dht/kbucket_standard_test.zig");
}
