//! Simple MCP Client Example
//!
//! This example demonstrates how to create an MCP client
//! that connects to a server.

const std = @import("std");

const mcp = @import("mcp");

pub fn main(init: std.process.Init) void {
    run(init.io, init.gpa, init.minimal.args.vector) catch |err| {
        mcp.reportError(err);
    };
}

fn run(io: std.Io, allocator: std.mem.Allocator, args: std.process.Args.Vector) !void {
    if (args.len < 2) {
        std.debug.print("Usage: {s} <server-command>\n", .{args[0]});
        std.debug.print("Example: {s} zig-out/bin/example-server\n", .{args[0]});
        return;
    }

    // Create client
    var client: mcp.Client = .init(io, allocator, .{
        .name = "simple-client",
        .version = "1.0.0",
        .title = "Simple MCP Client",
    });
    defer client.deinit(allocator);

    // Enable capabilities
    client.enableSampling();
    client.enableElicitation();
    client.enableTasks();
    client.enableRoots(true);

    // Add some roots
    try client.addRoot(allocator, "file:///home/user/documents", "Documents");
    try client.addRoot(allocator, "file:///home/user/projects", "Projects");

    std.debug.print("MCP Client initialized\n", .{});
    std.debug.print("Client: {s} v{s}\n", .{ client.config.name, client.config.version });
    std.debug.print("Roots configured: {d}\n", .{client.roots_list.items.len});

    // In a real implementation, you would:
    // 1. Connect to server: try client.connectStdio(io, allocator, args[1], &.{});
    // 2. List tools: try client.listTools(io, allocator);
    // 3. Call tools: try client.callTool(io, allocator, "greet", args);
    // 4. Handle responses in an event loop

    std.debug.print("\nTo connect to a server, run:\n", .{});
    std.debug.print("  echo '{{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{{}}}}' | .\\zig-out\\bin\\example-server\n", .{});
}
