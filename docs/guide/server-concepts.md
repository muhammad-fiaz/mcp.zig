---
title: "Server Concepts"
description: "Core MCP server concepts: tools, resources, prompts, and how servers expose capabilities to AI applications."
keywords: [MCP server, tools, resources, prompts, capabilities, server features]
---

# Understanding MCP Servers

MCP servers are programs that expose specific capabilities to AI applications through standardized protocol interfaces.

## Core Server Features

Servers provide functionality through three building blocks:

| Feature       | Explanation                                                        | Who controls it |
| :------------ | :----------------------------------------------------------------- | :-------------- |
| **Tools**     | Functions that the LLM can actively call. Used to perform actions. | Model           |
| **Resources** | Passive data sources for read-only access to context info.         | Application     |
| **Prompts**   | Pre-built instruction templates for users (e.g. slash commands).   | User            |

### Tools

Tools enable AI models to perform actions. Each tool defines a specific operation with typed inputs (JSON Schema) and outputs.

- **list**: Discover available tools.
- **call**: Execute a specific tool.

Example definition:

```json
{
  "name": "searchFlights",
  "description": "Search for available flights",
  "inputSchema": { ... }
}
```

### Resources

Resources provide structured access to information (files, databases, APIs) as context.

- **Direct Resources**: Fixed URIs (e.g., `file:///path/doc.md`).
- **Resource Templates**: Dynamic URIs (e.g., `travel://activities/{city}`).
- **Operations**: list, read, subscribe.

### Prompts

Prompts are user-controlled templates (like "Plan a vacation"). They help structure interactions.

- **list**: Discover prompts.
- **get**: Retrieve prompt details and arguments.

## Bringing Servers Together

The power of MCP emerges when multiple servers work together. For example, a Travel Server, Weather Server, and Calendar Server can be combined by the Host to fulfill a complex user request like "Plan my vacation".
