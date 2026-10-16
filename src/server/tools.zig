//! MCP Tools Module (Spec 2026-07-28)
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
    _meta: ?std.json.Value = null,
    handler: *const fn (user_data: ?*anyopaque, io: std.Io, allocator: std.mem.Allocator, arguments: ?std.json.Value) ToolError!ToolResult,
    user_data: ?*anyopaque = null,

    /// Returns the UI resource URI declared in `_meta.ui`, if any.
    pub fn getUiResourceUri(self: Tool) ?[]const u8 {
        const m = self._meta orelse return null;
        if (m != .object) return null;
        const ui_val = m.object.get("ui") orelse return null;
        if (ui_val != .object) return null;
        const uri_val = ui_val.object.get("resourceUri") orelse return null;
        if (uri_val != .string) return null;
        return uri_val.string;
    }
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
    _meta: ?std.json.Value = null,
    is_error: bool = false,

    /// Returns true if this result carries metadata for the MCP Apps UI extension.
    pub fn hasUi(self: ToolResult) bool {
        const m = self._meta orelse return false;
        if (m != .object) return false;
        return m.object.contains("ui");
    }
};

/// Errors that can occur during tool execution.
pub const ToolError = error{
    InvalidArguments,
    ExecutionFailed,
    PermissionDenied,
    ResourceNotFound,
    Timeout,
    OutOfMemory,
    /// The tool cannot finish yet and needs more input from the client.
    /// The server turns this into an MRTR `InputRequiredResult` using the
    /// resolver configured on `ServerConfig.mrtr`.
    InputRequired,
    Unknown,
};

