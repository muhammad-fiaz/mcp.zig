//! MCP Middleware and Utilities
//!
//! Provides middleware support, request validation, and helper utilities
//! for building MCP servers and clients.

const std = @import("std");

/// Middleware function type that wraps tool handlers.
/// Return null to continue with original handler, or return a result to short-circuit.
pub const ToolMiddleware = *const fn (ctx: ?*anyopaque, io: std.Io, allocator: std.mem.Allocator, name: []const u8, args: ?std.json.Value) ?ToolResult;

/// Middleware function type that wraps resource handlers.
pub const ResourceMiddleware = *const fn (ctx: ?*anyopaque, io: std.Io, allocator: std.mem.Allocator, uri: []const u8) ?ResourceContent;

/// Middleware function type that wraps prompt handlers.
pub const PromptMiddleware = *const fn (ctx: ?*anyopaque, io: std.Io, allocator: std.mem.Allocator, name: []const u8, args: ?std.json.Value) ?[]const PromptMessage;

/// Result types for middleware.
pub const ToolResult = @import("../server/tools.zig").ToolResult;
pub const ResourceContent = @import("../server/resources.zig").ResourceContent;
pub const PromptMessage = @import("../server/prompts.zig").PromptMessage;

/// Logging middleware context.
pub const LoggingContext = struct {
    log_level: LogLevel = .info,

    pub const LogLevel = enum {
        debug,
        info,
        warn,
        err,
    };

    pub fn log(self: *LoggingContext, comptime level: LogLevel, comptime fmt: []const u8, args: anytype) void {
        if (@intFromEnum(level) >= @intFromEnum(self.log_level)) {
            std.log.info(fmt, args);
        }
    }
};

/// Rate limiter for tool calls.
pub const RateLimiter = struct {
    max_calls: u32,
    call_count: u32,

    pub fn init(max_calls: u32) RateLimiter {
        return .{
            .max_calls = max_calls,
            .call_count = 0,
        };
    }

    pub fn check(self: *RateLimiter) bool {
        if (self.call_count >= self.max_calls) {
            return false;
        }
        self.call_count += 1;
        return true;
    }

    pub fn reset(self: *RateLimiter) void {
        self.call_count = 0;
    }
};

/// Request validator for tool arguments.
pub const RequestValidator = struct {
    required_fields: []const []const u8,
    optional_fields: []const []const u8,

    pub fn init(required: []const []const u8, optional: []const []const u8) RequestValidator {
        return .{
            .required_fields = required,
            .optional_fields = optional,
        };
    }

    pub fn validate(self: RequestValidator, args: ?std.json.Value) ?[]const u8 {
        if (args == null) {
            if (self.required_fields.len > 0) {
                return "Missing required arguments";
            }
            return null;
        }

        const a = args orelse return null;
        if (a != .object) return "Arguments must be an object";

        for (self.required_fields) |field| {
            if (a.object.get(field) == null) {
                return "Missing required field";
            }
        }

        return null;
    }
};

/// Helper to create a tool result with text content.
pub fn textResult(allocator: std.mem.Allocator, text: []const u8) !ToolResult {
    return @import("../server/tools.zig").textResult(allocator, text);
}

/// Helper to create an error result.
pub fn errorResult(allocator: std.mem.Allocator, message: []const u8) !ToolResult {
    return @import("../server/tools.zig").errorResult(allocator, message);
}

/// Helper to extract string from JSON value.
pub fn getString(value: ?std.json.Value, key: []const u8) ?[]const u8 {
    return @import("../server/tools.zig").getString(value, key);
}

/// Helper to extract integer from JSON value.
pub fn getInteger(value: ?std.json.Value, key: []const u8) ?i64 {
    return @import("../server/tools.zig").getInteger(value, key);
}

/// Helper to extract float from JSON value.
pub fn getFloat(value: ?std.json.Value, key: []const u8) ?f64 {
    return @import("../server/tools.zig").getFloat(value, key);
}

/// Helper to extract boolean from JSON value.
pub fn getBoolean(value: ?std.json.Value, key: []const u8) ?bool {
    return @import("../server/tools.zig").getBoolean(value, key);
}

