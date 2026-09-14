---
title: "Calculator Server Example"
description: "Build an MCP calculator server with arithmetic operations using MCP.zig."
keywords: [calculator server, arithmetic tools, add, subtract, multiply, divide, output schema]
---

# Calculator Server Example

An MCP server exposing arithmetic tools with full JSON Schema 2020-12 input schemas and structured output.

## Overview

This example demonstrates:

- `InputSchemaBuilder` with number fields
- `OutputSchema` with structured content
- `ToolAnnotations` (read-only, idempotent)
- Task-enabled divide tool (`taskSupport = "optional"`)
- STDIO + HTTP transport options

## Full Source Code

```zig
const std = @import("std");
const mcp = @import("mcp");

pub fn main(init: std.process.Init) void {
    run(init.io, init.gpa) catch |err| {
        mcp.reportError(err);
    };
}

fn run(io: std.Io, allocator: std.mem.Allocator) !void {
    var schema_arena = std.heap.ArenaAllocator.init(allocator);
    defer schema_arena.deinit();
    const sa = schema_arena.allocator();

    const input_schema = try buildTwoNumberSchema(sa);
    const output_schema = try buildArithmeticOutputSchema(sa);

    var server = mcp.Server.init(allocator, .{
        .name = "calculator-server",
        .version = "1.0.0",
        .title = "Calculator Server",
        .description = "Perform arithmetic operations: add, subtract, multiply, divide",
        .instructions = "Call add/subtract/multiply/divide with arguments 'a' and 'b' (numbers).",
    });
    defer server.deinit();

    const ro_hints: mcp.tools.ToolAnnotations = .{
        .readOnlyHint = true,
        .idempotentHint = true,
        .destructiveHint = false,
    };

    try server.addTool(.{
        .name = "add",
        .description = "Add two numbers (a + b)",
        .title = "Addition",
        .inputSchema = input_schema,
        .outputSchema = output_schema,
        .annotations = ro_hints,
        .handler = addHandler,
    });

    try server.addTool(.{
        .name = "subtract",
        .description = "Subtract b from a (a - b)",
        .title = "Subtraction",
        .inputSchema = input_schema,
        .outputSchema = output_schema,
        .annotations = ro_hints,
        .handler = subtractHandler,
    });

    try server.addTool(.{
        .name = "multiply",
        .description = "Multiply two numbers (a * b)",
        .title = "Multiplication",
        .inputSchema = input_schema,
        .outputSchema = output_schema,
        .annotations = ro_hints,
        .handler = multiplyHandler,
    });

    try server.addTool(.{
        .name = "divide",
        .description = "Divide a by b (a / b). Supports async task execution.",
        .title = "Division",
        .inputSchema = input_schema,
        .outputSchema = output_schema,
        .annotations = ro_hints,
        .execution = .{ .taskSupport = "optional" },
        .handler = divideHandler,
    });

    try server.addResource(.{
        .uri = "info://calculator/formulas",
        .name = "Arithmetic Formulas",
        .description = "Quick reference for arithmetic operations",
        .mimeType = "text/plain",
        .handler = formulasHandler,
    });

    server.enableLogging();
    server.enableTasks();

    try server.run(io, allocator, .stdio);
}

fn buildTwoNumberSchema(allocator: std.mem.Allocator) !mcp.types.InputSchema {
    var b = mcp.schema.InputSchemaBuilder.init(allocator);
    defer b.deinit(allocator);
    _ = b.setSchemaDialect("https://json-schema.org/draft/2020-12/schema");
    _ = try b.addNumber(allocator, "a", "First operand", true);
    _ = try b.addNumber(allocator, "b", "Second operand", true);
    return b.toInputSchema(allocator);
}

fn buildArithmeticOutputSchema(allocator: std.mem.Allocator) !mcp.types.OutputSchema {
    var props: std.json.ObjectMap = .empty;
    errdefer props.deinit(allocator);

    var result_obj: std.json.ObjectMap = .empty;
    try result_obj.put(allocator, "type", .{ .string = "number" });
    try props.put(allocator, "result", .{ .object = result_obj });

    var op_obj: std.json.ObjectMap = .empty;
    try op_obj.put(allocator, "type", .{ .string = "string" });
    try props.put(allocator, "operation", .{ .object = op_obj });

    return .{
        .@"$schema" = "https://json-schema.org/draft/2020-12/schema",
        .type = "object",
        .properties = .{ .object = props },
        .required = &[_][]const u8{ "result", "operation" },
    };
}

fn mathResult(
    allocator: std.mem.Allocator,
    op: []const u8,
    value: f64,
) mcp.tools.ToolError!mcp.tools.ToolResult {
    var obj: std.json.ObjectMap = .empty;
    obj.put(allocator, "operation", .{ .string = op }) catch return mcp.tools.ToolError.OutOfMemory;
    obj.put(allocator, "result", .{ .float = value }) catch return mcp.tools.ToolError.OutOfMemory;
    return mcp.tools.structuredResult(allocator, .{ .object = obj }) catch
        return mcp.tools.ToolError.OutOfMemory;
}

fn addHandler(_: ?*anyopaque, _: std.Io, allocator: std.mem.Allocator, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    const a = mcp.tools.getFloat(args, "a") orelse
        return mcp.tools.errorResult(allocator, "Missing argument: a") catch return mcp.tools.ToolError.OutOfMemory;
    const b = mcp.tools.getFloat(args, "b") orelse
        return mcp.tools.errorResult(allocator, "Missing argument: b") catch return mcp.tools.ToolError.OutOfMemory;
    return mathResult(allocator, "add", a + b);
}

fn subtractHandler(_: ?*anyopaque, _: std.Io, allocator: std.mem.Allocator, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    const a = mcp.tools.getFloat(args, "a") orelse
        return mcp.tools.errorResult(allocator, "Missing argument: a") catch return mcp.tools.ToolError.OutOfMemory;
    const b = mcp.tools.getFloat(args, "b") orelse
        return mcp.tools.errorResult(allocator, "Missing argument: b") catch return mcp.tools.ToolError.OutOfMemory;
    return mathResult(allocator, "subtract", a - b);
}

fn multiplyHandler(_: ?*anyopaque, _: std.Io, allocator: std.mem.Allocator, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    const a = mcp.tools.getFloat(args, "a") orelse
        return mcp.tools.errorResult(allocator, "Missing argument: a") catch return mcp.tools.ToolError.OutOfMemory;
    const b = mcp.tools.getFloat(args, "b") orelse
        return mcp.tools.errorResult(allocator, "Missing argument: b") catch return mcp.tools.ToolError.OutOfMemory;
    return mathResult(allocator, "multiply", a * b);
}

fn divideHandler(_: ?*anyopaque, _: std.Io, allocator: std.mem.Allocator, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    const a = mcp.tools.getFloat(args, "a") orelse
        return mcp.tools.errorResult(allocator, "Missing argument: a") catch return mcp.tools.ToolError.OutOfMemory;
    const b = mcp.tools.getFloat(args, "b") orelse
        return mcp.tools.errorResult(allocator, "Missing argument: b") catch return mcp.tools.ToolError.OutOfMemory;
    if (b == 0) {
        return mcp.tools.errorResult(allocator, "Division by zero is undefined") catch
            return mcp.tools.ToolError.OutOfMemory;
    }
    return mathResult(allocator, "divide", a / b);
}

fn formulasHandler(
    _: ?*anyopaque,
    _: std.Io,
    _: std.mem.Allocator,
    uri: []const u8,
) mcp.resources.ResourceError!mcp.resources.ResourceContent {
    return .{
        .uri = uri,
        .mimeType = "text/plain",
        .text =
        \\Arithmetic Formulas
        \\-------------------
        \\Addition:       a + b
        \\Subtraction:    a - b
        \\Multiplication: a * b
        \\Division:       a / b  (b ≠ 0)
        ,
    };
}
```

