//! MCP Type Definitions (Spec 2025-11-25)
//!
//! Contains all type definitions used throughout the MCP protocol including
//! capability structures, tool definitions, resources, prompts, content types,
//! tasks, sampling, and other protocol primitives.

const std = @import("std");

/// Request ID can be a string or integer, used to match responses to requests.
pub const RequestId = union(enum) {
    string: []const u8,
    integer: i64,

    pub fn format(
        self: RequestId,
        comptime _: []const u8,
        _: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        switch (self) {
            .string => |s| try writer.print("\"{s}\"", .{s}),
            .integer => |i| try writer.print("{d}", .{i}),
        }
    }

    /// Compares two request IDs for equality.
    pub fn eql(self: RequestId, other: RequestId) bool {
        return switch (self) {
            .string => |s| switch (other) {
                .string => |os| std.mem.eql(u8, s, os),
                .integer => false,
            },
            .integer => |i| switch (other) {
                .string => false,
                .integer => |oi| i == oi,
            },
        };
    }
};

/// Token for tracking progress of long-running operations.
pub const ProgressToken = union(enum) {
    string: []const u8,
    integer: i64,
};

/// An opaque token used to represent a cursor for pagination.
pub const Cursor = []const u8;

/// The sender or recipient of messages and data in a conversation.
pub const Role = enum {
    user,
    assistant,

    pub fn toString(self: Role) []const u8 {
        return @tagName(self);
    }

    pub fn fromString(str: []const u8) ?Role {
        if (std.mem.eql(u8, str, "user")) return .user;
        if (std.mem.eql(u8, str, "assistant")) return .assistant;
        return null;
    }
};

/// Log severity levels following syslog conventions (RFC 5424).
pub const LoggingLevel = enum {
    debug,
    info,
    notice,
    warning,
    @"error",
    critical,
    alert,
    emergency,

    pub fn toString(self: LoggingLevel) []const u8 {
        return @tagName(self);
    }
};

/// Optional annotations for the client. The client can use annotations to
/// inform how objects are used or displayed.
pub const Annotations = struct {
    /// Describes who the intended audience of this object or data is.
    audience: ?[]const Role = null,
    /// Describes how important this data is (1 = most important, 0 = least).
    priority: ?f64 = null,
    /// The moment the resource was last modified (ISO 8601 formatted string).
    lastModified: ?[]const u8 = null,
};

/// An optionally-sized icon that can be displayed in a user interface.
pub const Icon = struct {
    /// A standard URI pointing to an icon resource.
    src: []const u8,
    /// Optional MIME type override (e.g. "image/png", "image/svg+xml").
    mimeType: ?[]const u8 = null,
    /// Optional sizes in WxH format (e.g. "48x48") or "any".
    sizes: ?[]const []const u8 = null,
    /// Optional theme specifier for the icon.
    theme: ?IconTheme = null,

    pub const IconTheme = enum { light, dark };
};

/// Describes the MCP implementation (client or server).
pub const Implementation = struct {
    /// Intended for programmatic or logical use.
    name: []const u8,
    /// Version string.
    version: []const u8,
    /// Intended for UI and end-user contexts.
    title: ?[]const u8 = null,
    /// An optional human-readable description.
    description: ?[]const u8 = null,
    /// Optional set of sized icons.
    icons: ?[]const Icon = null,
    /// An optional URL of the website for this implementation.
    websiteUrl: ?[]const u8 = null,
};

/// Server capabilities advertised during initialization.
pub const ServerCapabilities = struct {
    experimental: ?std.json.Value = null,
    logging: ?LoggingCapability = null,
    completions: ?CompletionsCapability = null,
    prompts: ?PromptsCapability = null,
    resources: ?ResourcesCapability = null,
    tools: ?ToolsCapability = null,
    tasks: ?ServerTasksCapability = null,
};

pub const LoggingCapability = struct {};
pub const CompletionsCapability = struct {};

pub const PromptsCapability = struct {
    listChanged: bool = false,
};

