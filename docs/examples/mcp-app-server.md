---
title: "MCP Apps Server Example"
description: "Build interactive UI applications using the MCP Apps extension (io.modelcontextprotocol/ui) with MCP.zig."
keywords: [mcp apps, ui extension, interactive ui, html resource, _meta.ui, server capabilities, extensions negotiation]
---

# MCP Apps Server Example

Demonstrates building an interactive graphical MCP server using the **MCP Apps UI extension** (`io.modelcontextprotocol/ui`).

## Overview

[MCP Apps](https://modelcontextprotocol.io/extensions/apps/overview) allow MCP servers to deliver interactive user interfaces (embedded dashboards, calculators, visualizations, forms) directly inside AI hosts such as Claude Desktop, Zed, Goose, or custom web portals.

This example demonstrates:

1. **Extension Negotiation**: Calling `try server.enableUi()` to advertise `io.modelcontextprotocol/ui` in `capabilities.extensions` during `server/discover`.
2. **UI Resources**: Exposing HTML user interfaces with MIME type `text/html;profile=mcp-app` (`mcp.MIME_TYPE_MCP_APP`) using `mcp.ResourceBuilder.mcpApp()`.
3. **Tool UI Metadata**: Linking tools to UI resources using `_meta.ui.resourceUri` via `ToolBuilder.ui()` and `ToolBuilder.uiWithVisibility()`.
4. **Tool Results with UI**: Returning tool execution responses carrying UI metadata using `mcp.uiResult()`.
5. **Dual Transport**: Running over STDIO by default (for host integration) or HTTP via `--http` (for browser/curl testing).

## Architecture

```mermaid
sequenceDiagram
    participant Host as AI Host (App Viewport)
    participant Server as MCP Apps Server

    Host->>Server: server/discover (advertises extension support)
    Server-->>Host: capabilities.extensions["io.modelcontextprotocol/ui"]
    Host->>Server: tools/list
    Server-->>Host: tools with _meta.ui.resourceUri
    Host->>Server: tools/call ("open_dashboard")
    Server-->>Host: ToolResult with _meta.ui pointing to ui://dashboard/interactive
    Host->>Server: resources/read ("ui://dashboard/interactive")
    Server-->>Host: ResourceContent (text/html;profile=mcp-app)
    Note over Host: Renders sandboxed interactive UI in viewport
```

## Running the Example

### STDIO Transport (Default)

Use STDIO when connecting from Claude Desktop, Zed, or the MCP Inspector:

```bash
zig build run-mcp-app
```

In your MCP client configuration (e.g. `claude_desktop_config.json`):

```json
{
  "mcpServers": {
    "mcp-app": {
      "command": "zig-out/bin/mcp-app-server"
    }
  }
}
```

### HTTP Transport

To test over HTTP and view endpoints via `curl`:

```bash
zig build run-mcp-app -- --http --port 8080
```

## Example Walkthrough

### 1. Enabling the UI Extension

```zig
var server = mcp.Server.init(allocator, .{
    .name = "mcp-apps-server",
    .version = "1.0.0",
});
defer server.deinit();

// Negotiates io.modelcontextprotocol/ui during discovery
try server.enableUi();
```

During `server/discover`, the server responds with:

```json
{
  "jsonrpc": "2.0",
  "id": 1,
  "result": {
    "protocolVersion": "2026-07-28",
    "supportedVersions": ["2026-07-28"],
    "serverInfo": { "name": "mcp-apps-server", "version": "1.0.0" },
    "capabilities": {
      "tools": {},
      "resources": {},
      "extensions": {
        "io.modelcontextprotocol/ui": { "version": "draft" }
      }
    }
  }
}
```

### 2. Registering an MCP App UI Resource

```zig
var dash_res_builder = mcp.ResourceBuilder.init("ui://dashboard/interactive", "Interactive Dashboard");
_ = dash_res_builder
    .title("System & Metrics Dashboard")
    .description("Self-contained interactive dashboard")
    .mcpApp() // sets MIME type to text/html;profile=mcp-app
    .handler(dashboardResourceHandler);
try server.addResource(dash_res_builder.build());
```

### 3. Linking Tools to the UI via `_meta`

```zig
var open_dash_builder = mcp.ToolBuilder.init("open_dashboard");
_ = try open_dash_builder
    .title("Open Interactive Dashboard")
    .description("Launches the interactive real-time system metrics dashboard")
    .readOnly()
    .idempotent()
    .ui(allocator, "ui://dashboard/interactive");
_ = open_dash_builder.handler(openDashboardHandler);
try server.addTool(open_dash_builder.build());
```

When the client lists tools (`tools/list`), each UI tool advertises its linked resource:

```json
{
  "name": "open_dashboard",
  "description": "Launches the interactive real-time system metrics dashboard",
  "_meta": {
    "ui": {
      "resourceUri": "ui://dashboard/interactive"
    }
  }
}
```

### 4. Returning Tool Results with UI

```zig
fn openDashboardHandler(
    _: ?*anyopaque,
    _: std.Io,
    allocator: std.mem.Allocator,
    _: ?std.json.Value,
) mcp.tools.ToolError!mcp.ToolResult {
    return mcp.uiResult(
        allocator,
        "ui://dashboard/interactive",
        "Dashboard ready. The interactive UI is rendered in the MCP Apps viewport.",
    ) catch return mcp.tools.ToolError.OutOfMemory;
}
```

The tool result carries `_meta`:

```json
{
  "jsonrpc": "2.0",
  "id": 2,
  "result": {
    "resultType": "complete",
    "content": [
      {
        "type": "text",
        "text": "Dashboard ready. The interactive UI is rendered in the MCP Apps viewport."
      }
    ],
    "_meta": {
      "ui": {
        "resourceUri": "ui://dashboard/interactive"
      }
    },
    "isError": false
  }
}
```

## Testing with HTTP & `curl`

Start the server:

```bash
zig build run-mcp-app -- --http --port 8080
```

### Discovery

```bash
curl -X POST http://127.0.0.1:8080/mcp \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","id":1,"method":"server/discover","params":{"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28","io.modelcontextprotocol/clientCapabilities":{}}}}'
```

### Read UI Resource

```bash
curl -X POST http://127.0.0.1:8080/mcp \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","id":2,"method":"resources/read","params":{"uri":"ui://dashboard/interactive","_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28","io.modelcontextprotocol/clientCapabilities":{}}}}'
```

### Call Tool with UI

```bash
curl -X POST http://127.0.0.1:8080/mcp \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"open_dashboard","_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28","io.modelcontextprotocol/clientCapabilities":{}}}}'
```
