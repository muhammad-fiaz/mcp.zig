//! Simple MCP Client Example
//!
//! Demonstrates client initialization, capability declaration, and root configuration.
//! Run: zig build run-client

const std = @import("std");
const mcp = @import("mcp");

pub fn main(init: std.process.Init) void {
    run(init.io, init.gpa, init.minimal.args) catch |err| mcp.reportError(err);
}

fn run(io: std.Io, allocator: std.mem.Allocator, process_args: std.process.Args) !void {
    var args = try std.process.Args.Iterator.initAllocator(process_args, allocator);
    defer args.deinit();

    const exe = args.next() orelse "example-client";
    const server_cmd = args.next();

    if (server_cmd == null) {
        std.debug.print("Usage: {s} <server-command>\n", .{exe});
        std.debug.print("  Example: {s} zig-out/bin/example-server\n", .{exe});
        return;
    }

    var client: mcp.Client = .init(io, allocator, .{
        .name = "simple-client",
        .version = "1.0.0",
        .title = "Simple MCP Client",
    });
    defer client.deinit(allocator);

    // Declare supported capabilities
    client.enableSamplingAdvanced(true, true);
    client.enableElicitation();
    client.enableTasksAdvanced(true, true);
    client.enableRoots(true);

    // Register file-system roots the server should respect
    const docs = mcp.roots.fileRoot("file:///home/user/documents", "Documents");
    const projects = mcp.roots.fileRoot("file:///home/user/projects", "Projects");
    try client.addRoot(allocator, docs.uri, docs.name);
    try client.addRoot(allocator, projects.uri, projects.name);

    std.debug.print("MCP Client initialized\n", .{});
    std.debug.print("  Name:   {s} v{s}\n", .{ client.config.name, client.config.version });
    std.debug.print("  Roots:  {d} configured\n", .{client.roots_list.items.len});
    std.debug.print("\nNext steps (production usage):\n", .{});
    std.debug.print("  1. Connect:    client.connectStdio(io, allocator, cmd, args)\n", .{});
    std.debug.print("  2. List tools: client.listTools(io, allocator)\n", .{});
    std.debug.print("  3. Call tool:  client.callTool(io, allocator, name, params)\n", .{});
}
