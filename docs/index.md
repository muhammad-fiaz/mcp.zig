---
layout: home
title: Model Context Protocol (MCP) Library for Zig
titleTemplate: false
description: A native Model Context Protocol (MCP) library for Zig — build MCP servers and clients with tools, resources, prompts, STDIO/HTTP transport, and JSON-RPC 2.0, implementing protocol revision 2026-07-28.
keywords: zig, mcp, model context protocol, ai, llm, tools, resources, prompts, zig library, json-rpc, mcp server, mcp client, stdio transport, http transport, ai integration, ziglang

hero:
  name: MCP.zig
  text: Model Context Protocol for Zig
  tagline: A native Zig implementation of MCP revision 2026-07-28, with a server framework, a client framework, and STDIO and HTTP transports
  image:
    src: /logo.png
    alt: MCP.zig - Model Context Protocol Library for Zig
  actions:
    - theme: brand
      text: Get Started
      link: /guide/getting-started
    - theme: alt
      text: View on GitHub
      link: https://github.com/muhammad-fiaz/mcp.zig
    - theme: alt
      text: Official MCP Docs
      link: https://modelcontextprotocol.io/docs/getting-started/intro

features:
  - title: Server and client
    details: Both halves of the protocol are implemented — serve tools, resource templates, and prompts, and consume them from any conforming peer.
  - title: MCP 2026-07-28
    details: server/discover as the entry point, _meta on every request, resultType on every result, Multi Round-Trip Requests, and the opt-in tasks extension. No initialize handshake.
  - title: Two transports
    details: STDIO and Streamable HTTP, built on httpx.zig, behind a whole-message transport interface that custom transports can implement.
  - title: MCP Apps & UI
    details: Build interactive HTML interfaces (text/html;profile=mcp-app) with io.modelcontextprotocol/ui that render inline inside Claude Desktop, Zed, and Goose.
  - title: Full JSON Schema
    details: inputSchema and outputSchema are complete JSON Schema 2020-12 documents. Typed builders cover the common cases; raw documents are emitted verbatim.
  - title: Type-safe handlers
    details: Tool, resource, and prompt handlers are plain Zig functions with typed results, so mistakes surface at compile time.
---

