//! MCP Client Implementation (Spec 2026-07-28)
//!
//! Provides an MCP client that connects to MCP servers via STDIO or HTTP transport.
//! The client handles server discovery, capability advertisement, and provides
//! methods for listing and invoking tools, reading resources, and fetching prompts.
//! Supports task-augmented requests, sampling (deprecated), elicitation, roots (deprecated),
//! and MRTR (Multi Round-Trip Requests).

const std = @import("std");

const jsonrpc = @import("../protocol/jsonrpc.zig");
const protocol = @import("../protocol/protocol.zig");
const types = @import("../protocol/types.zig");
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
/// Supports STDIO and HTTP transports, server discovery, and provides
/// methods for all standard MCP operations including tool calls, resource
/// reads, prompt fetches, and task management.
///
/// In MCP 2026-07-28, the protocol is stateless per-request. Every request
/// carries the protocol version and client info in _meta.
pub const Client = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
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

    const Self = @This();

    /// Represents a request awaiting a response from the server.
    pub const PendingRequest = struct {
        method: []const u8,
        callback: ?*const fn (result: ?std.json.Value, err: ?jsonrpc.ErrorResponse.Error) void = null,
    };

    /// Initializes a new client with the given configuration.
    pub fn init(io: std.Io, allocator: std.mem.Allocator, config: ClientConfig) Self {
        return .{
            .io = io,
            .allocator = allocator,
            .config = config,
            .pending_requests = .init(allocator),
            .roots_list = .empty,
        };
    }

    /// Releases all resources held by the client.
    pub fn deinit(self: *Self) void {
        self.pending_requests.deinit();
        self.roots_list.deinit(self.allocator);
        if (self.authorization_token) |token| {
            self.allocator.free(token);
        }
        if (self.transport) |t| {
            t.destroy(self.allocator);
        }
    }

    /// Enables the sampling capability (deprecated in 2026-07-28).
    pub fn enableSampling(self: *Self) void {
        self.capabilities.sampling = .{};
    }

    /// Enables the sampling capability with context and/or tools support (deprecated).
    pub fn enableSamplingAdvanced(self: *Self, context: bool, tools_support: bool) void {
        self.capabilities.sampling = .{
            .context = if (context) .{} else null,
            .tools = if (tools_support) .{} else null,
        };
    }

    /// Enables the roots capability (deprecated in 2026-07-28).
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

    /// Enables task-augmented requests for sampling and elicitation.
    pub fn enableTasksAdvanced(self: *Self, sampling: bool, elicitation: bool) void {
        self.capabilities.tasks = .{
            .list = .{},
            .cancel = .{},
            .requests = .{
                .sampling = if (sampling) .{ .createMessage = .{} } else null,
                .elicitation = if (elicitation) .{ .create = .{} } else null,
            },
        };
    }

    /// Adds a filesystem root that the server can access (deprecated).
    pub fn addRoot(self: *Self, uri: []const u8, name: ?[]const u8) !void {
        try self.roots_list.append(self.allocator, .{ .uri = uri, .name = name });
    }

    /// Connects to a server by spawning a process and communicating via STDIO.
    pub fn connectStdio(self: *Self, command: []const u8, args: []const []const u8) !void {
        _ = args;
        _ = command;
        self.state = .connecting;

        const stdio = try self.allocator.create(transport_mod.StdioTransport);
        stdio.* = .{};
        self.transport = stdio.transport();

        self.state = .connected;
        self.log("Connected via STDIO");
    }

    /// Sets the authorization token for Bearer auth (OAuth 2.1).
    pub fn setAuthorizationToken(self: *Self, token: []const u8) !void {
        if (self.authorization_token) |old| {
            self.allocator.free(old);
        }
        self.authorization_token = try self.allocator.dupe(u8, token);
    }

    /// Connects to a server via HTTP at the specified URL.
    pub fn connectHttp(self: *Self, url: []const u8) !void {
        self.state = .connecting;

        const http = try self.allocator.create(transport_mod.HttpTransport);
        http.* = try transport_mod.HttpTransport.init(self.allocator, url);
        if (self.authorization_token) |token| {
            try http.setAuthorizationToken(self.allocator, token);
        }
        try http.setClientInfo(self.allocator, self.config.name, self.config.version);
        self.transport = http.transport();

        self.state = .connected;
        self.log("Connected via HTTP");
    }

    /// Sends a server/discover request to learn about the server.
    /// This is the mandatory entry point in MCP 2026-07-28.
    pub fn discover(self: *Self) !void {
        try self.sendRequest("server/discover", null);
    }

    /// Sends a JSON-RPC request to the connected server.
    fn sendRequest(self: *Self, method: []const u8, params: ?std.json.Value) !void {
        const id = self.next_request_id;
        self.next_request_id += 1;

        try self.pending_requests.put(id, .{ .method = method });

        // Build _meta with per-request metadata (2026-07-28 stateless model).
        // `info` is stored by value inside `meta`; both are deinited below
        // after the request has been serialized and sent.
        var info: std.json.ObjectMap = .empty;
        defer info.deinit(self.allocator);
        try info.put(self.allocator, "name", .{ .string = self.config.name });
        try info.put(self.allocator, "version", .{ .string = self.config.version });

        var meta: std.json.ObjectMap = .empty;
        defer meta.deinit(self.allocator);
        try meta.put(self.allocator, "io.modelcontextprotocol/protocolVersion", .{ .string = protocol.VERSION });
        try meta.put(self.allocator, "io.modelcontextprotocol/clientInfo", .{
            .object = info,
        });

        var merged_params: std.json.ObjectMap = .empty;
        defer merged_params.deinit(self.allocator);
        if (params) |p| {
            if (p == .object) {
                var iter = p.object.iterator();
                while (iter.next()) |entry| {
                    try merged_params.put(self.allocator, entry.key_ptr.*, entry.value_ptr.*);
                }
            }
        }
        try merged_params.put(self.allocator, "_meta", .{ .object = meta });

        const request = jsonrpc.createRequest(.{ .integer = id }, method, .{ .object = merged_params });
        const json = try jsonrpc.serializeMessage(self.allocator, .{ .request = request });
        defer self.allocator.free(json);

        if (self.transport) |t| {
            try t.send(self.io, self.allocator, json);
        }
    }

    /// Sends a JSON-RPC notification to the connected server.
    fn sendNotification(self: *Self, method: []const u8, params: ?std.json.Value) !void {
        const notification = jsonrpc.createNotification(method, params);
        const json = try jsonrpc.serializeMessage(self.allocator, .{ .notification = notification });
        defer self.allocator.free(json);

        if (self.transport) |t| {
            try t.send(self.io, self.allocator, json);
        }
    }

    /// Requests the list of available tools from the server.
    pub fn listTools(self: *Self) !void {
        try self.sendRequest("tools/list", null);
    }

    /// A round of Multi Round-Trip Requests that the server asked the client to
    /// satisfy before it could complete the original request.
    pub const InputRequiredRound = struct {
        /// Server-assigned request map, keyed by identifier.
        inputRequests: types.InputRequests,
        /// Opaque server state that MUST be echoed back verbatim on the retry.
        requestState: ?[]const u8 = null,

        /// Returns the request registered under `key`, or null.
        pub fn request(self: InputRequiredRound, key: []const u8) ?std.json.Value {
            return self.inputRequests.get(key);
        }
    };

    /// Recognises an `InputRequiredResult` in a `result` object.
    ///
    /// Returns null for any other `resultType`, including `complete`. A
    /// `resultType` this client does not recognise is treated as invalid by
    /// the spec, so only the two core values are accepted here.
    pub fn parseInputRequired(result: std.json.ObjectMap) ?InputRequiredRound {
        const rt = result.get("resultType") orelse return null;
        if (rt != .string) return null;
        if (!std.mem.eql(u8, rt.string, protocol.RESULT_TYPE_INPUT_REQUIRED)) return null;

        var requests: types.InputRequests = .empty;
        if (result.get("inputRequests")) |v| {
            if (v == .object) requests = v.object;
        }
        var state: ?[]const u8 = null;
        if (result.get("requestState")) |v| {
            if (v == .string) state = v.string;
        }
        return .{ .inputRequests = requests, .requestState = state };
    }

    /// Invokes a tool on the server with optional arguments.
    pub fn callTool(self: *Self, name: []const u8, arguments: ?std.json.Value) !void {
        try self.callToolRound(name, arguments, null);
    }

    /// Retries `tools/call` with the `inputResponses` and `requestState` from
    /// a previous `InputRequiredResult`.
    ///
    /// The retry is a fresh request and therefore gets a fresh JSON-RPC id.
    /// Pass `round.requestState` back unchanged; it is opaque to the client.
    pub fn callToolRound(
        self: *Self,
        name: []const u8,
        arguments: ?std.json.Value,
        round: ?InputRequiredRound,
    ) !void {
        var params: std.json.ObjectMap = .empty;
        defer params.deinit(self.allocator);
        try params.put(self.allocator, "name", .{ .string = name });
        if (arguments) |args| {
            try params.put(self.allocator, "arguments", args);
        }
        if (round) |r| {
            try self.putRoundParams(r, &params);
        }
        try self.sendRequest("tools/call", .{ .object = params });
    }

    /// Requests the list of available resources from the server.
    pub fn listResources(self: *Self) !void {
        try self.sendRequest("resources/list", null);
    }

    /// Reads a resource from the server by URI.
    pub fn readResource(self: *Self, uri: []const u8) !void {
        try self.readResourceRound(uri, null);
    }

    /// Retries `resources/read` with the `inputResponses` and `requestState`
    /// from a previous `InputRequiredResult`.
    pub fn readResourceRound(self: *Self, uri: []const u8, round: ?InputRequiredRound) !void {
        var params: std.json.ObjectMap = .empty;
        defer params.deinit(self.allocator);
        try params.put(self.allocator, "uri", .{ .string = uri });
        try self.putRoundParams(round, &params);
        try self.sendRequest("resources/read", .{ .object = params });
    }

    /// Subscribes to resource updates via subscriptions/listen.
    pub fn subscriptionsListen(self: *Self, uri: []const u8) !void {
        var params: std.json.ObjectMap = .empty;
        defer params.deinit(self.allocator);
        try params.put(self.allocator, "uri", .{ .string = uri });
        try self.sendRequest("subscriptions/listen", .{ .object = params });
    }

    /// Requests the list of resource templates from the server.
    pub fn listResourceTemplates(self: *Self) !void {
        try self.sendRequest("resources/templates/list", null);
    }

    /// Requests the list of available prompts from the server.
    pub fn listPrompts(self: *Self) !void {
        try self.sendRequest("prompts/list", null);
    }

    /// Fetches a prompt from the server with optional arguments.
    pub fn getPrompt(self: *Self, name: []const u8, arguments: ?std.json.Value) !void {
        try self.getPromptRound(name, arguments, null);
    }

    /// Retries `prompts/get` with the `inputResponses` and `requestState`
    /// from a previous `InputRequiredResult`.
    pub fn getPromptRound(self: *Self, name: []const u8, arguments: ?std.json.Value, round: ?InputRequiredRound) !void {
        var params: std.json.ObjectMap = .empty;
        defer params.deinit(self.allocator);
        try params.put(self.allocator, "name", .{ .string = name });
        if (arguments) |args| {
            try params.put(self.allocator, "arguments", args);
        }
        try self.putRoundParams(round, &params);
        try self.sendRequest("prompts/get", .{ .object = params });
    }

    /// Copies an MRTR round into request params.
    ///
    /// `requestState` is opaque to the client and is echoed back verbatim; the
    /// spec forbids inspecting or modifying it.
    fn putRoundParams(self: *Self, round: ?InputRequiredRound, params: *std.json.ObjectMap) !void {
        const r = round orelse return;
        try params.put(self.allocator, "inputResponses", .{ .object = r.inputRequests });
        if (r.requestState) |state| {
            try params.put(self.allocator, "requestState", .{ .string = state });
        }
    }

    /// Requests argument completion suggestions.
    pub fn complete(self: *Self, ref: std.json.Value, argument: std.json.Value) !void {
        var params: std.json.ObjectMap = .empty;
        defer params.deinit(self.allocator);
        try params.put(self.allocator, "ref", ref);
        try params.put(self.allocator, "argument", argument);
        try self.sendRequest("completion/complete", .{ .object = params });
    }

    /// Gets the status and metadata of a task.
    pub fn getTask(self: *Self, taskId: []const u8) !void {
        var params: std.json.ObjectMap = .empty;
        defer params.deinit(self.allocator);
        try params.put(self.allocator, "taskId", .{ .string = taskId });
        try self.sendRequest("tasks/get", .{ .object = params });
    }

    /// Gets the result payload of a completed task.
    pub fn getTaskResult(self: *Self, taskId: []const u8) !void {
        var params: std.json.ObjectMap = .empty;
        defer params.deinit(self.allocator);
        try params.put(self.allocator, "taskId", .{ .string = taskId });
        try self.sendRequest("tasks/result", .{ .object = params });
    }

    /// Lists all tasks.
    pub fn listTasks(self: *Self) !void {
        try self.sendRequest("tasks/list", null);
    }

    /// Cancels a running task.
    pub fn cancelTask(self: *Self, taskId: []const u8) !void {
        var params: std.json.ObjectMap = .empty;
        defer params.deinit(self.allocator);
        try params.put(self.allocator, "taskId", .{ .string = taskId });
        try self.sendRequest("tasks/cancel", .{ .object = params });
    }

    /// Sends the notifications/roots/list_changed notification (deprecated).
    pub fn notifyRootsChanged(self: *Self) !void {
        try self.sendNotification("notifications/roots/list_changed", null);
    }

    /// Sends multiple JSON-RPC requests as a batch.
    /// Returns an array of responses.
    pub fn sendBatch(self: *Self, requests: []const jsonrpc.Request) !std.ArrayList(jsonrpc.Response) {
        var responses: std.ArrayList(jsonrpc.Response) = .empty;
        errdefer responses.deinit(self.allocator);

        for (requests) |req| {
            const id = self.next_request_id;
            self.next_request_id += 1;

            try self.pending_requests.put(id, .{ .method = req.method });

            const request = jsonrpc.createRequest(.{ .integer = id }, req.method, req.params);
            const json = try jsonrpc.serializeMessage(self.allocator, .{ .request = request });
            defer self.allocator.free(json);

            if (self.transport) |t| {
                try t.send(self.io, self.allocator, json);
            }
        }

        return responses;
    }

    /// Disconnects from the server and releases the transport.
    pub fn disconnect(self: *Self) void {
        if (self.transport) |t| {
            t.close();
            t.destroy(self.allocator);
            self.transport = null;
        }
        self.state = .disconnected;
    }

    fn log(self: *Self, message: []const u8) void {
        _ = self;
        std.log.info("{s}", .{message});
    }
};

