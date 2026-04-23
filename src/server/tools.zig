//! MCP Tools Module (Spec 2025-11-25)
//!
//! Provides the Tool primitive for MCP servers. Tools are executable functions
//! that AI applications can invoke to perform actions such as file operations,
//! API calls, calculations, or any other server-side operations.

const std = @import("std");

const jsonrpc = @import("../protocol/jsonrpc.zig");
const schema = @import("../protocol/schema.zig");
const types = @import("../protocol/types.zig");

/// A tool that can be exposed by an MCP server.
pub const Tool = struct {
    name: []const u8,
    description: ?[]const u8 = null,
    title: ?[]const u8 = null,
    inputSchema: ?types.InputSchema = null,
    outputSchema: ?types.OutputSchema = null,
    execution: ?types.ToolExecution = null,
    icons: ?[]const types.Icon = null,
    annotations: ?ToolAnnotations = null,
    handler: *const fn (allocator: std.mem.Allocator, arguments: ?std.json.Value) ToolError!ToolResult,
    user_data: ?*anyopaque = null,
};

/// Annotations describing tool behavior characteristics for client display and safety.
/// NOTE: all properties are hints, not guarantees.
pub const ToolAnnotations = struct {
    /// A human-readable title for the tool.
    title: ?[]const u8 = null,
    /// If true, the tool does not modify its environment. Default: false.
    readOnlyHint: bool = false,
    /// If true, the tool may perform destructive updates. Default: true.
    destructiveHint: bool = true,
    /// If true, calling repeatedly with same args has no additional effect. Default: false.
    idempotentHint: bool = false,
    /// If true, this tool may interact with an "open world". Default: true.
    openWorldHint: bool = true,
};

/// Result of a tool execution.
pub const ToolResult = struct {
    content: []const types.ContentBlock,
    structuredContent: ?std.json.Value = null,
    is_error: bool = false,
};

/// Errors that can occur during tool execution.
pub const ToolError = error{
    InvalidArguments,
    ExecutionFailed,
    PermissionDenied,
    ResourceNotFound,
    Timeout,
    OutOfMemory,
    Unknown,
};

/// Builder for creating tools with a fluent API.
pub const ToolBuilder = struct {
    allocator: std.mem.Allocator,
    tool: Tool,
    input_builder: ?schema.InputSchemaBuilder = null,

    const Self = @This();

    /// Creates a new tool builder with the given name.
    pub fn init(allocator: std.mem.Allocator, name: []const u8) Self {
        return .{
            .allocator = allocator,
            .tool = .{
                .name = name,
                .handler = defaultHandler,
            },
        };
    }

    /// Sets the tool description.
    pub fn description(self: *Self, desc: []const u8) *Self {
        self.tool.description = desc;
        return self;
    }

    /// Sets the tool display title.
    pub fn title(self: *Self, t: []const u8) *Self {
        self.tool.title = t;
        return self;
    }

    /// Sets the tool handler function.
    pub fn handler(self: *Self, h: *const fn (std.mem.Allocator, ?std.json.Value) ToolError!ToolResult) *Self {
        self.tool.handler = h;
        return self;
    }

    /// Marks the tool as potentially destructive.
    pub fn destructive(self: *Self) *Self {
        if (self.tool.annotations == null) {
            self.tool.annotations = .{};
        }
        self.tool.annotations.?.destructiveHint = true;
        return self;
    }

    /// Marks the tool as read-only (no side effects).
    pub fn readOnly(self: *Self) *Self {
        if (self.tool.annotations == null) {
            self.tool.annotations = .{};
        }
        self.tool.annotations.?.readOnlyHint = true;
        return self;
    }

    /// Marks the tool as idempotent.
    pub fn idempotent(self: *Self) *Self {
        if (self.tool.annotations == null) {
            self.tool.annotations = .{};
        }
        self.tool.annotations.?.idempotentHint = true;
        return self;
    }

    /// Marks the tool as interacting with an open world.
    pub fn openWorld(self: *Self) *Self {
        if (self.tool.annotations == null) {
            self.tool.annotations = .{};
        }
        self.tool.annotations.?.openWorldHint = true;
        return self;
    }

    /// Sets task support for the tool execution.
    pub fn taskSupport(self: *Self, support: []const u8) *Self {
        self.tool.execution = .{ .taskSupport = support };
        return self;
    }

    /// Builds and returns the final tool.
    pub fn build(self: *Self) Tool {
        return self.tool;
    }

    fn defaultHandler(_: std.mem.Allocator, _: ?std.json.Value) ToolError!ToolResult {
        return .{ .content = &.{} };
    }
};

/// Creates a tool result containing a single text content item.
pub fn textResult(allocator: std.mem.Allocator, text: []const u8) !ToolResult {
    const owned_text = try allocator.dupe(u8, text);
    const content = try allocator.alloc(types.ContentBlock, 1);
    content[0] = .{ .text = .{ .text = owned_text } };
    return .{ .content = content };
}

/// Creates an error result containing a message.
pub fn errorResult(allocator: std.mem.Allocator, message: []const u8) !ToolResult {
    const content = try allocator.alloc(types.ContentBlock, 1);
    content[0] = .{ .text = .{ .text = message } };
    return .{
        .content = content,
        .is_error = true,
    };
}

/// Creates a tool result containing an image.
pub fn imageResult(allocator: std.mem.Allocator, data: []const u8, mimeType: []const u8) !ToolResult {
    const content = try allocator.alloc(types.ContentBlock, 1);
    content[0] = .{ .image = .{ .data = data, .mimeType = mimeType } };
    return .{ .content = content };
}

