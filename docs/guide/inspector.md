---
title: "Inspector"
description: "Use the MCP Inspector to test and debug your MCP servers with interactive tool calls and resource reads."
keywords: [MCP Inspector, debugging, testing, developer tools, npx, inspection]
---

# MCP Inspector

The **MCP Inspector** is an interactive developer tool for testing and debugging MCP servers.

## Getting started

::: warning Requires an Inspector build for 2026-07-28
The Inspector is maintained separately from this library. It speaks the
stateless, handshake-free model of revision `2026-07-28`, so an Inspector
release that still expects `initialize`/`notifications/initialized` will not
connect to a server built with mcp.zig. Check the Inspector's own release notes
for which protocol revision it targets, and use `npx @modelcontextprotocol/inspector@latest`
to get the newest one.
:::

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

The command after `inspector` is executed as a child process, so it must be a
real executable path or a command the Inspector can spawn directly. `zig build
run-server` starts the server under the Inspector's STDIO transport; the
alternative is to build first and point the Inspector at the produced binary:

```bash
zig build
npx @modelcontextprotocol/inspector ./zig-out/bin/example-server
```

## Features

The Inspector interface provides several features:

- **Server connection pane**: Select transport and customize command-line arguments.
- **Resources tab**: List resources, show metadata, inspect content, and test subscriptions.
- **Prompts tab**: Display templates, arguments, and test prompts with custom inputs.
- **Tools tab**: List tools, show schemas, and test tool execution.
- **Notifications pane**: View logs and notifications received from the server.

## Things to check by hand

Some behaviour is easier to confirm against the source than through the UI:

- **Required `_meta`** — every request must carry
  `io.modelcontextprotocol/protocolVersion` and
  `io.modelcontextprotocol/clientCapabilities`; a request missing either is
  answered with `-32602`.
- **`resultType` on every result** — `"complete"`, `"input_required"`, or
  `"task"`. An unrecognised value is rejected.
- **Caching hints** — the six cacheable operations must carry `ttlMs` and
  `cacheScope`.
- **Header mirroring** — over Streamable HTTP, `MCP-Protocol-Version`,
  `Mcp-Method`, `Mcp-Name`, and `Mcp-Param-*` must agree with the body.

## Best Practices

- **Iterative testing**: Make server changes, rebuild, reconnect Inspector, and test.
- **Monitor messages**: Watch the log pane to see JSON-RPC traffic.
- **Test edge cases**: Try invalid inputs or missing arguments to verify error handling.