pub const ResourcesCapability = struct {
    subscribe: bool = false,
    listChanged: bool = false,
};

pub const ToolsCapability = struct {
    listChanged: bool = false,
};

/// Server-side task capabilities.
pub const ServerTasksCapability = struct {
    list: ?struct {} = null,
    cancel: ?struct {} = null,
    requests: ?struct {
        tools: ?struct {
            call: ?struct {} = null,
        } = null,
    } = null,
};

/// Client capabilities advertised during initialization.
pub const ClientCapabilities = struct {
    experimental: ?std.json.Value = null,
    roots: ?RootsCapability = null,
    sampling: ?SamplingCapability = null,
    elicitation: ?ElicitationCapability = null,
    tasks: ?ClientTasksCapability = null,
};

pub const RootsCapability = struct {
    listChanged: bool = false,
};

pub const SamplingCapability = struct {
    /// Whether the client supports context inclusion.
    context: ?struct {} = null,
    /// Whether the client supports tool use via tools and toolChoice parameters.
    tools: ?struct {} = null,
};

pub const ElicitationCapability = struct {
    form: ?struct {} = null,
    url: ?struct {} = null,
};

/// Client-side task capabilities.
pub const ClientTasksCapability = struct {
    list: ?struct {} = null,
    cancel: ?struct {} = null,
    requests: ?struct {
        sampling: ?struct {
            createMessage: ?struct {} = null,
        } = null,
        elicitation: ?struct {
            create: ?struct {} = null,
        } = null,
    } = null,
};

/// Action for an elicitation response.
pub const ElicitationAction = enum {
    accept,
    decline,
    cancel,

    pub fn toString(self: ElicitationAction) []const u8 {
        return @tagName(self);
    }
};

/// Parameters for creating an elicitation request.
pub const ElicitationRequestParams = struct {
    mode: ?[]const u8 = null, // "form" | "url"
    message: []const u8,
    requestedSchema: ?std.json.Value = null,
    url: ?[]const u8 = null,
    elicitationId: ?[]const u8 = null,
};

/// Result returned from an elicitation request.
pub const ElicitationResult = struct {
    action: ElicitationAction,
    content: ?std.json.Value = null,
    _meta: ?std.json.Value = null,
};

/// Text provided to or from an LLM.
pub const TextContent = struct {
    type: []const u8 = "text",
    text: []const u8,
    annotations: ?Annotations = null,
    _meta: ?std.json.Value = null,
};

/// An image provided to or from an LLM.
pub const ImageContent = struct {
    type: []const u8 = "image",
    data: []const u8,
    mimeType: []const u8,
    annotations: ?Annotations = null,
    _meta: ?std.json.Value = null,
};

/// Audio provided to or from an LLM.
pub const AudioContent = struct {
    type: []const u8 = "audio",
    /// The base64-encoded audio data.
    data: []const u8,
    /// The MIME type of the audio.
    mimeType: []const u8,
    annotations: ?Annotations = null,
    _meta: ?std.json.Value = null,
};

/// A resource link that the server is capable of reading.
pub const ResourceLink = struct {
    type: []const u8 = "resource_link",
    icons: ?[]const Icon = null,
    name: []const u8,
    title: ?[]const u8 = null,
    uri: []const u8,
    description: ?[]const u8 = null,
    mimeType: ?[]const u8 = null,
    annotations: ?Annotations = null,
    size: ?u64 = null,
    _meta: ?std.json.Value = null,
};

/// The contents of a resource, embedded into a prompt or tool call result.
pub const EmbeddedResource = struct {
    type: []const u8 = "resource",
    resource: ResourceContent,
    annotations: ?Annotations = null,
    _meta: ?std.json.Value = null,
};

/// Content block that can be text, image, audio, resource link, or embedded resource.
/// Corresponds to `ContentBlock` in the spec.
pub const ContentBlock = union(enum) {
    text: TextContent,
    image: ImageContent,
    audio: AudioContent,
    resource_link: ResourceLink,
    resource: EmbeddedResource,

    /// Returns the text content if this is a text item, null otherwise.
    pub fn asText(self: ContentBlock) ?[]const u8 {
        return switch (self) {
            .text => |t| t.text,
            else => null,
        };
    }
};

