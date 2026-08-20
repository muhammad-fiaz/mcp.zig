---
title: "JSON-RPC Protocol"
description: "MCP uses JSON-RPC 2.0 for communication — understand requests, responses, notifications, and batch operations."
keywords: [JSON-RPC 2.0, requests, responses, notifications, error codes, MCP methods]
---

# JSON-RPC Protocol

mcp.zig implements JSON-RPC 2.0 for all MCP communication.

## Overview

JSON-RPC is a stateless, light-weight remote procedure call (RPC) protocol that uses JSON for data encoding.

## Message Types

### Request

```json
{
  "jsonrpc": "2.0",
  "id": 1,
  "method": "tools/call",
  "params": {
    "name": "greet",
    "arguments": { "name": "World" }
  }
}
```

### Response

```json
{
  "jsonrpc": "2.0",
  "id": 1,
  "result": {
    "content": [{ "type": "text", "text": "Hello, World!" }]
  }
}
```

### Notification

```json
{
  "jsonrpc": "2.0",
  "method": "notifications/roots/list_changed"
}
```

### Error Response

```json
{
  "jsonrpc": "2.0",
  "id": 1,
  "error": {
    "code": -32600,
    "message": "Invalid Request"
  }
}
```

## Using the API

### Parse Messages

```zig
const message = try mcp.jsonrpc.parseMessage(allocator, json_string);

switch (message) {
    .request => |req| {
        std.debug.print("Request: {s}\n", .{req.method});
    },
    .notification => |notif| {
        std.debug.print("Notification: {s}\n", .{notif.method});
    },
    .response => |resp| {
        std.debug.print("Response ID: {any}\n", .{resp.id});
    },
    .error_response => |err| {
        std.debug.print("Error: {s}\n", .{err.error.message});
    },
}
```

### Create Messages

```zig
// Request
const req = mcp.jsonrpc.createRequest(
    .{ .integer = 1 },
    "tools/list",
    null,
);

// Response
const resp = mcp.jsonrpc.createResponse(
    .{ .integer = 1 },
    result_value,
);

// Notification
const notif = mcp.jsonrpc.createNotification(
    "notifications/roots/list_changed",
    null,
);
```

### Serialize Messages

```zig
const json = try mcp.jsonrpc.serializeMessage(allocator, message);
defer allocator.free(json);

// Send json over transport
```

## Error Codes

| Code   | Constant           | Description               |
| ------ | ------------------ | ------------------------- |
| -32700 | `PARSE_ERROR`      | Invalid JSON              |
| -32600 | `INVALID_REQUEST`  | Invalid request object    |
| -32601 | `METHOD_NOT_FOUND` | Method doesn't exist      |
| -32602 | `INVALID_PARAMS`   | Invalid method parameters |
| -32603 | `INTERNAL_ERROR`   | Internal JSON-RPC error   |

### Creating Error Responses

```zig
// Parse error
const err = mcp.jsonrpc.createParseError(null);

// Method not found
const err = mcp.jsonrpc.createMethodNotFound(request_id, method);

// Invalid params
const err = mcp.jsonrpc.createInvalidParams(request_id, "Missing required field");

// Custom error
const err = mcp.jsonrpc.createErrorResponse(
    request_id,
    -32000,  // Custom code
    "Custom error message",
    null,
);
```

## Request IDs

Request IDs can be integers or strings:

```zig
// Integer ID
const id: mcp.types.RequestId = .{ .integer = 42 };

// String ID
const id: mcp.types.RequestId = .{ .string = "request-001" };
```

## MCP Methods (2026-07-28)

### Lifecycle

| Method              | Type         | Description                    |
| ------------------- | ------------ | ------------------------------ |
| `server/discover`   | Request      | Discover server capabilities   |

### Tools

| Method       | Type    | Description          |
| ------------ | ------- | -------------------- |
| `tools/list` | Request | List available tools |
| `tools/call` | Request | Execute a tool       |

### Resources

| Method                     | Type    | Description          |
| -------------------------- | ------- | -------------------- |
| `resources/list`           | Request | List resources       |
| `resources/read`           | Request | Read a resource      |
| `resources/templates/list` | Request | List templates       |
| `subscriptions/listen`     | Request | Subscribe to changes |

### Prompts

| Method         | Type    | Description  |
| -------------- | ------- | ------------ |
| `prompts/list` | Request | List prompts |
| `prompts/get`  | Request | Get a prompt |

### Completion

| Method                 | Type    | Description            |
| ---------------------- | ------- | ---------------------- |
| `completion/complete`  | Request | Argument completion    |

### Tasks

| Method          | Type    | Description         |
| --------------- | ------- | ------------------- |
| `tasks/get`     | Request | Get task status     |
| `tasks/result`  | Request | Get task result     |
| `tasks/list`    | Request | List all tasks      |
| `tasks/cancel`  | Request | Cancel a task       |

## Complete Example

```zig
const std = @import("std");
const mcp = @import("mcp");

pub fn handleMessage(allocator: std.mem.Allocator, json: []const u8) ![]const u8 {
    // Parse incoming message
    const message = mcp.jsonrpc.parseMessage(allocator, json) catch {
        const err = mcp.jsonrpc.createParseError(null);
        return try mcp.jsonrpc.serializeMessage(allocator, .{ .error_response = err });
    };

    // Handle based on message type
    switch (message) {
        .request => |req| {
            if (std.mem.eql(u8, req.method, "server/discover")) {
                const resp = mcp.jsonrpc.createResponse(req.id, null);
                return try mcp.jsonrpc.serializeMessage(allocator, .{ .response = resp });
            }

            const err = mcp.jsonrpc.createMethodNotFound(req.id, req.method);
            return try mcp.jsonrpc.serializeMessage(allocator, .{ .error_response = err });
        },
        .notification => {
            // Handle notification (no response needed)
            return "";
        },
        else => {
            return error.UnexpectedMessage;
        },
    }
}
```

## Next Steps

- [Schema Guide](/guide/schema) - JSON Schema validation
- [Transport Guide](/guide/transport) - How messages are sent
- [API Reference](/api/protocol) - Full protocol API
