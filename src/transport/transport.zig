//! MCP Transport Layer
//!
//! Provides transport mechanisms for MCP client-server communication.
//! Supports STDIO transport for local process communication and HTTP
//! transport (via httpx.zig) for remote server connections.

const std = @import("std");

const jsonrpc = @import("../protocol/jsonrpc.zig");
const types = @import("../protocol/types.zig");
const httpx = @import("httpx");

/// Generic transport interface for MCP communication.
/// Implementations must provide send, receive, and close operations.
pub const Transport = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        send: *const fn (ptr: *anyopaque, io: std.Io, allocator: std.mem.Allocator, message: []const u8) SendError!void,
        receive: *const fn (ptr: *anyopaque, io: std.Io, allocator: std.mem.Allocator) ReceiveError!?[]const u8,
        close: *const fn (ptr: *anyopaque) void,
        destroy: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator) void,
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

    /// Destroys the transport, releasing all resources including the transport object itself.
    pub fn destroy(self: Transport, allocator: std.mem.Allocator) void {
        self.vtable.destroy(self.ptr, allocator);
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
                .destroy = destroyVtable,
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

    fn destroyVtable(ptr: *anyopaque, allocator: std.mem.Allocator) void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        self.deinit(allocator);
        allocator.destroy(self);
    }
};

/// HTTP transport for remote server communication using httpx.zig.
/// Sends requests via HTTP POST and receives JSON or SSE responses.
/// Stateless per-request model (MCP 2026-07-28).
pub const HttpTransport = struct {
    endpoint: []const u8,
    authorization_token: ?[]const u8 = null,
    protocol_version: []const u8 = "2026-07-28",
    client_info: ?struct { name: []const u8, version: []const u8 } = null,
    client_capabilities: ?types.ClientCapabilities = null,
    is_closed: bool = false,
    pending_responses: std.ArrayList([]const u8) = .empty,

    const Self = @This();

    /// Initializes a new HTTP transport with the given endpoint URL.
    pub fn init(allocator: std.mem.Allocator, endpoint: []const u8) !Self {
        const owned_endpoint = try allocator.dupe(u8, endpoint);
        return .{
            .endpoint = owned_endpoint,
            .pending_responses = .empty,
        };
    }

    /// Releases resources held by the transport.
    pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
        allocator.free(self.endpoint);
        for (self.pending_responses.items) |item| {
            allocator.free(item);
        }
        self.pending_responses.deinit(allocator);
        if (self.authorization_token) |token| {
            allocator.free(token);
        }
    }

    /// Sends a JSON-RPC message via HTTP POST using httpx.zig client.
    pub fn send(self: *Self, _: std.Io, allocator: std.mem.Allocator, message: []const u8) Transport.SendError!void {
        if (self.is_closed) return Transport.SendError.ConnectionClosed;

        var client = httpx.createClientWithConfig(allocator, .{
            .base_url = self.endpoint,
            .verify_ssl = true,
        });
        defer client.deinit();

        // Build headers
        var headers: std.ArrayList([2][]const u8) = .empty;
        defer headers.deinit(allocator);

        try headers.append(allocator, .{ "Content-Type", "application/json" });
        try headers.append(allocator, .{ "Accept", "application/json, text/event-stream" });
        try headers.append(allocator, .{ "MCP-Protocol-Version", self.protocol_version });

        if (self.authorization_token) |token| {
            const bearer = try std.fmt.allocPrint(allocator, "Bearer {s}", .{token});
            defer allocator.free(bearer);
            try headers.append(allocator, .{ "Authorization", bearer });
        }

        // Per-request metadata with namespaced keys (2026-07-28)
        if (self.client_info) |ci| {
            const client_info_json = try std.fmt.allocPrint(allocator, "{{\"name\":\"{s}\",\"version\":\"{s}\"}}", .{ ci.name, ci.version });
            defer allocator.free(client_info_json);
            try headers.append(allocator, .{ "io.modelcontextprotocol/clientInfo", client_info_json });
        }

        const response = client.post(self.endpoint, .{
            .body = message,
            .headers = headers.items,
        }) catch return Transport.SendError.WriteError;
        defer response.deinit();

        // Handle errors
        if (response.status.code >= 400) {
            return Transport.SendError.WriteError;
        }

        const body_text = response.text() orelse return;

        // Check for SSE content type
        if (response.contentType()) |ctype| {
            if (std.mem.indexOf(u8, ctype, "text/event-stream") != null) {
                self.enqueueSseEvents(allocator, body_text) catch return Transport.SendError.OutOfMemory;
                return;
            }
        }

        // Direct JSON response
        const owned = allocator.dupe(u8, body_text) catch return Transport.SendError.OutOfMemory;
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

    /// Sets the authorization token for Bearer auth (OAuth 2.1).
    pub fn setAuthorizationToken(self: *Self, allocator: std.mem.Allocator, token: []const u8) !void {
        if (self.authorization_token) |old| {
            allocator.free(old);
        }
        self.authorization_token = try allocator.dupe(u8, token);
    }

    /// Sets client info for per-request metadata.
    pub fn setClientInfo(self: *Self, allocator: std.mem.Allocator, name: []const u8, version: []const u8) !void {
        self.client_info = .{
            .name = try allocator.dupe(u8, name),
            .version = try allocator.dupe(u8, version),
        };
    }

    fn enqueueSseEvents(self: *Self, allocator: std.mem.Allocator, body: []const u8) !void {
        var current: std.ArrayList(u8) = .empty;
        defer current.deinit(allocator);

        var it = std.mem.splitScalar(u8, body, '\n');
        while (it.next()) |line| {
            if (line.len == 0) {
                if (current.items.len > 0) {
                    const owned = try allocator.dupe(u8, current.items);
                    try self.pending_responses.append(allocator, owned);
                    current.clearRetainingCapacity();
                }
                continue;
            }

            if (std.mem.startsWith(u8, line, "data:")) {
                var data_line = line[5..];
                if (data_line.len > 0 and data_line[0] == ' ') data_line = data_line[1..];
                if (current.items.len > 0) {
                    try current.append(allocator, '\n');
                }
                try current.appendSlice(allocator, data_line);
            }
        }

        if (current.items.len > 0) {
            const owned = try allocator.dupe(u8, current.items);
            try self.pending_responses.append(allocator, owned);
        }
    }

    /// Returns a Transport interface for this HTTP transport.
    pub fn transport(self: *Self) Transport {
        return .{
            .ptr = self,
            .vtable = &.{
                .send = sendVtable,
                .receive = receiveVtable,
                .close = closeVtable,
                .destroy = destroyVtable,
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

    fn destroyVtable(ptr: *anyopaque, allocator: std.mem.Allocator) void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        self.deinit(allocator);
        allocator.destroy(self);
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