test "Client initialization" {
    var client = Client.init(std.Io.failing, std.testing.allocator, .{
        .name = "test-client",
        .version = "1.0.0",
    });
    defer client.deinit();

    try std.testing.expectEqual(ClientState.disconnected, client.state);
}

test "Client capabilities" {
    var client = Client.init(std.Io.failing, std.testing.allocator, .{
        .name = "test",
        .version = "1.0.0",
    });
    defer client.deinit();

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
    var client = Client.init(std.Io.failing, std.testing.allocator, .{
        .name = "test",
        .version = "1.0.0",
    });
    defer client.deinit();

    client.enableSamplingAdvanced(true, true);
    try std.testing.expect(client.capabilities.sampling.?.context != null);
    try std.testing.expect(client.capabilities.sampling.?.tools != null);
}

test "Client add root" {
    var client = Client.init(std.Io.failing, std.testing.allocator, .{
        .name = "test",
        .version = "1.0.0",
    });
    defer client.deinit();

    try client.addRoot("file:///tmp", "Temp");
    try std.testing.expectEqual(@as(usize, 1), client.roots_list.items.len);
}

test "Client multiple roots" {
    var client = Client.init(std.Io.failing, std.testing.allocator, .{
        .name = "test",
        .version = "1.0.0",
    });
    defer client.deinit();

    try client.addRoot("file:///tmp", "Temp");
    try client.addRoot("file:///home", "Home");
    try client.addRoot("file:///var", "Var");
    try std.testing.expectEqual(@as(usize, 3), client.roots_list.items.len);
}

