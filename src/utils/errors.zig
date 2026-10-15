//! MCP Error Utilities
//!
//! Provides error types, error codes, and helper functions for creating
//! JSON-RPC and MCP-specific error responses.

const std = @import("std");
const report = @import("../report.zig");

/// Structured MCP error with code, message, and optional data.
pub const McpError = struct {
    code: ErrorCode,
    message: []const u8,
    data: ?std.json.Value = null,

    pub fn format(self: McpError, comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
        try writer.print("McpError({d}): {s}", .{ @backingInt(self.code), self.message });
        if (self.code == .internal_error) {
            try writer.print("\nThis might be a bug. Please report it at: {s}", .{report.ISSUES_URL});
        }
    }
};

/// Standard JSON-RPC 2.0 error codes with MCP-specific extensions.
///
/// `-32020..-32099` is reserved for the MCP specification. The `-32002`
/// and `-32042` codes come from earlier revisions and MUST NOT be emitted by
/// a 2026-07-28 implementation; they are kept only so callers can recognise
/// them from older peers.
pub const ErrorCode = enum(i32) {
    parse_error = -32700,
    invalid_request = -32600,
    method_not_found = -32601,
    invalid_params = -32602,
    internal_error = -32603,

    /// HTTP headers do not match the request body, or required headers are
    /// missing/malformed.
    header_mismatch = -32020,
    /// Processing requires a client capability that was not declared.
    missing_required_client_capability = -32021,
    /// The requested protocol version is not supported by this server.
    unsupported_protocol_version = -32022,

    request_cancelled = -32800,
    content_too_large = -32801,

    /// Deprecated: user rejected an interaction. Not a JSON-RPC code.
    user_rejected = -1,

    /// Returns the integer value of this error code.
    pub fn toInt(self: ErrorCode) i32 {
        return @backingInt(self);
    }

    /// Returns the standard message for this error code.
    pub fn message(self: ErrorCode) []const u8 {
        return switch (self) {
            .parse_error => "Parse error",
            .invalid_request => "Invalid request",
            .method_not_found => "Method not found",
            .invalid_params => "Invalid params",
            .internal_error => "Internal error",
            .header_mismatch => "Header mismatch",
            .missing_required_client_capability => "Missing required client capability",
            .unsupported_protocol_version => "Unsupported protocol version",
            .request_cancelled => "Request cancelled",
            .content_too_large => "Content too large",
            .user_rejected => "User rejected",
        };
    }
};

/// Creates an error with the given code and optional message.
pub fn create(code: ErrorCode, msg: ?[]const u8) McpError {
    return .{ .code = code, .message = msg orelse code.message() };
}

/// Creates a parse error (-32700).
pub fn parseError(msg: ?[]const u8) McpError {
    return create(.parse_error, msg);
}

/// Creates an invalid request error (-32600).
pub fn invalidRequest(msg: ?[]const u8) McpError {
    return create(.invalid_request, msg);
}

/// Creates a method not found error (-32601).
pub fn methodNotFound(method: []const u8) McpError {
    _ = method;
    return create(.method_not_found, null);
}

/// Creates an invalid params error (-32602).
pub fn invalidParams(msg: ?[]const u8) McpError {
    return create(.invalid_params, msg);
}

/// Creates an internal error (-32603).
pub fn internalError(msg: ?[]const u8) McpError {
    return create(.internal_error, msg);
}

test "ErrorCode" {
    try std.testing.expectEqual(@as(i32, -32700), ErrorCode.parse_error.toInt());
    try std.testing.expectEqualStrings("Parse error", ErrorCode.parse_error.message());
}

test "create error" {
    const err = parseError(null);
    try std.testing.expectEqual(ErrorCode.parse_error, err.code);
}
