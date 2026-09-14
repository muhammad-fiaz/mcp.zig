//! Graceful Shutdown Example
//!
//! Demonstrates graceful shutdown of an MCP server.
//! Shows how to properly shut down the server after
//! processing the current request.
//!
//! Run: zig build run-shutdown-example

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
        .name = "shutdown-server",
        .version = "1.0.0",
        .title = "Shutdown Server",
        .description = "Demonstrates graceful shutdown",
        .instructions = "Call 'shutdown' tool to gracefully stop the server.",
    });
    defer server.deinit();

    var ctx: Ctx = .{
        .server = &server,
        .io = io,
        .allocator = allocator,
    };

    // Add a shutdown tool
    try server.addTool(.{
        .name = "shutdown",
        .description = "Gracefully shutdown the server",
        .user_data = &ctx,
        .handler = shutdownHandler,
    });

    // Add a normal tool
    try server.addTool(.{
        .name = "process",
        .description = "Process some data",
        .user_data = &ctx,
        .handler = processHandler,
    });

    server.enableLogging();
    std.debug.print("Shutdown server started\n", .{});
    std.debug.print("Tools: process, shutdown\n", .{});
    std.debug.print("Call 'shutdown' to gracefully stop the server\n", .{});

    try server.run(io, allocator, .stdio);
}

fn shutdownHandler(user_data: ?*anyopaque, _: std.Io, allocator: std.mem.Allocator, _: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    const ctx: *Ctx = @ptrCast(@alignCast(user_data.?));
    std.debug.print("Shutdown requested - server will stop after this request\n", .{});
    ctx.server.shutdown();
    return mcp.tools.textResult(allocator, "Server shutting down gracefully") catch return mcp.tools.ToolError.OutOfMemory;
}

fn processHandler(user_data: ?*anyopaque, _: std.Io, allocator: std.mem.Allocator, _: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    const ctx: *Ctx = @ptrCast(@alignCast(user_data.?));
    _ = ctx;
    return mcp.tools.textResult(allocator, "Data processed successfully") catch return mcp.tools.ToolError.OutOfMemory;
}
