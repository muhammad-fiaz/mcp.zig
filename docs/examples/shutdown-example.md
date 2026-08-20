---
title: "Graceful Shutdown Example"
description: "Demonstrate graceful shutdown of an MCP server using MCP.zig."
keywords: [graceful shutdown, server shutdown, shutdown, stop server, clean exit]
---

# Graceful Shutdown Example

Demonstrates graceful shutdown of an MCP server. Shows how to properly shut down the server after processing the current request.

## Overview

This example shows how to:

- Call `server.shutdown()` from a tool handler
- Process the current request before shutting down
- Use the `shutdown` tool to trigger clean server exit
- Combine normal tools with a shutdown tool

## Full Source Code

```zig
const std = @import("std");
const mcp = @import("mcp");

const Ctx = struct {
    server: *mcp.Server,
    io: std.Io,
    allocator: std.mem.Allocator,
};

pub fn main(init: std.process.Init) void {
    run(init.io, init.gpa) catch |err| mcp.reportError(err);
}

fn run(io: std.Io, allocator: std.mem.Allocator) !void {
    var server = mcp.Server.init(allocator, .{
        .name = "shutdown-server",
        .version = "1.0.0",
        .title = "Shutdown Server",
        .description = "Demonstrates graceful shutdown",
        .instructions = "Call 'shutdown' tool to gracefully stop the server.",
    });
    defer server.deinit();

    var ctx: Ctx = .{
        .server = &server,
        .io = io,
        .allocator = allocator,
    };

    try server.addTool(.{
        .name = "shutdown",
        .description = "Gracefully shutdown the server",
        .user_data = &ctx,
        .handler = shutdownHandler,
    });

    try server.addTool(.{
        .name = "process",
        .description = "Process some data",
        .user_data = &ctx,
        .handler = processHandler,
    });

    server.enableLogging();
    try server.run(io, allocator, .stdio);
}

fn shutdownHandler(user_data: ?*anyopaque, _: std.Io, allocator: std.mem.Allocator, _: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    const ctx: *Ctx = @ptrCast(@alignCast(user_data.?));
    std.debug.print("Shutdown requested - server will stop after this request\n", .{});
    ctx.server.shutdown();
    return mcp.tools.textResult(allocator, "Server shutting down gracefully") catch return mcp.tools.ToolError.OutOfMemory;
}

fn processHandler(user_data: ?*anyopaque, _: std.Io, allocator: std.mem.Allocator, _: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    const ctx: *Ctx = @ptrCast(@alignCast(user_data.?));
    _ = ctx;
    return mcp.tools.textResult(allocator, "Data processed successfully") catch return mcp.tools.ToolError.OutOfMemory;
}
```

## Build and Run

```bash
zig build
./zig-out/bin/shutdown-example
```

PowerShell (Windows):

```powershell
zig build
.\zig-out\bin\shutdown-example.exe
```

## Client Usage

### Process Data (normal operation)

```bash
echo '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"process","arguments":{"input":"test"}}}' | ./zig-out/bin/shutdown-example
```

### Shutdown Server

```bash
echo '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"shutdown"}}' | ./zig-out/bin/shutdown-example
```

PowerShell:

```powershell
'{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"process","arguments":{"input":"test"}}}' | .\zig-out\bin\shutdown-example.exe
```

## Expected Output

**Process data response:**

```json
{"jsonrpc":"2.0","id":1,"result":{"content":[{"type":"text","text":"Data processed successfully"}],"isError":false,"resultType":"complete","structuredContent":{"text":"Data processed successfully"}}}
```

**Shutdown response:**

```json
{"jsonrpc":"2.0","id":2,"result":{"content":[{"type":"text","text":"Server shutting down gracefully"}],"isError":false,"resultType":"complete","structuredContent":{"text":"Server shutting down gracefully"}}}
```

**Console output (stderr):**

```text
Shutdown requested - server will stop after this request
```

After the shutdown tool is called, the server stops accepting new requests and exits cleanly.

## How Graceful Shutdown Works

Call `server.shutdown()` from any tool handler to trigger a graceful shutdown:

```zig
fn shutdownHandler(user_data: ?*anyopaque, _: std.Io, allocator: std.mem.Allocator, _: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    const ctx: *Ctx = @ptrCast(@alignCast(user_data.?));
    ctx.server.shutdown(); // Signals the server to stop
    return mcp.tools.textResult(allocator, "Server shutting down") catch ...;
}
```

The server:

1. Finishes processing the current request
2. Sends the response to the client
3. Stops the event loop
4. Returns from `server.run()`

This ensures no in-flight requests are dropped and resources are cleaned up properly.

## Next Steps

- [Health Check Example](/examples/health-check-example)
- [Server Guide](/guide/server)
- [Examples Overview](/examples/)