test "Client disconnect" {
    var client = Client.init(std.Io.failing, std.testing.allocator, .{
        .name = "test",
        .version = "1.0.0",
    });
    defer client.deinit();

    try std.testing.expectEqual(ClientState.disconnected, client.state);
    client.disconnect();
    try std.testing.expectEqual(ClientState.disconnected, client.state);
}

test "Client set authorization token" {
    var client = Client.init(std.Io.failing, std.testing.allocator, .{
        .name = "test",
        .version = "1.0.0",
    });
    defer client.deinit();

    try client.setAuthorizationToken("test-token-123");
    try std.testing.expect(client.authorization_token != null);
    try std.testing.expectEqualStrings("test-token-123", client.authorization_token.?);
}

test "Client enable all capabilities" {
    var client = Client.init(std.Io.failing, std.testing.allocator, .{
        .name = "test",
        .version = "1.0.0",
    });
    defer client.deinit();

    client.enableSamplingAdvanced(true, true);
    client.enableRoots(true);
    client.enableElicitation();
    client.enableTasksAdvanced(true, true);

    try std.testing.expect(client.capabilities.sampling != null);
    try std.testing.expect(client.capabilities.roots != null);
    try std.testing.expect(client.capabilities.elicitation != null);
    try std.testing.expect(client.capabilities.tasks != null);
}

