//! Streamable HTTP conformance rules (MCP 2026-07-28).
//!
//! The spec requires that the Streamable HTTP transport mirror selected body
//! fields into headers so intermediaries can route without parsing the body,
//! and that servers validate those headers against the body. This module holds
//! that logic as pure functions so it can be unit tested without a live
//! socket.
//!
//! Required headers on every POST to the MCP endpoint:
//!   - `MCP-Protocol-Version` — must equal `_meta["io.modelcontextprotocol/protocolVersion"]`
//!   - `Mcp-Method`            — must equal the JSON-RPC `method`
//!   - `Mcp-Name`              — required for tools/call, resources/read,
//!                               prompts/get and every `tasks/*` method; must
//!                               equal `params.name` / `params.uri` /
//!                               `params.taskId`
//!
//! Any mismatch is a `HeaderMismatch` error (`-32020`); an unsupported protocol
//! version is `UnsupportedProtocolVersion` (`-32022`).

const std = @import("std");
const httpx = @import("httpx");
const protocol = @import("../protocol/protocol.zig");
const jsonrpc = @import("../protocol/jsonrpc.zig");
const param_headers = @import("../protocol/param_headers.zig");

// Canonical definitions live in the protocol layer so the client and server
// cannot disagree about them; these remain as readable aliases.
pub const header_protocol_version = protocol.HEADER_PROTOCOL_VERSION;
pub const header_method = protocol.HEADER_METHOD;
pub const header_name = protocol.HEADER_NAME;
pub const header_param_prefix = protocol.HEADER_PARAM_PREFIX;

/// Methods whose identity is carried by `Mcp-Name`.
pub const name_required_methods = [_][]const u8{
    "tools/call",
    "resources/read",
    "prompts/get",
};

/// Outcome of validating an incoming HTTP request against its body.
pub const Verdict = union(enum) {
    /// Request is well-formed.
    ok,
    /// Header/body mismatch: `code` is always `HEADER_MISMATCH` (-32020).
    mismatch: struct { message: []const u8 },
    /// Protocol version is not supported: `code` is `UNSUPPORTED_PROTOCOL_VERSION`.
    unsupported_version: struct { supported: []const []const u8, requested: []const u8 },
    /// A required header was absent.
    missing_header: struct { name: []const u8 },
    /// `Origin` present but not allowed.
    forbidden_origin,
    /// The body is a notification: respond 202 Accepted with no body.
    accepted_notification,
    /// Unknown RPC method: 404 with -32601.
    unknown_method: struct { method: []const u8 },
    /// The body itself is not a valid JSON-RPC message.
    invalid_request: struct { message: []const u8 },
    /// A required `_meta` field is missing, so the request is malformed.
    invalid_params: struct { message: []const u8 },
};

/// Decodes the Base64 sentinel format used for header values that are not
/// safe as plain ASCII: `=?base64?<base64>?=`.
///
/// Returns null when the value is not sentinel-encoded. The caller owns the
/// returned slice when it is non-null.
pub const decodeSentinel = protocol.decodeSentinel;

/// Returns true when `Origin` is acceptable.
///
/// When the server binds to loopback, only loopback origins are allowed; this
/// is the DNS-rebinding protection the spec requires. A missing Origin header
/// (non-browser client) is allowed.
pub fn isOriginAllowed(origin: ?[]const u8, loopback_only: bool) bool {
    const o = origin orelse return true;
    if (!loopback_only) return true;

    const host = hostOfOrigin(o) orelse return false;
    return isLoopbackHostName(host);
}

