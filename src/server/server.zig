//! MCP Server Implementation (Spec 2025-11-25)
//!
//! Provides the main MCP Server that handles client connections, protocol
//! negotiation, capability advertisement, and request routing for tools,
//! resources, prompts, tasks, and all standard MCP methods.

const std = @import("std");
const protocol = @import("../protocol/protocol.zig");
const jsonrpc = @import("../protocol/jsonrpc.zig");
const types = @import("../protocol/types.zig");
const transport_mod = @import("../transport/transport.zig");
const tools_mod = @import("tools.zig");
const resources_mod = @import("resources.zig");
const prompts_mod = @import("prompts.zig");

/// Configuration for an MCP Server
pub const ServerConfig = struct {
    name: []const u8,
    version: []const u8,
    title: ?[]const u8 = null,
    description: ?[]const u8 = null,
    icons: ?[]const types.Icon = null,
    websiteUrl: ?[]const u8 = null,
    instructions: ?[]const u8 = null,
    allocator: std.mem.Allocator = std.heap.page_allocator,
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
    allocator: std.mem.Allocator,
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

    const Self = @This();

    pub const PendingRequest = struct {
        method: []const u8,
        timestamp: i64,
    };

    /// Initialize a new MCP Server
    pub fn init(config: ServerConfig) Self {
        const allocator = config.allocator;
        return .{
            .config = config,
            .allocator = allocator,
            .tools = std.StringHashMap(tools_mod.Tool).init(allocator),
            .resources = std.StringHashMap(resources_mod.Resource).init(allocator),
            .resource_templates = std.StringHashMap(resources_mod.ResourceTemplate).init(allocator),
            .prompts = std.StringHashMap(prompts_mod.Prompt).init(allocator),
            .pending_requests = std.AutoHashMap(i64, PendingRequest).init(allocator),
        };
    }

    /// Clean up server resources
    pub fn deinit(self: *Self) void {
        self.tools.deinit();
        self.resources.deinit();
        self.resource_templates.deinit();
        self.prompts.deinit();
        self.pending_requests.deinit();

        if (self.stdio_transport) |t| {
            t.deinit();
            self.allocator.destroy(t);
        }
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
    pub const RunOptions = union(enum) {
        stdio: void,
        http: struct { port: u16 = 8080, host: []const u8 = "localhost" },
    };

    /// Run the server with the specified transport
    pub fn run(self: *Self, options: RunOptions) !void {
        switch (options) {
            .stdio => {
                self.log("Server listening on STDIO");
                const stdio = try self.allocator.create(transport_mod.StdioTransport);
                stdio.* = transport_mod.StdioTransport.init(self.allocator);
                self.stdio_transport = stdio;
                self.transport = stdio.transport();
                try self.messageLoop();
            },
            .http => |config| {
                const url = try std.fmt.allocPrint(self.allocator, "http://{s}:{d}", .{ config.host, config.port });
                defer self.allocator.free(url);

                std.log.info("Server listening on {s}", .{url});

                const http = try self.allocator.create(transport_mod.HttpTransport);
                http.* = try transport_mod.HttpTransport.init(self.allocator, url);
                self.transport = http.transport();
                try self.messageLoop();
            },
        }
    }

    /// Run the server with a custom transport
    pub fn runWithTransport(self: *Self, t: transport_mod.Transport) !void {
        self.transport = t;
        try self.messageLoop();
    }

    /// Main message processing loop
    fn messageLoop(self: *Self) !void {
        while (self.state != .stopped and self.state != .shutting_down) {
            const message_data = self.transport.?.receive() catch |err| {
                switch (err) {
                    error.EndOfStream => {
                        self.state = .shutting_down;
                        break;
                    },
                    else => {
                        self.logError("Transport receive error");
                        continue;
                    },
                }
            };

            if (message_data) |data| {
                try self.handleMessage(data);
            }
        }

        self.state = .stopped;
    }

    /// Handle an incoming message
    fn handleMessage(self: *Self, data: []const u8) !void {
        const parsed_message = jsonrpc.parseMessage(self.allocator, data) catch {
            const error_response = jsonrpc.createParseError(null);
            try self.sendResponse(.{ .error_response = error_response });
            return;
        };
        defer parsed_message.deinit();

        switch (parsed_message.message) {
            .request => |req| try self.handleRequest(req),
            .notification => |notif| try self.handleNotification(notif),
            .response => |resp| self.handleResponse(resp),
            .error_response => |err| self.handleErrorResponse(err),
        }
    }

    /// Handle an incoming request
    fn handleRequest(self: *Self, request: jsonrpc.Request) !void {
        var buf: [256]u8 = undefined;
        if (std.fmt.bufPrint(&buf, "Received request: {s}", .{request.method})) |msg| {
            self.log(msg);
        } else |_| {}

        if (self.state == .uninitialized and !std.mem.eql(u8, request.method, "initialize")) {
            const error_response = jsonrpc.createErrorResponse(
                request.id,
                jsonrpc.ErrorCode.SERVER_NOT_INITIALIZED,
                "Server not initialized",
                null,
            );
            try self.sendResponse(.{ .error_response = error_response });
            return;
        }

        if (std.mem.eql(u8, request.method, "initialize")) {
            try self.handleInitialize(request);
        } else if (std.mem.eql(u8, request.method, "ping")) {
            try self.handlePing(request);
        } else if (std.mem.eql(u8, request.method, "tools/list")) {
            try self.handleToolsList(request);
        } else if (std.mem.eql(u8, request.method, "tools/call")) {
            try self.handleToolsCall(request);
        } else if (std.mem.eql(u8, request.method, "resources/list")) {
            try self.handleResourcesList(request);
        } else if (std.mem.eql(u8, request.method, "resources/read")) {
            try self.handleResourcesRead(request);
        } else if (std.mem.eql(u8, request.method, "resources/templates/list")) {
            try self.handleResourceTemplatesList(request);
        } else if (std.mem.eql(u8, request.method, "resources/subscribe")) {
            try self.handleSubscribe(request);
        } else if (std.mem.eql(u8, request.method, "resources/unsubscribe")) {
            try self.handleUnsubscribe(request);
        } else if (std.mem.eql(u8, request.method, "prompts/list")) {
            try self.handlePromptsList(request);
        } else if (std.mem.eql(u8, request.method, "prompts/get")) {
            try self.handlePromptsGet(request);
        } else if (std.mem.eql(u8, request.method, "logging/setLevel")) {
            try self.handleSetLogLevel(request);
        } else if (std.mem.eql(u8, request.method, "completion/complete")) {
            try self.handleCompletion(request);
        } else if (std.mem.eql(u8, request.method, "tasks/get")) {
            try self.handleTasksGet(request);
        } else if (std.mem.eql(u8, request.method, "tasks/result")) {
            try self.handleTasksResult(request);
        } else if (std.mem.eql(u8, request.method, "tasks/list")) {
            try self.handleTasksList(request);
        } else if (std.mem.eql(u8, request.method, "tasks/cancel")) {
            try self.handleTasksCancel(request);
        } else {
            const error_response = jsonrpc.createMethodNotFound(request.id, request.method);
            try self.sendResponse(.{ .error_response = error_response });
        }
    }

    /// Handle initialize request
    fn handleInitialize(self: *Self, request: jsonrpc.Request) !void {
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

        var result = std.json.ObjectMap.init(self.allocator);
        defer result.deinit();

        try result.put("protocolVersion", .{ .string = protocol.VERSION });

        var caps = std.json.ObjectMap.init(self.allocator);
        if (self.capabilities.tools) |t| {
            var tools_cap = std.json.ObjectMap.init(self.allocator);
            try tools_cap.put("listChanged", .{ .bool = t.listChanged });
            try caps.put("tools", .{ .object = tools_cap });
        }
        if (self.capabilities.resources) |r| {
            var res_cap = std.json.ObjectMap.init(self.allocator);
            try res_cap.put("listChanged", .{ .bool = r.listChanged });
            try res_cap.put("subscribe", .{ .bool = r.subscribe });
            try caps.put("resources", .{ .object = res_cap });
        }
        if (self.capabilities.prompts) |p| {
            var prompts_cap = std.json.ObjectMap.init(self.allocator);
            try prompts_cap.put("listChanged", .{ .bool = p.listChanged });
            try caps.put("prompts", .{ .object = prompts_cap });
        }
        if (self.capabilities.logging != null) {
            try caps.put("logging", .{ .object = std.json.ObjectMap.init(self.allocator) });
        }
        if (self.capabilities.completions != null) {
            try caps.put("completions", .{ .object = std.json.ObjectMap.init(self.allocator) });
        }
        if (self.capabilities.tasks != null) {
            var tasks_cap = std.json.ObjectMap.init(self.allocator);
            try tasks_cap.put("list", .{ .object = std.json.ObjectMap.init(self.allocator) });
            try tasks_cap.put("cancel", .{ .object = std.json.ObjectMap.init(self.allocator) });
            var requests_cap = std.json.ObjectMap.init(self.allocator);
            var tools_req = std.json.ObjectMap.init(self.allocator);
            try tools_req.put("call", .{ .object = std.json.ObjectMap.init(self.allocator) });
            try requests_cap.put("tools", .{ .object = tools_req });
            try tasks_cap.put("requests", .{ .object = requests_cap });
            try caps.put("tasks", .{ .object = tasks_cap });
        }
        try result.put("capabilities", .{ .object = caps });

        var server_info = std.json.ObjectMap.init(self.allocator);
        try server_info.put("name", .{ .string = self.config.name });
        try server_info.put("version", .{ .string = self.config.version });
        if (self.config.title) |t| {
            try server_info.put("title", .{ .string = t });
        }
        if (self.config.description) |d| {
            try server_info.put("description", .{ .string = d });
        }
        if (self.config.websiteUrl) |u| {
            try server_info.put("websiteUrl", .{ .string = u });
        }
        try result.put("serverInfo", .{ .object = server_info });

        if (self.config.instructions) |inst| {
            try result.put("instructions", .{ .string = inst });
        }

        const response = jsonrpc.createResponse(request.id, .{ .object = result });
        try self.sendResponse(.{ .response = response });
    }

    /// Handle ping request
    fn handlePing(self: *Self, request: jsonrpc.Request) !void {
        var result = std.json.ObjectMap.init(self.allocator);
        defer result.deinit();

        const response = jsonrpc.createResponse(request.id, .{ .object = result });
        try self.sendResponse(.{ .response = response });
    }

    /// Handle tools/list request
    fn handleToolsList(self: *Self, request: jsonrpc.Request) !void {
        var tools_array = std.json.Array.init(self.allocator);

        var iter = self.tools.iterator();
        while (iter.next()) |entry| {
            var tool_obj = std.json.ObjectMap.init(self.allocator);
            try tool_obj.put("name", .{ .string = entry.value_ptr.name });
            if (entry.value_ptr.description) |desc| {
                try tool_obj.put("description", .{ .string = desc });
            }
            if (entry.value_ptr.title) |t| {
                try tool_obj.put("title", .{ .string = t });
            }

            var input_schema = std.json.ObjectMap.init(self.allocator);
            try input_schema.put("type", .{ .string = "object" });
            try tool_obj.put("inputSchema", .{ .object = input_schema });

            if (entry.value_ptr.annotations) |ann| {
                var ann_obj = std.json.ObjectMap.init(self.allocator);
                if (ann.title) |t| try ann_obj.put("title", .{ .string = t });
                try ann_obj.put("readOnlyHint", .{ .bool = ann.readOnlyHint });
                try ann_obj.put("destructiveHint", .{ .bool = ann.destructiveHint });
                try ann_obj.put("idempotentHint", .{ .bool = ann.idempotentHint });
                try ann_obj.put("openWorldHint", .{ .bool = ann.openWorldHint });
                try tool_obj.put("annotations", .{ .object = ann_obj });
            }

            if (entry.value_ptr.execution) |exec| {
                var exec_obj = std.json.ObjectMap.init(self.allocator);
                if (exec.taskSupport) |ts| {
                    try exec_obj.put("taskSupport", .{ .string = ts });
                }
                try tool_obj.put("execution", .{ .object = exec_obj });
            }

            try tools_array.append(.{ .object = tool_obj });
        }

        var result = std.json.ObjectMap.init(self.allocator);
        try result.put("tools", .{ .array = tools_array });

        const response = jsonrpc.createResponse(request.id, .{ .object = result });
        try self.sendResponse(.{ .response = response });
    }

    /// Handle tools/call request
    fn handleToolsCall(self: *Self, request: jsonrpc.Request) !void {
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
            const tool_result = tool.handler(self.allocator, arguments) catch |err| {
                var content_array = std.json.Array.init(self.allocator);
                var text_obj = std.json.ObjectMap.init(self.allocator);
                try text_obj.put("type", .{ .string = "text" });
                try text_obj.put("text", .{ .string = @errorName(err) });
                try content_array.append(.{ .object = text_obj });

                var result = std.json.ObjectMap.init(self.allocator);
                try result.put("content", .{ .array = content_array });
                try result.put("isError", .{ .bool = true });

                const response = jsonrpc.createResponse(request.id, .{ .object = result });
                try self.sendResponse(.{ .response = response });
                return;
            };

            var content_array = std.json.Array.init(self.allocator);
            for (tool_result.content) |content_item| {
                var item_obj = std.json.ObjectMap.init(self.allocator);
                switch (content_item) {
                    .text => |text| {
                        try item_obj.put("type", .{ .string = "text" });
                        try item_obj.put("text", .{ .string = text.text });
                    },
                    .image => |img| {
                        try item_obj.put("type", .{ .string = "image" });
                        try item_obj.put("data", .{ .string = img.data });
                        try item_obj.put("mimeType", .{ .string = img.mimeType });
                    },
                    .audio => |aud| {
                        try item_obj.put("type", .{ .string = "audio" });
                        try item_obj.put("data", .{ .string = aud.data });
                        try item_obj.put("mimeType", .{ .string = aud.mimeType });
                    },
                    .resource_link => |link| {
                        try item_obj.put("type", .{ .string = "resource_link" });
                        try item_obj.put("uri", .{ .string = link.uri });
                        try item_obj.put("name", .{ .string = link.name });
                        if (link.title) |t| try item_obj.put("title", .{ .string = t });
                        if (link.description) |d| try item_obj.put("description", .{ .string = d });
                        if (link.mimeType) |m| try item_obj.put("mimeType", .{ .string = m });
                    },
                    .resource => |res| {
                        try item_obj.put("type", .{ .string = "resource" });
                        var res_obj = std.json.ObjectMap.init(self.allocator);
                        try res_obj.put("uri", .{ .string = res.resource.uri });
                        if (res.resource.text) |text| try res_obj.put("text", .{ .string = text });
                        if (res.resource.mimeType) |mime| try res_obj.put("mimeType", .{ .string = mime });
                        try item_obj.put("resource", .{ .object = res_obj });
                    },
                }
                try content_array.append(.{ .object = item_obj });
            }

            var result = std.json.ObjectMap.init(self.allocator);
            try result.put("content", .{ .array = content_array });
            try result.put("isError", .{ .bool = tool_result.is_error });
            if (tool_result.structuredContent) |sc| {
                try result.put("structuredContent", sc);
            }

            const response = jsonrpc.createResponse(request.id, .{ .object = result });
            try self.sendResponse(.{ .response = response });
        } else {
            const error_response = jsonrpc.createInvalidParams(request.id, "Tool not found");
            try self.sendResponse(.{ .error_response = error_response });
        }
    }

    /// Handle resources/list request
    fn handleResourcesList(self: *Self, request: jsonrpc.Request) !void {
        var resources_array = std.json.Array.init(self.allocator);

        var iter = self.resources.iterator();
        while (iter.next()) |entry| {
            var resource_obj = std.json.ObjectMap.init(self.allocator);
            try resource_obj.put("uri", .{ .string = entry.value_ptr.uri });
            try resource_obj.put("name", .{ .string = entry.value_ptr.name });
            if (entry.value_ptr.title) |t| {
                try resource_obj.put("title", .{ .string = t });
            }
            if (entry.value_ptr.description) |desc| {
                try resource_obj.put("description", .{ .string = desc });
            }
            if (entry.value_ptr.mimeType) |mime| {
                try resource_obj.put("mimeType", .{ .string = mime });
            }
            if (entry.value_ptr.size) |s| {
                try resource_obj.put("size", .{ .integer = @intCast(s) });
            }
            try resources_array.append(.{ .object = resource_obj });
        }

        var result = std.json.ObjectMap.init(self.allocator);
        try result.put("resources", .{ .array = resources_array });

        const response = jsonrpc.createResponse(request.id, .{ .object = result });
        try self.sendResponse(.{ .response = response });
    }

    /// Handle resources/read request
    fn handleResourcesRead(self: *Self, request: jsonrpc.Request) !void {
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
            const content = resource.handler(self.allocator, uri) catch |err| {
                const error_response = jsonrpc.createInternalError(request.id, .{ .string = @errorName(err) });
                try self.sendResponse(.{ .error_response = error_response });
                return;
            };

            var contents_array = std.json.Array.init(self.allocator);
            var content_obj = std.json.ObjectMap.init(self.allocator);
            try content_obj.put("uri", .{ .string = uri });
            if (content.text) |text| {
                try content_obj.put("text", .{ .string = text });
            }
            if (content.blob) |blob| {
                try content_obj.put("blob", .{ .string = blob });
            }
            if (content.mimeType) |mime| {
                try content_obj.put("mimeType", .{ .string = mime });
            }
            try contents_array.append(.{ .object = content_obj });

            var result = std.json.ObjectMap.init(self.allocator);
            try result.put("contents", .{ .array = contents_array });

            const response = jsonrpc.createResponse(request.id, .{ .object = result });
            try self.sendResponse(.{ .response = response });
        } else {
            const error_response = jsonrpc.createInvalidParams(request.id, "Resource not found");
            try self.sendResponse(.{ .error_response = error_response });
        }
    }

    /// Handle resources/templates/list request
    fn handleResourceTemplatesList(self: *Self, request: jsonrpc.Request) !void {
        var templates_array = std.json.Array.init(self.allocator);

        var iter = self.resource_templates.iterator();
        while (iter.next()) |entry| {
            var template_obj = std.json.ObjectMap.init(self.allocator);
            try template_obj.put("uriTemplate", .{ .string = entry.value_ptr.uriTemplate });
            try template_obj.put("name", .{ .string = entry.value_ptr.name });
            if (entry.value_ptr.title) |t| {
                try template_obj.put("title", .{ .string = t });
            }
            if (entry.value_ptr.description) |desc| {
                try template_obj.put("description", .{ .string = desc });
            }
            if (entry.value_ptr.mimeType) |mime| {
                try template_obj.put("mimeType", .{ .string = mime });
            }
            try templates_array.append(.{ .object = template_obj });
        }

        var result = std.json.ObjectMap.init(self.allocator);
        try result.put("resourceTemplates", .{ .array = templates_array });

        const response = jsonrpc.createResponse(request.id, .{ .object = result });
        try self.sendResponse(.{ .response = response });
    }

    /// Handle resources/subscribe request
    fn handleSubscribe(self: *Self, request: jsonrpc.Request) !void {
        _ = request.params;
        var result = std.json.ObjectMap.init(self.allocator);
        defer result.deinit();
        const response = jsonrpc.createResponse(request.id, .{ .object = result });
        try self.sendResponse(.{ .response = response });
    }

    /// Handle resources/unsubscribe request
    fn handleUnsubscribe(self: *Self, request: jsonrpc.Request) !void {
        _ = request.params;
        var result = std.json.ObjectMap.init(self.allocator);
        defer result.deinit();
        const response = jsonrpc.createResponse(request.id, .{ .object = result });
        try self.sendResponse(.{ .response = response });
    }

    /// Handle prompts/list request
    fn handlePromptsList(self: *Self, request: jsonrpc.Request) !void {
        var prompts_array = std.json.Array.init(self.allocator);

        var iter = self.prompts.iterator();
        while (iter.next()) |entry| {
            var prompt_obj = std.json.ObjectMap.init(self.allocator);
            try prompt_obj.put("name", .{ .string = entry.value_ptr.name });
            if (entry.value_ptr.description) |desc| {
                try prompt_obj.put("description", .{ .string = desc });
            }
            if (entry.value_ptr.title) |t| {
                try prompt_obj.put("title", .{ .string = t });
            }

            if (entry.value_ptr.arguments) |args| {
                var args_array = std.json.Array.init(self.allocator);
                for (args) |arg| {
                    var arg_obj = std.json.ObjectMap.init(self.allocator);
                    try arg_obj.put("name", .{ .string = arg.name });
                    if (arg.title) |t| {
                        try arg_obj.put("title", .{ .string = t });
                    }
                    if (arg.description) |d| {
                        try arg_obj.put("description", .{ .string = d });
                    }
                    try arg_obj.put("required", .{ .bool = arg.required });
                    try args_array.append(.{ .object = arg_obj });
                }
                try prompt_obj.put("arguments", .{ .array = args_array });
            }

            try prompts_array.append(.{ .object = prompt_obj });
        }

        var result = std.json.ObjectMap.init(self.allocator);
        try result.put("prompts", .{ .array = prompts_array });

        const response = jsonrpc.createResponse(request.id, .{ .object = result });
        try self.sendResponse(.{ .response = response });
    }

    /// Handle prompts/get request
    fn handlePromptsGet(self: *Self, request: jsonrpc.Request) !void {
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
            const messages = prompt.handler(self.allocator, arguments) catch |err| {
                const error_response = jsonrpc.createInternalError(request.id, .{ .string = @errorName(err) });
                try self.sendResponse(.{ .error_response = error_response });
                return;
            };

            var messages_array = std.json.Array.init(self.allocator);
            for (messages) |msg| {
                var msg_obj = std.json.ObjectMap.init(self.allocator);
                try msg_obj.put("role", .{ .string = msg.role.toString() });
                var content_obj = std.json.ObjectMap.init(self.allocator);
                switch (msg.content) {
                    .text => |text| {
                        try content_obj.put("type", .{ .string = "text" });
                        try content_obj.put("text", .{ .string = text.text });
                    },
                    .image => |img| {
                        try content_obj.put("type", .{ .string = "image" });
                        try content_obj.put("data", .{ .string = img.data });
                        try content_obj.put("mimeType", .{ .string = img.mimeType });
                    },
                    .audio => |aud| {
                        try content_obj.put("type", .{ .string = "audio" });
                        try content_obj.put("data", .{ .string = aud.data });
                        try content_obj.put("mimeType", .{ .string = aud.mimeType });
                    },
                    .resource_link => |link| {
                        try content_obj.put("type", .{ .string = "resource_link" });
                        try content_obj.put("uri", .{ .string = link.uri });
                        try content_obj.put("name", .{ .string = link.name });
                    },
                    .resource => |res| {
                        try content_obj.put("type", .{ .string = "resource" });
                        var res_inner = std.json.ObjectMap.init(self.allocator);
                        try res_inner.put("uri", .{ .string = res.resource.uri });
                        if (res.resource.text) |text| try res_inner.put("text", .{ .string = text });
                        try content_obj.put("resource", .{ .object = res_inner });
                    },
                }
                try msg_obj.put("content", .{ .object = content_obj });
                try messages_array.append(.{ .object = msg_obj });
            }

            var result = std.json.ObjectMap.init(self.allocator);
            try result.put("messages", .{ .array = messages_array });
            if (prompt.description) |desc| {
                try result.put("description", .{ .string = desc });
            }

            const response = jsonrpc.createResponse(request.id, .{ .object = result });
            try self.sendResponse(.{ .response = response });
        } else {
            const error_response = jsonrpc.createInvalidParams(request.id, "Prompt not found");
            try self.sendResponse(.{ .error_response = error_response });
        }
    }

    /// Handle logging/setLevel request
    fn handleSetLogLevel(self: *Self, request: jsonrpc.Request) !void {
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

        const result = std.json.ObjectMap.init(self.allocator);
        const response = jsonrpc.createResponse(request.id, .{ .object = result });
        try self.sendResponse(.{ .response = response });
    }

    /// Handle completion/complete request
    fn handleCompletion(self: *Self, request: jsonrpc.Request) !void {
        var completion = std.json.ObjectMap.init(self.allocator);
        const values_array = std.json.Array.init(self.allocator);
        try completion.put("values", .{ .array = values_array });
        try completion.put("hasMore", .{ .bool = false });

        var result = std.json.ObjectMap.init(self.allocator);
        try result.put("completion", .{ .object = completion });

        const response = jsonrpc.createResponse(request.id, .{ .object = result });
        try self.sendResponse(.{ .response = response });
    }

    /// Handle tasks/get request
    fn handleTasksGet(self: *Self, request: jsonrpc.Request) !void {
        _ = request.params;
        const error_response = jsonrpc.createMethodNotFound(request.id, "tasks/get");
        try self.sendResponse(.{ .error_response = error_response });
    }

    /// Handle tasks/result request
    fn handleTasksResult(self: *Self, request: jsonrpc.Request) !void {
        _ = request.params;
        const error_response = jsonrpc.createMethodNotFound(request.id, "tasks/result");
        try self.sendResponse(.{ .error_response = error_response });
    }

    /// Handle tasks/list request
    fn handleTasksList(self: *Self, request: jsonrpc.Request) !void {
        var result = std.json.ObjectMap.init(self.allocator);
        const tasks_array = std.json.Array.init(self.allocator);
        try result.put("tasks", .{ .array = tasks_array });

        const response = jsonrpc.createResponse(request.id, .{ .object = result });
        try self.sendResponse(.{ .response = response });
    }

    /// Handle tasks/cancel request
    fn handleTasksCancel(self: *Self, request: jsonrpc.Request) !void {
        _ = request.params;
        const error_response = jsonrpc.createMethodNotFound(request.id, "tasks/cancel");
        try self.sendResponse(.{ .error_response = error_response });
    }

    /// Handle incoming notifications
    fn handleNotification(self: *Self, notification: jsonrpc.Notification) !void {
        if (std.mem.eql(u8, notification.method, "notifications/initialized")) {
            self.state = .ready;
            self.log("Server initialized and ready");
        } else if (std.mem.eql(u8, notification.method, "notifications/cancelled")) {
            if (notification.params) |params| {
                if (params == .object) {
                    if (params.object.get("requestId")) |req_id| {
                        _ = req_id;
                    }
                }
            }
        } else if (std.mem.eql(u8, notification.method, "notifications/roots/list_changed")) {
            self.log("Roots list changed");
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
    fn handleErrorResponse(self: *Self, err: jsonrpc.ErrorResponse) void {
        if (err.id) |id| {
            const int_id = switch (id) {
                .integer => |i| i,
                .string => return,
            };
            _ = self.pending_requests.remove(int_id);
        }
        self.logError(err.@"error".message);
    }

    /// Send a notification to the client
    pub fn sendNotification(self: *Self, method: []const u8, params: ?std.json.Value) !void {
        const notification = jsonrpc.createNotification(method, params);
        try self.sendResponse(.{ .notification = notification });
    }

    /// Send a log message notification
    pub fn sendLogMessage(self: *Self, level: protocol.LogLevel, message: []const u8) !void {
        if (@intFromEnum(level) < @intFromEnum(self.log_level)) return;

        var params = std.json.ObjectMap.init(self.allocator);
        try params.put("level", .{ .string = level.toString() });
        try params.put("data", .{ .string = message });

        try self.sendNotification("notifications/message", .{ .object = params });
    }

    /// Send a progress notification
    pub fn sendProgress(self: *Self, token: std.json.Value, prog: f64, total: ?f64, message: ?[]const u8) !void {
        var params = std.json.ObjectMap.init(self.allocator);
        try params.put("progressToken", token);
        try params.put("progress", .{ .float = prog });
        if (total) |t| {
            try params.put("total", .{ .float = t });
        }
        if (message) |m| {
            try params.put("message", .{ .string = m });
        }
        try self.sendNotification("notifications/progress", .{ .object = params });
    }

    /// Notify clients that tools have changed
    pub fn notifyToolsChanged(self: *Self) !void {
        try self.sendNotification("notifications/tools/list_changed", null);
    }

    /// Notify clients that resources have changed
    pub fn notifyResourcesChanged(self: *Self) !void {
        try self.sendNotification("notifications/resources/list_changed", null);
    }

    /// Notify clients that a resource has been updated
    pub fn notifyResourceUpdated(self: *Self, uri: []const u8) !void {
        var params = std.json.ObjectMap.init(self.allocator);
        try params.put("uri", .{ .string = uri });
        try self.sendNotification("notifications/resources/updated", .{ .object = params });
    }

    /// Notify clients that prompts have changed
    pub fn notifyPromptsChanged(self: *Self) !void {
        try self.sendNotification("notifications/prompts/list_changed", null);
    }

    /// Send a response message
    fn sendResponse(self: *Self, message: jsonrpc.Message) !void {
        if (self.transport) |t| {
            const json = jsonrpc.serializeMessage(self.allocator, message) catch {
                self.logError("Failed to serialize response");
                return;
            };
            defer self.allocator.free(json);
            t.send(json) catch {
                self.logError("Failed to send response");
                return;
            };
        }
    }

    fn log(self: *Self, message: []const u8) void {
        if (self.stdio_transport) |t| {
            t.writeStderr(message);
        }
    }

    fn logError(self: *Self, message: []const u8) void {
        if (self.stdio_transport) |t| {
            var buf: [512]u8 = undefined;
            const formatted = std.fmt.bufPrint(&buf, "ERROR: {s}", .{message}) catch message;
            t.writeStderr(formatted);
        }
    }
};

test "Server initialization" {
    var server = Server.init(.{
        .name = "test-server",
        .version = "1.0.0",
        .allocator = std.testing.allocator,
    });
    defer server.deinit();

    try std.testing.expectEqual(ServerState.uninitialized, server.state);
    try std.testing.expectEqualStrings("test-server", server.config.name);
}

test "Server add tool" {
    var server = Server.init(.{
        .name = "test-server",
        .version = "1.0.0",
        .allocator = std.testing.allocator,
    });
    defer server.deinit();

    const tool = tools_mod.Tool{
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
    var server = Server.init(.{
        .name = "test-server",
        .version = "1.0.0",
        .allocator = std.testing.allocator,
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
    var server = Server.init(.{
        .name = "test-server",
        .version = "1.0.0",
        .allocator = std.testing.allocator,
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
    var server = Server.init(.{
        .name = "test-server",
        .version = "1.0.0",
        .allocator = std.testing.allocator,
    });
    defer server.deinit();

    server.enableLogging();
    server.enableCompletions();
    server.enableTasks();

    try std.testing.expect(server.capabilities.logging != null);
    try std.testing.expect(server.capabilities.completions != null);
    try std.testing.expect(server.capabilities.tasks != null);
}
