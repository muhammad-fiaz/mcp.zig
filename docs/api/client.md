# Client API

The `Client` struct is used to connect to MCP servers.

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

Clean up client resources.

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

## Complete Example

```zig
const std = @import("std");
const mcp = @import("mcp");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
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
    client.enableRoots();
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

/// Invoke a tool on the server with optional arguments
pub fn callTool(self: *Client, name: []const u8, arguments: ?std.json.Value) !void
```

### Resources

```zig
/// Request the list of available resources
pub fn listResources(self: *Client) !void

/// Read a specific resource's contents by URI
pub fn readResource(self: *Client, uri: []const u8) !void

/// Request available resource templates
pub fn listResourceTemplates(self: *Client) !void

/// Subscribe to a resource for updates
pub fn subscribeResource(self: *Client, uri: []const u8) !void

/// Unsubscribe from a resource's updates
pub fn unsubscribeResource(self: *Client, uri: []const u8) !void
```

### Prompts

```zig
/// Request the list of available prompts
pub fn listPrompts(self: *Client) !void

/// Fetch a prompt by name with optional arguments
pub fn getPrompt(self: *Client, name: []const u8, arguments: ?std.json.Value) !void
```

### Tasks

```zig
/// Retrieve task status and metadata
pub fn getTask(self: *Client, taskId: []const u8) !void

/// Get the result payload of a completed task
pub fn getTaskResult(self: *Client, taskId: []const u8) !void

/// List all available tasks
pub fn listTasks(self: *Client) !void

/// Request cancellation of a running task
pub fn cancelTask(self: *Client, taskId: []const u8) !void
```

### Utilities

```zig
/// Request autocomplete suggestions for a given reference and argument
pub fn complete(self: *Client, ref: std.json.Value, argument: std.json.Value) !void

/// Update the remote server's active log level
pub fn setLogLevel(self: *Client, level: []const u8) !void

/// Ping the server to check connection health
pub fn ping(self: *Client) !void
```

### Notifications

```zig
/// Notify the server that initialization was completed successfully
pub fn notifyInitialized(self: *Client) !void

/// Push a list-changed signal to the server when local roots change
pub fn notifyRootsChanged(self: *Client) !void
```
