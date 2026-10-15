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
//!   - `Mcp-Name`              — required for tools/call, resources/read and
//!                               prompts/get; must equal `params.name` / `params.uri`
//!
//! Any mismatch is a `HeaderMismatch` error (`-32020`); an unsupported protocol
//! version is `UnsupportedProtocolVersion` (`-32022`).

const std = @import("std");
const protocol = @import("../protocol/protocol.zig");
const jsonrpc = @import("../protocol/jsonrpc.zig");

pub const header_protocol_version = "MCP-Protocol-Version";
pub const header_method = "Mcp-Method";
pub const header_name = "Mcp-Name";
pub const header_param_prefix = "Mcp-Param-";

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
};

/// Decodes the Base64 sentinel format used for header values that are not
/// safe as plain ASCII: `=?base64?<base64>?=`.
///
/// Returns null when the value is not sentinel-encoded. The caller owns the
/// returned slice when it is non-null.
pub fn decodeSentinel(allocator: std.mem.Allocator, value: []const u8) !?[]const u8 {
    const prefix = "=?base64?";
    const suffix = "?=";
    if (!std.mem.startsWith(u8, value, prefix)) return null;
    if (!std.mem.endsWith(u8, value, suffix)) return null;
    if (value.len <= prefix.len + suffix.len) return null;

    const payload = value[prefix.len .. value.len - suffix.len];
    const decoder = std.base64.standard.Decoder;
    const size = decoder.calcSizeForSlice(payload) catch return error.InvalidSentinel;
    const buf = try allocator.alloc(u8, size);
    errdefer allocator.free(buf);
    decoder.decode(buf, payload) catch return error.InvalidSentinel;
    return buf;
}

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

/// Parses the body once and validates it against the HTTP headers.
pub fn validate(
    allocator: std.mem.Allocator,
    headers: HeaderSource,
    request_body: []const u8,
    loopback_only: bool,
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

    // Protocol version header, when present, must match the body. It is
    // required; callers that must stay tolerant of pre-2025-06-18 clients can
    // check `headers.protocolVersion() == null` themselves.
    const header_version = headers.protocolVersion() orelse {
        return .{ .missing_header = .{ .name = header_protocol_version } };
    };
    const body_version = metaString(req.params, protocol.META_PROTOCOL_VERSION) orelse "";
    if (!std.mem.eql(u8, header_version, body_version)) {
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
    if (!std.mem.eql(u8, header_method_value, req.method)) {
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
            if (!std.mem.eql(u8, header_name_value, body_name)) {
                return .{ .mismatch = .{ .message = "Mcp-Name header does not match request params" } };
            }
        }
    } else {
        return .{ .unknown_method = .{ .method = req.method } };
    }

    return .ok;
}

/// The subset of `httpx.Context` this module needs, so tests can supply a
/// plain map.
pub const HeaderSource = struct {
    context: ?*const anyopaque = null,
    fallback: ?*const [3]?[]const u8 = null,

    pub fn fromHeaders(protocol_version: ?[]const u8, method_header: ?[]const u8, name_header: ?[]const u8) HeaderSource {
        return .{ .fallback = &[_]?[]const u8{ protocol_version, method_header, name_header } };
    }

    fn protocolVersion(self: HeaderSource) ?[]const u8 {
        if (self.context) |c| {
            const ctx: *const @import("httpx").Context = @ptrCast(@alignCast(c));
            return ctx.header(header_protocol_version);
        }
        return self.fallback.?[0];
    }
    fn method(self: HeaderSource) ?[]const u8 {
        if (self.context) |c| {
            const ctx: *const @import("httpx").Context = @ptrCast(@alignCast(c));
            return ctx.header(header_method);
        }
        return self.fallback.?[1];
    }
    fn name(self: HeaderSource) ?[]const u8 {
        if (self.context) |c| {
            const ctx: *const @import("httpx").Context = @ptrCast(@alignCast(c));
            return ctx.header(header_name);
        }
        return self.fallback.?[2];
    }
    pub fn origin(self: HeaderSource) ?[]const u8 {
        if (self.context) |c| {
            const ctx: *const @import("httpx").Context = @ptrCast(@alignCast(c));
            return ctx.header("Origin");
        }
        return null;
    }
};

pub fn requiresName(method: []const u8) bool {
    for (name_required_methods) |m| {
        if (std.mem.eql(u8, m, method)) return true;
    }
    return false;
}

fn isKnownMethod(method: []const u8) bool {
    return protocol.Method.fromString(method) != null or
        std.mem.eql(u8, method, "health/check");
}

fn paramsIdentity(method: []const u8, params: ?std.json.Value) ?[]const u8 {
    const p = params orelse return null;
    if (p != .object) return null;
    const key = if (std.mem.eql(u8, method, "resources/read")) "uri" else "name";
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

// --- tests ---

const testing = std.testing;

fn body(method: []const u8, version: ?[]const u8, extra: []const u8) []const u8 {
    const ver = if (version) |v| v else protocol.PROTOCOL_VERSION;
    return std.fmt.allocPrint(testing.allocator,
        \\{{"jsonrpc":"2.0","id":1,"method":"{s}","params":{{"_meta":{{"io.modelcontextprotocol/protocolVersion":"{s}"}}{s}}}}}
    , .{ method, ver, extra }) catch unreachable;
}

test "validate accepts a well-formed request" {
    const b = body("tools/list", null, "");
    defer testing.allocator.free(b);
    const v = try validate(testing.allocator, .fromHeaders(protocol.PROTOCOL_VERSION, "tools/list", null), b, true);
    try testing.expect(v == .ok);
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
