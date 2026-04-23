# Error Handling

Proper error handling is essential for robust MCP servers and clients.

## Error Types

### Tool Errors

```zig
pub const ToolError = error{
    InvalidArguments,
    ExecutionFailed,
    OutOfMemory,
    Unknown,
};
```

### Resource Errors

```zig
pub const ResourceError = error{
    NotFound,
    InvalidUri,
    AccessDenied,
    OutOfMemory,
};
```

### Prompt Errors

```zig
pub const PromptError = error{
    InvalidArguments,
    GenerationFailed,
    OutOfMemory,
    Unknown,
};
```

## Handling Errors in Handlers

### Returning Errors

```zig
fn myToolHandler(
    allocator: std.mem.Allocator,
    args: ?std.json.Value,
) mcp.tools.ToolError!mcp.tools.ToolResult {
    // Missing required argument
    const input = mcp.tools.getString(args, "input") orelse {
        return error.InvalidArguments;
    };

    // Operation failed
    const result = performOperation(input) catch {
        return error.ExecutionFailed;
    };

    // Memory allocation failed
    const output = allocator.alloc(u8, size) catch {
        return error.OutOfMemory;
    };

    return mcp.tools.textResult(allocator, output);
}
```

### Error Results vs Error Returns

There's a difference between returning an error and returning an error result:

**Return error** - Indicates failure to the MCP protocol:

```zig
return error.InvalidArguments;
```

**Return error result** - Successful response with error content:

```zig
return .{
    .content = &.{.{ .text = .{ .text = "File not found" } }},
    .isError = true,
};
```

### When to Use Which

| Scenario                          | Use                                |
| --------------------------------- | ---------------------------------- |
| Missing required argument         | `return error.InvalidArguments`    |
| Invalid argument value            | `return error.InvalidArguments`    |
| Expected failure (file not found) | Error result with `isError = true` |
| Unexpected failure                | `return error.ExecutionFailed`     |
| Out of memory                     | `return error.OutOfMemory`         |

## JSON-RPC Errors

### Standard Error Codes

```zig
const ErrorCode = struct {
    pub const PARSE_ERROR = -32700;
    pub const INVALID_REQUEST = -32600;
    pub const METHOD_NOT_FOUND = -32601;
    pub const INVALID_PARAMS = -32602;
    pub const INTERNAL_ERROR = -32603;
};
```

### Creating Error Responses

```zig
// Parse error (invalid JSON)
const err = mcp.jsonrpc.createParseError(null);

// Invalid request
const err = mcp.jsonrpc.createInvalidRequest(id, null);

// Method not found
const err = mcp.jsonrpc.createMethodNotFound(id, method);

// Invalid params
const err = mcp.jsonrpc.createInvalidParams(id, "Missing 'name' field");

// Internal error
const err = mcp.jsonrpc.createInternalError(id, null);
```

## Server Error Handling

The server handles errors from handlers:

```zig
fn handleToolCall(self: *Server, request: Request) !Message {
    const tool = self.findTool(request.params.name) orelse {
        return .{ .error_response = mcp.jsonrpc.createMethodNotFound(request.id, request.params.name) };
    };

    const result = tool.handler(self.allocator, request.params.arguments) catch |err| {
        return switch (err) {
            error.InvalidArguments => .{ .error_response = mcp.jsonrpc.createInvalidParams(request.id, "Invalid arguments") },
            error.OutOfMemory => .{ .error_response = mcp.jsonrpc.createInternalError(request.id, null) },
            else => .{ .error_response = mcp.jsonrpc.createInternalError(request.id, null) },
        };
    };

    return .{ .response = mcp.jsonrpc.createResponse(request.id, result.toJson()) };
}
```

## Best Practices

### Validate Early

```zig
fn handler(allocator: Allocator, args: ?json.Value) ToolError!ToolResult {
    // Validate all arguments first
    const a = getArg(args, "a") orelse return error.InvalidArguments;
    const b = getArg(args, "b") orelse return error.InvalidArguments;
    const c = getArg(args, "c") orelse return error.InvalidArguments;

    // Then perform operations
    return doWork(a, b, c);
}
```

