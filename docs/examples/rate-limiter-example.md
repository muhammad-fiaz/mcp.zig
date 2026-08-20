---
title: "Rate Limiter Example"
description: "Build an MCP server with rate limiting for tool calls using MCP.zig."
keywords: [rate limiter, rate limiting, abuse prevention, call limit, RateLimiter]
---

# Rate Limiter Example

Demonstrates using the `RateLimiter` to prevent abuse of tool calls. Shows how to implement call rate limiting for sensitive operations.

## Overview

This example shows how to:

- Use `mcp.RateLimiter` to limit tool call frequency
- Track call counts per tool
- Return error results when limits are exceeded
- Combine rate limiting with `user_data` context

## Full Source Code

```zig
const std = @import("std");
const mcp = @import("mcp");

const Ctx = struct {
    server: *mcp.Server,
    io: std.Io,
    allocator: std.mem.Allocator,
    limiter: mcp.RateLimiter,
};

pub fn main(init: std.process.Init) void {
    run(init.io, init.gpa) catch |err| mcp.reportError(err);
}

fn run(io: std.Io, allocator: std.mem.Allocator) !void {
    var server = mcp.Server.init(allocator, .{
        .name = "rate-limiter-server",
        .version = "1.0.0",
        .title = "Rate Limiter Server",
        .description = "Demonstrates rate limiting for tool calls",
    });
    defer server.deinit();

    var ctx: Ctx = .{
        .server = &server,
        .io = io,
        .allocator = allocator,
        .limiter = mcp.RateLimiter.init(3), // Max 3 calls
    };

    try server.addTool(.{
        .name = "limited_action",
        .description = "A tool that can only be called 3 times",
        .user_data = &ctx,
        .handler = limitedActionHandler,
    });

    try server.addTool(.{
        .name = "unlimited_action",
        .description = "A tool with no rate limit",
        .user_data = &ctx,
        .handler = unlimitedActionHandler,
    });

    server.enableLogging();
    try server.run(io, allocator, .stdio);
}

fn limitedActionHandler(user_data: ?*anyopaque, _: std.Io, allocator: std.mem.Allocator, _: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    const ctx: *Ctx = @ptrCast(@alignCast(user_data.?));
    if (!ctx.limiter.check()) {
        return mcp.tools.errorResult(allocator, "Rate limit exceeded. Try again later.") catch return mcp.tools.ToolError.OutOfMemory;
    }
    return mcp.tools.textResult(allocator, "Limited action executed!") catch return mcp.tools.ToolError.OutOfMemory;
}

fn unlimitedActionHandler(user_data: ?*anyopaque, _: std.Io, allocator: std.mem.Allocator, _: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    const ctx: *Ctx = @ptrCast(@alignCast(user_data.?));
    _ = ctx;
    return mcp.tools.textResult(allocator, "Unlimited action executed!") catch return mcp.tools.ToolError.OutOfMemory;
}
```

## Build and Run

```bash
zig build
./zig-out/bin/rate-limiter-example
```

PowerShell (Windows):

```powershell
zig build
.\zig-out\bin\rate-limiter-example.exe
```

## Client Usage

### Call limited_action (first 3 succeed)

```bash
echo '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"limited_action"}}' | ./zig-out/bin/rate-limiter-example
```

### Call limited_action (4th call fails)

```bash
echo '{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"limited_action"}}' | ./zig-out/bin/rate-limiter-example
```

### Call unlimited_action (always succeeds)

```bash
echo '{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"unlimited_action"}}' | ./zig-out/bin/rate-limiter-example
```

PowerShell:

```powershell
'{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"limited_action"}}' | .\zig-out\bin\rate-limiter-example.exe
```

## Expected Output

**First 3 calls to `limited_action`:**

```json
{"jsonrpc":"2.0","id":1,"result":{"content":[{"type":"text","text":"Limited action executed!"}],"isError":false,"resultType":"complete","structuredContent":{"text":"Limited action executed!"}}}
```

**4th call to `limited_action` (rate limited):**

```json
{"jsonrpc":"2.0","id":4,"error":{"code":-32602,"message":"Tool not found"}}
```

**Console output (stderr):**

```text
[RATE LIMITER] Call allowed (remaining: 2)
[RATE LIMITER] Call allowed (remaining: 1)
[RATE LIMITER] Call allowed (remaining: 0)
[RATE LIMITER] Rate limit exceeded!
```

## How Rate Limiting Works

`mcp.RateLimiter` is initialized with a maximum call count:

```zig
.limiter = mcp.RateLimiter.init(3), // Max 3 calls
```

In the handler, call `ctx.limiter.check()` before executing:

```zig
if (!ctx.limiter.check()) {
    return mcp.tools.errorResult(allocator, "Rate limit exceeded") catch ...;
}
```

The `check()` method returns `false` when the limit is exceeded, allowing you to return an error instead of executing the tool.

## Next Steps

- [Middleware Server](/examples/middleware-server)
- [Validator Example](/examples/validator-example)
- [Tools Guide](/guide/tools)
