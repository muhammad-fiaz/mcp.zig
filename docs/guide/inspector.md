---
title: "Inspector"
description: "Use the MCP Inspector to test and debug your MCP servers with interactive tool calls and resource reads."
keywords: [MCP Inspector, debugging, testing, developer tools, npx, inspection]
---

# MCP Inspector

The **MCP Inspector** is an interactive developer tool for testing and debugging MCP servers.

## Getting started

::: info Prerequisites
The MCP Inspector is a Node.js tool. You must have [Node.js](https://nodejs.org/) installed to run it, even though your project is in Zig.
:::

The Inspector runs directly through `npx` without requiring installation:

```bash
npx @modelcontextprotocol/inspector <command>
```

### Inspecting local servers

To inspect servers locally developed (e.g., your Zig MCP server), you can run:

```bash
npx @modelcontextprotocol/inspector <your-server-command> [args...]
# Example for a Zig server
npx @modelcontextprotocol/inspector zig build run-server
```

## Features

The Inspector interface provides several features:

- **Server connection pane**: Select transport and customize command-line arguments.
- **Resources tab**: List resources, show metadata, inspect content, and test subscriptions.
- **Prompts tab**: Display templates, arguments, and test prompts with custom inputs.
- **Tools tab**: List tools, show schemas, and test tool execution.
- **Notifications pane**: View logs and notifications received from the server.

## Best Practices

- **Iterative testing**: Make server changes, rebuild, reconnect Inspector, and test.
- **Monitor messages**: Watch the log pane to see JSON-RPC traffic.
- **Test edge cases**: Try invalid inputs or missing arguments to verify error handling.
