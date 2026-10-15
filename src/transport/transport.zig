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
            const bytes_read = stdin.readStreaming(io, &.{&buf}) catch |err| {
                if (err == error.EndOfStream) {
                    // Real EOF: process a trailing line without newline,
                    // otherwise report end of stream.
                    if (self.read_buffer.items.len == 0) {
                        return Transport.ReceiveError.EndOfStream;
                    }
                    break;
                }
                return Transport.ReceiveError.ReadError;
            };

            if (bytes_read == 0) {
                // May be spurious (can return fewer bytes than requested,
                // including 0); retry rather than truncating the line.
                continue;
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

/// Params field mirrored into the `Mcp-Name` header, per method.
fn nameFieldForMethod(method: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, method, "tools/call")) return "name";
    if (std.mem.eql(u8, method, "prompts/get")) return "name";
    if (std.mem.eql(u8, method, "resources/read")) return "uri";
    return null;
}

/// Extracts the value the server will compare `Mcp-Name` against.
fn methodIdentity(method: []const u8, params: ?std.json.Value) ?[]const u8 {
    const field = nameFieldForMethod(method) orelse return null;
    const p = params orelse return null;
    if (p != .object) return null;
    const v = p.object.get(field) orelse return null;
    return if (v == .string) v.string else null;
}

/// True when `value` can be placed in an HTTP header verbatim: printable
/// US-ASCII only, so no control characters or multi-byte sequences.
fn isHeaderSafe(value: []const u8) bool {
    // An empty header value conveys nothing and is not a valid one.
    if (value.len == 0) return false;
    for (value) |ch| {
        if (ch < 0x20 or ch > 0x7e) return false;
    }
    return true;
}

/// Base64-encodes `value` into a freshly allocated buffer.
///
/// `std.base64.Encoder` exposes `encode`/`calcSize` rather than an allocating
/// convenience, so the buffer is sized and filled here.
pub fn base64Alloc(allocator: std.mem.Allocator, value: []const u8) ![]u8 {
    const encoder = std.base64.standard.Encoder;
    const buf = try allocator.alloc(u8, encoder.calcSize(value.len));
    _ = encoder.encode(buf, value);
    return buf;
}

