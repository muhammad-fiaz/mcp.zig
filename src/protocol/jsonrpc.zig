//! JSON-RPC 2.0 Implementation
//!
//! Provides a complete JSON-RPC 2.0 implementation for MCP communication.
//! Handles message parsing, serialization, validation, and factory functions
//! for creating requests, responses, notifications, and errors.

const std = @import("std");
const types = @import("types.zig");

/// JSON-RPC protocol version.
pub const VERSION = "2.0";

/// A JSON-RPC 2.0 request message.
pub const Request = struct {
    jsonrpc: []const u8 = VERSION,
    id: types.RequestId,
    method: []const u8,
    params: ?std.json.Value = null,

    pub fn format(
        self: Request,
        comptime _: []const u8,
        _: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        try writer.print("Request{{ id: {}, method: \"{s}\" }}", .{ self.id, self.method });
    }
};

/// A JSON-RPC 2.0 notification (request without id).
pub const Notification = struct {
    jsonrpc: []const u8 = VERSION,
    method: []const u8,
    params: ?std.json.Value = null,

    pub fn format(
        self: Notification,
        comptime _: []const u8,
        _: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        try writer.print("Notification{{ method: \"{s}\" }}", .{self.method});
    }
};

/// A JSON-RPC 2.0 success response.
pub const Response = struct {
    jsonrpc: []const u8 = VERSION,
    id: types.RequestId,
    result: ?std.json.Value = null,

    pub fn format(
        self: Response,
        comptime _: []const u8,
        _: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        try writer.print("Response{{ id: {} }}", .{self.id});
    }
};

/// A JSON-RPC 2.0 error response.
pub const ErrorResponse = struct {
    jsonrpc: []const u8 = VERSION,
    id: ?types.RequestId,
    @"error": Error,

    pub const Error = struct {
        code: i32,
        message: []const u8,
        data: ?std.json.Value = null,
    };

    pub fn format(
        self: ErrorResponse,
        comptime _: []const u8,
        _: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        if (self.id) |id| {
            try writer.print("ErrorResponse{{ id: {}, code: {d}, message: \"{s}\" }}", .{ id, self.@"error".code, self.@"error".message });
        } else {
            try writer.print("ErrorResponse{{ id: null, code: {d}, message: \"{s}\" }}", .{ self.@"error".code, self.@"error".message });
        }
    }
};

/// Union of all JSON-RPC message types.
pub const Message = union(enum) {
    request: Request,
    notification: Notification,
    response: Response,
    error_response: ErrorResponse,

    pub fn isRequest(self: Message) bool {
        return self == .request;
    }

    pub fn isNotification(self: Message) bool {
        return self == .notification;
    }

    pub fn isResponse(self: Message) bool {
        return self == .response or self == .error_response;
    }
};

/// Standard JSON-RPC 2.0 error codes and MCP extensions.
pub const ErrorCode = struct {
    pub const PARSE_ERROR: i32 = -32700;
    pub const INVALID_REQUEST: i32 = -32600;
    pub const METHOD_NOT_FOUND: i32 = -32601;
    pub const INVALID_PARAMS: i32 = -32602;
    pub const INTERNAL_ERROR: i32 = -32603;
    pub const SERVER_NOT_INITIALIZED: i32 = -32002;
    pub const REQUEST_CANCELLED: i32 = -32800;
    pub const CONTENT_TOO_LARGE: i32 = -32801;
};

/// Errors that can occur during message parsing.
pub const ParseError = error{
    InvalidJson,
    MissingVersion,
    InvalidVersion,
    MissingMethod,
    InvalidMessage,
    OutOfMemory,
};

/// Result of parsing a message, keeping the arena alive.
pub const ParsedMessage = struct {
    message: Message,
    parsed: std.json.Parsed(std.json.Value),

    pub fn deinit(self: ParsedMessage) void {
        self.parsed.deinit();
    }
};

/// Parses a JSON-RPC message from a JSON string.
pub fn parseMessage(allocator: std.mem.Allocator, json_str: []const u8) ParseError!ParsedMessage {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, json_str, .{}) catch {
        return ParseError.InvalidJson;
    };
    errdefer parsed.deinit();

    const message = parseFromValue(parsed.value) catch |err| {
        return err;
    };

    return ParsedMessage{
        .message = message,
        .parsed = parsed,
    };
}