<style>
:root {
  --vp-home-hero-name-color: transparent;
  --vp-home-hero-name-background: -webkit-linear-gradient(120deg, #f7a41d 30%, #ec971f);
  --vp-home-hero-image-background-image: linear-gradient(-45deg, #f7a41d50 50%, #ec971f50 50%);
  --vp-home-hero-image-filter: blur(44px);
}

@media (min-width: 640px) {
  :root {
    --vp-home-hero-image-filter: blur(56px);
  }
}

@media (min-width: 960px) {
  :root {
    --vp-home-hero-image-filter: blur(68px);
  }
}
</style>

## Why MCP.zig?

The [Model Context Protocol (MCP)](https://modelcontextprotocol.io/docs/getting-started/intro) is an open standard for connecting AI applications to external systems. Official SDKs exist for TypeScript, Python, and other languages; **Zig has no first-party MCP implementation**.

**MCP.zig** is a native Zig implementation of revision `2026-07-28`, providing both a server and a client framework with no runtime dependency beyond [httpx.zig](https://github.com/muhammad-fiaz/httpx.zig).

::: info Official MCP Resources
For the official MCP specification and documentation, visit [modelcontextprotocol.io](https://modelcontextprotocol.io/docs/getting-started/intro)
:::

## Quick Start

### Installation

mcp.zig requires **Zig 0.17.0** or later (`minimum_zig_version` in `build.zig.zon`).

```bash
zig fetch --save git+https://github.com/muhammad-fiaz/mcp.zig.git
zig build                  # static library
zig build run-all-examples # library plus every example
```

Wire the module into your `build.zig`:

```zig
const mcp_dep = b.dependency("mcp", .{
    .target = target,
    .optimize = optimize,
});
exe.root_module.addImport("mcp", mcp_dep.module("mcp"));
```

### Create a Simple Server

```zig
const std = @import("std");
const mcp = @import("mcp");

pub fn main(init: std.process.Init) void {
    run(init.io, init.gpa) catch |err| {
        mcp.reportError(err);
    };
}

fn run(io: std.Io, allocator: std.mem.Allocator) !void {
    var server: mcp.Server = .init(allocator, .{
        .name = "my-server",
        .version = "1.0.0",
    });
    defer server.deinit();

    // Register a tool
    try server.addTool(.{
        .name = "greet",
        .description = "Greet a user",
        .handler = greetHandler,
    });

    // Run with STDIO transport
    try server.run(io, allocator, .stdio);
}

fn greetHandler(
    _: ?*anyopaque,
    _: std.Io,
    allocator: std.mem.Allocator,
    args: ?std.json.Value,
) mcp.tools.ToolError!mcp.tools.ToolResult {
    const name = mcp.tools.getString(args, "name") orelse "World";
    const message = try std.fmt.allocPrint(allocator, "Hello, {s}!", .{name});
    return mcp.tools.textResult(allocator, message);
}
```

## At a Glance

| Area           | What mcp.zig provides                                                                                     |
| -------------- | -------------------------------------------------------------------------------------------------------- |
| **Protocol**   | Revision `2026-07-28` over JSON-RPC 2.0, stateless per request, `server/discover` entry point, MRTR        |
| **Server**     | Tools, resources, resource templates, prompts, pagination, caching hints, subscriptions, MRTR, tasks        |
| **Client**     | STDIO and HTTP transports, tool calls, reads, prompts, completion, batches, elicitation, sampling, roots   |
| **Extensions** | MCP Apps (`io.modelcontextprotocol/ui`), Tasks (`io.modelcontextprotocol/tasks`), capability negotiation   |
| **Transports** | STDIO and Streamable HTTP via httpx.zig, behind a whole-message `Transport` interface                       |
| **Dependencies** | One external package: `httpx.zig`. No other runtime dependencies                                         |
| **Platforms**  | Linux, macOS, Windows (CI runs the test suite on all three)                                                |

Built-in support covers OAuth 2.0 Client Credentials, Bearer token authentication,
RFC 9728 Protected Resource discovery, WWW-Authenticate challenge parsing, and
thread-safe cooperative cancellation via `CancellationToken`.

## What is MCP?

The **Model Context Protocol (MCP)** standardises four things:

- **Tools** - functions an application can invoke
- **Resources** - data an application can read and reference
- **Prompts** - reusable message templates
- **Transports** - the channels those are exchanged over (STDIO, HTTP)

Learn more at the [official MCP documentation](https://modelcontextprotocol.io/docs/getting-started/intro).

## Community

- [Documentation](https://muhammad-fiaz.github.io/mcp.zig/)
- [GitHub repository](https://github.com/muhammad-fiaz/mcp.zig)
- [Issue tracker](https://github.com/muhammad-fiaz/mcp.zig/issues)
- [Discussions](https://github.com/muhammad-fiaz/mcp.zig/discussions)
- [Official MCP site](https://modelcontextprotocol.io/)

## Related Zig Projects

- For **Env.zig** (.env parsing), check out **[env.zig](https://github.com/muhammad-fiaz/env.zig)**.
- For **TUI** support, check out **[tui.zig](https://github.com/muhammad-fiaz/tui.zig)**.
- For **ZON file format** support, check out **[zon.zig](https://github.com/muhammad-fiaz/zon.zig)**.
- For **Spinners/loading/progress bar** support, check out **[loaders.zig](https://github.com/muhammad-fiaz/loaders.zig)**.
- For **Terminal colors & text styles** support, check out **[tint.zig](https://github.com/muhammad-fiaz/tint.zig)**.
- For **MCP** support, check out **[mcp.zig](https://github.com/muhammad-fiaz/mcp.zig)**.
- For **API framework** support, check out **[api.zig](https://github.com/muhammad-fiaz/api.zig)**.
- For **Web framework** support, check out **[zix](https://github.com/muhammad-fiaz/zix)**.
- For **archive/compression** support, check out **[archive.zig](https://github.com/muhammad-fiaz/archive.zig)**.
- For **compression file format** support, check out **[zigx](https://github.com/muhammad-fiaz/zigx)**.
- For **CUDA** support, check out **[cuda.zig](https://github.com/muhammad-fiaz/cuda.zig)**.
- For **Simplified build.zig config** support, check out **[buildx.zig](https://github.com/muhammad-fiaz/buildx.zig)**.
- For **SQLite (zig-native implementation)** support, check out **[sqlite.zig](https://github.com/muhammad-fiaz/sqlite.zig)**.
- For **File downloading** support, check out **[downloader.zig](https://github.com/muhammad-fiaz/downloader.zig)**.
- For **update checker/auto-updater** support, check out **[updater.zig](https://github.com/muhammad-fiaz/updater.zig)**.
- For **Numerical computing** support, check out **[num.zig](https://github.com/muhammad-fiaz/num.zig)**.
- For **Logging** support, check out **[logly.zig](https://github.com/muhammad-fiaz/logly.zig)**.
- For **Data validation and serialization** support, check out **[zigantic](https://github.com/muhammad-fiaz/zigantic)**.
- For **UUID** support, check out **[uuid.zig](https://github.com/muhammad-fiaz/uuid.zig)**.
- For **Key-Value database** support, check out **[zkv.zig](https://github.com/muhammad-fiaz/zkv.zig)**.
- For **Terminal color & text styles** support, check out **[hint.zig](https://github.com/muhammad-fiaz/hint.zig)**.
- For **Brotli compression** support, check out **[brotli.zig](https://github.com/muhammad-fiaz/brotli.zig)**.
- For **Zstd compression** support, check out **[zstd.zig](https://github.com/muhammad-fiaz/zstd.zig)**.
- For **Tree-Sitter** support, check out **[tree-sitter.zig](https://github.com/muhammad-fiaz/tree-sitter.zig)**.
- For **HTTP client and server** support, check out **[httpx.zig](https://github.com/muhammad-fiaz/httpx.zig)**.