fn hostOfOrigin(origin: []const u8) ?[]const u8 {
    const scheme_end = std.mem.indexOf(u8, origin, "://") orelse return null;
    var rest = origin[scheme_end + 3 ..];
    // Strip userinfo if present.
    if (std.mem.indexOfScalar(u8, rest, '@')) |at| rest = rest[at + 1 ..];
    // Strip path/query/fragment.
    if (std.mem.indexOfAny(u8, rest, "/?#")) |cut| rest = rest[0..cut];
    // Strip port.
    if (std.mem.lastIndexOfScalar(u8, rest, ':')) |colon| {
        const maybe_port = rest[colon + 1 ..];
        if (maybe_port.len == 0 or (std.ascii.isDigit(maybe_port[0]) and std.fmt.parseInt(u16, maybe_port, 10) catch null != null)) {
            rest = rest[0..colon];
        }
    }
    return if (rest.len == 0) null else rest;
}

/// True when a bare hostname/IP is a loopback address. Used to decide whether
/// a listener is loopback-only.
pub fn isLoopbackHostName(host: []const u8) bool {
    if (host.len == 0) return false;
    // Strip IPv6 brackets.
    if (host.len >= 2 and host[0] == '[' and host[host.len - 1] == ']') {
        return isLoopbackHostName(host[1 .. host.len - 1]);
    }
    if (std.mem.eql(u8, host, "localhost")) return true;
    if (std.mem.eql(u8, host, "::1")) return true;
    // IPv4 loopback range 127.0.0.0/8
    var it = std.mem.splitScalar(u8, host, '.');
    var octet: u8 = 0;
    var seen: usize = 0;
    while (it.next()) |part| {
        seen += 1;
        if (seen > 4) return false;
        octet = std.fmt.parseInt(u8, part, 10) catch return false;
        if (seen == 1) {
            if (octet != 127) return false;
        }
    }
    return seen == 4;
}

/// True when a header value matches the corresponding body field.
///
/// Header values that cannot be represented safely in an HTTP header are sent
/// using the spec's base64 sentinel (`=?base64?<base64>?=`), so a raw byte
/// comparison alone would reject an otherwise valid request.
fn headerMatchesBody(allocator: std.mem.Allocator, header_value: []const u8, body_value: []const u8) !bool {
    if (std.mem.eql(u8, header_value, body_value)) return true;

    const decoded = try decodeSentinel(allocator, header_value);
    defer if (decoded) |buf| allocator.free(buf);
    const buf = decoded orelse return false;
    return std.mem.eql(u8, buf, body_value);
}

/// Parses the body once and validates it against the HTTP headers.
pub fn validate(
    allocator: std.mem.Allocator,
    headers: HeaderSource,
    request_body: []const u8,
    loopback_only: bool,
) !Verdict {
    return validateWithSchemas(allocator, headers, request_body, loopback_only, .{});
}

/// Resolves the `inputSchema` a tool was declared with.
///
/// The server needs this to know which arguments a client is required to
/// mirror as `Mcp-Param-*` headers, and what values they must agree with.
pub const ArgumentSchemas = struct {
    ctx: ?*const anyopaque = null,
    resolve: ?*const fn (ctx: *const anyopaque, tool_name: []const u8) ?std.json.Value = null,
};

