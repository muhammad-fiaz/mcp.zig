//! MCP Sampling Module (Spec 2026-07-28, deprecated but functional)
//!
//! Provides types and utilities for LLM sampling requests. Sampling allows
//! servers to request language model completions from the client, enabling
//! AI-powered workflows while keeping the model under client control.
//! Supports tool use via tools and toolChoice parameters.

const std = @import("std");
const types = @import("../protocol/types.zig");

/// Request from server to client for an LLM completion.
pub const SamplingRequest = struct {
    messages: []const types.SamplingMessage,
    modelPreferences: ?types.ModelPreferences = null,
    systemPrompt: ?[]const u8 = null,
    includeContext: ?[]const u8 = null,
    temperature: ?f64 = null,
    maxTokens: u32,
    stopSequences: ?[]const []const u8 = null,
    metadata: ?std.json.Value = null,
    tools: ?[]const types.ToolDefinition = null,
    toolChoice: ?types.ToolChoice = null,
    task: ?types.TaskMetadata = null,
    _meta: ?std.json.Value = null,
};

/// Response containing the LLM completion.
///
/// `content` is either a single block (one content item) or an array, which
/// is the shape used when the model returns several tool uses.
pub const SamplingResponse = struct {
    role: types.Role,
    content: types.SamplingContent,
    model: []const u8,
    stopReason: ?[]const u8 = null,
    _meta: ?std.json.Value = null,
};

/// Stop reasons defined by the spec. Implementations may return their own
/// additional values, so this is not an exhaustive enumeration.
pub const StopReason = enum {
    endTurn,
    stopSequence,
    maxTokens,
    /// The model wants to use one or more tools.
    toolUse,

    pub fn toString(self: StopReason) []const u8 {
        return @tagName(self);
    }
};

/// Handler function type for processing sampling requests.
pub const SamplingHandler = *const fn (
    allocator: std.mem.Allocator,
    request: SamplingRequest,
) SamplingError!SamplingResponse;

/// Errors that can occur during sampling.
pub const SamplingError = error{
    RequestDenied,
    ModelUnavailable,
    TokenLimitExceeded,
    Timeout,
    OutOfMemory,
    Unknown,
};

/// Builds a sampling request with messages and token limit.
pub fn buildRequest(messages: []const types.SamplingMessage, maxTokens: u32) SamplingRequest {
    return .{ .messages = messages, .maxTokens = maxTokens };
}

/// Creates a text message for use in sampling requests.
pub fn textMessage(role: types.Role, text: []const u8) types.SamplingMessage {
    return .{ .role = role, .content = types.SamplingContent.one(.{ .text = .{ .text = text } }) };
}

/// Creates a user text message for sampling.
pub fn userMessage(text: []const u8) types.SamplingMessage {
    return textMessage(.user, text);
}

/// Creates an assistant text message for sampling.
pub fn assistantMessage(text: []const u8) types.SamplingMessage {
    return textMessage(.assistant, text);
}

test "buildRequest" {
    const msgs = &[_]types.SamplingMessage{textMessage(.user, "Hello")};
    const req = buildRequest(msgs, 100);
    try std.testing.expectEqual(@as(u32, 100), req.maxTokens);
}

test "userMessage" {
    const msg = userMessage("Hello");
    try std.testing.expectEqual(types.Role.user, msg.role);
}

test "assistantMessage" {
    const msg = assistantMessage("Hi");
    try std.testing.expectEqual(types.Role.assistant, msg.role);
}

test "SamplingContent carries a single block or an array" {
    const one = types.SamplingContent.one(.{ .text = .{ .text = "hi" } });
    try std.testing.expectEqual(@as(usize, 1), one.count());
    try std.testing.expect(one.get(1) == null);

    const blocks = [_]types.SamplingMessageContentBlock{
        .{ .tool_use = .{ .id = "call_1", .name = "get_weather", .input = .{ .null = {} } } },
        .{ .tool_use = .{ .id = "call_2", .name = "get_weather", .input = .{ .null = {} } } },
    };
    const many = types.SamplingContent.list(&blocks);
    try std.testing.expectEqual(@as(usize, 2), many.count());
    try std.testing.expect(types.hasToolUse(many));
}

