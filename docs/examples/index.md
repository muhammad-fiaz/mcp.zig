# Examples

Explore these complete, working examples to learn how to use mcp.zig effectively.

## Available Examples

### [Simple Server](/examples/simple-server)

A basic MCP server with a greeting tool. Perfect for getting started.

### [Simple Client](/examples/simple-client)

A basic MCP client that connects to servers.

### [Weather Server](/examples/weather-server)

A more complex server that provides weather information using multiple tools.

### [Calculator Server](/examples/calculator-server)

A server demonstrating mathematical operations with proper input validation.

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
```

PowerShell (Windows):

```powershell
.\zig-out\bin\example-server.exe
.\zig-out\bin\weather-server.exe
.\zig-out\bin\calculator-server.exe
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
├── simple_server.zig      # Basic server example
├── simple_client.zig      # Basic client example
├── weather_server.zig     # Weather tool example
└── calculator_server.zig  # Calculator example
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
