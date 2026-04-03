# Server API

The `Server` struct is the main component for building MCP servers.

## Constructor

### `Server.init`

```zig
pub fn init(config: ServerConfig) Server
```

Create a new MCP server.

**Parameters:**

| Field         | Type          | Description               |
| ------------- | ------------- | ------------------------- |
| `name`        | `[]const u8`  | Server name (required)    |
| `version`     | `[]const u8`  | Server version (required) |
| `allocator`   | `Allocator`   | Memory allocator          |
| `title`       | `?[]const u8` | Human-readable title      |
| `description` | `?[]const u8` | Server description        |

**Example:**

```zig
var server = mcp.Server.init(.{
    .name = "my-server",
    .version = "1.0.0",
    .allocator = allocator,
});
defer server.deinit();
```

---

## Lifecycle

### `Server.deinit`

```zig
pub fn deinit(self: *Server) void
```

Clean up server resources.

### `Server.run`

```zig
pub fn run(self: *Server, transport: TransportType) !void
```

Start the server with the specified transport.

**Transport Types:**

- `.stdio` - Standard I/O transport
- `.{ .http = .{ .port = u16 } }` - HTTP transport

**Example:**

```zig
try server.run(.stdio);
// or
try server.run(.{ .http = .{ .port = 8080 } });
```

---

## Capabilities

### `Server.enableTools`

```zig
pub fn enableTools(self: *Server) void
```

Enable the tools capability.

### `Server.enableResources`

```zig
pub fn enableResources(self: *Server, subscribe: bool) void
```

Enable the resources capability.

**Parameters:**

- `subscribe` - Enable subscription support for resource changes

### `Server.enablePrompts`

```zig
pub fn enablePrompts(self: *Server, listChanged: bool) void
```

Enable the prompts capability.

### `Server.enableLogging`

```zig
pub fn enableLogging(self: *Server) void
```

Enable the logging capability.

---

## Tools

### `Server.addTool`

```zig
pub fn addTool(self: *Server, tool: Tool) !void
```

Register a tool with the server.

**Tool struct:**

```zig
pub const Tool = struct {
    name: []const u8,
    description: ?[]const u8 = null,
    title: ?[]const u8 = null,
    inputSchema: ?types.InputSchema = null,
    outputSchema: ?types.OutputSchema = null,
    execution: ?types.ToolExecution = null,
    icons: ?[]const types.Icon = null,
    annotations: ?ToolAnnotations = null,
    handler: *const fn (allocator: std.mem.Allocator, arguments: ?std.json.Value) ToolError!ToolResult,
    user_data: ?*anyopaque = null,
};
```

**Example:**

```zig
try server.addTool(.{
    .name = "greet",
    .description = "Greet someone",
    .handler = greetHandler,
});
```

---

## Resources

### `Server.addResource`

```zig
pub fn addResource(self: *Server, resource: Resource) !void
```

Register a resource with the server.

**Resource struct:**

```zig
pub const Resource = struct {
    uri: []const u8,
    name: []const u8,
    title: ?[]const u8 = null,
    description: ?[]const u8 = null,
    mimeType: ?[]const u8 = null,
    icons: ?[]const types.Icon = null,
    annotations: ?types.Annotations = null,
    size: ?u64 = null,
    _meta: ?std.json.Value = null,
    handler: *const fn (allocator: std.mem.Allocator, uri: []const u8) ResourceError!ResourceContent,
    user_data: ?*anyopaque = null,
};
```

### `Server.addResourceTemplate`

```zig
pub fn addResourceTemplate(self: *Server, template: ResourceTemplate) !void
```

Register a resource template for dynamic URIs.

---

## Prompts

### `Server.addPrompt`

```zig
pub fn addPrompt(self: *Server, prompt: Prompt) !void
```

Register a prompt with the server.

**Prompt struct:**

```zig
pub const Prompt = struct {
    name: []const u8,
    title: ?[]const u8 = null,
    description: ?[]const u8 = null,
    arguments: ?[]const PromptArgument = null,
    icons: ?[]const types.Icon = null,
    _meta: ?std.json.Value = null,
    handler: *const fn (allocator: std.mem.Allocator, args: ?std.json.Value) PromptError![]const PromptMessage,
    user_data: ?*anyopaque = null,
};
```

---

## Message Handling

### `Server.handleMessage`

```zig
pub fn handleMessage(self: *Server, data: []const u8) !void
```

Process an incoming JSON-RPC message.

### `Server.sendResponse`

```zig
pub fn sendResponse(self: *Server, message: Message) !void
```

Send a JSON-RPC response.

---

## Complete Example

```zig
const std = @import("std");
const mcp = @import("mcp");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var server = mcp.Server.init(.{
        .name = "api-example-server",
        .version = "1.0.0",
        .description = "Demonstrates the full Server API",
        .allocator = allocator,
    });
    defer server.deinit();

    // Enable all capabilities
    server.enableTools();
    server.enableResources(true);
    server.enablePrompts(true);
    server.enableLogging();

    // Register components
    try server.addTool(.{
        .name = "echo",
        .description = "Echo back input",
        .handler = echoHandler,
    });

    try server.addResource(.{
        .uri = "file:///config.json",
        .name = "Configuration",
        .mimeType = "application/json",
        .handler = configHandler,
    });

    try server.addPrompt(.{
        .name = "summarize",
        .description = "Summarize text",
        .handler = summarizeHandler,
    });

    // Run
    try server.run(.stdio);
}
```
