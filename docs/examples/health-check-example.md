---
title: "Health Check Example"
description: "Demonstrate the built-in health check endpoint for MCP servers using MCP.zig."
keywords: [health check, health/check, server status, uptime, connections, monitoring]
---

# Health Check Example

Demonstrates the built-in health check endpoint. Every MCP server automatically responds to `health/check` requests with server status, uptime, and connection information.

## Overview

This example shows how to:

- Use the automatic `health/check` endpoint (no configuration needed)
- Query server status, uptime, and active connections
- Add tools alongside health checking
- Monitor server health from clients

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
        .name = "health-check-server",
        .version = "1.0.0",
        .title = "Health Check Server",
        .description = "Demonstrates the built-in health check endpoint",
        .instructions = "This server responds to health/check requests automatically.",
    });
    defer server.deinit();

    var ctx: Ctx = .{
        .server = &server,
        .io = io,
        .allocator = allocator,
    };

    try server.addTool(.{
        .name = "echo",
        .description = "Echo back the input",
        .user_data = &ctx,
        .handler = echoHandler,
    });

    server.enableLogging();
    try server.run(io, allocator, .stdio);
}

fn echoHandler(user_data: ?*anyopaque, _: std.Io, allocator: std.mem.Allocator, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    const ctx: *Ctx = @ptrCast(@alignCast(user_data.?));
    _ = ctx;
    const input = mcp.tools.getString(args, "input") orelse
        return mcp.tools.textResult(allocator, "No input provided") catch return mcp.tools.ToolError.OutOfMemory;
    return mcp.tools.textResult(allocator, input) catch return mcp.tools.ToolError.OutOfMemory;
}
```

## Build and Run

```bash
zig build
./zig-out/bin/health-check-example
```

PowerShell (Windows):

```powershell
zig build
.\zig-out\bin\health-check-example.exe
```

## Client Usage

### Health Check

```bash
echo '{"jsonrpc":"2.0","id":1,"method":"health/check"}' | ./zig-out/bin/health-check-example
```

PowerShell:

```powershell
'{"jsonrpc":"2.0","id":1,"method":"health/check"}' | .\zig-out\bin\health-check-example.exe
```

### Discover Server

```bash
echo '{"jsonrpc":"2.0","id":2,"method":"server/discover"}' | ./zig-out/bin/health-check-example
```

### Call Echo Tool

```bash
echo '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"echo","arguments":{"input":"Hello"}}}' | ./zig-out/bin/health-check-example
```

## Expected Output

**Health check response:**

```json
{"jsonrpc":"2.0","id":1,"result":{"status":"ready","serverInfo":{"name":"health-check-server","version":"1.0.0"},"uptime":0,"activeConnections":1}}
```

**Discover response:**

```json
{"jsonrpc":"2.0","id":2,"result":{"supportedVersions":["2026-07-28","2025-11-25","2025-06-18","2025-03-26","2024-11-05"],"capabilities":{"tools":{"listChanged":true},"logging":{}},"serverInfo":{"name":"health-check-server","version":"1.0.0","title":"Health Check Server","description":"Demonstrates the built-in health check endpoint"}}}
```

**Echo tool response:**

```json
{"jsonrpc":"2.0","id":3,"result":{"content":[{"type":"text","text":"Hello"}],"isError":false,"resultType":"complete","structuredContent":{"text":"Hello"}}}
```

## Health Check Fields

| Field | Description |
|-------|-------------|
| `status` | Server status: `"ready"`, `"shutting_down"`, or `"stopped"` |
| `serverInfo.name` | Server name from init config |
| `serverInfo.version` | Server version from init config |
| `uptime` | Seconds since server started |
| `activeConnections` | Number of active client connections |

## How It Works

The `health/check` endpoint is built into every MCP server — no configuration needed. Simply send a JSON-RPC request with method `"health/check"` and the server responds with status information automatically.

This is useful for:

- Load balancer health probes
- Monitoring dashboards
- Client connection validation
- Debugging server availability

## Next Steps

- [Shutdown Example](/examples/shutdown-example)
- [Server Guide](/guide/server)
- [Examples Overview](/examples/)
