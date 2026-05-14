# API Reference

This section documents the public API exported by mcp.zig.

## Modules

| Module | Description |
| --- | --- |
| [mcp.Server](/api/server) | Server runtime and MCP request handling |
| [mcp.Client](/api/client) | Client runtime and server interaction |
| [mcp.protocol](/api/protocol) | Protocol constants and method names |
| [mcp.jsonrpc](/api/protocol#json-rpc) | JSON-RPC parsing/serialization helpers |
| [mcp.types](/api/types) | Shared MCP data structures |
| [mcp.transport](/api/protocol#transport) | Transport interface and implementations |
| [mcp.tools](/guide/tools) | Tool helpers such as textResult/getString |
| [mcp.resources](/guide/resources) | Resource and template types |
| [mcp.prompts](/guide/prompts) | Prompt and prompt message helpers |

## Import

```zig
const mcp = @import("mcp");

const Server = mcp.Server;
const Client = mcp.Client;
const types = mcp.types;
const protocol = mcp.protocol;
const jsonrpc = mcp.jsonrpc;
```

## Versions

- Library version: `0.0.4`
- Protocol version: `2025-11-25`

```zig
const protocol_version = mcp.protocol.PROTOCOL_VERSION;
```

## Notes

- Server tools/resources/prompts capabilities are enabled by registration (`addTool`, `addResource`, `addPrompt`).
- HTTP server mode accepts JSON-RPC POST requests on `/`.
- Client APIs are currently request-oriented (`!void`) and do not block-wait for typed responses.
