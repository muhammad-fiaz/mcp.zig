---
title: "Simple Server Example"
description: "Build a simple MCP server with tools, resources, and prompts using MCP.zig."
keywords: [simple server, MCP server example, tools, resources, prompts, greet tool, echo tool]
---

# Simple Server Example

A complete MCP server example with tools, resources, prompts, and logging.

## Overview

This example shows how to:

- Create an MCP server with `mcp.Server.init`
- Register tools (`greet`, `echo`) with input schemas
- Register a resource (`info://server/about`)
- Register a prompt (`introduce`)
- Run over STDIO transport

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

    const greet_schema = try buildGreetSchema(sa);
    const echo_schema = try buildEchoSchema(sa);

    var server = mcp.Server.init(allocator, .{
        .name = "simple-server",
        .version = "1.0.0",
        .title = "Simple MCP Server",
        .description = "A minimal example MCP server demonstrating tools, resources, and prompts",
        .instructions = "Use 'greet' to greet someone by name, or 'echo' to reflect a message back.",
    });
    defer server.deinit();

    try server.addTool(.{
        .name = "greet",
        .description = "Greet a user by name",
        .title = "Greeting Tool",
        .inputSchema = greet_schema,
        .annotations = .{ .readOnlyHint = true, .idempotentHint = true },
        .handler = greetHandler,
    });

    try server.addTool(.{
        .name = "echo",
        .description = "Echo back the input message unchanged",
        .title = "Echo Tool",
        .inputSchema = echo_schema,
        .annotations = .{ .readOnlyHint = true, .idempotentHint = true },
        .handler = echoHandler,
    });

    try server.addResource(.{
        .uri = "info://server/about",
        .name = "About",
        .description = "Information about this server",
        .mimeType = "text/plain",
        .annotations = .{ .priority = 0.9 },
        .handler = aboutHandler,
    });

    try server.addPrompt(.{
        .name = "introduce",
        .description = "Ask the model to introduce this server's capabilities",
        .title = "Server Introduction",
        .arguments = &[_]mcp.prompts.PromptArgument{
            .{ .name = "style", .description = "Tone: formal or casual", .required = false },
        },
        .handler = introduceHandler,
    });

    server.enableLogging();
    try server.run(io, allocator, .stdio);
}

fn buildGreetSchema(allocator: std.mem.Allocator) !mcp.types.InputSchema {
    var b = mcp.schema.InputSchemaBuilder.init(allocator);
    defer b.deinit(allocator);
    _ = b.setSchemaDialect("https://json-schema.org/draft/2020-12/schema");
    _ = try b.addString(allocator, "name", "Name of the person to greet", false);
    return b.toInputSchema(allocator);
}

fn buildEchoSchema(allocator: std.mem.Allocator) !mcp.types.InputSchema {
    var b = mcp.schema.InputSchemaBuilder.init(allocator);
    defer b.deinit(allocator);
    _ = b.setSchemaDialect("https://json-schema.org/draft/2020-12/schema");
    _ = try b.addString(allocator, "message", "Message to echo back", true);
    return b.toInputSchema(allocator);
}

fn greetHandler(
    _: ?*anyopaque,
    _: std.Io,
    allocator: std.mem.Allocator,
    args: ?std.json.Value,
) mcp.tools.ToolError!mcp.tools.ToolResult {
    const name = mcp.tools.getString(args, "name") orelse "World";
    const greeting = std.fmt.allocPrint(allocator, "Hello, {s}! Welcome to mcp.zig.", .{name}) catch
        return mcp.tools.ToolError.OutOfMemory;
    return mcp.tools.textResult(allocator, greeting) catch return mcp.tools.ToolError.OutOfMemory;
}

fn echoHandler(
    _: ?*anyopaque,
    _: std.Io,
    allocator: std.mem.Allocator,
    args: ?std.json.Value,
) mcp.tools.ToolError!mcp.tools.ToolResult {
    const message = mcp.tools.getString(args, "message") orelse "No message provided";
    return mcp.tools.textResult(allocator, message) catch return mcp.tools.ToolError.OutOfMemory;
}

fn aboutHandler(
    _: ?*anyopaque,
    _: std.Io,
    _: std.mem.Allocator,
    uri: []const u8,
) mcp.resources.ResourceError!mcp.resources.ResourceContent {
    return .{
        .uri = uri,
        .mimeType = "text/plain",
        .text =
        \\Simple MCP Server v1.0.0
        \\
        \\Built with mcp.zig — a native Zig implementation of the
        \\Model Context Protocol (spec 2026-07-28).
        \\
        \\Tools:  greet, echo
        \\Resources: info://server/about
        \\Prompts: introduce
        ,
    };
}

fn introduceHandler(
    _: ?*anyopaque,
    _: std.Io,
    allocator: std.mem.Allocator,
    args: ?std.json.Value,
) mcp.prompts.PromptError![]const mcp.prompts.PromptMessage {
    const style = mcp.prompts.getStringArg(args, "style") orelse "casual";
    const text = std.fmt.allocPrint(
        allocator,
        "Please introduce this MCP server in a {s} tone. Describe the 'greet' and 'echo' tools.",
        .{style},
    ) catch return mcp.prompts.PromptError.OutOfMemory;
    const messages = allocator.alloc(mcp.prompts.PromptMessage, 1) catch
        return mcp.prompts.PromptError.OutOfMemory;
    messages[0] = mcp.prompts.userMessage(text);
    return messages;
}
```

## Build and Run

```bash
zig build
./zig-out/bin/example-server
```

PowerShell (Windows):

```powershell
zig build
.\zig-out\bin\example-server.exe
```

## Client Usage

### Discover Server

```bash
echo '{"jsonrpc":"2.0","id":1,"method":"server/discover"}' | ./zig-out/bin/example-server
```

PowerShell:

```powershell
'{"jsonrpc":"2.0","id":1,"method":"server/discover"}' | .\zig-out\bin\example-server.exe
```

### Call greet Tool

```bash
echo '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"greet","arguments":{"name":"Alice"}}}' | ./zig-out/bin/example-server
```

PowerShell:

```powershell
'{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"greet","arguments":{"name":"Alice"}}}' | .\zig-out\bin\example-server.exe
```

### Call echo Tool

```bash
echo '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"echo","arguments":{"message":"Hello World"}}}' | ./zig-out/bin/example-server
```

### List Tools

```bash
echo '{"jsonrpc":"2.0","id":4,"method":"tools/list"}' | ./zig-out/bin/example-server
```

## Expected Output

**Discover response:**

```json
{"jsonrpc":"2.0","id":1,"result":{"supportedVersions":["2026-07-28","2025-11-25","2025-06-18","2025-03-26","2024-11-05"],"capabilities":{"tools":{"listChanged":true},"logging":{}},"serverInfo":{"name":"simple-server","version":"1.0.0","title":"Simple MCP Server","description":"A minimal example MCP server demonstrating tools, resources, and prompts"}}}
```

**greet("Alice") response:**

```json
{"jsonrpc":"2.0","id":2,"result":{"content":[{"type":"text","text":"Hello, Alice! Welcome to mcp.zig."}],"isError":false,"resultType":"complete","structuredContent":{"text":"Hello, Alice! Welcome to mcp.zig."}}}
```

**echo("Hello World") response:**

```json
{"jsonrpc":"2.0","id":3,"result":{"content":[{"type":"text","text":"Hello World"}],"isError":false,"resultType":"complete","structuredContent":{"text":"Hello World"}}}
```

## Next Steps

- [Simple Client](/examples/simple-client)
- [Weather Server](/examples/weather-server)
- [Calculator Server](/examples/calculator-server)
