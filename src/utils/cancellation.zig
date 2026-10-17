//! Cooperative Cancellation Token
//!
//! Provides a thread-safe, atomic cancellation token for cooperative cancellation
//! of long-running tools, tasks, and request operations.

const std = @import("std");

/// Thread-safe cooperative cancellation token.
pub const CancellationToken = struct {
    cancelled: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    /// Initializes a new, uncancelled token.
    pub fn init() CancellationToken {
        return .{
            .cancelled = std.atomic.Value(bool).init(false),
        };
    }

    /// Sets the token to cancelled state.
    pub fn cancel(self: *CancellationToken) void {
        self.cancelled.store(true, .release);
    }

    /// Returns true if cancellation was requested.
    pub fn isCancelled(self: *const CancellationToken) bool {
        return self.cancelled.load(.acquire);
    }

    /// Resets the token back to uncancelled state.
    pub fn reset(self: *CancellationToken) void {
        self.cancelled.store(false, .release);
    }

    /// Returns `error.Cancelled` if cancellation has been requested.
    pub fn check(self: *const CancellationToken) error{Cancelled}!void {
        if (self.isCancelled()) {
            return error.Cancelled;
        }
    }
};

test "CancellationToken lifecycle" {
    var token = CancellationToken.init();
    try std.testing.expect(!token.isCancelled());
    try token.check();

    token.cancel();
    try std.testing.expect(token.isCancelled());
    try std.testing.expectError(error.Cancelled, token.check());

    token.reset();
    try std.testing.expect(!token.isCancelled());
    try token.check();
}
