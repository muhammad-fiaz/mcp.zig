# Types API

Core type definitions used throughout mcp.zig.

## Request ID

### `types.RequestId`

```zig
pub const RequestId = union(enum) {
    integer: i64,
    string: []const u8,
};
```

Request IDs can be either integers or strings.

**Example:**

```zig
const id1: mcp.types.RequestId = .{ .integer = 42 };
const id2: mcp.types.RequestId = .{ .string = "request-001" };
```

---

## Content

### `ContentBlock`

```zig
pub const ContentBlock = union(enum) {
    text: TextContent,
    image: ImageContent,
    audio: AudioContent,
    resource_link: ResourceLink,
    resource: EmbeddedResource,
};
```

Content types for tool results and messages.

### `TextContent`

```zig
pub const TextContent = struct {
    type: []const u8 = "text",
    text: []const u8,
    annotations: ?Annotations = null,
    _meta: ?std.json.Value = null,
};
```

### `ImageContent`

```zig
pub const ImageContent = struct {
    type: []const u8 = "image",
    data: []const u8,
    mimeType: []const u8,
    annotations: ?Annotations = null,
    _meta: ?std.json.Value = null,
};
```

### `AudioContent`

```zig
pub const AudioContent = struct {
    type: []const u8 = "audio",
    data: []const u8,
    mimeType: []const u8,
    annotations: ?Annotations = null,
    _meta: ?std.json.Value = null,
};
```

### `ResourceLink`

```zig
pub const ResourceLink = struct {
    type: []const u8 = "resource_link",
    icons: ?[]const Icon = null,
    name: []const u8,
    title: ?[]const u8 = null,
    uri: []const u8,
    description: ?[]const u8 = null,
    mimeType: ?[]const u8 = null,
    annotations: ?Annotations = null,
    size: ?u64 = null,
    _meta: ?std.json.Value = null,
};
```

### Helper Functions

Instead of constructing contents manually, tools should utilize the helper functions:

```zig
/// Create a text result
pub fn textResult(allocator: std.mem.Allocator, text: []const u8) !ToolResult

/// Create an image result
pub fn imageResult(allocator: std.mem.Allocator, data: []const u8, mimeType: []const u8) !ToolResult

/// Create an audio result
pub fn audioResult(allocator: std.mem.Allocator, data: []const u8, mimeType: []const u8) !ToolResult

/// Create a resource link result
pub fn resourceLinkResult(allocator: std.mem.Allocator, name: []const u8, uri: []const u8) !ToolResult
```

**Example:**

```zig
return mcp.tools.textResult(allocator, "Hello, World!");
```

---

## Tool Types

### `ToolResult`

```zig
pub const ToolResult = struct {
    content: []const ContentBlock,
    structuredContent: ?std.json.Value = null,
    is_error: bool = false,
};
```

### `ToolError`

```zig
pub const ToolError = error{
    InvalidArguments,
    ExecutionFailed,
    OutOfMemory,
    Unknown,
};
```

---

## Resource Types

### `Resource`

```zig
pub const Resource = struct {
    uri: []const u8,
    name: []const u8,
    mimeType: ?[]const u8 = null,
    description: ?[]const u8 = null,
};
```

### `ResourceContent`

```zig
pub const ResourceContent = struct {
    uri: []const u8,
    mimeType: ?[]const u8 = null,
    text: ?[]const u8 = null,
    blob: ?[]const u8 = null,
};
```

### `ResourceError`

```zig
pub const ResourceError = error{
    NotFound,
    InvalidUri,
    AccessDenied,
    OutOfMemory,
};
```

---

## Root Types

### `Root`

```zig
pub const Root = struct {
    uri: []const u8,
    name: ?[]const u8 = null,
};
```

Represents a filesystem root.

---

## Implementation Info

### `Implementation`

```zig
pub const Implementation = struct {
    name: []const u8,
    version: []const u8,
    title: ?[]const u8 = null,
};
```

Used in initialize requests for server/client info.

---

## Capabilities

### `ServerCapabilities`

```zig
pub const ServerCapabilities = struct {
    experimental: ?std.json.Value = null,
    completions: ?CompletionsCapability = null,
    tools: ?ToolsCapability = null,
    resources: ?ResourcesCapability = null,
    prompts: ?PromptsCapability = null,
    logging: ?LoggingCapability = null,
    tasks: ?ServerTasksCapability = null,
};
```

### `ClientCapabilities`

```zig
pub const ClientCapabilities = struct {
    experimental: ?std.json.Value = null,
    roots: ?RootsCapability = null,
    sampling: ?SamplingCapability = null,
    elicitation: ?ElicitationCapability = null,
    tasks: ?ClientTasksCapability = null,
};
```

---

## Schema Types

### `Schema`

```zig
pub const Schema = struct {
    type: ?SchemaType = null,
    properties: ?std.json.ObjectMap = null,
    required: ?[]const []const u8 = null,
    items: ?*const Schema = null,
    description: ?[]const u8 = null,
    minimum: ?f64 = null,
    maximum: ?f64 = null,
    pattern: ?[]const u8 = null,
};
```

### `SchemaType`

```zig
pub const SchemaType = enum {
    object,
    array,
    string,
    number,
    integer,
    boolean,
    null_type,
};
```

---

## Log Levels

### `LoggingLevel`

```zig
pub const LoggingLevel = enum {
    debug,
    info,
    notice,
    warning,
    @"error",
    critical,
    alert,
    emergency,
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

fn run(_: std.Io, _: std.mem.Allocator) !void {
    std.debug.print("Root: {s}\n", .{root.uri});
    std.debug.print("Implementation: {s} v{s}\n", .{ impl.name, impl.version });
}
```
