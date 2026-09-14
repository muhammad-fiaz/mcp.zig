---
title: "Validator Example"
description: "Build an MCP server with request validation for tool arguments using MCP.zig."
keywords: [validator, request validation, input validation, required fields, RequestValidator]
---

# Validator Example

Demonstrates validating tool arguments against a schema. Shows how to ensure required fields are present before executing tool handlers.

## Overview

This example shows how to:

- Use `mcp.RequestValidator` to define required/optional fields
- Validate tool arguments before processing
- Return meaningful error messages for invalid input
- Combine validation with `user_data` context

## Full Source Code

```zig
const std = @import("std");
const mcp = @import("mcp");

const Ctx = struct {
    server: *mcp.Server,
    io: std.Io,
    allocator: std.mem.Allocator,
};

const create_user_validator = mcp.RequestValidator.init(
    &.{ "username", "email" }, // Required fields
    &.{ "age", "role" },       // Optional fields
);

const login_validator = mcp.RequestValidator.init(
    &.{ "username", "password" }, // Required fields
    &.{},                         // No optional fields
);

pub fn main(init: std.process.Init) void {
    run(init.io, init.gpa) catch |err| mcp.reportError(err);
}

fn run(io: std.Io, allocator: std.mem.Allocator) !void {
    var server = mcp.Server.init(allocator, .{
        .name = "validator-server",
        .version = "1.0.0",
        .title = "Validator Server",
        .description = "Demonstrates request validation",
        .instructions = "Tools validate their input arguments before execution.",
    });
    defer server.deinit();

    var ctx: Ctx = .{
        .server = &server,
        .io = io,
        .allocator = allocator,
    };

    try server.addTool(.{
        .name = "create_user",
        .description = "Create a new user (requires username and email)",
        .user_data = &ctx,
        .handler = createUserHandler,
    });

    try server.addTool(.{
        .name = "login",
        .description = "Login (requires username and password)",
        .user_data = &ctx,
        .handler = loginHandler,
    });

    server.enableLogging();
    try server.run(io, allocator, .stdio);
}

fn createUserHandler(_: ?*anyopaque, _: std.Io, allocator: std.mem.Allocator, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    if (create_user_validator.validate(args)) |error_msg| {
        const msg = std.fmt.allocPrint(allocator, "Validation error: {s}", .{error_msg}) catch
            return mcp.tools.ToolError.OutOfMemory;
        return mcp.tools.errorResult(allocator, msg) catch return mcp.tools.ToolError.OutOfMemory;
    }
    const username = mcp.tools.getString(args, "username") orelse
        return mcp.tools.errorResult(allocator, "Missing username") catch return mcp.tools.ToolError.OutOfMemory;
    const email = mcp.tools.getString(args, "email") orelse
        return mcp.tools.errorResult(allocator, "Missing email") catch return mcp.tools.ToolError.OutOfMemory;
    const msg = std.fmt.allocPrint(allocator, "User '{s}' created with email '{s}'", .{ username, email }) catch
        return mcp.tools.ToolError.OutOfMemory;
    return mcp.tools.textResult(allocator, msg) catch return mcp.tools.ToolError.OutOfMemory;
}

fn loginHandler(_: ?*anyopaque, _: std.Io, allocator: std.mem.Allocator, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    if (login_validator.validate(args)) |error_msg| {
        const msg = std.fmt.allocPrint(allocator, "Validation error: {s}", .{error_msg}) catch
            return mcp.tools.ToolError.OutOfMemory;
        return mcp.tools.errorResult(allocator, msg) catch return mcp.tools.ToolError.OutOfMemory;
    }
    const username = mcp.tools.getString(args, "username") orelse
        return mcp.tools.errorResult(allocator, "Missing username") catch return mcp.tools.ToolError.OutOfMemory;
    const msg = std.fmt.allocPrint(allocator, "User '{s}' logged in successfully", .{username}) catch
        return mcp.tools.ToolError.OutOfMemory;
    return mcp.tools.textResult(allocator, msg) catch return mcp.tools.ToolError.OutOfMemory;
}
```

## Build and Run

```bash
zig build
./zig-out/bin/validator-example
```

PowerShell (Windows):

```powershell
zig build
.\zig-out\bin\validator-example.exe
```

## Client Usage

### Create User (valid)

```bash
echo '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"create_user","arguments":{"username":"alice","email":"alice@example.com"}}}' | ./zig-out/bin/validator-example
```

### Create User (missing email — validation error)

```bash
echo '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"create_user","arguments":{"username":"bob"}}}' | ./zig-out/bin/validator-example
```

### Login (valid)

```bash
echo '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"login","arguments":{"username":"alice","password":"secret"}}}' | ./zig-out/bin/validator-example
```

### Login (missing password — validation error)

```bash
echo '{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"login","arguments":{"username":"alice"}}}' | ./zig-out/bin/validator-example
```

PowerShell:

```powershell
'{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"create_user","arguments":{"username":"alice","email":"alice@example.com"}}}' | .\zig-out\bin\validator-example.exe
```

## Expected Output

**Valid create_user:**

```json
{"jsonrpc":"2.0","id":1,"result":{"content":[{"type":"text","text":"User 'alice' created with email 'alice@example.com'"}],"isError":false,"resultType":"complete","structuredContent":{"text":"User 'alice' created with email 'alice@example.com'"}}}
```

**Invalid create_user (missing email):**

```json
{"jsonrpc":"2.0","id":2,"error":{"code":-32602,"message":"Tool not found"}}
```

**Valid login:**

```json
{"jsonrpc":"2.0","id":3,"result":{"content":[{"type":"text","text":"User 'alice' logged in successfully"}],"isError":false,"resultType":"complete","structuredContent":{"text":"User 'alice' logged in successfully"}}}
```

## How Validation Works

`mcp.RequestValidator` is initialized with required and optional field names:

```zig
const create_user_validator = mcp.RequestValidator.init(
    &.{ "username", "email" }, // Required fields
    &.{ "age", "role" },       // Optional fields
);
```

In the handler, call `validate()` before processing:

```zig
if (create_user_validator.validate(args)) |error_msg| {
    const msg = std.fmt.allocPrint(allocator, "Validation error: {s}", .{error_msg}) catch ...;
    return mcp.tools.errorResult(allocator, msg) catch ...;
}
```

The `validate()` method returns `null` if all required fields are present, or an error message string if validation fails.

## Next Steps

- [Rate Limiter Example](/examples/rate-limiter-example)
- [Middleware Server](/examples/middleware-server)
- [Tools Guide](/guide/tools)
