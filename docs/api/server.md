---
title: "Server API Reference"
description: "Complete API reference for mcp.Server — initialization, configuration, tools, resources, prompts, and transport."
keywords: [Server API, mcp.Server, ServerConfig, addTool, addResource, addPrompt, enableLogging, STDIO, HTTP]
---

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
| `icons` | `?[]const mcp.types.Icon` | Optional icon list |
| `websiteUrl` | `?[]const u8` | Optional website URL |
| `instructions` | `?[]const u8` | Optional usage instructions |
| `cache` | `CacheConfig` | Caching hints for cacheable results |

### `CacheConfig`

Servers MUST emit `ttlMs` (>= 0) and `cacheScope` on `resultType: "complete"` results for `server/discover`, `tools/list`, `prompts/list`, `resources/list`, `resources/templates/list`, and `resources/read`.

| Field | Type | Default | Description |
| --- | --- | --- | --- |
| `ttl_ms` | `i64` | `300000` | Freshness hint in ms for lists and `server/discover`; negatives clamp to `0` |
| `read_ttl_ms` | `i64` | `60000` | Freshness hint for `resources/read` |
| `scope` | `types.CacheScope` | `.public` | Cache scope for lists and `server/discover` |
| `read_scope` | `types.CacheScope` | `.private` | Cache scope for `resources/read` |

`types.CacheScope` is either `.public` (no user-specific data) or `.private` (must not be shared across authorization contexts).

## Lifecycle

```zig
pub fn deinit(self: *Server) void
pub fn run(self: *Server, io: std.Io, allocator: std.mem.Allocator, options: RunOptions) !void
pub fn runWithTransport(self: *Server, io: std.Io, allocator: std.mem.Allocator, t: mcp.transport.Transport) !void
```

Run options:

| Option | Description |
| --- | --- |
| `.stdio` | Line-delimited JSON-RPC over stdin/stdout |
| `.{ .http = .{ .host = "127.0.0.1", .port = 8080 } }` | HTTP listener with JSON-RPC POST on `/mcp` |

Note: HTTP mode accepts host names such as `127.0.0.1` and binds accordingly.
It is implemented with httpx.zig 0.2.2 (Zig 0.17.0).

## Registration

```zig
pub fn addTool(self: *Server, tool: mcp.tools.Tool) !void
pub fn addResource(self: *Server, resource: mcp.resources.Resource) !void
pub fn addResourceTemplate(self: *Server, template: mcp.resources.ResourceTemplate) !void
pub fn addPrompt(self: *Server, prompt: mcp.prompts.Prompt) !void
```

## Capability & Extension Toggles

```zig
pub fn enableLogging(self: *Server) void
pub fn enableCompletions(self: *Server) void
pub fn enableTasks(self: *Server) !void
pub fn enableUi(self: *Server) !void
pub fn enableUiWithSettings(self: *Server, settings: std.json.Value) !void
pub fn isUiEnabled(self: *Server) bool
pub fn isTasksEnabled(self: *Server) bool
```

Tools/resources/prompts capabilities are advertised automatically once components are registered.

## Utility Notifications

```zig
pub fn sendNotification(self: *Server, io: std.Io, allocator: std.mem.Allocator, method: []const u8, params: ?std.json.Value) !void
pub fn sendLogMessage(self: *Server, io: std.Io, allocator: std.mem.Allocator, level: mcp.protocol.LogLevel, message: []const u8) !void
pub fn sendProgress(self: *Server, io: std.Io, allocator: std.mem.Allocator, token: std.json.Value, prog: f64, total: ?f64, message: ?[]const u8) !void

pub fn notifyToolsChanged(self: *Server, io: std.Io, allocator: std.mem.Allocator) !void
pub fn notifyResourcesChanged(self: *Server, io: std.Io, allocator: std.mem.Allocator) !void
pub fn notifyResourceUpdated(self: *Server, io: std.Io, allocator: std.mem.Allocator, uri: []const u8) !void
pub fn notifyPromptsChanged(self: *Server, io: std.Io, allocator: std.mem.Allocator) !void
```

::: warning Log level is per-request
Logging is opt-in per request. A client asks for logs by putting
`io.modelcontextprotocol/logLevel` in that request's `_meta`, and the server
emits **nothing** when the field is absent. `sendLogMessage` therefore only
delivers while the request that asked for logs is still being handled, and a
message below the requested level is dropped. An unrecognized level fails the
request with `-32602`. The connection-wide `logging/setLevel` method was removed
in 2026-07-28.
:::

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
            fn handler(_: ?*anyopaque, _: std.Io, alloc: std.mem.Allocator, _: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
                return mcp.tools.textResult(alloc, "pong") catch return mcp.tools.ToolError.OutOfMemory;
            }
        }.handler,
    });

    server.enableLogging();
    try server.run(io, allocator, .stdio);
}
```
