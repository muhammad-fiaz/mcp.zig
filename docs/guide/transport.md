# Transport

Transports handle the communication layer between MCP clients and servers.

## Available Transports

| Transport | Use Case        | Protocol     |
| --------- | --------------- | ------------ |
| **STDIO** | Local processes | stdin/stdout |
| **HTTP**  | Remote servers  | HTTP/HTTPS   |

## STDIO Transport

The most common transport for local MCP servers.

### Server Side

```zig
try server.run(io, allocator, .stdio);
```

### Client Side

```zig
try client.connectStdio(io, allocator, "./my-server", &.{});
```

### How It Works

1. Client spawns the server as a child process
2. Communication happens via stdin/stdout
3. JSON-RPC messages are exchanged line by line

### Message Format

Each message is a single line of JSON followed by a newline:

```
{"jsonrpc":"2.0","method":"initialize","id":1,"params":{...}}\n
```

## HTTP Transport

For remote MCP servers or web-based integration.

### Server Side

```zig
try server.run(io, allocator, .{ .http = .{ .port = 8080 } });
```

Custom host/domain and port:

```zig
try server.run(io, allocator, .{ .http = .{ .host = "api.example.com", .port = 8443 } });
```

### Client Side

```zig
try client.connectHttp(io, allocator, "http://localhost:8080");
```

### Endpoints

| Endpoint | Method | Description       |
| -------- | ------ | ----------------- |
| `/`      | POST   | JSON-RPC endpoint |

### HTTP Request Format

Send JSON-RPC payloads as `application/json` with HTTP `POST`:

```bash
curl -X POST http://localhost:8080 \
    -H "Content-Type: application/json" \
    -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"test","version":"1.0.0"}}}'
```

The response body contains the JSON-RPC response.

### Example Pattern

Most examples default to `stdio` and include optional HTTP run lines.
`examples/simple_server.zig` is currently configured for HTTP mode and can be switched back to `stdio` if needed.

## Custom Transports

Implement the `Transport` interface for custom transports:

```zig
const MyTransport = struct {
    pub fn send(self: *MyTransport, io: std.Io, allocator: std.mem.Allocator, message: []const u8) !void {
        // Send the message
    }

    pub fn receive(self: *MyTransport, io: std.Io, allocator: std.mem.Allocator) !?[]const u8 {
        // Receive a message
    }

    pub fn close(self: *MyTransport) void {
        // Close the transport
    }

    pub fn transport(self: *MyTransport) mcp.transport.Transport {
        return .{
            .ptr = self,
            .vtable = &.{
                .send = send_wrapper,
                .receive = receive_wrapper,
                .close = close_wrapper,
            },
        };
    }
};
```

## Transport Options

### STDIO Options

```zig
const stdio_transport = mcp.transport.StdioTransport.init(allocator);
```

### HTTP Options

```zig
const http_transport = mcp.transport.HttpTransport.init(
    allocator,
    "http://localhost:8080",
);
```

## Best Practices

### STDIO

::: tip Recommended for

- Command-line tools
- Local development
- IDE integrations
- Desktop applications
  :::

### HTTP

::: tip Recommended for

- Remote servers
- Microservices
- Cloud deployments
- Multi-client scenarios
  :::

## Error Handling

```zig
const message = transport.receive(io, allocator) catch |err| {
    switch (err) {
        error.ConnectionClosed => {
            // Handle disconnect
        },
        error.EndOfStream => {
            // Handle graceful end of input
        },
        else => return err,
    }
};
```

## Complete Example

```zig
const std = @import("std");
const mcp = @import("mcp");

pub fn main(init: std.process.Init) void {
    run(init.io, init.gpa, init.minimal.args) catch |err| {
        mcp.reportError(err);
    };
}

fn run(io: std.Io, allocator: std.mem.Allocator, process_args: std.process.Args) !void {
    // Create server
    var server: mcp.Server = .init(allocator, .{
        .name = "multi-transport-server",
        .version = "1.0.0",
    });
    defer server.deinit();

    // Get transport mode from args
    var args = try std.process.Args.Iterator.initAllocator(process_args, allocator);
    defer args.deinit();
    _ = args.next();
    const mode = args.next() orelse "stdio";

    if (std.mem.eql(u8, mode, "http")) {
        std.debug.print("Starting HTTP server on port 8080...\n", .{});
        try server.run(io, allocator, .{ .http = .{ .port = 8080 } });
    } else {
        std.debug.print("Starting STDIO server...\n", .{});
        try server.run(io, allocator, .stdio);
    }
}
```

## Next Steps

- [JSON-RPC Protocol](/guide/jsonrpc) - Understand the protocol
- [Error Handling](/guide/error-handling) - Handle transport errors
- [API Reference](/api/protocol#transport) - Transport API details
