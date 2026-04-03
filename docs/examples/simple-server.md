# Simple Server Example

A minimal MCP server that demonstrates basic functionality.

## Overview

This example shows how to:

- Create an MCP server
- Register a simple tool
- Run the server with STDIO transport

## Source Code

```zig
//! Simple MCP Server Example
//!
//! A basic server that demonstrates core MCP functionality.

const std = @import("std");
const mcp = @import("mcp");

pub fn main() void {
    if (run()) {
        // Success
    } else |err| {
        mcp.reportError(err);
    }
}

fn run() !void {
    // Initialize allocator
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Check for updates
    if (mcp.report.checkForUpdates(allocator)) |t| t.detach();

    // Create the server
    var server = mcp.Server.init(.{
        .name = "simple-server",
        .version = "1.0.0",
        .allocator = allocator,
    });
    defer server.deinit();

    // Enable capabilities
    server.enableTools();

    // Register a greeting tool
    try server.addTool(.{
        .name = "greet",
        .description = "Greet someone with a friendly message",
        .handler = greetHandler,
    });

    // Run the server
    try server.run(.stdio);
}

fn greetHandler(
    allocator: std.mem.Allocator,
    args: ?std.json.Value,
) mcp.tools.ToolError!mcp.tools.ToolResult {
    // Get the name argument, default to "World"
    const name = mcp.tools.getString(args, "name") orelse "World";

    // Create greeting message
    const message = try std.fmt.allocPrint(
        allocator,
        "Hello, {s}! Welcome to MCP.",
        .{name},
    );

    return mcp.tools.ToolResult{
        .content = &.{mcp.Content.createText(message)},
    };
}
```

## Running the Example

### Build

```bash
zig build
```

### Run

```bash
./zig-out/bin/example-server
```

### Test with JSON-RPC

Send an initialize request:

```bash
echo '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"test","version":"1.0.0"}}}' | ./zig-out/bin/example-server
```

Call the greet tool:

```bash
echo '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"greet","arguments":{"name":"Alice"}}}' | ./zig-out/bin/example-server
```

## Testing with Claude Desktop

Add to your Claude Desktop configuration:

```json
{
  "mcpServers": {
    "simple-server": {
      "command": "/path/to/zig-out/bin/example-server"
    }
  }
}
```

Then restart Claude Desktop and try asking it to greet someone!

## Key Concepts

### Server Initialization

The server requires a name and version. The allocator is used for all runtime allocations.

### Tool Registration

Tools are registered with:

- `name`: Unique identifier
- `description`: Human-readable description
- `handler`: Function to execute

### Tool Handlers

Handlers receive:

- `allocator`: For any allocations needed
- `args`: JSON arguments from the client

And return a `ToolResult` with content.

## Next Steps

- [Weather Server](/examples/weather-server) - A more complex example
- [Calculator Server](/examples/calculator-server) - Input validation
- [Server Guide](/guide/server) - Deep dive into server features
