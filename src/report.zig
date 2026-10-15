//! Error Reporting
//!
//! Prints actionable error messages for applications built on this library.
//!
//! This module deliberately performs no network access. An earlier version
//! included an update checker that spawned a thread performing an outbound
//! HTTPS request on every `Client.init`, which `Client.deinit` then had to
//! join: that added tens of seconds to normal program shutdown and could hang
//! indefinitely when the network was unavailable. The checker has been removed.

const std = @import("std");

pub const ISSUES_URL = "https://github.com/muhammad-fiaz/mcp.zig/issues";

/// Prints the message plus the shared "this may be a bug" hint.
///
/// Both public helpers funnel through here so the hint text lives in exactly
/// one place.
fn reportDetail(comptime fmt: []const u8, args: anytype) void {
    std.debug.print("\n[MCP ERROR] " ++ fmt ++ "\n", args);
    std.debug.print("\nIf you believe this is a bug in mcp.zig, please report it at:\n  {s}\n\n", .{ISSUES_URL});
}

/// Prints an error message with instructions for reporting bugs.
pub fn reportError(err: anyerror) void {
    reportDetail("{}", .{err});
}

/// Prints a custom error message with instructions for reporting bugs.
pub fn reportErrorMessage(message: []const u8) void {
    reportDetail("{s}", .{message});
}
