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
const client_mod = @import("../client/client.zig");
const prompts_mod = @import("prompts.zig");
const resources_mod = @import("resources.zig");
const tools_mod = @import("tools.zig");
const http_rules = @import("http_rules.zig");

/// Streamable HTTP rules (header validation, Origin checks).
pub const HttpRules = http_rules;

fn isLoopbackHost(host: []const u8) bool {
    return http_rules.isLoopbackHostName(if (host.len == 0) "localhost" else host);
}

/// Builds a JSON-RPC error body wrapped in an HTTP response, used for the
/// status-code mapping required by the Streamable HTTP binding.
///
/// The serialized body is allocated from `allocator`, which is the httpx
/// per-request arena and is released once the response has been written.
fn jsonRpcHttpError(
    allocator: std.mem.Allocator,
    status: u16,
    id: ?types.RequestId,
    code: i32,
    message: []const u8,
    data: ?std.json.Value,
) httpx.Response {
    const response = jsonrpc.createErrorResponse(id, code, message, data);
    const json = jsonrpc.serializeMessage(allocator, .{ .error_response = response }) catch {
        return .{ .status = status, .body = message, .contentType = "application/json" };
    };
    return .{
        .status = status,
        .body = json,
        .contentType = "application/json",
    };
}

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
    /// Maximum entries per page on `*/list` requests. Zero (the default)
    /// returns everything in a single page, which is valid: `nextCursor` is
    /// then omitted entirely.
    page_size: usize = 0,
    /// Builds the MRTR response when a handler returns `error.InputRequired`.
    ///
    /// A server that needs client input (elicitation, sampling or roots)
    /// signals it from a tool, resource or prompt handler by returning
    /// `error.InputRequired`; this hook turns that into the
    /// `InputRequiredResult` the client is asked to satisfy. It receives the
    /// request params so it can inspect any `inputResponses` and
    /// `requestState` echoed back on a retry.
    mrtr: ?*const fn (
        user_data: ?*anyopaque,
        method: []const u8,
        params: ?std.json.Value,
        allocator: std.mem.Allocator,
    ) anyerror!types.InputRequiredResult = null,
    /// Passed to the `mrtr` hook.
    mrtr_user_data: ?*anyopaque = null,
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
    /// Request ids the client has cancelled via `notifications/cancelled`.
    /// Handlers poll `isCancelled` and the server answers with -32800.
    cancelled_requests: std.AutoHashMap(i64, void),
    log_level: protocol.LogLevel = .info,
    /// Host the HTTP listener is bound to, used for Origin validation.
    http_host: ?[]const u8 = null,
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
            .cancelled_requests = .init(allocator),
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
        self.cancelled_requests.deinit();
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
        self.http_host = config.host;

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
        const config = mcp_server.http_host orelse "127.0.0.1";

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
            return jsonRpcHttpError(ctx.allocator, 400, null, jsonrpc.ErrorCode.INVALID_REQUEST, "Empty request body", null);
        }

        // Streamable HTTP conformance: validate headers against the body and
        // map the outcome onto the status codes the spec prescribes.
        const verdict = http_rules.validate(
            ctx.allocator,
            .{ .context = ctx },
            body,
            // Servers bound to a loopback host reject cross-origin browser
            // requests (DNS rebinding protection).
            isLoopbackHost(config),
        ) catch |err| {
            std.log.warn("HTTP request validation failed: {s}", .{@errorName(err)});
            return jsonRpcHttpError(ctx.allocator, 400, null, jsonrpc.ErrorCode.INVALID_REQUEST, "Invalid request", null);
        };

        switch (verdict) {
            .forbidden_origin => {
                return .{ .status = 403, .body = "Forbidden", .contentType = "text/plain; charset=utf-8" };
            },
            .invalid_request => |d| {
                return jsonRpcHttpError(ctx.allocator, 400, null, jsonrpc.ErrorCode.INVALID_REQUEST, d.message, null);
            },
            // A required _meta field is absent: malformed request, -32602/400.
            .invalid_params => |d| {
                return jsonRpcHttpError(ctx.allocator, 400, null, jsonrpc.ErrorCode.INVALID_PARAMS, d.message, null);
            },
            .missing_header => |d| {
                return jsonRpcHttpError(ctx.allocator, 400, null, jsonrpc.ErrorCode.HEADER_MISMATCH, d.name, null);
            },
            .mismatch => |d| {
                return jsonRpcHttpError(ctx.allocator, 400, null, jsonrpc.ErrorCode.HEADER_MISMATCH, d.message, null);
            },
            .unsupported_version => |d| {
                var supported: std.json.Array = .init(ctx.allocator);
                for (d.supported) |v| supported.append(.{ .string = v }) catch {};
                var info_map: std.json.ObjectMap = .empty;
                info_map.put(ctx.allocator, "supported", .{ .array = supported }) catch {};
                info_map.put(ctx.allocator, "requested", .{ .string = d.requested }) catch {};

                return jsonRpcHttpError(ctx.allocator, 400, null, jsonrpc.ErrorCode.UNSUPPORTED_PROTOCOL_VERSION, "Unsupported protocol version", .{ .object = info_map });
            },
            .accepted_notification => {
                return .{ .status = 202, .body = "" };
            },
            .unknown_method => |d| {
                // Spec: unknown RPC method is 404 with -32601.
                return jsonRpcHttpError(ctx.allocator, 404, null, jsonrpc.ErrorCode.METHOD_NOT_FOUND, d.method, null);
            },
            .ok => {},
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
            } else {
                // Transports that report "nothing queued" by returning null
                // instead of blocking (HttpTransport does) would otherwise
                // spin a core at 100% while waiting for a response.
                std.Io.sleep(io, .{ .nanoseconds = std.time.ns_per_ms }, .real) catch {};
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

        const page = try Self.paginate(allocator, keys, Self.requestCursor(request.params), self.config.page_size);
        defer if (page.next_cursor) |c| allocator.free(c);

        for (page.items) |key| {
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
        try Self.putNextCursor(allocator, &result, page.next_cursor);
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
                // A handler that needs more client input opts into MRTR by
                // returning error.InputRequired.
                if (err == error.InputRequired) {
                    if (try self.sendInputRequiredIfRequested(io, allocator, request)) return;
                }
                var content = try allocator.alloc(types.ContentBlock, 1);
                content[0] = .{ .text = .{ .text = @errorName(err) } };
                const result_value = try buildToolCallResultValue(allocator, .{ .content = content, .is_error = true });
                const response = jsonrpc.createResponse(request.id, result_value);
                try self.sendResponse(io, allocator, .{ .response = response });
                return;
            };

            // Cancellation is only meaningful while the request is in flight,
            // so the record is cleared once the result is known.
            defer self.clearCancelled(request.id);
            if (self.isCancelled(request.id)) {
                try self.sendResponse(io, allocator, .{ .error_response = Self.cancelledErrorResponse(request.id) });
                return;
            }

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

        const page = try Self.paginate(allocator, keys, Self.requestCursor(request.params), self.config.page_size);
        defer if (page.next_cursor) |c| allocator.free(c);

        for (page.items) |key| {
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
        try Self.putNextCursor(allocator, &result, page.next_cursor);
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
                if (err == error.InputRequired) {
                    if (try self.sendInputRequiredIfRequested(io, allocator, request)) return;
                }
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

        const page = try Self.paginate(allocator, keys, Self.requestCursor(request.params), self.config.page_size);
        defer if (page.next_cursor) |c| allocator.free(c);

        for (page.items) |key| {
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
        try Self.putNextCursor(allocator, &result, page.next_cursor);
        try Self.putResultComplete(allocator, &result);
        try self.putListCacheHints(allocator, &result);

        const response = jsonrpc.createResponse(request.id, .{ .object = result });
        try self.sendResponse(io, allocator, .{ .response = response });
    }

    /// Handle subscriptions/listen request (replaces resources/subscribe + resources/unsubscribe + HTTP GET)
    /// Builds the `io.modelcontextprotocol/subscriptionId` `_meta` object that
    /// every message on a subscription stream must carry.
    fn putSubscriptionIdMeta(
        allocator: std.mem.Allocator,
        meta: *std.json.ObjectMap,
        id: types.RequestId,
    ) !void {
        switch (id) {
            .integer => |i| try meta.put(allocator, protocol.META_SUBSCRIPTION_ID, .{ .integer = i }),
            .string => |s| try meta.put(allocator, protocol.META_SUBSCRIPTION_ID, .{ .string = s }),
        }
    }

    /// The client capability an MRTR input request depends on, or null when the
    /// method needs none.
    fn requiredCapabilityForMethod(method: []const u8) ?[]const u8 {
        if (std.mem.eql(u8, method, protocol.MRTR_METHOD_ELICITATION)) return "elicitation";
        if (std.mem.eql(u8, method, protocol.MRTR_METHOD_SAMPLING)) return "sampling";
        if (std.mem.eql(u8, method, protocol.MRTR_METHOD_ROOTS)) return "roots";
        return null;
    }

    /// Returns the first capability the client did not declare that the given
    /// input requests need, or null when everything is declared.
    ///
    /// The spec forbids sending an input request the client has not declared
    /// support for; e.g. an `elicitation/create` to a client that never
    /// advertised elicitation.
    fn undeclaredCapability(
        params: ?std.json.Value,
        input_requests: ?types.InputRequests,
    ) ?[]const u8 {
        const requests = input_requests orelse return null;
        const p = params orelse return null;
        if (p != .object) return null;
        const meta = p.object.get("_meta") orelse return null;
        if (meta != .object) return null;
        const caps = meta.object.get(protocol.META_CLIENT_CAPABILITIES) orelse return null;
        if (caps != .object) return null;

        var it = requests.iterator();
        while (it.next()) |entry| {
            const req_obj = entry.value_ptr.*;
            if (req_obj != .object) continue;
            const method_val = req_obj.object.get("method") orelse continue;
            if (method_val != .string) continue;

            const capability = requiredCapabilityForMethod(method_val.string) orelse continue;
            if (caps.object.get(capability) == null) return capability;
        }
        return null;
    }

    /// Builds the -32021 response for an undeclared capability.
    ///
    /// The spec requires `data.requiredCapabilities` to list the capabilities
    /// that were missing.
    fn missingCapabilityError(allocator: std.mem.Allocator, id: types.RequestId, capability: []const u8) jsonrpc.ErrorResponse {
        var names: std.json.Array = .init(allocator);
        names.append(.{ .string = capability }) catch {};
        var data: std.json.ObjectMap = .empty;
        data.put(allocator, "requiredCapabilities", .{ .array = names }) catch {};
        return jsonrpc.createErrorResponse(
            id,
            jsonrpc.ErrorCode.MISSING_REQUIRED_CLIENT_CAPABILITY,
            "Client did not declare a required capability",
            .{ .object = data },
        );
    }

    /// Emits an MRTR `InputRequiredResult` when a handler asked for more input.
    ///
    /// Returns true when the response was sent, so callers can return early.
    /// Without a configured `mrtr` hook there is nothing to build from, so this
    /// reports false and the caller falls back to a normal error response.
    fn sendInputRequiredIfRequested(
        self: *Self,
        io: anytype,
        allocator: std.mem.Allocator,
        request: jsonrpc.Request,
    ) !bool {
        const hook = self.config.mrtr orelse return false;
        const input_required = try hook(
            self.config.mrtr_user_data,
            request.method,
            request.params,
            allocator,
        );

        // The server must not ask for input the client never declared support
        // for; doing so is -32021 with data.requiredCapabilities.
        if (Self.undeclaredCapability(request.params, input_required.inputRequests)) |capability| {
            try self.sendResponse(io, allocator, .{ .error_response = Self.missingCapabilityError(allocator, request.id, capability) });
            return true;
        }

        try self.sendInputRequired(io, allocator, request.id, input_required);
        return true;
    }

    /// Handle a `subscriptions/listen` request.
    ///
    /// The server must acknowledge first, carrying the subscription's id in
    /// `_meta`, and must not send any other notification for that subscription
    /// before the acknowledgment. The `notifications` field reflects the subset
    /// of the requested filter the server agreed to honour; unsupported types
    /// are omitted. The closing response then signals a graceful end.
    fn handleSubscriptionsListen(self: *Self, io: anytype, allocator: std.mem.Allocator, request: jsonrpc.Request) !void {
        var requested: types.SubscriptionFilter = .{};
        if (request.params) |params| {
            if (params == .object) {
                if (params.object.get("notifications")) |n| {
                    if (n == .object) requested = Self.parseSubscriptionFilter(allocator, n.object);
                }
            }
        }

        // Honour only what this server actually supports.
        const agreed = types.SubscriptionFilter{
            .toolsListChanged = requested.toolsListChanged and
                self.capabilities.tools != null and self.capabilities.tools.?.listChanged,
            .promptsListChanged = requested.promptsListChanged and
                self.capabilities.prompts != null and self.capabilities.prompts.?.listChanged,
            .resourcesListChanged = requested.resourcesListChanged and
                self.capabilities.resources != null and self.capabilities.resources.?.listChanged,
            .resourceSubscriptions = if (self.capabilities.resources != null)
                requested.resourceSubscriptions
            else
                null,
        };

        var ack_meta: std.json.ObjectMap = .empty;
        try Self.putSubscriptionIdMeta(allocator, &ack_meta, request.id);

        var ack_filter: std.json.ObjectMap = .empty;
        if (agreed.toolsListChanged) try ack_filter.put(allocator, "toolsListChanged", .{ .bool = true });
        if (agreed.promptsListChanged) try ack_filter.put(allocator, "promptsListChanged", .{ .bool = true });
        if (agreed.resourcesListChanged) try ack_filter.put(allocator, "resourcesListChanged", .{ .bool = true });
        if (agreed.resourceSubscriptions) |uris| {
            if (uris.len > 0) {
                var arr: std.json.Array = .init(allocator);
                for (uris) |u| try arr.append(.{ .string = u });
                try ack_filter.put(allocator, "resourceSubscriptions", .{ .array = arr });
            }
        }

        // The subscription id travels in params._meta, not at the top of
        // params, alongside the agreed filter.
        var ack_params: std.json.ObjectMap = .empty;
        try ack_params.put(allocator, "_meta", .{ .object = ack_meta });
        try ack_params.put(allocator, "notifications", .{ .object = ack_filter });

        try self.sendNotification(io, allocator, "notifications/subscriptions/acknowledged", .{ .object = ack_params });

        var result: std.json.ObjectMap = .empty;
        try Self.putResultComplete(allocator, &result);
        var close_meta: std.json.ObjectMap = .empty;
        try Self.putSubscriptionIdMeta(allocator, &close_meta, request.id);
        try result.put(allocator, "_meta", .{ .object = close_meta });

        const response = jsonrpc.createResponse(request.id, .{ .object = result });
        try self.sendResponse(io, allocator, .{ .response = response });
    }

    /// Reads a `notifications` filter object, ignoring malformed entries.
    fn parseSubscriptionFilter(allocator: std.mem.Allocator, obj: std.json.ObjectMap) types.SubscriptionFilter {
        var filter: types.SubscriptionFilter = .{};
        if (obj.get("toolsListChanged")) |v| {
            if (v == .bool) filter.toolsListChanged = v.bool;
        }
        if (obj.get("promptsListChanged")) |v| {
            if (v == .bool) filter.promptsListChanged = v.bool;
        }
        if (obj.get("resourcesListChanged")) |v| {
            if (v == .bool) filter.resourcesListChanged = v.bool;
        }
        if (obj.get("resourceSubscriptions")) |v| {
            if (v == .array) {
                var list: std.ArrayList([]const u8) = .empty;
                for (v.array.items) |item| {
                    if (item == .string) list.append(allocator, item.string) catch return filter;
                }
                filter.resourceSubscriptions = list.items;
            }
        }
        return filter;
    }

    /// Handle prompts/list request
    fn handlePromptsList(self: *Self, io: anytype, allocator: std.mem.Allocator, request: jsonrpc.Request) !void {
        var prompts_array: std.json.Array = .init(allocator);

        const keys = try Self.sortedKeys(allocator, @TypeOf(self.prompts), &self.prompts);
        defer allocator.free(keys);

        const page = try Self.paginate(allocator, keys, Self.requestCursor(request.params), self.config.page_size);
        defer if (page.next_cursor) |c| allocator.free(c);

        for (page.items) |key| {
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
        try Self.putNextCursor(allocator, &result, page.next_cursor);
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
                if (err == error.InputRequired) {
                    if (try self.sendInputRequiredIfRequested(io, allocator, request)) return;
                }
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

    /// One page of a sorted key list, plus the cursor for the page after it.
    const Page = struct {
        items: []const []const u8,
        next_cursor: ?[]const u8,
    };

    /// Encodes a pagination cursor. The value is opaque to clients, so the
    /// offset is base64-encoded rather than sent as a plain integer.
    fn encodeCursor(allocator: std.mem.Allocator, index: usize) ![]const u8 {
        const decimal = try std.fmt.allocPrint(allocator, "{d}", .{index});
        defer allocator.free(decimal);
        return protocol.base64Alloc(allocator, decimal);
    }

    /// Decodes a cursor produced by `encodeCursor`, or null when unusable.
    ///
    /// A malformed cursor is treated as "start from the beginning" rather
    /// than as an error, so a client holding a stale cursor still gets a
    /// usable response.
    fn decodeCursor(allocator: std.mem.Allocator, cursor: []const u8) ?usize {
        const decoder = std.base64.standard.Decoder;
        const size = decoder.calcSizeForSlice(cursor) catch return null;
        const buf = allocator.alloc(u8, size) catch return null;
        defer allocator.free(buf);
        decoder.decode(buf, cursor) catch return null;
        return std.fmt.parseInt(usize, buf, 10) catch null;
    }

    /// Slices `keys` into the page starting at `cursor`, honouring
    /// `page_size`. A `page_size` of zero yields everything in one page and no
    /// cursor.
    fn paginate(
        allocator: std.mem.Allocator,
        keys: []const []const u8,
        cursor: ?[]const u8,
        page_size: usize,
    ) !Page {
        const start: usize = if (cursor) |c| blk: {
            const idx = decodeCursor(allocator, c) orelse break :blk 0;
            break :blk @min(idx, keys.len);
        } else 0;

        if (page_size == 0 or start >= keys.len) {
            return .{ .items = keys[start..], .next_cursor = null };
        }

        const end = @min(start + page_size, keys.len);
        const next: ?[]const u8 = if (end < keys.len) try encodeCursor(allocator, end) else null;
        return .{ .items = keys[start..end], .next_cursor = next };
    }

    /// Reads the `cursor` request parameter, if present.
    fn requestCursor(params: ?std.json.Value) ?[]const u8 {
        const p = params orelse return null;
        if (p != .object) return null;
        const c = p.object.get("cursor") orelse return null;
        return if (c == .string) c.string else null;
    }

    /// Emits `nextCursor` when there is a further page.
    fn putNextCursor(allocator: std.mem.Allocator, result: *std.json.ObjectMap, next: ?[]const u8) !void {
        if (next) |c| try result.put(allocator, "nextCursor", .{ .string = c });
    }

    /// True when the client cancelled the request with the given id.
    ///
    /// Long-running handlers should poll this and return early; the spec
    /// requires every request to still produce a response, so the server
    /// answers a cancelled request with -32800.
    pub fn isCancelled(self: *Self, id: types.RequestId) bool {
        const numeric = switch (id) {
            .integer => |i| i,
            .string => return false,
        };
        return self.cancelled_requests.contains(numeric);
    }

    /// Clears a recorded cancellation, so a reused id starts fresh.
    pub fn clearCancelled(self: *Self, id: types.RequestId) void {
        const numeric = switch (id) {
            .integer => |i| i,
            .string => return,
        };
        _ = self.cancelled_requests.remove(numeric);
    }

    /// The JSON-RPC error a cancelled request should be answered with.
    fn cancelledErrorResponse(id: types.RequestId) jsonrpc.ErrorResponse {
        return jsonrpc.createErrorResponse(
            id,
            jsonrpc.ErrorCode.REQUEST_CANCELLED,
            "Request cancelled",
            null,
        );
    }

    /// Handle incoming notifications
    fn handleNotification(self: *Self, io: anytype, notification: jsonrpc.Notification) !void {
        if (std.mem.eql(u8, notification.method, "notifications/cancelled")) {
            if (notification.params) |params| {
                if (params == .object) {
                    if (params.object.get("requestId")) |req_id| {
                        // Record the cancellation so a long-running handler can
                        // observe it and the server can answer with -32800.
                        if (req_id == .integer) {
                            self.cancelled_requests.put(req_id.integer, {}) catch {};
                        }
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

    /// Builds an MRTR `InputRequiredResult` payload.
    ///
    /// The 2026-07-28 spec requires at least one of `inputRequests` or
    /// `requestState` on every such result, so returning neither is rejected
    /// here rather than emitted as a spec-invalid response.
    pub fn buildInputRequiredResult(
        allocator: std.mem.Allocator,
        input_required: types.InputRequiredResult,
    ) !std.json.ObjectMap {
        if (input_required.inputRequests == null and input_required.requestState == null) {
            return error.EmptyInputRequiredResult;
        }

        var result: std.json.ObjectMap = .empty;
        try result.put(allocator, "resultType", .{ .string = protocol.RESULT_TYPE_INPUT_REQUIRED });
        if (input_required.inputRequests) |requests| {
            try result.put(allocator, "inputRequests", .{ .object = requests });
        }
        if (input_required.requestState) |state| {
            try result.put(allocator, "requestState", .{ .string = state });
        }
        return result;
    }

    /// Adds one server-to-client request to an MRTR `InputRequests` map.
    ///
    /// `key` is the server-assigned identifier the client echoes back in the
    /// matching `InputResponses` entry, and must be unique within the request.
    pub fn putInputRequest(
        allocator: std.mem.Allocator,
        requests: *types.InputRequests,
        key: []const u8,
        method: []const u8,
        params: ?std.json.Value,
    ) !void {
        var request_obj: std.json.ObjectMap = .empty;
        try request_obj.put(allocator, "method", .{ .string = method });
        if (params) |p| {
            try request_obj.put(allocator, "params", p);
        }
        try requests.put(allocator, key, .{ .object = request_obj });
    }

    /// Sends an MRTR `InputRequiredResult` as the response to `id`.
    pub fn sendInputRequired(
        self: *Self,
        io: anytype,
        allocator: std.mem.Allocator,
        id: types.RequestId,
        input_required: types.InputRequiredResult,
    ) !void {
        const result = try Self.buildInputRequiredResult(allocator, input_required);
        const response = jsonrpc.createResponse(id, .{ .object = result });
        try self.sendResponse(io, allocator, .{ .response = response });
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

// MCP 2026-07-28 spec conformance tests (issue #14)

/// Captures the JSON a handler emits so tests can assert on the wire format.
const CaptureTransport = struct {
    buf: std.ArrayList(u8) = .empty,
    allocator: std.mem.Allocator,
    captured: ?[]const u8 = null,
    /// Every message written, in order, for tests that assert on the
    /// sequence (for example a notification preceding its response).
    messages: std.ArrayList([]u8) = .empty,

    fn send(self: *CaptureTransport, _: std.Io, al: std.mem.Allocator, message: []const u8) !void {
        // `message` and the allocator we are handed both live in a per-request
        // arena that is freed when the handler returns, so copy into storage
        // owned by this struct using the test allocator.
        self.buf.clearRetainingCapacity();
        try self.buf.appendSlice(self.allocator, message);
        self.captured = self.buf.items;

        // Same reasoning for the ordered log: allocate from the test allocator
        // rather than the per-request one.
        try self.messages.append(self.allocator, try self.allocator.dupe(u8, message));
        _ = al;
    }
    fn receive(_: *CaptureTransport, _: std.Io, _: std.mem.Allocator) transport_mod.Transport.ReceiveError!?[]const u8 {
        return null;
    }
    fn close(_: *CaptureTransport) void {}
    fn deinitCapture(self: *CaptureTransport) void {
        for (self.messages.items) |m| self.allocator.free(m);
        self.messages.deinit(self.allocator);
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

test "spec: MRTR InputRequiredResult carries inputRequests and requestState" {
    const allocator = std.testing.allocator;

    var requests: types.InputRequests = .empty;
    defer requests.deinit(allocator);

    var schema: std.json.ObjectMap = .empty;
    defer schema.deinit(allocator);
    var props: std.json.ObjectMap = .empty;
    defer props.deinit(allocator);
    try props.put(allocator, "name", .{ .string = "string" });
    try schema.put(allocator, "type", .{ .string = "object" });
    try schema.put(allocator, "properties", .{ .object = props });

    var params: std.json.ObjectMap = .empty;
    defer params.deinit(allocator);
    try params.put(allocator, "message", .{ .string = "Provide your GitHub username" });
    try params.put(allocator, "requestedSchema", .{ .object = schema });

    try Server.putInputRequest(allocator, &requests, "github_login", protocol.MRTR_METHOD_ELICITATION, .{ .object = params });

    var result = try Server.buildInputRequiredResult(allocator, .{
        .inputRequests = requests,
        .requestState = "opaque-blob",
    });
    defer result.deinit(allocator);

    try std.testing.expectEqualStrings("input_required", result.get("resultType").?.string);
    try std.testing.expectEqualStrings("opaque-blob", result.get("requestState").?.string);

    // inputRequests is a map keyed by the server-assigned identifier.
    const emitted = result.get("inputRequests").?.object;
    var entry = emitted.get("github_login").?.object;
    defer entry.deinit(allocator);
    try std.testing.expectEqualStrings("elicitation/create", entry.get("method").?.string);
    try std.testing.expect(entry.get("params") != null);
}

test "spec: MRTR rejects a result with neither inputRequests nor requestState" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(
        error.EmptyInputRequiredResult,
        Server.buildInputRequiredResult(allocator, .{}),
    );
}

test "spec: MRTR inputRequests may be omitted when only requestState is used" {
    const allocator = std.testing.allocator;

    var result = try Server.buildInputRequiredResult(allocator, .{ .requestState = "state-only" });
    defer result.deinit(allocator);

    try std.testing.expectEqualStrings("input_required", result.get("resultType").?.string);
    try std.testing.expect(result.get("inputRequests") == null);
}

test "spec: subscriptionId _meta key matches the spec namespace" {
    try std.testing.expectEqualStrings(
        "io.modelcontextprotocol/subscriptionId",
        protocol.META_SUBSCRIPTION_ID,
    );
}

test "spec: tools/call returning error.InputRequired emits an MRTR result" {
    const a = std.testing.allocator;

    // A handler that always needs more input.
    const needsInput = struct {
        fn handler(_: ?*anyopaque, _: std.Io, _: std.mem.Allocator, _: ?std.json.Value) tools_mod.ToolError!tools_mod.ToolResult {
            return tools_mod.ToolError.InputRequired;
        }
    }.handler;

    // The resolver builds the elicitation request the client must satisfy.
    const resolver = struct {
        fn f(_: ?*anyopaque, method: []const u8, _: ?std.json.Value, allocator: std.mem.Allocator) anyerror!types.InputRequiredResult {
            std.debug.assert(std.mem.eql(u8, method, "tools/call"));

            var schema: std.json.ObjectMap = .empty;
            var props: std.json.ObjectMap = .empty;
            try props.put(allocator, "name", .{ .string = "string" });
            try schema.put(allocator, "type", .{ .string = "object" });
            try schema.put(allocator, "properties", .{ .object = props });

            var params: std.json.ObjectMap = .empty;
            try params.put(allocator, "mode", .{ .string = "form" });
            try params.put(allocator, "message", .{ .string = "Provide your GitHub username" });
            try params.put(allocator, "requestedSchema", .{ .object = schema });

            var requests: types.InputRequests = .empty;
            try Server.putInputRequest(
                allocator,
                &requests,
                "github_login",
                protocol.MRTR_METHOD_ELICITATION,
                .{ .object = params },
            );

            return .{ .inputRequests = requests, .requestState = "opaque-state" };
        }
    }.f;

    var server = Server.init(a, .{
        .name = "mrtr-server",
        .version = "1.0.0",
        .mrtr = resolver,
    });
    defer server.deinit();

    try server.addTool(.{
        .name = "needs_input",
        .description = "Needs more input",
        .inputSchema = .{ .type = "object" },
        .handler = needsInput,
    });

    var collector = CaptureTransport{ .allocator = a };
    defer collector.deinitCapture();
    const prev_transport = server.transport;
    defer server.transport = prev_transport;
    server.transport = .{
        .ptr = &collector,
        .vtable = &.{
            .send = struct {
                fn f(p: *anyopaque, io: std.Io, al: std.mem.Allocator, m: []const u8) transport_mod.Transport.SendError!void {
                    const self: *CaptureTransport = @ptrCast(@alignCast(p));
                    self.send(io, al, m) catch return error.OutOfMemory;
                }
            }.f,
            .receive = struct {
                fn f(p: *anyopaque, io: std.Io, al: std.mem.Allocator) transport_mod.Transport.ReceiveError!?[]const u8 {
                    const self: *CaptureTransport = @ptrCast(@alignCast(p));
                    return self.receive(io, al);
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

    // The resolver asks for elicitation/create, so the client must declare it.
    const req = "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"tools/call\",\"params\":{\"name\":\"needs_input\",\"_meta\":{\"io.modelcontextprotocol/protocolVersion\":\"2026-07-28\",\"io.modelcontextprotocol/clientCapabilities\":{\"elicitation\":{}}}}}";
    try server.handleMessage(std.Io.failing, a, req);

    try std.testing.expectEqual(@as(usize, 1), collector.messages.items.len);

    var parsed = try std.json.parseFromSlice(std.json.Value, a, collector.messages.items[0], .{});
    defer parsed.deinit();

    const result = parsed.value.object.get("result").?.object;
    try std.testing.expectEqualStrings("input_required", result.get("resultType").?.string);
    try std.testing.expectEqualStrings("opaque-state", result.get("requestState").?.string);

    // inputRequests is a map keyed by the server-assigned identifier.
    const requests = result.get("inputRequests").?.object;
    const entry = requests.get("github_login").?.object;
    try std.testing.expectEqualStrings(protocol.MRTR_METHOD_ELICITATION, entry.get("method").?.string);
    try std.testing.expect(entry.get("params") != null);
}

test "spec: paginate slices pages and round-trips the cursor" {
    const a = std.testing.allocator;

    const keys = [_][]const u8{ "a", "b", "c", "d", "e" };

    const all = try Server.paginate(a, &keys, null, 0);
    try std.testing.expectEqual(@as(usize, 5), all.items.len);
    try std.testing.expect(all.next_cursor == null);

    const first = try Server.paginate(a, &keys, null, 2);
    defer if (first.next_cursor) |c| a.free(c);
    try std.testing.expectEqual(@as(usize, 2), first.items.len);
    try std.testing.expectEqualStrings("a", first.items[0]);
    try std.testing.expect(first.next_cursor != null);

    const second = try Server.paginate(a, &keys, first.next_cursor, 2);
    defer if (second.next_cursor) |c| a.free(c);
    try std.testing.expectEqual(@as(usize, 2), second.items.len);
    try std.testing.expectEqualStrings("c", second.items[0]);

    const third = try Server.paginate(a, &keys, second.next_cursor, 2);
    try std.testing.expectEqual(@as(usize, 1), third.items.len);
    try std.testing.expectEqualStrings("e", third.items[0]);
    try std.testing.expect(third.next_cursor == null);

    const stale = try Server.paginate(a, &keys, "not-base64!!", 2);
    defer if (stale.next_cursor) |c| a.free(c);
    try std.testing.expectEqualStrings("a", stale.items[0]);
}

test "spec: tools/list paginates and reports nextCursor" {
    const a = std.testing.allocator;

    var server = Server.init(a, .{ .name = "page-server", .version = "1.0.0", .page_size = 2 });
    defer server.deinit();

    for ([_][]const u8{ "one", "two", "three" }) |name| {
        try server.addTool(.{
            .name = name,
            .description = "d",
            .inputSchema = .{ .type = "object" },
            .handler = struct {
                fn h(_: ?*anyopaque, _: std.Io, _: std.mem.Allocator, _: ?std.json.Value) tools_mod.ToolError!tools_mod.ToolResult {
                    return .{ .content = &.{} };
                }
            }.h,
        });
    }

    var collector = CaptureTransport{ .allocator = a };
    defer collector.deinitCapture();
    const prev = server.transport;
    defer server.transport = prev;
    server.transport = .{
        .ptr = &collector,
        .vtable = &.{
            .send = struct {
                fn f(p: *anyopaque, io: std.Io, al: std.mem.Allocator, m: []const u8) transport_mod.Transport.SendError!void {
                    const self: *CaptureTransport = @ptrCast(@alignCast(p));
                    self.send(io, al, m) catch return error.OutOfMemory;
                }
            }.f,
            .receive = struct {
                fn f(p: *anyopaque, io: std.Io, al: std.mem.Allocator) transport_mod.Transport.ReceiveError!?[]const u8 {
                    const self: *CaptureTransport = @ptrCast(@alignCast(p));
                    return self.receive(io, al);
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

    const req = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/list\",\"params\":{\"_meta\":{\"io.modelcontextprotocol/protocolVersion\":\"2026-07-28\",\"io.modelcontextprotocol/clientCapabilities\":{}}}}";
    try server.handleMessage(std.Io.failing, a, req);

    var parsed = try std.json.parseFromSlice(std.json.Value, a, collector.messages.items[0], .{});
    defer parsed.deinit();

    const result = parsed.value.object.get("result").?.object;
    try std.testing.expectEqual(@as(usize, 2), result.get("tools").?.array.items.len);
    const cursor = result.get("nextCursor").?.string;

    const req2 = try std.fmt.allocPrint(a, "{{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/list\",\"params\":{{\"cursor\":\"{s}\",\"_meta\":{{\"io.modelcontextprotocol/protocolVersion\":\"2026-07-28\",\"io.modelcontextprotocol/clientCapabilities\":{{}}}}}}}}", .{cursor});
    defer a.free(req2);
    try server.handleMessage(std.Io.failing, a, req2);

    var p2 = try std.json.parseFromSlice(std.json.Value, a, collector.messages.items[1], .{});
    defer p2.deinit();
    const r2 = p2.value.object.get("result").?.object;
    try std.testing.expectEqual(@as(usize, 1), r2.get("tools").?.array.items.len);
    try std.testing.expect(r2.get("nextCursor") == null);
}

test "spec: MRTR refuses to ask for an undeclared client capability" {
    const a = std.testing.allocator;

    const needsInput = struct {
        fn handler(_: ?*anyopaque, _: std.Io, _: std.mem.Allocator, _: ?std.json.Value) tools_mod.ToolError!tools_mod.ToolResult {
            return tools_mod.ToolError.InputRequired;
        }
    }.handler;

    const resolver = struct {
        fn f(_: ?*anyopaque, _: []const u8, _: ?std.json.Value, allocator: std.mem.Allocator) anyerror!types.InputRequiredResult {
            var requests: types.InputRequests = .empty;
            try Server.putInputRequest(allocator, &requests, "github_login", protocol.MRTR_METHOD_ELICITATION, null);
            return .{ .inputRequests = requests };
        }
    }.f;

    var server = Server.init(a, .{ .name = "cap-server", .version = "1.0.0", .mrtr = resolver });
    defer server.deinit();
    try server.addTool(.{
        .name = "needs_input",
        .description = "d",
        .inputSchema = .{ .type = "object" },
        .handler = needsInput,
    });

    var collector = CaptureTransport{ .allocator = a };
    defer collector.deinitCapture();
    const prev = server.transport;
    defer server.transport = prev;
    server.transport = .{
        .ptr = &collector,
        .vtable = &.{
            .send = struct {
                fn f(p: *anyopaque, io: std.Io, al: std.mem.Allocator, m: []const u8) transport_mod.Transport.SendError!void {
                    const self: *CaptureTransport = @ptrCast(@alignCast(p));
                    self.send(io, al, m) catch return error.OutOfMemory;
                }
            }.f,
            .receive = struct {
                fn f(p: *anyopaque, io: std.Io, al: std.mem.Allocator) transport_mod.Transport.ReceiveError!?[]const u8 {
                    const self: *CaptureTransport = @ptrCast(@alignCast(p));
                    return self.receive(io, al);
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

    // The client declared no capabilities at all.
    const req = "{\"jsonrpc\":\"2.0\",\"id\":4,\"method\":\"tools/call\",\"params\":{\"name\":\"needs_input\",\"_meta\":{\"io.modelcontextprotocol/protocolVersion\":\"2026-07-28\",\"io.modelcontextprotocol/clientCapabilities\":{}}}}";
    try server.handleMessage(std.Io.failing, a, req);

    var parsed = try std.json.parseFromSlice(std.json.Value, a, collector.messages.items[0], .{});
    defer parsed.deinit();

    const err_obj = parsed.value.object.get("error").?.object;
    try std.testing.expectEqual(
        @as(i64, jsonrpc.ErrorCode.MISSING_REQUIRED_CLIENT_CAPABILITY),
        err_obj.get("code").?.integer,
    );
    // data.requiredCapabilities names what was missing.
    try std.testing.expect(err_obj.get("data").?.object.get("requiredCapabilities") != null);
    // No input_required result is emitted in its place.
    try std.testing.expect(parsed.value.object.get("result") == null);
}

test "spec: subscriptions/listen acknowledges before closing, tagged with subscriptionId" {
    const a = std.testing.allocator;

    var server = Server.init(a, .{ .name = "sub-server", .version = "1.0.0" });
    defer server.deinit();

    // Advertise listChanged so the tools filter is honoured.
    server.capabilities.tools = .{ .listChanged = true };

    var collector = CaptureTransport{ .allocator = a };
    defer collector.deinitCapture();
    const prev_transport = server.transport;
    defer server.transport = prev_transport;
    server.transport = .{
        .ptr = &collector,
        .vtable = &.{
            .send = struct {
                fn f(p: *anyopaque, io: std.Io, al: std.mem.Allocator, m: []const u8) transport_mod.Transport.SendError!void {
                    const self: *CaptureTransport = @ptrCast(@alignCast(p));
                    self.send(io, al, m) catch return error.OutOfMemory;
                }
            }.f,
            .receive = struct {
                fn f(p: *anyopaque, io: std.Io, al: std.mem.Allocator) transport_mod.Transport.ReceiveError!?[]const u8 {
                    const self: *CaptureTransport = @ptrCast(@alignCast(p));
                    return self.receive(io, al);
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

    const req = "{\"jsonrpc\":\"2.0\",\"id\":7,\"method\":\"subscriptions/listen\",\"params\":{\"notifications\":{\"toolsListChanged\":true,\"promptsListChanged\":true},\"_meta\":{\"io.modelcontextprotocol/protocolVersion\":\"2026-07-28\",\"io.modelcontextprotocol/clientCapabilities\":{}}}}";
    try server.handleMessage(std.Io.failing, a, req);

    // The server must send exactly two messages: the acknowledgment
    // notification first, then the graceful-closure response.
    try std.testing.expectEqual(@as(usize, 2), collector.messages.items.len);

    var ack = try std.json.parseFromSlice(std.json.Value, a, collector.messages.items[0], .{});
    defer ack.deinit();
    const ack_obj = ack.value.object;
    try std.testing.expectEqualStrings("notifications/subscriptions/acknowledged", ack_obj.get("method").?.string);
    try std.testing.expect(ack_obj.get("id") == null);

    const ack_meta = ack_obj.get("params").?.object.get("_meta").?.object;
    try std.testing.expectEqual(@as(i64, 7), ack_meta.get(protocol.META_SUBSCRIPTION_ID).?.integer);

    // The acknowledged filter is the subset the server agreed to honour.
    const agreed = ack_obj.get("params").?.object.get("notifications").?.object;
    try std.testing.expectEqual(@as(bool, true), agreed.get("toolsListChanged").?.bool);
    // Prompts capability was not advertised, so it must be omitted.
    try std.testing.expect(agreed.get("promptsListChanged") == null);

    var closed = try std.json.parseFromSlice(std.json.Value, a, collector.messages.items[1], .{});
    defer closed.deinit();
    const result = closed.value.object.get("result").?.object;
    try std.testing.expectEqualStrings("complete", result.get("resultType").?.string);
    try std.testing.expectEqual(
        @as(i64, 7),
        result.get("_meta").?.object.get(protocol.META_SUBSCRIPTION_ID).?.integer,
    );
}

/// In-memory transport pairing a Client with a Server so the full request
/// path runs inside a single test. Runs under `std.testing.allocator`, so any
/// leak or double free on either side fails the test.
const RoundTrip = struct {
    server: *Server,
    allocator: std.mem.Allocator,
    /// Most recent server response; one request yields exactly one reply.
    pending: ?[]u8 = null,

    fn dispatch(p: *anyopaque, io: std.Io, a: std.mem.Allocator, msg: []const u8) transport_mod.Transport.SendError!void {
        const self: *RoundTrip = @ptrCast(@alignCast(p));
        self.server.handleMessage(io, a, msg) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.WriteError,
        };
    }

    fn capture(p: *anyopaque, _: std.Io, _: std.mem.Allocator, msg: []const u8) transport_mod.Transport.SendError!void {
        const self: *RoundTrip = @ptrCast(@alignCast(p));
        // The server frees the buffer as soon as `send` returns and may hand
        // down a per-request arena, so the copy uses this transport's own
        // long-lived allocator.
        if (self.pending) |old| self.allocator.free(old);
        self.pending = self.allocator.dupe(u8, msg) catch return error.OutOfMemory;
    }

    fn drain(p: *anyopaque, _: std.Io, a: std.mem.Allocator) transport_mod.Transport.ReceiveError!?[]const u8 {
        const self: *RoundTrip = @ptrCast(@alignCast(p));
        const msg = self.pending orelse return null;
        self.pending = null;
        return a.dupe(u8, msg) catch return error.OutOfMemory;
    }

    fn noop(_: *anyopaque) void {}

    fn noopDestroy(_: *anyopaque, _: std.mem.Allocator) void {}

    fn deinit(self: *RoundTrip) void {
        if (self.pending) |msg| self.allocator.free(msg);
        self.pending = null;
    }

    fn clientSide(self: *RoundTrip) transport_mod.Transport {
        return .{ .ptr = self, .vtable = &.{
            .send = dispatch,
            .receive = drain,
            .close = noop,
            .destroy = noopDestroy,
        } };
    }

    fn serverSide(self: *RoundTrip) transport_mod.Transport {
        return .{ .ptr = self, .vtable = &.{
            .send = capture,
            .receive = drain,
            .close = noop,
            .destroy = noopDestroy,
        } };
    }
};

fn roundTripGreet(
    _: ?*anyopaque,
    _: std.Io,
    allocator: std.mem.Allocator,
    arguments: ?std.json.Value,
) tools_mod.ToolError!tools_mod.ToolResult {
    var who: []const u8 = "world";
    if (arguments) |args| {
        if (args == .object) {
            if (args.object.get("name")) |n| {
                if (n == .string) who = n.string;
            }
        }
    }
    const text = try std.fmt.allocPrint(allocator, "Hello, {s}!", .{who});
    const content = try allocator.alloc(types.ContentBlock, 1);
    content[0] = .{ .text = .{ .text = text } };
    return .{ .content = content };
}

fn roundTripAbout(
    _: ?*anyopaque,
    _: std.Io,
    _: std.mem.Allocator,
    uri: []const u8,
) resources_mod.ResourceError!resources_mod.ResourceContent {
    return .{ .uri = uri, .mimeType = "text/plain", .text = "round-trip resource" };
}

const round_trip_prompt_messages = [_]prompts_mod.PromptMessage{
    .{ .role = .user, .content = .{ .text = .{ .text = "Say hello." } } },
};

fn roundTripPrompt(
    _: ?*anyopaque,
    _: std.Io,
    _: std.mem.Allocator,
    _: ?std.json.Value,
) prompts_mod.PromptError![]const prompts_mod.PromptMessage {
    return &round_trip_prompt_messages;
}

test "memory: full client/server round trip leaks nothing" {
    const a = std.testing.allocator;

    var server = Server.init(a, .{ .name = "round-trip", .version = "1.0.0" });
    defer server.deinit();

    try server.addTool(.{
        .name = "greet",
        .description = "Greet a user",
        .inputSchema = .{ .type = "object" },
        .handler = roundTripGreet,
    });
    try server.addResource(.{
        .uri = "info://about",
        .name = "About",
        .mimeType = "text/plain",
        .handler = roundTripAbout,
    });
    try server.addPrompt(.{
        .name = "hello",
        .description = "Say hello",
        .handler = roundTripPrompt,
    });

    var link = RoundTrip{ .server = &server, .allocator = a };
    defer link.deinit();
    server.transport = link.serverSide();

    var client = client_mod.Client.init(std.Io.failing, a, .{ .name = "round-trip-client", .version = "1.0.0" });
    defer client.deinit();
    client.transport = link.clientSide();

    // Every call below must produce a well-formed result; std.testing.allocator
    // reports any leak once `defer`s unwind at the end of the test.
    const steps = [_]struct { name: []const u8, send: *const fn (*client_mod.Client) anyerror!void }{
        .{ .name = "server/discover", .send = struct {
            fn f(c: *client_mod.Client) anyerror!void {
                try c.discover();
            }
        }.f },
        .{ .name = "tools/list", .send = struct {
            fn f(c: *client_mod.Client) anyerror!void {
                try c.listTools();
            }
        }.f },
        .{ .name = "tools/call", .send = struct {
            fn f(c: *client_mod.Client) anyerror!void {
                var args: std.json.ObjectMap = .empty;
                defer args.deinit(c.allocator);
                try args.put(c.allocator, "name", .{ .string = "Zig" });
                try c.callTool("greet", .{ .object = args });
            }
        }.f },
        .{ .name = "resources/list", .send = struct {
            fn f(c: *client_mod.Client) anyerror!void {
                try c.listResources();
            }
        }.f },
        .{ .name = "resources/read", .send = struct {
            fn f(c: *client_mod.Client) anyerror!void {
                try c.readResource("info://about");
            }
        }.f },
        .{ .name = "prompts/list", .send = struct {
            fn f(c: *client_mod.Client) anyerror!void {
                try c.listPrompts();
            }
        }.f },
        .{ .name = "prompts/get", .send = struct {
            fn f(c: *client_mod.Client) anyerror!void {
                try c.getPrompt("hello", null);
            }
        }.f },
    };

    for (steps) |step| {
        try step.send(&client);

        const raw = link.pending orelse return error.NoResponse;
        link.pending = null;
        defer a.free(raw);

        var parsed = try std.json.parseFromSlice(std.json.Value, a, raw, .{});
        defer parsed.deinit();

        const obj = switch (parsed.value) {
            .object => |o| o,
            else => return error.BadResponse,
        };
        try std.testing.expect(obj.get("error") == null);
        const result = obj.get("result") orelse return error.MissingResult;
        switch (result) {
            .object => |r| try std.testing.expectEqualStrings(
                protocol.RESULT_TYPE_COMPLETE,
                r.get("resultType").?.string,
            ),
            else => return error.BadResult,
        }
    }
}
