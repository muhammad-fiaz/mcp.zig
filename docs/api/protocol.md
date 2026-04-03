# Protocol API

The protocol module provides JSON-RPC 2.0 and MCP protocol implementations.

## Protocol Constants

### `protocol.PROTOCOL_VERSION`

```zig
pub const PROTOCOL_VERSION = "2025-11-25";
pub const VERSION = PROTOCOL_VERSION; // Alias
```

The current MCP protocol version.

### `protocol.SUPPORTED_VERSIONS`

```zig
pub const SUPPORTED_VERSIONS = [_][]const u8{
    "2025-11-25",
    "2025-06-18",
    "2025-03-26",
    "2024-11-05",
};
```

List of supported protocol versions.

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
    };
};
```

### `StdioTransport`

```zig
pub const StdioTransport = struct {
    pub fn init(allocator: std.mem.Allocator) StdioTransport;
    pub fn deinit(self: *StdioTransport) void;
    pub fn send(self: *StdioTransport, data: []const u8) Transport.SendError!void;
    pub fn receive(self: *StdioTransport) Transport.ReceiveError!?[]const u8;
    pub fn transport(self: *StdioTransport) Transport;
};
```

### `HttpTransport`

```zig
pub const HttpTransport = struct {
    pub fn init(allocator: std.mem.Allocator, endpoint: []const u8) !HttpTransport;
    pub fn deinit(self: *HttpTransport) void;
    pub fn send(self: *HttpTransport, message: []const u8) Transport.SendError!void;
    pub fn receive(self: *HttpTransport) Transport.ReceiveError!?[]const u8;
    pub fn setSessionId(self: *HttpTransport, id: []const u8) !void;
    pub fn setAuthorizationToken(self: *HttpTransport, token: []const u8) !void;
    pub fn transport(self: *HttpTransport) Transport;
};
```

HTTP mode details:

- Clients send JSON-RPC with `POST /` and `Content-Type: application/json`.
- Server responses may include `MCP-Session-Id` for session continuity.
- Request bodies should include a valid `Content-Length`.

---

## Complete Example

```zig
const std = @import("std");
const mcp = @import("mcp");

pub fn main() !void {
    const allocator = std.heap.page_allocator;

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
