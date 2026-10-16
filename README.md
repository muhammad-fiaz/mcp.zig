<div align="center">
<img alt="logo" src="https://github.com/user-attachments/assets/09fa609c-22fd-4076-9849-dbd9800f8c03" />
    
# MCP.zig

<a href="https://muhammad-fiaz.github.io/mcp.zig/"><img src="https://img.shields.io/badge/docs-muhammad--fiaz.github.io-blue" alt="Documentation"></a>
<a href="https://ziglang.org/"><img src="https://img.shields.io/badge/Zig-0.17.0+-orange.svg?logo=zig" alt="Zig Version"></a>
<a href="https://github.com/muhammad-fiaz/mcp.zig/actions/workflows/ci.yml"><img src="https://github.com/muhammad-fiaz/mcp.zig/actions/workflows/ci.yml/badge.svg" alt="CI"></a>
<a href="https://github.com/muhammad-fiaz/mcp.zig"><img src="https://img.shields.io/github/stars/muhammad-fiaz/mcp.zig" alt="GitHub stars"></a>
<a href="https://github.com/muhammad-fiaz/mcp.zig/issues"><img src="https://img.shields.io/github/issues/muhammad-fiaz/mcp.zig" alt="GitHub issues"></a>
<a href="https://github.com/muhammad-fiaz/mcp.zig/pulls"><img src="https://img.shields.io/github/issues-pr/muhammad-fiaz/mcp.zig" alt="GitHub pull requests"></a>
<a href="https://github.com/muhammad-fiaz/mcp.zig"><img src="https://img.shields.io/github/last-commit/muhammad-fiaz/mcp.zig" alt="GitHub last commit"></a>
<a href="https://github.com/muhammad-fiaz/mcp.zig/blob/main/LICENSE"><img src="https://img.shields.io/github/license/muhammad-fiaz/mcp.zig" alt="License"></a>
<a href="https://github.com/muhammad-fiaz/mcp.zig/actions/workflows/deploy-docs.yml"><img src="https://github.com/muhammad-fiaz/mcp.zig/actions/workflows/deploy-docs.yml/badge.svg" alt="Docs"></a>
<img src="https://img.shields.io/badge/platforms-linux%20%7C%20windows%20%7C%20macos-blue" alt="Supported Platforms">
<a href="https://github.com/muhammad-fiaz/mcp.zig/releases/latest"><img src="https://img.shields.io/github/v/release/muhammad-fiaz/mcp.zig?label=Latest%20Release&style=flat-square" alt="Latest Release"></a>
<a href="https://pay.muhammadfiaz.com"><img src="https://img.shields.io/badge/Sponsor-pay.muhammadfiaz.com-ff69b4?style=flat&logo=heart" alt="Sponsor"></a>
<a href="https://github.com/sponsors/muhammad-fiaz"><img src="https://img.shields.io/badge/Sponsor-GitHub-pink?style=social&logo=github" alt="GitHub Sponsors"></a>
<a href="https://hits.sh/github.com/muhammad-fiaz/mcp.zig/"><img src="https://hits.sh/github.com/muhammad-fiaz/mcp.zig.svg?label=Visitors&extraCount=0&color=green" alt="Repo Visitors"></a>

<p><em>A Model Context Protocol (MCP) library for the Zig ecosystem.</em></p>

<b><a href="https://muhammad-fiaz.github.io/mcp.zig/">Documentation</a> |
<a href="https://muhammad-fiaz.github.io/mcp.zig/api/">API Reference</a> |
<a href="https://muhammad-fiaz.github.io/mcp.zig/guide/getting-started">Quick Start</a> |
<a href="https://muhammad-fiaz.github.io/mcp.zig/contributing">Contributing</a></b>

</div>

---

## What is MCP?

**Model Context Protocol (MCP)** is an open standard for connecting AI applications to external systems.
It defines a common wire format and vocabulary for the tools, resources, and prompts an application exposes.

## Why mcp.zig?

