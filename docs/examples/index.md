# Examples

Explore these complete, working examples to learn how to use mcp.zig effectively.

## Available Examples

### [Simple Server](/examples/simple-server)

A minimal MCP server with greeting and echo tools, a resource, and a prompt.

### [Simple Client](/examples/simple-client)

A basic MCP client demonstrating capability declaration and roots configuration.

### [Weather Server](/examples/weather-server)

A multi-tool server with InputSchema constraints, resource templates, and task support.

### [Calculator Server](/examples/calculator-server)

Arithmetic tools with structured output schemas, annotations, and task-enabled division.

### [Advanced Server](/examples/advanced-server)

Full feature showcase: JSON Schema 2020-12, icons, output schemas, task support, prompts.

### [Filesystem Server](/examples/filesystem-server)

Read files and list directories. Demonstrates real file I/O inside tool handlers.

### [Notes Server](/examples/notes-server)

Stateful server storing in-memory notes. Shows `user_data` context, list-change notifications.

### [HTTP Server](/examples/http-server)

HTTP transport with SSE support. Includes a `hash_text` tool and a status resource.

## Running Examples

All examples are included in the `examples/` directory of the repository.

### Build All Examples

```bash
zig build
```

### Run an Example

```bash
# Run the simple server
./zig-out/bin/example-server

# Run the weather server
./zig-out/bin/weather-server

# Run the calculator
./zig-out/bin/calculator-server

# Run the advanced server
./zig-out/bin/advanced-server
```

PowerShell (Windows):

```powershell
.\zig-out\bin\example-server.exe
.\zig-out\bin\weather-server.exe
.\zig-out\bin\calculator-server.exe
.\zig-out\bin\advanced-server.exe
```

To use custom HTTP transport, switch the run line in `examples/simple_server.zig` from stdio to HTTP and set your host/domain and port, for example:

```zig
try server.run(io, allocator, .{ .http = .{ .host = "api.example.com", .port = 8443 } });
```

## Testing with an AI Client

You can test your MCP server with Claude Desktop or other MCP-compatible AI clients.

### Claude Desktop Configuration

Add to your Claude Desktop config (usually at `~/.config/claude/config.json`):

```json
{
  "mcpServers": {
    "my-server": {
      "command": "/path/to/zig-out/bin/example-server"
    }
  }
}
```

### Manual Testing

You can also test by sending JSON-RPC messages directly:

```bash
echo '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"test","version":"1.0.0"}}}' | ./zig-out/bin/example-server
```

PowerShell (Windows) STDIO test:

```powershell
.\zig-out\bin\example-server.exe
```

Then paste one JSON-RPC line and press Enter:

```json
{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"test","version":"1.0.0"}}}
```

For HTTP transport mode:

```bash
# switch run line in source from stdio to HTTP mode and set host/port:
# try server.run(io, allocator, .{ .http = .{ .host = "localhost", .port = 8080 } });
./zig-out/bin/example-server

curl -X POST http://localhost:8080 \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"test","version":"1.0.0"}}}'
```

PowerShell:

```powershell
$body = '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"test","version":"1.0.0"}}}'
Invoke-RestMethod -Method Post -Uri http://localhost:8080 -ContentType 'application/json' -Body $body
```

## Project Structure

```
examples/
├── simple_server.zig      # Minimal server (tools, resource, prompt)
├── simple_client.zig      # Client with roots and capabilities
├── weather_server.zig     # Weather tools + resource template
├── calculator_server.zig  # Arithmetic with output schemas
├── advanced_server.zig    # Full feature showcase
├── filesystem_server.zig  # File I/O via tools and resources
├── notes_server.zig       # Stateful notes store (user_data)
└── http_server.zig        # HTTP transport + SSE example
```

## Creating Your Own Examples

1. Create a new file in the `examples/` directory
2. Add it to `build.zig`
3. Import `mcp` and start building!

```zig
const std = @import("std");
const mcp = @import("mcp");

pub fn main(init: std.process.Init) void {
    run(init.io, init.gpa) catch |err| mcp.reportError(err);
}

fn run(io: std.Io, allocator: std.mem.Allocator) !void {
    // Your code here
    _ = .{ io, allocator };
}
```
