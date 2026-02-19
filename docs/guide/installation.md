# Installation

This guide covers different ways to install and use mcp.zig in your project.

## Requirements

- **Zig 0.15.0** or later
- A Zig project with `build.zig` and `build.zig.zon`

## Using Zig Package Manager

The recommended way to use mcp.zig is through Zig's built-in package manager.

### Step 1: Add Dependency

Run the following command to add mcp.zig to your project:

```bash
# Latest development branch
zig fetch --save git+https://github.com/muhammad-fiaz/mcp.zig.git

# Or specific release
zig fetch --save https://github.com/muhammad-fiaz/mcp.zig/archive/refs/tags/0.0.2.tar.gz
```

This will automatically update your `build.zig.zon` with the dependency and correct hash.

### Step 2: Configure Build

Update your `build.zig` to use the dependency:

```zig
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Get the mcp dependency
    const mcp_dep = b.dependency("mcp", .{
        .target = target,
        .optimize = optimize,
    });

    // Create your executable
    const exe = b.addExecutable(.{
        .name = "my-mcp-server",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    // Add the mcp module
    exe.root_module.addImport("mcp", mcp_dep.module("mcp"));

    b.installArtifact(exe);
}
```

### Step 3: Build

Run zig build to fetch and build:

```bash
zig build
```

## Using Git Submodule

Alternatively, you can use a Git submodule:

```bash
git submodule add https://github.com/muhammad-fiaz/mcp.zig.git deps/mcp.zig
```

Then in your `build.zig`:

```zig
const mcp_module = b.addModule("mcp", .{
    .root_source_file = .{ .cwd_relative = "deps/mcp.zig/src/mcp.zig" },
});

exe.root_module.addImport("mcp", mcp_module);
```

## Verifying Installation

Create a simple test file to verify the installation:

```zig
// src/main.zig
const std = @import("std");
const mcp = @import("mcp");

pub fn main() !void {
    std.debug.print("mcp.zig version: {s}\n", .{mcp.protocol.VERSION});
    std.debug.print("Installation successful!\n", .{});
}
```

Build and run:

```bash
zig build
./zig-out/bin/my-mcp-server
```

You should see:

```
mcp.zig version: 2025-03-26
Installation successful!
```

## Next Steps

- [Getting Started](/guide/getting-started) - Create your first MCP server
- [Server Guide](/guide/server) - Learn about server capabilities
- [Examples](/examples/) - Explore example projects