The [Model Context Protocol (MCP)](https://modelcontextprotocol.io/docs/getting-started/intro) is an open standard by Anthropic for connecting AI applications to external systems. While MCP has official SDKs for TypeScript, Python, and other languages, **Zig currently lacks proper MCP support**.

**mcp.zig** is a native Zig implementation of MCP revision `2026-07-28`, with
both a server and a client, so that Zig programs can:

- Serve tools, resources, resource templates, and prompts to any MCP client
- Act as an MCP client over STDIO or Streamable HTTP
- Depend on a single external package (`httpx.zig`) rather than a runtime

## Features

- **Server framework** - Expose tools, resource templates, and prompts over STDIO or HTTP
- **Client framework** - Connect over STDIO or HTTP and declare elicitation, sampling, roots, and extension capabilities
- **MCP 2026-07-28** - Stateless per-request model: `server/discover` as the entry point, `_meta` on every request, `resultType` on every result, no `initialize` handshake
- **MRTR** - Multi Round-Trip Requests: a handler returning `error.InputRequired` yields an `input_required` result that the client resolves and retries under a new request id
- **Tasks extension** - Opt-in `io.modelcontextprotocol/tasks` support: a `tools/call` augmented with `_meta["io.modelcontextprotocol/task"]` returns `resultType: "task"`, results carry `_meta["io.modelcontextprotocol/relatedTask"]`, and the server pushes `notifications/tasks`; `tasks/get`, `tasks/update`, and `tasks/cancel` are available on both sides
- **Content types** - Text, image, audio, resource-link, and structured tool results
- **Transports** - STDIO and Streamable HTTP, built on [httpx.zig](https://github.com/muhammad-fiaz/httpx.zig)
- **Middleware** - Optional rate limiting, request validation, batch requests, and logging around tool handlers
- **Tests** - Unit tests for the protocol layer, transports, server, and client

### Known limitations

- **Streamable HTTP streams** - The transport vtable exchanges whole messages, so the per-request SSE stream lifetime that `subscriptions/listen` needs is not modelled end to end. The HTTP client accepts both `application/json` and `text/event-stream` responses; the HTTP server answers a single POST with a single response.
- **Authorization** - Only `setAuthorizationToken` (a bearer token) is implemented. There is no protected-resource or authorization-server metadata discovery, no `WWW-Authenticate` parsing, no PKCE, dynamic client registration, token refresh, or step-up.
- **Cancellation** - Cooperative and poll-based: a synchronous handler that never consults its cancellation token cannot be interrupted.

## Documentation

Full documentation is available at **[muhammad-fiaz.github.io/mcp.zig](https://muhammad-fiaz.github.io/mcp.zig/)**

For the official MCP specification and resources, visit:

- [MCP Documentation](https://modelcontextprotocol.io/docs/getting-started/intro)
- [MCP Specification](https://spec.modelcontextprotocol.io/)

## Related Zig Projects

- For API framework support, check out [api.zig](https://github.com/muhammad-fiaz/api.zig).

- For web framework support, check out [zix](https://github.com/muhammad-fiaz/zix).

- For logging support, check out [logly.zig](https://github.com/muhammad-fiaz/logly.zig).

- For data validation and serialization support, check out [zigantic](https://github.com/muhammad-fiaz/zigantic).

- For Http Client and Server support, check out [httpx.zig](https://github.com/muhammad-fiaz/httpx.zig).

## Quick Start

### Installation

mcp.zig requires **Zig 0.17.0** or later (`minimum_zig_version` in `build.zig.zon`).

Add the package to your project:

```bash
zig fetch --save git+https://github.com/muhammad-fiaz/mcp.zig.git
```

Build it with `zig build`:

```bash
zig build                  # static library
zig build run-all-examples # library plus every example
```

Then in your `build.zig`:

```zig
const mcp_dep = b.dependency("mcp", .{
    .target = target,
    .optimize = optimize,
});
exe.root_module.addImport("mcp", mcp_dep.module("mcp"));
```

### Creating a Server

```zig
const std = @import("std");
const mcp = @import("mcp");

pub fn main(init: std.process.Init) void {
    run(init.io, init.gpa) catch |err| {
        mcp.reportError(err);
    };
}

fn run(io: std.Io, allocator: std.mem.Allocator) !void {
    // Create server
    var server: mcp.Server = .init(allocator, .{
        .name = "my-server",
        .version = "1.0.0",
    });
    defer server.deinit();

    // Add a tool
    try server.addTool(.{
        .name = "greet",
        .description = "Greet a user",
        .handler = greetHandler,
    });

    // Run with STDIO transport
    try server.run(io, allocator, .stdio);

    // Or serve Streamable HTTP on POST /mcp:
    // try server.run(io, allocator, .{ .http = .{ .host = "127.0.0.1", .port = 8080 } });
}

fn greetHandler(
    _: ?*anyopaque,
    _: std.Io,
    allocator: std.mem.Allocator,
    args: ?std.json.Value,
) mcp.tools.ToolError!mcp.tools.ToolResult {
    const name = mcp.tools.getString(args, "name") orelse "World";
    const message = try std.fmt.allocPrint(allocator, "Hello, {s}!", .{name});
    return mcp.tools.textResult(allocator, message);
}
```

### Creating a Client

```zig
const std = @import("std");
const mcp = @import("mcp");

pub fn main(init: std.process.Init) void {
    run(init.io, init.gpa) catch |err| {
        mcp.reportError(err);
    };
}

fn run(io: std.Io, allocator: std.mem.Allocator) !void {
    var client: mcp.Client = .init(io, allocator, .{
        .name = "my-client",
        .version = "1.0.0",
    });
    defer client.deinit();

    // Declare client capabilities before the first request
    client.enableSampling();     // Deprecated in 2026-07-28, still supported
    client.enableRoots();        // Deprecated in 2026-07-28, presence-only
    client.enableElicitation();  // Form and URL elicitation
    try client.enableTasks();

    // Connect to a server
    try client.connectStdio("my-server-binary", &.{});

    // server/discover is the entry point in 2026-07-28; there is no
    // initialize handshake and no session id
    try client.discover();
    try client.listTools();
}
```

Request helpers such as `discover`, `listTools`, `callTool`, and `readResource`
return `!void`: they write the request to the transport and do **not** hand back
a request id. Results arrive as separate messages.

- `handleMessage(payload)` takes one raw JSON-RPC message, resolves the matching
  pending request, and stores its final result.
- `takeResult(id)` returns the owned raw JSON of that result, which the caller
  must `free`, or `null` while the request is still outstanding.

`callToolResolved`, `readResourceResolved`, and `getPromptResolved` are the
request helpers that return the id (`!i64`), because they drive MRTR rounds
automatically. `callToolAsTask(name, arguments, ttlMs)` asks the server to run a
tool as a task; like `callTool` it returns `!void`.

```zig
const Resolver = struct {
    fn resolve(
        _: *anyopaque,
        allocator: std.mem.Allocator,
        key: []const u8,
        _: std.json.Value,
    ) anyerror!std.json.Value {
        var answer: std.json.ObjectMap = .empty;
        try answer.put(allocator, key, .{ .string = "accept" });
        return .{ .object = answer };
    }
};

fn call(io: std.Io, allocator: std.mem.Allocator) !void {
    var client: mcp.Client = .init(io, allocator, .{ .name = "my-client", .version = "1.0.0" });
    defer client.deinit();

    try client.connectStdio("my-server-binary", &.{});

    const id = try client.callToolResolved("greet", null, .{
        .ctx = undefined,
        .resolve = Resolver.resolve,
    });

    // Pump every message the transport delivers
    const t = client.transport orelse return error.NotConnected;
    if (try t.receive(io, allocator)) |message| {
        defer allocator.free(message);
        try client.handleMessage(message);
    }

    if (client.takeResult(id)) |raw| {
        defer allocator.free(raw);
        // raw is the JSON text of the result
    }
}
```

## Examples

The `examples/` directory contains fifteen runnable programs, each wired to its own
build step:

| Example                                                 | Description                                        | Run step           |
| ------------------------------------------------------- | -------------------------------------------------- | ------------------ |
| [simple_server.zig](examples/simple_server.zig)         | Minimal server: two tools, one resource, one prompt | `run-server`       |
| [simple_client.zig](examples/simple_client.zig)         | Connect, discover, list tools/resources/prompts     | `run-client`       |
| [full_client.zig](examples/full_client.zig)             | Client and server over a loopback transport, asserting every response | `run-full-client`  |
| [weather_server.zig](examples/weather_server.zig)       | Multi-tool weather server with a resource template  | `run-weather`      |
| [calculator_server.zig](examples/calculator_server.zig) | Arithmetic tools with structured output schemas     | `run-calc`         |
| [advanced_server.zig](examples/advanced_server.zig)     | JSON Schema 2020-12, icons, annotations, templates, tasks extension | `run-advanced`     |
| [filesystem_server.zig](examples/filesystem_server.zig) | Dynamic filesystem resources and URI templates      | `run-filesystem`   |
| [notes_server.zig](examples/notes_server.zig)           | Stateful in-memory notes with list-change notifications | `run-notes`      |
| [http_server.zig](examples/http_server.zig)             | HTTP transport server on `127.0.0.1:8080`           | `run-http`         |
| [middleware_server.zig](examples/middleware_server.zig) | Wrapping tool handlers in middleware                | `run-middleware`   |
| [batch_client.zig](examples/batch_client.zig)           | Sending several requests as one JSON-RPC batch      | `run-batch`        |
| [rate_limiter_example.zig](examples/rate_limiter_example.zig) | Rate limiting tool calls                     | `run-rate-limiter` |
| [health_check_example.zig](examples/health_check_example.zig) | The built-in `health/check` method            | `run-health-check` |
| [shutdown_example.zig](examples/shutdown_example.zig)   | Graceful shutdown after the current request         | `run-shutdown`     |
| [validator_example.zig](examples/validator_example.zig) | Validating tool arguments against a schema          | `run-validator`    |

Build every example without running it, or run one:

```bash
zig build run-all-examples

zig build run-server
zig build run-weather
zig build run-calc
zig build run-advanced
```

## Architecture

```
src/
├── mcp.zig              # Module entry point and re-exports
├── version.zig          # Library version
├── report.zig           # Error reporting (mcp.reportError, mcp.ISSUES_URL)
├── protocol/
│   ├── protocol.zig     # Methods, _meta keys, error codes, HTTP headers
│   ├── types.zig        # Payload and capability types
│   ├── jsonrpc.zig      # JSON-RPC 2.0 codec
│   ├── schema.zig       # JSON Schema 2020-12 builders
│   └── param_headers.zig # x-mcp-header parameter annotations
├── transport/
│   └── transport.zig    # Transport vtable, STDIO and HTTP (httpx.zig)
├── server/
│   ├── server.zig       # Server implementation
│   ├── http_rules.zig   # Streamable HTTP header and origin validation
│   ├── tools.zig        # Tool primitive and ToolBuilder
│   ├── resources.zig    # Resource primitive and templates
│   └── prompts.zig      # Prompt primitive
├── client/
│   ├── client.zig       # Client implementation
│   ├── elicitation.zig  # Elicitation support
│   ├── roots.zig        # Roots support (deprecated)
│   └── sampling.zig     # Sampling support (deprecated)
└── utils/
    ├── mod.zig          # Utility module index
    ├── logging.zig      # Logging helpers
    ├── middleware.zig   # Rate limiting, batching, validation
    └── progress.zig     # Progress reporting
```

## Server Features

### Tools

Tools are functions that an AI application can invoke. A handler receives
`(?*anyopaque, std.Io, std.mem.Allocator, ?std.json.Value)` and returns
`mcp.tools.ToolError!mcp.tools.ToolResult`:

```zig
try server.addTool(.{
    .name = "search_files",
    .description = "Search for files matching a pattern",
    .handler = searchHandler,
});
```

`mcp.ToolBuilder.init(name)` takes one argument and `.build()` is not
fallible, so a builder chain never needs `try` on `build()`:

```zig
var builder: mcp.ToolBuilder = .init("search_files");
const tool = builder
    .description("Search for files matching a pattern")
    .inputSchema(schema)
    .readOnly()
    .handler(searchHandler)
    .build();

try server.addTool(tool);
```

`inputSchema` and `outputSchema` are complete JSON Schema 2020-12 documents.
Keywords the typed schema builder cannot express are supplied through
`InputSchema.fromJson(value)` or `ToolBuilder.inputSchemaFromRaw(value)`; the
server emits that document verbatim before overlaying the typed fields.

### Resources

Resources expose read-only data. A handler receives
`(?*anyopaque, std.Io, std.mem.Allocator, []const u8)` and returns
`mcp.resources.ResourceError!mcp.resources.ResourceContent`:

```zig
try server.addResource(.{
    .uri = "file:///docs/readme.md",
    .name = "README",
    .mimeType = "text/markdown",
    .handler = readFileHandler,
});
```

Parameterised URIs use `addResourceTemplate` with a `uriTemplate`.

### Prompts

Prompts are reusable message templates. A handler receives
`(?*anyopaque, std.Io, std.mem.Allocator, ?std.json.Value)` and returns
`mcp.prompts.PromptError![]const mcp.prompts.PromptMessage`:

```zig
try server.addPrompt(.{
    .name = "summarize",
    .description = "Summarize a document",
    .arguments = &.{
        .{ .name = "document", .required = true },
    },
    .handler = summarizeHandler,
});
```

### Tasks

The tasks extension (`io.modelcontextprotocol/tasks`) is opt-in on both sides.
`Server.enableTasks()` declares it, and a tool opts into task augmentation with
`ToolBuilder.taskSupport("optional" | "required" | "forbidden")`:

```zig
var builder: mcp.ToolBuilder = .init("reindex");
const tool = builder
    .description("Rebuild the search index")
    .taskSupport("optional")
    .handler(reindexHandler)
    .build();

try server.enableTasks();
try server.addTool(tool);
```

A `tools/call` carrying `_meta["io.modelcontextprotocol/task"] = {"ttl": <ms>}`
then answers with `resultType: "task"` and a task snapshot, and repeats the task
id under `_meta["io.modelcontextprotocol/relatedTask"] = {"taskId": ...}`.
Clients opt in with `Client.callToolAsTask(name, arguments, ttlMs)` and observe
the outcome by polling `getTask`, answering blocked rounds with `updateTask`, or
cancelling with `cancelTask`.

Servers that manage task lifetime directly can `storeTask`, `updateTask` with a
`Server.TaskUpdate`, `getTask`, and `removeTask`; `notifyTask` pushes a single
`notifications/tasks` snapshot, and `updateTask` pushes it automatically.
`notifications/tasks` reaches only the subscriptions whose
`types.SubscriptionFilter.taskIds` list the task. `tasks/*` is refused with
`-32021` unless the client also declares the extension.

## Client Features

### Roots

Advertise the filesystem boundaries a server may work within. Deprecated in
`2026-07-28` but still supported; the capability is presence-only, there is no
`listChanged` flag, and the server ignores
`notifications/roots/list_changed`:

```zig
client.enableRoots();
try client.addRoot("file:///projects", "Projects");
```

### Sampling

Allow a server to request an LLM completion, in practice through an
`input_required` round. Also deprecated in `2026-07-28` but supported:

```zig
client.enableSampling();
// Or, with optional context and tools support:
client.enableSamplingAdvanced(true, true);
```

### Elicitation

```zig
client.enableElicitation(); // Form and URL elicitation
client.enableElicitationForm();
client.enableElicitationUrl();
```

## Testing

Run the unit tests:

```bash
zig build test
zig build test --summary all
```

Compile the tests and every example for another target without executing them,
which works for targets that cannot run on the host:

```bash
zig build test-compile -Dtarget=x86_64-linux
zig build test-compile -Dtarget=x86_64-windows
zig build test-compile -Dtarget=x86_64-macos
```

CI runs these three commands on Linux, Windows, and macOS: `zig build test`,
`zig build run-all-examples`, and `zig fmt --check src examples build.zig`.
`zig fmt --check src examples build.zig` should also pass locally before you
open a pull request.

## Generating Documentation

Generate native, interactive HTML API documentation for the library:

```bash
zig build docs
```

The generated files (including `index.html`, `main.js`, and `main.wasm`) will be located in the `zig-out/docs/` directory. You can view them using any standard web browser.

## Protocol Version

This library implements MCP protocol version **2026-07-28** (`protocol.VERSION`)
and speaks that revision everywhere. There is no `initialize` handshake, no
`ping`, no `logging/setLevel`, no `resources/subscribe` or `resources/unsubscribe`,
and no `Mcp-Session-Id`: `server/discover` is the entry point and every request is
independent. Each request carries `_meta` with
`io.modelcontextprotocol/protocolVersion`,
`io.modelcontextprotocol/clientInfo`, and
`io.modelcontextprotocol/clientCapabilities`; each result carries a `resultType`
of `"complete"`, `"input_required"`, or `"task"`. Cacheable results may add
`ttlMs` and `cacheScope`.

| Version    | Status                                                                                  |
| ---------- | --------------------------------------------------------------------------------------- |
| 2026-07-28 | Supported (latest, default)                                                             |
| 2025-11-25 | Unsupported / Deprecated (older session-based revision; methods removed in 2026-07-28) |
| 2025-06-18 | Unsupported / Deprecated (older session-based revision; methods removed in 2026-07-28) |
| 2025-03-26 | Unsupported / Deprecated (older session-based revision; methods removed in 2026-07-28) |
| 2024-11-05 | Unsupported / Deprecated (initial specification; methods removed in 2026-07-28)        |

`protocol.PROTOCOL_VERSION` (`2026-07-28`) is the only revision this library actively speaks and serves. Earlier
revisions (`2025-11-25`, `2025-06-18`, `2025-03-26`, `2024-11-05`) established a stateful session with an `initialize`
handshake, which this revision removed in favor of the stateless per-request model. There is no legacy fallback:
`protocol.SUPPORTED_VERSIONS` contains only `["2026-07-28"]`, `server/discover` advertises only `["2026-07-28"]`,
and requests specifying older revisions in `MCP-Protocol-Version` or body `_meta` are rejected with `ErrorCode.UNSUPPORTED_PROTOCOL_VERSION` (-32022).

Methods removed by `2026-07-28` and deliberately not implemented:
`initialize`, `notifications/initialized`, `ping`, `logging/setLevel`,
`notifications/roots/list_changed`, `resources/subscribe`,
`resources/unsubscribe`, `tasks/result`, and `tasks/list`. Resource
subscriptions use `subscriptions/listen`, which the server ends with
`Server.endSubscription`.

### Deprecated but supported features

Roots, Sampling, and Logging are deprecated in `2026-07-28` but remain in the
specification, and mcp.zig implements them:

- **Roots** and **Sampling** are reachable through Multi Round-Trip Requests:
  the MRTR schema still defines `ListRootsRequest` and `CreateMessageRequest`
  as valid `inputRequests` entries, and a handler that returns
  `error.InputRequired` turns into such a request.
- **Logging** is per-request. A client opts in with
  `_meta.io.modelcontextprotocol/logLevel`, and `Server.sendLogMessage` emits
  `notifications/message` only for requests that supplied the field.
  `logging/setLevel` is not implemented.
- Roots is presence-only (`roots?: {}`). There is no `listChanged` flag and no
  `notifyRootsChanged` on the client; the server ignores
  `notifications/roots/list_changed`.

Prefer tool parameters, resource URIs, and `stderr` for new work.

## Contributing

Bug reports and pull requests are welcome. See [CONTRIBUTING.md](CONTRIBUTING.md)
and the [Contributing guide](https://muhammad-fiaz.github.io/mcp.zig/contributing).
For security vulnerabilities, see [SECURITY.md](SECURITY.md).

## Support

If you find this project helpful, consider supporting its development:

<a href="https://pay.muhammadfiaz.com"><img src="https://img.shields.io/badge/Sponsor-pay.muhammadfiaz.com-ff69b4?style=for-the-badge&logo=heart" alt="Sponsor"></a>
<a href="https://github.com/sponsors/muhammad-fiaz"><img src="https://img.shields.io/badge/GitHub_Sponsors-GitHub-pink?style=for-the-badge&logo=github" alt="GitHub Sponsors"></a>

## License

This project is licensed under the MIT License. See [LICENSE](LICENSE) for details.

## Resources

- [mcp.zig Documentation](https://muhammad-fiaz.github.io/mcp.zig/)
- [Official MCP Documentation](https://modelcontextprotocol.io/docs/getting-started/intro)
- [MCP Specification](https://spec.modelcontextprotocol.io)
- [MCP GitHub](https://github.com/modelcontextprotocol)
