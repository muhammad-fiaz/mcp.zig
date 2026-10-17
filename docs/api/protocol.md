---
title: "Protocol API Reference"
description: "MCP protocol API reference — JSON-RPC message types, serialization, and protocol constants."
keywords: [Protocol API, JSON-RPC, parseMessage, serializeMessage, ErrorCode, Transport, PROTOCOL_VERSION]
---

# Protocol API

The protocol module provides JSON-RPC 2.0 and MCP protocol implementations.

## Protocol Constants

### `protocol.PROTOCOL_VERSION`

```zig
pub const PROTOCOL_VERSION = "2026-07-28";
pub const VERSION = PROTOCOL_VERSION; // Alias
```

The current MCP protocol version.

### `protocol.SUPPORTED_VERSIONS`

```zig
pub const SUPPORTED_VERSIONS = [_][]const u8{
    "2026-07-28", // Supported (default, latest active specification)
};
```

List of MCP protocol versions actively supported and advertised by this library in `server/discover`. Only `2026-07-28` is served; earlier revisions are unsupported and deprecated.

### `protocol.DEPRECATED_VERSIONS`

```zig
pub const DEPRECATED_VERSIONS = [_][]const u8{
    "2025-11-25", // Unsupported / Deprecated (session/handshake removed)
    "2025-06-18", // Unsupported / Deprecated (session/handshake removed)
    "2025-03-26", // Unsupported / Deprecated (session/handshake removed)
    "2024-11-05", // Unsupported / Deprecated (initial specification)
};
```

| Version    | Status                                                                                  |
| ---------- | --------------------------------------------------------------------------------------- |
| 2026-07-28 | Supported (latest, default; the active revision this library speaks and serves)         |
| 2025-11-25 | Unsupported / Deprecated (older session-based revision; methods removed in 2026-07-28) |
| 2025-06-18 | Unsupported / Deprecated (older session-based revision; methods removed in 2026-07-28) |
| 2025-03-26 | Unsupported / Deprecated (older session-based revision; methods removed in 2026-07-28) |
| 2024-11-05 | Unsupported / Deprecated (initial specification; methods removed in 2026-07-28)        |

---

## JSON-RPC

### Message Types

```zig
pub const Message = union(enum) {
    request: Request,
    notification: Notification,
    response: Response,
    error_response: ErrorResponse,
};
```

### Request

```zig
pub const Request = struct {
    id: types.RequestId,
    method: []const u8,
    params: ?std.json.Value = null,
};
```

### Response

```zig
pub const Response = struct {
    id: types.RequestId,
    result: ?std.json.Value = null,
};
```

### Notification

```zig
pub const Notification = struct {
    method: []const u8,
    params: ?std.json.Value = null,
};
```

### ErrorResponse

```zig
pub const ErrorResponse = struct {
    id: ?types.RequestId,
    @"error": Error,

    pub const Error = struct {
        code: i32,
        message: []const u8,
        data: ?std.json.Value = null,
    };
};
```

---

## Parsing

### `jsonrpc.parseMessage`

```zig
pub fn parseMessage(allocator: std.mem.Allocator, data: []const u8) ParseError!ParsedMessage
```

Parse a JSON-RPC message from a string.

**Example:**

```zig
const parsed = try mcp.jsonrpc.parseMessage(allocator, json_string);
defer parsed.deinit();

const message = parsed.message;

switch (message) {
    .request => |req| { /* handle request */ },
    .notification => |notif| { /* handle notification */ },
    .response => |resp| { /* handle response */ },
    .error_response => |err| { /* handle error */ },
}
```

---

## Serialization

### `jsonrpc.serializeMessage`

```zig
pub fn serializeMessage(allocator: std.mem.Allocator, message: Message) ![]u8
```

Serialize a message to JSON.

**Example:**

```zig
const json = try mcp.jsonrpc.serializeMessage(allocator, message);
defer allocator.free(json);
```

---

## Factory Functions

### `jsonrpc.createRequest`

```zig
pub fn createRequest(
    id: types.RequestId,
    method: []const u8,
    params: ?std.json.Value,
) Request
```

### `jsonrpc.createResponse`

```zig
pub fn createResponse(
    id: types.RequestId,
    result: ?std.json.Value,
) Response
```

### `jsonrpc.createNotification`

```zig
pub fn createNotification(
    method: []const u8,
    params: ?std.json.Value,
) Notification
```

### `jsonrpc.createErrorResponse`

