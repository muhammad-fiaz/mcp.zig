# HTTP Server

The HTTP server example runs an MCP server over HTTP instead of STDIO, with automatic
Server-Sent Events (SSE) fallback for clients that request streaming.

**Source:** [`examples/http_server.zig`](https://github.com/muhammad-fiaz/mcp.zig/blob/main/examples/http_server.zig)

## Run

```bash
zig build run-http
# or
./zig-out/bin/http-server
```

The server listens on `http://localhost:8080`.

## Features

| Feature | Description |
|---------|-------------|
| HTTP transport | POST JSON-RPC to `http://localhost:8080/` |
| SSE support | Add `Accept: text/event-stream` for streaming responses |
| `ping` tool | Respond with pong + optional message |
| `hash_text` tool | FNV-1a 64-bit hash of any string |
| Status resource | `http://localhost:8080/status` (JSON) |

## Quick Test

**Initialize:**
```bash
curl -X POST http://localhost:8080/ \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"test","version":"1.0.0"}}}'
```

**List tools:**
```bash
curl -X POST http://localhost:8080/ \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","id":2,"method":"tools/list"}'
```

**Call ping:**
```bash
curl -X POST http://localhost:8080/ \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"ping","arguments":{"message":"hello"}}}'
```

**With SSE streaming:**
```bash
curl -X POST http://localhost:8080/ \
  -H "Content-Type: application/json" \
  -H "Accept: text/event-stream" \
  -d '{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"hash_text","arguments":{"text":"mcp.zig"}}}'
```

PowerShell equivalent:
```powershell
$body = '{"jsonrpc":"2.0","id":1,"method":"tools/list"}'
Invoke-RestMethod -Method Post -Uri http://localhost:8080/ `
  -ContentType 'application/json' -Body $body
```

## HTTP Transport Configuration

```zig
try server.run(io, allocator, .{
    .http = .{
        .host = "localhost",  // or "0.0.0.0" to bind all interfaces
        .port = 8080,
    }
});
```

## `hash_text` Tool

Demonstrates a pure computation tool with no external dependencies:

```zig
fn hashTextHandler(
    _: ?*anyopaque,
    _: std.Io,
    allocator: std.mem.Allocator,
    args: ?std.json.Value,
) mcp.tools.ToolError!mcp.tools.ToolResult {
    const text = mcp.tools.getString(args, "text") orelse
        return mcp.tools.errorResult(allocator, "Missing argument: text")
            catch return mcp.tools.ToolError.OutOfMemory;

    // FNV-1a 64-bit hash
    var h: u64 = 14695981039346656037;
    for (text) |byte| {
        h ^= @as(u64, byte);
        h = h *% 1099511628211;
    }

    const result = std.fmt.allocPrint(allocator, "{x:0>16}", .{h})
        catch return mcp.tools.ToolError.OutOfMemory;
    return mcp.tools.textResult(allocator, result)
        catch return mcp.tools.ToolError.OutOfMemory;
}
```

## Security

- By default binds to `127.0.0.1` (localhost only)
- The HTTP transport validates `Origin` headers to prevent DNS rebinding attacks
- For production, add proper authentication via bearer tokens or API keys in your reverse proxy