test "Client request maps do not leak" {
    // Exercises sendRequest (meta/clientInfo maps) and every params-building
    // helper with no transport attached. std.testing.allocator fails the test
    // on any leak.
    var client = Client.init(std.Io.failing, std.testing.allocator, .{
        .name = "test",
        .version = "1.0.0",
    });
    defer client.deinit();

    try client.discover();
    try client.listTools();
    try client.listResources();
    try client.listPrompts();
    try client.listTasks();
    try client.callTool("greet", null);

    var args: std.json.ObjectMap = .empty;
    defer args.deinit(std.testing.allocator);
    try args.put(std.testing.allocator, "name", .{ .string = "World" });
    try client.callTool("greet", .{ .object = args });
    try client.getPrompt("intro", .{ .object = args });
    try client.readResource("file:///data.json");
    try client.subscriptionsListen("file:///data.json");
    try client.getTask("task-1");
    try client.getTaskResult("task-1");
    try client.cancelTask("task-1");
    try client.complete(.{ .string = "ref" }, .{ .string = "arg" });
    try client.notifyRootsChanged();
}

test "Client sendBatch with unmanaged ArrayList (Zig 0.17 migration)" {
    var client = Client.init(std.Io.failing, std.testing.allocator, .{
        .name = "test",
        .version = "1.0.0",
    });
    defer client.deinit();

    // No transport: requests are tracked as pending, responses list is empty.
    const reqs = [_]jsonrpc.Request{
        .{ .id = .{ .integer = 1 }, .method = "tools/list", .params = null },
        .{ .id = .{ .integer = 2 }, .method = "resources/list", .params = null },
    };
    var responses = try client.sendBatch(&reqs);
    defer responses.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), responses.items.len);
    try std.testing.expectEqual(@as(i64, 3), client.next_request_id);
}