/// Legacy alias for backward compatibility.
pub const ContentItem = ContentBlock;

/// A request from the assistant to call a tool (used in sampling).
pub const ToolUseContent = struct {
    type: []const u8 = "tool_use",
    /// A unique identifier for this tool use.
    id: []const u8,
    /// The name of the tool to call.
    name: []const u8,
    /// The arguments to pass to the tool.
    input: std.json.Value,
    _meta: ?std.json.Value = null,
};

/// The result of a tool use, provided by the user back to the assistant.
pub const ToolResultContent = struct {
    type: []const u8 = "tool_result",
    /// The ID of the tool use this result corresponds to.
    toolUseId: []const u8,
    /// The unstructured result content.
    content: []const ContentBlock,
    /// An optional structured result object.
    structuredContent: ?std.json.Value = null,
    /// Whether the tool use resulted in an error.
    isError: ?bool = null,
    _meta: ?std.json.Value = null,
};

/// Content blocks that can appear in sampling messages.
pub const SamplingMessageContentBlock = union(enum) {
    text: TextContent,
    image: ImageContent,
    audio: AudioContent,
    tool_use: ToolUseContent,
    tool_result: ToolResultContent,
};

/// Controls tool selection behavior for sampling requests.
pub const ToolChoice = struct {
    /// "none" | "required" | "auto"
    mode: ?[]const u8 = null,
};

/// Content of a text resource.
pub const TextResourceContents = struct {
    uri: []const u8,
    mimeType: ?[]const u8 = null,
    _meta: ?std.json.Value = null,
    text: []const u8,
};

/// Content of a binary resource.
pub const BlobResourceContents = struct {
    uri: []const u8,
    mimeType: ?[]const u8 = null,
    _meta: ?std.json.Value = null,
    /// A base64-encoded string representing the binary data.
    blob: []const u8,
};

/// Generic resource content (used in server-side resource handlers).
pub const ResourceContent = struct {
    uri: []const u8,
    mimeType: ?[]const u8 = null,
    text: ?[]const u8 = null,
    blob: ?[]const u8 = null,
    _meta: ?std.json.Value = null,
};

/// Definition of a resource exposed by a server.
pub const ResourceDefinition = struct {
    icons: ?[]const Icon = null,
    name: []const u8,
    title: ?[]const u8 = null,
    uri: []const u8,
    description: ?[]const u8 = null,
    mimeType: ?[]const u8 = null,
    annotations: ?Annotations = null,
    size: ?u64 = null,
    _meta: ?std.json.Value = null,
};

/// Resource template for dynamic resources with URI parameters.
pub const ResourceTemplate = struct {
    icons: ?[]const Icon = null,
    name: []const u8,
    title: ?[]const u8 = null,
    uriTemplate: []const u8,
    description: ?[]const u8 = null,
    mimeType: ?[]const u8 = null,
    annotations: ?Annotations = null,
    _meta: ?std.json.Value = null,
};

/// Definition of a tool exposed by a server.
pub const ToolDefinition = struct {
    icons: ?[]const Icon = null,
    name: []const u8,
    title: ?[]const u8 = null,
    description: ?[]const u8 = null,
    inputSchema: InputSchema,
    execution: ?ToolExecution = null,
    outputSchema: ?OutputSchema = null,
    annotations: ?ToolAnnotations = null,
    _meta: ?std.json.Value = null,
};

/// JSON Schema for tool input parameters.
pub const InputSchema = struct {
    @"$schema": ?[]const u8 = null,
    type: []const u8 = "object",
    properties: ?std.json.Value = null,
    required: ?[]const []const u8 = null,
    description: ?[]const u8 = null,
};

