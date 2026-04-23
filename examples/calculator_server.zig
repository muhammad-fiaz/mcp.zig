//! Calculator Server Example
//!
//! A simple calculator MCP server with arithmetic operations.

const std = @import("std");

const mcp = @import("mcp");

pub fn main(init: std.process.Init) void {
    run(init.io, init.gpa) catch |err| {
        mcp.reportError(err);
    };
}

fn run(io: std.Io, allocator: std.mem.Allocator) !void {
    var server: mcp.Server = .init(allocator, .{
        .name = "calculator-server",
        .version = "1.0.0",
        .title = "Calculator Server",
        .description = "Perform arithmetic operations",
        .instructions = "Use add, subtract, multiply, or divide tools with 'a' and 'b' number arguments.",
        });
    defer server.deinit();

    // Add arithmetic tools
    try server.addTool(.{
        .name = "add",
        .description = "Add two numbers",
        .title = "Addition",
        .annotations = .{
            .readOnlyHint = true,
            .idempotentHint = true,
            .destructiveHint = false,
        },
        .handler = addHandler,
    });

    try server.addTool(.{
        .name = "subtract",
        .description = "Subtract two numbers",
        .title = "Subtraction",
        .annotations = .{
            .readOnlyHint = true,
            .idempotentHint = true,
            .destructiveHint = false,
        },
        .handler = subtractHandler,
    });

    try server.addTool(.{
        .name = "multiply",
        .description = "Multiply two numbers",
        .title = "Multiplication",
        .annotations = .{
            .readOnlyHint = true,
            .idempotentHint = true,
            .destructiveHint = false,
        },
        .handler = multiplyHandler,
    });

    try server.addTool(.{
        .name = "divide",
        .description = "Divide two numbers",
        .title = "Division",
        .annotations = .{
            .readOnlyHint = true,
            .idempotentHint = true,
            .destructiveHint = false,
        },
        .execution = .{ .taskSupport = "optional" },
        .handler = divideHandler,
    });

    server.enableLogging();
    server.enableTasks();
    try server.run(io, allocator, .stdio);

    // To run with HTTP transport:
    // try server.run(io, allocator, .{ .http = .{ .host = "localhost", .port = 8080 } });
}

fn addHandler(allocator: std.mem.Allocator, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    const a = mcp.tools.getFloat(args, "a") orelse {
        return mcp.tools.errorResult(allocator, "Missing argument: a") catch return mcp.tools.ToolError.OutOfMemory;
    };
    const b = mcp.tools.getFloat(args, "b") orelse {
        return mcp.tools.errorResult(allocator, "Missing argument: b") catch return mcp.tools.ToolError.OutOfMemory;
    };

    var buf: [64]u8 = undefined;
    const result = std.fmt.bufPrint(&buf, "{d} + {d} = {d}", .{ a, b, a + b }) catch "Error";
    return mcp.tools.textResult(allocator, result) catch return mcp.tools.ToolError.OutOfMemory;
}

fn subtractHandler(allocator: std.mem.Allocator, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    const a = mcp.tools.getFloat(args, "a") orelse {
        return mcp.tools.errorResult(allocator, "Missing argument: a") catch return mcp.tools.ToolError.OutOfMemory;
    };
    const b = mcp.tools.getFloat(args, "b") orelse {
        return mcp.tools.errorResult(allocator, "Missing argument: b") catch return mcp.tools.ToolError.OutOfMemory;
    };

    var buf: [64]u8 = undefined;
    const result = std.fmt.bufPrint(&buf, "{d} - {d} = {d}", .{ a, b, a - b }) catch "Error";
    return mcp.tools.textResult(allocator, result) catch return mcp.tools.ToolError.OutOfMemory;
}

fn multiplyHandler(allocator: std.mem.Allocator, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    const a = mcp.tools.getFloat(args, "a") orelse {
        return mcp.tools.errorResult(allocator, "Missing argument: a") catch return mcp.tools.ToolError.OutOfMemory;
    };
    const b = mcp.tools.getFloat(args, "b") orelse {
        return mcp.tools.errorResult(allocator, "Missing argument: b") catch return mcp.tools.ToolError.OutOfMemory;
    };

    var buf: [64]u8 = undefined;
    const result = std.fmt.bufPrint(&buf, "{d} * {d} = {d}", .{ a, b, a * b }) catch "Error";
    return mcp.tools.textResult(allocator, result) catch return mcp.tools.ToolError.OutOfMemory;
}

fn divideHandler(allocator: std.mem.Allocator, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    const a = mcp.tools.getFloat(args, "a") orelse {
        return mcp.tools.errorResult(allocator, "Missing argument: a") catch return mcp.tools.ToolError.OutOfMemory;
    };
    const b = mcp.tools.getFloat(args, "b") orelse {
        return mcp.tools.errorResult(allocator, "Missing argument: b") catch return mcp.tools.ToolError.OutOfMemory;
    };

    if (b == 0) {
        return mcp.tools.errorResult(allocator, "Division by zero") catch return mcp.tools.ToolError.OutOfMemory;
    }

    var buf: [64]u8 = undefined;
    const result = std.fmt.bufPrint(&buf, "{d} / {d} = {d}", .{ a, b, a / b }) catch "Error";
    return mcp.tools.textResult(allocator, result) catch return mcp.tools.ToolError.OutOfMemory;
}
