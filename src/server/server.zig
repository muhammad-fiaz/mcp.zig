//! MCP Server Implementation (Spec 2026-07-28)
//!
//! Provides the main MCP Server that handles client connections, server discovery,
//! capability advertisement, and request routing for tools, resources, prompts,
//! tasks, and all standard MCP methods.
//!
//! This implementation follows the stateless per-request model of MCP 2026-07-28:
//! - No initialize/initialized handshake (removed)
//! - Every request carries protocol version and client info in _meta
//! - server/discover is the mandatory entry point
//! - Resources are served via HTTP POST /mcp + SSE (no GET endpoint)

const std = @import("std");
const httpx = @import("httpx");

const jsonrpc = @import("../protocol/jsonrpc.zig");
const protocol = @import("../protocol/protocol.zig");
const types = @import("../protocol/types.zig");
const transport_mod = @import("../transport/transport.zig");
const prompts_mod = @import("prompts.zig");
const resources_mod = @import("resources.zig");
const tools_mod = @import("tools.zig");

/// Caching configuration for cacheable list/read results (MCP 2026-07-28).
///
/// Servers MUST include `ttlMs` (>= 0) and `cacheScope` on results whose
/// `resultType` is `"complete"` for `server/discover`, `tools/list`,
/// `prompts/list`, `resources/list`, `resources/templates/list`, and
/// `resources/read`.
pub const CacheConfig = struct {
    /// Freshness hint in milliseconds. `0` means immediately stale.
    /// Values are clamped to >= 0 by the server.
    ttl_ms: i64 = protocol.DEFAULT_CACHE_TTL_MS,
    /// Freshness hint for `resources/read`, which usually returns
    /// request-specific data.
    read_ttl_ms: i64 = protocol.DEFAULT_RESOURCE_READ_TTL_MS,
    /// Scope for list results and `server/discover`.
    scope: types.CacheScope = .public,
    /// Scope for `resources/read` results, which may be user-specific.
    read_scope: types.CacheScope = .private,
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
    /// Caching hints emitted on cacheable results.
    cache: CacheConfig = .{},
};

/// Current state of the server
pub const ServerState = enum {
    ready,
    shutting_down,
    stopped,
};

