//! Simple MCP Server Example
//!
//! This example demonstrates how to create a basic MCP server
//! with tools, resources, and prompts.

const std = @import("std");

const mcp = @import("mcp");

pub fn main() void {
    run() catch |err| {
        mcp.reportError(err);
    };
}

fn run() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Check for updates in background
    if (mcp.report.checkForUpdates(allocator)) |t| t.detach();

    // Create server
    var server = mcp.Server.init(.{
        .name = "simple-server",
        .version = "1.0.0",
        .title = "Simple MCP Server",
        .description = "A simple example MCP server",
        .instructions = "This server provides basic greeting and echo tools.",
        .allocator = allocator,
    });
    defer server.deinit();

    // Add a greeting tool
    try server.addTool(.{
        .name = "greet",
        .description = "Greet a user by name",
        .title = "Greeting Tool",
        .annotations = .{
            .readOnlyHint = true,
            .idempotentHint = true,
            .destructiveHint = false,
        },
        .handler = greetHandler,
    });

    // Add an echo tool
    try server.addTool(.{
        .name = "echo",
        .description = "Echo back the input message",
        .title = "Echo Tool",
        .annotations = .{
            .readOnlyHint = true,
            .idempotentHint = true,
            .destructiveHint = false,
        },
        .handler = echoHandler,
    });

    // Add a simple resource
    try server.addResource(.{
        .uri = "info://server/about",
        .name = "About",
        .description = "Information about this server",
        .mimeType = "text/plain",
        .handler = aboutHandler,
    });

    // Add a prompt
    try server.addPrompt(.{
        .name = "introduce",
        .description = "Introduce the server capabilities",
        .title = "Introduction Prompt",
        .arguments = &[_]mcp.prompts.PromptArgument{
            .{ .name = "style", .description = "Introduction style (formal/casual)", .required = false },
        },
        .handler = introduceHandler,
    });

    // Enable logging
    server.enableLogging();
    server.enableTasks();

    // Run the server
    try server.run(.stdio);

    // To run with HTTP transport:
    // try server.run(.{ .http = .{ .host = "localhost", .port = 8080 } });
}

fn greetHandler(allocator: std.mem.Allocator, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    const name = mcp.tools.getString(args, "name") orelse "World";

    const greeting = std.fmt.allocPrint(allocator, "Hello, {s}! Welcome to MCP.", .{name}) catch return mcp.tools.ToolError.OutOfMemory;

    return mcp.tools.textResult(allocator, greeting) catch return mcp.tools.ToolError.OutOfMemory;
}

fn echoHandler(allocator: std.mem.Allocator, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    const message = mcp.tools.getString(args, "message") orelse "No message provided";

    // Demonstrate structured result
    var obj: std.json.ObjectMap = .empty;
    obj.put(allocator, "echo", .{ .string = message }) catch {};
    obj.put(allocator, "timestamp", .{ .integer = std.time.timestamp() }) catch {};

    return mcp.tools.structuredResult(allocator, .{ .object = obj }) catch return mcp.tools.ToolError.OutOfMemory;
}

fn aboutHandler(_: std.mem.Allocator, uri: []const u8) mcp.resources.ResourceError!mcp.resources.ResourceContent {
    return .{
        .uri = uri,
        .mimeType = "text/plain",
        .text = "Simple MCP Server v1.0.0\n\nThis is an example MCP server built with mcp.zig.",
    };
}

fn introduceHandler(allocator: std.mem.Allocator, args: ?std.json.Value) mcp.prompts.PromptError![]const mcp.prompts.PromptMessage {
    const style = mcp.prompts.getStringArg(args, "style") orelse "casual";
    _ = style;

    const messages = allocator.alloc(mcp.prompts.PromptMessage, 1) catch return mcp.prompts.PromptError.OutOfMemory;
    messages[0] = mcp.prompts.userMessage("Please introduce this MCP server and explain what tools it provides.");
    return messages;
}
