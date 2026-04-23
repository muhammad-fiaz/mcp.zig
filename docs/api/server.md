# Server API

`mcp.Server` is the core runtime for exposing tools, resources, prompts, and utility notifications.

## Constructor

```zig
pub fn init(allocator: std.mem.Allocator, config: ServerConfig) Server
```

Important `ServerConfig` fields:

| Field | Type | Description |
| --- | --- | --- |
| `name` | `[]const u8` | Required server name |
| `version` | `[]const u8` | Required server version |
| `title` | `?[]const u8` | Optional human-readable title |
| `description` | `?[]const u8` | Optional description |
| `instructions` | `?[]const u8` | Optional usage instructions |

## Lifecycle

```zig
pub fn deinit(self: *Server) void
pub fn run(self: *Server, io: std.Io, allocator: std.mem.Allocator, options: RunOptions) !void
pub fn runWithTransport(self: *Server, t: mcp.transport.Transport) !void
```

Run options:

| Option | Description |
| --- | --- |
| `.stdio` | Line-delimited JSON-RPC over stdin/stdout |
| `.{ .http = .{ .host = "localhost", .port = 8080 } }` | HTTP listener with JSON-RPC POST on `/` |

Note: HTTP mode accepts host names such as `localhost` and binds to loopback when appropriate.

## Registration

```zig
pub fn addTool(self: *Server, tool: mcp.tools.Tool) !void
pub fn addResource(self: *Server, resource: mcp.resources.Resource) !void
pub fn addResourceTemplate(self: *Server, template: mcp.resources.ResourceTemplate) !void
pub fn addPrompt(self: *Server, prompt: mcp.prompts.Prompt) !void
```

## Capability Toggles

```zig
pub fn enableLogging(self: *Server) void
pub fn enableCompletions(self: *Server) void
pub fn enableTasks(self: *Server) void
```

Tools/resources/prompts capabilities are advertised automatically once components are registered.

## Utility Notifications

```zig
pub fn sendNotification(self: *Server, method: []const u8, params: ?std.json.Value) !void
pub fn sendLogMessage(self: *Server, level: mcp.protocol.LogLevel, message: []const u8) !void
pub fn sendProgress(self: *Server, token: std.json.Value, prog: f64, total: ?f64, message: ?[]const u8) !void

pub fn notifyToolsChanged(self: *Server) !void
pub fn notifyResourcesChanged(self: *Server) !void
pub fn notifyResourceUpdated(self: *Server, uri: []const u8) !void
pub fn notifyPromptsChanged(self: *Server) !void
```

## Minimal Example

```zig
const std = @import("std");
const mcp = @import("mcp");

pub fn main(init: std.process.Init) void {
    run(init.io, init.gpa) catch |err| mcp.reportError(err);
}

fn run(io: std.Io, allocator: std.mem.Allocator) !void {
    var server: mcp.Server = .init(allocator, .{
        .name = "api-example-server",
        .version = "1.0.0",
    });
    defer server.deinit();

    try server.addTool(.{
        .name = "ping",
        .description = "Returns pong",
        .handler = struct {
            fn handler(alloc: std.mem.Allocator, _: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
                return mcp.tools.textResult(alloc, "pong") catch return mcp.tools.ToolError.OutOfMemory;
            }
        }.handler,
    });

    server.enableLogging();
    try server.run(io, allocator, .stdio);
}
```
