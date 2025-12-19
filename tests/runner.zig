test {
    _ = @import("network/integration.zig");
    _ = @import("network/security_test.zig");
    _ = @import("network/yamux_test.zig");
    _ = @import("dht/lookup_test.zig");
    _ = @import("dht/rpc_test.zig");
    _ = @import("dht/ping_test.zig");
    _ = @import("dht/store_test.zig");
}