```zig
pub fn createErrorResponse(
    id: ?types.RequestId,
    code: i32,
    message: []const u8,
    data: ?std.json.Value,
) ErrorResponse
```

---

## Error Helpers

### `jsonrpc.createParseError`

```zig
pub fn createParseError(data: ?std.json.Value) ErrorResponse
```

Create a parse error response (-32700).

### `jsonrpc.createInvalidRequest`

```zig
pub fn createInvalidRequest(id: ?types.RequestId, data: ?std.json.Value) ErrorResponse
```

Create an invalid request error (-32600).

### `jsonrpc.createMethodNotFound`

```zig
pub fn createMethodNotFound(id: types.RequestId, method: []const u8) ErrorResponse
```

Create a method not found error (-32601).

### `jsonrpc.createInvalidParams`

```zig
pub fn createInvalidParams(id: types.RequestId, message: []const u8) ErrorResponse
```

Create an invalid params error (-32602).

### `jsonrpc.createInternalError`

```zig
pub fn createInternalError(id: types.RequestId, data: ?std.json.Value) ErrorResponse
```

Create an internal error (-32603).

---

## Error Codes

```zig
pub const ErrorCode = struct {
    pub const PARSE_ERROR = -32700;
    pub const INVALID_REQUEST = -32600;
    pub const METHOD_NOT_FOUND = -32601;
    pub const INVALID_PARAMS = -32602;
    pub const INTERNAL_ERROR = -32603;
    pub const SERVER_NOT_INITIALIZED = -32002;
    pub const REQUEST_CANCELLED = -32800;
    pub const CONTENT_TOO_LARGE = -32801;
};
```

---

## Transport

### `Transport` Interface

```zig
pub const Transport = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        send: *const fn(...) anyerror!void,
        receive: *const fn(...) anyerror!?[]const u8,
        close: *const fn(...) void,
        destroy: *const fn(...) void,
    };
};
```

### `StdioTransport`

```zig
pub const StdioTransport = struct {
    // Plain struct value, no init function: `var t: StdioTransport = .{};`
    pub fn deinit(self: *StdioTransport, allocator: std.mem.Allocator) void;
    pub fn send(self: *StdioTransport, io: std.Io, allocator: std.mem.Allocator, message: []const u8) Transport.SendError!void;
    pub fn receive(self: *StdioTransport, io: std.Io, allocator: std.mem.Allocator) Transport.ReceiveError!?[]const u8;
    pub fn transport(self: *StdioTransport) Transport;
};
```

### `HttpTransport`

```zig
pub const HttpTransport = struct {
    pub fn init(allocator: std.mem.Allocator, endpoint: []const u8) !HttpTransport;
    pub fn deinit(self: *HttpTransport, allocator: std.mem.Allocator) void;
    pub fn send(self: *HttpTransport, io: std.Io, allocator: std.mem.Allocator, message: []const u8) Transport.SendError!void;
    pub fn receive(self: *HttpTransport, io: std.Io, allocator: std.mem.Allocator) Transport.ReceiveError!?[]const u8;
    pub fn setAuthorizationToken(self: *HttpTransport, allocator: std.mem.Allocator, token: []const u8) !void;
    pub fn setClientInfo(self: *HttpTransport, allocator: std.mem.Allocator, name: []const u8, version: []const u8) !void;
    pub fn transport(self: *HttpTransport) Transport;
};
```

HTTP mode details:

- Clients send JSON-RPC with `POST /mcp` and `Content-Type: application/json`.
- Requests include `Accept: application/json, text/event-stream` and
  `MCP-Protocol-Version: 2026-07-28`.
- SSE is selected with `Accept: text/event-stream`; the server replies with
  `Content-Type: text/event-stream` (`data: <json>\n\n`).
- The protocol is stateless per-request; every request carries protocol version
  and client info in `_meta`.

---

## Authorization (`mcp.auth`)

Protocol-level authorization primitives for OAuth 2.0 / 2.1 authentication and resource discovery.

### `parseWwwAuthenticate`

```zig
pub fn parseWwwAuthenticate(header: []const u8) WwwAuthenticateChallenge
```

Parses an HTTP `WWW-Authenticate` response challenge header. Extracts `scheme`, `realm`, `resource_metadata`, `scope`, `error`, and `error_description`.

### `fetchProtectedResourceMetadata` & `discoverProtectedResourceMetadata`

