//! MCP Protocol Layer (Spec 2025-11-25)
//!
//! Defines core MCP protocol structures, message types, and method constants.
//! Built on JSON-RPC 2.0, this module provides the foundation for MCP communication
//! including initialization, capability negotiation, tasks, and all standard MCP methods.

const std = @import("std");
const jsonrpc = @import("jsonrpc.zig");
const types = @import("types.zig");

pub const JsonRpc = jsonrpc;
pub const Types = types;

/// Current MCP protocol version supported by this library.
pub const PROTOCOL_VERSION = "2025-11-25";

/// Legacy alias for compatibility.
pub const VERSION = PROTOCOL_VERSION;

/// List of all MCP protocol versions this library can communicate with.
pub const SUPPORTED_VERSIONS = [_][]const u8{
    "2025-11-25",
    "2025-06-18",
    "2025-03-26",
    "2024-11-05",
};

/// JSON-RPC version used by MCP.
pub const JSONRPC_VERSION = "2.0";

/// All MCP method names as defined in the protocol specification.
pub const Method = enum {
    // Lifecycle
    initialize,
    @"notifications/initialized",
    ping,

    // Tools
    @"tools/list",
    @"tools/call",
    @"notifications/tools/list_changed",

    // Resources
    @"resources/list",
    @"resources/read",
    @"resources/subscribe",
    @"resources/unsubscribe",
    @"resources/templates/list",
    @"notifications/resources/list_changed",
    @"notifications/resources/updated",

    // Prompts
    @"prompts/list",
    @"prompts/get",
    @"notifications/prompts/list_changed",

    // Logging
    @"logging/setLevel",
    @"notifications/message",

    // Sampling
    @"sampling/createMessage",

    // Elicitation
    @"elicitation/create",
    @"notifications/elicitation/complete",

    // Roots
    @"roots/list",
    @"notifications/roots/list_changed",

    // Completion
    @"completion/complete",

    // Progress & Cancellation
    @"notifications/progress",
    @"notifications/cancelled",

    // Tasks
    @"tasks/get",
    @"tasks/result",
    @"tasks/list",
    @"tasks/cancel",
    @"notifications/tasks/status",

    /// Returns the string representation of the method name.
    pub fn toString(self: Method) []const u8 {
        return @tagName(self);
    }

    /// Parses a method name string into the corresponding enum value.
    pub fn fromString(str: []const u8) ?Method {
        inline for (std.meta.fields(Method)) |field| {
            if (std.mem.eql(u8, field.name, str)) {
                return @enumFromInt(field.value);
            }
        }
        return null;
    }
};


/// Parameters for the initialize request.
pub const InitializeParams = struct {
    _meta: ?std.json.Value = null,
    protocolVersion: []const u8,
    capabilities: types.ClientCapabilities,
    clientInfo: types.Implementation,
};

/// Result of a successful initialize request.
pub const InitializeResult = struct {
    _meta: ?std.json.Value = null,
    protocolVersion: []const u8,
    capabilities: types.ServerCapabilities,
    serverInfo: types.Implementation,
    instructions: ?[]const u8 = null,
};


/// Result of listing available tools.
pub const ToolsListResult = struct {
    _meta: ?std.json.Value = null,
    nextCursor: ?[]const u8 = null,
    tools: []const types.ToolDefinition,
};

/// Parameters for calling a tool.
pub const ToolCallParams = struct {
    task: ?types.TaskMetadata = null,
    _meta: ?std.json.Value = null,
    name: []const u8,
    arguments: ?std.json.Value = null,
};

/// Result of a tool call.
pub const ToolCallResult = struct {
    _meta: ?std.json.Value = null,
    content: []const types.ContentBlock,
    structuredContent: ?std.json.Value = null,
    isError: ?bool = null,
};


/// Result of listing available resources.
pub const ResourcesListResult = struct {
    _meta: ?std.json.Value = null,
    nextCursor: ?[]const u8 = null,
    resources: []const types.ResourceDefinition,
};

/// Parameters for reading a resource.
pub const ResourcesReadParams = struct {
    _meta: ?std.json.Value = null,
    uri: []const u8,
};

/// Result of reading a resource.
pub const ResourcesReadResult = struct {
    _meta: ?std.json.Value = null,
    contents: []const types.ResourceContent,
};

