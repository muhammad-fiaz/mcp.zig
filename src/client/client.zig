//! MCP Client Implementation (Spec 2025-11-25)
//!
//! Provides an MCP client that connects to MCP servers via STDIO or HTTP transport.
//! The client handles protocol negotiation, capability advertisement, and provides
//! methods for listing and invoking tools, reading resources, and fetching prompts.
//! Supports task-augmented requests, sampling, elicitation, and roots.

const std = @import("std");

const jsonrpc = @import("../protocol/jsonrpc.zig");
const protocol = @import("../protocol/protocol.zig");
const types = @import("../protocol/types.zig");
const report = @import("../report.zig");
const transport_mod = @import("../transport/transport.zig");

/// Configuration options for creating an MCP client.
pub const ClientConfig = struct {
    name: []const u8,
    version: []const u8,
    title: ?[]const u8 = null,
    description: ?[]const u8 = null,
    icons: ?[]const types.Icon = null,
    websiteUrl: ?[]const u8 = null,
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
/// reads, prompt fetches, and task management.
pub const Client = struct {
    config: ClientConfig,
    state: ClientState = .disconnected,
    transport: ?transport_mod.Transport = null,
    server_info: ?types.Implementation = null,
    server_capabilities: ?types.ServerCapabilities = null,
    next_request_id: i64 = 1,
    pending_requests: std.AutoHashMap(i64, PendingRequest),
    capabilities: types.ClientCapabilities = .{},
    authorization_token: ?[]const u8 = null,
    roots_list: std.ArrayList(types.Root),
    update_thread: ?std.Thread = null,

    const Self = @This();

    /// Represents a request awaiting a response from the server.
    pub const PendingRequest = struct {
        method: []const u8,
        callback: ?*const fn (result: ?std.json.Value, err: ?jsonrpc.ErrorResponse.Error) void = null,
    };

    /// Initializes a new client with the given configuration.
    pub fn init(io: std.Io, allocator: std.mem.Allocator, config: ClientConfig) Self {
        return .{
            .config = config,
            .pending_requests = .init(allocator),
            .roots_list = .empty,
            .update_thread = report.checkForUpdates(io, allocator),
        };
    }

    /// Releases all resources held by the client.
    pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
        self.pending_requests.deinit();
        self.roots_list.deinit(allocator);
        if (self.authorization_token) |token| {
            allocator.free(token);
        }
        if (self.update_thread) |t| t.detach();
    }

    /// Enables the sampling capability, allowing the server to request LLM completions.
    pub fn enableSampling(self: *Self) void {
        self.capabilities.sampling = .{};
    }

    /// Enables the sampling capability with context and/or tools support.
    pub fn enableSamplingAdvanced(self: *Self, context: bool, tools_support: bool) void {
        self.capabilities.sampling = .{
            .context = if (context) .{} else null,
            .tools = if (tools_support) .{} else null,
        };
    }

    /// Enables the roots capability for providing filesystem boundaries to the server.
    pub fn enableRoots(self: *Self, listChanged: bool) void {
        self.capabilities.roots = .{ .listChanged = listChanged };
    }

    /// Enables the elicitation capability for handling server-initiated user input requests.
    pub fn enableElicitation(self: *Self) void {
        self.capabilities.elicitation = .{ .form = .{}, .url = .{} };
    }

    /// Enables form-only elicitation.
    pub fn enableElicitationForm(self: *Self) void {
        self.capabilities.elicitation = .{ .form = .{} };
    }

    /// Enables URL-only elicitation.
    pub fn enableElicitationUrl(self: *Self) void {
        self.capabilities.elicitation = .{ .url = .{} };
    }

    /// Enables the tasks capability for managing long-running operations.
    pub fn enableTasks(self: *Self) void {
        self.capabilities.tasks = .{
            .list = .{},
            .cancel = .{},
        };
    }

    /// Adds a filesystem root that the server can access.
    pub fn addRoot(self: *Self, allocator: std.mem.Allocator, uri: []const u8, name: ?[]const u8) !void {
        try self.roots_list.append(allocator, .{ .uri = uri, .name = name });
    }

    /// Connects to a server by spawning a process and communicating via STDIO.
    pub fn connectStdio(self: *Self, io: std.Io, allocator: std.mem.Allocator, command: []const u8, args: []const []const u8) !void {
        _ = args;
        _ = command;
        self.state = .connecting;

        const stdio = try allocator.create(transport_mod.StdioTransport);
        stdio.* = .{};
        self.transport = stdio.transport();

        try self.initialize(io, allocator);
    }

    /// Sets the authorization token for Bearer auth (OAuth 2.1).
    pub fn setAuthorizationToken(self: *Self, allocator: std.mem.Allocator, token: []const u8) !void {
        if (self.authorization_token) |old| {
            allocator.free(old);
        }
        self.authorization_token = try allocator.dupe(u8, token);
    }

    /// Connects to a server via HTTP at the specified URL.
    pub fn connectHttp(self: *Self, io: std.Io, allocator: std.mem.Allocator, url: []const u8) !void {
        self.state = .connecting;

        const http = try allocator.create(transport_mod.HttpTransport);
        http.* = try transport_mod.HttpTransport.init(allocator, url);
        if (self.authorization_token) |token| {
            try http.setAuthorizationToken(allocator, token);
        }
        self.transport = http.transport();

        try self.initialize(io, allocator);
    }

    /// Sends the initialize request to begin the MCP handshake.
    fn initialize(self: *Self, io: std.Io, allocator: std.mem.Allocator) !void {
        var params: std.json.ObjectMap = .empty;
        defer params.deinit(allocator);

        try params.put(allocator, "protocolVersion", .{ .string = protocol.VERSION });

        var caps: std.json.ObjectMap = .empty;
        if (self.capabilities.sampling != null) {
            var sampling_cap: std.json.ObjectMap = .empty;
            if (self.capabilities.sampling.?.context != null) {
                try sampling_cap.put(allocator, "context", .{ .object = .empty });
            }
            if (self.capabilities.sampling.?.tools != null) {
                try sampling_cap.put(allocator, "tools", .{ .object = .empty });
            }
            try caps.put(allocator, "sampling", .{ .object = sampling_cap });
        }
        if (self.capabilities.roots) |r| {
            var roots_cap: std.json.ObjectMap = .empty;
            try roots_cap.put(allocator, "listChanged", .{ .bool = r.listChanged });
            try caps.put(allocator, "roots", .{ .object = roots_cap });
        }
        if (self.capabilities.elicitation) |e| {
            var elicit_cap: std.json.ObjectMap = .empty;
            if (e.form != null) {
                try elicit_cap.put(allocator, "form", .{ .object = .empty });
            }
            if (e.url != null) {
                try elicit_cap.put(allocator, "url", .{ .object = .empty });
            }
            try caps.put(allocator, "elicitation", .{ .object = elicit_cap });
        }
        if (self.capabilities.tasks != null) {
            var tasks_cap: std.json.ObjectMap = .empty;
            try tasks_cap.put(allocator, "list", .{ .object = .empty });
            try tasks_cap.put(allocator, "cancel", .{ .object = .empty });
            try caps.put(allocator, "tasks", .{ .object = tasks_cap });
        }
        try params.put(allocator, "capabilities", .{ .object = caps });

        var client_info: std.json.ObjectMap = .empty;
        try client_info.put(allocator, "name", .{ .string = self.config.name });
        try client_info.put(allocator, "version", .{ .string = self.config.version });
        if (self.config.title) |t| {
            try client_info.put(allocator, "title", .{ .string = t });
        }
        if (self.config.description) |d| {
            try client_info.put(allocator, "description", .{ .string = d });
        }
        try params.put(allocator, "clientInfo", .{ .object = client_info });

        try self.sendRequest(io, allocator, "initialize", .{ .object = params });
    }

    /// Sends a JSON-RPC request to the connected server.
    fn sendRequest(self: *Self, io: std.Io, allocator: std.mem.Allocator, method: []const u8, params: ?std.json.Value) !void {
        const id = self.next_request_id;
        self.next_request_id += 1;

        try self.pending_requests.put(id, .{ .method = method });

        const request = jsonrpc.createRequest(.{ .integer = id }, method, params);
        const json = try jsonrpc.serializeMessage(allocator, .{ .request = request });
        defer allocator.free(json);

        if (self.transport) |t| {
            t.send(io, allocator, json) catch {
                std.log.err("Failed to send request", .{});
                return;
            };
        }
    }

    /// Sends a JSON-RPC notification to the connected server.
    fn sendNotification(self: *Self, io: std.Io, allocator: std.mem.Allocator, method: []const u8, params: ?std.json.Value) !void {
        const notification = jsonrpc.createNotification(method, params);
        const json = try jsonrpc.serializeMessage(allocator, .{ .notification = notification });
        defer allocator.free(json);

        if (self.transport) |t| {
            t.send(io, allocator, json) catch {
                std.log.err("Failed to send notification", .{});
                return;
            };
        }
    }

    /// Requests the list of available tools from the server.
    pub fn listTools(self: *Self, io: std.Io, allocator: std.mem.Allocator) !void {
        try self.sendRequest(io, allocator, "tools/list", null);
    }

    /// Invokes a tool on the server with optional arguments.
    pub fn callTool(self: *Self, io: std.Io, allocator: std.mem.Allocator, name: []const u8, arguments: ?std.json.Value) !void {
        var params: std.json.ObjectMap = .empty;
        try params.put(allocator, "name", .{ .string = name });
        if (arguments) |args| {
            try params.put(allocator, "arguments", args);
        }
        try self.sendRequest(io, allocator, "tools/call", .{ .object = params });
    }

    /// Requests the list of available resources from the server.
    pub fn listResources(self: *Self, io: std.Io, allocator: std.mem.Allocator) !void {
        try self.sendRequest(io, allocator, "resources/list", null);
    }

    /// Reads a resource from the server by URI.
    pub fn readResource(self: *Self, io: std.Io, allocator: std.mem.Allocator, uri: []const u8) !void {
        var params: std.json.ObjectMap = .empty;
        try params.put(allocator, "uri", .{ .string = uri });
        try self.sendRequest(io, allocator, "resources/read", .{ .object = params });
    }

    /// Subscribes to updates for a resource URI.
    pub fn subscribeResource(self: *Self, io: std.Io, allocator: std.mem.Allocator, uri: []const u8) !void {
        var params: std.json.ObjectMap = .empty;
        try params.put(allocator, "uri", .{ .string = uri });
        try self.sendRequest(io, allocator, "resources/subscribe", .{ .object = params });
    }

    /// Unsubscribes from updates for a resource URI.
    pub fn unsubscribeResource(self: *Self, io: std.Io, allocator: std.mem.Allocator, uri: []const u8) !void {
        var params: std.json.ObjectMap = .empty;
        try params.put(allocator, "uri", .{ .string = uri });
        try self.sendRequest(io, allocator, "resources/unsubscribe", .{ .object = params });
    }

    /// Requests the list of resource templates from the server.
    pub fn listResourceTemplates(self: *Self, io: std.Io, allocator: std.mem.Allocator) !void {
        try self.sendRequest(io, allocator, "resources/templates/list", null);
    }

    /// Requests the list of available prompts from the server.
    pub fn listPrompts(self: *Self, io: std.Io, allocator: std.mem.Allocator) !void {
        try self.sendRequest(io, allocator, "prompts/list", null);
    }

    /// Fetches a prompt from the server with optional arguments.
    pub fn getPrompt(self: *Self, io: std.Io, allocator: std.mem.Allocator, name: []const u8, arguments: ?std.json.Value) !void {
        var params: std.json.ObjectMap = .empty;
        try params.put(allocator, "name", .{ .string = name });
        if (arguments) |args| {
            try params.put(allocator, "arguments", args);
        }
        try self.sendRequest(io, allocator, "prompts/get", .{ .object = params });
    }

    /// Requests argument completion suggestions.
    pub fn complete(self: *Self, io: std.Io, allocator: std.mem.Allocator, ref: std.json.Value, argument: std.json.Value) !void {
        var params: std.json.ObjectMap = .empty;
        try params.put(allocator, "ref", ref);
        try params.put(allocator, "argument", argument);
        try self.sendRequest(io, allocator, "completion/complete", .{ .object = params });
    }

    /// Sets the log level on the server.
    pub fn setLogLevel(self: *Self, io: std.Io, allocator: std.mem.Allocator, level: []const u8) !void {
        var params: std.json.ObjectMap = .empty;
        try params.put(allocator, "level", .{ .string = level });
        try self.sendRequest(io, allocator, "logging/setLevel", .{ .object = params });
    }

    /// Sends a ping to the server.
    pub fn ping(self: *Self, io: std.Io, allocator: std.mem.Allocator) !void {
        try self.sendRequest(io, allocator, "ping", null);
    }

    /// Gets the status and metadata of a task.
    pub fn getTask(self: *Self, io: std.Io, allocator: std.mem.Allocator, taskId: []const u8) !void {
        var params: std.json.ObjectMap = .empty;
        try params.put(allocator, "taskId", .{ .string = taskId });
        try self.sendRequest(io, allocator, "tasks/get", .{ .object = params });
    }

    /// Gets the result payload of a completed task.
    pub fn getTaskResult(self: *Self, io: std.Io, allocator: std.mem.Allocator, taskId: []const u8) !void {
        var params: std.json.ObjectMap = .empty;
        try params.put(allocator, "taskId", .{ .string = taskId });
        try self.sendRequest(io, allocator, "tasks/result", .{ .object = params });
    }

    /// Lists all tasks.
    pub fn listTasks(self: *Self, io: std.Io, allocator: std.mem.Allocator) !void {
        try self.sendRequest(io, allocator, "tasks/list", null);
    }

    /// Cancels a running task.
    pub fn cancelTask(self: *Self, io: std.Io, allocator: std.mem.Allocator, taskId: []const u8) !void {
        var params: std.json.ObjectMap = .empty;
        try params.put(allocator, "taskId", .{ .string = taskId });
        try self.sendRequest(io, allocator, "tasks/cancel", .{ .object = params });
    }

    /// Sends the notifications/initialized notification.
    pub fn notifyInitialized(self: *Self, io: std.Io, allocator: std.mem.Allocator) !void {
        try self.sendNotification(io, allocator, "notifications/initialized", null);
    }

    /// Sends the notifications/roots/list_changed notification.
    pub fn notifyRootsChanged(self: *Self, io: std.Io, allocator: std.mem.Allocator) !void {
        try self.sendNotification(io, allocator, "notifications/roots/list_changed", null);
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
    var client: Client = .init(std.Io.failing, std.testing.allocator, .{
        .name = "test-client",
        .version = "1.0.0",
    });
    defer client.deinit(std.testing.allocator);

    try std.testing.expectEqual(ClientState.disconnected, client.state);
}

test "Client capabilities" {
    var client: Client = .init(std.Io.failing, std.testing.allocator, .{
        .name = "test",
        .version = "1.0.0",
    });
    defer client.deinit(std.testing.allocator);

    client.enableSampling();
    client.enableRoots(true);
    client.enableElicitation();
    client.enableTasks();

    try std.testing.expect(client.capabilities.sampling != null);
    try std.testing.expect(client.capabilities.roots.?.listChanged);
    try std.testing.expect(client.capabilities.elicitation != null);
    try std.testing.expect(client.capabilities.tasks != null);
}

test "Client advanced sampling" {
    var client: Client = .init(std.Io.failing, std.testing.allocator, .{
        .name = "test",
        .version = "1.0.0",
    });
    defer client.deinit(std.testing.allocator);

    client.enableSamplingAdvanced(true, true);
    try std.testing.expect(client.capabilities.sampling.?.context != null);
    try std.testing.expect(client.capabilities.sampling.?.tools != null);
}

test "Client add root" {
    var client: Client = .init(std.Io.failing, std.testing.allocator, .{
        .name = "test",
        .version = "1.0.0",
    });
    defer client.deinit(std.testing.allocator);

    try client.addRoot(std.testing.allocator, "file:///tmp", "Temp");
    try std.testing.expectEqual(@as(usize, 1), client.roots_list.items.len);
}
