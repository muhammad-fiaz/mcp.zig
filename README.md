<div align="center">
<img alt="logo" src="https://github.com/user-attachments/assets/09fa609c-22fd-4076-9849-dbd9800f8c03" />
    
# MCP.zig

<a href="https://muhammad-fiaz.github.io/mcp.zig/"><img src="https://img.shields.io/badge/docs-muhammad--fiaz.github.io-blue" alt="Documentation"></a>
<a href="https://ziglang.org/"><img src="https://img.shields.io/badge/Zig-0.15.0+-orange.svg?logo=zig" alt="Zig Version"></a>
<a href="https://github.com/muhammad-fiaz/mcp.zig"><img src="https://img.shields.io/github/stars/muhammad-fiaz/mcp.zig" alt="GitHub stars"></a>
<a href="https://github.com/muhammad-fiaz/mcp.zig/issues"><img src="https://img.shields.io/github/issues/muhammad-fiaz/mcp.zig" alt="GitHub issues"></a>
<a href="https://github.com/muhammad-fiaz/mcp.zig/pulls"><img src="https://img.shields.io/github/issues-pr/muhammad-fiaz/mcp.zig" alt="GitHub pull requests"></a>
<a href="https://github.com/muhammad-fiaz/mcp.zig"><img src="https://img.shields.io/github/last-commit/muhammad-fiaz/mcp.zig" alt="GitHub last commit"></a>
<a href="https://github.com/muhammad-fiaz/mcp.zig/blob/main/LICENSE"><img src="https://img.shields.io/github/license/muhammad-fiaz/mcp.zig" alt="License"></a>
<a href="https://github.com/muhammad-fiaz/mcp.zig/actions/workflows/deploy-docs.yml"><img src="https://github.com/muhammad-fiaz/mcp.zig/actions/workflows/deploy-docs.yml/badge.svg" alt="Docs"></a>
<img src="https://img.shields.io/badge/platforms-linux%20%7C%20windows%20%7C%20macos-blue" alt="Supported Platforms">
<a href="https://github.com/muhammad-fiaz/mcp.zig/releases/latest"><img src="https://img.shields.io/github/v/release/muhammad-fiaz/mcp.zig?label=Latest%20Release&style=flat-square" alt="Latest Release"></a>
<a href="https://pay.muhammadfiaz.com"><img src="https://img.shields.io/badge/Sponsor-pay.muhammadfiaz.com-ff69b4?style=flat&logo=heart" alt="Sponsor"></a>
<a href="https://github.com/sponsors/muhammad-fiaz"><img src="https://img.shields.io/badge/Sponsor-💖-pink?style=social&logo=github" alt="GitHub Sponsors"></a>
<a href="https://hits.sh/github.com/muhammad-fiaz/mcp.zig/"><img src="https://hits.sh/github.com/muhammad-fiaz/mcp.zig.svg?label=Visitors&extraCount=0&color=green" alt="Repo Visitors"></a>

<p><em>A comprehensive Model Context Protocol (MCP) library for Zig — bringing MCP support to the Zig ecosystem.</em></p>

<b>📚 <a href="https://muhammad-fiaz.github.io/mcp.zig/">Documentation</a> |
<a href="https://muhammad-fiaz.github.io/mcp.zig/api/">API Reference</a> |
<a href="https://muhammad-fiaz.github.io/mcp.zig/guide/getting-started">Quick Start</a> |
<a href="https://muhammad-fiaz.github.io/mcp.zig/contributing">Contributing</a></b>

</div>

---

## 🔌 What is MCP?

**Model Context Protocol (MCP)** is an open-source standard for connecting AI applications to external systems.
**Think of MCP like a USB-C port for AI applications.** Just as USB-C provides a standardized way to connect electronic devices, MCP provides a standardized way to connect AI applications to external systems.

## 🎯 Why mcp.zig?

