# Tools

Tools are the primary way for AI clients to interact with your MCP server. They represent actions that can be performed.

## Defining a Tool

```zig
try server.addTool(.{
    .name = "tool_name",
    .description = "What this tool does",
    .handler = handlerFunction,
});
```

## Handler Functions

Tool handlers have this signature:

```zig
fn handler(
    _: ?*anyopaque,
    _: std.Io,
    allocator: std.mem.Allocator,
    args: ?std.json.Value,
) mcp.tools.ToolError!mcp.tools.ToolResult;
```

Use `_` for `user_data` and `io` when you don't need them.

### Example Handler

```zig
fn greetHandler(
    _: ?*anyopaque,
    _: std.Io,
    allocator: std.mem.Allocator,
    args: ?std.json.Value,
) mcp.tools.ToolError!mcp.tools.ToolResult {
    const name = mcp.tools.getString(args, "name") orelse "World";

    const message = try std.fmt.allocPrint(
        allocator,
        "Hello, {s}!",
        .{name},
    );

    return mcp.tools.textResult(allocator, message);
}
```

## Input Schema

Define expected arguments using JSON Schema:

```zig
var schema = mcp.schema.InputSchemaBuilder.init(allocator);
defer schema.deinit(allocator);

_ = try schema.addString(allocator, "name", "The person's name", true);
_ = try schema.addNumber(allocator, "age", "The person's age", false);

try server.addTool(.{
    .name = "greet",
    .description = "Greet a person",
    .handler = greetHandler,
    .inputSchema = try schema.toInputSchema(allocator),
});
```

## Argument Helpers

### Get String Argument

```zig
const value = mcp.tools.getString(args, "key");
if (value) |v| {
    // Use v
}
```

### Get Number Argument

```zig
const value = mcp.tools.getFloat(args, "key");
if (value) |v| {
    // Use v (f64)
}
```

### Get Boolean Argument

```zig
const value = mcp.tools.getBoolean(args, "key");
if (value) |v| {
    // Use v
}
```

## Return Values

### Text Content

```zig
return mcp.tools.textResult(allocator, "Hello, World!");
```

### Image Content

```zig
return mcp.tools.imageResult(allocator, base64_data, "image/png");
```

### Multiple Content Items

```zig
const content = try allocator.alloc(mcp.types.ContentBlock, 3);
content[0] = .{ .text = .{ .text = "Result:" } };
content[1] = .{ .text = .{ .text = "Item 1" } };
content[2] = .{ .text = .{ .text = "Item 2" } };
return .{ .content = content };
```

### Indicating Errors

```zig
return mcp.tools.errorResult(allocator, "Error occurred");
```

## Error Handling

```zig
fn handler(_: ?*anyopaque, _: std.Io, allocator: Allocator, args: ?std.json.Value) mcp.tools.ToolError!ToolResult {
    // Validation error
    if (missing_required_arg) {
        return error.InvalidArguments;
    }

    // Execution error
    if (operation_failed) {
        return error.ExecutionFailed;
    }

    // Out of memory
    const data = allocator.alloc(u8, size) catch {
        return error.OutOfMemory;
    };

    // Success
    return .{ .content = &.{} };
}
```

## Tool Builder

Use the builder pattern for complex tools:

```zig
var schema = mcp.schema.InputSchemaBuilder.init(allocator);
defer schema.deinit(allocator);

_ = try schema.addString(allocator, "input", "Input text", true);
_ = try schema.addNumber(allocator, "count", "Number of iterations", false);
_ = try schema.addBoolean(allocator, "verbose", "Enable verbose output", false);

const tool = mcp.tools.ToolBuilder.init("advanced_tool")
    .description("An advanced tool with many options")
    .handler(advancedHandler)
    .inputSchema(try schema.toInputSchema(allocator))
    .build();

try server.addTool(tool);
```

## Output Schema

You can describe structured tool results with `outputSchema`:

```zig
var props: std.json.ObjectMap = .empty;
var value_obj: std.json.ObjectMap = .empty;
try value_obj.put(allocator, "type", .{ .string = "number" });
try props.put(allocator, "result", .{ .object = value_obj });

const output_schema = mcp.types.OutputSchema{
    .@"$schema" = "https://json-schema.org/draft/2020-12/schema",
    .type = "object",
    .properties = .{ .object = props },
    .required = &[_][]const u8{ "result" },
};

try server.addTool(.{
    .name = "calculate",
    .description = "Perform calculations",
    .handler = calculateHandler,
    .outputSchema = output_schema,
});
```

## Task Support

Tools can opt into task-aware execution:

```zig
try server.addTool(.{
    .name = "long_task",
    .description = "Run a long task",
    .execution = .{ .taskSupport = "optional" },
    .handler = longTaskHandler,
});
```

## Best Practices

::: tip Do

- Provide clear, descriptive tool names
- Document all parameters in the schema
- Handle errors gracefully
- Return meaningful content
  :::

::: warning Don't

- Use side effects without documenting them
- Return empty content on success
- Ignore input validation
  :::

## Complete Example

```zig
const std = @import("std");
const mcp = @import("mcp");

fn calculateHandler(
    _: ?*anyopaque,
    _: std.Io,
    allocator: std.mem.Allocator,
    args: ?std.json.Value,
) mcp.tools.ToolError!mcp.tools.ToolResult {
    const operation = mcp.tools.getString(args, "operation") orelse {
        return error.InvalidArguments;
    };

    const a = mcp.tools.getFloat(args, "a") orelse {
        return error.InvalidArguments;
    };

    const b = mcp.tools.getFloat(args, "b") orelse {
        return error.InvalidArguments;
    };

    const result: f64 = if (std.mem.eql(u8, operation, "add"))
        a + b
    else if (std.mem.eql(u8, operation, "subtract"))
        a - b
    else if (std.mem.eql(u8, operation, "multiply"))
        a * b
    else if (std.mem.eql(u8, operation, "divide"))
        if (b != 0) a / b else return error.InvalidArguments
    else
        return error.InvalidArguments;

    const message = try std.fmt.allocPrint(
        allocator,
        "Result: {d}",
        .{result},
    );

    return mcp.tools.textResult(allocator, message);
}
```

## Next Steps

- [Resources Guide](/guide/resources) - Expose data to AI
- [Prompts Guide](/guide/prompts) - Create prompt templates
- [Error Handling](/guide/error-handling) - Handle errors properly