pub fn validateWithSchemas(
    allocator: std.mem.Allocator,
    headers: HeaderSource,
    request_body: []const u8,
    loopback_only: bool,
    schemas: ArgumentSchemas,
) !Verdict {
    if (!isOriginAllowed(headers.origin(), loopback_only)) {
        return .forbidden_origin;
    }

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    const parsed = jsonrpc.parseMessage(aa, request_body) catch {
        return .{ .invalid_request = .{ .message = "Invalid JSON-RPC message" } };
    };

    // Notifications carry no response: 202 Accepted with no body.
    switch (parsed.message) {
        .notification => return .accepted_notification,
        .response, .error_response => {
            return .{ .invalid_request = .{ .message = "Clients must not send responses to servers" } };
        },
        .request => {},
    }
    const req = parsed.message.request;

    // Per-request protocol fields: `protocolVersion` and `clientCapabilities`
    // are both required on every client request. A request missing either is
    // malformed and the spec answers -32602 (HTTP 400), so this is checked
    // before the header/body comparison, which would otherwise report a
    // missing body field as a header mismatch (-32020).
    if (metaString(req.params, protocol.META_PROTOCOL_VERSION) == null) {
        return .{ .invalid_params = .{ .message = "Missing required _meta field: io.modelcontextprotocol/protocolVersion" } };
    }
    if (metaValue(req.params, protocol.META_CLIENT_CAPABILITIES) == null) {
        return .{ .invalid_params = .{ .message = "Missing required _meta field: io.modelcontextprotocol/clientCapabilities" } };
    }

    // Protocol version header, when present, must match the body. It is
    // required; callers that must stay tolerant of pre-2025-06-18 clients can
    // check `headers.protocolVersion() == null` themselves.
    const header_version = headers.protocolVersion() orelse {
        return .{ .missing_header = .{ .name = header_protocol_version } };
    };
    const body_version = metaString(req.params, protocol.META_PROTOCOL_VERSION) orelse "";
    if (!try headerMatchesBody(allocator, header_version, body_version)) {
        return .{ .mismatch = .{ .message = "MCP-Protocol-Version header does not match _meta" } };
    }
    const supported = protocol.supportsVersion(header_version);
    if (!supported) {
        return .{ .unsupported_version = .{
            .supported = &protocol.SUPPORTED_VERSIONS,
            .requested = header_version,
        } };
    }

    // Mcp-Method must mirror the JSON-RPC method.
    const header_method_value = headers.method() orelse {
        return .{ .missing_header = .{ .name = header_method } };
    };
    if (!try headerMatchesBody(allocator, header_method_value, req.method)) {
        return .{ .mismatch = .{ .message = "Mcp-Method header does not match request method" } };
    }

    if (isKnownMethod(req.method)) {
        // Mcp-Name mirrors params.name / params.uri where applicable.
        const needs_name = requiresName(req.method);
        if (needs_name) {
            const header_name_value = headers.name() orelse {
                return .{ .missing_header = .{ .name = header_name } };
            };
            const body_name = paramsIdentity(req.method, req.params) orelse "";
            if (!try headerMatchesBody(allocator, header_name_value, body_name)) {
                return .{ .mismatch = .{ .message = "Mcp-Name header does not match request params" } };
            }
        }
    } else {
        return .{ .unknown_method = .{ .method = req.method } };
    }

    // Mirrored per-parameter headers must agree with the body.
    if (!try validateParamHeaders(allocator, headers, req.params, schemas)) {
        return .{ .mismatch = .{ .message = "Mcp-Param-* header does not match request params" } };
    }

    return .ok;
}