/// Batch request builder for sending multiple requests at once.
pub const BatchRequest = struct {
    requests: std.ArrayList(BatchItem),
    allocator: std.mem.Allocator,

    const BatchItem = struct {
        method: []const u8,
        params: ?std.json.Value,
    };

    pub fn init(allocator: std.mem.Allocator) BatchRequest {
        return .{
            .requests = .empty,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *BatchRequest) void {
        self.requests.deinit(self.allocator);
    }

    pub fn addRequest(self: *BatchRequest, method: []const u8, params: ?std.json.Value) !void {
        try self.requests.append(self.allocator, .{ .method = method, .params = params });
    }

    pub fn addListTools(self: *BatchRequest) !void {
        try self.addRequest("tools/list", null);
    }

    pub fn addListResources(self: *BatchRequest) !void {
        try self.addRequest("resources/list", null);
    }

    pub fn addListPrompts(self: *BatchRequest) !void {
        try self.addRequest("prompts/list", null);
    }

    pub fn addDiscover(self: *BatchRequest) !void {
        try self.addRequest("server/discover", null);
    }

    pub fn addHealthCheck(self: *BatchRequest) !void {
        try self.addRequest("health/check", null);
    }

    pub fn addToolsCall(self: *BatchRequest, name: []const u8) !void {
        try self.addRequest("tools/call", null);
        _ = name;
    }
};

test "RateLimiter" {
    var limiter = RateLimiter.init(5);

    // Should allow first 5 calls
    for (0..5) |_| {
        try std.testing.expect(limiter.check());
    }

    // Should reject 6th call
    try std.testing.expect(!limiter.check());

    // Reset and try again
    limiter.reset();
    try std.testing.expect(limiter.check());
}

test "RateLimiter zero limit" {
    var limiter = RateLimiter.init(0);
    try std.testing.expect(!limiter.check());
}

test "RateLimiter single call" {
    var limiter = RateLimiter.init(1);
    try std.testing.expect(limiter.check());
    try std.testing.expect(!limiter.check());
}

test "RequestValidator" {
    const validator = RequestValidator.init(&.{ "name", "age" }, &.{"email"});

    // Missing required field
    var args1: std.json.ObjectMap = .empty;
    defer args1.deinit(std.testing.allocator);
    try args1.put(std.testing.allocator, "name", .{ .string = "test" });
    const err = validator.validate(.{ .object = args1 });
    try std.testing.expect(err != null);

    // All required fields present
    var args2: std.json.ObjectMap = .empty;
    defer args2.deinit(std.testing.allocator);
    try args2.put(std.testing.allocator, "name", .{ .string = "test" });
    try args2.put(std.testing.allocator, "age", .{ .integer = 25 });
    const err2 = validator.validate(.{ .object = args2 });
    try std.testing.expect(err2 == null);
}

test "RequestValidator null args" {
    const validator = RequestValidator.init(&.{"name"}, &.{});
    // Null args with required fields should fail
    const err = validator.validate(null);
    try std.testing.expect(err != null);
}

test "RequestValidator no required fields" {
    const validator = RequestValidator.init(&.{}, &.{"email"});
    // No required fields, null args is OK
    const err = validator.validate(null);
    try std.testing.expect(err == null);
}

test "RequestValidator non-object args" {
    const validator = RequestValidator.init(&.{"name"}, &.{});
    // Non-object args with required fields should fail
    const err = validator.validate(.{ .string = "not an object" });
    try std.testing.expect(err != null);
}

test "RequestValidator optional fields" {
    const validator = RequestValidator.init(&.{ "name", "email" }, &.{ "age", "role" });

    // All required + some optional
    var args: std.json.ObjectMap = .empty;
    defer args.deinit(std.testing.allocator);
    try args.put(std.testing.allocator, "name", .{ .string = "test" });
    try args.put(std.testing.allocator, "email", .{ .string = "test@example.com" });
    try args.put(std.testing.allocator, "age", .{ .integer = 30 });
    const err = validator.validate(.{ .object = args });
    try std.testing.expect(err == null);
}

test "BatchRequest init" {
    var batch = BatchRequest.init(std.testing.allocator);
    defer batch.deinit();

    try std.testing.expectEqual(@as(usize, 0), batch.requests.items.len);
}

test "BatchRequest addRequest" {
    var batch = BatchRequest.init(std.testing.allocator);
    defer batch.deinit();

    try batch.addRequest("tools/list", null);
    try std.testing.expectEqual(@as(usize, 1), batch.requests.items.len);
    try std.testing.expectEqualStrings("tools/list", batch.requests.items[0].method);
}

test "BatchRequest addToolsCall" {
    var batch = BatchRequest.init(std.testing.allocator);
    defer batch.deinit();

    try batch.addToolsCall("test_tool");
    try std.testing.expectEqual(@as(usize, 1), batch.requests.items.len);
    try std.testing.expectEqualStrings("tools/call", batch.requests.items[0].method);
}

test "BatchRequest addListTools" {
    var batch = BatchRequest.init(std.testing.allocator);
    defer batch.deinit();

    try batch.addListTools();
    try std.testing.expectEqual(@as(usize, 1), batch.requests.items.len);
    try std.testing.expectEqualStrings("tools/list", batch.requests.items[0].method);
}

test "BatchRequest addListResources" {
    var batch = BatchRequest.init(std.testing.allocator);
    defer batch.deinit();

    try batch.addListResources();
    try std.testing.expectEqual(@as(usize, 1), batch.requests.items.len);
    try std.testing.expectEqualStrings("resources/list", batch.requests.items[0].method);
}

test "BatchRequest addDiscover" {
    var batch = BatchRequest.init(std.testing.allocator);
    defer batch.deinit();

    try batch.addDiscover();
    try std.testing.expectEqual(@as(usize, 1), batch.requests.items.len);
    try std.testing.expectEqualStrings("server/discover", batch.requests.items[0].method);
}

test "BatchRequest multiple requests" {
    var batch = BatchRequest.init(std.testing.allocator);
    defer batch.deinit();

    try batch.addDiscover();
    try batch.addListTools();
    try batch.addListResources();
    try batch.addListTools();

    try std.testing.expectEqual(@as(usize, 4), batch.requests.items.len);
}
