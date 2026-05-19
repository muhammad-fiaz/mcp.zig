# Client API

The `Client` struct is used to connect to MCP servers and send MCP requests.

## Constructor

### `Client.init`

```zig
pub fn init(io: std.Io, allocator: std.mem.Allocator, config: ClientConfig) Client
```

Create a new MCP client.

**Config fields:**

| Field | Type | Description |
| --- | --- | --- |
| `name` | `[]const u8` | Client name (required) |
| `version` | `[]const u8` | Client version (required) |
| `title` | `?[]const u8` | Optional human-readable title |
| `description` | `?[]const u8` | Optional description |
| `icons` | `?[]const mcp.types.Icon` | Optional icon list |
| `websiteUrl` | `?[]const u8` | Optional website URL |

**Example:**

```zig
var client: mcp.Client = .init(io, allocator, .{
    .name = "my-client",
    .version = "1.0.0",
});
defer client.deinit(allocator);
```

---

## Lifecycle

### `Client.deinit`

```zig
pub fn deinit(self: *Client, allocator: std.mem.Allocator) void
```

Clean up client resources and pending state.

---

## Capabilities

```zig
pub fn enableRoots(self: *Client, listChanged: bool) void
pub fn enableSampling(self: *Client) void
pub fn enableSamplingAdvanced(self: *Client, context: bool, tools_support: bool) void
pub fn enableElicitation(self: *Client) void
pub fn enableElicitationForm(self: *Client) void
pub fn enableElicitationUrl(self: *Client) void
pub fn enableTasks(self: *Client) void
pub fn enableTasksAdvanced(self: *Client, sampling: bool, elicitation: bool) void
```

---

## Roots Management

```zig
pub fn addRoot(self: *Client, allocator: std.mem.Allocator, uri: []const u8, name: ?[]const u8) !void
```

---

## Connection Management

```zig
pub fn connectStdio(self: *Client, io: std.Io, allocator: std.mem.Allocator, command: []const u8, args: []const []const u8) !void
pub fn connectHttp(self: *Client, io: std.Io, allocator: std.mem.Allocator, url: []const u8) !void
pub fn setAuthorizationToken(self: *Client, allocator: std.mem.Allocator, token: []const u8) !void
pub fn disconnect(self: *Client) void
```

---

## Request APIs

All request APIs currently send protocol requests and return `!void`.

```zig
pub fn listTools(self: *Client, io: std.Io, allocator: std.mem.Allocator) !void
pub fn callTool(self: *Client, io: std.Io, allocator: std.mem.Allocator, name: []const u8, arguments: ?std.json.Value) !void

pub fn listResources(self: *Client, io: std.Io, allocator: std.mem.Allocator) !void
pub fn readResource(self: *Client, io: std.Io, allocator: std.mem.Allocator, uri: []const u8) !void
pub fn subscribeResource(self: *Client, io: std.Io, allocator: std.mem.Allocator, uri: []const u8) !void
pub fn unsubscribeResource(self: *Client, io: std.Io, allocator: std.mem.Allocator, uri: []const u8) !void
pub fn listResourceTemplates(self: *Client, io: std.Io, allocator: std.mem.Allocator) !void

pub fn listPrompts(self: *Client, io: std.Io, allocator: std.mem.Allocator) !void
pub fn getPrompt(self: *Client, io: std.Io, allocator: std.mem.Allocator, name: []const u8, arguments: ?std.json.Value) !void

pub fn complete(self: *Client, io: std.Io, allocator: std.mem.Allocator, ref: std.json.Value, argument: std.json.Value) !void
pub fn setLogLevel(self: *Client, io: std.Io, allocator: std.mem.Allocator, level: []const u8) !void
pub fn ping(self: *Client, io: std.Io, allocator: std.mem.Allocator) !void

pub fn getTask(self: *Client, io: std.Io, allocator: std.mem.Allocator, taskId: []const u8) !void
pub fn getTaskResult(self: *Client, io: std.Io, allocator: std.mem.Allocator, taskId: []const u8) !void
pub fn listTasks(self: *Client, io: std.Io, allocator: std.mem.Allocator) !void
pub fn cancelTask(self: *Client, io: std.Io, allocator: std.mem.Allocator, taskId: []const u8) !void

pub fn notifyInitialized(self: *Client, io: std.Io, allocator: std.mem.Allocator) !void
pub fn notifyRootsChanged(self: *Client, io: std.Io, allocator: std.mem.Allocator) !void
```

---

## Minimal Example

```zig
const std = @import("std");
const mcp = @import("mcp");

pub fn main(init: std.process.Init) void {
    run(init.io, init.gpa) catch |err| mcp.reportError(err);
}

fn run(io: std.Io, allocator: std.mem.Allocator) !void {
    var client: mcp.Client = .init(io, allocator, .{
        .name = "full-client",
        .version = "1.0.0",
    });
    defer client.deinit(allocator);

    client.enableRoots(true);
    client.enableSamplingAdvanced(true, true);

    try client.addRoot(allocator, "file:///home/user/docs", "Documentation");
    try client.addRoot(allocator, "file:///home/user/code", "Source Code");
}
```
