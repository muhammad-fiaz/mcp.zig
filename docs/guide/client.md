# Client

The `Client` allows you to connect to MCP servers and interact with their capabilities.

## Creating a Client

```zig
const mcp = @import("mcp");

var client = mcp.Client.init(.{
    .name = "my-client",
    .version = "1.0.0",
    .allocator = allocator,
});
defer client.deinit();
```

## Configuration

| Option      | Type         | Description               |
| ----------- | ------------ | ------------------------- |
| `name`      | `[]const u8` | Client name (required)    |
| `version`   | `[]const u8` | Client version (required) |
| `allocator` | `Allocator`  | Memory allocator          |

## Connecting to a Server

### STDIO Transport

### STDIO Transport

```zig
try client.connectStdio("path/to/server", &.{});
```

### HTTP Transport

```zig
// Connect to localhost on port 8080
try client.connectHttp("http://localhost:8080");

// Connect to a custom host and port
try client.connectHttp("http://192.168.1.50:9000");
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
const tools = try client.listTools();
for (tools) |tool| {
    std.debug.print("Tool: {s}\n", .{tool.name});
}
```

### Call a Tool

```zig
var args = std.json.ObjectMap.init(allocator);
try args.put("name", .{ .string = "World" });

const result = try client.callTool("greet", .{ .object = args });

for (result.content) |content| {
    if (content == .text) {
        std.debug.print("{s}\n", .{content.text.text});
    }
}
```

## Using Resources

### List Resources

```zig
const resources = try client.listResources();
for (resources) |resource| {
    std.debug.print("Resource: {s}\n", .{resource.uri});
}
```

### Read a Resource

```zig
const contents = try client.readResource("file:///data.json");
for (contents) |content| {
    std.debug.print("Content: {s}\n", .{content.text.text});
}
```

## Using Prompts

### List Prompts

```zig
const prompts = try client.listPrompts();
for (prompts) |prompt| {
    std.debug.print("Prompt: {s}\n", .{prompt.name});
}
```

### Get a Prompt

```zig
var args = std.json.ObjectMap.init(allocator);
try args.put("topic", .{ .string = "Zig programming" });

const result = try client.getPrompt("summarize", .{ .object = args });

for (result.messages) |message| {
    std.debug.print("[{s}]: {s}\n", .{
        message.role,
        message.content.text.text,
    });
}
```

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

pub fn main() void {
    if (run()) {
        // Success
    } else |err| {
        mcp.reportError(err);
    }
}

fn run() !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var client = mcp.Client.init(.{
        .name = "demo-client",
        .version = "1.0.0",
        .allocator = allocator,
    });
    defer client.deinit();

    // Enable capabilities
    client.enableRoots(true);

    // Add roots
    try client.addRoot("file:///home/user/documents", "Documents");

    // Connect to a server
    try client.connectStdio("./my-server", &.{});

    // List and call tools
    const tools = try client.listTools();
    std.debug.print("Available tools: {d}\n", .{tools.len});

    // Call a tool
    const result = try client.callTool("hello", null);
    std.debug.print("Result: {any}\n", .{result});
}
```

## Next Steps

- [Server Guide](/guide/server) - Create servers to connect to
- [Tools Guide](/guide/tools) - Understand tool interactions
- [Examples](/examples/simple-client) - See complete client examples
