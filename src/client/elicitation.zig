//! MCP Elicitation Module (Spec 2025-11-25)
//!
//! Provides types and utilities for server-initiated elicitation requests.
//! Elicitation allows servers to request structured information from users
//! through the client, enabling interactive workflows.
//! Supports both form-based and URL-based elicitation modes.

const std = @import("std");
const types = @import("../protocol/types.zig");

/// Request from server to elicit information from the user (form mode).
pub const ElicitationFormRequest = struct {
    message: []const u8,
    requestedSchema: std.json.Value,
    mode: ?[]const u8 = null,
    task: ?types.TaskMetadata = null,
    _meta: ?std.json.Value = null,
};

/// Request from server to elicit information via URL.
pub const ElicitationUrlRequest = struct {
    message: []const u8,
    elicitationId: []const u8,
    url: []const u8,
    mode: []const u8 = "url",
    task: ?types.TaskMetadata = null,
    _meta: ?std.json.Value = null,
};

/// Generic elicitation request supporting both modes.
pub const ElicitationRequest = union(enum) {
    form: ElicitationFormRequest,
    url: ElicitationUrlRequest,
};

/// Response to an elicitation request.
pub const ElicitationResponse = struct {
    action: Action,
    content: ?std.json.Value = null,
    _meta: ?std.json.Value = null,

    pub const Action = enum {
        accept,
        decline,
        cancel,

        pub fn toString(self: Action) []const u8 {
            return @tagName(self);
        }
    };
};

/// Handler function type for processing elicitation requests.
pub const ElicitationHandler = *const fn (
    allocator: std.mem.Allocator,
    request: ElicitationRequest,
) ElicitationError!ElicitationResponse;

/// Errors that can occur during elicitation.
pub const ElicitationError = error{
    UserCancelled,
    Timeout,
    InvalidSchema,
    OutOfMemory,
    Unknown,
};

/// Creates an accept response with the given content.
pub fn accept(content: std.json.Value) ElicitationResponse {
    return .{ .action = .accept, .content = content };
}

/// Creates a decline response indicating the user refused.
pub fn decline() ElicitationResponse {
    return .{ .action = .decline };
}

/// Creates a cancel response indicating the operation was cancelled.
pub fn cancel() ElicitationResponse {
    return .{ .action = .cancel };
}

/// Builds a form elicitation request.
pub fn formRequest(message: []const u8, schema: std.json.Value) ElicitationRequest {
    return .{ .form = .{ .message = message, .requestedSchema = schema } };
}

/// Builds a URL elicitation request.
pub fn urlRequest(message: []const u8, elicitation_id: []const u8, url: []const u8) ElicitationRequest {
    return .{ .url = .{ .message = message, .elicitationId = elicitation_id, .url = url } };
}

test "accept response" {
    const resp = accept(.{ .string = "test" });
    try std.testing.expectEqual(ElicitationResponse.Action.accept, resp.action);
}

test "decline response" {
    const resp = decline();
    try std.testing.expectEqual(ElicitationResponse.Action.decline, resp.action);
}

test "cancel response" {
    const resp = cancel();
    try std.testing.expectEqual(ElicitationResponse.Action.cancel, resp.action);
}

test "Action toString" {
    try std.testing.expectEqualStrings("accept", ElicitationResponse.Action.accept.toString());
    try std.testing.expectEqualStrings("decline", ElicitationResponse.Action.decline.toString());
}
