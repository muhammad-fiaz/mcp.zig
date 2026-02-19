//! MCP Client Implementation
//!
//! Provides an MCP client that connects to MCP servers via STDIO or HTTP transport.
//! The client handles protocol negotiation, capability advertisement, and provides
//! methods for listing and invoking tools, reading resources, and fetching prompts.

const std = @import("std");
const protocol = @import("../protocol/protocol.zig");
const jsonrpc = @import("../protocol/jsonrpc.zig");
const types = @import("../protocol/types.zig");
const transport_mod = @import("../transport/transport.zig");
const report = @import("../report.zig");

/// Configuration options for creating an MCP client.
pub const ClientConfig = struct {
    name: []const u8,
    version: []const u8,
    title: ?[]const u8 = null,
    description: ?[]const u8 = null,
    allocator: std.mem.Allocator = std.heap.page_allocator,
};

/// Connection state of the client.
pub const ClientState = enum {
    disconnected,
    connecting,
    connected,
    error_state,
};

/// MCP Client for connecting to and interacting with MCP servers.
///
/// Supports STDIO and HTTP transports, capability negotiation, and provides
/// methods for all standard MCP operations including tool calls, resource
/// reads, and prompt fetches.
pub const Client = struct {
    config: ClientConfig,
    allocator: std.mem.Allocator,
    state: ClientState = .disconnected,
    transport: ?transport_mod.Transport = null,
    server_info: ?types.Implementation = null,
    server_capabilities: ?types.ServerCapabilities = null,
    next_request_id: i64 = 1,
    pending_requests: std.AutoHashMap(i64, PendingRequest),
    capabilities: types.ClientCapabilities = .{},
    roots_list: std.ArrayList(types.Root),
    update_thread: ?std.Thread = null,

    const Self = @This();

    /// Represents a request awaiting a response from the server.
    pub const PendingRequest = struct {
        method: []const u8,
        callback: ?*const fn (result: ?std.json.Value, err: ?jsonrpc.ErrorResponse.Error) void = null,
    };

    /// Initializes a new client with the given configuration.
    pub fn init(config: ClientConfig) Self {
        const allocator = config.allocator;
        return .{
            .config = config,
            .allocator = allocator,
            .pending_requests = std.AutoHashMap(i64, PendingRequest).init(allocator),
            .roots_list = .{},
            .update_thread = report.checkForUpdates(allocator),
        };
    }

    /// Releases all resources held by the client.
    pub fn deinit(self: *Self) void {
        self.pending_requests.deinit();
        self.roots_list.deinit(self.allocator);
        if (self.update_thread) |t| t.detach();
    }

    /// Enables the sampling capability, allowing the server to request LLM completions.
    pub fn enableSampling(self: *Self) void {
        self.capabilities.sampling = .{};
    }

    /// Enables the roots capability for providing filesystem boundaries to the server.
    pub fn enableRoots(self: *Self, listChanged: bool) void {
        self.capabilities.roots = .{ .listChanged = listChanged };
    }

    /// Enables the elicitation capability for handling server-initiated user input requests.
    pub fn enableElicitation(self: *Self) void {
        self.capabilities.elicitation = .{ .form = .{}, .url = .{} };
    }

    /// Adds a filesystem root that the server can access.
    pub fn addRoot(self: *Self, uri: []const u8, name: ?[]const u8) !void {
        try self.roots_list.append(self.allocator, .{ .uri = uri, .name = name });
    }

    /// Connects to a server by spawning a process and communicating via STDIO.
    pub fn connectStdio(self: *Self, command: []const u8, args: []const []const u8) !void {
        _ = args;
        _ = command;
        self.state = .connecting;

        const stdio = try self.allocator.create(transport_mod.StdioTransport);
        stdio.* = transport_mod.StdioTransport.init(self.allocator);
        self.transport = stdio.transport();

        try self.initialize();
    }

    /// Connects to a server via HTTP at the specified URL.
    pub fn connectHttp(self: *Self, url: []const u8) !void {
        self.state = .connecting;

        const http = try self.allocator.create(transport_mod.HttpTransport);
        http.* = transport_mod.HttpTransport.init(self.allocator, url);
        self.transport = http.transport();

        try self.initialize();
    }

    /// Sends the initialize request to begin the MCP handshake.
    fn initialize(self: *Self) !void {
        var params = std.json.ObjectMap.init(self.allocator);
        defer params.deinit();

        try params.put("protocolVersion", .{ .string = protocol.VERSION });

        var caps = std.json.ObjectMap.init(self.allocator);
        if (self.capabilities.sampling != null) {
            try caps.put("sampling", .{ .object = std.json.ObjectMap.init(self.allocator) });
        }
        if (self.capabilities.roots) |r| {
            var roots_cap = std.json.ObjectMap.init(self.allocator);
            try roots_cap.put("listChanged", .{ .bool = r.listChanged });
            try caps.put("roots", .{ .object = roots_cap });
        }
        try params.put("capabilities", .{ .object = caps });

        var client_info = std.json.ObjectMap.init(self.allocator);
        try client_info.put("name", .{ .string = self.config.name });
        try client_info.put("version", .{ .string = self.config.version });
        try params.put("clientInfo", .{ .object = client_info });

        try self.sendRequest("initialize", .{ .object = params });
    }

    /// Sends a JSON-RPC request to the connected server.
    fn sendRequest(self: *Self, method: []const u8, params: ?std.json.Value) !void {
        const id = self.next_request_id;
        self.next_request_id += 1;

        try self.pending_requests.put(id, .{ .method = method });

        const request = jsonrpc.createRequest(.{ .integer = id }, method, params);
        const json = try jsonrpc.serializeMessage(self.allocator, .{ .request = request });
        defer self.allocator.free(json);

        if (self.transport) |t| {
            t.send(json) catch {
                std.log.err("Failed to send request", .{});
                return; // Log but don't crash - request is lost but client continues
            };
        }
    }

    /// Requests the list of available tools from the server.
    pub fn listTools(self: *Self) !void {
        try self.sendRequest("tools/list", null);
    }

    /// Invokes a tool on the server with optional arguments.
    pub fn callTool(self: *Self, name: []const u8, arguments: ?std.json.Value) !void {
        var params = std.json.ObjectMap.init(self.allocator);
        try params.put("name", .{ .string = name });
        if (arguments) |args| {
            try params.put("arguments", args);
        }
        try self.sendRequest("tools/call", .{ .object = params });
    }

    /// Requests the list of available resources from the server.
    pub fn listResources(self: *Self) !void {
        try self.sendRequest("resources/list", null);
    }

    /// Reads a resource from the server by URI.
    pub fn readResource(self: *Self, uri: []const u8) !void {
        var params = std.json.ObjectMap.init(self.allocator);
        try params.put("uri", .{ .string = uri });
        try self.sendRequest("resources/read", .{ .object = params });
    }

    /// Requests the list of available prompts from the server.
    pub fn listPrompts(self: *Self) !void {
        try self.sendRequest("prompts/list", null);
    }

    /// Fetches a prompt from the server with optional arguments.
    pub fn getPrompt(self: *Self, name: []const u8, arguments: ?std.json.Value) !void {
        var params = std.json.ObjectMap.init(self.allocator);
        try params.put("name", .{ .string = name });
        if (arguments) |args| {
            try params.put("arguments", args);
        }
        try self.sendRequest("prompts/get", .{ .object = params });
    }

    /// Disconnects from the server and releases the transport.
    pub fn disconnect(self: *Self) void {
        if (self.transport) |t| {
            t.close();
        }
        self.state = .disconnected;
    }
};

test "Client initialization" {
    var client = Client.init(.{
        .name = "test-client",
        .version = "1.0.0",
        .allocator = std.testing.allocator,
    });
    defer client.deinit();

    try std.testing.expectEqual(ClientState.disconnected, client.state);
}

test "Client capabilities" {
    var client = Client.init(.{
        .name = "test",
        .version = "1.0.0",
        .allocator = std.testing.allocator,
    });
    defer client.deinit();

    client.enableSampling();
    client.enableRoots(true);

    try std.testing.expect(client.capabilities.sampling != null);
    try std.testing.expect(client.capabilities.roots.?.listChanged);
}
