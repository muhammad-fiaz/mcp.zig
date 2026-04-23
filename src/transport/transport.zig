//! MCP Transport Layer
//!
//! Provides transport mechanisms for MCP client-server communication.
//! Supports STDIO transport for local process communication and HTTP
//! transport for remote server connections.

const std = @import("std");

const jsonrpc = @import("../protocol/jsonrpc.zig");
const types = @import("../protocol/types.zig");

/// Generic transport interface for MCP communication.
/// Implementations must provide send, receive, and close operations.
pub const Transport = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        send: *const fn (ptr: *anyopaque, io: std.Io, allocator: std.mem.Allocator, message: []const u8) SendError!void,
        receive: *const fn (ptr: *anyopaque, io: std.Io, allocator: std.mem.Allocator) ReceiveError!?[]const u8,
        close: *const fn (ptr: *anyopaque) void,
    };

    pub const SendError = error{
        ConnectionClosed,
        WriteError,
        OutOfMemory,
    };

    pub const ReceiveError = error{
        ConnectionClosed,
        ReadError,
        MessageTooLarge,
        OutOfMemory,
        EndOfStream,
    };

    /// Sends a message through the transport.
    pub fn send(self: Transport, io: std.Io, allocator: std.mem.Allocator, message: []const u8) SendError!void {
        return self.vtable.send(self.ptr, io, allocator, message);
    }

    /// Receives a message from the transport (blocking).
    pub fn receive(self: Transport, io: std.Io, allocator: std.mem.Allocator) ReceiveError!?[]const u8 {
        return self.vtable.receive(self.ptr, io, allocator);
    }

    /// Closes the transport connection.
    pub fn close(self: Transport) void {
        self.vtable.close(self.ptr);
    }
};

/// STDIO transport for local process communication.
/// Messages are delimited by newlines and sent via stdin/stdout.
pub const StdioTransport = struct {
    read_buffer: std.ArrayList(u8) = .empty,
    is_closed: bool = false,
    max_message_size: usize = 4 * 1024 * 1024,

    const Self = @This();

    /// Releases resources held by the transport.
    pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
        self.read_buffer.deinit(allocator);
    }

    /// Sends a JSON-RPC message to stdout with newline delimiter.
    pub fn send(self: *Self, io: std.Io, _: std.mem.Allocator, message: []const u8) Transport.SendError!void {
        if (self.is_closed) return Transport.SendError.ConnectionClosed;

        const stdout = std.Io.File.stdout();
        stdout.writeStreamingAll(io, message) catch return Transport.SendError.WriteError;
        stdout.writeStreamingAll(io, "\n") catch return Transport.SendError.WriteError;
    }

    /// Sends a JSON-RPC message object.
    pub fn sendMessage(self: *Self, io: std.Io, allocator: std.mem.Allocator, message: jsonrpc.Message) !void {
        const json = try jsonrpc.serializeMessage(allocator, message);
        defer allocator.free(json);
        try self.send(io, allocator, json);
    }

    /// Receives a JSON-RPC message from stdin (reads until newline).
    pub fn receive(self: *Self, io: std.Io, allocator: std.mem.Allocator) Transport.ReceiveError!?[]const u8 {
        if (self.is_closed) return Transport.ReceiveError.ConnectionClosed;

        self.read_buffer.clearRetainingCapacity();

        const stdin = std.Io.File.stdin();

        while (true) {
            var buf: [1]u8 = undefined;
            const bytes_read = stdin.readStreaming(io, &.{&buf}) catch return Transport.ReceiveError.ReadError;

            if (bytes_read == 0) {
                if (self.read_buffer.items.len == 0) {
                    return Transport.ReceiveError.EndOfStream;
                }
                break;
            }

            const byte = buf[0];
            if (byte == '\n') {
                break;
            }

            if (self.read_buffer.items.len >= self.max_message_size) {
                return Transport.ReceiveError.MessageTooLarge;
            }

            self.read_buffer.append(allocator, byte) catch return Transport.ReceiveError.OutOfMemory;
        }

        if (self.read_buffer.items.len == 0) {
            return null;
        }

        const result = allocator.dupe(u8, self.read_buffer.items) catch {
            return Transport.ReceiveError.OutOfMemory;
        };
        return result;
    }

    /// Closes the transport.
    pub fn close(self: *Self) void {
        self.is_closed = true;
    }

    /// Writes a message to stderr for logging.
    pub fn writeStderr(_: *Self, io: std.Io, message: []const u8) void {
        const stderr = std.Io.File.stderr();
        stderr.writeStreamingAll(io, message) catch {};
        stderr.writeStreamingAll(io, "\n") catch {};
    }

    /// Returns a Transport interface for this STDIO transport.
    pub fn transport(self: *Self) Transport {
        return .{
            .ptr = self,
            .vtable = &.{
                .send = sendVtable,
                .receive = receiveVtable,
                .close = closeVtable,
            },
        };
    }

    fn sendVtable(ptr: *anyopaque, io: std.Io, allocator: std.mem.Allocator, message: []const u8) Transport.SendError!void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        return self.send(io, allocator, message);
    }

    fn receiveVtable(ptr: *anyopaque, io: std.Io, allocator: std.mem.Allocator) Transport.ReceiveError!?[]const u8 {
        const self: *Self = @ptrCast(@alignCast(ptr));
        return self.receive(io, allocator);
    }

    fn closeVtable(ptr: *anyopaque) void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        self.close();
    }
};