/// Builder for creating tools with a fluent API.
pub const ToolBuilder = struct {
    tool: Tool,

    const Self = @This();

    /// Creates a new tool builder with the given name.
    pub fn init(name: []const u8) Self {
        return .{
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
    pub fn handler(self: *Self, h: *const fn (?*anyopaque, std.Io, std.mem.Allocator, ?std.json.Value) ToolError!ToolResult) *Self {
        self.tool.handler = h;
        return self;
    }

    /// Sets the input schema for the tool.
    pub fn inputSchema(self: *Self, schema_value: types.InputSchema) *Self {
        self.tool.inputSchema = schema_value;
        return self;
    }

    /// Sets the input schema from a raw JSON Schema 2020-12 document, so
    /// keywords the typed struct cannot express (`$ref`, `$defs`, `allOf`,
    /// `anyOf`, `additionalProperties`, ...) reach clients intact.
    pub fn inputSchemaFromRaw(self: *Self, value: std.json.Value) *Self {
        self.tool.inputSchema = types.InputSchema.fromJson(value);
        return self;
    }

    /// Sets the input schema from an InputSchemaBuilder using an allocator.
    pub fn inputSchemaFromBuilder(self: *Self, allocator: std.mem.Allocator, builder: *schema.InputSchemaBuilder) !*Self {
        self.tool.inputSchema = try builder.toInputSchema(allocator);
        return self;
    }

    /// Sets the output schema for the tool.
    pub fn outputSchema(self: *Self, schema_value: types.OutputSchema) *Self {
        self.tool.outputSchema = schema_value;
        return self;
    }

    /// Sets the output schema from a raw JSON Schema 2020-12 document.
    pub fn outputSchemaFromRaw(self: *Self, value: std.json.Value) *Self {
        self.tool.outputSchema = types.OutputSchema.fromJson(value);
        return self;
    }

    /// Sets icon metadata for the tool.
    pub fn icons(self: *Self, icons_value: []const types.Icon) *Self {
        self.tool.icons = icons_value;
        return self;
    }

    /// Sets annotations metadata for the tool.
    pub fn annotations(self: *Self, annotations_value: ToolAnnotations) *Self {
        self.tool.annotations = annotations_value;
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

    /// Sets metadata for the tool, such as MCP Apps (`_meta.ui`).
    pub fn meta(self: *Self, m: std.json.Value) *Self {
        self.tool._meta = m;
        return self;
    }

    /// Sets MCP Apps UI extension metadata (`_meta.ui`) pointing to a UI resource URI (e.g. `ui://charts/interactive`).
    pub fn ui(self: *Self, allocator: std.mem.Allocator, resource_uri: []const u8) !*Self {
        var ui_obj: std.json.ObjectMap = .empty;
        try ui_obj.put(allocator, "resourceUri", .{ .string = resource_uri });
        var meta_obj: std.json.ObjectMap = .empty;
        try meta_obj.put(allocator, "ui", .{ .object = ui_obj });
        self.tool._meta = .{ .object = meta_obj };
        return self;
    }

    /// Sets MCP Apps UI extension metadata (`_meta.ui`) pointing to a UI resource URI with visibility settings.
    pub fn uiWithVisibility(
        self: *Self,
        allocator: std.mem.Allocator,
        resource_uri: []const u8,
        visibility: []const []const u8,
    ) !*Self {
        var ui_obj: std.json.ObjectMap = .empty;
        try ui_obj.put(allocator, "resourceUri", .{ .string = resource_uri });
        var vis_arr: std.json.Array = .init(allocator);
        for (visibility) |v| {
            try vis_arr.append(.{ .string = v });
        }
        try ui_obj.put(allocator, "visibility", .{ .array = vis_arr });
        var meta_obj: std.json.ObjectMap = .empty;
        try meta_obj.put(allocator, "ui", .{ .object = ui_obj });
        self.tool._meta = .{ .object = meta_obj };
        return self;
    }

    /// Builds and returns the final tool.
    pub fn build(self: *Self) Tool {
        return self.tool;
    }

    fn defaultHandler(_: ?*anyopaque, _: std.Io, _: std.mem.Allocator, _: ?std.json.Value) ToolError!ToolResult {
        return .{ .content = &.{} };
    }
};

/// Creates a tool result containing a single text content item.
pub fn textResult(allocator: std.mem.Allocator, text: []const u8) !ToolResult {
    const owned_text = try allocator.dupe(u8, text);
    const content = try allocator.alloc(types.ContentBlock, 1);
    content[0] = .{ .text = .{ .text = owned_text } };

    var obj: std.json.ObjectMap = .empty;
    try obj.put(allocator, "text", .{ .string = owned_text });

    return .{
        .content = content,
        .structuredContent = .{ .object = obj },
    };
}

/// Creates an error result containing a message.
pub fn errorResult(allocator: std.mem.Allocator, message: []const u8) !ToolResult {
    const owned_message = try allocator.dupe(u8, message);
    const content = try allocator.alloc(types.ContentBlock, 1);
    content[0] = .{ .text = .{ .text = owned_message } };

    var obj: std.json.ObjectMap = .empty;
    try obj.put(allocator, "error", .{ .string = owned_message });

    return .{
        .content = content,
        .structuredContent = .{ .object = obj },
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
    var builder: ToolBuilder = .init("test_tool");
    const tool = builder
        .description("A test tool")
        .title("Test Tool")
        .readOnly()
        .build();

    try std.testing.expectEqualStrings("test_tool", tool.name);
    try std.testing.expectEqualStrings("A test tool", tool.description.?);
    try std.testing.expect(tool.annotations.?.readOnlyHint);
}

test "ToolBuilder with inputSchemaFromBuilder" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var schema_builder = schema.InputSchemaBuilder.init(allocator);
    defer schema_builder.deinit(allocator);

    _ = try schema_builder.addString(allocator, "query", "Search query", true);

    var builder: ToolBuilder = .init("search_tool");
    _ = try builder
        .description("Search tool")
        .inputSchemaFromBuilder(allocator, &schema_builder);
    const tool = builder.build();

    try std.testing.expectEqualStrings("search_tool", tool.name);
    try std.testing.expectEqualStrings("object", tool.inputSchema.?.type);
    try std.testing.expectEqualStrings("query", tool.inputSchema.?.required.?[0]);
}

test "ToolBuilder with task support" {
    var builder: ToolBuilder = .init("long_tool");
    const tool = builder
        .description("A long-running tool")
        .taskSupport("optional")
        .build();

    try std.testing.expectEqualStrings("optional", tool.execution.?.taskSupport.?);
}

test "ToolBuilder with meta and ui" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var builder: ToolBuilder = .init("ui_tool");
    _ = try builder
        .description("A tool with UI")
        .uiWithVisibility(allocator, "ui://charts/interactive", &[_][]const u8{ "model", "app" });
    const tool = builder.build();

    try std.testing.expect(tool._meta != null);
    const ui_obj = tool._meta.?.object.get("ui").?.object;
    try std.testing.expectEqualStrings("ui://charts/interactive", ui_obj.get("resourceUri").?.string);
    const vis = ui_obj.get("visibility").?.array;
    try std.testing.expectEqual(@as(usize, 2), vis.items.len);
    try std.testing.expectEqualStrings("model", vis.items[0].string);
    try std.testing.expectEqualStrings("app", vis.items[1].string);

    try std.testing.expectEqualStrings("ui://charts/interactive", tool.getUiResourceUri().?);
    const result_with_ui = ToolResult{
        .content = &.{},
        ._meta = tool._meta,
    };
    try std.testing.expect(result_with_ui.hasUi());
    const result_without_ui = ToolResult{
        .content = &.{},
    };
    try std.testing.expect(!result_without_ui.hasUi());
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

    const value: std.json.Value = .{ .object = obj };

    try std.testing.expectEqualStrings("test", getString(value, "name").?);
    try std.testing.expectEqual(@as(i64, 42), getInteger(value, "count").?);
    try std.testing.expect(getBoolean(value, "enabled").?);
    try std.testing.expectApproxEqAbs(@as(f64, 3.14), getFloat(value, "value").?, 0.001);

    try std.testing.expect(getString(value, "missing") == null);
}
