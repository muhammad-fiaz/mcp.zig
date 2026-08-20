//! Rate Limiter Example
//!
//! Demonstrates using the RateLimiter to prevent abuse of tool calls.
//! Shows how to implement call rate limiting for sensitive operations.
//!
//! Run: zig build run-rate-limiter-example

const std = @import("std");
const mcp = @import("mcp");

// Context shared across all handlers
const Ctx = struct {
    server: *mcp.Server,
    io: std.Io,
    allocator: std.mem.Allocator,
    limiter: mcp.RateLimiter,
};

pub fn main(init: std.process.Init) void {
    run(init.io, init.gpa) catch |err| mcp.reportError(err);
}

fn run(io: std.Io, allocator: std.mem.Allocator) !void {
    var server = mcp.Server.init(allocator, .{
        .name = "rate-limiter-server",
        .version = "1.0.0",
        .title = "Rate Limiter Server",
        .description = "Demonstrates rate limiting for tool calls",
    });
    defer server.deinit();

    var ctx: Ctx = .{
        .server = &server,
        .io = io,
        .allocator = allocator,
        .limiter = mcp.RateLimiter.init(3), // Max 3 calls
    };

    // Add a rate-limited tool
    try server.addTool(.{
        .name = "limited_action",
        .description = "A tool that can only be called 3 times",
        .user_data = &ctx,
        .handler = limitedActionHandler,
    });

    // Add an unlimited tool
    try server.addTool(.{
        .name = "unlimited_action",
        .description = "A tool with no rate limit",
        .user_data = &ctx,
        .handler = unlimitedActionHandler,
    });

    server.enableLogging();
    std.debug.print("Rate Limiter server started\n", .{});
    std.debug.print("Tools: limited_action (max 3), unlimited_action (no limit)\n", .{});

    try server.run(io, allocator, .stdio);
}

fn limitedActionHandler(user_data: ?*anyopaque, _: std.Io, allocator: std.mem.Allocator, _: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    const ctx: *Ctx = @ptrCast(@alignCast(user_data.?));

    if (!ctx.limiter.check()) {
        std.debug.print("[RATE LIMITER] Rate limit exceeded!\n", .{});
        return mcp.tools.errorResult(allocator, "Rate limit exceeded. Try again later.") catch return mcp.tools.ToolError.OutOfMemory;
    }

    std.debug.print("[RATE LIMITER] Call allowed (remaining: {d})\n", .{3 - ctx.limiter.call_count});
    return mcp.tools.textResult(allocator, "Limited action executed!") catch return mcp.tools.ToolError.OutOfMemory;
}

fn unlimitedActionHandler(user_data: ?*anyopaque, _: std.Io, allocator: std.mem.Allocator, _: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    const ctx: *Ctx = @ptrCast(@alignCast(user_data.?));
    _ = ctx;
    return mcp.tools.textResult(allocator, "Unlimited action executed!") catch return mcp.tools.ToolError.OutOfMemory;
}
