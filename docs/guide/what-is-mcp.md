---
title: "What is MCP?"
description: "Learn about the Model Context Protocol (MCP), an open standard for connecting AI applications to external systems like tools, resources, and prompts."
keywords: [MCP, Model Context Protocol, AI integration, tools, resources, prompts, zig]
---

# What is MCP?

**Model Context Protocol (MCP)** is an open-source standard for connecting AI applications to external systems.
Using MCP, AI applications like Claude or ChatGPT can connect to data sources (e.g. local files, databases), tools (e.g. search engines, calculators) and workflows (e.g. specialized prompts)—enabling them to access key information and perform tasks.

**Think of MCP like a USB-C port for AI applications.** Just as USB-C provides a standardized way to connect electronic devices, MCP provides a standardized way to connect AI applications to external systems.

::: tip Official Documentation
For the complete official MCP documentation, visit [modelcontextprotocol.io](https://modelcontextprotocol.io/docs/getting-started/intro)
:::

## What can MCP enable?

- **Personalized Assistants**: Agents can access your Google Calendar and Notion, acting as a more personalized AI assistant.
- **Automated Development**: Tools like Claude Code can generate an entire web app using a Figma design.
- **Enterprise Data Access**: Enterprise chatbots can connect to multiple databases across an organization, empowering users to analyze data using chat.
- **Creative Workflows**: AI models can create 3D designs on Blender and print them out using a 3D printer.

## Why does MCP matter?

Depending on where you sit in the ecosystem, MCP can have a range of benefits:

- **Developers**: MCP reduces development time and complexity when building, or integrating with, an AI application or agent.
- **AI applications or agents**: MCP provides access to an ecosystem of data sources, tools and apps which will enhance capabilities and improve the end-user experience.
- **End-users**: MCP results in more capable AI applications or agents which can access your data and take actions on your behalf when necessary.

## Why mcp.zig?

While MCP has official SDKs for TypeScript, Python, and other languages, **Zig currently lacks proper MCP support**.

`mcp.zig` provides a native Zig implementation of MCP revision `2026-07-28`,
with both a server and a client, on top of a single external package
(`httpx.zig`).

### Comparison

| Aspect          | mcp.zig                       | TypeScript SDK | Python SDK |
| --------------- | ----------------------------- | -------------- | ---------- |
| **Language**    | Zig                           | TypeScript     | Python     |
| **Compilation** | Ahead-of-time, static binary  | JIT            | Interpreted |
| **Memory safety** | Checked at compile time    | Checked at runtime | Checked at runtime |
| **Dependencies** | One (`httpx.zig`)            | npm tree       | pip tree   |

## Core Concepts

### Tools

Tools are functions that AI can call to perform actions:

```zig
try server.addTool(.{
    .name = "get_weather",
    .description = "Get weather for a location",
    .handler = weatherHandler,
});
```

### Resources

Resources provide read access to data:

```zig
try server.addResource(.{
    .uri = "file:///documents/readme.txt",
    .name = "README",
    .mimeType = "text/plain",
    .handler = readmeHandler,
});
```

### Prompts

Prompts are reusable templates for interactions:

```zig
try server.addPrompt(.{
    .name = "code_review",
    .description = "Review code for best practices",
    .handler = codeReviewHandler,
});
```

## Protocol Overview

MCP uses JSON-RPC 2.0 for communication. In revision `2026-07-28` the protocol
is stateless per request: there is no `initialize` handshake and no session id,
so **every** request carries the protocol version, the client identity, and the
client capabilities in `_meta`:

```json
{
  "jsonrpc": "2.0",
  "id": 1,
  "method": "tools/call",
  "params": {
    "name": "get_weather",
    "arguments": {
      "location": "San Francisco"
    },
    "_meta": {
      "io.modelcontextprotocol/protocolVersion": "2026-07-28",
      "io.modelcontextprotocol/clientInfo": {
        "name": "my-client",
        "version": "1.0.0"
      },
      "io.modelcontextprotocol/clientCapabilities": {}
    }
  }
}
```

Responses follow the same format, and every result carries a `resultType`:

```json
{
  "jsonrpc": "2.0",
  "id": 1,
  "result": {
    "resultType": "complete",
    "content": [
      {
        "type": "text",
        "text": "Weather in San Francisco: 68F, Sunny"
      }
    ],
    "isError": false
  }
}
```

A result is `complete`, `input_required` when the server needs more input from
the client before it can finish, or `task` when the request was augmented with
the tasks extension. Cacheable results additionally carry `ttlMs` and
`cacheScope`.

## Transports

mcp.zig implements two transports:

### STDIO

For local process communication (most common):

```zig
try server.run(io, allocator, .stdio);
```

### Streamable HTTP

For remote communication. The server listens on `POST /mcp` and answers with
`application/json`, or with `text/event-stream` when the request's `Accept`
header asks for it:

```zig
try server.run(io, allocator, .{ .http = .{ .port = 8080 } });
```

## Learn More

### mcp.zig Documentation

- [Getting Started](/guide/getting-started)
- [Server Guide](/guide/server)
- [Client Guide](/guide/client)
- [API Reference](/api/)

### Official MCP Resources

- [Official MCP Documentation](https://modelcontextprotocol.io/docs/getting-started/intro)
- [MCP Specification](https://spec.modelcontextprotocol.io/)
- [MCP GitHub Organization](https://github.com/modelcontextprotocol)
