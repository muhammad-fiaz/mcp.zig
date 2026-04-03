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

pub fn main() !void {
    // Your code here
}
```