/// Parses a JSON-RPC message from a parsed JSON value.
pub fn parseFromValue(value: std.json.Value) ParseError!Message {
    if (value != .object) {
        return ParseError.InvalidMessage;
    }

    const obj = value.object;

    if (obj.get("jsonrpc")) |version_val| {
        if (version_val != .string or !std.mem.eql(u8, version_val.string, VERSION)) {
            return ParseError.InvalidVersion;
        }
    } else {
        return ParseError.MissingVersion;
    }

    if (obj.get("error")) |_| {
        return Message{ .error_response = parseErrorResponse(obj) catch return ParseError.InvalidMessage };
    }

    if (obj.get("method")) |method_val| {
        if (method_val != .string) {
            return ParseError.InvalidMessage;
        }

        if (obj.get("id")) |id_val| {
            return Message{ .request = parseRequest(obj, id_val, method_val.string) catch return ParseError.InvalidMessage };
        } else {
            return Message{ .notification = parseNotification(obj, method_val.string) };
        }
    }

    if (obj.get("id")) |id_val| {
        if (obj.get("result") != null) {
            return Message{ .response = parseResponse(obj, id_val) catch return ParseError.InvalidMessage };
        }
    }

    return ParseError.InvalidMessage;
}

fn parseRequest(obj: std.json.ObjectMap, id_val: std.json.Value, method: []const u8) !Request {
    return Request{
        .id = try parseRequestId(id_val),
        .method = method,
        .params = obj.get("params"),
    };
}

fn parseNotification(obj: std.json.ObjectMap, method: []const u8) Notification {
    return Notification{
        .method = method,
        .params = obj.get("params"),
    };
}

fn parseResponse(obj: std.json.ObjectMap, id_val: std.json.Value) !Response {
    return Response{
        .id = try parseRequestId(id_val),
        .result = obj.get("result"),
    };
}

fn parseErrorResponse(obj: std.json.ObjectMap) !ErrorResponse {
    const error_obj = obj.get("error") orelse return error.InvalidMessage;
    if (error_obj != .object) return error.InvalidMessage;

    const err = error_obj.object;
    const code = if (err.get("code")) |c| switch (c) {
        .integer => @as(i32, @intCast(c.integer)),
        else => return error.InvalidMessage,
    } else return error.InvalidMessage;

    const message = if (err.get("message")) |m| switch (m) {
        .string => m.string,
        else => return error.InvalidMessage,
    } else return error.InvalidMessage;

    const id = if (obj.get("id")) |id_val| try parseRequestId(id_val) else null;

    return ErrorResponse{
        .id = id,
        .@"error" = .{
            .code = code,
            .message = message,
            .data = err.get("data"),
        },
    };
}

fn parseRequestId(value: std.json.Value) !types.RequestId {
    return switch (value) {
        .string => |s| types.RequestId{ .string = s },
        .integer => |i| types.RequestId{ .integer = i },
        else => error.InvalidMessage,
    };
}

/// Serializes a message to a JSON string.
pub fn serializeMessage(allocator: std.mem.Allocator, message: Message) ![]u8 {
    var buffer: std.ArrayList(u8) = .{};
    errdefer buffer.deinit(allocator);

    switch (message) {
        .request => |req| try serializeRequest(allocator, &buffer, req),
        .notification => |notif| try serializeNotification(allocator, &buffer, notif),
        .response => |resp| try serializeResponse(allocator, &buffer, resp),
        .error_response => |err| try serializeErrorResponse(allocator, &buffer, err),
    }

    return buffer.toOwnedSlice(allocator);
}

fn serializeRequest(allocator: std.mem.Allocator, buffer: *std.ArrayList(u8), req: Request) !void {
    try buffer.appendSlice(allocator, "{\"jsonrpc\":\"2.0\",\"id\":");
    try serializeRequestId(allocator, buffer, req.id);
    try buffer.appendSlice(allocator, ",\"method\":\"");
    try buffer.appendSlice(allocator, req.method);
    try buffer.appendSlice(allocator, "\"");
    if (req.params) |params| {
        try buffer.appendSlice(allocator, ",\"params\":");
        try serializeValue(allocator, buffer, params);
    }
    try buffer.appendSlice(allocator, "}");
}

