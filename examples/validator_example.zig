//! Request Validator Example
//!
//! Demonstrates validating tool arguments against a schema.
//! Shows how to ensure required fields are present before
//! executing tool handlers.
//!
//! Run: zig build run-validator-example

const std = @import("std");
const mcp = @import("mcp");

// Context shared across all handlers
const Ctx = struct {
    server: *mcp.Server,
    io: std.Io,
    allocator: std.mem.Allocator,
};

// Validators for our tools
const create_user_validator = mcp.RequestValidator.init(
    &.{ "username", "email" }, // Required fields
    &.{ "age", "role" }, // Optional fields
);

const login_validator = mcp.RequestValidator.init(
    &.{ "username", "password" }, // Required fields
    &.{}, // No optional fields
);

pub fn main(init: std.process.Init) void {
    run(init.io, init.gpa) catch |err| mcp.reportError(err);
}

fn run(io: std.Io, allocator: std.mem.Allocator) !void {
    var server = mcp.Server.init(allocator, .{
        .name = "validator-server",
        .version = "1.0.0",
        .title = "Validator Server",
        .description = "Demonstrates request validation",
        .instructions = "Tools validate their input arguments before execution.",
    });
    defer server.deinit();

    var ctx: Ctx = .{
        .server = &server,
        .io = io,
        .allocator = allocator,
    };

    // Add a tool with validation
    try server.addTool(.{
        .name = "create_user",
        .description = "Create a new user (requires username and email)",
        .user_data = &ctx,
        .handler = createUserHandler,
    });

    // Add another tool with validation
    try server.addTool(.{
        .name = "login",
        .description = "Login (requires username and password)",
        .user_data = &ctx,
        .handler = loginHandler,
    });

    server.enableLogging();
    std.debug.print("Validator server started\n", .{});
    std.debug.print("Tools: create_user (requires username, email), login (requires username, password)\n", .{});

    try server.run(io, allocator, .stdio);
}

fn createUserHandler(_: ?*anyopaque, _: std.Io, allocator: std.mem.Allocator, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    // Validate arguments
    if (create_user_validator.validate(args)) |error_msg| {
        const msg = std.fmt.allocPrint(allocator, "Validation error: {s}", .{error_msg}) catch
            return mcp.tools.ToolError.OutOfMemory;
        return mcp.tools.errorResult(allocator, msg) catch return mcp.tools.ToolError.OutOfMemory;
    }

    const username = mcp.tools.getString(args, "username") orelse
        return mcp.tools.errorResult(allocator, "Missing username") catch return mcp.tools.ToolError.OutOfMemory;
    const email = mcp.tools.getString(args, "email") orelse
        return mcp.tools.errorResult(allocator, "Missing email") catch return mcp.tools.ToolError.OutOfMemory;

    const msg = std.fmt.allocPrint(allocator, "User '{s}' created with email '{s}'", .{ username, email }) catch
        return mcp.tools.ToolError.OutOfMemory;
    return mcp.tools.textResult(allocator, msg) catch return mcp.tools.ToolError.OutOfMemory;
}

fn loginHandler(_: ?*anyopaque, _: std.Io, allocator: std.mem.Allocator, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    // Validate arguments
    if (login_validator.validate(args)) |error_msg| {
        const msg = std.fmt.allocPrint(allocator, "Validation error: {s}", .{error_msg}) catch
            return mcp.tools.ToolError.OutOfMemory;
        return mcp.tools.errorResult(allocator, msg) catch return mcp.tools.ToolError.OutOfMemory;
    }

    const username = mcp.tools.getString(args, "username") orelse
        return mcp.tools.errorResult(allocator, "Missing username") catch return mcp.tools.ToolError.OutOfMemory;

    const msg = std.fmt.allocPrint(allocator, "User '{s}' logged in successfully", .{username}) catch
        return mcp.tools.ToolError.OutOfMemory;
    return mcp.tools.textResult(allocator, msg) catch return mcp.tools.ToolError.OutOfMemory;
}
