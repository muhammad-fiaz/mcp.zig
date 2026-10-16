---
title: "Client API"
description: "MCP Client API reference — connect to servers, discover capabilities, call tools, read resources, and fetch prompts."
keywords: [MCP client, client API, connect, discover, tools, resources, prompts, capabilities]
---

# Client

The `Client` allows you to connect to MCP servers and interact with their capabilities.

## Creating a Client

```zig
const mcp = @import("mcp");

var client: mcp.Client = .init(io, allocator, .{
    .name = "my-client",
    .version = "1.0.0",
});
defer client.deinit();
```

## Configuration

| Option      | Type         | Description               |
| ----------- | ------------ | ------------------------- |
| `name`      | `[]const u8` | Client name (required)    |
| `version`   | `[]const u8` | Client version (required) |

## Connecting to a Server

### STDIO Transport

```zig
try client.connectStdio("path/to/server", &.{});
```

### HTTP Transport

```zig
// Connect to 127.0.0.1 on port 8080 (MCP endpoint is POST /mcp)
try client.connectHttp("http://127.0.0.1:8080/mcp");

// Connect to a custom host and port
try client.connectHttp("http://192.168.1.50:9000/mcp");
```

The HTTP client transport uses httpx.zig 0.2.2 (Zig 0.17.0).

## Capabilities

### Enable Roots

```zig
client.enableRoots(true);
```

### Enable Sampling

```zig
client.enableSampling();
```

## Using Tools

### List Available Tools

```zig
try client.listTools();
```

### Call a Tool

```zig
var args: std.json.ObjectMap = .empty;
try args.put(allocator, "name", .{ .string = "World" });

try client.callTool("greet", .{ .object = args });
```

## Using Resources

### List Resources

```zig
try client.listResources();
```

### Read a Resource

```zig
try client.readResource("file:///data.json");
```

## Using Prompts

### List Prompts

```zig
try client.listPrompts();
```

### Get a Prompt

```zig
var args: std.json.ObjectMap = .empty;
try args.put(allocator, "topic", .{ .string = "Zig programming" });

try client.getPrompt("summarize", .{ .object = args });
```

## Handling Responses

Request APIs are fire-and-forget: they send a JSON-RPC message and return
`!void`. Feed every received payload into `handleMessage`, which resolves the
matching pending request and stores the result for `takeResult`:

```zig
// Start a request; it returns the id it was sent under.
const id = try client.listToolsPage(null);

// Pump each payload from the transport.
if (client.transport) |t| {
    if (try t.receive(client.io, client.allocator)) |json| {
        try client.handleMessage(json);
    }
}

if (client.takeResult(id)) |raw| {
    defer client.allocator.free(raw);
    var parsed = try std.json.parseFromSlice(std.json.Value, client.allocator, raw, .{});
    defer parsed.deinit();
    std.debug.print("Tools: {any}\n", .{parsed.value});
}
```

`handleMessage` also validates the `resultType` discriminator. An absent one
is read as `"complete"` for earlier-protocol servers; an unrecognised value
returns `error.UnknownResultType`, because the base protocol says such a result
is invalid.

### Automatic MRTR rounds

`callToolResolved`, `readResourceResolved` and `getPromptResolved` start a
request that walks Multi Round-Trip Requests automatically. Supply an
`InputResolver`, pump messages as usual, and the client resolves each
`inputRequests` entry, echoes `requestState`, and retries under a new JSON-RPC
id until the server produces a final result:

```zig
const Resolver = struct {
    fn resolve(ctx: *anyopaque, allocator: std.mem.Allocator, key: []const u8, request: std.json.Value) anyerror!std.json.Value {
        // Ask the user, run an LLM, etc. The value is borrowed by the client
        // only for the duration of the round.
        _ = ctx;
        _ = allocator;
        _ = key;
        _ = request;
        var accept: std.json.ObjectMap = .empty;
        try accept.put(allocator, "action", .{ .string = "accept" });
        return .{ .object = accept };
    }
};

const id = try client.callToolResolved("needs_input", null, .{ .ctx = undefined, .resolve = Resolver.resolve });
```

Rounds are bounded by `client.max_mrtr_rounds`, so a server that keeps asking
fails with `error.MrtrRoundLimitExceeded` instead of looping forever.

### Notifications

Register a handler per method. Notifications delivered on a
`subscriptions/listen` stream also carry the subscription id, so several
concurrent streams can be told apart:

```zig
try client.onNotification("notifications/tools/list_changed", .{
    .ctx = undefined,
    .handle = struct {
        fn onChange(ctx: *anyopaque, params: std.json.ObjectMap, subscription_id: ?i64) void {
            _ = ctx;
            _ = params;
            std.debug.print("tools changed (subscription {?})\n", .{subscription_id});
        }
    }.onChange,
});
```

`params` borrows the receive buffer and is only valid for the duration of the
call; copy anything that has to outlive it.

## Managing Roots

Roots define the file system areas the client has access to:

```zig
try client.addRoot("file:///home/user/project", "Project Root");
try client.addRoot("file:///home/user/data", "Data Directory");
```

## Complete Example

```zig
const std = @import("std");
const mcp = @import("mcp");

pub fn main(init: std.process.Init) void {
    if (run(init.io, init.gpa)) {
        // Success
    } else |err| {
        mcp.reportError(err);
    }
}

fn run(io: std.Io, allocator: std.mem.Allocator) !void {
    var client: mcp.Client = .init(io, allocator, .{
        .name = "demo-client",
        .version = "1.0.0",
    });
    defer client.deinit();

    // Enable capabilities
    client.enableRoots(true);

    // Add roots
    try client.addRoot("file:///home/user/documents", "Documents");

    // Connect to a server
    try client.connectStdio("./my-server", &.{});

    // List and call tools
    try client.listTools();

    // Call a tool
    try client.callTool("hello", null);
}
```

## Next Steps

- [Server Guide](/guide/server) - Create servers to connect to
- [Tools Guide](/guide/tools) - Understand tool interactions
- [Examples](/examples/simple-client) - See complete client examples
