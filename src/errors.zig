pub const NomadError = error{
    // Configuration errors
    InvalidSwarmKey,
    InvalidConfig,

    // Network errors
    ConnectionRefused,
    HandshakeFailed,
    CircuitBreakerOpen,
    Timeout,
    ConnectionResetByPeer,
    NetworkUnreachable,
    OperationTimedOut,

    // Storage errors
    BlockNotFound,
    InvalidCid,
    StorageFull,

    // Consensus errors
    ConflictDetected,
    QuorumNotReached,

    // DHT errors
    PeerUnreachable,
    LookupFailed,

    // General errors
    NotImplemented,
    OutOfMemory,
};

/// Determine if an error is retriable.
/// Retriable errors are transient failures that may resolve on retry.
pub fn isRetriableError(err: anyerror) bool {
    return switch (err) {
        NomadError.ConnectionRefused, NomadError.ConnectionResetByPeer, NomadError.Timeout, NomadError.NetworkUnreachable, NomadError.OperationTimedOut => true,
        else => false,
    };
}

/// Determine if an error is fatal.
/// Fatal errors cannot be recovered from and should cause immediate termination.
pub fn isFatalError(err: anyerror) bool {
    return switch (err) {
        NomadError.InvalidSwarmKey, NomadError.InvalidConfig, NomadError.InvalidCid, NomadError.QuorumNotReached => true,
        else => false,
    };
}

/// Categorize an error for logging and error handling.
pub const ErrorCategory = enum {
    /// Transient network or system issues (should retry)
    Transient,
    /// Fatal configuration or validation issues (cannot recover)
    Fatal,
    /// Expected operational states (not an error)
    Expected,
};

pub fn categorizeError(err: anyerror) ErrorCategory {
    return switch (err) {
        // Transient network issues
        NomadError.ConnectionRefused, NomadError.ConnectionResetByPeer, NomadError.Timeout, NomadError.NetworkUnreachable, NomadError.OperationTimedOut, NomadError.CircuitBreakerOpen => .Transient,

        // Fatal configuration/validation issues
        NomadError.InvalidSwarmKey, NomadError.InvalidConfig, NomadError.InvalidCid, NomadError.QuorumNotReached => .Fatal,

        // Storage/consensus issues - treat as fatal
        NomadError.BlockNotFound, NomadError.StorageFull, NomadError.ConflictDetected => .Fatal,

        // Implementation issues - treat as fatal
        NomadError.NotImplemented, NomadError.PeerUnreachable, NomadError.LookupFailed => .Fatal,

        // Out of memory - fatal (but could also be transient in some cases)
        NomadError.OutOfMemory => .Fatal,

        // Unknown errors - treat as transient (should retry)
        else => .Transient,
    };
}
