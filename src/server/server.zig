//! MCP Server Implementation (Spec 2025-11-25)
//!
//! Provides the main MCP Server that handles client connections, protocol
//! negotiation, capability advertisement, and request routing for tools,
//! resources, prompts, tasks, and all standard MCP methods.

const std = @import("std");
const http = std.http;

const jsonrpc = @import("../protocol/jsonrpc.zig");
const protocol = @import("../protocol/protocol.zig");
const types = @import("../protocol/types.zig");
const transport_mod = @import("../transport/transport.zig");
const prompts_mod = @import("prompts.zig");
const resources_mod = @import("resources.zig");
const tools_mod = @import("tools.zig");

const HttpRequestTransport = struct {
    response_message: ?[]const u8 = null,
    is_closed: bool = false,

    const Self = @This();

    pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
        if (self.response_message) |msg| {
            allocator.free(msg);
            self.response_message = null;
        }
    }

    pub fn send(self: *Self, _: std.Io, allocator: std.mem.Allocator, message: []const u8) transport_mod.Transport.SendError!void {
        if (self.is_closed) return transport_mod.Transport.SendError.ConnectionClosed;

        const owned = allocator.dupe(u8, message) catch return transport_mod.Transport.SendError.OutOfMemory;
        if (self.response_message) |old| {
            allocator.free(old);
        }
        self.response_message = owned;
    }

    pub fn receive(self: *Self, _: std.Io, _: std.mem.Allocator) transport_mod.Transport.ReceiveError!?[]const u8 {
        if (self.is_closed) return transport_mod.Transport.ReceiveError.ConnectionClosed;
        return null;
    }

    pub fn close(self: *Self) void {
        self.is_closed = true;
    }

    pub fn transport(self: *Self) transport_mod.Transport {
        return .{
            .ptr = self,
            .vtable = &.{
                .send = sendVtable,
                .receive = receiveVtable,
                .close = closeVtable,
            },
        };
    }

    fn sendVtable(ptr: *anyopaque, io: std.Io, allocator: std.mem.Allocator, message: []const u8) transport_mod.Transport.SendError!void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        return self.send(io, allocator, message);
    }

    fn receiveVtable(ptr: *anyopaque, io: std.Io, allocator: std.mem.Allocator) transport_mod.Transport.ReceiveError!?[]const u8 {
        const self: *Self = @ptrCast(@alignCast(ptr));
        return self.receive(io, allocator);
    }

    fn closeVtable(ptr: *anyopaque) void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        self.close();
    }
};

/// Configuration for an MCP Server
pub const ServerConfig = struct {
    name: []const u8,
    version: []const u8,
    title: ?[]const u8 = null,
    description: ?[]const u8 = null,
    icons: ?[]const types.Icon = null,
    websiteUrl: ?[]const u8 = null,
    instructions: ?[]const u8 = null,
};

/// Current state of the server
pub const ServerState = enum {
    uninitialized,
    initializing,
    ready,
    shutting_down,
    stopped,
};