The [Model Context Protocol (MCP)](https://modelcontextprotocol.io/docs/getting-started/intro) is an open standard by Anthropic for connecting AI applications to external systems. While MCP has official SDKs for TypeScript, Python, and other languages, **Zig currently lacks proper MCP support**.

**mcp.zig** aims to fill this gap by providing a native, high-performance MCP implementation for the Zig programming language, enabling Zig developers to:

- 🔧 Build MCP servers that expose tools, resources, and prompts to AI applications
- 🔌 Create MCP clients that connect to any MCP-compatible server
- ⚡ Leverage Zig's performance and safety features for AI integrations

## ✨ Features

- 🛠️ **Server Framework** - Build MCP servers that expose tools, resources, and prompts
- 🔌 **Client Framework** - Create MCP clients that connect to servers
- 📡 **Transport Layer** - STDIO and HTTP transport support
- 📋 **Full Protocol Support** - JSON-RPC 2.0, capability negotiation, lifecycle management
- ⚡ **Native Performance** - Written in pure Zig for optimal performance
- 🧪 **Comprehensive Testing** - Unit tests for all components

## 📚 Documentation

Full documentation is available at **[muhammad-fiaz.github.io/mcp.zig](https://muhammad-fiaz.github.io/mcp.zig/)**

For the official MCP specification and resources, visit:

- [MCP Documentation](https://modelcontextprotocol.io/docs/getting-started/intro)
- [MCP Specification](https://spec.modelcontextprotocol.io/)

## 🚀 Quick Start

### Installation

### Installation

Run the following command to add mcp.zig to your project:

```bash
zig fetch --save https://github.com/muhammad-fiaz/mcp.zig/archive/refs/tags/v0.0.1.tar.gz
```

Then in your `build.zig`:

```zig
const mcp_dep = b.dependency("mcp", .{
    .target = target,
    .optimize = optimize,
});
exe.root_module.addImport("mcp", mcp_dep.module("mcp"));
```

### Creating a Server

```zig
const std = @import("std");
const mcp = @import("mcp");

pub fn main() void {
    if (run()) {} else |err| {
        mcp.reportError(err);
    }
}

fn run() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Check for updates
    _ = mcp.report.checkForUpdates(allocator);

    // Create server
    var server = mcp.Server.init(.{
        .name = "my-server",
        .version = "1.0.0",
        .allocator = allocator,
    });
    defer server.deinit();

    // Enable tools capability
    server.enableTools();

    // Add a tool
    try server.addTool(.{
        .name = "greet",
        .description = "Greet a user",
        .handler = greetHandler,
    });

    // Run with STDIO transport
    try server.run(.stdio);
}

fn greetHandler(
    allocator: std.mem.Allocator,
    args: ?std.json.Value
) mcp.tools.ToolError!mcp.tools.ToolResult {
    const name = mcp.tools.getString(args, "name") orelse "World";
    const message = try std.fmt.allocPrint(allocator, "Hello, {s}!", .{name});
    return .{ .content = &.{mcp.Content.createText(message)} };
}
```

### Creating a Client

```zig
const std = @import("std");
const mcp = @import("mcp");

pub fn main() void {
    if (run()) {} else |err| {
        mcp.reportError(err);
    }
}

fn run() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var client = mcp.Client.init(.{
        .name = "my-client",
        .version = "1.0.0",
        .allocator = allocator,
    });
    defer client.deinit();

    // Enable capabilities
    client.enableSampling();
    client.enableRoots(true); // Supports list changed notifications

    // Add roots
    try client.addRoot("file:///projects", "Projects");
}
```

## 📁 Examples

The `examples/` directory contains several example implementations:

| Example                   | Description                           |
| ------------------------- | ------------------------------------- |
| **simple_server.zig**     | Basic server with greeting tool       |
| **simple_client.zig**     | Basic client setup                    |
| **weather_server.zig**    | Weather information server            |
| **calculator_server.zig** | Calculator with arithmetic operations |

Run examples:

```bash
# Build all examples
zig build

# Run examples
./zig-out/bin/example-server
./zig-out/bin/weather-server
./zig-out/bin/calculator-server
```

## 🏗️ Architecture

```
src/
├── mcp.zig              # Main entry point
├── protocol/
│   ├── protocol.zig     # MCP protocol definitions
│   ├── types.zig        # Type definitions
│   ├── jsonrpc.zig      # JSON-RPC 2.0 implementation
│   └── schema.zig       # JSON Schema utilities
├── transport/
│   └── transport.zig    # STDIO and HTTP transports
├── server/
│   ├── server.zig       # Server implementation
│   ├── tools.zig        # Tool primitive
│   ├── resources.zig    # Resource primitive
│   └── prompts.zig      # Prompt primitive
└── client/
    └── client.zig       # Client implementation
```

## 🛠️ Server Features

### Tools

Tools are executable functions that AI applications can invoke:

```zig
try server.addTool(.{
    .name = "search_files",
    .description = "Search for files matching a pattern",
    .handler = searchHandler,
});
```

### Resources

Resources provide read-only data to AI applications:

```zig
try server.addResource(.{
    .uri = "file:///docs/readme.md",
    .name = "README",
    .mimeType = "text/markdown",
    .handler = readFileHandler,
});
```

### Prompts

Prompts are reusable templates for LLM interactions:

```zig
try server.addPrompt(.{
    .name = "summarize",
    .description = "Summarize a document",
    .arguments = &.{
        .{ .name = "document", .required = true },
    },
    .handler = summarizeHandler,
});
```

## 🔌 Client Features

### Roots

Define filesystem boundaries:

```zig
client.enableRoots(true);
try client.addRoot("file:///projects", "Projects");
```

### Sampling

Allow servers to request LLM completions:

```zig
client.enableSampling();
```

## 🧪 Testing

Run the test suite:

```bash
zig build test
```

## 📖 Protocol Version

This library implements MCP protocol version **2025-11-25**.

| Version    | Status        |
| ---------- | ------------- |
| 2025-11-25 | ✅ Supported  |
| 2024-11-05 | ✅ Compatible |


## 🤝 Contributing

Contributions are welcome! Please feel free to submit issues and pull requests.

See [Contributing Guide](https://muhammad-fiaz.github.io/mcp.zig/contributing) for guidelines.

## 💖 Support

If you find this project helpful, consider supporting its development:

<a href="https://pay.muhammadfiaz.com"><img src="https://img.shields.io/badge/Sponsor-pay.muhammadfiaz.com-ff69b4?style=for-the-badge&logo=heart" alt="Sponsor"></a>
<a href="https://github.com/sponsors/muhammad-fiaz"><img src="https://img.shields.io/badge/GitHub_Sponsors-💖-pink?style=for-the-badge&logo=github" alt="GitHub Sponsors"></a>

## 📄 License

MIT License - see [LICENSE](LICENSE) for details.

## 🔗 Resources

- [📚 mcp.zig Documentation](https://muhammad-fiaz.github.io/mcp.zig/)
- [🌐 Official MCP Documentation](https://modelcontextprotocol.io/docs/getting-started/intro)
- [📋 MCP Specification](https://spec.modelcontextprotocol.io)
- [💻 MCP GitHub](https://github.com/modelcontextprotocol)
