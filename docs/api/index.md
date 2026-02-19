# API Reference

This section provides detailed API documentation for mcp.zig.

## Modules Overview

| Module                                     | Description                     |
| ------------------------------------------ | ------------------------------- |
| [`mcp.Server`](/api/server)                | MCP server implementation       |
| [`mcp.Client`](/api/client)                | MCP client implementation       |
| [`mcp.protocol`](/api/protocol)            | Protocol constants and types    |
| [`mcp.types`](/api/types)                  | Core type definitions           |
| [`mcp.jsonrpc`](/api/protocol#jsonrpc)     | JSON-RPC 2.0 implementation     |
| [`mcp.transport`](/api/protocol#transport) | Transport layer implementations |
| [`mcp.tools`](/api/server#tools)           | Tool utilities                  |
| [`mcp.resources`](/api/server#resources)   | Resource utilities              |
| [`mcp.prompts`](/api/server#prompts)       | Prompt utilities                |
| [`mcp.schema`](/api/types#schema)          | JSON Schema utilities           |
| [`mcp.report`](/guide/error-handling)      | Error reporting and updates     |

## Quick Links

### Server Development

- [Server.init](/api/server#init) - Create a new server
- [Server.addTool](/api/server#addtool) - Register a tool
- [Server.addResource](/api/server#addresource) - Register a resource
- [Server.addPrompt](/api/server#addprompt) - Register a prompt
- [Server.run](/api/server#run) - Start the server

### Client Development

- [Client.init](/api/client#init) - Create a new client
- [Client.callTool](/api/client#calltool) - Call a remote tool
- [Client.readResource](/api/client#readresource) - Read a resource
- [Client.getPrompt](/api/client#getprompt) - Get a prompt

### Types

- [Content](/api/types#content) - Content types (text, image, etc.)
- [ToolResult](/api/types#toolresult) - Tool execution result
- [Resource](/api/types#resource) - Resource definition
- [Prompt](/api/types#prompt) - Prompt definition

## Import

```zig
const mcp = @import("mcp");

// Access submodules
const Server = mcp.Server;
const Client = mcp.Client;
const Content = mcp.Content;
const types = mcp.types;
const protocol = mcp.protocol;
const report = mcp.report;
```

## Version

Current version: **0.0.2**

Protocol version: **2025-11-25**

```zig
const version = mcp.protocol.PROTOCOL_VERSION; // "2025-11-25"
```
