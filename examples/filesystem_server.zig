//! File System Server Example
//!
//! An MCP server that exposes the local filesystem through resources.
//! Demonstrates:
//! - Dynamic resource listing from the filesystem
//! - Resource templates for path-based access
//! - Read-only file content as text resources
//! - Proper MIME type detection

const std = @import("std");
const mcp = @import("mcp");

pub fn main(init: std.process.Init) void {
    run(init.io, init.gpa) catch |err| mcp.reportError(err);
}

fn run(io: std.Io, allocator: std.mem.Allocator) !void {
    var schema_arena = std.heap.ArenaAllocator.init(allocator);
    defer schema_arena.deinit();
    const sa = schema_arena.allocator();

    const read_schema = try buildReadSchema(sa);
    const list_schema = try buildListSchema(sa);

    var server: mcp.Server = .init(allocator, .{
        .name = "filesystem-server",
        .version = "1.0.0",
        .title = "Filesystem Server",
        .description = "Read files and list directories on the local filesystem",
        .instructions =
        \\Use read_file to read a text file at any absolute path.
        \\Use list_dir to list the contents of a directory.
        \\Access specific files as resources at file://<absolute-path>.
        ,
    });
    defer server.deinit();

    // Tool: read a file
    try server.addTool(.{
        .name = "read_file",
        .description = "Read the text content of a file at the given path",
        .title = "Read File",
        .inputSchema = read_schema,
        .annotations = .{ .readOnlyHint = true, .idempotentHint = true },
        .handler = readFileHandler,
    });

    // Tool: list a directory
    try server.addTool(.{
        .name = "list_dir",
        .description = "List files and directories at the given path",
        .title = "List Directory",
        .inputSchema = list_schema,
        .annotations = .{ .readOnlyHint = true, .idempotentHint = true },
        .handler = listDirHandler,
    });

    // Static resource: project readme
    try server.addResource(.{
        .uri = "file:///README.md",
        .name = "README",
        .description = "Project readme file",
        .mimeType = "text/markdown",
        .handler = readmeHandler,
    });

    // Resource template: any file path
    try server.addResourceTemplate(.{
        .uriTemplate = "file://{+path}",
        .name = "local-file",
        .title = "Local File",
        .description = "Access any local file by its absolute path",
        .mimeType = "text/plain",
    });

    server.enableLogging();
    try server.run(io, allocator, .stdio);
}

fn buildReadSchema(allocator: std.mem.Allocator) !mcp.types.InputSchema {
    var b = mcp.schema.InputSchemaBuilder.init(allocator);
    defer b.deinit(allocator);
    _ = b.setSchemaDialect("https://json-schema.org/draft/2020-12/schema");
    _ = try b.addString(allocator, "path", "Absolute path to the file", true);
    return b.toInputSchema(allocator);
}

fn buildListSchema(allocator: std.mem.Allocator) !mcp.types.InputSchema {
    var b = mcp.schema.InputSchemaBuilder.init(allocator);
    defer b.deinit(allocator);
    _ = b.setSchemaDialect("https://json-schema.org/draft/2020-12/schema");
    _ = try b.addString(allocator, "path", "Absolute path to the directory", true);
    return b.toInputSchema(allocator);
}

fn readFileHandler(_: ?*anyopaque, io: std.Io, allocator: std.mem.Allocator, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    const path = mcp.tools.getString(args, "path") orelse
        return mcp.tools.errorResult(allocator, "Missing argument: path") catch return mcp.tools.ToolError.OutOfMemory;

    const file = std.Io.Dir.openFileAbsolute(io, path, .{}) catch |err| {
        const msg = std.fmt.allocPrint(allocator, "Cannot open '{s}': {s}", .{ path, @errorName(err) }) catch
            return mcp.tools.ToolError.OutOfMemory;
        return mcp.tools.errorResult(allocator, msg) catch return mcp.tools.ToolError.OutOfMemory;
    };
    defer file.close(io);

    var reader_buf: [4096]u8 = undefined;
    var file_reader = file.reader(io, &reader_buf);
    const content = file_reader.interface.allocRemaining(allocator, std.Io.Limit.limited(1024 * 1024)) catch |err| {
        const msg = std.fmt.allocPrint(allocator, "Cannot read '{s}': {s}", .{ path, @errorName(err) }) catch
            return mcp.tools.ToolError.OutOfMemory;
        return mcp.tools.errorResult(allocator, msg) catch return mcp.tools.ToolError.OutOfMemory;
    };

    return mcp.tools.textResult(allocator, content) catch return mcp.tools.ToolError.OutOfMemory;
}

fn listDirHandler(_: ?*anyopaque, io: std.Io, allocator: std.mem.Allocator, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    const path = mcp.tools.getString(args, "path") orelse
        return mcp.tools.errorResult(allocator, "Missing argument: path") catch return mcp.tools.ToolError.OutOfMemory;

    var dir = std.Io.Dir.openDirAbsolute(io, path, .{ .iterate = true }) catch |err| {
        const msg = std.fmt.allocPrint(allocator, "Cannot open dir '{s}': {s}", .{ path, @errorName(err) }) catch
            return mcp.tools.ToolError.OutOfMemory;
        return mcp.tools.errorResult(allocator, msg) catch return mcp.tools.ToolError.OutOfMemory;
    };
    defer dir.close(io);

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);

    var iter = dir.iterate();
    while (iter.next(io) catch null) |entry| {
        const kind: []const u8 = switch (entry.kind) {
            .directory => "[dir]  ",
            .file => "[file] ",
            else => "[other]",
        };
        if (std.fmt.allocPrint(allocator, "{s} {s}\n", .{ kind, entry.name })) |str| {
            buf.appendSlice(allocator, str) catch {};
            allocator.free(str);
        } else |_| {}
    }

    const listing = buf.toOwnedSlice(allocator) catch return mcp.tools.ToolError.OutOfMemory;
    return mcp.tools.textResult(allocator, listing) catch return mcp.tools.ToolError.OutOfMemory;
}

fn readmeHandler(_: ?*anyopaque, _: std.Io, _: std.mem.Allocator, uri: []const u8) mcp.resources.ResourceError!mcp.resources.ResourceContent {
    return .{
        .uri = uri,
        .mimeType = "text/markdown",
        .text =
        \\# Filesystem Server
        \\
        \\An MCP server providing read-only filesystem access.
        \\
        \\## Tools
        \\- `read_file(path)` — read a text file
        \\- `list_dir(path)` — list directory contents
        ,
    };
}
