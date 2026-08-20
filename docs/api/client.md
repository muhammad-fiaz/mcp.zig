---
title: "Client API Reference"
description: "Complete API reference for mcp.Client — connection, discovery, tools, resources, prompts, and capabilities."
keywords: [Client API, mcp.Client, ClientConfig, connectStdio, connectHttp, discover, listTools, callTool]
---

# Client API

The `Client` struct is used to connect to MCP servers and send MCP requests.

## Constructor

### `Client.init`

```zig
pub fn init(io: std.Io, allocator: std.mem.Allocator, config: ClientConfig) Client
```

Create a new MCP client. The `io` and `allocator` are stored internally and reused for all operations.

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
pub fn addRoot(self: *Client, uri: []const u8, name: ?[]const u8) !void
```

---

## Connection Management

```zig
pub fn connectStdio(self: *Client, command: []const u8, args: []const []const u8) !void
pub fn connectHttp(self: *Client, url: []const u8) !void
pub fn setAuthorizationToken(self: *Client, token: []const u8) !void
pub fn disconnect(self: *Client) void
```

---

## Request APIs

All request APIs send JSON-RPC messages and return `!void`. The `io` and `allocator` are reused from initialization.

```zig
pub fn discover(self: *Client) !void

pub fn listTools(self: *Client) !void
pub fn callTool(self: *Client, name: []const u8, arguments: ?std.json.Value) !void

pub fn listResources(self: *Client) !void
pub fn readResource(self: *Client, uri: []const u8) !void
pub fn subscriptionsListen(self: *Client, uri: []const u8) !void
pub fn listResourceTemplates(self: *Client) !void

pub fn listPrompts(self: *Client) !void
pub fn getPrompt(self: *Client, name: []const u8, arguments: ?std.json.Value) !void

pub fn complete(self: *Client, ref: std.json.Value, argument: std.json.Value) !void

pub fn getTask(self: *Client, taskId: []const u8) !void
pub fn getTaskResult(self: *Client, taskId: []const u8) !void
pub fn listTasks(self: *Client) !void
pub fn cancelTask(self: *Client, taskId: []const u8) !void

pub fn notifyRootsChanged(self: *Client) !void
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
    defer client.deinit();

    client.enableRoots(true);
    client.enableSamplingAdvanced(true, true);

    try client.addRoot("file:///home/user/docs", "Documentation");
    try client.addRoot("file:///home/user/code", "Source Code");
}
```
