//! HTTP MCP Server Example
//!
//! Demonstrates running an MCP server over HTTP instead of STDIO.
//! Clients can POST JSON-RPC to http://localhost:8080/
//! and optionally receive SSE streams with Accept: text/event-stream.
//!
//! Features:
//! - HTTP transport with SSE support
//! - Tool with input schema
//! - Resource accessible via HTTP

const std = @import("std");
const mcp = @import("mcp");

pub fn main(init: std.process.Init) void {
    run(init.io, init.gpa) catch |err| mcp.reportError(err);
}

fn run(io: std.Io, allocator: std.mem.Allocator) !void {
    var sa_arena = std.heap.ArenaAllocator.init(allocator);
    defer sa_arena.deinit();
    const sa = sa_arena.allocator();

    const ping_schema = try buildPingSchema(sa);
    const hash_schema = try buildHashSchema(sa);

    var server: mcp.Server = .init(allocator, .{
        .name = "http-server",
        .version = "1.0.0",
        .title = "HTTP MCP Server",
        .description = "An MCP server accessible over HTTP with SSE support",
        .instructions = "POST JSON-RPC to http://localhost:8080/. Use 'ping' or 'hash_text'.",
    });
    defer server.deinit();

    try server.addTool(.{
        .name = "ping",
        .description = "Respond with 'pong' and optional custom message",
        .title = "Ping",
        .inputSchema = ping_schema,
        .annotations = .{ .readOnlyHint = true, .idempotentHint = true },
        .handler = pingHandler,
    });

    try server.addTool(.{
        .name = "hash_text",
        .description = "Compute a simple FNV-1a hash of the input text (returns hex string)",
        .title = "Hash Text",
        .inputSchema = hash_schema,
        .annotations = .{ .readOnlyHint = true, .idempotentHint = true },
        .handler = hashTextHandler,
    });

    try server.addResource(.{
        .uri = "http://localhost:8080/status",
        .name = "Server Status",
        .description = "Current server status",
        .mimeType = "application/json",
        .handler = statusHandler,
    });

    server.enableLogging();

    // Print connection info to stderr before blocking
    std.debug.print("HTTP MCP Server starting on http://localhost:8080\n", .{});
    std.debug.print("Send JSON-RPC via: curl -X POST http://localhost:8080/ -H 'Content-Type: application/json' -d '{{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"ping\"}}'\n", .{});

    // Run HTTP transport on localhost:8080
    try server.run(io, allocator, .{ .http = .{ .host = "localhost", .port = 8080 } });
}

fn buildPingSchema(allocator: std.mem.Allocator) !mcp.types.InputSchema {
    var b = mcp.schema.InputSchemaBuilder.init(allocator);
    defer b.deinit(allocator);
    _ = b.setSchemaDialect("https://json-schema.org/draft/2020-12/schema");
    _ = try b.addString(allocator, "message", "Optional custom message to echo back", false);
    return b.toInputSchema(allocator);
}

fn buildHashSchema(allocator: std.mem.Allocator) !mcp.types.InputSchema {
    var b = mcp.schema.InputSchemaBuilder.init(allocator);
    defer b.deinit(allocator);
    _ = b.setSchemaDialect("https://json-schema.org/draft/2020-12/schema");
    _ = try b.addString(allocator, "text", "Text to hash", true);
    return b.toInputSchema(allocator);
}

fn pingHandler(_: ?*anyopaque, _: std.Io, allocator: std.mem.Allocator, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    const msg = mcp.tools.getString(args, "message") orelse "";
    const reply = if (msg.len > 0)
        std.fmt.allocPrint(allocator, "pong: {s}", .{msg}) catch return mcp.tools.ToolError.OutOfMemory
    else
        allocator.dupe(u8, "pong") catch return mcp.tools.ToolError.OutOfMemory;
    return mcp.tools.textResult(allocator, reply) catch return mcp.tools.ToolError.OutOfMemory;
}

fn hashTextHandler(_: ?*anyopaque, _: std.Io, allocator: std.mem.Allocator, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    const text = mcp.tools.getString(args, "text") orelse
        return mcp.tools.errorResult(allocator, "Missing argument: text") catch return mcp.tools.ToolError.OutOfMemory;

    // FNV-1a 64-bit hash
    var h: u64 = 14695981039346656037;
    for (text) |byte| {
        h ^= @as(u64, byte);
        h = h *% 1099511628211;
    }

    const result = std.fmt.allocPrint(allocator, "{x:0>16}", .{h}) catch return mcp.tools.ToolError.OutOfMemory;
    return mcp.tools.textResult(allocator, result) catch return mcp.tools.ToolError.OutOfMemory;
}

fn statusHandler(_: ?*anyopaque, _: std.Io, _: std.mem.Allocator, uri: []const u8) mcp.resources.ResourceError!mcp.resources.ResourceContent {
    return .{
        .uri = uri,
        .mimeType = "application/json",
        .text = "{\"status\":\"ok\",\"server\":\"http-server\",\"version\":\"1.0.0\"}",
    };
}