/// JSON Schema for tool output.
pub const OutputSchema = struct {
    @"$schema": ?[]const u8 = null,
    type: []const u8 = "object",
    properties: ?std.json.Value = null,
    required: ?[]const []const u8 = null,
};

/// Execution-related properties for a tool.
pub const ToolExecution = struct {
    /// "forbidden" | "optional" | "required"
    taskSupport: ?[]const u8 = null,
};

/// Additional properties describing a Tool to clients.
/// NOTE: all properties are hints, not guarantees.
pub const ToolAnnotations = struct {
    /// A human-readable title for the tool.
    title: ?[]const u8 = null,
    /// If true, the tool does not modify its environment. Default: false.
    readOnlyHint: ?bool = null,
    /// If true, the tool may perform destructive updates. Default: true.
    destructiveHint: ?bool = null,
    /// If true, calling repeatedly with same args has no additional effect. Default: false.
    idempotentHint: ?bool = null,
    /// If true, this tool may interact with an "open world". Default: true.
    openWorldHint: ?bool = null,
};

/// Definition of a prompt template.
pub const PromptDefinition = struct {
    icons: ?[]const Icon = null,
    name: []const u8,
    title: ?[]const u8 = null,
    description: ?[]const u8 = null,
    arguments: ?[]const PromptArgument = null,
    _meta: ?std.json.Value = null,
};

/// Argument specification for a prompt.
pub const PromptArgument = struct {
    name: []const u8,
    title: ?[]const u8 = null,
    description: ?[]const u8 = null,
    required: bool = false,
};

/// Message in a prompt response.
pub const PromptMessage = struct {
    role: Role,
    content: ContentBlock,
};

/// Message issued to or received from an LLM API.
pub const SamplingMessage = struct {
    role: Role,
    content: SamplingMessageContentBlock,
    _meta: ?std.json.Value = null,
};

/// Model preferences for sampling requests.
pub const ModelPreferences = struct {
    hints: ?[]const ModelHint = null,
    costPriority: ?f64 = null,
    speedPriority: ?f64 = null,
    intelligencePriority: ?f64 = null,
};

/// Hint for model selection during sampling.
pub const ModelHint = struct {
    name: ?[]const u8 = null,
};

/// Represents a root directory or file that the server can operate on.
pub const Root = struct {
    /// The URI identifying the root. Must start with file:// for now.
    uri: []const u8,
    /// An optional name for the root.
    name: ?[]const u8 = null,
    _meta: ?std.json.Value = null,
};

/// Reference for argument completion.
pub const CompletionRef = union(enum) {
    prompt: PromptRef,
    resource: ResourceRef,

    pub const PromptRef = struct {
        type: []const u8 = "ref/prompt",
        name: []const u8,
        title: ?[]const u8 = null,
    };

    pub const ResourceRef = struct {
        type: []const u8 = "ref/resource",
        uri: []const u8,
    };
};

/// Argument being completed.
pub const CompletionArgument = struct {
    name: []const u8,
    value: []const u8,
};

/// Result of argument completion.
pub const CompletionResult = struct {
    values: []const []const u8,
    total: ?u64 = null,
    hasMore: ?bool = null,
};

/// The status of a task.
pub const TaskStatus = enum {
    working,
    input_required,
    completed,
    failed,
    cancelled,

    pub fn toString(self: TaskStatus) []const u8 {
        return @tagName(self);
    }
};

/// Data associated with a task.
pub const Task = struct {
    taskId: []const u8,
    status: TaskStatus,
    statusMessage: ?[]const u8 = null,
    /// ISO 8601 timestamp when the task was created.
    createdAt: []const u8,
    /// ISO 8601 timestamp when the task was last updated.
    lastUpdatedAt: []const u8,
    /// Actual retention duration from creation in milliseconds, null for unlimited.
    ttl: ?i64 = null,
    /// Suggested polling interval in milliseconds.
    pollInterval: ?i64 = null,
};

/// Metadata for augmenting a request with task execution.
pub const TaskMetadata = struct {
    /// Requested duration in milliseconds to retain task from creation.
    ttl: ?i64 = null,
};