/// Creates a tool result containing audio.
pub fn audioResult(allocator: std.mem.Allocator, data: []const u8, mimeType: []const u8) !ToolResult {
    const content = try allocator.alloc(types.ContentBlock, 1);
    content[0] = .{ .audio = .{ .data = data, .mimeType = mimeType } };
    return .{ .content = content };
}

/// Creates a tool result containing a resource link.
pub fn resourceLinkResult(allocator: std.mem.Allocator, name: []const u8, uri: []const u8) !ToolResult {
    const content = try allocator.alloc(types.ContentBlock, 1);
    content[0] = .{ .resource_link = .{ .name = name, .uri = uri } };
    return .{ .content = content };
}

/// Creates a tool result with structured JSON content and a text fallback.
pub fn structuredResult(allocator: std.mem.Allocator, structured: std.json.Value) !ToolResult {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);
    try jsonrpc.serializeValue(allocator, &out, structured);
    const text_json = try out.toOwnedSlice(allocator);

    const content = try allocator.alloc(types.ContentBlock, 1);
    content[0] = .{ .text = .{ .text = text_json } };

    return .{
        .content = content,
        .structuredContent = structured,
    };
}

/// Extracts a string argument from tool arguments by key.
pub fn getString(args: ?std.json.Value, key: []const u8) ?[]const u8 {
    if (args) |a| {
        if (a == .object) {
            if (a.object.get(key)) |val| {
                if (val == .string) {
                    return val.string;
                }
            }
        }
    }
    return null;
}

/// Extracts an integer argument from tool arguments by key.
pub fn getInteger(args: ?std.json.Value, key: []const u8) ?i64 {
    if (args) |a| {
        if (a == .object) {
            if (a.object.get(key)) |val| {
                if (val == .integer) {
                    return val.integer;
                }
            }
        }
    }
    return null;
}

/// Extracts a float argument from tool arguments by key.
pub fn getFloat(args: ?std.json.Value, key: []const u8) ?f64 {
    if (args) |a| {
        if (a == .object) {
            if (a.object.get(key)) |val| {
                return switch (val) {
                    .float => val.float,
                    .integer => @floatFromInt(val.integer),
                    else => null,
                };
            }
        }
    }
    return null;
}

/// Extracts a boolean argument from tool arguments by key.
pub fn getBoolean(args: ?std.json.Value, key: []const u8) ?bool {
    if (args) |a| {
        if (a == .object) {
            if (a.object.get(key)) |val| {
                if (val == .bool) {
                    return val.bool;
                }
            }
        }
    }
    return null;
}

/// Extracts an array argument from tool arguments by key.
pub fn getArray(args: ?std.json.Value, key: []const u8) ?std.json.Array {
    if (args) |a| {
        if (a == .object) {
            if (a.object.get(key)) |val| {
                if (val == .array) {
                    return val.array;
                }
            }
        }
    }
    return null;
}

/// Extracts an object argument from tool arguments by key.
pub fn getObject(args: ?std.json.Value, key: []const u8) ?std.json.ObjectMap {
    if (args) |a| {
        if (a == .object) {
            if (a.object.get(key)) |val| {
                if (val == .object) {
                    return val.object;
                }
            }
        }
    }
    return null;
}

/// Validates a tool name according to MCP naming conventions.
/// Names must be alphanumeric with underscores, hyphens, or dots. Max length 128.
pub fn isValidToolName(name: []const u8) bool {
    if (name.len == 0 or name.len > 128) return false;
    for (name) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '_' and c != '-' and c != '.') return false;
    }
    return true;
}

test "ToolBuilder" {
    const allocator = std.testing.allocator;

    var builder = ToolBuilder.init(allocator, "test_tool");
    const tool = builder
        .description("A test tool")
        .title("Test Tool")
        .readOnly()
        .build();

    try std.testing.expectEqualStrings("test_tool", tool.name);
    try std.testing.expectEqualStrings("A test tool", tool.description.?);
    try std.testing.expect(tool.annotations.?.readOnlyHint);
}

test "ToolBuilder with task support" {
    const allocator = std.testing.allocator;

    var builder = ToolBuilder.init(allocator, "long_tool");
    const tool = builder
        .description("A long-running tool")
        .taskSupport("optional")
        .build();

    try std.testing.expectEqualStrings("optional", tool.execution.?.taskSupport.?);
}

test "isValidToolName" {
    try std.testing.expect(isValidToolName("my_tool"));
    try std.testing.expect(isValidToolName("getThing"));
    try std.testing.expect(isValidToolName("calculate_sum_123"));
    try std.testing.expect(isValidToolName("123tool"));
    try std.testing.expect(isValidToolName("my-tool"));
    try std.testing.expect(isValidToolName("domain.tool.action"));

    try std.testing.expect(!isValidToolName(""));
    try std.testing.expect(!isValidToolName("my tool"));
}

test "argument extraction" {
    const allocator = std.testing.allocator;

    var obj: std.json.ObjectMap = .empty;
    defer obj.deinit(allocator);

    try obj.put(allocator, "name", .{ .string = "test" });
    try obj.put(allocator, "count", .{ .integer = 42 });
    try obj.put(allocator, "enabled", .{ .bool = true });
    try obj.put(allocator, "value", .{ .float = 3.14 });

    const value = std.json.Value{ .object = obj };

    try std.testing.expectEqualStrings("test", getString(value, "name").?);
    try std.testing.expectEqual(@as(i64, 42), getInteger(value, "count").?);
    try std.testing.expect(getBoolean(value, "enabled").?);
    try std.testing.expectApproxEqAbs(@as(f64, 3.14), getFloat(value, "value").?, 0.001);

    try std.testing.expect(getString(value, "missing") == null);
}
