//! Health Check Example
//!
//! Demonstrates the built-in health check endpoint.
//! Every MCP server automatically responds to health/check requests
//! with server status, uptime, and connection information.
//!
//! Run: zig build run-health-check-example

const std = @import("std");
const mcp = @import("mcp");

// Context shared across all handlers
const Ctx = struct {
    server: *mcp.Server,
    io: std.Io,
    allocator: std.mem.Allocator,
};

pub fn main(init: std.process.Init) void {
    run(init.io, init.gpa) catch |err| mcp.reportError(err);
}

fn run(io: std.Io, allocator: std.mem.Allocator) !void {
    var server = mcp.Server.init(allocator, .{
        .name = "health-check-server",
        .version = "1.0.0",
        .title = "Health Check Server",
        .description = "Demonstrates the built-in health check endpoint",
        .instructions = "This server responds to health/check requests automatically.",
    });
    defer server.deinit();

    var ctx: Ctx = .{
        .server = &server,
        .io = io,
        .allocator = allocator,
    };

    // Add some tools
    try server.addTool(.{
        .name = "echo",
        .description = "Echo back the input",
        .user_data = &ctx,
        .handler = echoHandler,
    });

    server.enableLogging();
    std.debug.print("Health Check server started\n", .{});
    std.debug.print("The server automatically handles health/check requests\n", .{});
    std.debug.print("Test with: echo '{s}' | jq .\n", .{
        \\{"jsonrpc":"2.0","id":1,"method":"health/check"}
    });

    try server.run(io, allocator, .stdio);
}

fn echoHandler(user_data: ?*anyopaque, _: std.Io, allocator: std.mem.Allocator, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    const ctx: *Ctx = @ptrCast(@alignCast(user_data.?));
    _ = ctx;

    const input = mcp.tools.getString(args, "input") orelse
        return mcp.tools.textResult(allocator, "No input provided") catch return mcp.tools.ToolError.OutOfMemory;

    return mcp.tools.textResult(allocator, input) catch return mcp.tools.ToolError.OutOfMemory;
}
