---
layout: home

hero:
  name: mcp.zig
  text: Model Context Protocol for Zig
  tagline: Bringing MCP support to the Zig ecosystem — the first comprehensive MCP library for Zig
  image:
    src: /logo.png
    alt: mcp.zig
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
  - icon: 🚀
    title: Fast & Efficient
    details: Built in Zig for maximum performance with zero runtime overhead. Compile-time optimizations ensure blazing fast execution.
  - icon: 🔧
    title: Full MCP Support
    details: Complete implementation of the Model Context Protocol including tools, resources, prompts, and JSON-RPC communication.
  - icon: 🔌
    title: Multiple Transports
    details: Support for STDIO and HTTP transports out of the box. Easily extensible for custom transport implementations.
  - icon: 📦
    title: Easy Integration
    details: Simple API design makes it easy to create MCP servers and clients. Get started with just a few lines of code.
  - icon: 🛡️
    title: Type Safe
    details: Leverages Zig's powerful type system for compile-time safety and clear error messages.
  - icon: 🌐
    title: AI Ready
    details: Connect AI applications to external systems like data sources, tools, and workflows using the open MCP standard.
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

## 🎯 Why mcp.zig?

The [Model Context Protocol (MCP)](https://modelcontextprotocol.io/docs/getting-started/intro) is an open standard by Anthropic for connecting AI applications to external systems. While MCP has official SDKs for TypeScript, Python, and other languages, **Zig currently lacks proper MCP support**.

**mcp.zig** fills this gap by providing a native, high-performance MCP implementation for Zig developers.

::: info Official MCP Resources
For the official MCP specification and documentation, visit [modelcontextprotocol.io](https://modelcontextprotocol.io/docs/getting-started/intro)
:::

## Quick Start

### Installation

Run the following command to add mcp.zig to your project:

```bash
# Latest development branch
zig fetch --save git+https://github.com/muhammad-fiaz/mcp.zig.git

# Or specific release
zig fetch --save https://github.com/muhammad-fiaz/mcp.zig/archive/refs/tags/v0.0.3.tar.gz
```

### Create a Simple Server

```zig
const std = @import("std");
const mcp = @import("mcp");

pub fn main() void {
    run() catch |err| {
        mcp.reportError(err);
    };
}

fn run() !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var server = mcp.Server.init(.{
        .name = "my-server",
        .version = "1.0.0",
        .allocator = allocator,
    });
    defer server.deinit();

    // Register a tool
    try server.addTool(.{
        .name = "greet",
        .description = "Greet a user",
        .handler = greetHandler,
    });

    // Run with STDIO transport
    try server.run(.stdio);
}
```

## Why Choose mcp.zig?

| Feature            | mcp.zig                    | Other Languages |
| ------------------ | -------------------------- | --------------- |
| **Performance**    | ⚡ Native Zig speed        | Interpreted/JIT |
| **Memory Safety**  | ✅ Compile-time guarantees | Runtime checks  |
| **Binary Size**    | 📦 Minimal (~100KB)        | Large runtimes  |
| **Dependencies**   | 🔗 Zero external deps      | Many packages   |
| **Cross-Platform** | 🌍 Linux, macOS, Windows   | Varies          |

## What is MCP?

The **Model Context Protocol (MCP)** is an open standard that enables:

- 🔧 **Tools** - Functions that AI can call to perform actions
- 📁 **Resources** - Data that AI can read and reference
- 💬 **Prompts** - Reusable templates for AI interactions
- 🔌 **Transports** - Communication channels (STDIO, HTTP)

Learn more at the [official MCP documentation](https://modelcontextprotocol.io/docs/getting-started/intro).

## Community

- [📖 Documentation](https://muhammad-fiaz.github.io/mcp.zig/)
- [💻 GitHub Repository](https://github.com/muhammad-fiaz/mcp.zig)
- [🐛 Issue Tracker](https://github.com/muhammad-fiaz/mcp.zig/issues)
- [💬 Discussions](https://github.com/muhammad-fiaz/mcp.zig/discussions)
- [🌐 Official MCP Site](https://modelcontextprotocol.io/)
