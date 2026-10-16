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
    /// Invoked by `tasks/update` with the `inputResponses` the client sent for a
    /// task that is still running. The extension added this method so a task in
    /// `input_required` status can receive answers; observe the outcome by
    /// polling `tasks/get`.
    onTaskUpdate: ?*const fn (
        user_data: ?*anyopaque,
        task_id: []const u8,
        input_responses: ?std.json.Value,
    ) anyerror!void = null,
    /// Passed to the `mrtr` hook.
    mrtr_user_data: ?*anyopaque = null,
    /// Passed to the `onTaskUpdate` hook.
    taskUpdateUserData: ?*anyopaque = null,
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
    /// Open `subscriptions/listen` streams, keyed by the JSON-RPC id of the
    /// listen request. Every notification matching a subscription is tagged
    /// with that id so clients can demultiplex concurrent subscriptions.
    subscriptions: std.AutoHashMap(i64, Subscription),
    /// Guarantees distinct task ids even when the entropy source fails.
    next_task_seq: u64 = 0,
    log_level: protocol.LogLevel = .info,
    /// Log level requested by the request currently being handled, from
    /// `_meta.io.modelcontextprotocol/logLevel`. Null means the client did not
    /// ask for logs, and the server must then emit no `notifications/message`.
    request_log_level: ?protocol.LogLevel = null,
    /// True when the current request is an MRTR retry. Results produced by a
    /// retry carry `inputResponses` or `requestState`, which are not part of
    /// the cache key, so the spec forbids advertising caching hints for them.
    suppress_cache_hints: bool = false,
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
        /// Owns the single buffer referenced by BOTH `task.statusMessage` and
        /// `task.error.?.message`, so it is only ever freed through here.
        error_message: ?[]const u8 = null,
    };

    /// An open `subscriptions/listen` stream.
    ///
    /// The filter outlives the request that negotiated it, so anything read
    /// from the request arena has to be copied into the server allocator and
    /// tracked here. `owned` is false only for filters installed directly by
    /// tests with static storage.
    const Subscription = struct {
        filter: types.SubscriptionFilter,
        owned: bool = false,
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
            .subscriptions = .init(allocator),
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
        var subs = self.subscriptions.iterator();
        while (subs.next()) |entry| self.freeSubscription(entry.value_ptr.*);
        self.subscriptions.deinit();
        if (self.capabilities.extensions) |ext| {
            if (ext == .object) {
                var owned = ext.object;
                owned.deinit(self.allocator);
            }
        }
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

    /// Enable the tasks extension.
    ///
    /// The extension replaced the 2025-11-25 per-method task capabilities,
    /// which servers must no longer advertise. Support is now signalled by
    /// the extension label alone.
    pub fn enableTasks(self: *Self) !void {
        try self.declareExtension(self.allocator, protocol.EXTENSION_TASKS);
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
        const verdict = http_rules.validateWithSchemas(
            ctx.allocator,
            .{ .context = ctx },
            body,
            // Servers bound to a loopback host reject cross-origin browser
            // requests (DNS rebinding protection).
            isLoopbackHost(config),
            .{
                .ctx = mcp_server,
                .resolve = struct {
                    fn f(user: *const anyopaque, tool_name: []const u8) ?std.json.Value {
                        const self: *const Server = @ptrCast(@alignCast(user));
                        const tool = self.tools.get(tool_name) orelse return null;
                        const schema = tool.inputSchema orelse return null;
                        // Serialise just the schema so annotations can be
                        // collected from the same document clients receive.
                        var arena: std.heap.ArenaAllocator = .init(self.allocator);
                        defer arena.deinit();
                        var obj: std.json.ObjectMap = .empty;
                        putInputSchemaFields(arena.allocator(), &obj, schema) catch return null;
                        return .{ .object = obj };
                    }
                }.f,
            },
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

        // Resolve the log level this request asked for before running the
        // handler, so anything it logs is emitted at the requested threshold.
        self.request_log_level = Self.requestLogLevel(request.params) catch {
            self.request_log_level = null;
            const error_response = jsonrpc.createInvalidParams(request.id, "Invalid log level");
            try self.sendResponse(io, allocator, .{ .error_response = error_response });
            return;
        };
        defer self.request_log_level = null;

        // A retry of an MRTR request must not look cacheable.
        self.suppress_cache_hints = Self.isMrtrRetry(request.params);
        defer self.suppress_cache_hints = false;

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
            // The tasks extension requires the client to declare it, and
            // servers MUST refuse with -32021 otherwise.
            if (!Self.clientDeclaredExtension(request.params, protocol.EXTENSION_TASKS)) {
                try self.sendMissingExtension(io, allocator, request.id);
                return;
            }
            try self.handleTasksGet(io, allocator, request);
        } else if (std.mem.eql(u8, request.method, "tasks/update")) {
            if (!Self.clientDeclaredExtension(request.params, protocol.EXTENSION_TASKS)) {
                try self.sendMissingExtension(io, allocator, request.id);
                return;
            }
            try self.handleTasksUpdate(io, allocator, request);
        } else if (std.mem.eql(u8, request.method, "tasks/cancel")) {
            if (!Self.clientDeclaredExtension(request.params, protocol.EXTENSION_TASKS)) {
                try self.sendMissingExtension(io, allocator, request.id);
                return;
            }
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
        // Extension labels are the modern handshake. The legacy per-method
        // `tasks` capability is gone, as the extension requires.
        if (self.capabilities.extensions) |ext| {
            try caps.put(allocator, "extensions", ext);
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

        const maybe_page = try self.paginateOrError(io, allocator, request, keys);
        const page = maybe_page orelse return;
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
                try putInputSchemaFields(allocator, &input_schema, schema);
            } else {
                try input_schema.put(allocator, "type", .{ .string = "object" });
            }
            try tool_obj.put(allocator, "inputSchema", .{ .object = input_schema });

            if (entry.outputSchema) |schema| {
                var output_schema: std.json.ObjectMap = .empty;
                if (schema.raw) |raw| {
                    switch (raw) {
                        .object => |obj| {
                            var it = obj.iterator();
                            while (it.next()) |kv| {
                                try output_schema.put(allocator, kv.key_ptr.*, kv.value_ptr.*);
                            }
                        },
                        else => {},
                    }
                }
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
    /// Writes a tool's `inputSchema` exactly as clients receive it: the caller's
    /// full 2020-12 document first, then the typed convenience fields on top.
    ///
    /// Shared by `tools/list` and by `x-mcp-header` validation, which must read
    /// annotations from the very same document.
    fn putInputSchemaFields(
        allocator: std.mem.Allocator,
        obj: *std.json.ObjectMap,
        schema: types.InputSchema,
    ) !void {
        if (schema.raw) |raw| {
            switch (raw) {
                .object => |raw_obj| {
                    var it = raw_obj.iterator();
                    while (it.next()) |kv| {
                        try obj.put(allocator, kv.key_ptr.*, kv.value_ptr.*);
                    }
                },
                else => {},
            }
        }

        try obj.put(allocator, "type", .{ .string = schema.type });
        if (schema.@"$schema") |s| try obj.put(allocator, "$schema", .{ .string = s });
        if (schema.description) |d| try obj.put(allocator, "description", .{ .string = d });
        if (schema.properties) |p| try obj.put(allocator, "properties", p);
        if (schema.required) |req| {
            var arr: std.json.Array = .init(allocator);
            for (req) |name| try arr.append(.{ .string = name });
            try obj.put(allocator, "required", .{ .array = arr });
        }
    }

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
                // 2026-07-28: the tasks extension opts in through request
                // `_meta`, so a compliant client never sends a `task` param.
                if (params.object.get("_meta")) |meta| {
                    if (meta == .object) {
                        if (meta.object.get(protocol.META_TASK)) |task_val| {
                            if (task_val == .object) {
                                var ttl: ?i64 = null;
                                if (task_val.object.get("ttl")) |ttl_val| {
                                    if (ttl_val == .integer) ttl = ttl_val.integer;
                                }
                                task_meta = .{ .ttl = ttl };
                            }
                        }
                    }
                }
                // Retained only for a legacy 2025-11-25 client.
                if (task_meta == null) {
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
        }

        if (self.tools.get(tool_name)) |tool| {
            // Task augmentation is decided by the extension label, not the removed
            // per-method capability. A tool requiring a task is refused when the
            // client has not declared the extension.
            const tasks_enabled = self.hasExtension(protocol.EXTENSION_TASKS);
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
                errdefer if (status_message) |m| self.allocator.free(m);
                const tool_result: tools_mod.ToolResult = tool.handler(tool.user_data, io, allocator, arguments) catch |err| blk: {
                    const msg = try std.fmt.allocPrint(self.allocator, "{s}", .{@errorName(err)});
                    status_message = msg;
                    var content = try self.allocator.alloc(types.ContentBlock, 1);
                    content[0] = .{ .text = .{ .text = msg } };
                    break :blk tools_mod.ToolResult{ .content = content, .is_error = true };
                };

                // A handler may also report failure by returning an error
                // result instead of throwing. A failed task has to carry the
                // reason, so lift it out of the first text block.
                if (tool_result.is_error and status_message == null) {
                    for (tool_result.content) |block| {
                        if (block == .text) {
                            status_message = try self.allocator.dupe(u8, block.text.text);
                            break;
                        }
                    }
                }

                const result_json = try self.serializeToolCallResult(tool_result);
                const task_id = try self.generateTaskId(io, self.allocator);
                const created_at = try nowIsoTimestamp(io, self.allocator);
                const updated_at = try self.allocator.dupe(u8, created_at);

                // `statusMessage` and `error.message` share one owned buffer,
                // freed once through `TaskEntry.error_message`.
                var task: types.Task = .{
                    .taskId = task_id,
                    .status = if (tool_result.is_error) .failed else .completed,
                    .createdAt = created_at,
                    .lastUpdatedAt = updated_at,
                    .ttlMs = if (task_meta) |meta| meta.ttl else null,
                    .pollIntervalMs = null,
                };
                if (status_message) |msg| {
                    task.statusMessage = msg;
                    // A failed task must carry the reason, not just a label.
                    if (tool_result.is_error) {
                        task.@"error" = .{ .message = msg };
                    }
                }

                try self.tasks.put(task_id, .{ .task = task, .result_json = result_json, .error_message = status_message });

                const task_obj = try buildTaskObject(allocator, task);
                var result: std.json.ObjectMap = .empty;
                try result.put(allocator, "task", .{ .object = task_obj });
                try Self.putResultTask(allocator, &result);

                // Let the client correlate this acknowledgement with the task
                // without having to parse the embedded snapshot.
                var task_meta_obj: std.json.ObjectMap = .empty;
                try task_meta_obj.put(allocator, "taskId", .{ .string = task_id });
                var result_meta: std.json.ObjectMap = .empty;
                try result_meta.put(allocator, protocol.META_RELATED_TASK, .{ .object = task_meta_obj });
                try result.put(allocator, "_meta", .{ .object = result_meta });

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

        const maybe_page = try self.paginateOrError(io, allocator, request, keys);
        const page = maybe_page orelse return;
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

        const maybe_page = try self.paginateOrError(io, allocator, request, keys);
        const page = maybe_page orelse return;
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

    /// The numeric part of a request id, or null for string ids.
    fn requestIdValue(id: types.RequestId) ?i64 {
        return switch (id) {
            .integer => |i| i,
            .string => null,
        };
    }

    /// The client capability an MRTR input request depends on, or null when the
    /// method needs none.
    fn requiredCapabilityForMethod(method: []const u8) ?[]const u8 {
        if (std.mem.eql(u8, method, protocol.MRTR_METHOD_ELICITATION)) return "elicitation";
        if (std.mem.eql(u8, method, protocol.MRTR_METHOD_SAMPLING)) return "sampling";
        if (std.mem.eql(u8, method, protocol.MRTR_METHOD_ROOTS)) return "roots";
        return null;
    }

    /// Declares support for an extension, advertised in `capabilities.extensions`.
    ///
    /// The tasks extension, for example, is declared with
    /// `protocol.EXTENSION_TASKS`.
    pub fn declareExtension(self: *Self, allocator: std.mem.Allocator, label: []const u8) !void {
        var extensions: std.json.ObjectMap = .empty;
        if (self.capabilities.extensions) |existing| {
            if (existing == .object) extensions = existing.object;
        }
        try extensions.put(allocator, label, .{ .object = .empty });
        self.capabilities.extensions = .{ .object = extensions };
    }

    /// True when this server declares `label` in its capabilities.
    pub fn hasExtension(self: *Self, label: []const u8) bool {
        const ext = self.capabilities.extensions orelse return false;
        if (ext != .object) return false;
        return ext.object.contains(label);
    }

    /// True when the client declared `label` in the per-request
    /// `clientCapabilities.extensions` of this message.
    fn clientDeclaredExtension(params: ?std.json.Value, label: []const u8) bool {
        const p = params orelse return false;
        if (p != .object) return false;
        const meta = p.object.get("_meta") orelse return false;
        if (meta != .object) return false;
        const caps = meta.object.get(protocol.META_CLIENT_CAPABILITIES) orelse return false;
        if (caps != .object) return false;
        const extensions = caps.object.get("extensions") orelse return false;
        if (extensions != .object) return false;
        return extensions.object.contains(label);
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

    /// Rejects a request that needs an extension the client did not declare.
    ///
    /// `data.requiredCapabilities` carries the `extensions` object the spec
    /// shows for extension negotiation, rather than a flat name.
    fn sendMissingExtension(self: *Self, io: anytype, allocator: std.mem.Allocator, id: types.RequestId) !void {
        var extensions: std.json.ObjectMap = .empty;
        try extensions.put(allocator, protocol.EXTENSION_TASKS, .{ .object = .empty });
        var data: std.json.ObjectMap = .empty;
        defer data.deinit(allocator);
        try data.put(allocator, "requiredCapabilities", .{ .object = extensions });

        const response = jsonrpc.createErrorResponse(
            id,
            jsonrpc.ErrorCode.MISSING_REQUIRED_CLIENT_CAPABILITY,
            "Client did not declare the " ++ protocol.EXTENSION_TASKS ++ " extension",
            .{ .object = data },
        );
        try self.sendResponse(io, allocator, .{ .error_response = response });
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
    /// are omitted. The response is deliberately not sent here: the stream stays
    /// open and the subscription is recorded until the client cancels it or the
    /// server tears it down, which is what makes it long-lived.
    fn handleSubscriptionsListen(self: *Self, io: anytype, allocator: std.mem.Allocator, request: jsonrpc.Request) !void {
        const listen_id = Self.requestIdValue(request.id) orelse return error.InvalidRequestId;
        var requested: types.SubscriptionFilter = .{};
        if (request.params) |params| {
            if (params == .object) {
                if (params.object.get("notifications")) |n| {
                    if (n == .object) requested = Self.parseSubscriptionFilter(allocator, n.object);
                }
            }
        }

        // The parsed string arrays belong to the request allocator and the
        // negotiated copy is deep-copied below, so release them when this
        // request finishes.
        defer Self.freeFilterLists(allocator, requested);

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
            // Task notifications only exist when the tasks extension is declared.
            .taskIds = if (self.hasExtension(protocol.EXTENSION_TASKS)) requested.taskIds else null,
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
        if (agreed.taskIds) |ids| {
            if (ids.len > 0) {
                var arr: std.json.Array = .init(allocator);
                for (ids) |id| try arr.append(.{ .string = id });
                try ack_filter.put(allocator, "taskIds", .{ .array = arr });
            }
        }

        // The subscription id travels in params._meta, not at the top of
        // params, alongside the agreed filter.
        var ack_params: std.json.ObjectMap = .empty;
        try ack_params.put(allocator, "_meta", .{ .object = ack_meta });
        try ack_params.put(allocator, "notifications", .{ .object = ack_filter });

        try self.sendNotification(io, allocator, "notifications/subscriptions/acknowledged", .{ .object = ack_params });

        // Keep the stream open: record the agreed filter so later change
        // notifications are routed here with this subscription's id attached.
        try self.subscriptions.put(listen_id, .{ .filter = try self.ownSubscriptionFilter(agreed), .owned = true });
    }

    /// Deep-copies the negotiated filter into the server allocator.
    ///
    /// `params` (and therefore `requested`) lives in the per-request arena, so
    /// storing its slices directly would leave the open subscription reading
    /// freed memory once the request completes.
    fn ownSubscriptionFilter(self: *Self, filter: types.SubscriptionFilter) !types.SubscriptionFilter {
        var owned = filter;
        owned.resourceSubscriptions = try self.dupeStringList(filter.resourceSubscriptions);
        owned.taskIds = try self.dupeStringList(filter.taskIds);
        return owned;
    }

    fn dupeStringList(self: *Self, list: ?[]const []const u8) !?[]const []const u8 {
        const items = list orelse return null;
        if (items.len == 0) return &.{};
        const out = try self.allocator.alloc([]const u8, items.len);
        errdefer self.allocator.free(out);
        for (items, out) |item, *slot| slot.* = try self.allocator.dupe(u8, item);
        return out;
    }

    /// Frees an owned subscription filter. Safe to call on borrowed filters.
    fn freeSubscription(self: *Self, sub: Subscription) void {
        if (!sub.owned) return;
        if (sub.filter.resourceSubscriptions) |list| {
            if (list.len > 0) {
                for (list) |s| self.allocator.free(s);
                self.allocator.free(list);
            }
        }
        if (sub.filter.taskIds) |list| {
            if (list.len > 0) {
                for (list) |s| self.allocator.free(s);
                self.allocator.free(list);
            }
        }
    }

    /// Tears a subscription down at the server's initiative.
    ///
    /// The spec has the server signal a graceful end by responding to the
    /// originating `subscriptions/listen` request, with the subscription id in
    /// `_meta` of the result, before the stream closes.
    pub fn endSubscription(self: *Self, io: anytype, allocator: std.mem.Allocator, subscription_id: i64) !void {
        const removed = self.subscriptions.fetchRemove(subscription_id) orelse return;
        self.freeSubscription(removed.value);

        var result: std.json.ObjectMap = .empty;
        defer result.deinit(allocator);
        try Self.putResultComplete(allocator, &result);
        var close_meta: std.json.ObjectMap = .empty;
        defer close_meta.deinit(allocator);
        try Self.putSubscriptionIdMeta(allocator, &close_meta, .{ .integer = subscription_id });
        try result.put(allocator, "_meta", .{ .object = close_meta });

        const response = jsonrpc.createResponse(.{ .integer = subscription_id }, .{ .object = result });
        try self.sendResponse(io, allocator, .{ .response = response });
    }

    /// Number of `subscriptions/listen` streams currently open.
    pub fn activeSubscriptions(self: *Self) usize {
        return self.subscriptions.count();
    }

    /// Sends `method` to every subscription whose filter admits it.
    ///
    /// Each copy carries `io.modelcontextprotocol/subscriptionId` set to the id
    /// of the listen request that opened the stream, so a client holding
    /// several concurrent subscriptions can tell them apart.
    ///
    /// `subject` carries the URI for resource updates, which must match a
    /// subscription entry exactly rather than just testing a flag.
    fn broadcastSubscription(
        self: *Self,
        io: anytype,
        allocator: std.mem.Allocator,
        method: []const u8,
        params: ?std.json.ObjectMap,
        subject: ?[]const u8,
        admits: fn (types.SubscriptionFilter, ?[]const u8) bool,
    ) !void {
        if (self.subscriptions.count() == 0) return;

        var ids: std.ArrayList(i64) = .empty;
        defer ids.deinit(allocator);
        var it = self.subscriptions.iterator();
        while (it.next()) |entry| {
            if (admits(entry.value_ptr.filter, subject)) try ids.append(allocator, entry.key_ptr.*);
        }

        for (ids.items) |sub_id| {
            var out: std.json.ObjectMap = .empty;
            defer out.deinit(allocator);
            if (params) |p| {
                var it2 = p.iterator();
                while (it2.next()) |kv| try out.put(allocator, kv.key_ptr.*, kv.value_ptr.*);
            }

            var meta: std.json.ObjectMap = .empty;
            defer meta.deinit(allocator);
            try Self.putSubscriptionIdMeta(allocator, &meta, .{ .integer = sub_id });
            try meta.put(allocator, protocol.META_PROTOCOL_VERSION, .{ .string = protocol.PROTOCOL_VERSION });
            try out.put(allocator, "_meta", .{ .object = meta });

            try self.sendNotification(io, allocator, method, .{ .object = out });
        }
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
            if (v == .array) filter.resourceSubscriptions = copyStringArray(allocator, v);
        }
        if (obj.get("taskIds")) |v| {
            if (v == .array) filter.taskIds = copyStringArray(allocator, v);
        }
        return filter;
    }

    /// Copies the strings of a JSON string array into a single slice owned by
    /// `allocator`. The scratch `ArrayList` is released, so the only allocation
    /// handed back is the one the caller must free.
    /// Releases the string arrays `copyStringArray` allocated in a request.
    fn freeFilterLists(allocator: std.mem.Allocator, filter: types.SubscriptionFilter) void {
        if (filter.resourceSubscriptions) |list| {
            if (list.len > 0) allocator.free(list);
        }
        if (filter.taskIds) |list| {
            if (list.len > 0) allocator.free(list);
        }
    }

    fn copyStringArray(allocator: std.mem.Allocator, value: std.json.Value) ?[]const []const u8 {
        var list: std.ArrayList([]const u8) = .empty;
        defer list.deinit(allocator);
        for (value.array.items) |item| {
            if (item == .string) list.append(allocator, item.string) catch return null;
        }
        return allocator.dupe([]const u8, list.items) catch null;
    }

    /// Admits `notifications/tasks` for the task id it is asked about.
    fn admitsTask(f: types.SubscriptionFilter, subject: ?[]const u8) bool {
        const ids = f.taskIds orelse return false;
        const subject_id = subject orelse return false;
        for (ids) |id| {
            if (std.mem.eql(u8, id, subject_id)) return true;
        }
        return false;
    }

    /// Handle prompts/list request
    fn handlePromptsList(self: *Self, io: anytype, allocator: std.mem.Allocator, request: jsonrpc.Request) !void {
        var prompts_array: std.json.Array = .init(allocator);

        const keys = try Self.sortedKeys(allocator, @TypeOf(self.prompts), &self.prompts);
        defer allocator.free(keys);

        const maybe_page = try self.paginateOrError(io, allocator, request, keys);
        const page = maybe_page orelse return;
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

    /// Handle `tasks/update`: client responses to a task's outstanding input
    /// requests.
    ///
    /// The extension replaced the blocking `tasks/result` method with polling
    /// via `tasks/get`, and added this method so a task in `input_required`
    /// status can receive answers. The response is an empty acknowledgement:
    /// the client keeps observing the task by polling, because the update is
    /// only eventually consistent.
    fn handleTasksUpdate(self: *Self, io: anytype, allocator: std.mem.Allocator, request: jsonrpc.Request) !void {
        var task_id: ?[]const u8 = null;
        var responses: ?std.json.Value = null;
        if (request.params) |params| {
            if (params == .object) {
                if (params.object.get("taskId")) |id_val| {
                    if (id_val == .string) task_id = id_val.string;
                }
                if (params.object.get("inputResponses")) |r| responses = r;
            }
        }

        const id = task_id orelse {
            const error_response = jsonrpc.createInvalidParams(request.id, "Missing taskId");
            try self.sendResponse(io, allocator, .{ .error_response = error_response });
            return;
        };

        const entry = self.tasks.get(id) orelse {
            const error_response = jsonrpc.createInvalidParams(request.id, "Task not found");
            try self.sendResponse(io, allocator, .{ .error_response = error_response });
            return;
        };

        // A terminal task can no longer accept input.
        switch (entry.task.status) {
            .completed, .failed, .cancelled => {
                const error_response = jsonrpc.createInvalidParams(request.id, "Task is no longer running");
                try self.sendResponse(io, allocator, .{ .error_response = error_response });
                return;
            },
            else => {},
        }

        // Hand the responses to the application, which decides what they mean.
        // Keys that are not outstanding are ignored rather than rejected, so a
        // duplicate or stale response cannot fail an otherwise valid update.
        if (self.config.onTaskUpdate) |hook| {
            hook(self.config.taskUpdateUserData, id, responses) catch {
                const error_response = jsonrpc.createInternalError(request.id, .{ .string = "Task update failed" });
                try self.sendResponse(io, allocator, .{ .error_response = error_response });
                return;
            };
        }

        var result: std.json.ObjectMap = .empty;
        defer result.deinit(allocator);
        try Self.putResultComplete(allocator, &result);

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
            // An empty string is a valid cursor, so only an undecodable one is
            // an error, and the spec asks for -32602 rather than a silent
            // restart from the first page.
            const idx = decodeCursor(allocator, c) orelse return error.InvalidCursor;
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

    /// A cancellation signal a handler can poll.
    ///
    /// Cancellation is cooperative: a handler that never checks keeps running,
    /// so long-running work should poll `cancelled` between units of work and
    /// return early. The token stays valid for the duration of the call.
    pub const CancellationToken = struct {
        server: *Self,
        request_id: types.RequestId,

        /// True once the client has cancelled this request.
        pub fn cancelled(self: CancellationToken) bool {
            return self.server.isCancelled(self.request_id);
        }

        /// Returns true when the work should keep going.
        pub fn keepGoing(self: CancellationToken) bool {
            return !self.cancelled();
        }
    };

    /// The cancellation token for an in-flight request.
    pub fn cancellationToken(self: *Self, id: types.RequestId) CancellationToken {
        return .{ .server = self, .request_id = id };
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
    fn handleNotification(self: *Self, _: anytype, notification: jsonrpc.Notification) !void {
        if (std.mem.eql(u8, notification.method, "notifications/cancelled")) {
            if (notification.params) |params| {
                if (params == .object) {
                    if (params.object.get("requestId")) |req_id| {
                        // A client cancelling a subscriptions/listen request
                        // ends that stream, so drop the subscription rather
                        // than just recording a cancellation a handler would
                        // never poll.
                        if (req_id == .integer) {
                            if (self.subscriptions.fetchRemove(req_id.integer)) |removed| {
                                self.freeSubscription(removed.value);
                                return;
                            }
                        }
                        // Record the cancellation so a long-running handler can
                        // observe it and the server can answer with -32800.
                        if (req_id == .integer) {
                            self.cancelled_requests.put(req_id.integer, {}) catch {};
                        }
                    }
                }
            }
        }
        // `notifications/roots/list_changed` was removed in 2026-07-28, so it
        // is deliberately ignored rather than handled.
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

    /// Send a log message notification.
    ///
    /// Logging is opt-in per request: the client sets
    /// `io.modelcontextprotocol/logLevel` in that request's `_meta`, and the
    /// spec requires the server to emit nothing when the field is absent. A
    /// `notifications/message` is also request-scoped, so it is never delivered
    /// on a `subscriptions/listen` stream.
    pub fn sendLogMessage(self: *Self, io: anytype, allocator: std.mem.Allocator, level: protocol.LogLevel, message: []const u8) !void {
        // No level for the current request means the client did not ask.
        const threshold = self.request_log_level orelse return;
        if (@backingInt(level) < @backingInt(threshold)) return;

        var params: std.json.ObjectMap = .empty;
        defer params.deinit(allocator);
        try params.put(allocator, "level", .{ .string = level.toString() });
        try params.put(allocator, "data", .{ .string = message });

        try self.sendNotification(io, allocator, "notifications/message", .{ .object = params });
    }

    /// True when the request carries MRTR retry state.
    ///
    /// Either `inputResponses` or `requestState` means this is a retry rather than
    /// a fresh call, which changes both caching and header handling.
    fn isMrtrRetry(params: ?std.json.Value) bool {
        const p = params orelse return false;
        if (p != .object) return false;
        if (p.object.contains("inputResponses")) return true;
        // `requestState` normally travels at the top level of params.
        if (p.object.contains(protocol.META_REQUEST_STATE)) return true;
        // It may also sit in `_meta`, where the spec's reserved keys live.
        if (p.object.get("_meta")) |meta| {
            if (meta == .object and meta.object.contains(protocol.META_REQUEST_STATE)) return true;
        }
        return false;
    }

    /// Reads `io.modelcontextprotocol/logLevel` out of a request's `_meta`.
    ///
    /// Returns an error when the value is present but not a recognized level,
    /// which the spec says to reject with `-32602`.
    fn requestLogLevel(params: ?std.json.Value) !?protocol.LogLevel {
        const p = params orelse return null;
        if (p != .object) return null;
        const meta = p.object.get("_meta") orelse return null;
        if (meta != .object) return null;
        const raw = meta.object.get(protocol.META_LOG_LEVEL) orelse return null;
        if (raw != .string) return error.InvalidLogLevel;
        return protocol.LogLevel.fromString(raw.string) orelse error.InvalidLogLevel;
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
    ///
    /// Delivered only to subscriptions whose filter asked for it, and tagged
    /// with each subscriber's subscription id.
    pub fn notifyToolsChanged(self: *Self, io: anytype, allocator: std.mem.Allocator) !void {
        try self.broadcastSubscription(io, allocator, "notifications/tools/list_changed", null, null, struct {
            fn admits(f: types.SubscriptionFilter, _: ?[]const u8) bool {
                return f.toolsListChanged;
            }
        }.admits);
    }

    /// Notify clients that resources have changed
    pub fn notifyResourcesChanged(self: *Self, io: anytype, allocator: std.mem.Allocator) !void {
        try self.broadcastSubscription(io, allocator, "notifications/resources/list_changed", null, null, struct {
            fn admits(f: types.SubscriptionFilter, _: ?[]const u8) bool {
                return f.resourcesListChanged;
            }
        }.admits);
    }

    /// Notify clients that a resource has been updated
    ///
    /// Only subscribers that named this exact URI receive the notification.
    pub fn notifyResourceUpdated(self: *Self, io: anytype, allocator: std.mem.Allocator, uri: []const u8) !void {
        const target = try allocator.dupe(u8, uri);
        defer allocator.free(target);

        var params: std.json.ObjectMap = .empty;
        defer params.deinit(allocator);
        try params.put(allocator, "uri", .{ .string = target });
        try self.broadcastSubscription(io, allocator, "notifications/resources/updated", params, target, struct {
            fn admits(f: types.SubscriptionFilter, subject: ?[]const u8) bool {
                const uris = f.resourceSubscriptions orelse return false;
                const want = subject orelse return false;
                for (uris) |u| {
                    if (std.mem.eql(u8, u, want)) return true;
                }
                return false;
            }
        }.admits);
    }

    /// Notify clients that prompts have changed
    pub fn notifyPromptsChanged(self: *Self, io: anytype, allocator: std.mem.Allocator) !void {
        try self.broadcastSubscription(io, allocator, "notifications/prompts/list_changed", null, null, struct {
            fn admits(f: types.SubscriptionFilter, _: ?[]const u8) bool {
                return f.promptsListChanged;
            }
        }.admits);
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

    /// Records a task so the polling methods can find it.
    ///
    /// Applications call this when they materialize a task; the server then
    /// answers `tasks/get`, `tasks/update` and `tasks/cancel` for it. The
    /// `result` is returned verbatim once the task completes.
    pub fn storeTask(
        self: *Self,
        allocator: std.mem.Allocator,
        task_id: []const u8,
        status: types.TaskStatus,
        result: ?[]const u8,
    ) !void {
        const now = try nowIsoTimestamp(self.io orelse std.Io.failing, allocator);
        errdefer allocator.free(now);

        const task = types.Task{
            .taskId = try allocator.dupe(u8, task_id),
            .status = status,
            .createdAt = now,
            .lastUpdatedAt = try allocator.dupe(u8, now),
        };

        const entry = TaskEntry{
            .task = task,
            .result_json = result orelse "",
        };
        try self.tasks.put(task_id, entry);
    }

    /// A change to a stored task, applied by `storeTask` and `updateTask`.
    pub const TaskUpdate = struct {
        status: types.TaskStatus,
        /// Human-readable progress or failure note.
        statusMessage: ?[]const u8 = null,
        /// Failure detail. Required in practice when `status` is `failed`, in
        /// which case a message is synthesised from `statusMessage` if absent.
        errorMessage: ?[]const u8 = null,
        errorCode: ?i64 = null,
        /// Outstanding client requests, for `input_required` tasks.
        inputRequests: ?types.InputRequests = null,
        /// Opaque state for the next `tasks/update` round.
        requestState: ?[]const u8 = null,
        pollIntervalMs: ?i64 = null,
    };

    /// Applies `update` to a stored task and pushes `notifications/tasks` to
    /// every subscription watching that task id.
    ///
    /// The strings in `update` are copied into the server's allocator;
    /// `inputRequests` and `requestState` are only read while the notification
    /// is being built, so pass arena-backed values.
    pub fn updateTask(
        self: *Self,
        io: anytype,
        allocator: std.mem.Allocator,
        task_id: []const u8,
        update: TaskUpdate,
    ) !void {
        const entry = self.tasks.getPtr(task_id) orelse return error.UnknownTask;

        if (update.statusMessage orelse update.errorMessage) |msg| {
            const owned = try self.allocator.dupe(u8, msg);
            if (entry.error_message) |old| self.allocator.free(old);
            entry.error_message = owned;
            entry.task.statusMessage = owned;
        }
        if (update.errorMessage != null or update.status == .failed) {
            if (entry.task.statusMessage) |m| {
                entry.task.@"error" = .{ .code = update.errorCode, .message = m };
            }
        } else if (update.status != .failed) {
            entry.task.@"error" = null;
        }

        entry.task.status = update.status;
        entry.task.pollIntervalMs = update.pollIntervalMs;
        entry.task.requestState = update.requestState;
        entry.task.inputRequests = update.inputRequests;

        const stamp = try nowIsoTimestamp(io, self.allocator);
        defer self.allocator.free(stamp);
        const previous = entry.task.lastUpdatedAt;
        entry.task.lastUpdatedAt = try self.allocator.dupe(u8, stamp);
        self.allocator.free(previous);

        try self.notifyTask(io, allocator, task_id);
    }

    /// Pushes the current state of `task_id` as `notifications/tasks`.
    ///
    /// Only subscriptions whose filter lists this task id receive it.
    pub fn notifyTask(
        self: *Self,
        io: anytype,
        allocator: std.mem.Allocator,
        task_id: []const u8,
    ) !void {
        const entry = self.tasks.getPtr(task_id) orelse return error.UnknownTask;

        // The notification is serialized here and discarded, so its whole
        // object graph is scoped to a local arena rather than the caller's.
        var arena: std.heap.ArenaAllocator = .init(allocator);
        defer arena.deinit();
        const scratch = arena.allocator();

        var params: std.json.ObjectMap = .empty;
        try params.put(scratch, "task", .{ .object = try buildTaskObject(scratch, entry.task) });
        try self.broadcastSubscription(io, scratch, "notifications/tasks", params, task_id, admitsTask);
    }

    /// Reads a stored task, or null when the id is unknown or expired.
    pub fn getTask(self: *Self, task_id: []const u8) ?types.Task {
        const entry = self.tasks.get(task_id) orelse return null;
        return entry.task;
    }

    /// Removes a stored task and frees its owned strings.
    pub fn removeTask(self: *Self, task_id: []const u8) bool {
        const removed = self.tasks.fetchRemove(task_id) orelse return false;
        self.allocator.free(removed.value.task.taskId);
        self.allocator.free(removed.value.task.createdAt);
        self.allocator.free(removed.value.task.lastUpdatedAt);
        if (removed.value.error_message) |m| self.allocator.free(m);
        self.allocator.free(removed.value.result_json);
        return true;
    }

    fn deinitTasks(self: *Self) void {
        var iter = self.tasks.iterator();
        while (iter.next()) |entry| {
            self.allocator.free(entry.value_ptr.task.taskId);
            self.allocator.free(entry.value_ptr.task.createdAt);
            self.allocator.free(entry.value_ptr.task.lastUpdatedAt);
            // `statusMessage` and `error.message` alias this one buffer.
            if (entry.value_ptr.error_message) |msg| {
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

    fn generateTaskId(self: *Self, io: anytype, allocator: std.mem.Allocator) ![]const u8 {
        // Entropy may be unavailable (for example under a failing test `Io`).
        // Mixing in a per-server counter keeps ids unique regardless, instead
        // of handing out an uninitialised buffer.
        var bytes: [16]u8 = @splat(0);
        if (io.randomSecure(&bytes)) |_| {} else |_| {
            io.random(&bytes);
        }
        std.mem.writeInt(u64, bytes[8..16], self.next_task_seq, .little);
        self.next_task_seq += 1;

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
        // The extension names these `ttlMs` and `pollIntervalMs`, and allows a
        // null `ttlMs` for an unlimited retention.
        if (task.ttlMs) |ttl| {
            try task_obj.put(allocator, "ttlMs", .{ .integer = ttl });
        } else {
            try task_obj.put(allocator, "ttlMs", .null);
        }
        if (task.pollIntervalMs) |interval| {
            try task_obj.put(allocator, "pollIntervalMs", .{ .integer = interval });
        }
        // A failed task must explain itself; clients render `error` verbatim.
        if (task.@"error") |err| {
            var err_obj: std.json.ObjectMap = .empty;
            if (err.code) |code| try err_obj.put(allocator, "code", .{ .integer = code });
            if (err.message) |msg| try err_obj.put(allocator, "message", .{ .string = msg });
            if (err.data) |data| try err_obj.put(allocator, "data", data);
            try task_obj.put(allocator, "error", .{ .object = err_obj });
        }
        // An `input_required` task carries the round it is blocked on so the
        // client knows what to answer and the server can resume it.
        if (task.inputRequests) |requests| {
            try task_obj.put(allocator, "inputRequests", .{ .object = requests });
        }
        if (task.requestState) |state| {
            try task_obj.put(allocator, "requestState", .{ .string = state });
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

    /// Paginates a list request, mapping an unusable cursor onto the spec's
    /// `Invalid params` error instead of letting it surface as an internal error.
    ///
    /// Cursors are opaque to clients, so an expired or malformed one is the
    /// client's mistake, not a server failure. Returns null once the error
    /// response has been sent, so the caller simply returns.
    fn paginateOrError(
        self: *Self,
        io: anytype,
        allocator: std.mem.Allocator,
        request: jsonrpc.Request,
        keys: []const []const u8,
    ) !?Page {
        return Self.paginate(allocator, keys, Self.requestCursor(request.params), self.config.page_size) catch |err| switch (err) {
            error.InvalidCursor => {
                try self.sendResponse(io, allocator, .{
                    .error_response = jsonrpc.createInvalidParams(request.id, "Invalid or expired cursor"),
                });
                return null;
            },
            else => return err,
        };
    }

    /// Marks a result as fully satisfied: `resultType: "complete"`.
    /// Every result emitted by the server carries this in MCP 2026-07-28.
    fn putResultComplete(allocator: std.mem.Allocator, result: *std.json.ObjectMap) !void {
        try result.put(allocator, "resultType", .{ .string = protocol.RESULT_TYPE_COMPLETE });
    }

    /// Marks a result as a task acknowledgement: `resultType: "task"`.
    ///
    /// A task-augmented request answers with this discriminator plus the
    /// `task` snapshot; the real outcome is retrieved later via `tasks/get`.
    pub fn putResultTask(allocator: std.mem.Allocator, result: *std.json.ObjectMap) !void {
        try result.put(allocator, "resultType", .{ .string = protocol.RESULT_TYPE_TASK });
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
        self: *Self,
        allocator: std.mem.Allocator,
        result: *std.json.ObjectMap,
        ttl_ms: i64,
        scope: types.CacheScope,
    ) !void {
        const clamped = if (ttl_ms < 0) 0 else ttl_ms;
        // An MRTR retry is not cacheable, so the hints are omitted entirely.
        if (self.suppress_cache_hints) return;
        try result.put(allocator, "ttlMs", .{ .integer = clamped });
        try result.put(allocator, "cacheScope", .{ .string = scope.toString() });
    }

    /// Convenience: emit the standard list/discover cache hints.
    fn putListCacheHints(self: *Self, allocator: std.mem.Allocator, result: *std.json.ObjectMap) !void {
        try self.putCacheHints(allocator, result, self.config.cache.ttl_ms, self.config.cache.scope);
    }

    /// Convenience: emit cache hints for `resources/read` results, which are
    /// treated as user-specific by default.
    fn putReadCacheHints(self: *Self, allocator: std.mem.Allocator, result: *std.json.ObjectMap) !void {
        try self.putCacheHints(allocator, result, self.config.cache.read_ttl_ms, self.config.cache.read_scope);
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
    try server.enableTasks();

    try std.testing.expect(server.capabilities.logging != null);
    try std.testing.expect(server.capabilities.completions != null);
    try std.testing.expect(server.hasExtension(protocol.EXTENSION_TASKS));
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

    /// Drops the captured log so a test can assert on the next exchange alone.
    fn clearMessages(self: *CaptureTransport) void {
        for (self.messages.items) |m| self.allocator.free(m);
        self.messages.clearRetainingCapacity();
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

    // A cursor the client could not have obtained from us is rejected rather
    // than silently restarting from the first page.
    try std.testing.expectError(error.InvalidCursor, Server.paginate(a, &keys, "not-base64!!", 2));

    // An empty string is a legitimate cursor value, so it must not be treated
    // as "no cursor" (the spec calls this out explicitly).
    try std.testing.expectError(error.InvalidCursor, Server.paginate(a, &keys, "", 2));
}

test "spec: tools/list preserves full JSON Schema 2020-12 documents" {
    const a = std.testing.allocator;

    const Handler = struct {
        fn handler(_: ?*anyopaque, _: std.Io, _: std.mem.Allocator, _: ?std.json.Value) tools_mod.ToolError!tools_mod.ToolResult {
            return tools_mod.textResult(std.heap.page_allocator, "ok") catch return tools_mod.ToolError.OutOfMemory;
        }
    };

    // SEP-2100 makes inputSchema a complete 2020-12 document, so reference and
    // composition keywords must survive serialisation instead of being dropped
    // by the typed convenience struct.
    const raw_schema = try std.json.parseFromSlice(std.json.Value, a,
        \\{
        \\  "$schema": "https://json-schema.org/draft/2020-12/schema",
        \\  "type": "object",
        \\  "additionalProperties": false,
        \\  "allOf": [{ "type": "object" }],
        \\  "$defs": { "Name": { "type": "string" } },
        \\  "properties": { "name": { "$ref": "#/$defs/Name" } },
        \\  "required": ["name"]
        \\}
    , .{});
    defer raw_schema.deinit();

    var tool_builder = tools_mod.ToolBuilder.init("echo-schema");
    const tool = tool_builder
        .description("uses a full 2020-12 schema")
        .inputSchemaFromRaw(raw_schema.value)
        .outputSchemaFromRaw(raw_schema.value)
        .handler(Handler.handler)
        .build();

    var server = Server.init(a, .{ .name = "schema-server", .version = "1.0.0" });
    defer server.deinit();
    try server.addTool(tool);

    const parsed = try runRequest(&server, a, "tools/list", null);
    defer parsed.deinit();
    const result = try resultOf(parsed);
    const entry = result.get("tools").?.array.items[0].object;

    const input = entry.get("inputSchema").?.object;
    try std.testing.expectEqualStrings("https://json-schema.org/draft/2020-12/schema", input.get("$schema").?.string);
    try std.testing.expectEqual(false, input.get("additionalProperties").?.bool);
    try std.testing.expectEqual(@as(usize, 1), input.get("allOf").?.array.items.len);
    try std.testing.expect(input.get("$defs") != null);
    try std.testing.expectEqualStrings("#/$defs/Name", input.get("properties").?.object.get("name").?.object.get("$ref").?.string);
    try std.testing.expectEqual(@as(usize, 1), input.get("required").?.array.items.len);

    // The same must hold for outputSchema.
    const output = entry.get("outputSchema").?.object;
    try std.testing.expect(output.get("$defs") != null);
    try std.testing.expectEqual(@as(usize, 1), output.get("allOf").?.array.items.len);
}

test "spec: an unusable cursor is rejected with invalid params" {
    const a = std.testing.allocator;

    const Handler = struct {
        fn handler(_: ?*anyopaque, _: std.Io, al: std.mem.Allocator, _: ?std.json.Value) tools_mod.ToolError!tools_mod.ToolResult {
            return tools_mod.textResult(al, "ok") catch return tools_mod.ToolError.OutOfMemory;
        }
    };

    var server = Server.init(a, .{ .name = "cursor-server", .version = "1.0.0" });
    defer server.deinit();
    try server.addTool(.{ .name = "t", .description = "x", .handler = Handler.handler });

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

    // Cursors are opaque, so a malformed one is the client's error: -32602.
    try server.handleMessage(std.Io.failing, a,
        \\{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{"cursor":"not-a-real-cursor","_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28","io.modelcontextprotocol/clientCapabilities":{}}}}
    );

    var parsed = try std.json.parseFromSlice(std.json.Value, a, collector.messages.items[0], .{});
    defer parsed.deinit();
    const err = parsed.value.object.get("error").?.object;
    try std.testing.expectEqual(@as(i64, jsonrpc.ErrorCode.INVALID_PARAMS), err.get("code").?.integer);
    try std.testing.expect(err.get("message").?.string.len > 0);
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

test "spec: subscriptions/listen acknowledges and stays open" {
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

    // Only the acknowledgment is sent. The stream is long-lived, so no
    // completion response closes it right away.
    try std.testing.expectEqual(@as(usize, 1), collector.messages.items.len);
    try std.testing.expectEqual(@as(usize, 1), server.activeSubscriptions());

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

    // A later change notification reaches this subscriber, tagged with its id.
    try server.notifyToolsChanged(std.Io.failing, a);
    try std.testing.expectEqual(@as(usize, 2), collector.messages.items.len);

    var note = try std.json.parseFromSlice(std.json.Value, a, collector.messages.items[1], .{});
    defer note.deinit();
    try std.testing.expectEqualStrings("notifications/tools/list_changed", note.value.object.get("method").?.string);
    try std.testing.expectEqual(
        @as(i64, 7),
        note.value.object.get("params").?.object.get("_meta").?.object.get(protocol.META_SUBSCRIPTION_ID).?.integer,
    );

    // Tearing the subscription down closes the stream gracefully.
    try server.endSubscription(std.Io.failing, a, 7);
    try std.testing.expectEqual(@as(usize, 0), server.activeSubscriptions());
    try std.testing.expectEqual(@as(usize, 3), collector.messages.items.len);

    var closed = try std.json.parseFromSlice(std.json.Value, a, collector.messages.items[2], .{});
    defer closed.deinit();
    const result = closed.value.object.get("result").?.object;
    try std.testing.expectEqualStrings("complete", result.get("resultType").?.string);
    try std.testing.expectEqual(
        @as(i64, 7),
        result.get("_meta").?.object.get(protocol.META_SUBSCRIPTION_ID).?.integer,
    );
}

test "spec: task-augmented tools/call answers resultType task and reports failures" {
    const a = std.testing.allocator;

    const OkHandler = struct {
        fn handler(_: ?*anyopaque, _: std.Io, al: std.mem.Allocator, _: ?std.json.Value) tools_mod.ToolError!tools_mod.ToolResult {
            return tools_mod.textResult(al, "done") catch return tools_mod.ToolError.OutOfMemory;
        }
    };
    const FailHandler = struct {
        fn handler(_: ?*anyopaque, _: std.Io, al: std.mem.Allocator, _: ?std.json.Value) tools_mod.ToolError!tools_mod.ToolResult {
            return tools_mod.errorResult(al, "boom") catch return tools_mod.ToolError.OutOfMemory;
        }
    };

    var server = Server.init(a, .{ .name = "task-result", .version = "1.0.0" });
    defer server.deinit();
    try server.declareExtension(a, protocol.EXTENSION_TASKS);
    try server.addTool(.{
        .name = "slow",
        .description = "runs as a task",
        .handler = OkHandler.handler,
        .execution = .{ .taskSupport = "optional" },
    });
    try server.addTool(.{
        .name = "failing",
        .description = "fails as a task",
        .handler = FailHandler.handler,
        .execution = .{ .taskSupport = "optional" },
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

    const task_caps = "\"io.modelcontextprotocol/clientCapabilities\":{\"extensions\":{\"io.modelcontextprotocol/tasks\":{}}}";

    // The 2026-07-28 opt-in lives in request _meta, not a `task` param.
    const slow_req = try std.fmt.allocPrint(
        a,
        \\{{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{{"name":"slow","_meta":{{"io.modelcontextprotocol/protocolVersion":"2026-07-28","io.modelcontextprotocol/task":{{"ttl":60000}},{s}}}}}}}
    ,
        .{task_caps},
    );
    defer a.free(slow_req);
    try server.handleMessage(std.Io.failing, a, slow_req);

    var ok = try std.json.parseFromSlice(std.json.Value, a, collector.messages.items[0], .{});
    defer ok.deinit();
    const ok_result = ok.value.object.get("result").?.object;
    // A task acknowledgement is `resultType: "task"`, never "complete".
    try std.testing.expectEqualStrings("task", ok_result.get("resultType").?.string);
    const ok_task = ok_result.get("task").?.object;
    try std.testing.expectEqualStrings("completed", ok_task.get("status").?.string);
    try std.testing.expectEqual(@as(i64, 60000), ok_task.get("ttlMs").?.integer);
    try std.testing.expect(!ok_task.contains("error"));
    // The result correlates back to the task id.
    const related = ok_result.get("_meta").?.object.get(protocol.META_RELATED_TASK).?.object;
    try std.testing.expectEqualStrings(ok_task.get("taskId").?.string, related.get("taskId").?.string);

    // A failing task must explain itself through `error`.
    collector.clearMessages();
    const fail_req = try std.fmt.allocPrint(
        a,
        \\{{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{{"name":"failing","_meta":{{"io.modelcontextprotocol/protocolVersion":"2026-07-28","io.modelcontextprotocol/task":{{}},{s}}}}}}}
    ,
        .{task_caps},
    );
    defer a.free(fail_req);
    try server.handleMessage(std.Io.failing, a, fail_req);

    var bad = try std.json.parseFromSlice(std.json.Value, a, collector.messages.items[0], .{});
    defer bad.deinit();
    const bad_task = bad.value.object.get("result").?.object.get("task").?.object;
    try std.testing.expectEqualStrings("failed", bad_task.get("status").?.string);
    try std.testing.expectEqualStrings("boom", bad_task.get("error").?.object.get("message").?.string);

    // The stored task is retrievable through tasks/get.
    const ok_task_id = ok_task.get("taskId").?.string;
    try std.testing.expectEqual(types.TaskStatus.completed, server.getTask(ok_task_id).?.status);
    try std.testing.expect(server.getTask("does-not-exist") == null);
}

test "spec: notifications/tasks is routed only to subscriptions watching that id" {
    const a = std.testing.allocator;

    var server = Server.init(a, .{ .name = "task-notify", .version = "1.0.0" });
    defer server.deinit();
    try server.declareExtension(a, protocol.EXTENSION_TASKS);

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

    // Subscription 1 watches t-watch, subscription 2 watches a different id.
    try server.handleMessage(std.Io.failing, a,
        \\{"jsonrpc":"2.0","id":1,"method":"subscriptions/listen","params":{"notifications":{"taskIds":["t-watch"]},"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28","io.modelcontextprotocol/clientCapabilities":{"extensions":{"io.modelcontextprotocol/tasks":{}}}}}}
    );
    try server.handleMessage(std.Io.failing, a,
        \\{"jsonrpc":"2.0","id":2,"method":"subscriptions/listen","params":{"notifications":{"taskIds":["t-other"]},"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28","io.modelcontextprotocol/clientCapabilities":{"extensions":{"io.modelcontextprotocol/tasks":{}}}}}}
    );
    try std.testing.expectEqual(@as(usize, 2), server.activeSubscriptions());

    // The acknowledgement echoes the agreed filter.
    collector.clearMessages();
    try server.storeTask(a, "t-watch", .working, null);
    try server.storeTask(a, "t-other", .working, null);
    try server.updateTask(std.Io.failing, a, "t-watch", .{ .status = .completed, .statusMessage = "finished" });

    var pushed: usize = 0;
    for (collector.messages.items) |raw| {
        const parsed = try std.json.parseFromSlice(std.json.Value, a, raw, .{});
        defer parsed.deinit();
        const obj = parsed.value.object;
        const method = obj.get("method") orelse continue;
        if (!std.mem.eql(u8, method.string, "notifications/tasks")) continue;
        pushed += 1;
        const params = obj.get("params").?.object;
        const task = params.get("task").?.object;
        try std.testing.expectEqualStrings("t-watch", task.get("taskId").?.string);
        try std.testing.expectEqualStrings("completed", task.get("status").?.string);
        try std.testing.expectEqualStrings("finished", task.get("statusMessage").?.string);
        // Tagged with the listen request that opened the stream.
        try std.testing.expectEqual(@as(i64, 1), params.get("_meta").?.object.get(protocol.META_SUBSCRIPTION_ID).?.integer);
    }
    // Only the watching subscription was notified.
    try std.testing.expectEqual(@as(usize, 1), pushed);

    // A failing transition records the reason.
    collector.clearMessages();
    try server.updateTask(std.Io.failing, a, "t-watch", .{ .status = .failed, .errorMessage = "exploded" });
    const stored = server.getTask("t-watch").?;
    try std.testing.expectEqualStrings("exploded", stored.@"error".?.message.?);
    try std.testing.expect(server.removeTask("t-watch"));
    try std.testing.expect(!server.removeTask("t-watch"));
}

test "spec: tasks methods require the client to declare the extension" {
    const a = std.testing.allocator;
    var server = Server.init(a, .{ .name = "task-ext", .version = "1.0.0" });
    defer server.deinit();

    try server.declareExtension(a, protocol.EXTENSION_TASKS);
    try std.testing.expect(server.hasExtension(protocol.EXTENSION_TASKS));

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

    // Without the extension declared, tasks/get is refused with -32021 and
    // data.requiredCapabilities naming the extension.
    try server.handleMessage(std.Io.failing, a,
        \\{"jsonrpc":"2.0","id":1,"method":"tasks/get","params":{"taskId":"t1","_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28","io.modelcontextprotocol/clientCapabilities":{}}}}
    );

    var refused = try std.json.parseFromSlice(std.json.Value, a, collector.messages.items[0], .{});
    defer refused.deinit();
    const err = refused.value.object.get("error").?.object;
    try std.testing.expectEqual(
        @as(i64, jsonrpc.ErrorCode.MISSING_REQUIRED_CLIENT_CAPABILITY),
        err.get("code").?.integer,
    );
    const required = err.get("data").?.object.get("requiredCapabilities").?.object;
    try std.testing.expect(required.contains(protocol.EXTENSION_TASKS));

    // The same request succeeds once the client declares the extension.
    collector.clearMessages();
    try server.handleMessage(std.Io.failing, a,
        \\{"jsonrpc":"2.0","id":2,"method":"tasks/get","params":{"taskId":"t1","_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28","io.modelcontextprotocol/clientCapabilities":{"extensions":{"io.modelcontextprotocol/tasks":{}}}}}}
    );
    // The extension gate no longer fires: the request now reaches task lookup
    // and fails only because no such task exists.
    try std.testing.expectEqual(@as(usize, 1), collector.messages.items.len);
    var reached = try std.json.parseFromSlice(std.json.Value, a, collector.messages.items[0], .{});
    defer reached.deinit();
    const code = reached.value.object.get("error").?.object.get("code").?.integer;
    try std.testing.expectEqual(@as(i64, -32602), code);
}

test "spec: tasks/update acknowledges without embedding the task" {
    const a = std.testing.allocator;
    var server = Server.init(a, .{ .name = "task-update", .version = "1.0.0" });
    defer server.deinit();
    try server.declareExtension(a, protocol.EXTENSION_TASKS);

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

    // An unknown task is an invalid-params error, per the extension.
    try server.handleMessage(std.Io.failing, a,
        \\{"jsonrpc":"2.0","id":1,"method":"tasks/update","params":{"taskId":"missing","inputResponses":{"name":{"action":"accept"}},"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28","io.modelcontextprotocol/clientCapabilities":{"extensions":{"io.modelcontextprotocol/tasks":{}}}}}}
    );
    var msg = try std.json.parseFromSlice(std.json.Value, a, collector.messages.items[0], .{});
    defer msg.deinit();
    try std.testing.expectEqual(@as(i64, -32602), msg.value.object.get("error").?.object.get("code").?.integer);

    // With a real task the response is an empty acknowledgement: the spec makes
    // the update eventually consistent, so no task is inlined.
    collector.clearMessages();
    try server.storeTask(a, "t1", .working, null);
    try server.handleMessage(std.Io.failing, a,
        \\{"jsonrpc":"2.0","id":2,"method":"tasks/update","params":{"taskId":"t1","inputResponses":{"name":{"action":"accept"}},"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28","io.modelcontextprotocol/clientCapabilities":{"extensions":{"io.modelcontextprotocol/tasks":{}}}}}}
    );
    var ack = try std.json.parseFromSlice(std.json.Value, a, collector.messages.items[0], .{});
    defer ack.deinit();
    const result = ack.value.object.get("result").?.object;
    try std.testing.expectEqualStrings("complete", result.get("resultType").?.string);
    try std.testing.expect(result.get("task") == null);
}

test "spec: log level is per-request and absent means no logs" {
    const a = std.testing.allocator;
    var server = Server.init(a, .{ .name = "log", .version = "1.0.0" });
    defer server.deinit();

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

    // Without the log level in _meta the server must emit nothing.
    try std.testing.expect(server.request_log_level == null);
    try server.sendLogMessage(std.Io.failing, a, .debug, "should not appear");
    try std.testing.expectEqual(@as(usize, 0), collector.messages.items.len);

    const asked = try std.json.parseFromSlice(std.json.Value, a,
        \\{"_meta":{"io.modelcontextprotocol/logLevel":"warning"}}
    , .{});
    defer asked.deinit();
    try std.testing.expectEqual(@as(?protocol.LogLevel, .warning), try Server.requestLogLevel(asked.value));

    // Messages below the threshold are dropped, ones at or above it go out.
    server.request_log_level = .warning;
    try server.sendLogMessage(std.Io.failing, a, .info, "below threshold");
    try server.sendLogMessage(std.Io.failing, a, .@"error", "at threshold");

    var found_below = false;
    var found_at = false;
    for (collector.messages.items) |m| {
        if (std.mem.indexOf(u8, m, "below threshold") != null) found_below = true;
        if (std.mem.indexOf(u8, m, "at threshold") != null) found_at = true;
    }
    try std.testing.expect(!found_below);
    try std.testing.expect(found_at);

    // The threshold is per-request, so it does not leak into later requests.
    collector.clearMessages();
    server.request_log_level = null;
    try server.sendLogMessage(std.Io.failing, a, .@"error", "after request");
    try std.testing.expectEqual(@as(usize, 0), collector.messages.items.len);

    // An unrecognized level is rejected, so the request fails with -32602.
    const bad = try std.json.parseFromSlice(std.json.Value, a,
        \\{"_meta":{"io.modelcontextprotocol/logLevel":"shouty"}}
    , .{});
    defer bad.deinit();
    try std.testing.expectError(error.InvalidLogLevel, Server.requestLogLevel(bad.value));

    collector.clearMessages();
    const bad_req = "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/list\",\"params\":{\"_meta\":{\"io.modelcontextprotocol/protocolVersion\":\"2026-07-28\",\"io.modelcontextprotocol/clientCapabilities\":{},\"io.modelcontextprotocol/logLevel\":\"shouty\"}}}";
    try server.handleMessage(std.Io.failing, a, bad_req);
    var rejected = try std.json.parseFromSlice(std.json.Value, a, collector.messages.items[0], .{});
    defer rejected.deinit();
    try std.testing.expectEqual(
        @as(i64, -32602),
        rejected.value.object.get("error").?.object.get("code").?.integer,
    );
}

test "spec: the cancellation token reflects notifications/cancelled" {
    const a = std.testing.allocator;
    var server = Server.init(a, .{ .name = "cancel", .version = "1.0.0" });
    defer server.deinit();

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

    const token = server.cancellationToken(.{ .integer = 42 });
    try std.testing.expect(token.keepGoing());

    try server.handleMessage(std.Io.failing, a,
        \\{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":42,"reason":"user"}}
    );

    // The handler can now see the cancellation cooperatively.
    try std.testing.expect(token.cancelled());
    try std.testing.expect(!token.keepGoing());

    // An unrelated request is unaffected.
    const other = server.cancellationToken(.{ .integer = 7 });
    try std.testing.expect(other.keepGoing());

    // Clearing resets the signal for a reused id.
    server.clearCancelled(.{ .integer = 42 });
    try std.testing.expect(server.cancellationToken(.{ .integer = 42 }).keepGoing());
}

test "spec: notifications reach only the subscribers whose filter admits them" {
    const a = std.testing.allocator;

    var server = Server.init(a, .{ .name = "sub-route", .version = "1.0.0" });
    defer server.deinit();

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

    // Two concurrent subscriptions with disjoint filters.
    try server.subscriptions.put(1, .{ .filter = .{ .toolsListChanged = true } });
    try server.subscriptions.put(2, .{ .filter = .{ .promptsListChanged = true } });

    try server.notifyToolsChanged(std.Io.failing, a);
    try std.testing.expectEqual(@as(usize, 1), collector.messages.items.len);
    try std.testing.expect(std.mem.indexOf(u8, collector.messages.items[0], "\"io.modelcontextprotocol/subscriptionId\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, collector.messages.items[0], "\"io.modelcontextprotocol/subscriptionId\":2") == null);

    // With no matching subscriber nothing is emitted at all.
    try server.notifyResourcesChanged(std.Io.failing, a);
    try std.testing.expectEqual(@as(usize, 1), collector.messages.items.len);
}

test "spec: resources/updated only reaches subscribers naming that URI" {
    const a = std.testing.allocator;

    var server = Server.init(a, .{ .name = "sub-uri", .version = "1.0.0" });
    defer server.deinit();

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

    const watched = [_][]const u8{"file:///a.json"};
    try server.subscriptions.put(3, .{ .filter = .{ .resourceSubscriptions = &watched } });
    try server.subscriptions.put(4, .{ .filter = .{ .resourceSubscriptions = &.{} } });

    try server.notifyResourceUpdated(std.Io.failing, a, "file:///a.json");
    try std.testing.expectEqual(@as(usize, 1), collector.messages.items.len);
    try std.testing.expect(std.mem.indexOf(u8, collector.messages.items[0], "\"io.modelcontextprotocol/subscriptionId\":3") != null);
    try std.testing.expect(std.mem.indexOf(u8, collector.messages.items[0], "file:///a.json") != null);

    // A URI nobody subscribed to produces no notification.
    try server.notifyResourceUpdated(std.Io.failing, a, "file:///other.json");
    try std.testing.expectEqual(@as(usize, 1), collector.messages.items.len);
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
