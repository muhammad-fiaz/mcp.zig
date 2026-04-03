# Schema Validation

mcp.zig provides utilities for working with JSON Schema, commonly used for tool input validation.

## Overview

JSON Schema defines the structure of tool arguments, ensuring valid inputs.

## Basic Schemas

### Creating a Schema

```zig
var builder = mcp.schema.SchemaBuilder.init(allocator);

const schema = builder
    .string_()
    .description("A user's name")
    .build();
```

### Schema Types

| Type    | Method        | Description    |
| ------- | ------------- | -------------- |
| Object  | `.object_()`  | JSON object    |
| Array   | `.array_()`   | JSON array     |
| String  | `.string_()`  | Text value     |
| Number  | `.number_()`  | Floating point |
| Integer | `.integer_()` | Whole number   |
| Boolean | `.boolean_()` | true/false     |

## InputSchemaBuilder

Build complete input schemas for tools:

```zig
var schema = mcp.schema.InputSchemaBuilder.init(allocator);
defer schema.deinit();

// Add string property (required)
_ = try schema.addString("name", "User's name", true);

// Add number property (optional)
_ = try schema.addNumber("age", "User's age", false);

// Add boolean property
_ = try schema.addBoolean("active", "Is user active", false);

// Add enum property
_ = try schema.addEnum(
    "role",
    "User's role",
    &.{ "admin", "user", "guest" },
    true,
);

// Build the schema
const inputSchema = try schema.build();
```

### Using with Tools

```zig
try server.addTool(.{
    .name = "create_user",
    .description = "Create a new user",
    .handler = createUserHandler,
    .inputSchema = try schema.build(),
});
```

## Schema Properties

### String Constraints

```zig
builder
    .string_()
    .minLength(1)
    .maxLength(100)
    .pattern("^[a-zA-Z]+$")
    .format("email")
```

### Number Constraints

```zig
builder
    .number_()
    .minimum(0)
    .maximum(100)
```

### Common Formats

| Format      | Description       |
| ----------- | ----------------- |
| `email`     | Email address     |
| `uri`       | URI/URL           |
| `date-time` | ISO 8601 datetime |
| `uuid`      | UUID string       |

## Common Schemas

Pre-defined schemas for common types:

```zig
// String schema
const str = try mcp.schema.CommonSchemas.string_schema(allocator);

// Number schema
const num = try mcp.schema.CommonSchemas.number_schema(allocator);

// URI schema
const uri = try mcp.schema.CommonSchemas.uri_schema(allocator);

// DateTime schema
const dt = try mcp.schema.CommonSchemas.datetime_schema(allocator);
```

## Converting to JSON

Schemas can be converted to JSON for the protocol:

```zig
const json_value = try schema.toJson(allocator);
```

## Complete Example

```zig
const std = @import("std");
const mcp = @import("mcp");

pub fn setupServer(allocator: std.mem.Allocator) !mcp.Server {
    var server = mcp.Server.init(.{
        .name = "validated-server",
        .version = "1.0.0",
        .allocator = allocator,
    });

    // Build input schema
    var schema = mcp.schema.InputSchemaBuilder.init(allocator);

    _ = try schema.addString("username", "Unique username", true);
    _ = try schema.addString("email", "Email address", true);
    _ = try schema.addInteger("age", "User's age (must be 18+)", false);
    _ = try schema.addBoolean("newsletter", "Subscribe to newsletter", false);
    _ = try schema.addEnum(
        "plan",
        "Subscription plan",
        &.{ "free", "basic", "pro" },
        true,
    );

    try server.addTool(.{
        .name = "register_user",
        .description = "Register a new user account",
        .handler = registerHandler,
        .inputSchema = try schema.build(),
    });

    return server;
}

fn registerHandler(
    allocator: std.mem.Allocator,
    args: ?std.json.Value,
) mcp.tools.ToolError!mcp.tools.ToolResult {
    // Arguments are already validated against schema by client
    const username = mcp.tools.getString(args, "username") orelse {
        return error.InvalidArguments;
    };

    const email = mcp.tools.getString(args, "email") orelse {
        return error.InvalidArguments;
    };

    const plan = mcp.tools.getString(args, "plan") orelse "free";

    const message = try std.fmt.allocPrint(
        allocator,
        "User {s} registered with email {s} on {s} plan",
        .{ username, email, plan },
    );

    return mcp.tools.textResult(allocator, message);
}
```

## Best Practices

::: tip Do

- Always define schemas for tools
- Use descriptive descriptions
- Mark required fields appropriately
- Use appropriate types (integer vs number)
  :::

::: warning Don't

- Skip validation in handlers
- Use overly permissive schemas
- Forget to document optional fields
  :::

## Next Steps

- [Tools Guide](/guide/tools) - Using schemas with tools
- [Error Handling](/guide/error-handling) - Handle validation errors
- [API Reference](/api/types#schema) - Schema API details