### Provide Helpful Messages

```zig
fn handler(allocator: Allocator, args: ?json.Value) ToolError!ToolResult {
    const filename = getStringArg(args, "filename") orelse {
        return .{
            .content = &.{Content.createText("Missing 'filename' argument. Please provide the file to process.")},
            .isError = true,
        };
    };

    // ...
}
```

### Use errdefer for Cleanup

```zig
fn handler(allocator: Allocator, args: ?json.Value) ToolError!ToolResult {
    const buffer = try allocator.alloc(u8, 1024);
    errdefer allocator.free(buffer);

    const file = try std.fs.openFile(path, .{});
    errdefer file.close();

    // If any of the following fails, cleanup happens automatically
    try processFile(file, buffer);

    return .{ .content = &.{} };
}
```

## Complete Example

```zig
const std = @import("std");
const mcp = @import("mcp");

fn processFileHandler(
    allocator: std.mem.Allocator,
    args: ?std.json.Value,
) mcp.tools.ToolError!mcp.tools.ToolResult {
    // 1. Validate arguments
    const path = mcp.tools.getString(args, "path") orelse {
        return .{
            .content = &.{.{ .text = .{ .text = "Error: 'path' argument is required" } }},
            .isError = true,
        };
    };

    // 2. Check file exists
    std.fs.accessAbsolute(path, .{}) catch {
        return .{
            .content = &.{.{ .text = .{ .text = "Error: File not found at specified path" } }},
            .isError = true,
        };
    };

    // 3. Read file with proper cleanup
    const contents = std.fs.cwd().readFileAlloc(
        allocator,
        path,
        10 * 1024 * 1024, // 10MB limit
    ) catch |err| {
        const message = switch (err) {
            error.FileTooBig => "Error: File exceeds 10MB limit",
            error.AccessDenied => "Error: Permission denied",
            else => "Error: Failed to read file",
        };
        return .{
            .content = &.{.{ .text = .{ .text = message } }},
            .isError = true,
        };
    };
    defer allocator.free(contents);

    // 4. Process and return
    const result = try std.fmt.allocPrint(
        allocator,
        "Successfully processed {d} bytes from {s}",
        .{ contents.len, path },
    );

    return .{
        .content = &.{.{ .text = .{ .text = result } }},
    };
}
```

## Application-Level Error Reporting

When building MCP servers or clients, it's recommended to handle top-level errors gracefully and provide users with a way to report bugs. mcp.zig provides built-in utilities for this.

### Using mcp.reportError

Wrap your `main` application logic to catch and report unexpected errors:

```zig
pub fn main(init: std.process.Init) void {
    if (run(init.io, init.gpa)) {
        // Success
    } else |err| {
        // Report error with instructions and link to issue tracker
        mcp.reportError(err);
        std.process.exit(1);
    }
}
```

This will print the error along with the GitHub Issues URL where users can report bugs if they suspect a library issue.

### Accessing Bug Report URL

You can access the official bug report URL directly if you need to construct custom error messages:

```zig
const url = mcp.ISSUES_URL;
// https://github.com/muhammad-fiaz/mcp.zig/issues
```

## Update Checking

To ensure your application is running the latest version of mcp.zig, you can enable background update checks. This will check GitHub Releases and log a message if a new version is available.

```zig
pub fn main(init: std.process.Init) void {
    run(init.io, init.gpa) catch |err| {
        mcp.reportError(err);
    };
}

fn run(io: std.Io, allocator: std.mem.Allocator) !void {
    // Check for updates in background
    // This runs on a separate thread; detach to let it run in background
    if (mcp.report.checkForUpdates(io, allocator)) |t| t.detach();

    // Continue with server initialization...
}
```

## Next Steps

- [Tools Guide](/guide/tools) - Tool error handling
- [Resources Guide](/guide/resources) - Resource error handling
- [JSON-RPC Guide](/guide/jsonrpc) - Protocol errors