fn serializeNotification(allocator: std.mem.Allocator, buffer: *std.ArrayList(u8), notif: Notification) !void {
    try buffer.appendSlice(allocator, "{\"jsonrpc\":\"2.0\",\"method\":\"");
    try buffer.appendSlice(allocator, notif.method);
    try buffer.appendSlice(allocator, "\"");
    if (notif.params) |params| {
        try buffer.appendSlice(allocator, ",\"params\":");
        try serializeValue(allocator, buffer, params);
    }
    try buffer.appendSlice(allocator, "}");
}

fn serializeResponse(allocator: std.mem.Allocator, buffer: *std.ArrayList(u8), resp: Response) !void {
    try buffer.appendSlice(allocator, "{\"jsonrpc\":\"2.0\",\"id\":");
    try serializeRequestId(allocator, buffer, resp.id);
    try buffer.appendSlice(allocator, ",\"result\":");
    if (resp.result) |result| {
        try serializeValue(allocator, buffer, result);
    } else {
        try buffer.appendSlice(allocator, "null");
    }
    try buffer.appendSlice(allocator, "}");
}

fn serializeErrorResponse(allocator: std.mem.Allocator, buffer: *std.ArrayList(u8), err: ErrorResponse) !void {
    try buffer.appendSlice(allocator, "{\"jsonrpc\":\"2.0\",\"id\":");
    if (err.id) |id| {
        try serializeRequestId(allocator, buffer, id);
    } else {
        try buffer.appendSlice(allocator, "null");
    }
    try buffer.appendSlice(allocator, ",\"error\":{\"code\":");
    var code_buf: [16]u8 = undefined;
    const code_str = std.fmt.bufPrint(&code_buf, "{d}", .{err.@"error".code}) catch "0";
    try buffer.appendSlice(allocator, code_str);
    try buffer.appendSlice(allocator, ",\"message\":\"");
    try buffer.appendSlice(allocator, err.@"error".message);
    try buffer.appendSlice(allocator, "\"");
    if (err.@"error".data) |data| {
        try buffer.appendSlice(allocator, ",\"data\":");
        try serializeValue(allocator, buffer, data);
    }
    try buffer.appendSlice(allocator, "}}");
}

fn serializeRequestId(allocator: std.mem.Allocator, buffer: *std.ArrayList(u8), id: types.RequestId) !void {
    switch (id) {
        .string => |s| {
            try buffer.appendSlice(allocator, "\"");
            try buffer.appendSlice(allocator, s);
            try buffer.appendSlice(allocator, "\"");
        },
        .integer => |i| {
            var int_buf: [32]u8 = undefined;
            const int_str = std.fmt.bufPrint(&int_buf, "{d}", .{i}) catch "0";
            try buffer.appendSlice(allocator, int_str);
        },
    }
}

pub fn serializeValue(allocator: std.mem.Allocator, buffer: *std.ArrayList(u8), value: std.json.Value) !void {
    switch (value) {
        .null => try buffer.appendSlice(allocator, "null"),
        .bool => |b| try buffer.appendSlice(allocator, if (b) "true" else "false"),
        .integer => |i| {
            var int_buf: [32]u8 = undefined;
            const int_str = std.fmt.bufPrint(&int_buf, "{d}", .{i}) catch "0";
            try buffer.appendSlice(allocator, int_str);
        },
        .float => |f| {
            var float_buf: [64]u8 = undefined;
            const float_str = std.fmt.bufPrint(&float_buf, "{d}", .{f}) catch "0";
            try buffer.appendSlice(allocator, float_str);
        },
        .string => |s| {
            try buffer.appendSlice(allocator, "\"");
            for (s) |c| {
                switch (c) {
                    '"' => try buffer.appendSlice(allocator, "\\\""),
                    '\\' => try buffer.appendSlice(allocator, "\\\\"),
                    '\n' => try buffer.appendSlice(allocator, "\\n"),
                    '\r' => try buffer.appendSlice(allocator, "\\r"),
                    '\t' => try buffer.appendSlice(allocator, "\\t"),
                    else => try buffer.append(allocator, c),
                }
            }
            try buffer.appendSlice(allocator, "\"");
        },
        .array => |arr| {
            try buffer.appendSlice(allocator, "[");
            for (arr.items, 0..) |item, i| {
                if (i > 0) try buffer.appendSlice(allocator, ",");
                try serializeValue(allocator, buffer, item);
            }
            try buffer.appendSlice(allocator, "]");
        },
        .object => |obj| {
            try buffer.appendSlice(allocator, "{");
            var first = true;
            var iter = obj.iterator();
            while (iter.next()) |entry| {
                if (!first) try buffer.appendSlice(allocator, ",");
                first = false;
                try buffer.appendSlice(allocator, "\"");
                try buffer.appendSlice(allocator, entry.key_ptr.*);
                try buffer.appendSlice(allocator, "\":");
                try serializeValue(allocator, buffer, entry.value_ptr.*);
            }
            try buffer.appendSlice(allocator, "}");
        },
        .number_string => |s| try buffer.appendSlice(allocator, s),
    }
}