/// Result of listing resource templates.
pub const ResourceTemplatesListResult = struct {
    _meta: ?std.json.Value = null,
    nextCursor: ?[]const u8 = null,
    resourceTemplates: []const types.ResourceTemplate,
};

/// Parameters for subscribing to a resource.
pub const SubscribeParams = struct {
    _meta: ?std.json.Value = null,
    uri: []const u8,
};

/// Parameters for unsubscribing from a resource.
pub const UnsubscribeParams = struct {
    _meta: ?std.json.Value = null,
    uri: []const u8,
};

/// Parameters for resource updated notification.
pub const ResourceUpdatedParams = struct {
    _meta: ?std.json.Value = null,
    uri: []const u8,
};


/// Result of listing available prompts.
pub const PromptsListResult = struct {
    _meta: ?std.json.Value = null,
    nextCursor: ?[]const u8 = null,
    prompts: []const types.PromptDefinition,
};

/// Parameters for fetching a prompt.
pub const PromptsGetParams = struct {
    _meta: ?std.json.Value = null,
    name: []const u8,
    arguments: ?std.json.Value = null,
};

/// Result of fetching a prompt.
pub const PromptsGetResult = struct {
    _meta: ?std.json.Value = null,
    description: ?[]const u8 = null,
    messages: []const types.PromptMessage,
};


/// Parameters for creating a sampling message (LLM completion request).
pub const SamplingCreateMessageParams = struct {
    task: ?types.TaskMetadata = null,
    _meta: ?std.json.Value = null,
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
};

/// Result of a sampling message request.
pub const SamplingCreateMessageResult = struct {
    _meta: ?std.json.Value = null,
    model: []const u8,
    stopReason: ?[]const u8 = null,
    role: types.Role,
    content: types.SamplingMessageContentBlock,
};


/// Parameters for creating an elicitation request (form mode).
pub const ElicitationFormParams = struct {
    task: ?types.TaskMetadata = null,
    _meta: ?std.json.Value = null,
    mode: ?[]const u8 = null,
    message: []const u8,
    requestedSchema: std.json.Value,
};

/// Parameters for creating an elicitation request (URL mode).
pub const ElicitationUrlParams = struct {
    task: ?types.TaskMetadata = null,
    _meta: ?std.json.Value = null,
    mode: []const u8 = "url",
    message: []const u8,
    elicitationId: []const u8,
    url: []const u8,
};

/// Generic elicitation params (union of form and URL modes).
pub const ElicitationCreateParams = union(enum) {
    form: ElicitationFormParams,
    url: ElicitationUrlParams,
};

/// Result of an elicitation request.
pub const ElicitationCreateResult = struct {
    _meta: ?std.json.Value = null,
    action: []const u8,
    content: ?std.json.Value = null,
};


/// Log severity levels following syslog conventions.
pub const LogLevel = types.LoggingLevel;

/// Parameters for setting the log level.
pub const SetLogLevelParams = struct {
    _meta: ?std.json.Value = null,
    level: []const u8,
};

/// Log message notification payload.
pub const LogMessageNotification = struct {
    _meta: ?std.json.Value = null,
    level: []const u8,
    logger: ?[]const u8 = null,
    data: std.json.Value,
};


/// Progress notification payload for long-running operations.
pub const ProgressNotification = struct {
    _meta: ?std.json.Value = null,
    progressToken: types.ProgressToken,
    progress: f64,
    total: ?f64 = null,
    message: ?[]const u8 = null,
};

/// Cancellation notification payload.
pub const CancelledNotification = struct {
    _meta: ?std.json.Value = null,
    /// The ID of the request to cancel (optional; must not be used for task cancellation).
    requestId: ?types.RequestId = null,
    reason: ?[]const u8 = null,
};


/// Result of listing filesystem roots.
pub const RootsListResult = struct {
    _meta: ?std.json.Value = null,
    roots: []const types.Root,
};


/// Parameters for argument completion.
pub const CompletionCompleteParams = struct {
    _meta: ?std.json.Value = null,
    ref: types.CompletionRef,
    argument: types.CompletionArgument,
    context: ?struct {
        arguments: ?std.json.Value = null,
    } = null,
};

/// Result of argument completion.
pub const CompletionCompleteResult = struct {
    _meta: ?std.json.Value = null,
    completion: types.CompletionResult,
};