/// Validates every `Mcp-Param-<Name>` header against the matching body field.
///
/// A mirrored parameter that disagrees with the body is a header mismatch
/// (`-32020`). When the tool's `inputSchema` is available through `schemas`,
/// the check is exact: every argument annotated with `x-mcp-header` must be
/// present with an agreeing header, and a header naming an argument that is
/// not annotated is rejected. Without a schema the check falls back to
/// matching headers against same-named top-level params.
pub fn validateParamHeaders(
    allocator: std.mem.Allocator,
    source: HeaderSource,
    params: ?std.json.Value,
    schemas: ArgumentSchemas,
) !bool {
    const p = params orelse return true;
    if (p != .object) return true;

    const mirrored = try source.collectParamHeaders(allocator);
    defer if (mirrored.owned) allocator.free(mirrored.items);

    const method = source.method() orelse "";

    // `x-mcp-header` mirrors tool *arguments*, which live under
    // `params.arguments`; other methods have no such nesting.
    var annotations: []param_headers.Annotation = @constCast(&.{});
    defer param_headers.Annotation.freeList(allocator, annotations);

    var body_root: std.json.Value = p;
    if (std.mem.eql(u8, method, "tools/call")) {
        if (schemas.resolve) |resolve| {
            const schema_ctx = schemas.ctx orelse return true;
            if (p.object.get("name")) |n| {
                if (n == .string) {
                    if (resolve(schema_ctx, n.string)) |schema| {
                        // A schema that cannot be walked is the tool author's
                        // bug; leave the request to the normal validation path.
                        annotations = param_headers.collect(allocator, schema) catch &.{};
                    }
                }
            }
        }
        if (annotations.len != 0) {
            const args = p.object.get("arguments") orelse return true;
            body_root = args;
        }
    }
    if (body_root != .object) return true;

    for (mirrored.items) |entry| {
        if (!std.mem.startsWith(u8, entry.name, header_param_prefix)) continue;

        const field = entry.name[header_param_prefix.len..];
        if (field.len == 0) return false;

        var body_value: ?std.json.Value = null;
        if (annotations.len != 0) {
            // Only annotated arguments may be mirrored.
            const found = for (annotations) |a| {
                if (std.ascii.eqlIgnoreCase(a.name, field)) break a;
            } else null;
            const annotation = found orelse return false;
            body_value = param_headers.valueAtPath(body_root, annotation.path);
            if (body_value == null) return false;
        } else {
            body_value = body_root.object.get(field) orelse return false;
        }

        var expected: ?[]const u8 = null;
        defer if (expected) |e| allocator.free(e);
        switch (body_value.?) {
            .string => |s| expected = try allocator.dupe(u8, s),
            .integer => |i| expected = try std.fmt.allocPrint(allocator, "{d}", .{i}),
            .bool => |b| expected = try allocator.dupe(u8, if (b) "true" else "false"),
            // `x-mcp-header` is only defined for string, integer and boolean
            // primitives, so nothing else can legitimately be mirrored.
            else => return false,
        }
        const want = expected orelse continue;

        if (!try headerMatchesBody(allocator, entry.value, want)) return false;
    }

    // With a schema in hand, every annotated argument must also be mirrored.
    if (annotations.len != 0) {
        for (annotations) |a| {
            var present = false;
            for (mirrored.items) |entry| {
                if (!std.mem.startsWith(u8, entry.name, header_param_prefix)) continue;
                const field = entry.name[header_param_prefix.len..];
                if (std.ascii.eqlIgnoreCase(a.name, field)) {
                    present = true;
                    break;
                }
            }
            if (!present) return false;
        }
    }

    return true;
}

/// A mirrored `Mcp-Param-*` header pair.
pub const ParamHeader = struct {
    name: []const u8,
    value: []const u8,
};

/// The subset of `httpx.Context` this module needs, so tests can supply a
/// plain map.
pub const HeaderSource = struct {
    context: ?*const anyopaque = null,
    fallback: ?*const [3]?[]const u8 = null,
    /// Mirrored parameter headers, supplied directly by tests. Real requests
    /// read these off the httpx context instead.
    params: []const ParamHeader = &.{},

    pub fn fromHeaders(protocol_version: ?[]const u8, method_header: ?[]const u8, name_header: ?[]const u8) HeaderSource {
        return .{ .fallback = &[_]?[]const u8{ protocol_version, method_header, name_header } };
    }

    fn protocolVersion(self: HeaderSource) ?[]const u8 {
        if (self.context) |c| {
            const ctx: *const httpx.Context = @ptrCast(@alignCast(c));
            return ctx.header(header_protocol_version);
        }
        return self.fallback.?[0];
    }
    fn method(self: HeaderSource) ?[]const u8 {
        if (self.context) |c| {
            const ctx: *const httpx.Context = @ptrCast(@alignCast(c));
            return ctx.header(header_method);
        }
        return self.fallback.?[1];
    }
    fn name(self: HeaderSource) ?[]const u8 {
        if (self.context) |c| {
            const ctx: *const httpx.Context = @ptrCast(@alignCast(c));
            return ctx.header(header_name);
        }
        return self.fallback.?[2];
    }
    pub fn origin(self: HeaderSource) ?[]const u8 {
        if (self.context) |c| {
            const ctx: *const httpx.Context = @ptrCast(@alignCast(c));
            return ctx.header("Origin");
        }
        return null;
    }

    /// Collects the `Mcp-Param-*` headers. Caller frees the slice.
    /// Mirrored parameter headers plus whether the slice is owned by the caller.
    const CollectedParams = struct {
        items: []const ParamHeader,
        owned: bool,
    };

    fn collectParamHeaders(self: HeaderSource, allocator: std.mem.Allocator) !CollectedParams {
        if (self.params.len != 0) return .{ .items = self.params, .owned = false };

        if (self.context == null) return .{ .items = &.{}, .owned = false };

        const ctx: *const httpx.Context = @ptrCast(@alignCast(self.context.?));
        var list: std.ArrayList(ParamHeader) = .empty;
        errdefer list.deinit(allocator);
        for (ctx.headers) |h| {
            if (std.ascii.startsWithIgnoreCase(h.name, header_param_prefix)) {
                try list.append(allocator, .{ .name = h.name, .value = h.value });
            }
        }
        return .{ .items = try list.toOwnedSlice(allocator), .owned = true };
    }
};

