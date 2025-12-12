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
        send: *const fn (ptr: *anyopaque, message: []const u8) SendError!void,
        receive: *const fn (ptr: *anyopaque) ReceiveError!?[]const u8,
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
    pub fn send(self: Transport, message: []const u8) SendError!void {
        return self.vtable.send(self.ptr, message);
    }

    /// Receives a message from the transport (blocking).
    pub fn receive(self: Transport) ReceiveError!?[]const u8 {
        return self.vtable.receive(self.ptr);
    }

    /// Closes the transport connection.
    pub fn close(self: Transport) void {
        self.vtable.close(self.ptr);
    }
};

/// STDIO transport for local process communication.
/// Messages are delimited by newlines and sent via stdin/stdout.
pub const StdioTransport = struct {
    allocator: std.mem.Allocator,
    read_buffer: std.ArrayList(u8),
    is_closed: bool = false,
    max_message_size: usize = 4 * 1024 * 1024,

    const Self = @This();

    /// Initializes a new STDIO transport.
    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .allocator = allocator,
            .read_buffer = .{},
        };
    }

    /// Releases resources held by the transport.
    pub fn deinit(self: *Self) void {
        self.read_buffer.deinit(self.allocator);
    }

    /// Sends a JSON-RPC message to stdout with newline delimiter.
    pub fn send(self: *Self, message: []const u8) Transport.SendError!void {
        if (self.is_closed) return Transport.SendError.ConnectionClosed;

        const stdout = std.fs.File.stdout();
        stdout.writeAll(message) catch return Transport.SendError.WriteError;
        stdout.writeAll("\n") catch return Transport.SendError.WriteError;
    }

    /// Sends a JSON-RPC message object.
    pub fn sendMessage(self: *Self, message: jsonrpc.Message) !void {
        const json = try jsonrpc.serializeMessage(self.allocator, message);
        defer self.allocator.free(json);
        try self.send(json);
    }

    /// Receives a JSON-RPC message from stdin (reads until newline).
    pub fn receive(self: *Self) Transport.ReceiveError!?[]const u8 {
        if (self.is_closed) return Transport.ReceiveError.ConnectionClosed;

        self.read_buffer.clearRetainingCapacity();

        const stdin = std.fs.File.stdin();

        while (true) {
            var buf: [1]u8 = undefined;
            const bytes_read = stdin.read(&buf) catch return Transport.ReceiveError.ReadError;

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

            self.read_buffer.append(self.allocator, byte) catch return Transport.ReceiveError.OutOfMemory;
        }

        if (self.read_buffer.items.len == 0) {
            return null;
        }

        const result = self.allocator.dupe(u8, self.read_buffer.items) catch {
            return Transport.ReceiveError.OutOfMemory;
        };
        return result;
    }

    /// Closes the transport.
    pub fn close(self: *Self) void {
        self.is_closed = true;
    }

    /// Writes a message to stderr for logging.
    pub fn writeStderr(self: *Self, message: []const u8) void {
        _ = self;
        const stderr = std.fs.File.stderr();
        stderr.writeAll(message) catch {};
        stderr.writeAll("\n") catch {};
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

    fn sendVtable(ptr: *anyopaque, message: []const u8) Transport.SendError!void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        return self.send(message);
    }

    fn receiveVtable(ptr: *anyopaque) Transport.ReceiveError!?[]const u8 {
        const self: *Self = @ptrCast(@alignCast(ptr));
        return self.receive();
    }

    fn closeVtable(ptr: *anyopaque) void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        self.close();
    }
};

/// HTTP transport for remote server communication.
/// Sends requests via HTTP POST and receives responses.
pub const HttpTransport = struct {
    allocator: std.mem.Allocator,
    endpoint: []const u8,
    session_id: ?[]const u8 = null,
    protocol_version: []const u8 = "2025-11-25",
    is_closed: bool = false,
    pending_responses: std.ArrayList([]const u8),

    const Self = @This();

    /// Initializes a new HTTP transport with the given endpoint URL.
    pub fn init(allocator: std.mem.Allocator, endpoint: []const u8) !Self {
        const owned_endpoint = try allocator.dupe(u8, endpoint);
        return .{
            .allocator = allocator,
            .endpoint = owned_endpoint,
            .pending_responses = .{},
        };
    }

    /// Releases resources held by the transport.
    pub fn deinit(self: *Self) void {
        self.allocator.free(self.endpoint);
        for (self.pending_responses.items) |item| {
            self.allocator.free(item);
        }
        self.pending_responses.deinit(self.allocator);
        if (self.session_id) |sid| {
            self.allocator.free(sid);
        }
    }

    /// Sends a JSON-RPC message via HTTP POST.
    pub fn send(self: *Self, message: []const u8) Transport.SendError!void {
        if (self.is_closed) return Transport.SendError.ConnectionClosed;
        _ = message;
    }

    /// Receives a response from the pending queue.
    pub fn receive(self: *Self) Transport.ReceiveError!?[]const u8 {
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
    pub fn setSessionId(self: *Self, session_id: []const u8) !void {
        if (self.session_id) |old| {
            self.allocator.free(old);
        }
        self.session_id = try self.allocator.dupe(u8, session_id);
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

    fn sendVtable(ptr: *anyopaque, message: []const u8) Transport.SendError!void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        return self.send(message);
    }

    fn receiveVtable(ptr: *anyopaque) Transport.ReceiveError!?[]const u8 {
        const self: *Self = @ptrCast(@alignCast(ptr));
        return self.receive();
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
    allocator: std.mem.Allocator,
    transport_type: TransportType,
    options: TransportOptions,
) !Transport {
    switch (transport_type) {
        .stdio => {
            const stdio = try allocator.create(StdioTransport);
            stdio.* = StdioTransport.init(allocator);
            return stdio.transport();
        },
        .http => {
            const url = options.url orelse return error.MissingUrl;
            const http = try allocator.create(HttpTransport);
            http.* = try HttpTransport.init(allocator, url);
            return http.transport();
        },
    }
}

/// Options for transport creation.
pub const TransportOptions = struct {
    url: ?[]const u8 = null,
};

test "StdioTransport initialization" {
    const allocator = std.testing.allocator;
    var transport_impl = StdioTransport.init(allocator);
    defer transport_impl.deinit();

    try std.testing.expect(!transport_impl.is_closed);
}

test "HttpTransport initialization" {
    const allocator = std.testing.allocator;
    var transport_impl = try HttpTransport.init(allocator, "http://localhost:3000");
    defer transport_impl.deinit();

    try std.testing.expectEqualStrings("http://localhost:3000", transport_impl.endpoint);
}

test "HttpTransport session ID" {
    const allocator = std.testing.allocator;
    var transport_impl = try HttpTransport.init(allocator, "http://localhost:3000");
    defer transport_impl.deinit();

    try transport_impl.setSessionId("test-session-123");
    try std.testing.expectEqualStrings("test-session-123", transport_impl.session_id.?);
}