/// HTTP transport for remote server communication.
/// Sends requests via HTTP POST and receives responses.
pub const HttpTransport = struct {
    endpoint: []const u8,
    session_id: ?[]const u8 = null,
    authorization_token: ?[]const u8 = null,
    protocol_version: []const u8 = "2025-11-25",
    is_closed: bool = false,
    pending_responses: std.ArrayList([]const u8) = .empty,

    const Self = @This();

    /// Initializes a new HTTP transport with the given endpoint URL.
    pub fn init(allocator: std.mem.Allocator, endpoint: []const u8) !Self {
        const owned_endpoint = try allocator.dupe(u8, endpoint);
        return .{
            .endpoint = owned_endpoint,
        };
    }

    /// Releases resources held by the transport.
    pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
        allocator.free(self.endpoint);
        for (self.pending_responses.items) |item| {
            allocator.free(item);
        }
        self.pending_responses.deinit(allocator);
        if (self.session_id) |sid| {
            allocator.free(sid);
        }
        if (self.authorization_token) |token| {
            allocator.free(token);
        }
    }

    /// Sends a JSON-RPC message via HTTP POST.
    pub fn send(self: *Self, _: std.Io, allocator: std.mem.Allocator, message: []const u8) Transport.SendError!void {
        if (self.is_closed) return Transport.SendError.ConnectionClosed;

        var client: std.http.Client = .{ .allocator = allocator };
        defer client.deinit();

        const uri = std.Uri.parse(self.endpoint) catch return Transport.SendError.WriteError;

        var extra_headers: std.ArrayList(std.http.Header) = .empty;
        defer extra_headers.deinit(allocator);

        extra_headers.append(allocator, .{ .name = "Content-Type", .value = "application/json" }) catch {
            return Transport.SendError.OutOfMemory;
        };
        extra_headers.append(allocator, .{ .name = "Accept", .value = "application/json" }) catch {
            return Transport.SendError.OutOfMemory;
        };
        extra_headers.append(allocator, .{ .name = "MCP-Protocol-Version", .value = self.protocol_version }) catch {
            return Transport.SendError.OutOfMemory;
        };

        var authorization_value: ?[]u8 = null;
        defer if (authorization_value) |owned| allocator.free(owned);

        if (self.authorization_token) |token| {
            authorization_value = std.fmt.allocPrint(allocator, "Bearer {s}", .{token}) catch {
                return Transport.SendError.OutOfMemory;
            };
            extra_headers.append(allocator, .{ .name = "Authorization", .value = authorization_value.? }) catch {
                return Transport.SendError.OutOfMemory;
            };
        }

        if (self.session_id) |sid| {
            extra_headers.append(allocator, .{ .name = "MCP-Session-Id", .value = sid }) catch {
                return Transport.SendError.OutOfMemory;
            };
        }

        var req = client.request(.POST, uri, .{
            .headers = .{ .user_agent = .{ .override = "mcp.zig" } },
            .extra_headers = extra_headers.items,
        }) catch return Transport.SendError.WriteError;
        defer req.deinit();

        req.transfer_encoding = .{ .content_length = message.len };

        var body_writer = req.sendBodyUnflushed(&.{}) catch return Transport.SendError.WriteError;
        body_writer.writer.writeAll(message) catch return Transport.SendError.WriteError;
        body_writer.end() catch return Transport.SendError.WriteError;
        req.connection.?.flush() catch return Transport.SendError.WriteError;

        const redirect_buffer = allocator.alloc(u8, 8 * 1024) catch return Transport.SendError.OutOfMemory;
        defer allocator.free(redirect_buffer);

        var response = req.receiveHead(redirect_buffer) catch return Transport.SendError.WriteError;

        var header_it = response.head.iterateHeaders();
        while (header_it.next()) |header| {
            if (std.ascii.eqlIgnoreCase(header.name, "mcp-session-id")) {
                self.setSessionId(allocator, header.value) catch return Transport.SendError.OutOfMemory;
            }
        }

        var transfer_buffer: [1024]u8 = undefined;
        var reader = response.reader(&transfer_buffer);

        var body: std.ArrayList(u8) = .empty;
        defer body.deinit(allocator);

        var buf: [4096]u8 = undefined;
        while (true) {
            const n = reader.readSliceShort(&buf) catch return Transport.SendError.WriteError;
            if (n == 0) break;
            body.appendSlice(allocator, buf[0..n]) catch return Transport.SendError.OutOfMemory;
        }

        if (body.items.len == 0) return;

        const owned = allocator.dupe(u8, body.items) catch return Transport.SendError.OutOfMemory;
        self.pending_responses.append(allocator, owned) catch {
            allocator.free(owned);
            return Transport.SendError.OutOfMemory;
        };
    }

    /// Receives a response from the pending queue.
    pub fn receive(self: *Self, _: std.Io, _: std.mem.Allocator) Transport.ReceiveError!?[]const u8 {
        if (self.is_closed) return Transport.ReceiveError.ConnectionClosed;

        if (self.pending_responses.items.len > 0) {
            return self.pending_responses.orderedRemove(0);
        }
        return null;
    }

    /// Closes the transport.
    pub fn close(self: *Self) void {
        self.is_closed = true;
    }

    /// Sets the session ID from the MCP-Session-Id header.
    pub fn setSessionId(self: *Self, allocator: std.mem.Allocator, session_id: []const u8) !void {
        if (self.session_id) |old| {
            allocator.free(old);
        }
        self.session_id = try allocator.dupe(u8, session_id);
    }

    /// Sets the authorization token for Bearer auth (OAuth 2.1).
    pub fn setAuthorizationToken(self: *Self, allocator: std.mem.Allocator, token: []const u8) !void {
        if (self.authorization_token) |old| {
            allocator.free(old);
        }
        self.authorization_token = try allocator.dupe(u8, token);
    }

    /// Returns a Transport interface for this HTTP transport.
    pub fn transport(self: *Self) Transport {
        return .{
            .ptr = self,
            .vtable = &.{
                .send = sendVtable,
                .receive = receiveVtable,
                .close = closeVtable,
            },
        };
    }

    fn sendVtable(ptr: *anyopaque, io: std.Io, allocator: std.mem.Allocator, message: []const u8) Transport.SendError!void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        return self.send(io, allocator, message);
    }

    fn receiveVtable(ptr: *anyopaque, io: std.Io, allocator: std.mem.Allocator) Transport.ReceiveError!?[]const u8 {
        const self: *Self = @ptrCast(@alignCast(ptr));
        return self.receive(io, allocator);
    }

    fn closeVtable(ptr: *anyopaque) void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        self.close();
    }
};

