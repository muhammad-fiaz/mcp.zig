//! MCP Progress Module
//!
//! Provides progress tracking for long-running operations. Enables servers
//! to report progress to clients with optional total counts and messages.

const std = @import("std");

/// Token identifying a progress-tracked operation. Can be string or integer.
pub const ProgressToken = union(enum) {
    string: []const u8,
    integer: i64,
};

/// Progress notification data sent to clients.
pub const Progress = struct {
    token: ProgressToken,
    progress: f64,
    total: ?f64 = null,
    message: ?[]const u8 = null,
};

/// Tracks progress for a single long-running operation.
pub const Tracker = struct {
    token: ProgressToken,
    current: f64 = 0,
    total: ?f64 = null,
    callback: ?*const fn (Progress) void = null,

    /// Creates a new progress tracker with the given token and optional total.
    pub fn init(token: ProgressToken, total: ?f64) Tracker {
        return .{ .token = token, .total = total };
    }

    /// Updates the current progress value and optionally sends a message.
    pub fn update(self: *Tracker, progress: f64, message: ?[]const u8) void {
        self.current = progress;
        if (self.callback) |cb| {
            cb(.{
                .token = self.token,
                .progress = progress,
                .total = self.total,
                .message = message,
            });
        }
    }

    /// Increments the current progress by the given amount.
    pub fn increment(self: *Tracker, amount: f64) void {
        self.update(self.current + amount, null);
    }

    /// Marks the operation as complete by setting progress to total.
    pub fn complete(self: *Tracker) void {
        if (self.total) |t| {
            self.update(t, null);
        }
    }

    /// Returns the current progress as a percentage (0-100), or null if no total.
    pub fn percentage(self: *Tracker) ?f64 {
        if (self.total) |t| {
            if (t > 0) return (self.current / t) * 100.0;
        }
        return null;
    }
};

/// Creates a new random progress token.
pub fn createToken(allocator: std.mem.Allocator) !ProgressToken {
    var buf: [16]u8 = undefined;
    std.crypto.random.bytes(&buf);
    const hex = try std.fmt.allocPrint(allocator, "{s}", .{std.fmt.fmtSliceHexLower(&buf)});
    return .{ .string = hex };
}

test "Tracker" {
    var tracker: Tracker = .init(.{ .integer = 1 }, 100);
    try std.testing.expectEqual(@as(f64, 0), tracker.current);

    tracker.update(50, null);
    try std.testing.expectApproxEqAbs(@as(f64, 50), tracker.percentage().?, 0.001);
}
