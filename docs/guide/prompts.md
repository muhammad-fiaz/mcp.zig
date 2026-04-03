# Prompts

Prompts are reusable templates that help structure interactions with AI models.

## Defining a Prompt

```zig
try server.addPrompt(.{
    .name = "summarize",
    .description = "Summarize a piece of text",
    .handler = summarizeHandler,
});
```

## Prompt Properties

| Property      | Type                | Description                   |
| ------------- | ------------------- | ----------------------------- |
| `name`        | `[]const u8`        | Unique prompt name            |
| `title`       | `?[]const u8`       | Human-readable title          |
| `description` | `?[]const u8`       | Description of the prompt     |
| `arguments`   | `?[]PromptArgument` | Expected arguments            |
| `handler`     | `*Handler`          | Function to generate messages |

## Handler Functions

```zig
fn promptHandler(
    allocator: std.mem.Allocator,
    args: ?std.json.Value,
) PromptError![]const PromptMessage;
```

### Example Handler

```zig
fn codeReviewHandler(
    allocator: std.mem.Allocator,
    args: ?std.json.Value,
) mcp.prompts.PromptError![]const mcp.prompts.PromptMessage {
    const code = mcp.prompts.getStringArg(args, "code") orelse {
        return error.InvalidArguments;
    };

    const language = mcp.prompts.getStringArg(args, "language") orelse "unknown";

    const system_prompt = try std.fmt.allocPrint(
        allocator,
        "You are a code reviewer. Review the following {s} code for best practices, bugs, and improvements.",
        .{language},
    );

    return &.{
        mcp.prompts.userMessage(system_prompt),
        mcp.prompts.userMessage(code),
    };
}
```

## Prompt Arguments

Define expected arguments:

```zig
try server.addPrompt(.{
    .name = "analyze",
    .description = "Analyze text for sentiment",
    .arguments = &.{
        .{ .name = "text", .description = "Text to analyze", .required = true },
        .{ .name = "language", .description = "Language of the text", .required = false },
    },
    .handler = analyzeHandler,
});
```

## Message Types

### User Message

```zig
mcp.prompts.userMessage("Analyze this text for me")
```

### Assistant Message

```zig
mcp.prompts.assistantMessage("I'll analyze the text...")
```

### Custom Role

```zig
.{
    .role = "system",
    .content = .{ .text = .{ .text = "You are a helpful assistant." } },
}
```

## Using PromptBuilder

```zig
var builder = mcp.prompts.PromptBuilder.init(allocator, "my_prompt");
defer builder.deinit();

const prompt = builder
    .description("A helpful prompt")
    .addArgument("input", "The input text", true)
    .addArgument("style", "Output style", false)
    .handler(myHandler)
    .build();

try server.addPrompt(prompt);
```

## Complete Example

```zig
const std = @import("std");
const mcp = @import("mcp");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var server = mcp.Server.init(.{
        .name = "prompt-server",
        .version = "1.0.0",
        .allocator = allocator,
    });
    defer server.deinit();

    // Simple prompt
    try server.addPrompt(.{
        .name = "explain",
        .description = "Explain a concept simply",
        .arguments = &.{
            .{ .name = "concept", .description = "The concept to explain", .required = true },
            .{ .name = "level", .description = "Expertise level (beginner/advanced)", .required = false },
        },
        .handler = explainHandler,
    });

    // Code generation prompt
    try server.addPrompt(.{
        .name = "generate_code",
        .description = "Generate code for a task",
        .arguments = &.{
            .{ .name = "task", .description = "What the code should do", .required = true },
            .{ .name = "language", .description = "Programming language", .required = true },
        },
        .handler = generateCodeHandler,
    });

    try server.run(.stdio);
}

fn explainHandler(
    allocator: std.mem.Allocator,
    args: ?std.json.Value,
) mcp.prompts.PromptError![]const mcp.prompts.PromptMessage {
    const concept = mcp.prompts.getStringArg(args, "concept") orelse {
        return error.InvalidArguments;
    };

    const level = mcp.prompts.getStringArg(args, "level") orelse "beginner";

    const prompt_text = try std.fmt.allocPrint(
        allocator,
        "Please explain '{s}' at a {s} level. Use simple examples and analogies.",
        .{ concept, level },
    );

    return &.{
        mcp.prompts.userMessage(prompt_text),
    };
}

fn generateCodeHandler(
    allocator: std.mem.Allocator,
    args: ?std.json.Value,
) mcp.prompts.PromptError![]const mcp.prompts.PromptMessage {
    const task = mcp.prompts.getStringArg(args, "task") orelse {
        return error.InvalidArguments;
    };

    const language = mcp.prompts.getStringArg(args, "language") orelse {
        return error.InvalidArguments;
    };

    const system = try std.fmt.allocPrint(
        allocator,
        "You are an expert {s} programmer. Generate clean, well-documented code.",
        .{language},
    );

    const user = try std.fmt.allocPrint(
        allocator,
        "Write {s} code to: {s}",
        .{ language, task },
    );

    return &.{
        .{ .role = "system", .content = .{ .text = .{ .text = system } } },
        mcp.prompts.userMessage(user),
    };
}
```

## Next Steps

- [Transport Guide](/guide/transport) - Configure communication
- [Error Handling](/guide/error-handling) - Handle errors gracefully
- [Examples](/examples/) - See complete examples