/// Transport type selection.
pub const TransportType = enum {
    stdio,
    http,
};

/// Creates a transport based on the specified type.
pub fn createTransport(
    io: std.Io,
    allocator: std.mem.Allocator,
    transport_type: TransportType,
    options: TransportOptions,
) !Transport {
    _ = io;
    switch (transport_type) {
        .stdio => {
            const stdio = try allocator.create(StdioTransport);
            stdio.* = .{};
            return stdio.transport();
        },
        .http => {
            const url = options.url orelse return error.MissingUrl;
            const http_transport = try allocator.create(HttpTransport);
            http_transport.* = try .init(allocator, url);
            if (options.authorization_token) |token| {
                try http_transport.setAuthorizationToken(allocator, token);
            }
            return http_transport.transport();
        },
    }
}

/// Options for transport creation.
pub const TransportOptions = struct {
    url: ?[]const u8 = null,
    authorization_token: ?[]const u8 = null,
};

test "StdioTransport initialization" {
    var transport_impl: StdioTransport = .{};
    _ = &transport_impl;

    try std.testing.expect(!transport_impl.is_closed);
}

test "HttpTransport initialization" {
    const allocator = std.testing.allocator;
    var transport_impl = try HttpTransport.init(allocator, "http://localhost:3000");
    defer transport_impl.deinit(allocator);

    try std.testing.expectEqualStrings("http://localhost:3000", transport_impl.endpoint);
}

test "HttpTransport session ID" {
    const allocator = std.testing.allocator;
    var transport_impl = try HttpTransport.init(allocator, "http://localhost:3000");
    defer transport_impl.deinit(allocator);

    try transport_impl.setSessionId(allocator, "test-session-123");
    try std.testing.expectEqualStrings("test-session-123", transport_impl.session_id.?);
}