/// A response to a task-augmented request.
pub const CreateTaskResult = struct {
    _meta: ?std.json.Value = null,
    task: Task,
};

/// Metadata for associating messages with a task.
pub const RelatedTaskMetadata = struct {
    taskId: []const u8,
};

/// Restricted schema definitions for elicitation form fields.
pub const PrimitiveSchemaDefinition = union(enum) {
    string: StringSchema,
    number: NumberSchema,
    boolean: BooleanSchema,
    enum_single: SingleSelectEnumSchema,
    enum_multi: MultiSelectEnumSchema,
};

pub const StringSchema = struct {
    type: []const u8 = "string",
    title: ?[]const u8 = null,
    description: ?[]const u8 = null,
    minLength: ?u64 = null,
    maxLength: ?u64 = null,
    format: ?[]const u8 = null,
    default: ?[]const u8 = null,
};

pub const NumberSchema = struct {
    type: []const u8 = "number",
    title: ?[]const u8 = null,
    description: ?[]const u8 = null,
    minimum: ?f64 = null,
    maximum: ?f64 = null,
    default: ?f64 = null,
};

pub const BooleanSchema = struct {
    type: []const u8 = "boolean",
    title: ?[]const u8 = null,
    description: ?[]const u8 = null,
    default: ?bool = null,
};

/// Single-select enum (with or without titles).
pub const SingleSelectEnumSchema = struct {
    type: []const u8 = "string",
    title: ?[]const u8 = null,
    description: ?[]const u8 = null,
    @"enum": ?[]const []const u8 = null,
    oneOf: ?[]const EnumOption = null,
    default: ?[]const u8 = null,
};

/// Multi-select enum (with or without titles).
pub const MultiSelectEnumSchema = struct {
    type: []const u8 = "array",
    title: ?[]const u8 = null,
    description: ?[]const u8 = null,
    minItems: ?u64 = null,
    maxItems: ?u64 = null,
    items: ?std.json.Value = null,
    default: ?[]const []const u8 = null,
};

/// An enum option with value and display label.
pub const EnumOption = struct {
    @"const": []const u8,
    title: []const u8,
};

/// JSON-RPC error object.
pub const JsonRpcError = struct {
    code: i32,
    message: []const u8,
    data: ?std.json.Value = null,
};

/// Base result type. All results can carry _meta.
pub const Result = struct {
    _meta: ?std.json.Value = null,
};

test "RequestId equality" {
    const id1: RequestId = .{ .integer = 42 };
    const id2: RequestId = .{ .integer = 42 };
    const id3: RequestId = .{ .string = "abc" };

    try std.testing.expect(id1.eql(id2));
    try std.testing.expect(!id1.eql(id3));
}

test "ContentBlock text access" {
    const content: ContentBlock = .{ .text = .{ .text = "Hello" } };
    try std.testing.expectEqualStrings("Hello", content.asText().?);

    const image: ContentBlock = .{ .image = .{ .data = "base64", .mimeType = "image/png" } };
    try std.testing.expect(image.asText() == null);
}

test "Role conversion" {
    try std.testing.expectEqualStrings("user", Role.user.toString());
    try std.testing.expectEqualStrings("assistant", Role.assistant.toString());
    try std.testing.expectEqual(Role.user, Role.fromString("user").?);
    try std.testing.expect(Role.fromString("invalid") == null);
}

test "TaskStatus" {
    try std.testing.expectEqualStrings("working", TaskStatus.working.toString());
    try std.testing.expectEqualStrings("completed", TaskStatus.completed.toString());
}

test "ContentBlock audio variant" {
    const audio: ContentBlock = .{ .audio = .{ .data = "base64audio", .mimeType = "audio/wav" } };
    try std.testing.expect(audio.asText() == null);
}

test "ContentBlock resource_link variant" {
    const link: ContentBlock = .{ .resource_link = .{ .name = "test", .uri = "file:///test.txt" } };
    try std.testing.expect(link.asText() == null);
}
