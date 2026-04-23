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

`mcp.zig` aims to fill this gap by providing a native, high-performance MCP implementation for the Zig programming language.

### Comparison

| Feature            | mcp.zig      | TypeScript SDK | Python SDK  |
| ------------------ | ------------ | -------------- | ----------- |
| **Language**       | Zig          | TypeScript     | Python      |
| **Performance**    | ⚡ Native    | JIT            | Interpreted |
| **Binary Size**    | ~100KB       | ~50MB+ (Node)  | ~100MB+     |
| **Memory Safety**  | Compile-time | Runtime        | Runtime     |
| **Dependencies**   | Zero         | Many (npm)     | Many (pip)  |
| **Cross-Platform** | ✅           | ✅             | ✅          |

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

MCP uses JSON-RPC 2.0 for communication:

```json
{
  "jsonrpc": "2.0",
  "id": 1,
  "method": "tools/call",
  "params": {
    "name": "get_weather",
    "arguments": {
      "location": "San Francisco"
    }
  }
}
```

Responses follow the same format:

```json
{
  "jsonrpc": "2.0",
  "id": 1,
  "result": {
    "content": [
      {
        "type": "text",
        "text": "Weather in San Francisco: 68°F, Sunny"
      }
    ]
  }
}
```

## Transports

MCP supports multiple transport mechanisms:

### STDIO

For local process communication (most common):

```zig
try server.run(io, allocator, .stdio);
```

### HTTP

For remote communication:

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
