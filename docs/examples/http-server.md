---
title: "HTTP Server Example"
description: "Run an MCP server over HTTP with SSE support using MCP.zig."
keywords: [HTTP server, SSE, HTTP transport, streaming, hash_text tool, status resource, ping]
---

# HTTP Server

The HTTP server example runs an MCP server over HTTP instead of STDIO, with automatic
Server-Sent Events (SSE) fallback for clients that request streaming.

## Overview

This example demonstrates:

- HTTP transport with `127.0.0.1:8080`
- POST JSON-RPC to `/mcp` endpoint
- SSE support via `Accept: text/event-stream` header
- `ping` tool with optional message
- `hash_text` tool (FNV-1a 64-bit hash)
- Status resource at `/status`

## Full Source Code

```zig
const std = @import("std");
const mcp = @import("mcp");

pub fn main(init: std.process.Init) void {
    run(init.io, init.gpa) catch |err| mcp.reportError(err);
}

fn run(io: std.Io, allocator: std.mem.Allocator) !void {
    var sa_arena = std.heap.ArenaAllocator.init(allocator);
    defer sa_arena.deinit();
    const sa = sa_arena.allocator();

    const ping_schema = try buildPingSchema(sa);
    const hash_schema = try buildHashSchema(sa);

    var server = mcp.Server.init(allocator, .{
        .name = "http-server",
        .version = "1.0.0",
        .title = "HTTP MCP Server",
        .description = "An MCP server accessible over HTTP with SSE support",
        .instructions = "POST JSON-RPC to http://127.0.0.1:8080/mcp. Use 'ping' or 'hash_text'.",
    });
    defer server.deinit();

    try server.addTool(.{
        .name = "ping",
        .description = "Respond with 'pong' and optional custom message",
        .title = "Ping",
        .inputSchema = ping_schema,
        .annotations = .{ .readOnlyHint = true, .idempotentHint = true },
        .handler = pingHandler,
    });

    try server.addTool(.{
        .name = "hash_text",
        .description = "Compute a simple FNV-1a hash of the input text (returns hex string)",
        .title = "Hash Text",
        .inputSchema = hash_schema,
        .annotations = .{ .readOnlyHint = true, .idempotentHint = true },
        .handler = hashTextHandler,
    });

    try server.addResource(.{
        .uri = "http://localhost:8080/status",
        .name = "Server Status",
        .description = "Current server status",
        .mimeType = "application/json",
        .handler = statusHandler,
    });

    server.enableLogging();

    std.debug.print("HTTP MCP Server starting on http://127.0.0.1:8080\n", .{});

    try server.run(io, allocator, .{ .http = .{ .host = "127.0.0.1", .port = 8080 } });
}

fn buildPingSchema(allocator: std.mem.Allocator) !mcp.types.InputSchema {
    var b = mcp.schema.InputSchemaBuilder.init(allocator);
    defer b.deinit(allocator);
    _ = b.setSchemaDialect("https://json-schema.org/draft/2020-12/schema");
    _ = try b.addString(allocator, "message", "Optional custom message to echo back", false);
    return b.toInputSchema(allocator);
}

fn buildHashSchema(allocator: std.mem.Allocator) !mcp.types.InputSchema {
    var b = mcp.schema.InputSchemaBuilder.init(allocator);
    defer b.deinit(allocator);
    _ = b.setSchemaDialect("https://json-schema.org/draft/2020-12/schema");
    _ = try b.addString(allocator, "text", "Text to hash", true);
    return b.toInputSchema(allocator);
}

fn pingHandler(_: ?*anyopaque, _: std.Io, allocator: std.mem.Allocator, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    const msg = mcp.tools.getString(args, "message") orelse "";
    const reply = if (msg.len > 0)
        std.fmt.allocPrint(allocator, "pong: {s}", .{msg}) catch return mcp.tools.ToolError.OutOfMemory
    else
        allocator.dupe(u8, "pong") catch return mcp.tools.ToolError.OutOfMemory;
    return mcp.tools.textResult(allocator, reply) catch return mcp.tools.ToolError.OutOfMemory;
}

fn hashTextHandler(_: ?*anyopaque, _: std.Io, allocator: std.mem.Allocator, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    const text = mcp.tools.getString(args, "text") orelse
        return mcp.tools.errorResult(allocator, "Missing argument: text") catch return mcp.tools.ToolError.OutOfMemory;

    var h: u64 = 14695981039346656037;
    for (text) |byte| {
        h ^= @as(u64, byte);
        h = h *% 1099511628211;
    }

    const result = std.fmt.allocPrint(allocator, "{x:0>16}", .{h}) catch return mcp.tools.ToolError.OutOfMemory;
    return mcp.tools.textResult(allocator, result) catch return mcp.tools.ToolError.OutOfMemory;
}

fn statusHandler(_: ?*anyopaque, _: std.Io, _: std.mem.Allocator, uri: []const u8) mcp.resources.ResourceError!mcp.resources.ResourceContent {
    return .{
        .uri = uri,
        .mimeType = "application/json",
        .text = "{\"status\":\"ok\",\"server\":\"http-server\",\"version\":\"1.0.0\"}",
    };
}
```

## Build and Run

```bash
zig build
./zig-out/bin/http-server
```

PowerShell (Windows):

```powershell
zig build
.\zig-out\bin\http-server.exe
```

The server listens on `http://127.0.0.1:8080`.

## Client Usage

### Discover Server

```bash
curl -X POST http://127.0.0.1:8080/mcp \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","id":1,"method":"server/discover"}'
```

PowerShell:

```powershell
$body = '{"jsonrpc":"2.0","id":1,"method":"server/discover"}'
Invoke-RestMethod -Method Post -Uri http://127.0.0.1:8080/mcp -ContentType 'application/json' -Body $body
```

### List Tools

```bash
curl -X POST http://127.0.0.1:8080/mcp \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","id":2,"method":"tools/list"}'
```

### Call ping

```bash
curl -X POST http://127.0.0.1:8080/mcp \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"ping","arguments":{"message":"hello"}}}'
```

### Call hash_text

```bash
curl -X POST http://127.0.0.1:8080/mcp \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"hash_text","arguments":{"text":"mcp.zig"}}}'
```

## Expected Output

**ping("hello"):**

```json
{"jsonrpc":"2.0","id":3,"result":{"content":[{"type":"text","text":"pong: hello"}],"isError":false,"resultType":"complete","structuredContent":{"text":"pong: hello"}}}
```

**hash_text("mcp.zig"):**

```json
{"jsonrpc":"2.0","id":4,"result":{"content":[{"type":"text","text":"f80ddc2dcdd1e987"}],"isError":false,"resultType":"complete","structuredContent":{"text":"f80ddc2dcdd1e987"}}}
```

## HTTP Transport Configuration

```zig
try server.run(io, allocator, .{
    .http = .{
        .host = "127.0.0.1",  // Use 127.0.0.1, not "localhost"
        .port = 8080,
    }
});
```

## Security

- By default binds to `127.0.0.1` (localhost only)
- The HTTP transport validates `Origin` headers to prevent DNS rebinding attacks
- For production, add proper authentication via bearer tokens or API keys in your reverse proxy

## Next Steps

- [Simple Server](/examples/simple-server)
- [Transport Guide](/guide/transport)
- [Examples Overview](/examples/)