/// HTTP request context used for the per-request httpx transport.
const HttpRequestTransport = struct {
    response_message: ?[]const u8 = null,
    is_closed: bool = false,
    persistent_allocator: std.mem.Allocator = undefined,

    const Self = @This();

    pub fn deinit(self: *Self) void {
        // Don't free response_message here — it's allocated with ctx.allocator
        // (httpx's per-request arena) and will be freed when the request ends.
        self.response_message = null;
    }

    pub fn send(self: *Self, _: std.Io, _: std.mem.Allocator, message: []const u8) transport_mod.Transport.SendError!void {
        if (self.is_closed) return transport_mod.Transport.SendError.ConnectionClosed;

        // Always allocate with the persistent allocator, not the arena from handleMessage
        const owned = self.persistent_allocator.dupe(u8, message) catch return transport_mod.Transport.SendError.OutOfMemory;
        if (self.response_message) |old| {
            self.persistent_allocator.free(old);
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
                .destroy = destroyVtable,
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

    fn destroyVtable(ptr: *anyopaque, _: std.mem.Allocator) void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        self.deinit();
    }
};

/// MCP Server that handles client connections and routes requests
pub const Server = struct {
    allocator: std.mem.Allocator,
    config: ServerConfig,
    state: ServerState = .ready,
    tools: std.StringHashMap(tools_mod.Tool),
    resources: std.StringHashMap(resources_mod.Resource),
    resource_templates: std.StringHashMap(resources_mod.ResourceTemplate),
    prompts: std.StringHashMap(prompts_mod.Prompt),
    tasks: std.StringHashMap(TaskEntry),
    capabilities: types.ServerCapabilities = .{},
    transport: ?transport_mod.Transport = null,
    stdio_transport: ?*transport_mod.StdioTransport = null,
    next_request_id: i64 = 1,
    pending_requests: std.AutoHashMap(i64, PendingRequest),
    log_level: protocol.LogLevel = .info,
    io: ?std.Io = null,
    pub const max_http_body_size: usize = 4 * 1024 * 1024;

    const Self = @This();

    pub const PendingRequest = struct {
        method: []const u8,
        timestamp: i64,
    };

    const TaskEntry = struct {
        task: types.Task,
        result_json: []const u8,
    };

    /// Initialize a new MCP Server
    pub fn init(allocator: std.mem.Allocator, config: ServerConfig) Self {
        return .{
            .allocator = allocator,
            .config = config,
            .tools = .init(allocator),
            .resources = .init(allocator),
            .resource_templates = .init(allocator),
            .prompts = .init(allocator),
            .tasks = .init(allocator),
            .pending_requests = .init(allocator),
        };
    }

    /// Clean up server resources
    pub fn deinit(self: *Self) void {
        self.tools.deinit();
        self.resources.deinit();
        self.resource_templates.deinit();
        self.prompts.deinit();
        self.deinitTasks();
        self.pending_requests.deinit();
        if (self.stdio_transport) |stdio| {
            stdio.deinit(self.allocator);
            self.allocator.destroy(stdio);
            self.stdio_transport = null;
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
        self.capabilities.resources = .{ .listChanged = true, .subscribe = false };
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
        self.io = io;
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
        self.log(io, "Server listening on HTTP (httpx)");

        var server = try httpx.Server.init(allocator, io, .{
            .host = config.host,
            .port = config.port,
            .maxBody = max_http_body_size,
            .enableDocs = false,
        });
        defer server.deinit();

        // Pass the MCP server pointer via route user data.
        try server.router.add(.POST, "/mcp", Self.handleHttpRequest, .{ .userData = self });

        server.run();
    }

    /// Handle an incoming HTTP request on the /mcp endpoint.
    fn handleHttpRequest(ctx: *httpx.Context) anyerror!httpx.Response {
        const mcp_server: *Self = @ptrCast(@alignCast(ctx.userData orelse return .{
            .status = 500,
            .body = "Internal server error",
            .contentType = "text/plain; charset=utf-8",
        }));

        // Only POST is allowed for MCP Streamable HTTP
        if (ctx.method != .POST) {
            return .{
                .status = 405,
                .body = "Method Not Allowed",
                .contentType = "text/plain; charset=utf-8",
                .headers = &.{.{ .name = "Allow", .value = "POST" }},
            };
        }

        // Read request body
        const body = ctx.body;
        if (body.len == 0) {
            return .{
                .status = 400,
                .body = "Empty request body",
                .contentType = "text/plain; charset=utf-8",
            };
        }

        // Check for SSE preference
        const wants_sse = if (ctx.header("Accept")) |accept|
            std.mem.indexOf(u8, accept, "text/event-stream") != null
        else
            false;

        // Create per-request transport
        var request_transport: HttpRequestTransport = .{
            .persistent_allocator = ctx.allocator,
        };
        defer request_transport.deinit();

        const previous_transport = mcp_server.transport;
        mcp_server.transport = request_transport.transport();
        defer mcp_server.transport = previous_transport;

        // Handle the JSON-RPC message.
        // NOTE: response bodies must be allocated with ctx.allocator (per-request
        // arena, borrowed by the transport) — do NOT free before returning.
        mcp_server.handleMessage(mcp_server.io orelse return .{
            .status = 500,
            .body = "Server not initialized",
            .contentType = "text/plain; charset=utf-8",
        }, ctx.allocator, body) catch {
            const error_response = jsonrpc.createParseError(.{ .string = "Internal server error" });
            const err_json = jsonrpc.serializeMessage(ctx.allocator, .{ .error_response = error_response }) catch {
                return .{
                    .status = 500,
                    .body = "Internal server error",
                    .contentType = "text/plain; charset=utf-8",
                };
            };
            return .{
                .status = 500,
                .body = err_json,
                .contentType = "application/json",
            };
        };

        if (request_transport.response_message) |response_json| {
            if (wants_sse) {
                const sse_body = try std.fmt.allocPrint(ctx.allocator, "data: {s}\n\n", .{response_json});
                return .{
                    .status = 200,
                    .body = sse_body,
                    .contentType = "text/event-stream",
                };
            }

            return .{
                .status = 200,
                .body = response_json,
                .contentType = "application/json",
            };
        }

        // No response (notification)
        return .{
            .status = 202,
            .body = "",
        };
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
                    else => |e| {
                        var buf: [128]u8 = undefined;
                        if (std.fmt.bufPrint(&buf, "Transport receive error: {s}", .{@errorName(e)})) |msg| {
                            self.logError(io, msg);
                        } else |_| {
                            self.logError(io, "Transport receive error");
                        }
                        self.state = .shutting_down;
                        break;
                    },
                }
            };

            if (message_data) |data| {
                defer allocator.free(data);
                try self.handleMessage(io, allocator, data);
            }
        }

        self.state = .stopped;
    }

    /// Request graceful shutdown of the server.
    /// The server will stop after processing the current request.
    pub fn shutdown(self: *Self) void {
        self.state = .shutting_down;
    }

    /// Check if the server is shutting down.
    pub fn isShuttingDown(self: *Self) bool {
        return self.state == .shutting_down or self.state == .stopped;
    }

    /// Handle an incoming message
    pub fn handleMessage(self: *Self, io_or_alloc: anytype, allocator: std.mem.Allocator, data: []const u8) !void {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const aa = arena.allocator();

        const parsed_message = jsonrpc.parseMessage(aa, data) catch {
            const error_response = jsonrpc.createParseError(null);
            try self.sendResponse(io_or_alloc, aa, .{ .error_response = error_response });
            return;
        };

        switch (parsed_message.message) {
            .request => |req| try self.handleRequest(io_or_alloc, aa, req),
            .notification => |notif| try self.handleNotification(io_or_alloc, notif),
            .response => |resp| self.handleResponse(resp),
            .error_response => |err| self.handleErrorResponse(io_or_alloc, err),
        }
    }

    /// Handle an incoming request
    fn handleRequest(self: *Self, io: anytype, allocator: std.mem.Allocator, request: jsonrpc.Request) !void {
        var buf: [256]u8 = undefined;
        if (std.fmt.bufPrint(&buf, "Received request: {s}", .{request.method})) |msg| {
            self.log(io, msg);
        } else |_| {}

        if (std.mem.eql(u8, request.method, "server/discover")) {
            try self.handleDiscover(io, allocator, request);
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
        } else if (std.mem.eql(u8, request.method, "subscriptions/listen")) {
            try self.handleSubscriptionsListen(io, allocator, request);
        } else if (std.mem.eql(u8, request.method, "prompts/list")) {
            try self.handlePromptsList(io, allocator, request);
        } else if (std.mem.eql(u8, request.method, "prompts/get")) {
            try self.handlePromptsGet(io, allocator, request);
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
        } else if (std.mem.eql(u8, request.method, "sampling/createMessage")) {
            // Deprecated but still functional
            try self.handleSamplingCreateMessage(io, allocator, request);
        } else if (std.mem.eql(u8, request.method, "elicitation/create")) {
            try self.handleElicitationCreate(io, allocator, request);
        } else if (std.mem.eql(u8, request.method, "roots/list")) {
            try self.handleRootsList(io, allocator, request);
        } else if (std.mem.eql(u8, request.method, "health/check")) {
            try self.handleHealthCheck(io, allocator, request);
        } else {
            const error_response = jsonrpc.createMethodNotFound(request.id, request.method);
            try self.sendResponse(io, allocator, .{ .error_response = error_response });
        }
    }

    /// Handle health/check request - returns server health status
    fn handleHealthCheck(self: *Self, io: anytype, allocator: std.mem.Allocator, request: jsonrpc.Request) !void {
        var result: std.json.ObjectMap = .empty;

        // Server status
        const status_str: []const u8 = switch (self.state) {
            .ready => "ready",
            .shutting_down => "shutting_down",
            .stopped => "stopped",
        };
        try result.put(allocator, "status", .{ .string = status_str });

        // Server identity belongs under the namespaced _meta key.
        try Self.putServerInfoMeta(allocator, &result, self.config);

        // Uptime (placeholder - would need to track start time in production)
        try result.put(allocator, "uptime", .{ .integer = 0 });

        // Active connections count
        const active_count: i64 = if (self.transport != null) 1 else 0;
        try result.put(allocator, "activeConnections", .{ .integer = active_count });

        try Self.putResultComplete(allocator, &result);

        const response = jsonrpc.createResponse(request.id, .{ .object = result });
        try self.sendResponse(io, allocator, .{ .response = response });
    }

    /// Handle server/discover request (MUST be implemented by all servers).
    fn handleDiscover(self: *Self, io: anytype, allocator: std.mem.Allocator, request: jsonrpc.Request) !void {
        var result: std.json.ObjectMap = .empty;

        // supportedVersions (descending preference order)
        var versions_array: std.json.Array = .init(allocator);
        for (protocol.SUPPORTED_VERSIONS) |version| {
            try versions_array.append(.{ .string = version });
        }
        try result.put(allocator, "supportedVersions", .{ .array = versions_array });

        // capabilities
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

        // serverInfo lives under the namespaced _meta key (2026-07-28).
        try Self.putServerInfoMeta(allocator, &result, self.config);

        if (self.config.instructions) |inst| {
            try result.put(allocator, "instructions", .{ .string = inst });
        }

        try Self.putResultComplete(allocator, &result);
        try self.putListCacheHints(allocator, &result);

        const response = jsonrpc.createResponse(request.id, .{ .object = result });
        try self.sendResponse(io, allocator, .{ .response = response });
    }

    /// Collects map keys and sorts them so `tools/list`, `resources/list`,
    /// `resources/templates/list`, and `prompts/list` return results in a
    /// deterministic order. The spec asks servers to return a stable ordering
    /// so clients can cache and cache-diff these lists reliably; iterating the
    /// underlying hash map directly does not guarantee that.
    fn sortedKeys(
        allocator: std.mem.Allocator,
        comptime Map: type,
        map: *const Map,
    ) ![]const []const u8 {
        var keys: std.ArrayList([]const u8) = .empty;
        errdefer keys.deinit(allocator);

        var it = map.keyIterator();
        while (it.next()) |key| {
            keys.append(allocator, key.*) catch return error.OutOfMemory;
        }

        std.mem.sort([]const u8, keys.items, {}, lessThanStr);
        return keys.toOwnedSlice(allocator);
    }

    fn lessThanStr(_: void, a: []const u8, b: []const u8) bool {
        return std.mem.lessThan(u8, a, b);
    }

    /// Handle tools/list request
    fn handleToolsList(self: *Self, io: anytype, allocator: std.mem.Allocator, request: jsonrpc.Request) !void {
        var tools_array: std.json.Array = .init(allocator);

        const keys = try Self.sortedKeys(allocator, @TypeOf(self.tools), &self.tools);
        defer allocator.free(keys);

        for (keys) |key| {
            const entry = self.tools.get(key).?;
            var tool_obj: std.json.ObjectMap = .empty;
            try tool_obj.put(allocator, "name", .{ .string = entry.name });
            if (entry.description) |desc| {
                try tool_obj.put(allocator, "description", .{ .string = desc });
            }
            if (entry.title) |t| {
                try tool_obj.put(allocator, "title", .{ .string = t });
            }
            if (entry.icons) |icons| {
                try putIcons(allocator, &tool_obj, icons);
            }

            var input_schema: std.json.ObjectMap = .empty;
            if (entry.inputSchema) |schema| {
                try input_schema.put(allocator, "type", .{ .string = schema.type });

                if (schema.@"$schema") |s| try input_schema.put(allocator, "$schema", .{ .string = s });
                if (schema.description) |d| try input_schema.put(allocator, "description", .{ .string = d });
                if (schema.properties) |p| try input_schema.put(allocator, "properties", p);

                if (schema.required) |req| {
                    var arr: std.json.Array = .init(allocator);
                    for (req) |name| try arr.append(.{ .string = name });
                    try input_schema.put(allocator, "required", .{ .array = arr });
                }
            } else {
                try input_schema.put(allocator, "type", .{ .string = "object" });
            }
            try tool_obj.put(allocator, "inputSchema", .{ .object = input_schema });

            if (entry.outputSchema) |schema| {
                var output_schema: std.json.ObjectMap = .empty;
                try output_schema.put(allocator, "type", .{ .string = schema.type });
                if (schema.@"$schema") |s| try output_schema.put(allocator, "$schema", .{ .string = s });
                if (schema.properties) |p| try output_schema.put(allocator, "properties", p);
                if (schema.required) |req| {
                    var arr: std.json.Array = .init(allocator);
                    for (req) |name| try arr.append(.{ .string = name });
                    try output_schema.put(allocator, "required", .{ .array = arr });
                }
                try tool_obj.put(allocator, "outputSchema", .{ .object = output_schema });
            }

            if (entry.annotations) |ann| {
                var ann_obj: std.json.ObjectMap = .empty;
                if (ann.title) |t| try ann_obj.put(allocator, "title", .{ .string = t });
                try ann_obj.put(allocator, "readOnlyHint", .{ .bool = ann.readOnlyHint });
                try ann_obj.put(allocator, "destructiveHint", .{ .bool = ann.destructiveHint });
                try ann_obj.put(allocator, "idempotentHint", .{ .bool = ann.idempotentHint });
                try ann_obj.put(allocator, "openWorldHint", .{ .bool = ann.openWorldHint });
                try tool_obj.put(allocator, "annotations", .{ .object = ann_obj });
            }

            if (entry.execution) |exec| {
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
        try Self.putResultComplete(allocator, &result);
        try self.putListCacheHints(allocator, &result);

        const response = jsonrpc.createResponse(request.id, .{ .object = result });
        try self.sendResponse(io, allocator, .{ .response = response });
    }

    /// Handle tools/call request
    fn handleToolsCall(self: *Self, io: anytype, allocator: std.mem.Allocator, request: jsonrpc.Request) !void {
        var tool_name: []const u8 = "";
        var arguments: ?std.json.Value = null;
        var task_meta: ?types.TaskMetadata = null;

        if (request.params) |params| {
            if (params == .object) {
                if (params.object.get("name")) |name_val| {
                    if (name_val == .string) {
                        tool_name = name_val.string;
                    }
                }
                arguments = params.object.get("arguments");
                if (params.object.get("task")) |task_val| {
                    if (task_val == .object) {
                        var ttl: ?i64 = null;
                        if (task_val.object.get("ttl")) |ttl_val| {
                            if (ttl_val == .integer) {
                                ttl = @intCast(ttl_val.integer);
                            }
                        }
                        task_meta = .{ .ttl = ttl };
                    }
                }
            }
        }

        if (self.tools.get(tool_name)) |tool| {
            const tasks_enabled = self.capabilities.tasks != null and self.capabilities.tasks.?.requests != null and self.capabilities.tasks.?.requests.?.tools != null and self.capabilities.tasks.?.requests.?.tools.?.call != null;
            const task_support = if (tool.execution) |exec| exec.taskSupport else null;

            if (tasks_enabled and task_support != null and std.mem.eql(u8, task_support.?, "required") and task_meta == null) {
                const error_response = jsonrpc.createMethodNotFound(request.id, "tools/call");
                try self.sendResponse(io, allocator, .{ .error_response = error_response });
                return;
            }

            if (tasks_enabled and task_meta != null) {
                if (task_support == null or std.mem.eql(u8, task_support.?, "forbidden")) {
                    const error_response = jsonrpc.createMethodNotFound(request.id, "tools/call");
                    try self.sendResponse(io, allocator, .{ .error_response = error_response });
                    return;
                }

                var status_message: ?[]const u8 = null;
                const tool_result: tools_mod.ToolResult = tool.handler(tool.user_data, io, allocator, arguments) catch |err| blk: {
                    const msg = try std.fmt.allocPrint(self.allocator, "{s}", .{@errorName(err)});
                    status_message = msg;
                    var content = try self.allocator.alloc(types.ContentBlock, 1);
                    content[0] = .{ .text = .{ .text = msg } };
                    break :blk tools_mod.ToolResult{ .content = content, .is_error = true };
                };

                const result_json = try self.serializeToolCallResult(tool_result);
                const task_id = try generateTaskId(io, self.allocator);
                const created_at = try nowIsoTimestamp(io, self.allocator);
                const updated_at = try self.allocator.dupe(u8, created_at);

                const task: types.Task = .{
                    .taskId = task_id,
                    .status = if (tool_result.is_error) .failed else .completed,
                    .statusMessage = status_message,
                    .createdAt = created_at,
                    .lastUpdatedAt = updated_at,
                    .ttl = if (task_meta) |meta| meta.ttl else null,
                    .pollInterval = null,
                };

                try self.tasks.put(task_id, .{ .task = task, .result_json = result_json });

                const task_obj = try buildTaskObject(allocator, task);
                var result: std.json.ObjectMap = .empty;
                try result.put(allocator, "task", .{ .object = task_obj });
                try Self.putResultComplete(allocator, &result);

                const response = jsonrpc.createResponse(request.id, .{ .object = result });
                try self.sendResponse(io, allocator, .{ .response = response });
                return;
            }

            const tool_result = tool.handler(tool.user_data, io, allocator, arguments) catch |err| {
                var content = try allocator.alloc(types.ContentBlock, 1);
                content[0] = .{ .text = .{ .text = @errorName(err) } };
                const result_value = try buildToolCallResultValue(allocator, .{ .content = content, .is_error = true });
                const response = jsonrpc.createResponse(request.id, result_value);
                try self.sendResponse(io, allocator, .{ .response = response });
                return;
            };

            const result_value = try buildToolCallResultValue(allocator, tool_result);
            const response = jsonrpc.createResponse(request.id, result_value);
            try self.sendResponse(io, allocator, .{ .response = response });
        } else {
            const error_response = jsonrpc.createInvalidParams(request.id, "Tool not found");
            try self.sendResponse(io, allocator, .{ .error_response = error_response });
        }
    }

    /// Handle resources/list request
    fn handleResourcesList(self: *Self, io: anytype, allocator: std.mem.Allocator, request: jsonrpc.Request) !void {
        var resources_array: std.json.Array = .init(allocator);

        const keys = try Self.sortedKeys(allocator, @TypeOf(self.resources), &self.resources);
        defer allocator.free(keys);

        for (keys) |key| {
            const entry = self.resources.get(key).?;
            var resource_obj: std.json.ObjectMap = .empty;
            try resource_obj.put(allocator, "uri", .{ .string = entry.uri });
            try resource_obj.put(allocator, "name", .{ .string = entry.name });
            if (entry.title) |t| {
                try resource_obj.put(allocator, "title", .{ .string = t });
            }
            if (entry.description) |desc| {
                try resource_obj.put(allocator, "description", .{ .string = desc });
            }
            if (entry.mimeType) |mime| {
                try resource_obj.put(allocator, "mimeType", .{ .string = mime });
            }
            if (entry.icons) |icons| {
                try putIcons(allocator, &resource_obj, icons);
            }
            if (entry.annotations) |ann| {
                try putAnnotations(allocator, &resource_obj, ann);
            }
            if (entry.size) |s| {
                try resource_obj.put(allocator, "size", .{ .integer = @intCast(s) });
            }
            if (entry._meta) |meta| {
                try resource_obj.put(allocator, "_meta", meta);
            }
            try resources_array.append(.{ .object = resource_obj });
        }

        var result: std.json.ObjectMap = .empty;
        try result.put(allocator, "resources", .{ .array = resources_array });
        try Self.putResultComplete(allocator, &result);
        try self.putListCacheHints(allocator, &result);

        const response = jsonrpc.createResponse(request.id, .{ .object = result });
        try self.sendResponse(io, allocator, .{ .response = response });
    }

    /// Handle resources/read request
    fn handleResourcesRead(self: *Self, io: anytype, allocator: std.mem.Allocator, request: jsonrpc.Request) !void {
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
            const content = resource.handler(resource.user_data, io, allocator, uri) catch |err| {
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
            if (content._meta) |meta| {
                try content_obj.put(allocator, "_meta", meta);
            }
            try contents_array.append(.{ .object = content_obj });

            var result: std.json.ObjectMap = .empty;
            try result.put(allocator, "contents", .{ .array = contents_array });
            try Self.putResultComplete(allocator, &result);
            try self.putReadCacheHints(allocator, &result);

            const response = jsonrpc.createResponse(request.id, .{ .object = result });
            try self.sendResponse(io, allocator, .{ .response = response });
        } else {
            const error_response = jsonrpc.createInvalidParams(request.id, "Resource not found");
            try self.sendResponse(io, allocator, .{ .error_response = error_response });
        }
    }

    /// Handle resources/templates/list request
    fn handleResourceTemplatesList(self: *Self, io: anytype, allocator: std.mem.Allocator, request: jsonrpc.Request) !void {
        var templates_array: std.json.Array = .init(allocator);

        const keys = try Self.sortedKeys(allocator, @TypeOf(self.resource_templates), &self.resource_templates);
        defer allocator.free(keys);

        for (keys) |key| {
            const entry = self.resource_templates.get(key).?;
            var template_obj: std.json.ObjectMap = .empty;
            try template_obj.put(allocator, "uriTemplate", .{ .string = entry.uriTemplate });
            try template_obj.put(allocator, "name", .{ .string = entry.name });
            if (entry.title) |t| {
                try template_obj.put(allocator, "title", .{ .string = t });
            }
            if (entry.description) |desc| {
                try template_obj.put(allocator, "description", .{ .string = desc });
            }
            if (entry.mimeType) |mime| {
                try template_obj.put(allocator, "mimeType", .{ .string = mime });
            }
            if (entry.icons) |icons| {
                try putIcons(allocator, &template_obj, icons);
            }
            if (entry.annotations) |ann| {
                try putAnnotations(allocator, &template_obj, ann);
            }
            if (entry._meta) |meta| {
                try template_obj.put(allocator, "_meta", meta);
            }
            try templates_array.append(.{ .object = template_obj });
        }

        var result: std.json.ObjectMap = .empty;
        try result.put(allocator, "resourceTemplates", .{ .array = templates_array });
        try Self.putResultComplete(allocator, &result);
        try self.putListCacheHints(allocator, &result);

        const response = jsonrpc.createResponse(request.id, .{ .object = result });
        try self.sendResponse(io, allocator, .{ .response = response });
    }

    /// Handle subscriptions/listen request (replaces resources/subscribe + resources/unsubscribe + HTTP GET)
    fn handleSubscriptionsListen(self: *Self, io: anytype, allocator: std.mem.Allocator, request: jsonrpc.Request) !void {
        // For now, acknowledge the subscription. Full implementation would use long-lived SSE streams.
        var result: std.json.ObjectMap = .empty;
        try Self.putResultComplete(allocator, &result);

        const response = jsonrpc.createResponse(request.id, .{ .object = result });
        try self.sendResponse(io, allocator, .{ .response = response });
    }

    /// Handle prompts/list request
    fn handlePromptsList(self: *Self, io: anytype, allocator: std.mem.Allocator, request: jsonrpc.Request) !void {
        var prompts_array: std.json.Array = .init(allocator);

        const keys = try Self.sortedKeys(allocator, @TypeOf(self.prompts), &self.prompts);
        defer allocator.free(keys);

        for (keys) |key| {
            const entry = self.prompts.get(key).?;
            var prompt_obj: std.json.ObjectMap = .empty;
            try prompt_obj.put(allocator, "name", .{ .string = entry.name });
            if (entry.description) |desc| {
                try prompt_obj.put(allocator, "description", .{ .string = desc });
            }
            if (entry.title) |t| {
                try prompt_obj.put(allocator, "title", .{ .string = t });
            }
            if (entry.icons) |icons| {
                try putIcons(allocator, &prompt_obj, icons);
            }

            if (entry.arguments) |args| {
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

            if (entry._meta) |meta| {
                try prompt_obj.put(allocator, "_meta", meta);
            }

            try prompts_array.append(.{ .object = prompt_obj });
        }

        var result: std.json.ObjectMap = .empty;
        try result.put(allocator, "prompts", .{ .array = prompts_array });
        try Self.putResultComplete(allocator, &result);
        try self.putListCacheHints(allocator, &result);

        const response = jsonrpc.createResponse(request.id, .{ .object = result });
        try self.sendResponse(io, allocator, .{ .response = response });
    }

    /// Handle prompts/get request
    fn handlePromptsGet(self: *Self, io: anytype, allocator: std.mem.Allocator, request: jsonrpc.Request) !void {
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
            const messages = prompt.handler(prompt.user_data, io, allocator, arguments) catch |err| {
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
            try Self.putResultComplete(allocator, &result);

            const response = jsonrpc.createResponse(request.id, .{ .object = result });
            try self.sendResponse(io, allocator, .{ .response = response });
        } else {
            const error_response = jsonrpc.createInvalidParams(request.id, "Prompt not found");
            try self.sendResponse(io, allocator, .{ .error_response = error_response });
        }
    }

    /// Handle completion/complete request
    fn handleCompletion(self: *Self, io: anytype, allocator: std.mem.Allocator, request: jsonrpc.Request) !void {
        var completion: std.json.ObjectMap = .empty;
        const values_array: std.json.Array = .init(allocator);
        try completion.put(allocator, "values", .{ .array = values_array });
        try completion.put(allocator, "hasMore", .{ .bool = false });

        var result: std.json.ObjectMap = .empty;
        try result.put(allocator, "completion", .{ .object = completion });
        try Self.putResultComplete(allocator, &result);

        const response = jsonrpc.createResponse(request.id, .{ .object = result });
        try self.sendResponse(io, allocator, .{ .response = response });
    }

    /// Handle sampling/createMessage request (deprecated but functional)
    fn handleSamplingCreateMessage(self: *Self, io: anytype, allocator: std.mem.Allocator, request: jsonrpc.Request) !void {
        const error_response = jsonrpc.createMethodNotFound(request.id, "sampling/createMessage");
        try self.sendResponse(io, allocator, .{ .error_response = error_response });
    }

    /// Handle elicitation/create request
    fn handleElicitationCreate(self: *Self, io: anytype, allocator: std.mem.Allocator, request: jsonrpc.Request) !void {
        const error_response = jsonrpc.createMethodNotFound(request.id, "elicitation/create");
        try self.sendResponse(io, allocator, .{ .error_response = error_response });
    }

    /// Handle roots/list request (deprecated but functional)
    fn handleRootsList(self: *Self, io: anytype, allocator: std.mem.Allocator, request: jsonrpc.Request) !void {
        var result: std.json.ObjectMap = .empty;
        const roots_array: std.json.Array = .init(allocator);
        try result.put(allocator, "roots", .{ .array = roots_array });
        try Self.putResultComplete(allocator, &result);

        const response = jsonrpc.createResponse(request.id, .{ .object = result });
        try self.sendResponse(io, allocator, .{ .response = response });
    }

    /// Handle tasks/get request
    fn handleTasksGet(self: *Self, io: anytype, allocator: std.mem.Allocator, request: jsonrpc.Request) !void {
        var task_id: ?[]const u8 = null;
        if (request.params) |params| {
            if (params == .object) {
                if (params.object.get("taskId")) |id_val| {
                    if (id_val == .string) {
                        task_id = id_val.string;
                    }
                }
            }
        }

        const id = task_id orelse {
            const error_response = jsonrpc.createInvalidParams(request.id, "Missing taskId");
            try self.sendResponse(io, allocator, .{ .error_response = error_response });
            return;
        };

        if (self.tasks.get(id)) |entry| {
            const task_obj = try buildTaskObject(allocator, entry.task);
            const response = jsonrpc.createResponse(request.id, .{ .object = task_obj });
            try self.sendResponse(io, allocator, .{ .response = response });
        } else {
            const error_response = jsonrpc.createInvalidParams(request.id, "Task not found");
            try self.sendResponse(io, allocator, .{ .error_response = error_response });
        }
    }

    /// Handle tasks/result request
    fn handleTasksResult(self: *Self, io: anytype, allocator: std.mem.Allocator, request: jsonrpc.Request) !void {
        var task_id: ?[]const u8 = null;
        if (request.params) |params| {
            if (params == .object) {
                if (params.object.get("taskId")) |id_val| {
                    if (id_val == .string) {
                        task_id = id_val.string;
                    }
                }
            }
        }

        const id = task_id orelse {
            const error_response = jsonrpc.createInvalidParams(request.id, "Missing taskId");
            try self.sendResponse(io, allocator, .{ .error_response = error_response });
            return;
        };

        if (self.tasks.get(id)) |entry| {
            const parsed = try std.json.parseFromSlice(std.json.Value, allocator, entry.result_json, .{});
            defer parsed.deinit();

            if (parsed.value == .object) {
                var result_obj = parsed.value.object;
                if (result_obj.get("_meta") == null) {
                    var meta_obj: std.json.ObjectMap = .empty;
                    var related_obj: std.json.ObjectMap = .empty;
                    try related_obj.put(allocator, "taskId", .{ .string = entry.task.taskId });
                    try meta_obj.put(allocator, "io.modelcontextprotocol/related-task", .{ .object = related_obj });
                    try result_obj.put(allocator, "_meta", .{ .object = meta_obj });
                }
                const response = jsonrpc.createResponse(request.id, .{ .object = result_obj });
                try self.sendResponse(io, allocator, .{ .response = response });
                return;
            }

            const error_response = jsonrpc.createInternalError(request.id, .{ .string = "Invalid task result" });
            try self.sendResponse(io, allocator, .{ .error_response = error_response });
        } else {
            const error_response = jsonrpc.createInvalidParams(request.id, "Task not found");
            try self.sendResponse(io, allocator, .{ .error_response = error_response });
        }
    }

    /// Handle tasks/list request
    fn handleTasksList(self: *Self, io: anytype, allocator: std.mem.Allocator, request: jsonrpc.Request) !void {
        var result: std.json.ObjectMap = .empty;
        var tasks_array: std.json.Array = .init(allocator);

        var iter = self.tasks.iterator();
        while (iter.next()) |entry| {
            const task_obj = try buildTaskObject(allocator, entry.value_ptr.task);
            try tasks_array.append(.{ .object = task_obj });
        }
        try result.put(allocator, "tasks", .{ .array = tasks_array });

        const response = jsonrpc.createResponse(request.id, .{ .object = result });
        try self.sendResponse(io, allocator, .{ .response = response });
    }

    /// Handle tasks/cancel request
    fn handleTasksCancel(self: *Self, io: anytype, allocator: std.mem.Allocator, request: jsonrpc.Request) !void {
        var task_id: ?[]const u8 = null;
        if (request.params) |params| {
            if (params == .object) {
                if (params.object.get("taskId")) |id_val| {
                    if (id_val == .string) {
                        task_id = id_val.string;
                    }
                }
            }
        }

        const id = task_id orelse {
            const error_response = jsonrpc.createInvalidParams(request.id, "Missing taskId");
            try self.sendResponse(io, allocator, .{ .error_response = error_response });
            return;
        };

        if (self.tasks.getPtr(id)) |entry| {
            if (entry.task.status == .completed or entry.task.status == .failed or entry.task.status == .cancelled) {
                const error_response = jsonrpc.createInvalidParams(request.id, "Task already in terminal status");
                try self.sendResponse(io, allocator, .{ .error_response = error_response });
                return;
            }

            entry.task.status = .cancelled;
            const updated = try nowIsoTimestamp(io, self.allocator);
            self.allocator.free(entry.task.lastUpdatedAt);
            entry.task.lastUpdatedAt = updated;

            const task_obj = try buildTaskObject(allocator, entry.task);
            const response = jsonrpc.createResponse(request.id, .{ .object = task_obj });
            try self.sendResponse(io, allocator, .{ .response = response });
        } else {
            const error_response = jsonrpc.createInvalidParams(request.id, "Task not found");
            try self.sendResponse(io, allocator, .{ .error_response = error_response });
        }
    }

    /// Handle incoming notifications
    fn handleNotification(self: *Self, io: anytype, notification: jsonrpc.Notification) !void {
        if (std.mem.eql(u8, notification.method, "notifications/cancelled")) {
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
    fn handleErrorResponse(self: *Self, io: anytype, err: jsonrpc.ErrorResponse) void {
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
    pub fn sendNotification(self: *Self, io: anytype, allocator: std.mem.Allocator, method: []const u8, params: ?std.json.Value) !void {
        const notification = jsonrpc.createNotification(method, params);
        try self.sendResponse(io, allocator, .{ .notification = notification });
    }

    /// Send a log message notification
    pub fn sendLogMessage(self: *Self, io: anytype, allocator: std.mem.Allocator, level: protocol.LogLevel, message: []const u8) !void {
        if (@backingInt(level) < @backingInt(self.log_level)) return;

        var params: std.json.ObjectMap = .empty;
        try params.put(allocator, "level", .{ .string = level.toString() });
        try params.put(allocator, "data", .{ .string = message });

        try self.sendNotification(io, allocator, "notifications/message", .{ .object = params });
    }

    /// Send a progress notification
    pub fn sendProgress(self: *Self, io: anytype, allocator: std.mem.Allocator, token: std.json.Value, prog: f64, total: ?f64, message: ?[]const u8) !void {
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
    pub fn notifyToolsChanged(self: *Self, io: anytype, allocator: std.mem.Allocator) !void {
        try self.sendNotification(io, allocator, "notifications/tools/list_changed", null);
    }

    /// Notify clients that resources have changed
    pub fn notifyResourcesChanged(self: *Self, io: anytype, allocator: std.mem.Allocator) !void {
        try self.sendNotification(io, allocator, "notifications/resources/list_changed", null);
    }

    /// Notify clients that a resource has been updated
    pub fn notifyResourceUpdated(self: *Self, io: anytype, allocator: std.mem.Allocator, uri: []const u8) !void {
        var params: std.json.ObjectMap = .empty;
        try params.put(allocator, "uri", .{ .string = uri });
        try self.sendNotification(io, allocator, "notifications/resources/updated", .{ .object = params });
    }

    /// Notify clients that prompts have changed
    pub fn notifyPromptsChanged(self: *Self, io: anytype, allocator: std.mem.Allocator) !void {
        try self.sendNotification(io, allocator, "notifications/prompts/list_changed", null);
    }

    /// Send a response message
    fn sendResponse(self: *Self, io: anytype, allocator: std.mem.Allocator, message: jsonrpc.Message) !void {
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

    fn deinitTasks(self: *Self) void {
        var iter = self.tasks.iterator();
        while (iter.next()) |entry| {
            self.allocator.free(entry.value_ptr.task.taskId);
            self.allocator.free(entry.value_ptr.task.createdAt);
            self.allocator.free(entry.value_ptr.task.lastUpdatedAt);
            if (entry.value_ptr.task.statusMessage) |msg| {
                self.allocator.free(msg);
            }
            self.allocator.free(entry.value_ptr.result_json);
        }
        self.tasks.deinit();
    }

    fn nowIsoTimestamp(io: anytype, allocator: std.mem.Allocator) ![]const u8 {
        const now_ts = std.Io.Clock.real.now(io);
        const now_secs: i64 = now_ts.toSeconds();
        const secs: u64 = if (now_secs < 0) 0 else @intCast(now_secs);
        const epoch_seconds = std.time.epoch.EpochSeconds{ .secs = secs };
        const epoch_day = epoch_seconds.getEpochDay();
        const year_day = epoch_day.calculateYearDay();
        const month_day = year_day.calculateMonthDay();
        const day_seconds = epoch_seconds.getDaySeconds();

        const year: u16 = year_day.year;
        const month: u4 = month_day.month.numeric();
        const day: u5 = month_day.day_index + 1;
        const hour: u5 = day_seconds.getHoursIntoDay();
        const minute: u6 = day_seconds.getMinutesIntoHour();
        const second: u6 = day_seconds.getSecondsIntoMinute();

        return std.fmt.allocPrint(allocator, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z", .{
            year,
            month,
            day,
            hour,
            minute,
            second,
        });
    }

    fn generateTaskId(io: anytype, allocator: std.mem.Allocator) ![]const u8 {
        var bytes: [16]u8 = undefined;
        io.randomSecure(&bytes) catch io.random(&bytes);

        var hex_buf: [32]u8 = undefined;
        var i: usize = 0;
        while (i < bytes.len) : (i += 1) {
            _ = std.fmt.bufPrint(hex_buf[i * 2 .. i * 2 + 2], "{x:0>2}", .{bytes[i]}) catch unreachable;
        }
        return allocator.dupe(u8, &hex_buf);
    }

    fn buildToolCallResultValue(allocator: std.mem.Allocator, tool_result: tools_mod.ToolResult) !std.json.Value {
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
        try Self.putResultComplete(allocator, &result);
        if (tool_result.structuredContent) |sc| {
            try result.put(allocator, "structuredContent", sc);
        }
        return .{ .object = result };
    }

    fn serializeToolCallResult(self: *Self, tool_result: tools_mod.ToolResult) ![]const u8 {
        var arena: std.heap.ArenaAllocator = .init(self.allocator);
        defer arena.deinit();

        const result_value = try buildToolCallResultValue(arena.allocator(), tool_result);
        var buffer: std.ArrayList(u8) = .empty;
        defer buffer.deinit(self.allocator);

        try jsonrpc.serializeValue(self.allocator, &buffer, result_value);
        return buffer.toOwnedSlice(self.allocator);
    }

    fn buildTaskObject(allocator: std.mem.Allocator, task: types.Task) !std.json.ObjectMap {
        var task_obj: std.json.ObjectMap = .empty;
        try task_obj.put(allocator, "taskId", .{ .string = task.taskId });
        try task_obj.put(allocator, "status", .{ .string = task.status.toString() });
        if (task.statusMessage) |msg| {
            try task_obj.put(allocator, "statusMessage", .{ .string = msg });
        }
        try task_obj.put(allocator, "createdAt", .{ .string = task.createdAt });
        try task_obj.put(allocator, "lastUpdatedAt", .{ .string = task.lastUpdatedAt });
        if (task.ttl) |ttl| {
            try task_obj.put(allocator, "ttl", .{ .integer = ttl });
        }
        if (task.pollInterval) |interval| {
            try task_obj.put(allocator, "pollInterval", .{ .integer = interval });
        }
        return task_obj;
    }

    fn putIcons(allocator: std.mem.Allocator, obj: *std.json.ObjectMap, icons: []const types.Icon) !void {
        var icons_array: std.json.Array = .init(allocator);
        for (icons) |icon| {
            var icon_obj: std.json.ObjectMap = .empty;
            try icon_obj.put(allocator, "src", .{ .string = icon.src });
            if (icon.mimeType) |mime| {
                try icon_obj.put(allocator, "mimeType", .{ .string = mime });
            }
            if (icon.sizes) |sizes| {
                var sizes_array: std.json.Array = .init(allocator);
                for (sizes) |size| {
                    try sizes_array.append(.{ .string = size });
                }
                try icon_obj.put(allocator, "sizes", .{ .array = sizes_array });
            }
            if (icon.theme) |theme| {
                try icon_obj.put(allocator, "theme", .{ .string = @tagName(theme) });
            }
            try icons_array.append(.{ .object = icon_obj });
        }
        try obj.put(allocator, "icons", .{ .array = icons_array });
    }

    fn putAnnotations(allocator: std.mem.Allocator, obj: *std.json.ObjectMap, annotations: types.Annotations) !void {
        var ann_obj: std.json.ObjectMap = .empty;
        if (annotations.audience) |aud| {
            var aud_array: std.json.Array = .init(allocator);
            for (aud) |role| {
                try aud_array.append(.{ .string = role.toString() });
            }
            try ann_obj.put(allocator, "audience", .{ .array = aud_array });
        }
        if (annotations.priority) |priority| {
            try ann_obj.put(allocator, "priority", .{ .float = priority });
        }
        if (annotations.lastModified) |last_modified| {
            try ann_obj.put(allocator, "lastModified", .{ .string = last_modified });
        }
        try obj.put(allocator, "annotations", .{ .object = ann_obj });
    }

    /// Marks a result as fully satisfied: `resultType: "complete"`.
    /// Every result emitted by the server carries this in MCP 2026-07-28.
    fn putResultComplete(allocator: std.mem.Allocator, result: *std.json.ObjectMap) !void {
        try result.put(allocator, "resultType", .{ .string = protocol.RESULT_TYPE_COMPLETE });
    }

    /// Emits the mandatory caching hints on a cacheable result:
    /// `ttlMs` (clamped to >= 0) and `cacheScope`.
    fn putCacheHints(
        allocator: std.mem.Allocator,
        result: *std.json.ObjectMap,
        ttl_ms: i64,
        scope: types.CacheScope,
    ) !void {
        const clamped = if (ttl_ms < 0) 0 else ttl_ms;
        try result.put(allocator, "ttlMs", .{ .integer = clamped });
        try result.put(allocator, "cacheScope", .{ .string = scope.toString() });
    }

    /// Convenience: emit the standard list/discover cache hints.
    fn putListCacheHints(self: *Self, allocator: std.mem.Allocator, result: *std.json.ObjectMap) !void {
        try Self.putCacheHints(allocator, result, self.config.cache.ttl_ms, self.config.cache.scope);
    }

    /// Convenience: emit cache hints for `resources/read` results, which are
    /// treated as user-specific by default.
    fn putReadCacheHints(self: *Self, allocator: std.mem.Allocator, result: *std.json.ObjectMap) !void {
        try Self.putCacheHints(allocator, result, self.config.cache.read_ttl_ms, self.config.cache.read_scope);
    }

    /// Emits the server identity under the spec-mandated namespaced `_meta`
    /// key instead of a top-level `serverInfo` field.
    fn putServerInfoMeta(
        allocator: std.mem.Allocator,
        result: *std.json.ObjectMap,
        config: ServerConfig,
    ) !void {
        var server_info: std.json.ObjectMap = .empty;
        try server_info.put(allocator, "name", .{ .string = config.name });
        try server_info.put(allocator, "version", .{ .string = config.version });
        if (config.title) |t| try server_info.put(allocator, "title", .{ .string = t });
        if (config.description) |d| try server_info.put(allocator, "description", .{ .string = d });
        if (config.icons) |icons| try putIcons(allocator, &server_info, icons);
        if (config.websiteUrl) |u| try server_info.put(allocator, "websiteUrl", .{ .string = u });

        // Preserve any caller-supplied _meta fields on the result.
        var meta: std.json.ObjectMap = .empty;
        if (result.get("_meta")) |existing| {
            if (existing == .object) {
                var it = existing.object.iterator();
                while (it.next()) |entry| {
                    try meta.put(allocator, entry.key_ptr.*, entry.value_ptr.*);
                }
            }
        }
        try meta.put(allocator, protocol.META_SERVER_INFO, .{ .object = server_info });
        try result.put(allocator, "_meta", .{ .object = meta });
    }

    fn log(self: *Self, io: anytype, message: []const u8) void {
        if (self.stdio_transport) |t| {
            t.writeStderr(io, message);
        }
    }

    fn logError(self: *Self, io: anytype, message: []const u8) void {
        if (self.stdio_transport) |t| {
            var buf: [512]u8 = undefined;
            const formatted = std.fmt.bufPrint(&buf, "ERROR: {s}", .{message}) catch message;
            t.writeStderr(io, formatted);
        }
    }
};

test "Server initialization" {
    var server = Server.init(std.testing.allocator, .{
        .name = "test-server",
        .version = "1.0.0",
    });
    defer server.deinit();

    try std.testing.expectEqual(ServerState.ready, server.state);
    try std.testing.expectEqualStrings("test-server", server.config.name);
}

test "Server add tool" {
    var server = Server.init(std.testing.allocator, .{
        .name = "test-server",
        .version = "1.0.0",
    });
    defer server.deinit();

    const tool: tools_mod.Tool = .{
        .name = "test_tool",
        .description = "A test tool",
        .handler = struct {
            fn handler(_: ?*anyopaque, _: std.Io, _: std.mem.Allocator, _: ?std.json.Value) !tools_mod.ToolResult {
                return .{ .content = &.{} };
            }
        }.handler,
    };

    try server.addTool(tool);
    try std.testing.expect(server.tools.contains("test_tool"));
    try std.testing.expect(server.capabilities.tools != null);
}

test "Server add resource" {
    var server = Server.init(std.testing.allocator, .{
        .name = "test-server",
        .version = "1.0.0",
    });
    defer server.deinit();

    try server.addResource(.{
        .uri = "file:///test",
        .name = "Test",
        .handler = struct {
            fn handler(_: ?*anyopaque, _: std.Io, _: std.mem.Allocator, uri: []const u8) !resources_mod.ResourceContent {
                return .{ .uri = uri };
            }
        }.handler,
    });
    try std.testing.expect(server.resources.contains("file:///test"));
    try std.testing.expect(server.capabilities.resources != null);
}

test "Server add prompt" {
    var server = Server.init(std.testing.allocator, .{
        .name = "test-server",
        .version = "1.0.0",
    });
    defer server.deinit();

    try server.addPrompt(.{
        .name = "test_prompt",
        .description = "A test prompt",
        .handler = struct {
            fn handler(_: ?*anyopaque, _: std.Io, _: std.mem.Allocator, _: ?std.json.Value) ![]const prompts_mod.PromptMessage {
                return &.{};
            }
        }.handler,
    });
    try std.testing.expect(server.prompts.contains("test_prompt"));
    try std.testing.expect(server.capabilities.prompts != null);
}

test "Server enable capabilities" {
    var server = Server.init(std.testing.allocator, .{
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

test "Server shutdown" {
    var server = Server.init(std.testing.allocator, .{
        .name = "test-server",
        .version = "1.0.0",
    });
    defer server.deinit();

    try std.testing.expectEqual(ServerState.ready, server.state);
    server.shutdown();
    try std.testing.expectEqual(ServerState.shutting_down, server.state);
    try std.testing.expect(server.isShuttingDown());
}

test "Server isShuttingDown" {
    var server = Server.init(std.testing.allocator, .{
        .name = "test-server",
        .version = "1.0.0",
    });
    defer server.deinit();

    try std.testing.expect(!server.isShuttingDown());
    server.shutdown();
    try std.testing.expect(server.isShuttingDown());
}

test "Server health check state" {
    var server = Server.init(std.testing.allocator, .{
        .name = "test-server",
        .version = "1.0.0",
    });
    defer server.deinit();

    // Server should be ready initially
    try std.testing.expectEqual(ServerState.ready, server.state);
    try std.testing.expect(!server.isShuttingDown());

    // After shutdown, state should change
    server.shutdown();
    try std.testing.expectEqual(ServerState.shutting_down, server.state);
    try std.testing.expect(server.isShuttingDown());
}

test "Server add tool with annotations" {
    var server = Server.init(std.testing.allocator, .{
        .name = "test-server",
        .version = "1.0.0",
    });
    defer server.deinit();

    const tool: tools_mod.Tool = .{
        .name = "test_tool",
        .description = "A test tool",
        .annotations = .{ .readOnlyHint = true, .idempotentHint = true },
        .handler = struct {
            fn handler(_: ?*anyopaque, _: std.Io, _: std.mem.Allocator, _: ?std.json.Value) !tools_mod.ToolResult {
                return .{ .content = &.{} };
            }
        }.handler,
    };

    try server.addTool(tool);
    try std.testing.expect(server.tools.contains("test_tool"));
    try std.testing.expect(server.capabilities.tools != null);
}

test "Server add resource with annotations" {
    var server = Server.init(std.testing.allocator, .{
        .name = "test-server",
        .version = "1.0.0",
    });
    defer server.deinit();

    try server.addResource(.{
        .uri = "file:///test",
        .name = "Test",
        .description = "A test resource",
        .mimeType = "text/plain",
        .handler = struct {
            fn handler(_: ?*anyopaque, _: std.Io, _: std.mem.Allocator, uri: []const u8) !resources_mod.ResourceContent {
                return .{ .uri = uri };
            }
        }.handler,
    });
    try std.testing.expect(server.resources.contains("file:///test"));
    try std.testing.expect(server.capabilities.resources != null);
}

test "Server add prompt with description" {
    var server = Server.init(std.testing.allocator, .{
        .name = "test-server",
        .version = "1.0.0",
    });
    defer server.deinit();

    try server.addPrompt(.{
        .name = "test_prompt",
        .description = "A test prompt",
        .handler = struct {
            fn handler(_: ?*anyopaque, _: std.Io, _: std.mem.Allocator, _: ?std.json.Value) ![]const prompts_mod.PromptMessage {
                return &.{};
            }
        }.handler,
    });
    try std.testing.expect(server.prompts.contains("test_prompt"));
    try std.testing.expect(server.capabilities.prompts != null);
}

// --- MCP 2026-07-28 spec conformance tests (issue #14) ---

/// Captures the JSON a handler emits so tests can assert on the wire format.
const CaptureTransport = struct {
    buf: std.ArrayList(u8) = .empty,
    allocator: std.mem.Allocator,
    captured: ?[]const u8 = null,

    fn send(self: *CaptureTransport, _: std.Io, _: std.mem.Allocator, message: []const u8) !void {
        // `message` and the allocator we are handed both live in a per-request
        // arena that is freed when the handler returns, so copy into storage
        // owned by this struct using the test allocator.
        self.buf.clearRetainingCapacity();
        try self.buf.appendSlice(self.allocator, message);
        self.captured = self.buf.items;
    }
    fn receive(_: *CaptureTransport, _: std.Io, _: std.mem.Allocator) transport_mod.Transport.ReceiveError!?[]const u8 {
        return null;
    }
    fn close(_: *CaptureTransport) void {}
    fn deinitCapture(self: *CaptureTransport) void {
        self.buf.deinit(self.allocator);
    }
};

/// Runs one request through the server and returns the parsed result object.
fn runRequest(
    server: *Server,
    allocator: std.mem.Allocator,
    method: []const u8,
    params_json: ?[]const u8,
) !std.json.Parsed(std.json.Value) {
    var cap = CaptureTransport{ .allocator = allocator };
    defer cap.deinitCapture();
    const prev_transport = server.transport;
    defer server.transport = prev_transport;
    server.transport = .{
        .ptr = &cap,
        .vtable = &.{
            .send = struct {
                fn f(p: *anyopaque, io: std.Io, a: std.mem.Allocator, m: []const u8) transport_mod.Transport.SendError!void {
                    const self: *CaptureTransport = @ptrCast(@alignCast(p));
                    return self.send(io, a, m);
                }
            }.f,
            .receive = struct {
                fn f(p: *anyopaque, io: std.Io, a: std.mem.Allocator) transport_mod.Transport.ReceiveError!?[]const u8 {
                    const self: *CaptureTransport = @ptrCast(@alignCast(p));
                    return self.receive(io, a);
                }
            }.f,
            .close = struct {
                fn f(p: *anyopaque) void {
                    const self: *CaptureTransport = @ptrCast(@alignCast(p));
                    self.close();
                }
            }.f,
            .destroy = struct {
                fn f(_: *anyopaque, _: std.mem.Allocator) void {}
            }.f,
        },
    };

    const raw_request = if (params_json) |p|
        std.fmt.allocPrint(allocator, "{{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"{s}\",\"params\":{s}}}", .{ method, p }) catch return error.OutOfMemory
    else
        std.fmt.allocPrint(allocator, "{{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"{s}\"}}", .{method}) catch return error.OutOfMemory;
    defer allocator.free(raw_request);

    try server.handleMessage(std.Io.failing, allocator, raw_request);

    const raw = cap.captured orelse return error.NoResponseCaptured;
    return std.json.parseFromSlice(std.json.Value, allocator, raw, .{});
}

/// Borrows the `result` object of a parsed response. The caller must keep
/// `parsed` alive for as long as the returned map is used.
fn resultOf(parsed: std.json.Parsed(std.json.Value)) !std.json.ObjectMap {
    const res_obj = parsed.value.object.get("result") orelse return error.NoResultField;
    if (res_obj != .object) return error.ResultNotObject;
    return res_obj.object;
}

fn expectResultType(result: std.json.ObjectMap) !void {
    const rt = result.get("resultType") orelse return error.MissingResultType;
    try std.testing.expectEqualStrings("complete", rt.string);
}

fn expectCacheHints(result: std.json.ObjectMap, ttl: i64, scope: []const u8) !void {
    const ttl_val = result.get("ttlMs") orelse return error.MissingTtlMs;
    try std.testing.expectEqual(@as(i64, ttl), ttl_val.integer);
    const scope_val = result.get("cacheScope") orelse return error.MissingCacheScope;
    try std.testing.expectEqualStrings(scope, scope_val.string);
}

test "spec: server/discover emits resultType, cache hints and _meta serverInfo" {
    const allocator = std.testing.allocator;
    var server = Server.init(allocator, .{ .name = "spec-server", .version = "9.9.9" });
    defer server.deinit();

    const parsed = try runRequest(&server, allocator, "server/discover", null);
    defer parsed.deinit();
    const result = try resultOf(parsed);

    try expectResultType(result);
    try expectCacheHints(result, protocol.DEFAULT_CACHE_TTL_MS, "public");

    // serverInfo must live under the namespaced _meta key, not at top level.
    try std.testing.expect(result.get("serverInfo") == null);
    const meta = result.get("_meta") orelse return error.MissingMeta;
    const meta_obj = meta.object;
    const info = meta_obj.get(protocol.META_SERVER_INFO) orelse return error.MissingServerInfoMeta;
    try std.testing.expectEqualStrings("spec-server", info.object.get("name").?.string);
    try std.testing.expectEqualStrings("9.9.9", info.object.get("version").?.string);

    // supportedVersions and capabilities remain top-level.
    try std.testing.expect(result.get("supportedVersions") != null);
    try std.testing.expect(result.get("capabilities") != null);
}

test "spec: cacheable list results carry ttlMs and cacheScope" {
    const allocator = std.testing.allocator;
    var server = Server.init(allocator, .{ .name = "list-server", .version = "1.0.0" });
    defer server.deinit();

    try server.addTool(.{
        .name = "noop",
        .description = "does nothing",
        .handler = struct {
            fn handler(_: ?*anyopaque, _: std.Io, a: std.mem.Allocator, _: ?std.json.Value) tools_mod.ToolError!tools_mod.ToolResult {
                return tools_mod.textResult(a, "ok") catch return tools_mod.ToolError.OutOfMemory;
            }
        }.handler,
    });

    for ([_][]const u8{ "tools/list", "prompts/list", "resources/list", "resources/templates/list" }) |method| {
        const parsed = try runRequest(&server, allocator, method, null);
        defer parsed.deinit();
        const result = try resultOf(parsed);
        try expectResultType(result);
        try expectCacheHints(result, protocol.DEFAULT_CACHE_TTL_MS, "public");
    }
}

test "spec: resources/read uses the private read cache scope" {
    const allocator = std.testing.allocator;
    var server = Server.init(allocator, .{ .name = "read-server", .version = "1.0.0" });
    defer server.deinit();

    try server.addResource(.{
        .uri = "mem://thing",
        .name = "Thing",
        .mimeType = "text/plain",
        .handler = struct {
            fn handler(_: ?*anyopaque, _: std.Io, _: std.mem.Allocator, uri: []const u8) resources_mod.ResourceError!resources_mod.ResourceContent {
                return .{ .uri = uri, .mimeType = "text/plain", .text = "data" };
            }
        }.handler,
    });

    const parsed = try runRequest(&server, allocator, "resources/read", "{\"uri\":\"mem://thing\"}");
    defer parsed.deinit();

    const result = try resultOf(parsed);
    try expectResultType(result);
    try expectCacheHints(result, protocol.DEFAULT_RESOURCE_READ_TTL_MS, "private");
    try std.testing.expect(result.get("contents") != null);
}

test "spec: cache configuration overrides defaults" {
    const allocator = std.testing.allocator;
    var server = Server.init(allocator, .{
        .name = "cfg-server",
        .version = "1.0.0",
        .cache = .{ .ttl_ms = 42, .scope = .private, .read_ttl_ms = 7, .read_scope = .public },
    });
    defer server.deinit();

    const parsed = try runRequest(&server, allocator, "tools/list", null);
    defer parsed.deinit();
    const list = try resultOf(parsed);
    try expectCacheHints(list, 42, "private");
}

test "spec: negative ttlMs is clamped to zero" {
    const allocator = std.testing.allocator;
    var server = Server.init(allocator, .{
        .name = "clamp-server",
        .version = "1.0.0",
        .cache = .{ .ttl_ms = -5000 },
    });
    defer server.deinit();

    const parsed = try runRequest(&server, allocator, "tools/list", null);
    defer parsed.deinit();
    const result = try resultOf(parsed);
    try expectCacheHints(result, 0, "public");
}

test "spec: tools/list returns a deterministic order" {
    const allocator = std.testing.allocator;

    const Handler = struct {
        fn handler(_: ?*anyopaque, _: std.Io, a: std.mem.Allocator, _: ?std.json.Value) tools_mod.ToolError!tools_mod.ToolResult {
            return tools_mod.textResult(a, "ok") catch return tools_mod.ToolError.OutOfMemory;
        }
    };

    // Insert in a scrambled order across many tools; repeated calls must agree.
    const names = [_][]const u8{ "zeta", "alpha", "mike", "bravo", "delta", "echo", "yankee", "charlie", "golf", "hotel" };

    var server = Server.init(allocator, .{ .name = "order-server", .version = "1.0.0" });
    defer server.deinit();
    for (names) |n| {
        try server.addTool(.{ .name = n, .description = "x", .handler = Handler.handler });
    }

    const parsed = try runRequest(&server, allocator, "tools/list", null);
    defer parsed.deinit();
    const first = try resultOf(parsed);
    const first_tools = first.get("tools").?.array;
    for (0..5) |_| {
        const reparsed = try runRequest(&server, allocator, "tools/list", null);
        defer reparsed.deinit();
        const again = try resultOf(reparsed);
        const again_tools = again.get("tools").?.array;
        try std.testing.expectEqual(first_tools.items.len, again_tools.items.len);
        for (first_tools.items, again_tools.items) |a, b| {
            try std.testing.expectEqualStrings(
                a.object.get("name").?.string,
                b.object.get("name").?.string,
            );
        }
    }

    // And the order itself is sorted ascending by name.
    for (first_tools.items, 0..) |item, i| {
        if (i + 1 < first_tools.items.len) {
            const cur = item.object.get("name").?.string;
            const next = first_tools.items[i + 1].object.get("name").?.string;
            try std.testing.expect(std.mem.lessThan(u8, cur, next));
        }
    }
}

test "spec: prompts/get and health/check carry resultType" {
    const allocator = std.testing.allocator;
    var server = Server.init(allocator, .{ .name = "misc-server", .version = "1.0.0" });
    defer server.deinit();

    try server.addPrompt(.{
        .name = "hi",
        .description = "say hi",
        .handler = struct {
            fn handler(_: ?*anyopaque, _: std.Io, _: std.mem.Allocator, _: ?std.json.Value) prompts_mod.PromptError![]const prompts_mod.PromptMessage {
                return &.{};
            }
        }.handler,
    });

    const parsed = try runRequest(&server, allocator, "prompts/get", "{\"name\":\"hi\"}");
    defer parsed.deinit();
    const prompt = try resultOf(parsed);
    try expectResultType(prompt);

    const parsed_health = try runRequest(&server, allocator, "health/check", null);
    defer parsed_health.deinit();
    const health = try resultOf(parsed_health);
    try expectResultType(health);
    try std.testing.expect(health.get("serverInfo") == null);
    try std.testing.expect(health.get("_meta") != null);
}

test "spec: _meta serverInfo merges with pre-existing _meta keys" {
    const allocator = std.testing.allocator;
    var server = Server.init(allocator, .{ .name = "merge-server", .version = "2.0.0" });
    defer server.deinit();

    var result: std.json.ObjectMap = .empty;
    defer result.deinit(allocator);
    var existing: std.json.ObjectMap = .empty;
    defer existing.deinit(allocator);
    try existing.put(allocator, "custom", .{ .string = "keep-me" });
    try result.put(allocator, "_meta", .{ .object = existing });

    try Server.putServerInfoMeta(allocator, &result, server.config);

    // putServerInfoMeta builds a new _meta object; release it explicitly.
    var built_meta = result.get("_meta").?.object;
    defer built_meta.deinit(allocator);

    const meta = built_meta;
    try std.testing.expectEqualStrings("keep-me", meta.get("custom").?.string);
    var info_obj = meta.get(protocol.META_SERVER_INFO).?.object;
    defer info_obj.deinit(allocator);
    try std.testing.expectEqualStrings("merge-server", info_obj.get("name").?.string);
}