/// Parameters for tasks/get request.
pub const GetTaskParams = struct {
    taskId: []const u8,
};

/// Result of tasks/get — returns Result fields merged with Task fields.
pub const GetTaskResult = struct {
    _meta: ?std.json.Value = null,
    taskId: []const u8,
    status: types.TaskStatus,
    statusMessage: ?[]const u8 = null,
    createdAt: []const u8,
    lastUpdatedAt: []const u8,
    ttl: ?i64 = null,
    pollInterval: ?i64 = null,
};

/// Parameters for tasks/result request.
pub const GetTaskPayloadParams = struct {
    taskId: []const u8,
};

/// Result of tasks/result — structure matches the result type of the original request.
pub const GetTaskPayloadResult = struct {
    _meta: ?std.json.Value = null,
};

/// Parameters for tasks/list request (paginated).
pub const ListTasksParams = struct {
    cursor: ?types.Cursor = null,
};

/// Result of tasks/list.
pub const ListTasksResult = struct {
    _meta: ?std.json.Value = null,
    nextCursor: ?[]const u8 = null,
    tasks: []const types.Task,
};

/// Parameters for tasks/cancel request.
pub const CancelTaskParams = struct {
    taskId: []const u8,
};

/// Result of tasks/cancel — returns Result fields merged with Task fields.
pub const CancelTaskResult = GetTaskResult;

/// Parameters for notifications/tasks/status notification.
pub const TaskStatusNotificationParams = struct {
    _meta: ?std.json.Value = null,
    taskId: []const u8,
    status: types.TaskStatus,
    statusMessage: ?[]const u8 = null,
    createdAt: []const u8,
    lastUpdatedAt: []const u8,
    ttl: ?i64 = null,
    pollInterval: ?i64 = null,
};

/// Parameters for notifications/elicitation/complete notification.
pub const ElicitationCompleteParams = struct {
    elicitationId: []const u8,
};


/// Builds an initialize request message.
pub fn buildInitializeRequest(
    id: types.RequestId,
    params: InitializeParams,
) jsonrpc.Request {
    return jsonrpc.Request{
        .id = id,
        .method = Method.initialize.toString(),
        .params = serializeParams(params),
    };
}

/// Builds an initialize response message.
pub fn buildInitializeResponse(
    id: types.RequestId,
    result: InitializeResult,
) jsonrpc.Response {
    return jsonrpc.Response{
        .id = id,
        .result = serializeResult(result),
    };
}

/// Builds a tools/list request message.
pub fn buildToolsListRequest(id: types.RequestId) jsonrpc.Request {
    return jsonrpc.Request{
        .id = id,
        .method = Method.@"tools/list".toString(),
        .params = null,
    };
}

/// Builds a tools/call request message.
pub fn buildToolCallRequest(
    id: types.RequestId,
    params: ToolCallParams,
) jsonrpc.Request {
    return jsonrpc.Request{
        .id = id,
        .method = Method.@"tools/call".toString(),
        .params = serializeParams(params),
    };
}

fn serializeParams(value: anytype) ?std.json.Value {
    _ = value;
    return null;
}

fn serializeResult(value: anytype) ?std.json.Value {
    _ = value;
    return null;
}


test "Method enum" {
    try std.testing.expectEqualStrings("initialize", Method.initialize.toString());
    try std.testing.expectEqualStrings("tools/list", Method.@"tools/list".toString());
}

test "Method enum - new task methods" {
    try std.testing.expectEqualStrings("tasks/get", Method.@"tasks/get".toString());
    try std.testing.expectEqualStrings("tasks/result", Method.@"tasks/result".toString());
    try std.testing.expectEqualStrings("tasks/list", Method.@"tasks/list".toString());
    try std.testing.expectEqualStrings("tasks/cancel", Method.@"tasks/cancel".toString());
    try std.testing.expectEqualStrings("notifications/tasks/status", Method.@"notifications/tasks/status".toString());
}

test "Method enum - elicitation complete" {
    try std.testing.expectEqualStrings("notifications/elicitation/complete", Method.@"notifications/elicitation/complete".toString());
}

test "LogLevel enum" {
    try std.testing.expectEqualStrings("debug", LogLevel.debug.toString());
    try std.testing.expectEqualStrings("error", LogLevel.@"error".toString());
}
