---
title: "Code Examples"
description: "MCP.zig code examples — complete working servers and clients for learning and reference."
keywords: [examples, code examples, sample projects, demo, working examples, MCP server examples, MCP client examples]
---

# Examples

Explore these complete, working examples to learn how to use mcp.zig effectively.

## Available Examples

### Servers

#### [Simple Server](/examples/simple-server)

A minimal MCP server with greeting and echo tools, a resource, and a prompt.

#### [Weather Server](/examples/weather-server)

A multi-tool server with InputSchema constraints, resource templates, and task support.

#### [Calculator Server](/examples/calculator-server)

Arithmetic tools with structured output schemas, annotations, and task-enabled division.

#### [Advanced Server](/examples/advanced-server)

Full feature showcase: JSON Schema 2020-12, icons, output schemas, task support, prompts.

#### [Filesystem Server](/examples/filesystem-server)

Read files and list directories. Demonstrates real file I/O inside tool handlers.

#### [Notes Server](/examples/notes-server)

Stateful server storing in-memory notes. Shows `user_data` context, list-change notifications.

#### [HTTP Server](/examples/http-server)

HTTP transport with SSE support. Includes `ping` and `hash_text` tools and a status resource.

#### [Middleware Server](/examples/middleware-server)

Logging and authentication middleware that intercepts tool calls.

#### [Health Check Example](/examples/health-check-example)

Built-in `health/check` endpoint for server status, uptime, and connections.

#### [Shutdown Example](/examples/shutdown-example)

Graceful shutdown of an MCP server via a `shutdown` tool.

#### [Validator Example](/examples/validator-example)

Request validation for tool arguments using `RequestValidator`.

#### [Rate Limiter Example](/examples/rate-limiter-example)

Rate limiting for tool calls using `RateLimiter`.

### Clients

#### [Simple Client](/examples/simple-client)

A basic MCP client demonstrating capability declaration, roots, and server discovery.

#### [Batch Client](/examples/batch-client)

Sends multiple JSON-RPC requests as a batch using `BatchRequest`.

## Running Examples

All examples are included in the `examples/` directory of the repository.

### Build All Examples

```bash
zig build
```

### Run a Server Example

```bash
# Simple server
./zig-out/bin/example-server

# Weather server
./zig-out/bin/weather-server

# Calculator
./zig-out/bin/calculator-server

# Advanced server
./zig-out/bin/advanced-server

# Filesystem server
./zig-out/bin/filesystem-server

# Notes server
./zig-out/bin/notes-server

# HTTP server
./zig-out/bin/http-server

# Middleware server
./zig-out/bin/middleware-server

# Health check
./zig-out/bin/health-check-example

# Shutdown
./zig-out/bin/shutdown-example

# Validator
./zig-out/bin/validator-example

# Rate limiter
./zig-out/bin/rate-limiter-example
```

PowerShell (Windows):

```powershell
.\zig-out\bin\example-server.exe
.\zig-out\bin\weather-server.exe
.\zig-out\bin\calculator-server.exe
.\zig-out\bin\advanced-server.exe
.\zig-out\bin\filesystem-server.exe
.\zig-out\bin\notes-server.exe
.\zig-out\bin\http-server.exe
.\zig-out\bin\middleware-server.exe
.\zig-out\bin\health-check-example.exe
.\zig-out\bin\shutdown-example.exe
.\zig-out\bin\validator-example.exe
.\zig-out\bin\rate-limiter-example.exe
```

### Run a Client Example

```bash
# Simple client (connects to a server)
./zig-out/bin/example-client ./zig-out/bin/example-server

# Batch client
./zig-out/bin/batch-client ./zig-out/bin/example-server
```

PowerShell (Windows):

```powershell
.\zig-out\bin\example-client.exe .\zig-out\bin\example-server.exe
.\zig-out\bin\batch-client.exe .\zig-out\bin\example-server.exe
```

## Testing with an AI Client

You can test your MCP server with Claude Desktop or other MCP-compatible AI clients.

### Claude Desktop Configuration

Add to your Claude Desktop config (usually at `~/.config/claude/config.json`):

```json
{
  "mcpServers": {
    "my-server": {
      "command": "/path/to/zig-out/bin/example-server"
    }
  }
}
```

### Manual Testing with curl (HTTP Server)

```bash
# Start the HTTP server
./zig-out/bin/http-server

# Discover
curl -X POST http://127.0.0.1:8080/mcp \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","id":1,"method":"server/discover"}'

# Call ping
curl -X POST http://127.0.0.1:8080/mcp \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"ping","arguments":{"message":"hello"}}}'
```

## Project Structure

```
examples/
├── simple_server.zig          # Minimal server (greet, echo)
├── simple_client.zig          # Client with roots and capabilities
├── weather_server.zig         # Weather tools + resource template
├── calculator_server.zig      # Arithmetic with output schemas
├── advanced_server.zig        # Full feature showcase
├── filesystem_server.zig      # File I/O via tools and resources
├── notes_server.zig           # Stateful notes store (user_data)
├── http_server.zig            # HTTP transport + SSE example
├── middleware_server.zig      # Logging and auth middleware
├── health_check_example.zig   # Built-in health/check endpoint
├── shutdown_example.zig       # Graceful shutdown
├── validator_example.zig      # Request validation
├── rate_limiter_example.zig   # Rate limiting
└── batch_client.zig           # Batch JSON-RPC requests
```

## Creating Your Own Examples

1. Create a new file in the `examples/` directory
2. Add it to `build.zig`
3. Import `mcp` and start building!

```zig
const std = @import("std");
const mcp = @import("mcp");

pub fn main(init: std.process.Init) void {
    run(init.io, init.gpa) catch |err| mcp.reportError(err);
}

fn run(io: std.Io, allocator: std.mem.Allocator) !void {
    var server = mcp.Server.init(allocator, .{
        .name = "my-server",
        .version = "1.0.0",
    });
    defer server.deinit();

    // Add tools, resources, prompts...
    try server.addTool(.{
        .name = "my_tool",
        .description = "Does something useful",
        .handler = myHandler,
    });

    try server.run(io, allocator, .stdio);
}

fn myHandler(_: ?*anyopaque, _: std.Io, allocator: std.mem.Allocator, _: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    return mcp.tools.textResult(allocator, "Hello from my tool!") catch return mcp.tools.ToolError.OutOfMemory;
}
```
