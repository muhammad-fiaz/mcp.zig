//! Simple MCP Client Example
//!
//! Demonstrates connecting to an MCP server, discovering capabilities,
//! and listing available tools. This example shows the full client lifecycle.
//!
//! Run: zig build run-simple-client

const std = @import("std");
const mcp = @import("mcp");

pub fn main(init: std.process.Init) void {
    run(init.io, init.gpa, init.minimal.args) catch |err| mcp.reportError(err);
}

fn run(io: std.Io, allocator: std.mem.Allocator, process_args: std.process.Args) !void {
    var args = try std.process.Args.Iterator.initAllocator(process_args, allocator);
    defer args.deinit();

    const exe = args.next() orelse "simple-client";
    const server_cmd = args.next();

    if (server_cmd == null) {
        std.debug.print("Usage: {s} <server-command>\n", .{exe});
        std.debug.print("  Example: {s} zig-out/bin/example-server\n", .{exe});
        std.debug.print("\nThis client will:\n", .{});
        std.debug.print("  1. Connect to the server via STDIO\n", .{});
        std.debug.print("  2. Discover server capabilities\n", .{});
        std.debug.print("  3. List available tools\n", .{});
        std.debug.print("  4. Read available resources\n", .{});
        std.debug.print("  5. List available prompts\n", .{});
        return;
    }

    // Create client using explicit init style
    var client = mcp.Client.init(io, allocator, .{
        .name = "simple-client",
        .version = "1.0.0",
        .title = "Simple MCP Client",
        .description = "A simple client that demonstrates basic MCP operations",
    });
    defer client.deinit();

    // Declare supported capabilities
    client.enableSamplingAdvanced(true, true);
    client.enableElicitation();
    client.enableTasksAdvanced(true, true);
    client.enableRoots(true);

    // Add filesystem roots
    try client.addRoot("file:///tmp", "Temp");

    // Connect to server
    std.debug.print("Connecting to server: {s}...\n", .{server_cmd.?});
    try client.connectStdio(server_cmd.?, &.{});
    std.debug.print("Connected!\n", .{});

    // Discover server capabilities
    std.debug.print("\nDiscovering server capabilities...\n", .{});
    try client.discover();
    std.debug.print("Discovery complete!\n", .{});

    // List available tools
    std.debug.print("\nListing available tools...\n", .{});
    try client.listTools();
    std.debug.print("Tools listed!\n", .{});

    // List available resources
    std.debug.print("\nListing available resources...\n", .{});
    try client.listResources();
    std.debug.print("Resources listed!\n", .{});

    // List available prompts
    std.debug.print("\nListing available prompts...\n", .{});
    try client.listPrompts();
    std.debug.print("Prompts listed!\n", .{});

    // Disconnect
    client.disconnect();
    std.debug.print("\nDisconnected from server.\n", .{});
}