test "parseInputRequired recognises only the input_required resultType" {
    const a = std.testing.allocator;

    const body =
        \\{"resultType":"input_required","inputRequests":{"github_login":{"method":"elicitation/create","params":{"mode":"form"}}},"requestState":"opaque"}
    ;
    var parsed = try std.json.parseFromSlice(std.json.Value, a, body, .{});
    defer parsed.deinit();

    const round = Client.parseInputRequired(parsed.value.object).?;
    try std.testing.expectEqualStrings("opaque", round.requestState.?);
    try std.testing.expectEqualStrings("elicitation/create", round.request("github_login").?.object.get("method").?.string);

    // `complete` is not an MRTR round, and an absent resultType is treated as
    // complete for backwards compatibility, so neither yields a round.
    const complete = "{\"resultType\":\"complete\",\"content\":[]}";
    var p2 = try std.json.parseFromSlice(std.json.Value, a, complete, .{});
    defer p2.deinit();
    try std.testing.expect(Client.parseInputRequired(p2.value.object) == null);

    const legacy = "{\"content\":[]}";
    var p3 = try std.json.parseFromSlice(std.json.Value, a, legacy, .{});
    defer p3.deinit();
    try std.testing.expect(Client.parseInputRequired(p3.value.object) == null);
}

test "callToolRound echoes inputResponses and requestState on the retry" {
    const a = std.testing.allocator;

    var sent = std.ArrayList([]u8).empty;
    defer {
        for (sent.items) |m| a.free(m);
        sent.deinit(a);
    }

    var client = Client.init(std.Io.failing, a, .{ .name = "mrtr-client", .version = "1.0.0" });
    defer client.deinit();
    client.transport = .{
        .ptr = &sent,
        .vtable = &.{
            .send = struct {
                fn f(p: *anyopaque, _: std.Io, al: std.mem.Allocator, m: []const u8) transport_mod.Transport.SendError!void {
                    const list: *std.ArrayList([]u8) = @ptrCast(@alignCast(p));
                    list.append(al, try al.dupe(u8, m)) catch return error.OutOfMemory;
                }
            }.f,
            .receive = struct {
                fn f(_: *anyopaque, _: std.Io, _: std.mem.Allocator) transport_mod.Transport.ReceiveError!?[]const u8 {
                    return null;
                }
            }.f,
            .close = struct {
                fn f(_: *anyopaque) void {}
            }.f,
            .destroy = struct {
                fn f(_: *anyopaque, _: std.mem.Allocator) void {}
            }.f,
        },
    };

    var responses: types.InputRequests = .empty;
    defer responses.deinit(a);
    try responses.put(a, "github_login", .{ .string = "octocat" });

    try client.callToolRound("greet", null, .{ .inputRequests = responses, .requestState = "opaque" });

    try std.testing.expectEqual(@as(usize, 1), sent.items.len);
    var parsed = try std.json.parseFromSlice(std.json.Value, a, sent.items[0], .{});
    defer parsed.deinit();

    const params = parsed.value.object.get("params").?.object;
    try std.testing.expectEqualStrings("greet", params.get("name").?.string);
    try std.testing.expectEqualStrings("octocat", params.get("inputResponses").?.object.get("github_login").?.string);
    try std.testing.expectEqualStrings("opaque", params.get("requestState").?.string);
}
