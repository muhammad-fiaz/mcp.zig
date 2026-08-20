//! Batch Client Example
//!
//! Demonstrates sending multiple JSON-RPC requests as a batch.
//! This is useful for reducing network overhead when you need
//! to perform multiple operations at once.
//!
//! Run: zig build run-batch-client

const std = @import("std");
const mcp = @import("mcp");

pub fn main(init: std.process.Init) void {
    run(init.io, init.gpa, init.minimal.args) catch |err| mcp.reportError(err);
}

fn run(io: std.Io, allocator: std.mem.Allocator, process_args: std.process.Args) !void {
    var args = try std.process.Args.Iterator.initAllocator(process_args, allocator);
    defer args.deinit();

    const exe = args.next() orelse "batch-client";
    const server_cmd = args.next();

    if (server_cmd == null) {
        std.debug.print("Usage: {s} <server-command>\n", .{exe});
        std.debug.print("  Example: {s} zig-out/bin/example-server\n", .{exe});
        std.debug.print("\nThis client demonstrates batch requests by sending\n", .{});
        std.debug.print("multiple operations in a single batch.\n", .{});
        return;
    }

    // Create client
    var client = mcp.Client.init(io, allocator, .{
        .name = "batch-client",
        .version = "1.0.0",
        .title = "Batch MCP Client",
    });
    defer client.deinit();

    // Connect to server
    std.debug.print("Connecting to server: {s}...\n", .{server_cmd.?});
    try client.connectStdio(server_cmd.?, &.{});
    std.debug.print("Connected!\n", .{});

    // Create a batch request builder
    var batch = mcp.BatchRequest.init(allocator);
    defer batch.deinit();

    // Add multiple requests to the batch
    try batch.addDiscover();
    try batch.addListTools();
    try batch.addListResources();
    try batch.addListPrompts();
    try batch.addHealthCheck();

    std.debug.print("\nSending batch of {d} requests...\n", .{batch.requests.items.len});

    // In a real implementation, you'd send all requests at once
    // and collect all responses. For now, we demonstrate the batch builder.
    for (batch.requests.items) |item| {
        std.debug.print("  Queued: {s}\n", .{item.method});
    }

    std.debug.print("\nBatch built with {d} requests.\n", .{batch.requests.items.len});
    std.debug.print("In a full implementation, these would be sent as a single\n", .{});
    std.debug.print("JSON-RPC batch request and responses collected.\n", .{});

    client.disconnect();
    std.debug.print("\nDisconnected from server.\n", .{});
}
