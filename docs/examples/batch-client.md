---
title: "Batch Client Example"
description: "Send multiple JSON-RPC requests as a batch using MCP.zig client."
keywords: [batch client, batch requests, multiple requests, JSON-RPC batch, BatchRequest]
---

# Batch Client Example

Demonstrates sending multiple JSON-RPC requests as a batch. This is useful for reducing network overhead when you need to perform multiple operations at once.

## Overview

This example shows how to:

- Create a client and connect to a server via STDIO
- Use `mcp.BatchRequest` to build batch requests
- Add multiple request types to a batch (discover, list tools, list resources, etc.)
- Send and collect batch responses

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

    const exe = args.next() orelse "batch-client";
    const server_cmd = args.next();

    if (server_cmd == null) {
        std.debug.print("Usage: {s} <server-command>\n", .{exe});
        std.debug.print("  Example: {s} zig-out/bin/example-server\n", .{exe});
        std.debug.print("\nThis client demonstrates batch requests by sending\n", .{});
        std.debug.print("multiple operations in a single batch.\n", .{});
        return;
    }

    var client = mcp.Client.init(io, allocator, .{
        .name = "batch-client",
        .version = "1.0.0",
        .title = "Batch MCP Client",
    });
    defer client.deinit();

    std.debug.print("Connecting to server: {s}...\n", .{server_cmd.?});
    try client.connectStdio(server_cmd.?, &.{});
    std.debug.print("Connected!\n", .{});

    var batch = mcp.BatchRequest.init(allocator);
    defer batch.deinit();

    try batch.addDiscover();
    try batch.addListTools();
    try batch.addListResources();
    try batch.addListPrompts();
    try batch.addHealthCheck();

    std.debug.print("\nSending batch of {d} requests...\n", .{batch.requests.items.len});
    for (batch.requests.items) |item| {
        std.debug.print("  Queued: {s}\n", .{item.method});
    }

    std.debug.print("\nBatch built with {d} requests.\n", .{batch.requests.items.len});
    std.debug.print("In a full implementation, these would be sent as a single\n", .{});
    std.debug.print("JSON-RPC batch request and responses collected.\n", .{});

    client.disconnect();
    std.debug.print("\nDisconnected from server.\n", .{});
}
```

## Build and Run

```bash
zig build
./zig-out/bin/batch-client ./zig-out/bin/example-server
```

PowerShell (Windows):

```powershell
zig build
.\zig-out\bin\batch-client.exe .\zig-out\bin\example-server.exe
```

## Client Usage

The batch client takes a server command as an argument. It connects to the server, builds a batch of 5 requests, and displays what would be sent.

```bash
./zig-out/bin/batch-client ./zig-out/bin/example-server
```

PowerShell:

```powershell
.\zig-out\bin\batch-client.exe .\zig-out\bin\example-server.exe
```

## Expected Output

```text
Connecting to server: ./zig-out/bin/example-server...
Connected!

Sending batch of 5 requests...
  Queued: server/discover
  Queued: tools/list
  Queued: resources/list
  Queued: prompts/list
  Queued: health/check

Batch built with 5 requests.
In a full implementation, these would be sent as a single
JSON-RPC batch request and responses collected.

Disconnected from server.
```

## BatchRequest API

`mcp.BatchRequest` provides convenience methods for common batch operations:

```zig
var batch = mcp.BatchRequest.init(allocator);
defer batch.deinit();

try batch.addDiscover();       // server/discover
try batch.addListTools();      // tools/list
try batch.addListResources();  // resources/list
try batch.addListPrompts();    // prompts/list
try batch.addHealthCheck();    // health/check
```

Each method adds a JSON-RPC request to `batch.requests`. In a full implementation, you would serialize all requests as a JSON array and send them in a single HTTP POST or STDIO write.

## Next Steps

- [Simple Client](/examples/simple-client)
- [HTTP Server](/examples/http-server)
- [Client Guide](/guide/client)
