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
    /// Raw JSON text of each completed result, keyed by request id. Entries
    /// are taken with `takeResult`, which frees them.
    results: std.AutoHashMap(i64, []u8),
    /// Handlers for server-initiated notifications, keyed by method.
    notification_handlers: std.StringHashMapUnmanaged(NotificationHandler) = .empty,
    /// Subscription id of the most recent notification, for demultiplexing
    /// concurrent `subscriptions/listen` streams.
    last_subscription_id: ?i64 = null,
    /// Resolver driving automatic MRTR rounds, when one is set.
    input_resolver: ?InputResolver = null,
    /// Upper bound on automatic MRTR rounds, guarding against a server that
    /// keeps asking for input forever.
    max_mrtr_rounds: u32 = 8,
    capabilities: types.ClientCapabilities = .{},
    authorization_token: ?[]const u8 = null,
    roots_list: std.ArrayList(types.Root),

    const Self = @This();

    /// Represents a request awaiting a response from the server.
    /// Resolves one entry of a server's `inputRequests` map.
    ///
    /// The driver calls this for every entry the server asked about, then retries
    /// the original request with the answers. Returning an error aborts the
    /// round rather than retrying with a partial map.
    ///
    /// Ownership of the returned value stays with the resolver: the client only
    /// reads it while building the retry. Allocate it from the supplied
    /// allocator and keep it alive for the call, or return a value borrowing
    /// from memory you already own.
    pub const InputResolver = struct {
        ctx: *anyopaque,
        /// `request` is the `{ method, params }` object the server sent.
        resolve: *const fn (
            ctx: *anyopaque,
            allocator: std.mem.Allocator,
            key: []const u8,
            request: std.json.Value,
        ) anyerror!std.json.Value,
    };

    /// Bookkeeping for a request that may need several MRTR rounds.
    const MrtrState = struct {
        /// The request being retried, without the round-specific fields.
        method: []const u8,
        /// Original params, so the retry carries everything but `inputResponses`.
        base_params: std.json.ObjectMap,
        resolver: InputResolver,
        rounds_left: u32,
    };

    pub const PendingRequest = struct {
        method: []const u8,
        callback: ?*const fn (result: ?std.json.Value, err: ?jsonrpc.ErrorResponse.Error) void = null,
        /// Set when this request is being driven through MRTR rounds.
        mrtr: ?MrtrState = null,
    };

    /// Initializes a new client with the given configuration.
    pub fn init(io: std.Io, allocator: std.mem.Allocator, config: ClientConfig) Self {
        return .{
            .io = io,
            .allocator = allocator,
            .config = config,
            .pending_requests = .init(allocator),
            .results = .init(allocator),
            .roots_list = .empty,
        };
    }

    /// Invoked for one notification method.
    ///
    /// `params` is the notification's params object and `subscription_id` is the
    /// listen request the notification belongs to, or null when it is not carried
    /// on a subscription stream.
    ///
    /// `params` borrows the receive buffer and is only valid for the duration of the
    /// call; copy anything that has to outlive it.
    pub const NotificationHandler = struct {
        ctx: *anyopaque,
        handle: *const fn (ctx: *anyopaque, params: std.json.ObjectMap, subscription_id: ?i64) void,
    };

    /// Registers a handler for `method`, replacing any previous registration.
    ///
    /// The handler context is borrowed for the client's lifetime; pass null to
    /// remove the handler. Unknown notification methods are ignored rather than
    /// treated as an error.
    pub fn onNotification(self: *Self, method: []const u8, handler: ?NotificationHandler) !void {
        if (handler) |h| {
            // The map stores the slice pointer, so the key has to be owned here
            // or deinit would try to free a caller's string literal.
            const key = try self.allocator.dupe(u8, method);
            if (self.notification_handlers.getPtr(method)) |slot| {
                slot.* = h;
                self.allocator.free(key);
                return;
            }
            errdefer self.allocator.free(key);
            try self.notification_handlers.put(self.allocator, key, h);
            return;
        }
        if (self.notification_handlers.fetchRemove(method)) |entry| {
            self.allocator.free(entry.key);
        }
    }

    /// Routes a notification to its handler, recording which subscription it came
    /// from so callers holding several concurrent subscriptions can tell them
    /// apart.
    fn dispatchNotification(self: *Self, method: []const u8, obj: std.json.ObjectMap) !void {
        const params: std.json.ObjectMap = if (obj.get("params")) |p|
            (if (p == .object) p.object else .empty)
        else
            .empty;

        var subscription_id: ?i64 = null;
        if (params.get("_meta")) |meta| {
            if (meta == .object) {
                if (meta.object.get(protocol.META_SUBSCRIPTION_ID)) |v| {
                    if (v == .integer) subscription_id = v.integer;
                }
            }
        }
        if (subscription_id) |id| self.last_subscription_id = id;

        const entry = self.notification_handlers.getPtr(method) orelse return;
        entry.handle(entry.ctx, params, subscription_id);
    }

    /// Subscription the most recent notification arrived on, or null when the last
    /// notification was not carried on a subscription stream.
    pub fn currentSubscriptionId(self: *Self) ?i64 {
        return self.last_subscription_id;
    }

    /// Feeds one received JSON-RPC payload into the client.
    ///
    /// Applications pump this for every line or chunk the transport produces.
    /// Responses resolve their pending request, and a response carrying an
    /// `InputRequiredResult` is turned into an automatic retry when the request
    /// was started with a resolver.
    pub fn handleMessage(self: *Self, payload: []const u8) !void {
        var parsed = std.json.parseFromSlice(std.json.Value, self.allocator, payload, .{}) catch return;
        defer parsed.deinit();

        switch (parsed.value) {
            .object => |obj| {
                // A notification carries a method and no id.
                if (obj.get("id") == null) {
                    if (obj.get("method")) |m| {
                        if (m == .string) try self.dispatchNotification(m.string, obj);
                    }
                    return;
                }

                // A response is identified by carrying an id plus result/error.
                const id_value = obj.get("id") orelse return;
                const id: i64 = switch (id_value) {
                    .integer => |i| i,
                    else => return,
                };

                const entry = self.pending_requests.fetchRemove(id) orelse {
                    // Not a request we are tracking: record it anyway so a late
                    // response is still observable.
                    if (obj.get("result")) |r| try self.storeResult(id, r);
                    return;
                };
                const pending = entry.value;

                if (obj.get("error")) |_| {
                    if (pending.callback) |cb| cb(null, null);
                    return;
                }

                const result = obj.get("result") orelse return;

                // An input-required result drives another round when we know
                // how to resolve it.
                if (pending.mrtr) |state| {
                    // On a retry the params move into the new pending entry, so
                    // only the terminal path releases them here.
                    const retried = self.driveMrtrRound(state, result) catch |err| {
                        var b: std.json.ObjectMap = state.base_params;
                        b.deinit(self.allocator);
                        return err;
                    };
                    if (retried) return;

                    var base: std.json.ObjectMap = state.base_params;
                    base.deinit(self.allocator);
                }

                try self.storeResult(id, result);
                if (pending.callback) |cb| cb(result, null);
            },
            else => {},
        }
    }

    fn storeResult(self: *Self, id: i64, result: std.json.Value) !void {
        var aw: std.Io.Writer.Allocating = .init(self.allocator);
        defer aw.deinit();
        std.json.Stringify.value(result, .{}, &aw.writer) catch return;
        const owned = try self.allocator.dupe(u8, aw.written());
        errdefer self.allocator.free(owned);

        if (self.results.fetchRemove(id)) |old| self.allocator.free(old.value);
        try self.results.put(id, owned);
    }

    /// Returns and frees the completed result for `request_id`, or null when
    /// the request has not finished.
    pub fn takeResult(self: *Self, request_id: i64) ?[]u8 {
        const entry = self.results.fetchRemove(request_id) orelse return null;
        return entry.value;
    }

    /// Issues the retry for one `InputRequiredResult`. Returns true when a
    /// retry was sent, meaning the caller must not treat this as final.
    fn driveMrtrRound(self: *Self, state: MrtrState, result: std.json.Value) !bool {
        if (result != .object) return false;
        const obj = result.object;

        const kind = obj.get("resultType") orelse return false;
        if (kind != .string or !std.mem.eql(u8, kind.string, "input_required")) return false;

        const round = parseInputRequired(obj) orelse return false;
        if (state.rounds_left == 0) return error.MrtrRoundLimitExceeded;

        var responses: std.json.ObjectMap = .empty;
        defer responses.deinit(self.allocator);

        // The resolver owns the containers it returns. They only need to stay valid
        // until the retry has been serialized, so they are held here to keep
        // them alive and are not freed: the resolver decides how long they
        // live, which avoids the client and the resolver both releasing them.
        var answers: std.ArrayList(std.json.Value) = .empty;
        defer answers.deinit(self.allocator);

        var it = round.inputRequests.iterator();
        while (it.next()) |entry| {
            const answer = try state.resolver.resolve(
                state.resolver.ctx,
                self.allocator,
                entry.key_ptr.*,
                entry.value_ptr.*,
            );
            try answers.append(self.allocator, answer);
            try responses.put(self.allocator, entry.key_ptr.*, answer);
        }

        // The retry is an independent request, so it needs its own id and the
        // original params plus this round's answers and opaque state. Ownership
        // of `params` moves into the new pending entry.
        var params = state.base_params;
        try params.put(self.allocator, "inputResponses", .{ .object = responses });
        if (round.requestState) |rs| {
            try params.put(self.allocator, protocol.META_REQUEST_STATE, .{ .string = rs });
        }

        const id = self.next_request_id;
        self.next_request_id += 1;

        try self.pending_requests.put(id, .{
            .method = state.method,
            .mrtr = .{
                .method = state.method,
                .base_params = params,
                .resolver = state.resolver,
                .rounds_left = state.rounds_left - 1,
            },
        });

        const request = jsonrpc.createRequest(.{ .integer = id }, state.method, .{ .object = params });
        const json = try jsonrpc.serializeMessage(self.allocator, .{ .request = request });
        defer self.allocator.free(json);

        if (self.transport) |t| {
            try t.send(self.io, self.allocator, json);
        }
        return true;
    }

    /// Starts a `tools/call` that automatically walks MRTR rounds.
    ///
    /// Returns the id of the first request. Feed responses back through
    /// `handleMessage`; while the server answers with `input_required` the
    /// client resolves and retries on its own, and the final result is
    /// collected by `takeResult`.
    pub fn callToolResolved(
        self: *Self,
        name: []const u8,
        arguments: ?std.json.Value,
        resolver: InputResolver,
    ) !i64 {
        var params: std.json.ObjectMap = .empty;
        errdefer params.deinit(self.allocator);
        try params.put(self.allocator, "name", .{ .string = name });
        if (arguments) |a| try params.put(self.allocator, "arguments", a);

        return self.sendMrtrDriven("tools/call", params, resolver);
    }

    /// Starts a `resources/read` that automatically walks MRTR rounds.
    pub fn readResourceResolved(self: *Self, uri: []const u8, resolver: InputResolver) !i64 {
        var params: std.json.ObjectMap = .empty;
        errdefer params.deinit(self.allocator);
        try params.put(self.allocator, "uri", .{ .string = uri });
        return self.sendMrtrDriven("resources/read", params, resolver);
    }

    /// Starts a `prompts/get` that automatically walks MRTR rounds.
    pub fn getPromptResolved(
        self: *Self,
        name: []const u8,
        arguments: ?std.json.Value,
        resolver: InputResolver,
    ) !i64 {
        var params: std.json.ObjectMap = .empty;
        errdefer params.deinit(self.allocator);
        try params.put(self.allocator, "name", .{ .string = name });
        if (arguments) |a| try params.put(self.allocator, "arguments", a);
        return self.sendMrtrDriven("prompts/get", params, resolver);
    }

    fn sendMrtrDriven(self: *Self, method: []const u8, params: std.json.ObjectMap, resolver: InputResolver) !i64 {
        const id = self.next_request_id;
        self.next_request_id += 1;

        try self.pending_requests.put(id, .{
            .method = method,
            .mrtr = .{
                .method = method,
                .base_params = params,
                .resolver = resolver,
                .rounds_left = self.max_mrtr_rounds,
            },
        });
        errdefer _ = self.pending_requests.remove(id);

        const request = jsonrpc.createRequest(.{ .integer = id }, method, .{ .object = params });
        const json = try jsonrpc.serializeMessage(self.allocator, .{ .request = request });
        defer self.allocator.free(json);

        if (self.transport) |t| {
            try t.send(self.io, self.allocator, json);
        }
        return id;
    }

    /// Releases all resources held by the client.
    pub fn deinit(self: *Self) void {
        self.pending_requests.deinit();
        var it = self.results.valueIterator();
        while (it.next()) |raw| self.allocator.free(raw.*);
        self.results.deinit();
        var handlers = self.notification_handlers.iterator();
        while (handlers.next()) |entry| self.allocator.free(entry.key_ptr.*);
        self.notification_handlers.deinit(self.allocator);
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

        // Any caller-supplied `_meta` is preserved so reserved keys the caller set
        // (notably `progressToken`) survive; the protocol fields below are
        // then written on top.
        var meta: std.json.ObjectMap = .empty;
        defer meta.deinit(self.allocator);
        if (params) |p| {
            if (p == .object) {
                if (p.object.get("_meta")) |existing| {
                    if (existing == .object) meta = existing.object;
                }
            }
        }

        var info: std.json.ObjectMap = .empty;
        defer info.deinit(self.allocator);
        try info.put(self.allocator, "name", .{ .string = self.config.name });
        try info.put(self.allocator, "version", .{ .string = self.config.version });

        // `protocolVersion` and `clientCapabilities` are required on every
        // client request; a server rejects a request missing either with
        // -32602.
        try meta.put(self.allocator, "io.modelcontextprotocol/protocolVersion", .{ .string = protocol.VERSION });
        try meta.put(self.allocator, "io.modelcontextprotocol/clientInfo", .{
            .object = info,
        });
        var caps = try self.capabilities.toJson(self.allocator);
        defer caps.deinit(self.allocator);
        try meta.put(self.allocator, "io.modelcontextprotocol/clientCapabilities", .{ .object = caps });

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
        try self.listToolsPage(null);
    }

    /// Requests one page of tools, resuming from `cursor`.
    ///
    /// A null cursor asks for the first page. The server answers with a
    /// `nextCursor` when more pages remain.
    pub fn listToolsPage(self: *Self, cursor: ?[]const u8) !void {
        try self.sendPaginated("tools/list", cursor);
    }

    /// Sends a `*/list` request carrying an optional `cursor`.
    fn sendPaginated(self: *Self, method: []const u8, cursor: ?[]const u8) !void {
        if (cursor) |c| {
            var params: std.json.ObjectMap = .empty;
            defer params.deinit(self.allocator);
            try params.put(self.allocator, "cursor", .{ .string = c });
            try self.sendRequest(method, .{ .object = params });
        } else {
            try self.sendRequest(method, null);
        }
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

    /// A token that opts a request into progress notifications.
    ///
    /// The token travels in `params._meta.progressToken`; the server echoes it
    /// on each `notifications/progress` it sends.
    pub const ProgressToken = union(enum) {
        string: []const u8,
        integer: i64,

        pub fn toJson(self: ProgressToken) std.json.Value {
            return switch (self) {
                .string => |s| .{ .string = s },
                .integer => |i| .{ .integer = i },
            };
        }
    };

    /// Adds a `progressToken` to a request's `_meta`, opting into progress
    /// notifications for that request.
    fn putProgressToken(self: *Self, token: ?ProgressToken, params: *std.json.ObjectMap) !void {
        const t = token orelse return;
        var meta: std.json.ObjectMap = .empty;
        if (params.get("_meta")) |existing| {
            if (existing == .object) meta = existing.object;
        }
        try meta.put(self.allocator, "progressToken", t.toJson());
        try params.put(self.allocator, "_meta", .{ .object = meta });
    }

    /// Cancels an in-flight request the client previously issued.
    ///
    /// The server answers the original request with -32800; a cancelled
    /// request still produces a response, as JSON-RPC requires.
    pub fn cancel(self: *Self, request_id: i64, reason: ?[]const u8) !void {
        var params: std.json.ObjectMap = .empty;
        defer params.deinit(self.allocator);
        try params.put(self.allocator, "requestId", .{ .integer = request_id });
        if (reason) |r| {
            try params.put(self.allocator, "reason", .{ .string = r });
        }
        try self.sendNotification("notifications/cancelled", .{ .object = params });
    }

    /// Calls a tool, optionally opting into progress notifications.
    pub fn callToolWithProgress(
        self: *Self,
        name: []const u8,
        arguments: ?std.json.Value,
        progress: ?ProgressToken,
    ) !void {
        var params: std.json.ObjectMap = .empty;
        defer params.deinit(self.allocator);
        try params.put(self.allocator, "name", .{ .string = name });
        if (arguments) |args| {
            try params.put(self.allocator, "arguments", args);
        }
        try self.putProgressToken(progress, &params);
        try self.sendRequest("tools/call", .{ .object = params });
    }

    /// Requests the list of available resources from the server.
    pub fn listResources(self: *Self) !void {
        try self.listResourcesPage(null);
    }

    /// Requests one page of resources, resuming from `cursor`.
    pub fn listResourcesPage(self: *Self, cursor: ?[]const u8) !void {
        try self.sendPaginated("resources/list", cursor);
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

    /// Opens a long-lived notification stream via `subscriptions/listen`.
    ///
    /// The filter is sent as `params.notifications`, and the stream stays open
    /// until cancelled. Every notification the server sends back carries the
    /// subscription id of this request in `_meta`.
    pub fn subscriptionsListen(self: *Self, filter: types.SubscriptionFilter) !void {
        var notifications: std.json.ObjectMap = .empty;
        defer notifications.deinit(self.allocator);

        // The array must outlive the block that fills it: `notifications`
        // stores a copy of the slice and sendRequest reads it below.
        var uris: ?std.json.Array = null;
        defer if (uris) |*a| a.deinit();

        if (filter.toolsListChanged) try notifications.put(self.allocator, "toolsListChanged", .{ .bool = true });
        if (filter.promptsListChanged) try notifications.put(self.allocator, "promptsListChanged", .{ .bool = true });
        if (filter.resourcesListChanged) try notifications.put(self.allocator, "resourcesListChanged", .{ .bool = true });
        if (filter.resourceSubscriptions) |list| {
            if (list.len > 0) {
                var arr: std.json.Array = .init(self.allocator);
                for (list) |u| try arr.append(.{ .string = u });
                try notifications.put(self.allocator, "resourceSubscriptions", .{ .array = arr });
                uris = arr;
            }
        }

        var params: std.json.ObjectMap = .empty;
        defer params.deinit(self.allocator);
        try params.put(self.allocator, "notifications", .{ .object = notifications });
        try self.sendRequest("subscriptions/listen", .{ .object = params });
    }

    /// Requests the list of resource templates from the server.
    pub fn listResourceTemplates(self: *Self) !void {
        try self.listResourceTemplatesPage(null);
    }

    /// Requests one page of resource templates, resuming from `cursor`.
    pub fn listResourceTemplatesPage(self: *Self, cursor: ?[]const u8) !void {
        try self.sendPaginated("resources/templates/list", cursor);
    }

    /// Requests the list of available prompts from the server.
    pub fn listPrompts(self: *Self) !void {
        try self.listPromptsPage(null);
    }

    /// Requests one page of prompts, resuming from `cursor`.
    pub fn listPromptsPage(self: *Self, cursor: ?[]const u8) !void {
        try self.sendPaginated("prompts/list", cursor);
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

test "MRTR driver walks input-required rounds automatically" {
    const a = std.testing.allocator;

    var client = Client.init(std.Io.failing, a, .{ .name = "c", .version = "1.0.0" });
    defer client.deinit();

    var seen_keys: std.ArrayList([]u8) = .empty;
    defer {
        for (seen_keys.items) |k| a.free(k);
        seen_keys.deinit(a);
    }

    const Ctx = struct {
        keys: *std.ArrayList([]u8),
        owned: *std.ArrayList(std.json.ObjectMap),
        allocator: std.mem.Allocator,

        fn resolve(ctx: *anyopaque, allocator: std.mem.Allocator, key: []const u8, request: std.json.Value) anyerror!std.json.Value {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            const owned = try allocator.dupe(u8, key);
            try self.keys.append(self.allocator, owned);

            // Answer elicitation with an accept, and sampling with a message.
            const method = if (request == .object)
                (request.object.get("method") orelse std.json.Value{ .null = {} }).string
            else
                "";
            if (std.mem.eql(u8, method, "elicitation/create")) {
                var content: std.json.ObjectMap = .empty;
                try content.put(allocator, "answer", .{ .string = "42" });
                var out: std.json.ObjectMap = .empty;
                try out.put(allocator, "action", .{ .string = "accept" });
                try out.put(allocator, "content", .{ .object = content });
                try self.owned.append(self.allocator, content);
                try self.owned.append(self.allocator, out);
                return .{ .object = out };
            }
            var out: std.json.ObjectMap = .empty;
            try out.put(allocator, "text", .{ .string = "hello" });
            try self.owned.append(self.allocator, out);
            return .{ .object = out };
        }
    };

    var owned: std.ArrayList(std.json.ObjectMap) = .empty;
    defer {
        for (owned.items) |m| {
            var map = m;
            map.deinit(a);
        }
        owned.deinit(a);
    }

    var ctx = Ctx{ .keys = &seen_keys, .owned = &owned, .allocator = a };
    const resolver = Client.InputResolver{ .ctx = &ctx, .resolve = Ctx.resolve };

    const first_id = try client.callToolResolved("needs_input", null, resolver);
    try std.testing.expectEqual(@as(i64, 1), first_id);

    // Round 1: the server asks for two inputs and returns opaque state.
    try client.handleMessage(
        \\{"jsonrpc":"2.0","id":1,"result":{"resultType":"input_required","inputRequests":{
        \\  "who":{"method":"elicitation/create","params":{"message":"Who?"}},
        \\  "what":{"method":"sampling/createMessage","params":{"maxTokens":10}}},
        \\  "requestState":"opaque-blob"}}
    );

    // The resolver was consulted for both requests.
    try std.testing.expectEqual(@as(usize, 2), seen_keys.items.len);
    try std.testing.expectEqualStrings("who", seen_keys.items[0]);
    try std.testing.expectEqualStrings("what", seen_keys.items[1]);

    // Still no final result: the driver sent a retry instead.
    try std.testing.expect(client.takeResult(1) == null);

    // Round 2: the server answers, and the retry carried a different id.
    try client.handleMessage(
        \\{"jsonrpc":"2.0","id":2,"result":{"resultType":"complete","content":[{"type":"text","text":"done"}]}}
    );

    const final = client.takeResult(2) orelse return error.NoResultStored;
    defer a.free(final);
    try std.testing.expect(std.mem.indexOf(u8, final, "done") != null);
}

test "MRTR driver stops at the configured round limit" {
    const a = std.testing.allocator;

    var client = Client.init(std.Io.failing, a, .{ .name = "c", .version = "1.0.0" });
    defer client.deinit();

    const Ctx = struct {
        fn resolve(ctx: *anyopaque, allocator: std.mem.Allocator, key: []const u8, request: std.json.Value) anyerror!std.json.Value {
            _ = ctx;
            _ = allocator;
            _ = key;
            _ = request;
            return .{ .null = {} };
        }
    };

    client.max_mrtr_rounds = 2;
    const resolver = Client.InputResolver{ .ctx = undefined, .resolve = Ctx.resolve };
    const id = try client.callToolResolved("loop", null, resolver);

    // Every round asks again; the driver must eventually refuse rather than
    // spin forever.
    var round: i64 = 1;
    var last_err: ?anyerror = null;
    while (round <= 6) : (round += 1) {
        const payload = try std.fmt.allocPrint(
            a,
            "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"resultType\":\"input_required\",\"inputRequests\":{{\"a\":{{\"method\":\"roots/list\",\"params\":{{}}}}}}}}}}",
            .{id + round - 1},
        );
        defer a.free(payload);
        client.handleMessage(payload) catch |err| {
            last_err = err;
            break;
        };
    }
    try std.testing.expectEqual(@as(?anyerror, error.MrtrRoundLimitExceeded), last_err);
}

test "handleMessage stores results for untracked requests" {
    const a = std.testing.allocator;
    var client = Client.init(std.Io.failing, a, .{ .name = "c", .version = "1.0.0" });
    defer client.deinit();

    try client.handleMessage(
        \\{"jsonrpc":"2.0","id":99,"result":{"resultType":"complete","ok":true}}
    );
    const stored = client.takeResult(99) orelse return error.NoResultStored;
    defer a.free(stored);
    try std.testing.expect(std.mem.indexOf(u8, stored, "\"ok\":true") != null);
    // Taking twice yields nothing.
    try std.testing.expect(client.takeResult(99) == null);
}

test "notifications dispatch to handlers and carry the subscription id" {
    const a = std.testing.allocator;
    var client = Client.init(std.Io.failing, a, .{ .name = "c", .version = "1.0.0" });
    defer client.deinit();

    const Seen = struct {
        method: []const u8 = "",
        subscription_id: ?i64 = null,
        uri: [64]u8 = undefined,
        uri_len: usize = 0,

        fn uriSlice(self: *const @This()) []const u8 {
            return self.uri[0..self.uri_len];
        }

        fn onUpdate(ctx: *anyopaque, params: std.json.ObjectMap, subscription_id: ?i64) void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.method = "notifications/resources/updated";
            self.subscription_id = subscription_id;
            if (params.get("uri")) |u| {
                if (u == .string) {
                    // `params` is only valid for this call, so copy anything
                    // that has to outlive it.
                    const n = @min(u.string.len, self.uri.len);
                    @memcpy(self.uri[0..n], u.string[0..n]);
                    self.uri_len = n;
                }
            }
        }

        fn onAck(ctx: *anyopaque, params: std.json.ObjectMap, subscription_id: ?i64) void {
            _ = params;
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.method = "ack";
            self.subscription_id = subscription_id;
        }
    };

    var seen = Seen{};
    try client.onNotification("notifications/resources/updated", .{
        .ctx = &seen,
        .handle = Seen.onUpdate,
    });
    try client.onNotification("notifications/subscriptions/acknowledged", .{
        .ctx = &seen,
        .handle = Seen.onAck,
    });

    // A notification tagged with the subscription id it belongs to.
    try client.handleMessage(
        \\{"jsonrpc":"2.0","method":"notifications/resources/updated","params":{"uri":"file:///a.json","_meta":{"io.modelcontextprotocol/subscriptionId":3}}}
    );
    try std.testing.expectEqualStrings("notifications/resources/updated", seen.method);
    try std.testing.expectEqual(@as(?i64, 3), seen.subscription_id);
    try std.testing.expectEqualStrings("file:///a.json", seen.uriSlice());
    try std.testing.expectEqual(@as(?i64, 3), client.currentSubscriptionId());

    // Two concurrent subscriptions stay distinguishable.
    try client.handleMessage(
        \\{"jsonrpc":"2.0","method":"notifications/resources/updated","params":{"uri":"file:///b.json","_meta":{"io.modelcontextprotocol/subscriptionId":8}}}
    );
    try std.testing.expectEqual(@as(?i64, 8), seen.subscription_id);
    try std.testing.expectEqual(@as(?i64, 8), client.currentSubscriptionId());

    // A notification with no subscription id still dispatches.
    try client.handleMessage(
        \\{"jsonrpc":"2.0","method":"notifications/tools/list_changed","params":{}}
    );
    try std.testing.expectEqual(@as(?i64, 8), client.currentSubscriptionId());

    // The acknowledgment routes to its own handler.
    try client.handleMessage(
        \\{"jsonrpc":"2.0","method":"notifications/subscriptions/acknowledged","params":{"_meta":{"io.modelcontextprotocol/subscriptionId":3}}}
    );
    try std.testing.expectEqualStrings("ack", seen.method);
    try std.testing.expectEqual(@as(?i64, 3), seen.subscription_id);

    // An unknown method is ignored rather than an error.
    try client.handleMessage(
        \\{"jsonrpc":"2.0","method":"notifications/something/unknown","params":{}}
    );

    // Handlers can be removed.
    try client.onNotification("notifications/subscriptions/acknowledged", null);
    try client.handleMessage(
        \\{"jsonrpc":"2.0","method":"notifications/subscriptions/acknowledged","params":{}}
    );
    try std.testing.expectEqualStrings("ack", seen.method);
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
    try client.subscriptionsListen(.{ .toolsListChanged = true });

    // Pagination cursors and the full subscription filter shape.
    try client.listToolsPage("c1");
    try client.listResourcesPage("c2");
    try client.listPromptsPage("c3");
    try client.listResourceTemplatesPage("c4");
    const watched = [_][]const u8{ "file:///a.json", "file:///b.json" };
    try client.subscriptionsListen(.{
        .toolsListChanged = true,
        .promptsListChanged = true,
        .resourcesListChanged = true,
        .resourceSubscriptions = &watched,
    });
    // An empty filter still has to produce a well-formed request.
    try client.subscriptionsListen(.{});
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

test "progressToken is sent in params._meta, not at the top level" {
    const a = std.testing.allocator;

    var sent = std.ArrayList([]u8).empty;
    defer {
        for (sent.items) |m| a.free(m);
        sent.deinit(a);
    }

    var client = Client.init(std.Io.failing, a, .{ .name = "progress-client", .version = "1.0.0" });
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

    try client.callToolWithProgress("long", null, .{ .string = "tok-1" });

    try std.testing.expectEqual(@as(usize, 1), sent.items.len);
    var parsed = try std.json.parseFromSlice(std.json.Value, a, sent.items[0], .{});
    defer parsed.deinit();

    const params = parsed.value.object.get("params").?.object;
    // The reserved key lives under _meta.
    try std.testing.expect(params.get("progressToken") == null);
    try std.testing.expectEqualStrings(
        "tok-1",
        params.get("_meta").?.object.get("progressToken").?.string,
    );
}

test "cancel sends notifications/cancelled carrying the request id" {
    const a = std.testing.allocator;

    var sent = std.ArrayList([]u8).empty;
    defer {
        for (sent.items) |m| a.free(m);
        sent.deinit(a);
    }

    var client = Client.init(std.Io.failing, a, .{ .name = "cancel-client", .version = "1.0.0" });
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

    try client.cancel(42, null);

    var parsed = try std.json.parseFromSlice(std.json.Value, a, sent.items[0], .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("notifications/cancelled", parsed.value.object.get("method").?.string);
    // A notification carries no id.
    try std.testing.expect(parsed.value.object.get("id") == null);
    try std.testing.expectEqual(
        @as(i64, 42),
        parsed.value.object.get("params").?.object.get("requestId").?.integer,
    );
}