## Build and Run

```bash
zig build
./zig-out/bin/calculator-server
```

PowerShell (Windows):

```powershell
zig build
.\zig-out\bin\calculator-server.exe
```

## Client Usage

### Discover Server

```bash
echo '{"jsonrpc":"2.0","id":1,"method":"server/discover"}' | ./zig-out/bin/calculator-server
```

### Call add Tool

```bash
echo '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"add","arguments":{"a":5,"b":3}}}' | ./zig-out/bin/calculator-server
```

### Call divide Tool

```bash
echo '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"divide","arguments":{"a":10,"b":2}}}' | ./zig-out/bin/calculator-server
```

### Division by Zero Error

```bash
echo '{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"divide","arguments":{"a":10,"b":0}}}' | ./zig-out/bin/calculator-server
```

PowerShell:

```powershell
'{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"add","arguments":{"a":5,"b":3}}}' | .\zig-out\bin\calculator-server.exe
```

## Expected Output

**add(5, 3):**

```json
{"jsonrpc":"2.0","id":2,"result":{"content":[{"type":"text","text":"{\"operation\":\"add\",\"result\":8}"}],"isError":false,"resultType":"complete","structuredContent":{"operation":"add","result":8}}}
```

**divide(10, 2):**

```json
{"jsonrpc":"2.0","id":3,"result":{"content":[{"type":"text","text":"{\"operation\":\"divide\",\"result\":5}"}],"isError":false,"resultType":"complete","structuredContent":{"operation":"divide","result":5}}}
```

**divide(10, 0) — error:**

```json
{"jsonrpc":"2.0","id":4,"result":{"content":[{"type":"text","text":"Division by zero is undefined"}],"isError":true,"resultType":"complete"}}
```

## Output Shape

Each tool returns structured JSON with `operation` and `result` fields via `structuredResult`.

## Next Steps

- [Advanced Server](/examples/advanced-server)
- [Error Handling Guide](/guide/error-handling)
- [Tools Guide](/guide/tools)
