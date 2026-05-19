//! Advanced MCP Server Example
//!
//! Demonstrates the full range of mcp.zig v0.0.5 server features:
//! - JSON Schema 2020-12 input + output schemas
//! - Icons and tool annotations
//! - Task-enabled tools (taskSupport = "optional")
//! - Prompts with arguments
//! - Resources and resource templates
//! - Structured content in tool results
//! - HTTP transport (commented-out alternative)

const std = @import("std");
const mcp = @import("mcp");

pub fn main(init: std.process.Init) void {
    run(init.io, init.gpa) catch |err| mcp.reportError(err);
}

fn run(io: std.Io, allocator: std.mem.Allocator) !void {
    var sa_arena = std.heap.ArenaAllocator.init(allocator);
    defer sa_arena.deinit();
    const sa = sa_arena.allocator();

    const convert_in = try buildConvertSchema(sa);
    const convert_out = try buildConvertOutputSchema(sa);

    const server_icon = [_]mcp.types.Icon{.{
        .src = "https://example.com/mcp.zig/icon.svg",
        .mimeType = "image/svg+xml",
        .sizes = &[_][]const u8{"any"},
        .theme = .light,
    }};

    var server: mcp.Server = .init(allocator, .{
        .name = "advanced-server",
        .version = "1.0.0",
        .title = "Advanced MCP Server",
        .description = "Showcases the full mcp.zig v0.0.5 feature set",
        .websiteUrl = "https://github.com/muhammad-fiaz/mcp.zig",
        .instructions = "Use convert_temperature to convert between Celsius and Fahrenheit.",
        .icons = &server_icon,
    });
    defer server.deinit();

    const ro_hints: mcp.tools.ToolAnnotations = .{
        .readOnlyHint = true,
        .idempotentHint = true,
        .destructiveHint = false,
    };

    try server.addTool(.{
        .name = "convert_temperature",
        .description = "Convert a temperature value between Celsius and Fahrenheit",
        .title = "Temperature Converter",
        .inputSchema = convert_in,
        .outputSchema = convert_out,
        .annotations = ro_hints,
        .execution = .{ .taskSupport = "optional" },
        .icons = &server_icon,
        .handler = convertHandler,
    });

    try server.addResource(.{
        .uri = "info://advanced/features",
        .name = "Feature Summary",
        .description = "Overview of features used in this example",
        .mimeType = "text/plain",
        .icons = &server_icon,
        .annotations = .{ .priority = 0.6 },
        .handler = featuresHandler,
    });

    try server.addResourceTemplate(.{
        .uriTemplate = "info://advanced/{topic}",
        .name = "advanced-topic",
        .title = "Advanced Topic",
        .description = "Get info about a specific advanced topic",
        .mimeType = "text/plain",
    });

    try server.addPrompt(.{
        .name = "explain_conversion",
        .title = "Explain Temperature Conversion",
        .description = "Ask the model to explain a temperature conversion result",
        .arguments = &[_]mcp.prompts.PromptArgument{
            .{ .name = "input", .description = "Input value and unit (e.g. '100C')", .required = true },
            .{ .name = "output", .description = "Output value and unit (e.g. '212F')", .required = true },
        },
        .icons = &server_icon,
        .handler = explainPrompt,
    });

    server.enableLogging();
    server.enableTasks();
    server.enableCompletions();

    try server.run(io, allocator, .stdio);
    // HTTP alternative:
    // try server.run(io, allocator, .{ .http = .{ .host = "localhost", .port = 8080 } });
}

fn buildConvertSchema(allocator: std.mem.Allocator) !mcp.types.InputSchema {
    var b = mcp.schema.InputSchemaBuilder.init(allocator);
    defer b.deinit(allocator);
    _ = b.setSchemaDialect("https://json-schema.org/draft/2020-12/schema");
    _ = try b.addNumber(allocator, "value", "Temperature value to convert", true);
    _ = try b.addEnumWithDefault(allocator, "from", "Input unit", &.{ "C", "F" }, "C", true);
    _ = try b.addEnumWithDefault(allocator, "to", "Output unit", &.{ "C", "F" }, "F", true);
    return b.toInputSchema(allocator);
}

