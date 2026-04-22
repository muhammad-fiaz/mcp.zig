# Simple Client Example

A complete MCP client setup example using mcp.zig.

## Overview

This example demonstrates how to:

- create and initialize an MCP client
- enable client-side MCP capabilities
- configure roots for filesystem boundaries
- prepare for stdio and HTTP server connections

## Full Source Code

```zig
//! Simple MCP Client Example
//!
//! This example demonstrates how to create an MCP client
//! that connects to a server.

const std = @import("std");
const mcp = @import("mcp");

pub fn main() void {
    run() catch |err| {
        mcp.reportError(err);
    };
}

fn run() !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Get command line args for server path
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 2) {
        std.debug.print("Usage: {s} <server-command>\n", .{args[0]});
        std.debug.print("Example: {s} zig-out/bin/example-server\n", .{args[0]});
        return;
    }

    // Create client
    var client = mcp.Client.init(.{
        .name = "simple-client",
        .version = "1.0.0",
        .title = "Simple MCP Client",
        .allocator = allocator,
    });
    defer client.deinit();

    // Enable capabilities
    client.enableSampling();
    client.enableElicitation();
    client.enableTasks();
    client.enableRoots(true);

    // Add some roots
    try client.addRoot("file:///home/user/documents", "Documents");
    try client.addRoot("file:///home/user/projects", "Projects");

    std.debug.print("MCP Client initialized\n", .{});
    std.debug.print("Client: {s} v{s}\n", .{ client.config.name, client.config.version });
    std.debug.print("Roots configured: {d}\n", .{client.roots_list.items.len});

    // In a real implementation, you would:
    // 1. Connect to server: try client.connectStdio(args[1], &.{});
    // 2. List tools: try client.listTools();
    // 3. Call tools: try client.callTool("greet", args);
    // 4. Handle responses in an event loop

    std.debug.print("\nTo connect to a server, run:\n", .{});
    std.debug.print("  echo '{{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{{}}}}' | .\\zig-out\\bin\\example-server\n", .{});
}
```

## Client-Side API Explained

1. Client.init creates a client identity used during MCP initialize.
2. enableSampling enables model sampling capability negotiation.
3. enableElicitation enables user-input elicitation capability.
4. enableTasks enables task-related MCP methods.
5. enableRoots(true) enables roots capability and listChanged notification handling.
6. addRoot registers filesystem roots that the server may request.

## Connection APIs

For stdio servers:

```zig
try client.connectStdio("./zig-out/bin/example-server", &.{});
```

For HTTP servers:

```zig
try client.connectHttp("http://localhost:8080");
```

## Expected Console Output

When run with valid args, the program prints:

```text
MCP Client initialized
Client: simple-client v1.0.0
Roots configured: 2
```

## Build and Run

```bash
zig build
./zig-out/bin/example-client ./zig-out/bin/example-server
```

## Next Steps

- [Client Guide](/guide/client)
- [Transport Guide](/guide/transport)
- [Simple Server](/examples/simple-server)