```zig
pub fn fetchProtectedResourceMetadata(
    allocator: std.mem.Allocator,
    io: std.Io,
    url: []const u8,
) !ProtectedResourceMetadata

pub fn discoverProtectedResourceMetadata(
    allocator: std.mem.Allocator,
    io: std.Io,
    mcp_endpoint_url: []const u8,
    www_authenticate_header: ?[]const u8,
) !ProtectedResourceMetadata
```

Fetches and discovers RFC 9728 OAuth 2.0 Protected Resource Metadata from challenge headers or automatic well-known URI probing.

### `discoverAuthorizationServerMetadata`

```zig
pub fn discoverAuthorizationServerMetadata(
    allocator: std.mem.Allocator,
    io: std.Io,
    issuer_url: []const u8,
) !AuthorizationServerMetadata
```

Probes OAuth 2.0 and OpenID Connect discovery endpoints in priority order and validates the issuer against mix-up attacks (RFC 8414 Section 3.3).

### `requestClientCredentialsToken` & `requestClientCredentialsTokenWithResource`

```zig
pub fn requestClientCredentialsToken(
    allocator: std.mem.Allocator,
    io: std.Io,
    token_endpoint: []const u8,
    client_id: []const u8,
    client_secret: []const u8,
    scope: ?[]const u8,
) !ClientCredentialsTokenResponse

pub fn requestClientCredentialsTokenWithResource(
    allocator: std.mem.Allocator,
    io: std.Io,
    token_endpoint: []const u8,
    client_id: []const u8,
    client_secret: []const u8,
    scope: ?[]const u8,
    resource: ?[]const u8,
) !ClientCredentialsTokenResponse
```

Executes an RFC 6749 Section 4.4 Client Credentials Grant request with optional RFC 8707 Resource Indicators.

### `ClientIdMetadataDocument` (CIMD)

```zig
pub const ClientIdMetadataDocument = struct {
    client_id: []const u8,
    client_name: []const u8,
    client_uri: ?[]const u8 = null,
    logo_uri: ?[]const u8 = null,
    redirect_uris: []const []const u8 = &.{},
    grant_types: ?[]const []const u8 = null,
    response_types: ?[]const []const u8 = null,
    token_endpoint_auth_method: []const u8 = "none",

    pub fn validate(self: ClientIdMetadataDocument) bool;
    pub fn deinit(self: *ClientIdMetadataDocument, allocator: std.mem.Allocator) void;
};

pub fn parseClientIdMetadataDocument(allocator: std.mem.Allocator, json_bytes: []const u8) !ClientIdMetadataDocument;
```

### `generatePkce` & `verifyPkce` (RFC 7636 / OAuth 2.1)

```zig
pub const PkcePair = struct {
    verifier: [43]u8,
    challenge: [43]u8,
    method: []const u8 = "S256",
};

pub fn generatePkce(random: std.Random) PkcePair;
pub fn verifyPkce(verifier: []const u8, expected_challenge: []const u8) bool;
```

### `validateTokenAudience` (RFC 8707 / RFC 9728)

```zig
pub fn validateTokenAudience(token_audience: []const u8, expected_resource_uri: []const u8) bool;
```

Validates inbound token audience claims on the server to prevent token reuse across services.

---

## Cooperative Cancellation (`mcp.CancellationToken`)

Thread-safe atomic cancellation token for cooperative cancellation across tasks, tool handlers, and async workers:

```zig
pub const CancellationToken = struct {
    pub fn init() CancellationToken;
    pub fn cancel(self: *CancellationToken) void;
    pub fn isCancelled(self: *const CancellationToken) bool;
    pub fn reset(self: *CancellationToken) void;
    pub fn check(self: *const CancellationToken) error{Cancelled}!void;
};
```

---


## Complete Example

```zig
const std = @import("std");
const mcp = @import("mcp");

pub fn main(init: std.process.Init) void {
    run(init.io, init.gpa) catch |err| mcp.reportError(err);
}

fn run(_: std.Io, allocator: std.mem.Allocator) !void {
    // Create a request
    const request = mcp.jsonrpc.createRequest(
        .{ .integer = 1 },
        "tools/list",
        null,
    );

    // Serialize to JSON
    const json = try mcp.jsonrpc.serializeMessage(
        allocator,
        .{ .request = request },
    );
    defer allocator.free(json);

    std.debug.print("Request: {s}\n", .{json});

    // Parse a response
    const response_json = "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{}}";
    const parsed = try mcp.jsonrpc.parseMessage(allocator, response_json);
    defer parsed.deinit();

    switch (parsed.message) {
        .response => |resp| {
            std.debug.print("Got response for ID: {any}\n", .{resp.id});
        },
        else => {},
    }
}
```
