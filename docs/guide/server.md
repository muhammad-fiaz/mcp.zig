# Server

The Server is the main runtime component for exposing MCP capabilities to AI clients.

## Creating a Server

```zig
const mcp = @import("mcp");

var server = mcp.Server.init(.{
    .name = "my-server",
    .version = "1.0.0",
    .allocator = allocator,
});
defer server.deinit();
```

## Configuration

| Option | Type | Description |
| --- | --- | --- |
| name | []const u8 | Server name (required) |
| version | []const u8 | Server version (required) |
| allocator | std.mem.Allocator | Memory allocator |
| title | ?[]const u8 | Human-readable title |
| description | ?[]const u8 | Server description |
| instructions | ?[]const u8 | Optional server usage instructions |

## Capabilities

Capabilities are enabled by registration and explicit toggles:

```zig
try server.addTool(tool);
try server.addResource(resource);
try server.addPrompt(prompt);

server.enableLogging();
server.enableCompletions();
server.enableTasks();
```

## Running the Server

### STDIO Transport

For command-line tools and local processes:

```zig
try server.run(.stdio);
```

### HTTP Transport

For remote access:

```zig
try server.run(.{ .http = .{ .host = "127.0.0.1", .port = 8080 } });
```

You can also bind custom domains/hosts and ports:

```zig
try server.run(.{ .http = .{ .host = "api.example.com", .port = 8443 } });
```

The HTTP mode accepts JSON-RPC POST requests at the root path.

## Registering Components

### Tools

```zig
try server.addTool(.{
    .name = "calculate",
    .description = "Perform calculations",
    .handler = calcHandler,
});
```

### Resources

```zig
try server.addResource(.{
    .uri = "file:///data.json",
    .name = "Data File",
    .mimeType = "application/json",
    .handler = dataHandler,
});
```

### Prompts

```zig
try server.addPrompt(.{
    .name = "summarize",
    .description = "Summarize text",
    .handler = summarizeHandler,
});
```

## Error Handling

The server handles errors gracefully:

```zig
fn toolHandler(allocator: Allocator, args: ?json.Value) ToolError!ToolResult {
    const message = mcp.tools.getString(args, "message") orelse {
        return mcp.tools.errorResult(allocator, "Missing required argument: message") catch return mcp.tools.ToolError.OutOfMemory;
    };

    return mcp.tools.textResult(allocator, message) catch return mcp.tools.ToolError.OutOfMemory;
}
```

## Complete Example

```zig
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

    var server = mcp.Server.init(.{
        .name = "demo-server",
        .version = "1.0.0",
        .description = "A demo MCP server",
        .allocator = allocator,
    });
    defer server.deinit();

    // Register at least one tool/resource/prompt.
    try server.addTool(.{
        .name = "echo",
        .description = "Echo back the input",
        .handler = echoHandler,
    });

    // Run
    server.enableLogging();
    try server.run(.stdio);
}

fn echoHandler(
    allocator: std.mem.Allocator,
    args: ?std.json.Value,
) mcp.tools.ToolError!mcp.tools.ToolResult {
    const text = mcp.tools.getString(args, "text") orelse "No input";
    const result = try std.fmt.allocPrint(allocator, "Echo: {s}", .{text});

    return mcp.tools.textResult(allocator, result);
}
```

## Next Steps

- [Tools Guide](/guide/tools) - Creating powerful tools
- [Resources Guide](/guide/resources) - Exposing data resources
- [Examples](/examples/simple-server) - Complete server examples