pub fn requiresName(method: []const u8) bool {
    for (name_required_methods) |m| {
        if (std.mem.eql(u8, m, method)) return true;
    }
    // Every `tasks/*` request is keyed by `taskId`, so it carries Mcp-Name too.
    return std.mem.startsWith(u8, method, "tasks/");
}

fn isKnownMethod(method: []const u8) bool {
    return protocol.Method.fromString(method) != null or
        std.mem.eql(u8, method, "health/check");
}

fn paramsIdentity(method: []const u8, params: ?std.json.Value) ?[]const u8 {
    const p = params orelse return null;
    if (p != .object) return null;
    const key = if (std.mem.eql(u8, method, "resources/read"))
        "uri"
    else if (std.mem.startsWith(u8, method, "tasks/"))
        "taskId"
    else
        "name";
    const v = p.object.get(key) orelse return null;
    return if (v == .string) v.string else null;
}

fn metaString(params: ?std.json.Value, key: []const u8) ?[]const u8 {
    const p = params orelse return null;
    if (p != .object) return null;
    const meta = p.object.get("_meta") orelse return null;
    if (meta != .object) return null;
    const v = meta.object.get(key) orelse return null;
    return if (v == .string) v.string else null;
}

/// Like `metaString`, but returns the raw `_meta` value so non-string fields
/// (such as the client capabilities object) can be presence-checked.
fn metaValue(params: ?std.json.Value, key: []const u8) ?std.json.Value {
    const p = params orelse return null;
    if (p != .object) return null;
    const meta = p.object.get("_meta") orelse return null;
    if (meta != .object) return null;
    return meta.object.get(key);
}

// tests

const testing = std.testing;

/// Builds a request body carrying the `_meta` fields the spec requires on
/// every client request: `protocolVersion` and `clientCapabilities`.
fn body(method: []const u8, version: ?[]const u8, extra: []const u8) []const u8 {
    const ver = if (version) |v| v else protocol.PROTOCOL_VERSION;
    return std.fmt.allocPrint(testing.allocator,
        \\{{"jsonrpc":"2.0","id":1,"method":"{s}","params":{{"_meta":{{"io.modelcontextprotocol/protocolVersion":"{s}","io.modelcontextprotocol/clientCapabilities":{{}}}}{s}}}}}
    , .{ method, ver, extra }) catch unreachable;
}

test "validate accepts a well-formed request" {
    const b = body("tools/list", null, "");
    defer testing.allocator.free(b);
    const v = try validate(testing.allocator, .fromHeaders(protocol.PROTOCOL_VERSION, "tools/list", null), b, true);
    try testing.expect(v == .ok);
}

