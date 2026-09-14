---
title: "Simple Client Example"
description: "Connect to an MCP server with a simple client using STDIO transport."
keywords: [simple client, MCP client example, client setup, roots, STDIO, capabilities]
---

# Simple Client Example

A complete MCP client setup example using mcp.zig.

## Overview

This example demonstrates how to:

- Create and initialize an MCP client with `mcp.Client.init`
- Enable client-side MCP capabilities (sampling, elicitation, tasks, roots)
- Configure roots for filesystem boundaries
- Connect to a server via STDIO
- Discover server capabilities, list tools, resources, and prompts

## Full Source Code

```zig
const std = @import("std");
const mcp = @import("mcp");

pub fn main(init: std.process.Init) void {
    run(init.io, init.gpa, init.minimal.args) catch |err| mcp.reportError(err);
}

fn run(io: std.Io, allocator: std.mem.Allocator, process_args: std.process.Args) !void {
    var args = try std.process.Args.Iterator.initAllocator(process_args, allocator);
    defer args.deinit();

    const exe = args.next() orelse "simple-client";
    const server_cmd = args.next();

    if (server_cmd == null) {
        std.debug.print("Usage: {s} <server-command>\n", .{exe});
        std.debug.print("  Example: {s} zig-out/bin/example-server\n", .{exe});
        std.debug.print("\nThis client will:\n", .{});
        std.debug.print("  1. Connect to the server via STDIO\n", .{});
        std.debug.print("  2. Discover server capabilities\n", .{});
        std.debug.print("  3. List available tools\n", .{});
        std.debug.print("  4. Read available resources\n", .{});
        std.debug.print("  5. List available prompts\n", .{});
        return;
    }

    var client = mcp.Client.init(io, allocator, .{
        .name = "simple-client",
        .version = "1.0.0",
        .title = "Simple MCP Client",
        .description = "A simple client that demonstrates basic MCP operations",
    });
    defer client.deinit();

    client.enableSamplingAdvanced(true, true);
    client.enableElicitation();
    client.enableTasksAdvanced(true, true);
    client.enableRoots(true);

    try client.addRoot("file:///tmp", "Temp");

    std.debug.print("Connecting to server: {s}...\n", .{server_cmd.?});
    try client.connectStdio(server_cmd.?, &.{});
    std.debug.print("Connected!\n", .{});

    std.debug.print("\nDiscovering server capabilities...\n", .{});
    try client.discover();
    std.debug.print("Discovery complete!\n", .{});

    std.debug.print("\nListing available tools...\n", .{});
    try client.listTools();
    std.debug.print("Tools listed!\n", .{});

    std.debug.print("\nListing available resources...\n", .{});
    try client.listResources();
    std.debug.print("Resources listed!\n", .{});

    std.debug.print("\nListing available prompts...\n", .{});
    try client.listPrompts();
    std.debug.print("Prompts listed!\n", .{});

    client.disconnect();
    std.debug.print("\nDisconnected from server.\n", .{});
}
```

## Build and Run

```bash
zig build
./zig-out/bin/example-client ./zig-out/bin/example-server
```

PowerShell (Windows):

```powershell
zig build
.\zig-out\bin\example-client.exe .\zig-out\bin\example-server.exe
```

## Client-Side API Explained

1. **`Client.init`** creates a client identity with io and allocator stored internally
2. **`enableSamplingAdvanced`** enables sampling with context and tool use support
3. **`enableElicitation`** enables user-input elicitation capability
4. **`enableTasksAdvanced`** enables task-related MCP methods (including request augmentation)
5. **`enableRoots(true)`** enables roots capability and listChanged notification handling
6. **`addRoot`** registers filesystem roots that the server may request

## Connection APIs

For STDIO servers:

```zig
try client.connectStdio("./zig-out/bin/example-server", &.{});
```

For HTTP servers:

```zig
try client.connectHttp("http://127.0.0.1:8080/mcp");
```

## Expected Console Output

When run with a valid server command, the program prints:

```text
Connecting to server: ./zig-out/bin/example-server...
Connected!

Discovering server capabilities...
Discovery complete!

Listing available tools...
Tools listed!

Listing available resources...
Resources listed!

Listing available prompts...
Prompts listed!

Disconnected from server.
```

## Next Steps

- [Batch Client](/examples/batch-client)
- [Client Guide](/guide/client)
- [Transport Guide](/guide/transport)