/// Creates a request message.
pub fn createRequest(id: types.RequestId, method: []const u8, params: ?std.json.Value) Request {
    return Request{
        .id = id,
        .method = method,
        .params = params,
    };
}

/// Creates a notification message.
pub fn createNotification(method: []const u8, params: ?std.json.Value) Notification {
    return Notification{
        .method = method,
        .params = params,
    };
}

/// Creates a success response.
pub fn createResponse(id: types.RequestId, result: ?std.json.Value) Response {
    return Response{
        .id = id,
        .result = result,
    };
}

/// Creates an error response.
pub fn createErrorResponse(id: ?types.RequestId, code: i32, message: []const u8, data: ?std.json.Value) ErrorResponse {
    return ErrorResponse{
        .id = id,
        .@"error" = .{
            .code = code,
            .message = message,
            .data = data,
        },
    };
}

/// Creates a parse error response (-32700).
pub fn createParseError(data: ?std.json.Value) ErrorResponse {
    return createErrorResponse(null, ErrorCode.PARSE_ERROR, "Parse error", data);
}

/// Creates an invalid request error response (-32600).
pub fn createInvalidRequest(id: ?types.RequestId, data: ?std.json.Value) ErrorResponse {
    return createErrorResponse(id, ErrorCode.INVALID_REQUEST, "Invalid request", data);
}

/// Creates a method not found error response (-32601).
pub fn createMethodNotFound(id: types.RequestId, method: []const u8) ErrorResponse {
    _ = method;
    return createErrorResponse(id, ErrorCode.METHOD_NOT_FOUND, "Method not found", null);
}

/// Creates an invalid params error response (-32602).
pub fn createInvalidParams(id: types.RequestId, message: []const u8) ErrorResponse {
    return createErrorResponse(id, ErrorCode.INVALID_PARAMS, message, null);
}

/// Creates an internal error response (-32603).
pub fn createInternalError(id: types.RequestId, data: ?std.json.Value) ErrorResponse {
    return createErrorResponse(id, ErrorCode.INTERNAL_ERROR, "Internal error", data);
}

test "parse request" {
    const allocator = std.testing.allocator;
    const json = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"test\"}";

    const result = try parseMessage(allocator, json);
    defer result.deinit();
    try std.testing.expect(result.message == .request);
    try std.testing.expectEqualStrings("test", result.message.request.method);
}

test "parse notification" {
    const allocator = std.testing.allocator;
    const json = "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}";

    const result = try parseMessage(allocator, json);
    defer result.deinit();
    try std.testing.expect(result.message == .notification);
    try std.testing.expectEqualStrings("notifications/initialized", result.message.notification.method);
}

test "serialize request" {
    const allocator = std.testing.allocator;
    const req = createRequest(.{ .integer = 42 }, "test/method", null);

    const json = try serializeMessage(allocator, .{ .request = req });
    defer allocator.free(json);

    try std.testing.expect(std.mem.indexOf(u8, json, "\"jsonrpc\":\"2.0\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"id\":42") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"method\":\"test/method\"") != null);
}

test "error codes" {
    try std.testing.expectEqual(@as(i32, -32700), ErrorCode.PARSE_ERROR);
    try std.testing.expectEqual(@as(i32, -32600), ErrorCode.INVALID_REQUEST);
}
