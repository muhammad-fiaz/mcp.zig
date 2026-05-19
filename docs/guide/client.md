# Client

The `Client` allows you to connect to MCP servers and interact with their capabilities.

## Creating a Client

```zig
const mcp = @import("mcp");

var client: mcp.Client = .init(io, allocator, .{
    .name = "my-client",
    .version = "1.0.0",
});
defer client.deinit(allocator);
```

## Configuration

| Option      | Type         | Description               |
| ----------- | ------------ | ------------------------- |
| `name`      | `[]const u8` | Client name (required)    |
| `version`   | `[]const u8` | Client version (required) |

## Connecting to a Server

### STDIO Transport

```zig
try client.connectStdio(io, allocator, "path/to/server", &.{});
```

### HTTP Transport

```zig
// Connect to localhost on port 8080
try client.connectHttp(io, allocator, "http://localhost:8080");

// Connect to a custom host and port
try client.connectHttp(io, allocator, "http://192.168.1.50:9000");
```

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
try client.listTools(io, allocator);
```

### Call a Tool

```zig
var args: std.json.ObjectMap = .empty;
try args.put(allocator, "name", .{ .string = "World" });

try client.callTool(io, allocator, "greet", .{ .object = args });
```

## Using Resources

### List Resources

```zig
try client.listResources(io, allocator);
```

### Read a Resource

```zig
try client.readResource(io, allocator, "file:///data.json");
```

## Using Prompts

### List Prompts

```zig
try client.listPrompts(io, allocator);
```

### Get a Prompt

```zig
var args: std.json.ObjectMap = .empty;
try args.put(allocator, "topic", .{ .string = "Zig programming" });

try client.getPrompt(io, allocator, "summarize", .{ .object = args });
```

## Handling Responses

All request APIs send JSON-RPC messages and return `!void`. To read responses,
use the underlying transport and parse the incoming messages:

```zig
try client.listTools(io, allocator);

if (client.transport) |t| {
    if (try t.receive(io, allocator)) |json| {
        const parsed = try mcp.jsonrpc.parseMessage(allocator, json);
        defer parsed.deinit();

        switch (parsed.message) {
            .response => |resp| {
                std.debug.print("Response: {any}\n", .{resp.result});
            },
            .error_response => |err| {
                std.debug.print("Error: {s}\n", .{err.@"error".message});
            },
            else => {},
        }
    }
}
```

## Managing Roots

Roots define the file system areas the client has access to:

```zig
try client.addRoot(allocator, "file:///home/user/project", "Project Root");
try client.addRoot(allocator, "file:///home/user/data", "Data Directory");
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
    defer client.deinit(allocator);

    // Enable capabilities
    client.enableRoots(true);

    // Add roots
    try client.addRoot(allocator, "file:///home/user/documents", "Documents");

    // Connect to a server
    try client.connectStdio(io, allocator, "./my-server", &.{});

    // List and call tools
    const tools = try client.listTools(io, allocator);
    std.debug.print("Available tools: {d}\n", .{tools.len});

    // Call a tool
    const result = try client.callTool(io, allocator, "hello", null);
    std.debug.print("Result: {any}\n", .{result});
}
```

## Next Steps

- [Server Guide](/guide/server) - Create servers to connect to
- [Tools Guide](/guide/tools) - Understand tool interactions
- [Examples](/examples/simple-client) - See complete client examples
