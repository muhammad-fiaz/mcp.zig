//! MCP Prompts Module (Spec 2025-11-25)
//!
//! Provides the Prompt primitive for MCP servers. Prompts are reusable templates
//! that help structure interactions with LLMs, allowing servers to expose
//! predefined conversation patterns with optional arguments.

const std = @import("std");
const types = @import("../protocol/types.zig");

/// A prompt template exposed by an MCP server.
pub const Prompt = struct {
    name: []const u8,
    title: ?[]const u8 = null,
    description: ?[]const u8 = null,
    arguments: ?[]const PromptArgument = null,
    icons: ?[]const types.Icon = null,
    _meta: ?std.json.Value = null,
    handler: *const fn (allocator: std.mem.Allocator, args: ?std.json.Value) PromptError![]const PromptMessage,
    user_data: ?*anyopaque = null,
};

/// Argument specification for a prompt.
pub const PromptArgument = struct {
    name: []const u8,
    title: ?[]const u8 = null,
    description: ?[]const u8 = null,
    required: bool = false,
};

/// Message in a prompt result.
pub const PromptMessage = struct {
    role: types.Role,
    content: types.ContentBlock,
};

/// Errors that can occur during prompt operations.
pub const PromptError = error{
    InvalidArguments,
    GenerationFailed,
    OutOfMemory,
    Unknown,
};

/// Builder for creating prompts with a fluent API.
pub const PromptBuilder = struct {
    allocator: std.mem.Allocator,
    prompt: Prompt,
    args_list: std.ArrayList(PromptArgument),

    /// Creates a new prompt builder with the given name.
    pub fn init(allocator: std.mem.Allocator, name: []const u8) PromptBuilder {
        return .{
            .allocator = allocator,
            .prompt = .{ .name = name, .handler = defaultHandler },
            .args_list = .{},
        };
    }

    /// Releases resources held by the builder.
    pub fn deinit(self: *PromptBuilder) void {
        self.args_list.deinit(self.allocator);
    }

    /// Sets the prompt description.
    pub fn description(self: *PromptBuilder, desc: []const u8) *PromptBuilder {
        self.prompt.description = desc;
        return self;
    }

    /// Sets the prompt display title.
    pub fn title(self: *PromptBuilder, t: []const u8) *PromptBuilder {
        self.prompt.title = t;
        return self;
    }

    /// Adds an argument specification to the prompt.
    pub fn addArgument(self: *PromptBuilder, name: []const u8, desc: ?[]const u8, required: bool) !*PromptBuilder {
        try self.args_list.append(self.allocator, .{ .name = name, .description = desc, .required = required });
        return self;
    }

    /// Adds an argument specification with a title to the prompt.
    pub fn addArgumentWithTitle(self: *PromptBuilder, name: []const u8, arg_title: ?[]const u8, desc: ?[]const u8, required: bool) !*PromptBuilder {
        try self.args_list.append(self.allocator, .{ .name = name, .title = arg_title, .description = desc, .required = required });
        return self;
    }

    /// Sets the prompt handler function.
    pub fn handler(self: *PromptBuilder, h: *const fn (std.mem.Allocator, ?std.json.Value) PromptError![]const PromptMessage) *PromptBuilder {
        self.prompt.handler = h;
        return self;
    }

    /// Builds and returns the final prompt.
    pub fn build(self: *PromptBuilder) Prompt {
        if (self.args_list.items.len > 0) {
            self.prompt.arguments = self.args_list.items;
        }
        return self.prompt;
    }

    fn defaultHandler(_: std.mem.Allocator, _: ?std.json.Value) PromptError![]const PromptMessage {
        return &.{};
    }
};

/// Extracts a string argument from prompt arguments by key.
pub fn getStringArg(args: ?std.json.Value, key: []const u8) ?[]const u8 {
    if (args) |a| {
        if (a == .object) {
            if (a.object.get(key)) |val| {
                if (val == .string) return val.string;
            }
        }
    }
    return null;
}

/// Creates a user message with the given text content.
pub fn userMessage(text: []const u8) PromptMessage {
    return .{ .role = .user, .content = .{ .text = .{ .text = text } } };
}

/// Creates an assistant message with the given text content.
pub fn assistantMessage(text: []const u8) PromptMessage {
    return .{ .role = .assistant, .content = .{ .text = .{ .text = text } } };
}

test "PromptBuilder" {
    const allocator = std.testing.allocator;
    var builder = PromptBuilder.init(allocator, "test_prompt");
    defer builder.deinit();

    _ = try builder.addArgument("name", "User name", true);
    const prompt = builder.description("A test prompt").build();

    try std.testing.expectEqualStrings("test_prompt", prompt.name);
    try std.testing.expect(prompt.arguments.?.len == 1);
}

test "userMessage" {
    const msg = userMessage("Hello");
    try std.testing.expectEqual(types.Role.user, msg.role);
}

test "assistantMessage" {
    const msg = assistantMessage("Hi there");
    try std.testing.expectEqual(types.Role.assistant, msg.role);
}
