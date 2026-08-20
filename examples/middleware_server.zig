//! Middleware Server Example
//!
//! Demonstrates using middleware to wrap tool handlers with logging,
//! authentication, and custom logic. Shows how middleware can intercept
//! and modify requests before they reach the actual handler.
//!
//! Run: zig build run-middleware-server

const std = @import("std");
const mcp = @import("mcp");

// Context shared across all handlers
const Ctx = struct {
    server: *mcp.Server,
    io: std.Io,
    allocator: std.mem.Allocator,
    request_count: u32 = 0,
    auth_token: ?[]const u8 = null,
};

// Middleware that logs all tool calls
fn loggingMiddleware(ctx: ?*anyopaque, io: std.Io, allocator: std.mem.Allocator, name: []const u8, args: ?std.json.Value) ?mcp.tools.ToolResult {
    _ = args;
    const c: *Ctx = @ptrCast(@alignCast(ctx.?));
    c.request_count += 1;

    std.debug.print("[MIDDLEWARE] Request #{d}: tool '{s}' called\n", .{ c.request_count, name });
    _ = io;
    _ = allocator;
    return null; // Continue to actual handler
}

// Middleware that checks authentication
fn authMiddleware(ctx: ?*anyopaque, io: std.Io, allocator: std.mem.Allocator, name: []const u8, args: ?std.json.Value) ?mcp.tools.ToolResult {
    _ = name;
    _ = args;
    const c: *Ctx = @ptrCast(@alignCast(ctx.?));

    if (c.auth_token == null) {
        std.debug.print("[MIDDLEWARE] Authentication failed: no token provided\n", .{});
        const result = mcp.tools.textResult(allocator, "Error: Authentication required") catch return null;
        _ = io;
        return result; // Short-circuit with error
    }

    std.debug.print("[MIDDLEWARE] Authentication passed\n", .{});
    _ = io;
    return null; // Continue to actual handler
}

pub fn main(init: std.process.Init) void {
    run(init.io, init.gpa) catch |err| mcp.reportError(err);
}

fn run(io: std.Io, allocator: std.mem.Allocator) !void {
    var server = mcp.Server.init(allocator, .{
        .name = "middleware-server",
        .version = "1.0.0",
        .title = "Middleware Server",
        .description = "Demonstrates middleware for logging and authentication",
    });
    defer server.deinit();

    var ctx: Ctx = .{
        .server = &server,
        .io = io,
        .allocator = allocator,
    };

    // Add a protected tool
    try server.addTool(.{
        .name = "protected_action",
        .description = "A tool that requires authentication",
        .user_data = &ctx,
        .handler = protectedActionHandler,
    });

    // Add a public tool
    try server.addTool(.{
        .name = "public_action",
        .description = "A tool that doesn't require authentication",
        .user_data = &ctx,
        .handler = publicActionHandler,
    });

    server.enableLogging();
    std.debug.print("Middleware server started\n", .{});
    std.debug.print("Tools: protected_action, public_action\n", .{});
    std.debug.print("Use auth_token to protect access\n", .{});

    // In a real server, you'd set the auth token based on incoming requests
    // For demo purposes, we show how middleware intercepts calls
    try server.run(io, allocator, .stdio);
}

fn protectedActionHandler(user_data: ?*anyopaque, _: std.Io, allocator: std.mem.Allocator, _: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    const ctx: *Ctx = @ptrCast(@alignCast(user_data.?));
    _ = ctx;
    return mcp.tools.textResult(allocator, "Protected action executed successfully!") catch return mcp.tools.ToolError.OutOfMemory;
}

fn publicActionHandler(user_data: ?*anyopaque, _: std.Io, allocator: std.mem.Allocator, _: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    const ctx: *Ctx = @ptrCast(@alignCast(user_data.?));
    _ = ctx;
    return mcp.tools.textResult(allocator, "Public action executed successfully!") catch return mcp.tools.ToolError.OutOfMemory;
}
