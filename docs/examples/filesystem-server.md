# Filesystem Server

The filesystem server demonstrates how to build a read-only MCP server that exposes local
files through both tools and resources.

**Source:** [`examples/filesystem_server.zig`](https://github.com/muhammad-fiaz/mcp.zig/blob/main/examples/filesystem_server.zig)

## Run

```bash
zig build run-filesystem
# or
./zig-out/bin/filesystem-server
```

## Features

| Feature | Description |
|---------|-------------|
| `read_file` tool | Read the text content of any file by absolute path |
| `list_dir` tool | List directory contents with kind indicators |
| Static resource | `file:///README.md` — project readme |
| Resource template | `file://{+path}` — access any local file as a resource |

## Tools

### `read_file`

```json
{
  "name": "read_file",
  "inputSchema": {
    "type": "object",
    "properties": {
      "path": { "type": "string", "description": "Absolute path to the file" }
    },
    "required": ["path"]
  }
}
```

**Example call:**
```json
{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"read_file","arguments":{"path":"/etc/hostname"}}}
```

### `list_dir`

```json
{
  "name": "list_dir",
  "inputSchema": {
    "type": "object",
    "properties": {
      "path": { "type": "string", "description": "Absolute path to the directory" }
    },
    "required": ["path"]
  }
}
```

## Key Implementation Patterns

### Real file I/O inside a tool handler

```zig
fn readFileHandler(
    _: ?*anyopaque,
    _: std.Io,
    allocator: std.mem.Allocator,
    args: ?std.json.Value,
) mcp.tools.ToolError!mcp.tools.ToolResult {
    const path = mcp.tools.getString(args, "path") orelse
        return mcp.tools.errorResult(allocator, "Missing argument: path")
            catch return mcp.tools.ToolError.OutOfMemory;

    const file = std.fs.openFileAbsolute(path, .{}) catch |err| {
        const msg = std.fmt.allocPrint(
            allocator, "Cannot open '{s}': {s}", .{ path, @errorName(err) }
        ) catch return mcp.tools.ToolError.OutOfMemory;
        return mcp.tools.errorResult(allocator, msg)
            catch return mcp.tools.ToolError.OutOfMemory;
    };
    defer file.close();

    const content = file.readToEndAlloc(allocator, 1024 * 1024) catch |err| {
        const msg = std.fmt.allocPrint(
            allocator, "Cannot read '{s}': {s}", .{ path, @errorName(err) }
        ) catch return mcp.tools.ToolError.OutOfMemory;
        return mcp.tools.errorResult(allocator, msg)
            catch return mcp.tools.ToolError.OutOfMemory;
    };

    return mcp.tools.textResult(allocator, content) catch return mcp.tools.ToolError.OutOfMemory;
}
```

### Resource template for arbitrary file paths

```zig
try server.addResourceTemplate(.{
    .uriTemplate = "file://{+path}",
    .name = "local-file",
    .title = "Local File",
    .description = "Access any local file by its absolute path",
    .mimeType = "text/plain",
});
```

## Security Note

This example grants full filesystem read access. In production, restrict paths by validating
against allowed root directories before calling `std.fs.openFileAbsolute`.
