# Resources

Resources provide read access to data that AI can consume. They represent files, database records, API responses, or any other data source.

## Defining a Resource

```zig
try server.addResource(.{
    .uri = "file:///path/to/resource",
    .name = "My Resource",
    .mimeType = "text/plain",
    .handler = resourceHandler,
});
```

## Resource Properties

| Property      | Type          | Description                   |
| ------------- | ------------- | ----------------------------- |
| `uri`         | `[]const u8`  | Unique resource identifier    |
| `name`        | `[]const u8`  | Human-readable name           |
| `mimeType`    | `?[]const u8` | MIME type of the content      |
| `description` | `?[]const u8` | Description of the resource   |
| `handler`     | `*Handler`    | Function to read the resource |

## Handler Functions

```zig
fn resourceHandler(
    _: ?*anyopaque,
    io: std.Io,
    allocator: std.mem.Allocator,
    uri: []const u8,
) ResourceError!ResourceContent;
```

### Example Handler

```zig
fn readmeHandler(
    _: ?*anyopaque,
    io: std.Io,
    allocator: std.mem.Allocator,
    uri: []const u8,
) mcp.resources.ResourceError!mcp.resources.ResourceContent {
    _ = uri;

    const content = try std.Io.Dir.cwd().readFileAlloc(
        io,
        "README.md",
        allocator,
        .limited(1024 * 1024),
    );

    return .{
        .uri = "file:///README.md",
        .mimeType = "text/markdown",
        .text = content,
    };
}
```

## Resource Content Types

### Text Content

```zig
return .{
    .uri = uri,
    .mimeType = "text/plain",
    .text = "Hello, World!",
};
```

### Binary Content (Base64)

```zig
return .{
    .uri = uri,
    .mimeType = "image/png",
    .blob = base64_encoded_data,
};
```

## Resource Templates

Templates allow dynamic resource URIs with parameters:

```zig
try server.addResourceTemplate(.{
    .uriTemplate = "file:///users/{userId}/profile",
    .name = "User Profile",
    .description = "Get a user's profile by ID",
    .handler = profileHandler,
});
```

### Template Handler

```zig
fn profileHandler(
    _: ?*anyopaque,
    _: std.Io,
    allocator: std.mem.Allocator,
    uri: []const u8,
    params: std.StringHashMap([]const u8),
) ResourceError!ResourceContent {
    const user_id = params.get("userId") orelse {
        return error.InvalidUri;
    };

    // Fetch user profile using user_id
    const profile = try fetchProfile(allocator, user_id);

    return .{
        .uri = uri,
        .mimeType = "application/json",
        .text = profile,
    };
}
```

## Subscribing to Resources

Enable resource subscriptions for real-time updates:

```zig
// Resource changed notification
try server.notifyResourceUpdated("file:///data.json");
```

## Complete Example

```zig
const std = @import("std");
const mcp = @import("mcp");

pub fn main(init: std.process.Init) void {
    run(init.io, init.gpa) catch |err| {
        mcp.reportError(err);
    };
}

fn run(io: std.Io, allocator: std.mem.Allocator) !void {
    var server: mcp.Server = .init(allocator, .{
        .name = "resource-server",
        .version = "1.0.0",
    });
    defer server.deinit();

    // Static file resource
    try server.addResource(.{
        .uri = "file:///config.json",
        .name = "Configuration",
        .mimeType = "application/json",
        .description = "Application configuration",
        .handler = configHandler,
    });

    // Dynamic template
    try server.addResourceTemplate(.{
        .uriTemplate = "db:///records/{id}",
        .name = "Database Record",
        .handler = recordHandler,
    });

    try server.run(io, allocator, .stdio);
}

fn configHandler(
    _: ?*anyopaque,
    _: std.Io,
    allocator: std.mem.Allocator,
    uri: []const u8,
) mcp.resources.ResourceError!mcp.resources.ResourceContent {
    _ = allocator;
    return .{
        .uri = uri,
        .mimeType = "application/json",
        .text = "{\"debug\": true, \"version\": \"1.0.0\"}",
    };
}

fn recordHandler(
    _: ?*anyopaque,
    _: std.Io,
    allocator: std.mem.Allocator,
    uri: []const u8,
    params: std.StringHashMap([]const u8),
) mcp.resources.ResourceError!mcp.resources.ResourceContent {
    const id = params.get("id") orelse return error.InvalidUri;

    const content = try std.fmt.allocPrint(
        allocator,
        "{{\"id\": \"{s}\", \"data\": \"...\"}}",
        .{id},
    );

    return .{
        .uri = uri,
        .mimeType = "application/json",
        .text = content,
    };
}
```

## Next Steps

- [Prompts Guide](/guide/prompts) - Create prompt templates
- [Transport Guide](/guide/transport) - Configure transports
- [API Reference](/api/server#resources) - Detailed API docs
