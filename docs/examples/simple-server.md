# Simple Server Example

A complete MCP server example with tools, resources, prompts, and logging.

## Overview

This example shows how to:

- create an MCP server
- register tools (greet, echo)
- register a resource (info://server/about)
- register a prompt (introduce)
- run over stdio (and optionally HTTP)

## Full Source Code

```zig
//! Simple MCP Server Example
//!
//! This example demonstrates how to create a basic MCP server
//! with tools, resources, and prompts.

const std = @import("std");
const mcp = @import("mcp");

pub fn main() void {
    run() catch |err| {
        mcp.reportError(err);
    };
}

fn run() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Check for updates in background
    if (mcp.report.checkForUpdates(allocator)) |t| t.detach();

    // Create server
    var server = mcp.Server.init(.{
        .name = "simple-server",
        .version = "1.0.0",
        .title = "Simple MCP Server",
        .description = "A simple example MCP server",
        .instructions = "This server provides basic greeting and echo tools.",
        .allocator = allocator,
    });
    defer server.deinit();

    // Add a greeting tool
    try server.addTool(.{
        .name = "greet",
        .description = "Greet a user by name",
        .title = "Greeting Tool",
        .annotations = .{
            .readOnlyHint = true,
            .idempotentHint = true,
            .destructiveHint = false,
        },
        .handler = greetHandler,
    });

    // Add an echo tool
    try server.addTool(.{
        .name = "echo",
        .description = "Echo back the input message",
        .title = "Echo Tool",
        .annotations = .{
            .readOnlyHint = true,
            .idempotentHint = true,
            .destructiveHint = false,
        },
        .handler = echoHandler,
    });

    // Add a simple resource
    try server.addResource(.{
        .uri = "info://server/about",
        .name = "About",
        .description = "Information about this server",
        .mimeType = "text/plain",
        .handler = aboutHandler,
    });

    // Add a prompt
    try server.addPrompt(.{
        .name = "introduce",
        .description = "Introduce the server capabilities",
        .title = "Introduction Prompt",
        .arguments = &[_]mcp.prompts.PromptArgument{
            .{ .name = "style", .description = "Introduction style (formal/casual)", .required = false },
        },
        .handler = introduceHandler,
    });

    // Enable logging
    server.enableLogging();
    server.enableTasks();

    // Run the server
    try server.run(.stdio);

    // To run with HTTP transport:
    // try server.run(.{ .http = .{ .host = "localhost", .port = 8080 } });
}

fn greetHandler(allocator: std.mem.Allocator, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    const name = mcp.tools.getString(args, "name") orelse "World";

    const greeting = std.fmt.allocPrint(allocator, "Hello, {s}! Welcome to MCP.", .{name}) catch return mcp.tools.ToolError.OutOfMemory;

    return mcp.tools.textResult(allocator, greeting) catch return mcp.tools.ToolError.OutOfMemory;
}

fn echoHandler(allocator: std.mem.Allocator, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    const message = mcp.tools.getString(args, "message") orelse "No message provided";

    // Demonstrate structured result
    var obj = std.json.ObjectMap.init(allocator);
    obj.put("echo", .{ .string = message }) catch {};
    obj.put("timestamp", .{ .integer = std.time.timestamp() }) catch {};

    return mcp.tools.structuredResult(allocator, .{ .object = obj }) catch return mcp.tools.ToolError.OutOfMemory;
}

fn aboutHandler(_: std.mem.Allocator, uri: []const u8) mcp.resources.ResourceError!mcp.resources.ResourceContent {
    return .{
        .uri = uri,
        .mimeType = "text/plain",
        .text = "Simple MCP Server v1.0.0\n\nThis is an example MCP server built with mcp.zig.",
    };
}

fn introduceHandler(allocator: std.mem.Allocator, args: ?std.json.Value) mcp.prompts.PromptError![]const mcp.prompts.PromptMessage {
    const style = mcp.prompts.getStringArg(args, "style") orelse "casual";
    _ = style;

    const messages = allocator.alloc(mcp.prompts.PromptMessage, 1) catch return mcp.prompts.PromptError.OutOfMemory;
    messages[0] = mcp.prompts.userMessage("Please introduce this MCP server and explain what tools it provides.");
    return messages;
}
```

## Manual Test Commands

Initialize over stdio:

```bash
echo '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"test","version":"1.0.0"}}}' | ./zig-out/bin/example-server
```

Call greet tool over stdio:

```bash
echo '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"greet","arguments":{"name":"Alice"}}}' | ./zig-out/bin/example-server
```

To test HTTP mode, switch `server.run(.stdio)` to HTTP in the source and then run:

```bash
curl -X POST http://localhost:8080 \
    -H "Content-Type: application/json" \
    -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"test","version":"1.0.0"}}}'
```

PowerShell HTTP initialize (HTTP mode):

```powershell
$body = '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"test","version":"1.0.0"}}}'
Invoke-RestMethod -Method Post -Uri http://localhost:8080 -ContentType 'application/json' -Body $body
```

## Expected Output Pattern

You should receive JSON-RPC responses containing:

- initialize result with server capabilities
- tools/call result with text content from the selected tool

## Next Steps

- [Weather Server](/examples/weather-server)
- [Calculator Server](/examples/calculator-server)
- [Server Guide](/guide/server)
