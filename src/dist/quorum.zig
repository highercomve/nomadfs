const std = @import("std");

pub const QuorumConfig = struct {
    N: u8 = 3, // Replication Factor
    W: u8 = 1, // Write Quorum
    R: u8 = 1, // Read Quorum
};

pub fn isWriteSatisfied(config: QuorumConfig, successful_writes: u8) bool {
    return successful_writes >= config.W;
}

pub fn isReadSatisfied(config: QuorumConfig, successful_reads: u8) bool {
    return successful_reads >= config.R;
}
