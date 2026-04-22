# Client API

The `Client` struct is used to connect to MCP servers and send MCP requests.

## Constructor

### `Client.init`

```zig
pub fn init(config: ClientConfig) Client
```

Create a new MCP client.

**Parameters:**

| Field       | Type         | Description               |
| ----------- | ------------ | ------------------------- |
| `name`      | `[]const u8` | Client name (required)    |
| `version`   | `[]const u8` | Client version (required) |
| `allocator` | `Allocator`  | Memory allocator          |

**Example:**

```zig
var client = mcp.Client.init(.{
    .name = "my-client",
    .version = "1.0.0",
    .allocator = allocator,
});
defer client.deinit();
```

---

## Lifecycle

### `Client.deinit`

```zig
pub fn deinit(self: *Client) void
```

Clean up client resources and pending state.

---

## Capabilities

### `Client.enableRoots`

```zig
pub fn enableRoots(self: *Client, listChanged: bool) void
```

Enable the roots capability. Allows the client to provide filesystem roots to the server. `listChanged` indicates whether the client will send notifications when roots change.

### `Client.enableSampling`

```zig
pub fn enableSampling(self: *Client) void
```

Enable the sampling capability. Allows the server to request LLM completions.

### `Client.enableSamplingAdvanced`

```zig
pub fn enableSamplingAdvanced(self: *Client, context: bool, tools_support: bool) void
```

Enable the sampling capability with advanced configuration (context inclusion and tool use).

### `Client.enableElicitation`

```zig
pub fn enableElicitation(self: *Client) void
```

Enable the elicitation capability (both form and URL modes) for handling server-initiated user input requests.

### `Client.enableElicitationForm`

```zig
pub fn enableElicitationForm(self: *Client) void
```

### `Client.enableElicitationUrl`

```zig
pub fn enableElicitationUrl(self: *Client) void
```

### `Client.enableTasks`

```zig
pub fn enableTasks(self: *Client) void
```

Enable the tasks capability for managing long-running operations.

---

## Roots Management

### `Client.addRoot`

```zig
pub fn addRoot(self: *Client, uri: []const u8, name: ?[]const u8) !void
```

Add a filesystem root.

**Parameters:**

- `uri` - URI of the root (e.g., `file:///home/user/project`)
- `name` - Human-readable name for the root

**Example:**

```zig
try client.addRoot("file:///home/user/documents", "Documents");
try client.addRoot("file:///home/user/projects", "Projects");
```

---

## Fields

### `client.config`

```zig
pub const config: ClientConfig
```

The client configuration.

### `client.allocator`

```zig
pub const allocator: Allocator
```

The memory allocator.

### `client.roots_list`

```zig
pub const roots_list: ArrayList(types.Root)
```

List of configured roots.

### `client.capabilities`

```zig
pub const capabilities: ClientCapabilities
```

Enabled capabilities.

---

## Connection Management

### `Client.connectStdio`

```zig
pub fn connectStdio(self: *Client, command: []const u8, args: []const []const u8) !void
```

### `Client.connectHttp`

```zig
pub fn connectHttp(self: *Client, url: []const u8) !void
```

### `Client.setAuthorizationToken`

```zig
pub fn setAuthorizationToken(self: *Client, token: []const u8) !void
```

Set bearer token before calling `connectHttp` when your HTTP server requires authorization.

### `Client.disconnect`

```zig
pub fn disconnect(self: *Client) void
```

## Request APIs

All request APIs currently send protocol requests and return `!void`.

### Tools

```zig
pub fn listTools(self: *Client) !void
pub fn callTool(self: *Client, name: []const u8, arguments: ?std.json.Value) !void
```

### Resources

```zig
pub fn listResources(self: *Client) !void
pub fn readResource(self: *Client, uri: []const u8) !void
pub fn subscribeResource(self: *Client, uri: []const u8) !void
pub fn unsubscribeResource(self: *Client, uri: []const u8) !void
pub fn listResourceTemplates(self: *Client) !void
```

### Prompts

```zig
pub fn listPrompts(self: *Client) !void
pub fn getPrompt(self: *Client, name: []const u8, arguments: ?std.json.Value) !void
```

### Completion / Logging / Health

```zig
pub fn complete(self: *Client, ref: std.json.Value, argument: std.json.Value) !void
pub fn setLogLevel(self: *Client, level: []const u8) !void
pub fn ping(self: *Client) !void
```

### Tasks

```zig
pub fn getTask(self: *Client, taskId: []const u8) !void
pub fn getTaskResult(self: *Client, taskId: []const u8) !void
pub fn listTasks(self: *Client) !void
pub fn cancelTask(self: *Client, taskId: []const u8) !void
```

### Notifications

```zig
pub fn notifyInitialized(self: *Client) !void
pub fn notifyRootsChanged(self: *Client) !void
```

## Complete Example

```zig
const std = @import("std");
const mcp = @import("mcp");

pub fn main() !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Create client
    var client = mcp.Client.init(.{
        .name = "full-client",
        .version = "1.0.0",
        .allocator = allocator,
    });
    defer client.deinit();

    // Enable capabilities
    client.enableRoots(true);
    client.enableSampling();

    // Configure roots
    try client.addRoot("file:///home/user/docs", "Documentation");
    try client.addRoot("file:///home/user/code", "Source Code");

    // Print configuration
    std.debug.print("Client: {s} v{s}\n", .{
        client.config.name,
        client.config.version,
    });
    std.debug.print("Roots: {d}\n", .{client.roots_list.items.len});

    // In a full implementation, you would:
    // 1. Connect to a server via transport
    // 2. Send initialize request
    // 3. Interact with server capabilities
}
```

## Connection Management

### `Client.connectStdio`

```zig
pub fn connectStdio(self: *Client, command: []const u8, args: []const []const u8) !void
```

Connect to a server using the STDIO transport. 
*Note: Full sub-process spawning may require platform-specific tuning in real usage. Currently stubbed in simple scenarios.*

### `Client.connectHttp`

```zig
pub fn connectHttp(self: *Client, url: []const u8) !void
```

Connect to a server via HTTP transport.

### `Client.setAuthorizationToken`

```zig
pub fn setAuthorizationToken(self: *Client, token: []const u8) !void
```

Sets the authorization token for Bearer auth (OAuth 2.1 support) before making HTTP connections. Call this before `connectHttp`.

### `Client.disconnect`

```zig
pub fn disconnect(self: *Client) void
```

Disconnects from the server and closes the active transport.

---

## Server Queries and Interactions

### Tools

```zig
/// Request the list of available tools
pub fn listTools(self: *Client) !void

    // Request operations are currently fire-and-handle-later style
    try client.listTools();
    try client.callTool("hello", null);
/// Request the list of available resources
pub fn listResources(self: *Client) !void
