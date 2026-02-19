# Getting Started

Welcome to **mcp.zig** — the first comprehensive [Model Context Protocol (MCP)](https://modelcontextprotocol.io/docs/getting-started/intro) library for Zig!

::: info Why mcp.zig?
While MCP has official SDKs for TypeScript, Python, and other languages, **Zig currently lacks proper MCP support**. mcp.zig fills this gap, bringing the power of MCP to the Zig ecosystem.
:::

## What You'll Learn

In this guide, you'll learn how to:

1. Install mcp.zig as a dependency
2. Create a simple MCP server
3. Register tools, resources, and prompts
4. Connect to an MCP server as a client

## Prerequisites

Before you begin, make sure you have:

- [Zig 0.15.0](https://ziglang.org/download/) or later installed
- Basic familiarity with Zig programming language

## Quick Installation

Run the following command in your project directory:

```bash
# Latest development branch
zig fetch --save git+https://github.com/muhammad-fiaz/mcp.zig.git

# Or specific release
zig fetch --save https://github.com/muhammad-fiaz/mcp.zig/archive/refs/tags/0.0.2.tar.gz
```

Then in your `build.zig`:

```zig
const mcp_dep = b.dependency("mcp", .{
    .target = target,
    .optimize = optimize,
});

exe.root_module.addImport("mcp", mcp_dep.module("mcp"));
```

## Your First MCP Server

Here's a minimal example of an MCP server:

```zig
const std = @import("std");
const mcp = @import("mcp");

pub fn main() void {
    // Run the application logic
    run() catch |err| {
        // Report error with link to issue tracker if needed
        mcp.reportError(err);
    };
}

fn run() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Check for library updates in background (recommended)
    if (mcp.report.checkForUpdates(allocator)) |t| t.detach();

    // Create a server
    var server = mcp.Server.init(.{
        .name = "hello-server",
        .version = "1.0.0",
        .allocator = allocator,
    });
    defer server.deinit();

    // Add a simple tool
    try server.addTool(.{
        .name = "hello",
        .description = "Says hello to someone",
        .handler = helloHandler,
    });

    // Run the server (blocks until shutdown)
    try server.run(.stdio);
}

fn helloHandler(
    allocator: std.mem.Allocator,
    args: ?std.json.Value,
) mcp.tools.ToolError!mcp.tools.ToolResult {
    const name = mcp.tools.getString(args, "name") orelse "World";

    const message = try std.fmt.allocPrint(allocator, "Hello, {s}!", .{name});

    return mcp.tools.ToolResult{
        .content = &.{mcp.Content.createText(message)},
    };
}
```

## Next Steps

Now that you have the basics, explore:

- [Installation Guide](/guide/installation) - Learn about different installation methods
- [Server Guide](/guide/server) - Deep dive into server capabilities
- [Tools Guide](/guide/tools) - Learn how to create powerful tools
- [Examples](/examples/) - See complete working examples

### Official MCP Resources

- [Official MCP Documentation](https://modelcontextprotocol.io/docs/getting-started/intro) - Learn about MCP from Anthropic
- [MCP Specification](https://spec.modelcontextprotocol.io/) - Full protocol specification
- [MCP GitHub](https://github.com/modelcontextprotocol) - Official repositories