/// MCP Server that handles client connections and routes requests
pub const Server = struct {
    config: ServerConfig,
    state: ServerState = .uninitialized,
    tools: std.StringHashMap(tools_mod.Tool),
    resources: std.StringHashMap(resources_mod.Resource),
    resource_templates: std.StringHashMap(resources_mod.ResourceTemplate),
    prompts: std.StringHashMap(prompts_mod.Prompt),
    capabilities: types.ServerCapabilities = .{},
    client_info: ?types.Implementation = null,
    client_capabilities: ?types.ClientCapabilities = null,
    transport: ?transport_mod.Transport = null,
    stdio_transport: ?*transport_mod.StdioTransport = null,
    next_request_id: i64 = 1,
    pending_requests: std.AutoHashMap(i64, PendingRequest),
    log_level: protocol.LogLevel = .info,
    pub const max_http_body_size: usize = 4 * 1024 * 1024;

    const Self = @This();

    pub const PendingRequest = struct {
        method: []const u8,
        timestamp: i64,
    };

    /// Initialize a new MCP Server
    pub fn init(allocator: std.mem.Allocator, config: ServerConfig) Self {
        return .{
            .config = config,
            .tools = .init(allocator),
            .resources = .init(allocator),
            .resource_templates = .init(allocator),
            .prompts = .init(allocator),
            .pending_requests = .init(allocator),
        };
    }

    /// Clean up server resources
    pub fn deinit(self: *Self) void {
        self.tools.deinit();
        self.resources.deinit();
        self.resource_templates.deinit();
        self.prompts.deinit();
        self.pending_requests.deinit();
    }

    /// Add a tool to the server
    pub fn addTool(self: *Self, tool: tools_mod.Tool) !void {
        try self.tools.put(tool.name, tool);
        self.capabilities.tools = .{ .listChanged = true };
    }

    /// Add a resource to the server
    pub fn addResource(self: *Self, resource: resources_mod.Resource) !void {
        try self.resources.put(resource.uri, resource);
        self.capabilities.resources = .{ .listChanged = true, .subscribe = false };
    }

    /// Add a resource template to the server
    pub fn addResourceTemplate(self: *Self, template: resources_mod.ResourceTemplate) !void {
        try self.resource_templates.put(template.name, template);
        if (self.capabilities.resources == null) {
            self.capabilities.resources = .{};
        }
    }

    /// Add a prompt to the server
    pub fn addPrompt(self: *Self, prompt: prompts_mod.Prompt) !void {
        try self.prompts.put(prompt.name, prompt);
        self.capabilities.prompts = .{ .listChanged = true };
    }

    /// Enable logging capability
    pub fn enableLogging(self: *Self) void {
        self.capabilities.logging = .{};
    }

    /// Enable completion capability
    pub fn enableCompletions(self: *Self) void {
        self.capabilities.completions = .{};
    }

    /// Enable task-augmented tools/call support
    pub fn enableTasks(self: *Self) void {
        self.capabilities.tasks = .{
            .list = .{},
            .cancel = .{},
            .requests = .{
                .tools = .{
                    .call = .{},
                },
            },
        };
    }

    /// Options for running the server
    pub const HttpRunConfig = struct {
        port: u16 = 8080,
        host: []const u8 = "localhost",
    };

    pub const RunOptions = union(enum) {
        stdio: void,
        http: HttpRunConfig,
    };

    /// Run the server with the specified transport
    pub fn run(self: *Self, io: std.Io, allocator: std.mem.Allocator, options: RunOptions) !void {
        switch (options) {
            .stdio => {
                self.log(io, "Server listening on STDIO");
                const stdio = try allocator.create(transport_mod.StdioTransport);
                stdio.* = .{};
                self.stdio_transport = stdio;
                self.transport = stdio.transport();
                try self.messageLoop(io, allocator);
            },
            .http => |config| {
                try self.runHttp(io, allocator, config);
            },
        }
    }

    fn runHttp(self: *Self, io: std.Io, allocator: std.mem.Allocator, config: HttpRunConfig) !void {
        const bind_host = if (std.mem.eql(u8, config.host, "localhost")) "127.0.0.1" else config.host;

        const address = std.Io.net.IpAddress.resolve(io, bind_host, config.port) catch {
            return error.AddressResolutionError;
        };

        var listener = try std.Io.net.IpAddress.listen(&address, io, .{});
        defer listener.deinit(io);

        while (self.state != .stopped and self.state != .shutting_down) {
            const stream = listener.accept(io) catch |err| {
                std.log.err("HTTP accept failed: {s}", .{@errorName(err)});
                continue;
            };

            self.serveHttpConnection(io, allocator, stream) catch |err| {
                std.log.err("HTTP connection error: {s}", .{@errorName(err)});
            };
        }
    }

    fn serveHttpConnection(self: *Self, io: std.Io, allocator: std.mem.Allocator, stream: std.Io.net.Stream) !void {
        defer stream.close(io);

        var send_buffer: [4096]u8 = undefined;
        var recv_buffer: [4096]u8 = undefined;
        var connection_reader = stream.reader(io, &recv_buffer);
        var connection_writer = stream.writer(io, &send_buffer);
        var server: http.Server = .init(&connection_reader.interface, &connection_writer.interface);

        var request = server.receiveHead() catch |err| switch (err) {
            error.HttpConnectionClosing => return,
            else => return err,
        };

        if (request.head.method != .POST) {
            try request.respond("Method Not Allowed", .{
                .status = .method_not_allowed,
                .extra_headers = &.{
                    .{ .name = "Content-Type", .value = "text/plain" },
                },
            });
            return;
        }

        try self.handleHttpJsonRpcRequest(io, allocator, &request);
    }

    fn handleHttpJsonRpcRequest(self: *Self, io: std.Io, allocator: std.mem.Allocator, request: *http.Server.Request) !void {
        const content_length = request.head.content_length orelse {
            try request.respond("Content-Length required", .{
                .status = .bad_request,
                .extra_headers = &.{
                    .{ .name = "Content-Type", .value = "text/plain" },
                },
            });
            return;
        };

        if (content_length == 0) {
            try request.respond("Empty JSON-RPC payload", .{
                .status = .bad_request,
                .extra_headers = &.{
                    .{ .name = "Content-Type", .value = "text/plain" },
                },
            });
            return;
        }

        if (content_length > max_http_body_size) {
            try request.respond("Request body too large", .{
                .status = .bad_request,
                .extra_headers = &.{
                    .{ .name = "Content-Type", .value = "text/plain" },
                },
            });
            return;
        }

        var read_buffer: [2048]u8 = undefined;
        var body_reader = request.readerExpectContinue(&read_buffer) catch {
            try request.respond("Invalid request body", .{
                .status = .bad_request,
                .extra_headers = &.{
                    .{ .name = "Content-Type", .value = "text/plain" },
                },
            });
            return;
        };

        const read_len = std.math.cast(usize, content_length) orelse {
            try request.respond("Request body too large", .{
                .status = .bad_request,
                .extra_headers = &.{
                    .{ .name = "Content-Type", .value = "text/plain" },
                },
            });
            return;
        };

        const body_items = body_reader.readAlloc(allocator, read_len) catch {
            try request.respond("Failed to read request body", .{
                .status = .bad_request,
                .extra_headers = &.{
                    .{ .name = "Content-Type", .value = "text/plain" },
                },
            });
            return;
        };
        defer allocator.free(body_items);

        var request_transport: HttpRequestTransport = .{};
        defer request_transport.deinit(allocator);

        const previous_transport = self.transport;
        self.transport = request_transport.transport();
        defer self.transport = previous_transport;

        self.handleMessage(io, allocator, body_items) catch {
            const internal_error = jsonrpc.createParseError(.{ .string = "Internal server error" });
            const json = jsonrpc.serializeMessage(allocator, .{ .error_response = internal_error }) catch {
                try request.respond("Internal server error", .{
                    .status = .internal_server_error,
                    .extra_headers = &.{
                        .{ .name = "Content-Type", .value = "text/plain" },
                    },
                });
                return;
            };
            defer allocator.free(json);

            try request.respond(json, .{
                .status = .internal_server_error,
                .extra_headers = &.{
                    .{ .name = "Content-Type", .value = "application/json" },
                },
            });
            return;
        };

        if (request_transport.response_message) |response_json| {
            try request.respond(response_json, .{
                .status = .ok,
                .extra_headers = &.{
                    .{ .name = "Content-Type", .value = "application/json" },
                },
            });
            return;
        }

        try request.respond("", .{ .status = .no_content });
    }

    /// Run the server with a custom transport
    pub fn runWithTransport(self: *Self, io: std.Io, allocator: std.mem.Allocator, t: transport_mod.Transport) !void {
        self.transport = t;
        try self.messageLoop(io, allocator);
    }

    /// Main message processing loop
    fn messageLoop(self: *Self, io: std.Io, allocator: std.mem.Allocator) !void {
        while (self.state != .stopped and self.state != .shutting_down) {
            const message_data = self.transport.?.receive(io, allocator) catch |err| {
                switch (err) {
                    error.EndOfStream => {
                        self.state = .shutting_down;
                        break;
                    },
                    else => {
                        self.logError(io, "Transport receive error");
                        continue;
                    },
                }
            };

            if (message_data) |data| {
                try self.handleMessage(io, allocator, data);
            }
        }

        self.state = .stopped;
    }

    /// Handle an incoming message
    fn handleMessage(self: *Self, io: std.Io, allocator: std.mem.Allocator, data: []const u8) !void {
        const parsed_message = jsonrpc.parseMessage(allocator, data) catch {
            const error_response = jsonrpc.createParseError(null);
            try self.sendResponse(io, allocator, .{ .error_response = error_response });
            return;
        };
        defer parsed_message.deinit();

        switch (parsed_message.message) {
            .request => |req| try self.handleRequest(io, allocator, req),
            .notification => |notif| try self.handleNotification(io, notif),
            .response => |resp| self.handleResponse(resp),
            .error_response => |err| self.handleErrorResponse(io, err),
        }
    }

    /// Handle an incoming request
    fn handleRequest(self: *Self, io: std.Io, allocator: std.mem.Allocator, request: jsonrpc.Request) !void {
        var buf: [256]u8 = undefined;
        if (std.fmt.bufPrint(&buf, "Received request: {s}", .{request.method})) |msg| {
            self.log(io, msg);
        } else |_| {}

        if (self.state == .uninitialized and !std.mem.eql(u8, request.method, "initialize")) {
            const error_response = jsonrpc.createErrorResponse(
                request.id,
                jsonrpc.ErrorCode.SERVER_NOT_INITIALIZED,
                "Server not initialized",
                null,
            );
            try self.sendResponse(io, allocator, .{ .error_response = error_response });
            return;
        }

        if (std.mem.eql(u8, request.method, "initialize")) {
            try self.handleInitialize(io, allocator, request);
        } else if (std.mem.eql(u8, request.method, "ping")) {
            try self.handlePing(io, allocator, request);
        } else if (std.mem.eql(u8, request.method, "tools/list")) {
            try self.handleToolsList(io, allocator, request);
        } else if (std.mem.eql(u8, request.method, "tools/call")) {
            try self.handleToolsCall(io, allocator, request);
        } else if (std.mem.eql(u8, request.method, "resources/list")) {
            try self.handleResourcesList(io, allocator, request);
        } else if (std.mem.eql(u8, request.method, "resources/read")) {
            try self.handleResourcesRead(io, allocator, request);
        } else if (std.mem.eql(u8, request.method, "resources/templates/list")) {
            try self.handleResourceTemplatesList(io, allocator, request);
        } else if (std.mem.eql(u8, request.method, "resources/subscribe")) {
            try self.handleSubscribe(io, allocator, request);
        } else if (std.mem.eql(u8, request.method, "resources/unsubscribe")) {
            try self.handleUnsubscribe(io, allocator, request);
        } else if (std.mem.eql(u8, request.method, "prompts/list")) {
            try self.handlePromptsList(io, allocator, request);
        } else if (std.mem.eql(u8, request.method, "prompts/get")) {
            try self.handlePromptsGet(io, allocator, request);
        } else if (std.mem.eql(u8, request.method, "logging/setLevel")) {
            try self.handleSetLogLevel(io, allocator, request);
        } else if (std.mem.eql(u8, request.method, "completion/complete")) {
            try self.handleCompletion(io, allocator, request);
        } else if (std.mem.eql(u8, request.method, "tasks/get")) {
            try self.handleTasksGet(io, allocator, request);
        } else if (std.mem.eql(u8, request.method, "tasks/result")) {
            try self.handleTasksResult(io, allocator, request);
        } else if (std.mem.eql(u8, request.method, "tasks/list")) {
            try self.handleTasksList(io, allocator, request);
        } else if (std.mem.eql(u8, request.method, "tasks/cancel")) {
            try self.handleTasksCancel(io, allocator, request);
        } else {
            const error_response = jsonrpc.createMethodNotFound(request.id, request.method);
            try self.sendResponse(io, allocator, .{ .error_response = error_response });
        }
    }

    /// Handle initialize request
    fn handleInitialize(self: *Self, io: std.Io, allocator: std.mem.Allocator, request: jsonrpc.Request) !void {
        self.state = .initializing;

        if (request.params) |params| {
            if (params == .object) {
                const obj = params.object;

                if (obj.get("clientInfo")) |client_info_val| {
                    if (client_info_val == .object) {
                        const ci = client_info_val.object;
                        self.client_info = .{
                            .name = if (ci.get("name")) |n| if (n == .string) n.string else "unknown" else "unknown",
                            .version = if (ci.get("version")) |v| if (v == .string) v.string else "0.0.0" else "0.0.0",
                        };
                    }
                }
            }
        }

        var result: std.json.ObjectMap = .empty;
        defer result.deinit(allocator);

        try result.put(allocator, "protocolVersion", .{ .string = protocol.VERSION });

        var caps: std.json.ObjectMap = .empty;
        if (self.capabilities.tools) |t| {
            var tools_cap: std.json.ObjectMap = .empty;
            try tools_cap.put(allocator, "listChanged", .{ .bool = t.listChanged });
            try caps.put(allocator, "tools", .{ .object = tools_cap });
        }
        if (self.capabilities.resources) |r| {
            var res_cap: std.json.ObjectMap = .empty;
            try res_cap.put(allocator, "listChanged", .{ .bool = r.listChanged });
            try res_cap.put(allocator, "subscribe", .{ .bool = r.subscribe });
            try caps.put(allocator, "resources", .{ .object = res_cap });
        }
        if (self.capabilities.prompts) |p| {
            var prompts_cap: std.json.ObjectMap = .empty;
            try prompts_cap.put(allocator, "listChanged", .{ .bool = p.listChanged });
            try caps.put(allocator, "prompts", .{ .object = prompts_cap });
        }
        if (self.capabilities.logging != null) {
            try caps.put(allocator, "logging", .{ .object = .empty });
        }
        if (self.capabilities.completions != null) {
            try caps.put(allocator, "completions", .{ .object = .empty });
        }
        if (self.capabilities.tasks != null) {
            var tasks_cap: std.json.ObjectMap = .empty;
            try tasks_cap.put(allocator, "list", .{ .object = .empty });
            try tasks_cap.put(allocator, "cancel", .{ .object = .empty });
            var requests_cap: std.json.ObjectMap = .empty;
            var tools_req: std.json.ObjectMap = .empty;
            try tools_req.put(allocator, "call", .{ .object = .empty });
            try requests_cap.put(allocator, "tools", .{ .object = tools_req });
            try tasks_cap.put(allocator, "requests", .{ .object = requests_cap });
            try caps.put(allocator, "tasks", .{ .object = tasks_cap });
        }
        try result.put(allocator, "capabilities", .{ .object = caps });

        var server_info: std.json.ObjectMap = .empty;
        try server_info.put(allocator, "name", .{ .string = self.config.name });
        try server_info.put(allocator, "version", .{ .string = self.config.version });
        if (self.config.title) |t| {
            try server_info.put(allocator, "title", .{ .string = t });
        }
        if (self.config.description) |d| {
            try server_info.put(allocator, "description", .{ .string = d });
        }
        if (self.config.websiteUrl) |u| {
            try server_info.put(allocator, "websiteUrl", .{ .string = u });
        }
        try result.put(allocator, "serverInfo", .{ .object = server_info });

        if (self.config.instructions) |inst| {
            try result.put(allocator, "instructions", .{ .string = inst });
        }

        const response = jsonrpc.createResponse(request.id, .{ .object = result });
        try self.sendResponse(io, allocator, .{ .response = response });
    }

    /// Handle ping request
    fn handlePing(self: *Self, io: std.Io, allocator: std.mem.Allocator, request: jsonrpc.Request) !void {
        var result: std.json.ObjectMap = .empty;
        defer result.deinit(allocator);

        const response = jsonrpc.createResponse(request.id, .{ .object = result });
        try self.sendResponse(io, allocator, .{ .response = response });
    }

    /// Handle tools/list request
    fn handleToolsList(self: *Self, io: std.Io, allocator: std.mem.Allocator, request: jsonrpc.Request) !void {
        var tools_array: std.json.Array = .init(allocator);

        var iter = self.tools.iterator();
        while (iter.next()) |entry| {
            var tool_obj: std.json.ObjectMap = .empty;
            try tool_obj.put(allocator, "name", .{ .string = entry.value_ptr.name });
            if (entry.value_ptr.description) |desc| {
                try tool_obj.put(allocator, "description", .{ .string = desc });
            }
            if (entry.value_ptr.title) |t| {
                try tool_obj.put(allocator, "title", .{ .string = t });
            }

            var input_schema: std.json.ObjectMap = .empty;
            try input_schema.put(allocator, "type", .{ .string = "object" });
            try tool_obj.put(allocator, "inputSchema", .{ .object = input_schema });

            if (entry.value_ptr.annotations) |ann| {
                var ann_obj: std.json.ObjectMap = .empty;
                if (ann.title) |t| try ann_obj.put(allocator, "title", .{ .string = t });
                try ann_obj.put(allocator, "readOnlyHint", .{ .bool = ann.readOnlyHint });
                try ann_obj.put(allocator, "destructiveHint", .{ .bool = ann.destructiveHint });
                try ann_obj.put(allocator, "idempotentHint", .{ .bool = ann.idempotentHint });
                try ann_obj.put(allocator, "openWorldHint", .{ .bool = ann.openWorldHint });
                try tool_obj.put(allocator, "annotations", .{ .object = ann_obj });
            }

            if (entry.value_ptr.execution) |exec| {
                var exec_obj: std.json.ObjectMap = .empty;
                if (exec.taskSupport) |ts| {
                    try exec_obj.put(allocator, "taskSupport", .{ .string = ts });
                }
                try tool_obj.put(allocator, "execution", .{ .object = exec_obj });
            }

            try tools_array.append(.{ .object = tool_obj });
        }

        var result: std.json.ObjectMap = .empty;
        try result.put(allocator, "tools", .{ .array = tools_array });

        const response = jsonrpc.createResponse(request.id, .{ .object = result });
        try self.sendResponse(io, allocator, .{ .response = response });
    }

    /// Handle tools/call request
    fn handleToolsCall(self: *Self, io: std.Io, allocator: std.mem.Allocator, request: jsonrpc.Request) !void {
        var tool_name: []const u8 = "";
        var arguments: ?std.json.Value = null;

        if (request.params) |params| {
            if (params == .object) {
                if (params.object.get("name")) |name_val| {
                    if (name_val == .string) {
                        tool_name = name_val.string;
                    }
                }
                arguments = params.object.get("arguments");
            }
        }

        if (self.tools.get(tool_name)) |tool| {
            const tool_result = tool.handler(allocator, arguments) catch |err| {
                var content_array: std.json.Array = .init(allocator);
                var text_obj: std.json.ObjectMap = .empty;
                try text_obj.put(allocator, "type", .{ .string = "text" });
                try text_obj.put(allocator, "text", .{ .string = @errorName(err) });
                try content_array.append(.{ .object = text_obj });

                var result: std.json.ObjectMap = .empty;
                try result.put(allocator, "content", .{ .array = content_array });
                try result.put(allocator, "isError", .{ .bool = true });

                const response = jsonrpc.createResponse(request.id, .{ .object = result });
                try self.sendResponse(io, allocator, .{ .response = response });
                return;
            };

            var content_array: std.json.Array = .init(allocator);
            for (tool_result.content) |content_item| {
                var item_obj: std.json.ObjectMap = .empty;
                switch (content_item) {
                    .text => |text| {
                        try item_obj.put(allocator, "type", .{ .string = "text" });
                        try item_obj.put(allocator, "text", .{ .string = text.text });
                    },
                    .image => |img| {
                        try item_obj.put(allocator, "type", .{ .string = "image" });
                        try item_obj.put(allocator, "data", .{ .string = img.data });
                        try item_obj.put(allocator, "mimeType", .{ .string = img.mimeType });
                    },
                    .audio => |aud| {
                        try item_obj.put(allocator, "type", .{ .string = "audio" });
                        try item_obj.put(allocator, "data", .{ .string = aud.data });
                        try item_obj.put(allocator, "mimeType", .{ .string = aud.mimeType });
                    },
                    .resource_link => |link| {
                        try item_obj.put(allocator, "type", .{ .string = "resource_link" });
                        try item_obj.put(allocator, "uri", .{ .string = link.uri });
                        try item_obj.put(allocator, "name", .{ .string = link.name });
                        if (link.title) |t| try item_obj.put(allocator, "title", .{ .string = t });
                        if (link.description) |d| try item_obj.put(allocator, "description", .{ .string = d });
                        if (link.mimeType) |m| try item_obj.put(allocator, "mimeType", .{ .string = m });
                    },
                    .resource => |res| {
                        try item_obj.put(allocator, "type", .{ .string = "resource" });
                        var res_obj: std.json.ObjectMap = .empty;
                        try res_obj.put(allocator, "uri", .{ .string = res.resource.uri });
                        if (res.resource.text) |text| try res_obj.put(allocator, "text", .{ .string = text });
                        if (res.resource.mimeType) |mime| try res_obj.put(allocator, "mimeType", .{ .string = mime });
                        try item_obj.put(allocator, "resource", .{ .object = res_obj });
                    },
                }
                try content_array.append(.{ .object = item_obj });
            }

            var result: std.json.ObjectMap = .empty;
            try result.put(allocator, "content", .{ .array = content_array });
            try result.put(allocator, "isError", .{ .bool = tool_result.is_error });
            if (tool_result.structuredContent) |sc| {
                try result.put(allocator, "structuredContent", sc);
            }

            const response = jsonrpc.createResponse(request.id, .{ .object = result });
            try self.sendResponse(io, allocator, .{ .response = response });
        } else {
            const error_response = jsonrpc.createInvalidParams(request.id, "Tool not found");
            try self.sendResponse(io, allocator, .{ .error_response = error_response });
        }
    }

    /// Handle resources/list request
    fn handleResourcesList(self: *Self, io: std.Io, allocator: std.mem.Allocator, request: jsonrpc.Request) !void {
        var resources_array: std.json.Array = .init(allocator);

        var iter = self.resources.iterator();
        while (iter.next()) |entry| {
            var resource_obj: std.json.ObjectMap = .empty;
            try resource_obj.put(allocator, "uri", .{ .string = entry.value_ptr.uri });
            try resource_obj.put(allocator, "name", .{ .string = entry.value_ptr.name });
            if (entry.value_ptr.title) |t| {
                try resource_obj.put(allocator, "title", .{ .string = t });
            }
            if (entry.value_ptr.description) |desc| {
                try resource_obj.put(allocator, "description", .{ .string = desc });
            }
            if (entry.value_ptr.mimeType) |mime| {
                try resource_obj.put(allocator, "mimeType", .{ .string = mime });
            }
            if (entry.value_ptr.size) |s| {
                try resource_obj.put(allocator, "size", .{ .integer = @intCast(s) });
            }
            try resources_array.append(.{ .object = resource_obj });
        }

        var result: std.json.ObjectMap = .empty;
        try result.put(allocator, "resources", .{ .array = resources_array });

        const response = jsonrpc.createResponse(request.id, .{ .object = result });
        try self.sendResponse(io, allocator, .{ .response = response });
    }

    /// Handle resources/read request
    fn handleResourcesRead(self: *Self, io: std.Io, allocator: std.mem.Allocator, request: jsonrpc.Request) !void {
        var uri: []const u8 = "";

        if (request.params) |params| {
            if (params == .object) {
                if (params.object.get("uri")) |uri_val| {
                    if (uri_val == .string) {
                        uri = uri_val.string;
                    }
                }
            }
        }

        if (self.resources.get(uri)) |resource| {
            const content = resource.handler(allocator, uri) catch |err| {
                const error_response = jsonrpc.createInternalError(request.id, .{ .string = @errorName(err) });
                try self.sendResponse(io, allocator, .{ .error_response = error_response });
                return;
            };

            var contents_array: std.json.Array = .init(allocator);
            var content_obj: std.json.ObjectMap = .empty;
            try content_obj.put(allocator, "uri", .{ .string = uri });
            if (content.text) |text| {
                try content_obj.put(allocator, "text", .{ .string = text });
            }
            if (content.blob) |blob| {
                try content_obj.put(allocator, "blob", .{ .string = blob });
            }
            if (content.mimeType) |mime| {
                try content_obj.put(allocator, "mimeType", .{ .string = mime });
            }
            try contents_array.append(.{ .object = content_obj });

            var result: std.json.ObjectMap = .empty;
            try result.put(allocator, "contents", .{ .array = contents_array });

            const response = jsonrpc.createResponse(request.id, .{ .object = result });
            try self.sendResponse(io, allocator, .{ .response = response });
        } else {
            const error_response = jsonrpc.createInvalidParams(request.id, "Resource not found");
            try self.sendResponse(io, allocator, .{ .error_response = error_response });
        }
    }

    /// Handle resources/templates/list request
    fn handleResourceTemplatesList(self: *Self, io: std.Io, allocator: std.mem.Allocator, request: jsonrpc.Request) !void {
        var templates_array: std.json.Array = .init(allocator);

        var iter = self.resource_templates.iterator();
        while (iter.next()) |entry| {
            var template_obj: std.json.ObjectMap = .empty;
            try template_obj.put(allocator, "uriTemplate", .{ .string = entry.value_ptr.uriTemplate });
            try template_obj.put(allocator, "name", .{ .string = entry.value_ptr.name });
            if (entry.value_ptr.title) |t| {
                try template_obj.put(allocator, "title", .{ .string = t });
            }
            if (entry.value_ptr.description) |desc| {
                try template_obj.put(allocator, "description", .{ .string = desc });
            }
            if (entry.value_ptr.mimeType) |mime| {
                try template_obj.put(allocator, "mimeType", .{ .string = mime });
            }
            try templates_array.append(.{ .object = template_obj });
        }

        var result: std.json.ObjectMap = .empty;
        try result.put(allocator, "resourceTemplates", .{ .array = templates_array });

        const response = jsonrpc.createResponse(request.id, .{ .object = result });
        try self.sendResponse(io, allocator, .{ .response = response });
    }

    /// Handle resources/subscribe request
    fn handleSubscribe(self: *Self, io: std.Io, allocator: std.mem.Allocator, request: jsonrpc.Request) !void {
        _ = request.params;
        var result: std.json.ObjectMap = .empty;
        defer result.deinit(allocator);
        const response = jsonrpc.createResponse(request.id, .{ .object = result });
        try self.sendResponse(io, allocator, .{ .response = response });
    }

    /// Handle resources/unsubscribe request
    fn handleUnsubscribe(self: *Self, io: std.Io, allocator: std.mem.Allocator, request: jsonrpc.Request) !void {
        _ = request.params;
        var result: std.json.ObjectMap = .empty;
        defer result.deinit(allocator);
        const response = jsonrpc.createResponse(request.id, .{ .object = result });
        try self.sendResponse(io, allocator, .{ .response = response });
    }

    /// Handle prompts/list request
    fn handlePromptsList(self: *Self, io: std.Io, allocator: std.mem.Allocator, request: jsonrpc.Request) !void {
        var prompts_array: std.json.Array = .init(allocator);

        var iter = self.prompts.iterator();
        while (iter.next()) |entry| {
            var prompt_obj: std.json.ObjectMap = .empty;
            try prompt_obj.put(allocator, "name", .{ .string = entry.value_ptr.name });
            if (entry.value_ptr.description) |desc| {
                try prompt_obj.put(allocator, "description", .{ .string = desc });
            }
            if (entry.value_ptr.title) |t| {
                try prompt_obj.put(allocator, "title", .{ .string = t });
            }

            if (entry.value_ptr.arguments) |args| {
                var args_array: std.json.Array = .init(allocator);
                for (args) |arg| {
                    var arg_obj: std.json.ObjectMap = .empty;
                    try arg_obj.put(allocator, "name", .{ .string = arg.name });
                    if (arg.title) |t| {
                        try arg_obj.put(allocator, "title", .{ .string = t });
                    }
                    if (arg.description) |d| {
                        try arg_obj.put(allocator, "description", .{ .string = d });
                    }
                    try arg_obj.put(allocator, "required", .{ .bool = arg.required });
                    try args_array.append(.{ .object = arg_obj });
                }
                try prompt_obj.put(allocator, "arguments", .{ .array = args_array });
            }

            try prompts_array.append(.{ .object = prompt_obj });
        }

        var result: std.json.ObjectMap = .empty;
        try result.put(allocator, "prompts", .{ .array = prompts_array });

        const response = jsonrpc.createResponse(request.id, .{ .object = result });
        try self.sendResponse(io, allocator, .{ .response = response });
    }

    /// Handle prompts/get request
    fn handlePromptsGet(self: *Self, io: std.Io, allocator: std.mem.Allocator, request: jsonrpc.Request) !void {
        var prompt_name: []const u8 = "";
        var arguments: ?std.json.Value = null;

        if (request.params) |params| {
            if (params == .object) {
                if (params.object.get("name")) |name_val| {
                    if (name_val == .string) {
                        prompt_name = name_val.string;
                    }
                }
                arguments = params.object.get("arguments");
            }
        }

        if (self.prompts.get(prompt_name)) |prompt| {
            const messages = prompt.handler(allocator, arguments) catch |err| {
                const error_response = jsonrpc.createInternalError(request.id, .{ .string = @errorName(err) });
                try self.sendResponse(io, allocator, .{ .error_response = error_response });
                return;
            };

            var messages_array: std.json.Array = .init(allocator);
            for (messages) |msg| {
                var msg_obj: std.json.ObjectMap = .empty;
                try msg_obj.put(allocator, "role", .{ .string = msg.role.toString() });
                var content_obj: std.json.ObjectMap = .empty;
                switch (msg.content) {
                    .text => |text| {
                        try content_obj.put(allocator, "type", .{ .string = "text" });
                        try content_obj.put(allocator, "text", .{ .string = text.text });
                    },
                    .image => |img| {
                        try content_obj.put(allocator, "type", .{ .string = "image" });
                        try content_obj.put(allocator, "data", .{ .string = img.data });
                        try content_obj.put(allocator, "mimeType", .{ .string = img.mimeType });
                    },
                    .audio => |aud| {
                        try content_obj.put(allocator, "type", .{ .string = "audio" });
                        try content_obj.put(allocator, "data", .{ .string = aud.data });
                        try content_obj.put(allocator, "mimeType", .{ .string = aud.mimeType });
                    },
                    .resource_link => |link| {
                        try content_obj.put(allocator, "type", .{ .string = "resource_link" });
                        try content_obj.put(allocator, "uri", .{ .string = link.uri });
                        try content_obj.put(allocator, "name", .{ .string = link.name });
                    },
                    .resource => |res| {
                        try content_obj.put(allocator, "type", .{ .string = "resource" });
                        var res_inner: std.json.ObjectMap = .empty;
                        try res_inner.put(allocator, "uri", .{ .string = res.resource.uri });
                        if (res.resource.text) |text| try res_inner.put(allocator, "text", .{ .string = text });
                        try content_obj.put(allocator, "resource", .{ .object = res_inner });
                    },
                }
                try msg_obj.put(allocator, "content", .{ .object = content_obj });
                try messages_array.append(.{ .object = msg_obj });
            }

            var result: std.json.ObjectMap = .empty;
            try result.put(allocator, "messages", .{ .array = messages_array });
            if (prompt.description) |desc| {
                try result.put(allocator, "description", .{ .string = desc });
            }

            const response = jsonrpc.createResponse(request.id, .{ .object = result });
            try self.sendResponse(io, allocator, .{ .response = response });
        } else {
            const error_response = jsonrpc.createInvalidParams(request.id, "Prompt not found");
            try self.sendResponse(io, allocator, .{ .error_response = error_response });
        }
    }

    /// Handle logging/setLevel request
    fn handleSetLogLevel(self: *Self, io: std.Io, allocator: std.mem.Allocator, request: jsonrpc.Request) !void {
        if (request.params) |params| {
            if (params == .object) {
                if (params.object.get("level")) |level_val| {
                    if (level_val == .string) {
                        const level_str = level_val.string;
                        if (std.mem.eql(u8, level_str, "debug")) {
                            self.log_level = .debug;
                        } else if (std.mem.eql(u8, level_str, "info")) {
                            self.log_level = .info;
                        } else if (std.mem.eql(u8, level_str, "notice")) {
                            self.log_level = .notice;
                        } else if (std.mem.eql(u8, level_str, "warning")) {
                            self.log_level = .warning;
                        } else if (std.mem.eql(u8, level_str, "error")) {
                            self.log_level = .@"error";
                        } else if (std.mem.eql(u8, level_str, "critical")) {
                            self.log_level = .critical;
                        } else if (std.mem.eql(u8, level_str, "alert")) {
                            self.log_level = .alert;
                        } else if (std.mem.eql(u8, level_str, "emergency")) {
                            self.log_level = .emergency;
                        }
                    }
                }
            }
        }

        const result: std.json.ObjectMap = .empty;
        const response = jsonrpc.createResponse(request.id, .{ .object = result });
        try self.sendResponse(io, allocator, .{ .response = response });
    }

    /// Handle completion/complete request
    fn handleCompletion(self: *Self, io: std.Io, allocator: std.mem.Allocator, request: jsonrpc.Request) !void {
        var completion: std.json.ObjectMap = .empty;
        const values_array: std.json.Array = .init(allocator);
        try completion.put(allocator, "values", .{ .array = values_array });
        try completion.put(allocator, "hasMore", .{ .bool = false });

        var result: std.json.ObjectMap = .empty;
        try result.put(allocator, "completion", .{ .object = completion });

        const response = jsonrpc.createResponse(request.id, .{ .object = result });
        try self.sendResponse(io, allocator, .{ .response = response });
    }

    /// Handle tasks/get request
    fn handleTasksGet(self: *Self, io: std.Io, allocator: std.mem.Allocator, request: jsonrpc.Request) !void {
        _ = request.params;
        const error_response = jsonrpc.createMethodNotFound(request.id, "tasks/get");
        try self.sendResponse(io, allocator, .{ .error_response = error_response });
    }

    /// Handle tasks/result request
    fn handleTasksResult(self: *Self, io: std.Io, allocator: std.mem.Allocator, request: jsonrpc.Request) !void {
        _ = request.params;
        const error_response = jsonrpc.createMethodNotFound(request.id, "tasks/result");
        try self.sendResponse(io, allocator, .{ .error_response = error_response });
    }

    /// Handle tasks/list request
    fn handleTasksList(self: *Self, io: std.Io, allocator: std.mem.Allocator, request: jsonrpc.Request) !void {
        var result: std.json.ObjectMap = .empty;
        const tasks_array: std.json.Array = .init(allocator);
        try result.put(allocator, "tasks", .{ .array = tasks_array });

        const response = jsonrpc.createResponse(request.id, .{ .object = result });
        try self.sendResponse(io, allocator, .{ .response = response });
    }

    /// Handle tasks/cancel request
    fn handleTasksCancel(self: *Self, io: std.Io, allocator: std.mem.Allocator, request: jsonrpc.Request) !void {
        _ = request.params;
        const error_response = jsonrpc.createMethodNotFound(request.id, "tasks/cancel");
        try self.sendResponse(io, allocator, .{ .error_response = error_response });
    }

    /// Handle incoming notifications
    fn handleNotification(self: *Self, io: std.Io, notification: jsonrpc.Notification) !void {
        if (std.mem.eql(u8, notification.method, "notifications/initialized")) {
            self.state = .ready;
            self.log(io, "Server initialized and ready");
        } else if (std.mem.eql(u8, notification.method, "notifications/cancelled")) {
            if (notification.params) |params| {
                if (params == .object) {
                    if (params.object.get("requestId")) |req_id| {
                        _ = req_id;
                    }
                }
            }
        } else if (std.mem.eql(u8, notification.method, "notifications/roots/list_changed")) {
            self.log(io, "Roots list changed");
        }
    }

    /// Handle incoming response to a request we sent
    fn handleResponse(self: *Self, response: jsonrpc.Response) void {
        const id = switch (response.id) {
            .integer => |i| i,
            .string => return,
        };
        _ = self.pending_requests.remove(id);
    }

    /// Handle incoming error response
    fn handleErrorResponse(self: *Self, io: std.Io, err: jsonrpc.ErrorResponse) void {
        if (err.id) |id| {
            const int_id = switch (id) {
                .integer => |i| i,
                .string => return,
            };
            _ = self.pending_requests.remove(int_id);
        }
        self.logError(io, err.@"error".message);
    }

    /// Send a notification to the client
    pub fn sendNotification(self: *Self, io: std.Io, allocator: std.mem.Allocator, method: []const u8, params: ?std.json.Value) !void {
        const notification = jsonrpc.createNotification(method, params);
        try self.sendResponse(io, allocator, .{ .notification = notification });
    }

    /// Send a log message notification
    pub fn sendLogMessage(self: *Self, io: std.Io, allocator: std.mem.Allocator, level: protocol.LogLevel, message: []const u8) !void {
        if (@intFromEnum(level) < @intFromEnum(self.log_level)) return;

        var params: std.json.ObjectMap = .empty;
        try params.put(allocator, "level", .{ .string = level.toString() });
        try params.put(allocator, "data", .{ .string = message });

        try self.sendNotification(io, allocator, "notifications/message", .{ .object = params });
    }

    /// Send a progress notification
    pub fn sendProgress(self: *Self, io: std.Io, allocator: std.mem.Allocator, token: std.json.Value, prog: f64, total: ?f64, message: ?[]const u8) !void {
        var params: std.json.ObjectMap = .empty;
        try params.put(allocator, "progressToken", token);
        try params.put(allocator, "progress", .{ .float = prog });
        if (total) |t| {
            try params.put(allocator, "total", .{ .float = t });
        }
        if (message) |m| {
            try params.put(allocator, "message", .{ .string = m });
        }
        try self.sendNotification(io, allocator, "notifications/progress", .{ .object = params });
    }

    /// Notify clients that tools have changed
    pub fn notifyToolsChanged(self: *Self, io: std.Io, allocator: std.mem.Allocator) !void {
        try self.sendNotification(io, allocator, "notifications/tools/list_changed", null);
    }

    /// Notify clients that resources have changed
    pub fn notifyResourcesChanged(self: *Self, io: std.Io, allocator: std.mem.Allocator) !void {
        try self.sendNotification(io, allocator, "notifications/resources/list_changed", null);
    }

    /// Notify clients that a resource has been updated
    pub fn notifyResourceUpdated(self: *Self, io: std.Io, allocator: std.mem.Allocator, uri: []const u8) !void {
        var params: std.json.ObjectMap = .empty;
        try params.put(allocator, "uri", .{ .string = uri });
        try self.sendNotification(io, allocator, "notifications/resources/updated", .{ .object = params });
    }

    /// Notify clients that prompts have changed
    pub fn notifyPromptsChanged(self: *Self, io: std.Io, allocator: std.mem.Allocator) !void {
        try self.sendNotification(io, allocator, "notifications/prompts/list_changed", null);
    }

    /// Send a response message
    fn sendResponse(self: *Self, io: std.Io, allocator: std.mem.Allocator, message: jsonrpc.Message) !void {
        if (self.transport) |t| {
            const json = jsonrpc.serializeMessage(allocator, message) catch {
                self.logError(io, "Failed to serialize response");
                return;
            };
            defer allocator.free(json);
            t.send(io, allocator, json) catch {
                self.logError(io, "Failed to send response");
                return;
            };
        }
    }

    fn log(self: *Self, io: std.Io, message: []const u8) void {
        if (self.stdio_transport) |t| {
            t.writeStderr(io, message);
        }
    }

    fn logError(self: *Self, io: std.Io, message: []const u8) void {
        if (self.stdio_transport) |t| {
            var buf: [512]u8 = undefined;
            const formatted = std.fmt.bufPrint(&buf, "ERROR: {s}", .{message}) catch message;
            t.writeStderr(io, formatted);
        }
    }
};