test "validate rejects a request missing required _meta fields" {
    // The spec marks protocolVersion and clientCapabilities as required on
    // every client request; a request missing either is malformed and is
    // answered with -32602 (HTTP 400), not a header error.
    const no_caps = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/list\",\"params\":{\"_meta\":{\"io.modelcontextprotocol/protocolVersion\":\"2026-07-28\"}}}";
    const headers = HeaderSource.fromHeaders("2026-07-28", "tools/list", null);
    const v1 = try validate(testing.allocator, headers, no_caps, true);
    try testing.expect(v1 == .invalid_params);

    const no_version = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/list\",\"params\":{\"_meta\":{\"io.modelcontextprotocol/clientCapabilities\":{}}}}";
    const v2 = try validate(testing.allocator, headers, no_version, true);
    try testing.expect(v2 == .invalid_params);
}

test "validate rejects a missing protocol version header" {
    const b = body("tools/list", null, "");
    defer testing.allocator.free(b);
    const v = try validate(testing.allocator, .fromHeaders(null, "tools/list", null), b, true);
    try testing.expect(v == .missing_header);
}

test "validate rejects protocol version header/body mismatch" {
    const b = body("tools/list", null, "");
    defer testing.allocator.free(b);
    const v = try validate(testing.allocator, .fromHeaders("2025-06-18", "tools/list", null), b, true);
    try testing.expect(v == .mismatch);
}

test "validate rejects an unsupported protocol version" {
    const b = body("tools/list", "1900-01-01", "");
    defer testing.allocator.free(b);
    const v = try validate(testing.allocator, .fromHeaders("1900-01-01", "tools/list", null), b, true);
    try testing.expect(v == .unsupported_version);
}

test "validate rejects deprecated protocol versions as unsupported" {
    const b = body("tools/list", "2025-11-25", "");
    defer testing.allocator.free(b);
    const v = try validate(testing.allocator, .fromHeaders("2025-11-25", "tools/list", null), b, true);
    try testing.expect(v == .unsupported_version);
    try testing.expectEqualStrings("2025-11-25", v.unsupported_version.requested);
    try testing.expectEqual(@as(usize, 1), v.unsupported_version.supported.len);
    try testing.expectEqualStrings("2026-07-28", v.unsupported_version.supported[0]);
}

test "validate rejects a method header/body mismatch" {
    const b = body("tools/list", null, "");
    defer testing.allocator.free(b);
    const v = try validate(testing.allocator, .fromHeaders(protocol.PROTOCOL_VERSION, "resources/list", null), b, true);
    try testing.expect(v == .mismatch);
}

test "validate requires Mcp-Name for tools/call and checks it" {
    const extra = ",\"name\":\"greet\"";
    const b = body("tools/call", null, extra);
    defer testing.allocator.free(b);

    const missing = try validate(testing.allocator, .fromHeaders(protocol.PROTOCOL_VERSION, "tools/call", null), b, true);
    try testing.expect(missing == .missing_header);

    const good = try validate(testing.allocator, .fromHeaders(protocol.PROTOCOL_VERSION, "tools/call", "greet"), b, true);
    try testing.expect(good == .ok);

    const bad = try validate(testing.allocator, .fromHeaders(protocol.PROTOCOL_VERSION, "tools/call", "other"), b, true);
    try testing.expect(bad == .mismatch);
}

test "validate requires Mcp-Name for resources/read" {
    const b = body("resources/read", null, ",\"uri\":\"file:///a.txt\"");
    defer testing.allocator.free(b);
    const v = try validate(testing.allocator, .fromHeaders(protocol.PROTOCOL_VERSION, "resources/read", "file:///a.txt"), b, true);
    try testing.expect(v == .ok);
}

test "validate reports unknown methods" {
    const b = body("does/notExist", null, "");
    defer testing.allocator.free(b);
    const v = try validate(testing.allocator, .fromHeaders(protocol.PROTOCOL_VERSION, "does/notExist", null), b, true);
    try testing.expect(v == .unknown_method);
}