/// Encodes a header value, falling back to the spec's base64 sentinel
/// (`=?base64?<base64>?=`) when the raw value is not header-safe.
fn encodeHeaderValue(allocator: std.mem.Allocator, value: []const u8) ![]u8 {
    if (isHeaderSafe(value)) return allocator.dupe(u8, value);

    const b64 = try base64Alloc(allocator, value);
    defer allocator.free(b64);
    return std.fmt.allocPrint(allocator, "=?base64?{s}?=", .{b64});
}

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
        if (self.client_info) |ci| {
            allocator.free(ci.name);
            allocator.free(ci.version);
        }
    }

    /// Sends a JSON-RPC message via HTTP POST using httpx.zig client.
    pub fn send(self: *Self, io: std.Io, allocator: std.mem.Allocator, message: []const u8) Transport.SendError!void {
        if (self.is_closed) return Transport.SendError.ConnectionClosed;

        var client = httpx.Client.init(allocator, io, .{});
        defer client.deinit();

        // Build headers
        var headers: std.ArrayList(httpx.Header) = .empty;
        defer headers.deinit(allocator);

        try headers.append(allocator, .{ .name = "Content-Type", .value = "application/json" });
        try headers.append(allocator, .{ .name = "Accept", .value = "application/json, text/event-stream" });
        try headers.append(allocator, .{ .name = "MCP-Protocol-Version", .value = self.protocol_version });

        // Mirror the body fields the spec requires servers to validate.
        // `Mcp-Method` is always required; `Mcp-Name` is required for the
        // methods whose identity lives in `params.name` / `params.uri`.
        {
            var arena = std.heap.ArenaAllocator.init(allocator);
            defer arena.deinit();

            if (jsonrpc.parseMessage(arena.allocator(), message)) |parsed| {
                switch (parsed.message) {
                    .request => |req| {
                        const method_hdr = try encodeHeaderValue(allocator, req.method);
                        defer allocator.free(method_hdr);
                        try headers.append(allocator, .{ .name = "Mcp-Method", .value = method_hdr });

                        if (methodIdentity(req.method, req.params)) |ident| {
                            const name_hdr = try encodeHeaderValue(allocator, ident);
                            defer allocator.free(name_hdr);
                            try headers.append(allocator, .{ .name = "Mcp-Name", .value = name_hdr });
                        }
                    },
                    .notification, .response, .error_response => {},
                }
            } else |_| {
                // Unparseable messages are forwarded as-is; the server reports
                // the -32700 rather than the transport silently dropping them.
            }
        }

        var bearer_buf: ?[]u8 = null;
        defer if (bearer_buf) |b| allocator.free(b);

        if (self.authorization_token) |token| {
            bearer_buf = try std.fmt.allocPrint(allocator, "Bearer {s}", .{token});
            try headers.append(allocator, .{ .name = "Authorization", .value = bearer_buf.? });
        }

        // Per-request metadata with namespaced keys (2026-07-28)
        var client_info_buf: ?[]u8 = null;
        defer if (client_info_buf) |b| allocator.free(b);

        if (self.client_info) |ci| {
            // Serialised with std.json so names containing quotes, backslashes
            // or control characters cannot corrupt the header or the JSON.
            const ClientInfo = struct { name: []const u8, version: []const u8 };
            var aw: std.Io.Writer.Allocating = .init(allocator);
            defer aw.deinit();
            try std.json.Stringify.value(
                ClientInfo{ .name = ci.name, .version = ci.version },
                .{},
                &aw.writer,
            );
            client_info_buf = try allocator.dupe(u8, aw.written());
            try headers.append(allocator, .{ .name = "io.modelcontextprotocol/clientInfo", .value = client_info_buf.? });
        }

        var response = client.post(self.endpoint, .{
            .body = message,
            .headers = headers.items,
        }) catch return Transport.SendError.WriteError;
        defer response.deinit();

        // Handle errors
        if (response.status >= 400) {
            return Transport.SendError.WriteError;
        }

        const body_text: []const u8 = response.text();
        if (body_text.len == 0) return;

        // Check for SSE content type
        const ctype = response.contentType();
        if (std.mem.indexOf(u8, ctype, "text/event-stream") != null) {
            self.enqueueSseEvents(allocator, body_text) catch return Transport.SendError.OutOfMemory;
            return;
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
        if (self.client_info) |old| {
            allocator.free(old.name);
            allocator.free(old.version);
        }
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

test "HttpTransport receive empty queue returns null" {
    const allocator = std.testing.allocator;
    var transport_impl = try HttpTransport.init(allocator, "http://localhost:3000");
    defer transport_impl.deinit(allocator);

    const msg = try transport_impl.receive(std.Io.failing, allocator);
    try std.testing.expect(msg == null);
}

test "HttpTransport auth token and client info ownership" {
    const allocator = std.testing.allocator;
    var transport_impl = try HttpTransport.init(allocator, "http://localhost:3000");
    defer transport_impl.deinit(allocator);

    try transport_impl.setAuthorizationToken(allocator, "secret-token");
    try std.testing.expectEqualStrings("secret-token", transport_impl.authorization_token.?);
    try transport_impl.setAuthorizationToken(allocator, "rotated-token");
    try std.testing.expectEqualStrings("rotated-token", transport_impl.authorization_token.?);

    try transport_impl.setClientInfo(allocator, "test-client", "1.0.0");
    try std.testing.expectEqualStrings("test-client", transport_impl.client_info.?.name);
    try std.testing.expectEqualStrings("1.0.0", transport_impl.client_info.?.version);

    try std.testing.expectEqualStrings("2026-07-28", transport_impl.protocol_version);
}

test "HttpTransport SSE data framing enqueues payloads" {
    const allocator = std.testing.allocator;
    var transport_impl = try HttpTransport.init(allocator, "http://localhost:3000");
    defer transport_impl.deinit(allocator);

    try transport_impl.enqueueSseEvents(allocator, "data: {\"a\":1}\n\n");
    try std.testing.expectEqual(@as(usize, 1), transport_impl.pending_responses.items.len);
    try std.testing.expectEqualStrings("{\"a\":1}", transport_impl.pending_responses.items[0]);
}

test "nameFieldForMethod mirrors the spec's Mcp-Name rules" {
    try std.testing.expectEqualStrings("name", nameFieldForMethod("tools/call").?);
    try std.testing.expectEqualStrings("name", nameFieldForMethod("prompts/get").?);
    try std.testing.expectEqualStrings("uri", nameFieldForMethod("resources/read").?);
    try std.testing.expect(nameFieldForMethod("tools/list") == null);
    try std.testing.expect(nameFieldForMethod("server/discover") == null);
}

test "methodIdentity extracts the field the server compares Mcp-Name against" {
    const allocator = std.testing.allocator;

    const tool_args = try std.json.parseFromSlice(std.json.Value, allocator,
        \\{"name":"greet"}
    , .{});
    defer tool_args.deinit();
    try std.testing.expectEqualStrings("greet", methodIdentity("tools/call", tool_args.value).?);

    const read_args = try std.json.parseFromSlice(std.json.Value, allocator,
        \\{"uri":"file:///a.txt"}
    , .{});
    defer read_args.deinit();
    try std.testing.expectEqualStrings("file:///a.txt", methodIdentity("resources/read", read_args.value).?);

    // Methods without an identity field produce no header value.
    try std.testing.expect(methodIdentity("tools/list", read_args.value) == null);
    try std.testing.expect(methodIdentity("tools/call", null) == null);
}

test "isHeaderSafe accepts printable ASCII only" {
    try std.testing.expect(isHeaderSafe("tools/call"));
    try std.testing.expect(isHeaderSafe("file:///project/config.json"));
    try std.testing.expect(!isHeaderSafe("bad\nvalue"));
    try std.testing.expect(!isHeaderSafe("caf\u{00e9}"));
    try std.testing.expect(!isHeaderSafe(""));
}

test "encodeHeaderValue passes safe values through and sentencils the rest" {
    const allocator = std.testing.allocator;

    const safe = try encodeHeaderValue(allocator, "resources/read");
    defer allocator.free(safe);
    try std.testing.expectEqualStrings("resources/read", safe);

    const uri = "file:///caf\u{00e9}/\u{4e16}\u{754c}.txt";
    const encoded = try encodeHeaderValue(allocator, uri);
    defer allocator.free(encoded);

    try std.testing.expect(std.mem.startsWith(u8, encoded, "=?base64?"));
    try std.testing.expect(std.mem.endsWith(u8, encoded, "?="));

    // The server decodes this form, so it must round-trip to the exact bytes.
    const decoded = (try @import("../server/http_rules.zig").decodeSentinel(allocator, encoded)).?;
    defer allocator.free(decoded);
    try std.testing.expectEqualStrings(uri, decoded);
}

test "base64Alloc matches std.base64 encoding" {
    const allocator = std.testing.allocator;
    const input = "mcp.zig";

    const got = try base64Alloc(allocator, input);
    defer allocator.free(got);

    var expected_buf: [64]u8 = undefined;
    const expected = std.base64.standard.Encoder.encode(&expected_buf, input);
    try std.testing.expectEqualStrings(expected, got);
}