test "Server initialization" {
    var server: Server = .init(std.testing.allocator, .{
        .name = "test-server",
        .version = "1.0.0",
    });
    defer server.deinit();

    try std.testing.expectEqual(ServerState.uninitialized, server.state);
    try std.testing.expectEqualStrings("test-server", server.config.name);
}

test "Server add tool" {
    var server: Server = .init(std.testing.allocator, .{
        .name = "test-server",
        .version = "1.0.0",
    });
    defer server.deinit();

    const tool: tools_mod.Tool = .{
        .name = "test_tool",
        .description = "A test tool",
        .handler = struct {
            fn handler(_: std.mem.Allocator, _: ?std.json.Value) !tools_mod.ToolResult {
                return .{ .content = &.{} };
            }
        }.handler,
    };

    try server.addTool(tool);
    try std.testing.expect(server.tools.contains("test_tool"));
    try std.testing.expect(server.capabilities.tools != null);
}

test "Server add resource" {
    var server: Server = .init(std.testing.allocator, .{
        .name = "test-server",
        .version = "1.0.0",
    });
    defer server.deinit();

    try server.addResource(.{
        .uri = "file:///test",
        .name = "Test",
        .handler = struct {
            fn handler(_: std.mem.Allocator, uri: []const u8) !resources_mod.ResourceContent {
                return .{ .uri = uri };
            }
        }.handler,
    });
    try std.testing.expect(server.resources.contains("file:///test"));
    try std.testing.expect(server.capabilities.resources != null);
}

test "Server add prompt" {
    var server: Server = .init(std.testing.allocator, .{
        .name = "test-server",
        .version = "1.0.0",
    });
    defer server.deinit();

    try server.addPrompt(.{
        .name = "test_prompt",
        .description = "A test prompt",
        .handler = struct {
            fn handler(_: std.mem.Allocator, _: ?std.json.Value) ![]const prompts_mod.PromptMessage {
                return &.{};
            }
        }.handler,
    });
    try std.testing.expect(server.prompts.contains("test_prompt"));
    try std.testing.expect(server.capabilities.prompts != null);
}

test "Server enable capabilities" {
    var server: Server = .init(std.testing.allocator, .{
        .name = "test-server",
        .version = "1.0.0",
    });
    defer server.deinit();

    server.enableLogging();
    server.enableCompletions();
    server.enableTasks();

    try std.testing.expect(server.capabilities.logging != null);
    try std.testing.expect(server.capabilities.completions != null);
    try std.testing.expect(server.capabilities.tasks != null);
}