fn buildConvertOutputSchema(allocator: std.mem.Allocator) !mcp.types.OutputSchema {
    var props: std.json.ObjectMap = .empty;
    errdefer props.deinit(allocator);

    inline for (.{
        .{ "inputValue", "number" },
        .{ "inputUnit", "string" },
        .{ "resultValue", "number" },
        .{ "resultUnit", "string" },
    }) |pair| {
        var obj: std.json.ObjectMap = .empty;
        try obj.put(allocator, "type", .{ .string = pair[1] });
        try props.put(allocator, pair[0], .{ .object = obj });
    }

    return .{
        .@"$schema" = "https://json-schema.org/draft/2020-12/schema",
        .type = "object",
        .properties = .{ .object = props },
        .required = &[_][]const u8{ "inputValue", "inputUnit", "resultValue", "resultUnit" },
    };
}

fn convertHandler(_: ?*anyopaque, _: std.Io, allocator: std.mem.Allocator, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    const value = mcp.tools.getFloat(args, "value") orelse
        return mcp.tools.errorResult(allocator, "Missing argument: value") catch return mcp.tools.ToolError.OutOfMemory;
    const from = mcp.tools.getString(args, "from") orelse "C";
    const to = mcp.tools.getString(args, "to") orelse "F";

    const is_c = std.mem.eql(u8, from, "C");
    const is_f = std.mem.eql(u8, from, "F");
    if (!is_c and !is_f)
        return mcp.tools.errorResult(allocator, "from must be C or F") catch return mcp.tools.ToolError.OutOfMemory;

    const result_value = if (is_c and std.mem.eql(u8, to, "F"))
        (value * 9.0 / 5.0) + 32.0
    else if (is_f and std.mem.eql(u8, to, "C"))
        (value - 32.0) * 5.0 / 9.0
    else
        value;

    var obj: std.json.ObjectMap = .empty;
    obj.put(allocator, "inputValue", .{ .float = value }) catch {};
    obj.put(allocator, "inputUnit", .{ .string = from }) catch {};
    obj.put(allocator, "resultValue", .{ .float = result_value }) catch {};
    obj.put(allocator, "resultUnit", .{ .string = to }) catch {};

    return mcp.tools.structuredResult(allocator, .{ .object = obj }) catch
        return mcp.tools.ToolError.OutOfMemory;
}

fn featuresHandler(_: ?*anyopaque, _: std.Io, _: std.mem.Allocator, uri: []const u8) mcp.resources.ResourceError!mcp.resources.ResourceContent {
    return .{
        .uri = uri,
        .mimeType = "text/plain",
        .text =
        \\Advanced Server Features (mcp.zig v0.0.5)
        \\- JSON Schema 2020-12 input + output schemas
        \\- Structured content in tool results
        \\- Task-enabled tools (taskSupport = optional)
        \\- Icons and annotations on all primitives
        \\- Resource templates
        \\- Prompts with typed arguments
        ,
    };
}

fn explainPrompt(_: ?*anyopaque, _: std.Io, allocator: std.mem.Allocator, args: ?std.json.Value) mcp.prompts.PromptError![]const mcp.prompts.PromptMessage {
    const input = mcp.prompts.getStringArg(args, "input") orelse "?";
    const output = mcp.prompts.getStringArg(args, "output") orelse "?";
    const text = std.fmt.allocPrint(
        allocator,
        "Explain in plain language how {s} converts to {s}, including the formula used.",
        .{ input, output },
    ) catch return mcp.prompts.PromptError.OutOfMemory;
    const msgs = allocator.alloc(mcp.prompts.PromptMessage, 1) catch return mcp.prompts.PromptError.OutOfMemory;
    msgs[0] = mcp.prompts.userMessage(text);
    return msgs;
}
