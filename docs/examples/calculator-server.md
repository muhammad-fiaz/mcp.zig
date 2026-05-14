# Calculator Server Example

This example demonstrates argument validation and deterministic tool behavior.

## What This Example Includes

- add tool
- subtract tool
- multiply tool
- divide tool (division-by-zero handling)
- logging and tasks capabilities

## Tool Arguments

All tools expect numeric arguments:

- a
- b

## Build and Run

```bash
zig build
./zig-out/bin/calculator-server
```

The calculator example runs over stdio by default (CI/GitHub Actions friendly). To test with `curl`/HTTP, switch the run mode in `examples/calculator_server.zig` to:

```zig
try server.run(io, allocator, .{ .http = .{ .host = "localhost", .port = 8080 } });
```

## HTTP Request Example

```bash
curl -X POST http://localhost:8080 \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"multiply","arguments":{"a":7,"b":8}}}'
```

## Error Example

```bash
curl -X POST http://localhost:8080 \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"divide","arguments":{"a":10,"b":0}}}'
```

The divide tool returns an MCP error result payload for divide-by-zero.

## Source

See examples/calculator_server.zig for full code.

## Next

- [Error Handling Guide](/guide/error-handling)
- [Tools Guide](/guide/tools)
- [Simple Server](/examples/simple-server)
