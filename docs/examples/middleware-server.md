---
title: "Middleware Server Example"
description: "Build an MCP server with logging and authentication middleware using MCP.zig."
keywords: [middleware, logging, authentication, intercept, middleware chain, request logging]
---

# Middleware Server Example

Demonstrates using middleware to wrap tool handlers with logging, authentication, and custom logic. Shows how middleware can intercept and modify requests before they reach the actual handler.

## Overview

This example shows how to:

- Define a shared context struct (`Ctx`) for handler state
- Create a logging middleware that counts and logs every tool call
- Create an authentication middleware that can short-circuit requests
- Register tools that require authentication vs public tools
- Use `user_data` to pass context to handlers

## Full Source Code

```zig
const std = @import("std");
const mcp = @import("mcp");

const Ctx = struct {
    server: *mcp.Server,
    io: std.Io,
    allocator: std.mem.Allocator,
    request_count: u32 = 0,
    auth_token: ?[]const u8 = null,
};

fn loggingMiddleware(ctx: ?*anyopaque, io: std.Io, allocator: std.mem.Allocator, name: []const u8, args: ?std.json.Value) ?mcp.tools.ToolResult {
    _ = args;
    const c: *Ctx = @ptrCast(@alignCast(ctx.?));
    c.request_count += 1;
    std.debug.print("[MIDDLEWARE] Request #{d}: tool '{s}' called\n", .{ c.request_count, name });
    _ = io;
    _ = allocator;
    return null; // Continue to actual handler
}

fn authMiddleware(ctx: ?*anyopaque, io: std.Io, allocator: std.mem.Allocator, name: []const u8, args: ?std.json.Value) ?mcp.tools.ToolResult {
    _ = name;
    _ = args;
    const c: *Ctx = @ptrCast(@alignCast(ctx.?));
    if (c.auth_token == null) {
        std.debug.print("[MIDDLEWARE] Authentication failed: no token provided\n", .{});
        const result = mcp.tools.textResult(allocator, "Error: Authentication required") catch return null;
        _ = io;
        return result; // Short-circuit with error
    }
    std.debug.print("[MIDDLEWARE] Authentication passed\n", .{});
    _ = io;
    return null; // Continue to actual handler
}

pub fn main(init: std.process.Init) void {
    run(init.io, init.gpa) catch |err| mcp.reportError(err);
}

fn run(io: std.Io, allocator: std.mem.Allocator) !void {
    var server = mcp.Server.init(allocator, .{
        .name = "middleware-server",
        .version = "1.0.0",
        .title = "Middleware Server",
        .description = "Demonstrates middleware for logging and authentication",
    });
    defer server.deinit();

    var ctx: Ctx = .{
        .server = &server,
        .io = io,
        .allocator = allocator,
    };

    try server.addTool(.{
        .name = "protected_action",
        .description = "A tool that requires authentication",
        .user_data = &ctx,
        .handler = protectedActionHandler,
    });

    try server.addTool(.{
        .name = "public_action",
        .description = "A tool that doesn't require authentication",
        .user_data = &ctx,
        .handler = publicActionHandler,
    });

    server.enableLogging();
    try server.run(io, allocator, .stdio);
}

fn protectedActionHandler(user_data: ?*anyopaque, _: std.Io, allocator: std.mem.Allocator, _: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    const ctx: *Ctx = @ptrCast(@alignCast(user_data.?));
    _ = ctx;
    return mcp.tools.textResult(allocator, "Protected action executed successfully!") catch return mcp.tools.ToolError.OutOfMemory;
}

fn publicActionHandler(user_data: ?*anyopaque, _: std.Io, allocator: std.mem.Allocator, _: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    const ctx: *Ctx = @ptrCast(@alignCast(user_data.?));
    _ = ctx;
    return mcp.tools.textResult(allocator, "Public action executed successfully!") catch return mcp.tools.ToolError.OutOfMemory;
}
```

## Build and Run

```bash
zig build
./zig-out/bin/middleware-server
```

PowerShell (Windows):

```powershell
zig build
.\zig-out\bin\middleware-server.exe
```

## Client Usage

### Discover Server

```bash
echo '{"jsonrpc":"2.0","id":1,"method":"server/discover"}' | ./zig-out/bin/middleware-server
```

PowerShell:

```powershell
'{"jsonrpc":"2.0","id":1,"method":"server/discover"}' | .\zig-out\bin\middleware-server.exe
```

### Call a Tool

```bash
echo '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"public_action"}}' | ./zig-out/bin/middleware-server
```

PowerShell:

```powershell
'{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"public_action"}}' | .\zig-out\bin\middleware-server.exe
```

## Expected Output

**Discover response:**

```json
{"jsonrpc":"2.0","id":1,"result":{"supportedVersions":["2026-07-28","2025-11-25","2025-06-18","2025-03-26","2024-11-05"],"capabilities":{"tools":{"listChanged":true},"logging":{}},"serverInfo":{"name":"middleware-server","version":"1.0.0","title":"Middleware Server","description":"Demonstrates middleware for logging and authentication"}}}
```

**Tool call response:**

```json
{"jsonrpc":"2.0","id":2,"result":{"content":[{"type":"text","text":"Public action executed successfully!"}],"isError":false,"resultType":"complete","structuredContent":{"text":"Public action executed successfully!"}}}
```

**Console output (stderr):**

```text
[MIDDLEWARE] Request #1: tool 'public_action' called
[MIDDLEWARE] Authentication passed
```

## How Middleware Works

Middleware functions intercept tool calls before the actual handler runs:

1. **Logging middleware** increments a counter and prints the tool name, then returns `null` to continue to the handler
2. **Auth middleware** checks `ctx.auth_token` — if `null`, it returns an error result (short-circuit); otherwise returns `null` to continue

The middleware chain allows you to add cross-cutting concerns like logging, authentication, rate limiting, and request validation without modifying individual handlers.

## Next Steps

- [Rate Limiter Example](/examples/rate-limiter-example)
- [Validator Example](/examples/validator-example)
- [Server Guide](/guide/server)