test "a tool result message must contain only tool results" {
    const only = [_]types.SamplingMessageContentBlock{
        .{ .tool_result = .{ .toolUseId = "call_1", .content = &.{} } },
    };
    try std.testing.expect(types.isToolResultOnly(types.SamplingContent.list(&only)));

    const mixed = [_]types.SamplingMessageContentBlock{
        .{ .text = .{ .text = "Here are the results:" } },
        .{ .tool_result = .{ .toolUseId = "call_1", .content = &.{} } },
    };
    try std.testing.expect(!types.isToolResultOnly(types.SamplingContent.list(&mixed)));

    const msg = types.SamplingMessage{ .role = .user, .content = types.SamplingContent.list(&mixed) };
    try std.testing.expectError(
        error.ToolResultMessageMixedContent,
        types.validateSamplingMessages(&.{msg}),
    );
}

test "parallel tool uses must be answered by matching tool results" {
    const uses = [_]types.SamplingMessageContentBlock{
        .{ .tool_use = .{ .id = "call_1", .name = "get_weather", .input = .{ .null = {} } } },
        .{ .tool_use = .{ .id = "call_2", .name = "get_weather", .input = .{ .null = {} } } },
    };
    const assistant = types.SamplingMessage{
        .role = .assistant,
        .content = types.SamplingContent.list(&uses),
    };

    const partial = [_]types.SamplingMessageContentBlock{
        .{ .tool_result = .{ .toolUseId = "call_1", .content = &.{} } },
    };
    const partial_msg = types.SamplingMessage{
        .role = .user,
        .content = types.SamplingContent.list(&partial),
    };
    // call_2 is never resolved.
    try std.testing.expectError(
        error.UnmatchedToolUse,
        types.validateSamplingMessages(&.{ assistant, partial_msg }),
    );

    const full = [_]types.SamplingMessageContentBlock{
        .{ .tool_result = .{ .toolUseId = "call_1", .content = &.{} } },
        .{ .tool_result = .{ .toolUseId = "call_2", .content = &.{} } },
    };
    const full_msg = types.SamplingMessage{
        .role = .user,
        .content = types.SamplingContent.list(&full),
    };
    const final = assistantMessage("Paris is warmer than London.");
    try types.validateSamplingMessages(&.{ assistant, full_msg, final });
}

test "a tool result with no matching tool use is rejected" {
    const orphan = [_]types.SamplingMessageContentBlock{
        .{ .tool_result = .{ .toolUseId = "call_missing", .content = &.{} } },
    };
    const msg = types.SamplingMessage{ .role = .user, .content = types.SamplingContent.list(&orphan) };
    try std.testing.expectError(
        error.UnmatchedToolResult,
        types.validateSamplingMessages(&.{msg}),
    );
}

test "ToolChoice modes use the spec's three values" {
    try std.testing.expectEqualStrings("auto", types.ToolChoiceMode.auto.toString());
    try std.testing.expectEqualStrings("required", types.ToolChoiceMode.required.toString());
    try std.testing.expectEqualStrings("none", types.ToolChoiceMode.none.toString());

    const choice: types.ToolChoice = .{ .mode = .none };
    try std.testing.expectEqual(types.ToolChoiceMode.none, choice.mode.?);
}

test "stop reasons cover the spec values" {
    try std.testing.expectEqualStrings("endTurn", StopReason.endTurn.toString());
    try std.testing.expectEqualStrings("stopSequence", StopReason.stopSequence.toString());
    try std.testing.expectEqualStrings("maxTokens", StopReason.maxTokens.toString());
    try std.testing.expectEqualStrings("toolUse", StopReason.toolUse.toString());
}
