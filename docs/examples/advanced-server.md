# Advanced Server Example

An advanced MCP server example that demonstrates schemas, icons, prompts, resources, and task-enabled tools.

## Overview

This example shows how to:

- define JSON Schema 2020-12 input and output schemas
- attach icons and annotations
- enable tasks for tool calls
- expose resources and prompts

## Full Source Code

```zig
//! Advanced MCP Server Example
//!
//! Demonstrates schemas, icons, prompts, resources, and task-enabled tools.

const std = @import("std");
const mcp = @import("mcp");
const common = @import("common.zig");

pub fn main(init: std.process.Init) void {
    run(init.io, init.gpa) catch |err| {
        mcp.reportError(err);
    };
}

fn run(io: std.Io, allocator: std.mem.Allocator) !void {
    var schema_arena = std.heap.ArenaAllocator.init(allocator);
    defer schema_arena.deinit();
    const schema_alloc = schema_arena.allocator();

    const convert_schema = try buildConvertSchema(schema_alloc);
    const convert_output_schema = try buildConvertOutputSchema(schema_alloc);

    var server: mcp.Server = .init(allocator, .{
        .name = "advanced-server",
        .version = "1.0.0",
        .title = "Advanced MCP Server",
        .description = "Demonstrates schemas, icons, and task-enabled tools",
        .websiteUrl = "https://example.com/mcp.zig",
        .instructions = "Use convert_temperature to convert between C and F.",
        .icons = common.defaultIcons(),
    });
    defer server.deinit();

    try server.addTool(.{
        .name = "convert_temperature",
        .description = "Convert temperature between Celsius and Fahrenheit",
        .title = "Temperature Converter",
        .inputSchema = convert_schema,
        .outputSchema = convert_output_schema,
        .execution = .{ .taskSupport = "optional" },
        .icons = common.defaultIcons(),
        .annotations = common.readOnlyToolAnnotations(),
        .handler = convertHandler,
    });

    try server.addResource(.{
        .uri = "info://advanced/features",
        .name = "Feature Summary",
        .description = "Features used in this example",
        .mimeType = "text/plain",
        .icons = common.defaultIcons(),
        .annotations = .{ .priority = 0.6 },
        .handler = featuresHandler,
    });

    try server.addPrompt(.{
        .name = "explain_conversion",
        .title = "Explain Conversion",
        .description = "Explain a conversion result in plain language",
        .arguments = &[_]mcp.prompts.PromptArgument{
            .{ .name = "input", .description = "Input temperature", .required = true },
            .{ .name = "output", .description = "Output temperature", .required = true },
        },
        .icons = common.defaultIcons(),
        .handler = explainPrompt,
    });

    server.enableLogging();
    server.enableTasks();

    try server.run(io, allocator, .stdio);
}

fn buildConvertSchema(allocator: std.mem.Allocator) !mcp.types.InputSchema {
    var builder = mcp.schema.InputSchemaBuilder.init(allocator);
    defer builder.deinit(allocator);

    _ = builder.setSchemaDialect("https://json-schema.org/draft/2020-12/schema");
    _ = try builder.addNumber(allocator, "value", "Temperature value", true);
    _ = try builder.addEnumWithDefault(allocator, "from", "Input unit", &.{ "C", "F" }, "C", true);
    _ = try builder.addEnumWithDefault(allocator, "to", "Output unit", &.{ "C", "F" }, "F", true);

    return builder.toInputSchema(allocator);
}

fn buildConvertOutputSchema(allocator: std.mem.Allocator) !mcp.types.OutputSchema {
    var props: std.json.ObjectMap = .empty;
    errdefer props.deinit(allocator);

    var value_obj: std.json.ObjectMap = .empty;
    try value_obj.put(allocator, "type", .{ .string = "number" });
    try props.put(allocator, "inputValue", .{ .object = value_obj });

    var in_unit_obj: std.json.ObjectMap = .empty;
    try in_unit_obj.put(allocator, "type", .{ .string = "string" });
    try props.put(allocator, "inputUnit", .{ .object = in_unit_obj });

    var out_value_obj: std.json.ObjectMap = .empty;
    try out_value_obj.put(allocator, "type", .{ .string = "number" });
    try props.put(allocator, "resultValue", .{ .object = out_value_obj });

    var out_unit_obj: std.json.ObjectMap = .empty;
    try out_unit_obj.put(allocator, "type", .{ .string = "string" });
    try props.put(allocator, "resultUnit", .{ .object = out_unit_obj });

    return .{
        .@"$schema" = "https://json-schema.org/draft/2020-12/schema",
        .type = "object",
        .properties = .{ .object = props },
        .required = &[_][]const u8{ "inputValue", "inputUnit", "resultValue", "resultUnit" },
    };
}

fn convertHandler(_: ?*anyopaque, _: std.Io, allocator: std.mem.Allocator, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    const value = mcp.tools.getFloat(args, "value") orelse {
        return mcp.tools.errorResult(allocator, "Missing argument: value") catch return mcp.tools.ToolError.OutOfMemory;
    };
    const from_unit = mcp.tools.getString(args, "from") orelse "C";
    const to_unit = mcp.tools.getString(args, "to") orelse "F";

    const is_c = std.mem.eql(u8, from_unit, "C");
    const is_f = std.mem.eql(u8, from_unit, "F");
    const to_c = std.mem.eql(u8, to_unit, "C");
    const to_f = std.mem.eql(u8, to_unit, "F");

    if (!(is_c or is_f) or !(to_c or to_f)) {
        return mcp.tools.errorResult(allocator, "Units must be C or F") catch return mcp.tools.ToolError.OutOfMemory;
    }

    const result_value = if (is_c and to_f)
        (value * 9.0 / 5.0) + 32.0
    else if (is_f and to_c)
        (value - 32.0) * 5.0 / 9.0
    else
        value;

    var obj: std.json.ObjectMap = .empty;
    obj.put(allocator, "inputValue", .{ .float = value }) catch {};
    obj.put(allocator, "inputUnit", .{ .string = from_unit }) catch {};
    obj.put(allocator, "resultValue", .{ .float = result_value }) catch {};
    obj.put(allocator, "resultUnit", .{ .string = to_unit }) catch {};

    return mcp.tools.structuredResult(allocator, .{ .object = obj }) catch return mcp.tools.ToolError.OutOfMemory;
}

fn featuresHandler(_: ?*anyopaque, _: std.Io, _: std.mem.Allocator, uri: []const u8) mcp.resources.ResourceError!mcp.resources.ResourceContent {
    return .{
        .uri = uri,
        .mimeType = "text/plain",
        .text =
        \Advanced Server Features
        \- JSON Schema 2020-12 input/output
        \- Icons and annotations
        \- Task-enabled tools (optional)
        \- Prompts and resources
        ,
    };
}

fn explainPrompt(_: ?*anyopaque, _: std.Io, allocator: std.mem.Allocator, args: ?std.json.Value) mcp.prompts.PromptError![]const mcp.prompts.PromptMessage {
    const input = mcp.prompts.getStringArg(args, "input") orelse "";
    const output = mcp.prompts.getStringArg(args, "output") orelse "";

    const text = std.fmt.allocPrint(allocator, "Explain how {s} becomes {s} with a quick summary.", .{ input, output }) catch {
        return mcp.prompts.PromptError.OutOfMemory;
    };

    const messages = allocator.alloc(mcp.prompts.PromptMessage, 1) catch return mcp.prompts.PromptError.OutOfMemory;
    messages[0] = mcp.prompts.userMessage(text);
    return messages;
}
```

## Example Request

```json
{
  "jsonrpc": "2.0",
  "id": 1,
  "method": "tools/call",
  "params": {
    "name": "convert_temperature",
    "arguments": {
      "value": 25,
      "from": "C",
      "to": "F"
    }
  }
}
```

To request task tracking, include a `task` payload:

```json
{
  "jsonrpc": "2.0",
  "id": 2,
  "method": "tools/call",
  "params": {
    "name": "convert_temperature",
    "task": {
      "ttl": 60000
    },
    "arguments": {
      "value": 72,
      "from": "F",
      "to": "C"
    }
  }
}
```

## Build and Run

```bash
zig build
./zig-out/bin/advanced-server
```

PowerShell (Windows):

```powershell
zig build
.\zig-out\bin\advanced-server.exe
```

## Next Steps

- [Tools Guide](/guide/tools)
- [Server Guide](/guide/server)
- [Examples Overview](/examples/)