test "validate treats notifications as accepted" {
    const b = "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/cancelled\",\"params\":{\"requestId\":\"1\"}}";
    const v = try validate(testing.allocator, .fromHeaders(protocol.PROTOCOL_VERSION, "notifications/cancelled", null), b, true);
    try testing.expect(v == .accepted_notification);
}

test "validate rejects malformed bodies" {
    const v = try validate(testing.allocator, .fromHeaders(protocol.PROTOCOL_VERSION, "tools/list", null), "{oops", true);
    try testing.expect(v == .invalid_request);
}

test "origin: loopback only accepts loopback origins" {
    try testing.expect(isOriginAllowed(null, true));
    try testing.expect(isOriginAllowed("http://localhost:3000", true));
    try testing.expect(isOriginAllowed("http://127.0.0.1:8080", true));
    try testing.expect(isOriginAllowed("http://127.5.5.5", true));
    try testing.expect(isOriginAllowed("http://[::1]:8080", true));
    try testing.expect(!isOriginAllowed("http://evil.example.com", true));
    try testing.expect(!isOriginAllowed("http://192.168.1.10", true));
    try testing.expect(isOriginAllowed("http://evil.example.com", false));
}

test "sentinel decoding round-trips and passes through plain values" {
    const enc = "=?base64?SGVsbG8sIOS4lueVjA==?=";
    const decoded = (try decodeSentinel(testing.allocator, enc)).?;
    defer testing.allocator.free(decoded);
    try testing.expectEqualStrings("Hello, \u{4e16}\u{754c}", decoded);

    try testing.expect((try decodeSentinel(testing.allocator, "plain-value")) == null);
}

test "spec: Mcp-Param-* headers are validated against the body" {
    const a = testing.allocator;

    const req_body = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"greet\",\"arguments\":{\"who\":\"Zig\",\"times\":3},\"_meta\":{\"io.modelcontextprotocol/protocolVersion\":\"2026-07-28\",\"io.modelcontextprotocol/clientCapabilities\":{}}}}";

    const makeSource = struct {
        fn f(params: []const ParamHeader) HeaderSource {
            return .{
                .fallback = &[_]?[]const u8{ protocol.PROTOCOL_VERSION, "tools/call", "greet" },
                .params = params,
            };
        }
    }.f;

    const agree = [_]ParamHeader{
        .{ .name = "Mcp-Param-name", .value = "greet" },
    };
    try testing.expect(try validate(a, makeSource(&agree), req_body, false) == .ok);

    const disagree = [_]ParamHeader{
        .{ .name = "Mcp-Param-name", .value = "other" },
    };
    try testing.expect(try validate(a, makeSource(&disagree), req_body, false) == .mismatch);

    const unknown = [_]ParamHeader{
        .{ .name = "Mcp-Param-nope", .value = "x" },
    };
    try testing.expect(try validate(a, makeSource(&unknown), req_body, false) == .mismatch);
}

test "spec: Mcp-Param-* validation is schema-aware for nested tool arguments" {
    const a = testing.allocator;

    // `who` is annotated, so the client must mirror it as Mcp-Param-Who and
    // the value must agree with params.arguments.who. `times` is not
    // annotated, so mirroring it must be rejected.
    const schema = try std.json.parseFromSlice(std.json.Value, a,
        \\{
        \\  "type": "object",
        \\  "properties": {
        \\    "who": { "type": "string", "x-mcp-header": "Who" },
        \\    "times": { "type": "integer" }
        \\  },
        \\  "required": ["who"]
        \\}
    , .{});
    defer schema.deinit();

    const SchemaCtx = struct { value: std.json.Value };
    var schema_ctx = SchemaCtx{ .value = schema.value };

    const resolve = struct {
        fn f(user: *const anyopaque, tool_name: []const u8) ?std.json.Value {
            if (!std.mem.eql(u8, tool_name, "greet")) return null;
            const self: *const SchemaCtx = @ptrCast(@alignCast(user));
            return self.value;
        }
    }.f;
    const schemas: ArgumentSchemas = .{ .ctx = @ptrCast(&schema_ctx), .resolve = resolve };

    const makeSource = struct {
        fn f(params: []const ParamHeader) HeaderSource {
            return .{
                .fallback = &[_]?[]const u8{ protocol.PROTOCOL_VERSION, "tools/call", "greet" },
                .params = params,
            };
        }
    }.f;

    const call_body = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"greet\",\"arguments\":{\"who\":\"Zig\",\"times\":3},\"_meta\":{\"io.modelcontextprotocol/protocolVersion\":\"2026-07-28\",\"io.modelcontextprotocol/clientCapabilities\":{}}}}";

    // Mirroring the annotated argument with the right value is accepted.
    const agree = [_]ParamHeader{.{ .name = "Mcp-Param-Who", .value = "Zig" }};
    try testing.expect(try validateWithSchemas(a, makeSource(&agree), call_body, false, schemas) == .ok);

    // A value that disagrees with the body is a header mismatch.
    const disagree = [_]ParamHeader{.{ .name = "Mcp-Param-Who", .value = "Rust" }};
    try testing.expect(try validateWithSchemas(a, makeSource(&disagree), call_body, false, schemas) == .mismatch);

    // Mirroring an argument the schema does not annotate is rejected.
    const unannotated = [_]ParamHeader{.{ .name = "Mcp-Param-Times", .value = "3" }};
    try testing.expect(try validateWithSchemas(a, makeSource(&unannotated), call_body, false, schemas) == .mismatch);

    // Every annotated argument must be mirrored, so omitting it is rejected.
    try testing.expect(try validateWithSchemas(a, makeSource(&.{}), call_body, false, schemas) == .mismatch);

    // Without a schema the old lenient behaviour still holds.
    try testing.expect(try validateWithSchemas(a, makeSource(&.{}), call_body, false, .{}) == .ok);
}

test "http: Mcp-Name accepts the base64 sentinel encoding" {
    const a = testing.allocator;

    // A resource URI containing non-ASCII cannot travel as a plain header
    // value, so the client sends it sentinel-encoded. The server must decode
    // before comparing, otherwise every such request is rejected as a mismatch.
    const uri = "file:///caf\u{00e9}/\u{4e16}\u{754c}.txt";
    const b64 = try protocol.base64Alloc(a, uri);
    defer a.free(b64);
    const header_value = try std.fmt.allocPrint(a, "=?base64?{s}?=", .{b64});
    defer a.free(header_value);

    const req_body = try std.fmt.allocPrint(
        a,
        "{{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"resources/read\",\"params\":{{\"uri\":\"{s}\",\"_meta\":{{\"io.modelcontextprotocol/protocolVersion\":\"2026-07-28\",\"io.modelcontextprotocol/clientCapabilities\":{{}}}}}}}}",
        .{uri},
    );
    defer a.free(req_body);

    const headers = HeaderSource.fromHeaders("2026-07-28", "resources/read", header_value);

    const verdict = try validate(a, headers, req_body, false);
    try testing.expect(verdict == .ok);
}

test "http: Mcp-Method sentinel encoding is honoured" {
    const a = testing.allocator;

    const method = "tools/call";
    const b64 = try protocol.base64Alloc(a, method);
    defer a.free(b64);
    const header_value = try std.fmt.allocPrint(a, "=?base64?{s}?=", .{b64});
    defer a.free(header_value);

    const req_body = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"t\",\"_meta\":{\"io.modelcontextprotocol/protocolVersion\":\"2026-07-28\",\"io.modelcontextprotocol/clientCapabilities\":{}}}}";
    const headers = HeaderSource.fromHeaders("2026-07-28", header_value, "t");

    const verdict = try validate(a, headers, req_body, false);
    try testing.expect(verdict == .ok);
}
