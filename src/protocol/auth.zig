//! MCP Authorization & OAuth Utilities (RFC 6749, RFC 8414, RFC 9728)
//!
//! Provides utilities for OAuth 2.0 / 2.1 authentication in MCP:
//! - WWW-Authenticate header challenge parsing (RFC 6750)
//! - OAuth Protected Resource Metadata discovery (RFC 9728 / draft-ietf-oauth-resource-metadata)
//! - OAuth 2.0 Authorization Server Metadata discovery (RFC 8414)
//! - OAuth 2.0 Client Credentials token acquisition (RFC 6749 section 4.4)

const std = @import("std");
const httpx = @import("httpx");

/// Parsed parameters from a `WWW-Authenticate: Bearer ...` HTTP response header (RFC 6750).
pub const WwwAuthenticateChallenge = struct {
    scheme: []const u8 = "Bearer",
    realm: ?[]const u8 = null,
    resource_metadata: ?[]const u8 = null,
    scope: ?[]const u8 = null,
    error_code: ?[]const u8 = null,
    error_description: ?[]const u8 = null,
};

/// Parses a `WWW-Authenticate` header value.
///
/// Example inputs:
///   `Bearer realm="mcp", resource_metadata="https://api.example.com/.well-known/oauth-protected-resource"`
///   `Bearer error="invalid_token", error_description="The token has expired"`
pub fn parseWwwAuthenticate(header: []const u8) WwwAuthenticateChallenge {
    var result: WwwAuthenticateChallenge = .{};
    var trimmed = std.mem.trim(u8, header, " \t\r\n");

    // Extract auth scheme (e.g. "Bearer")
    if (std.mem.indexOfScalar(u8, trimmed, ' ')) |space_idx| {
        result.scheme = trimmed[0..space_idx];
        trimmed = std.mem.trim(u8, trimmed[space_idx + 1 ..], " \t");
    } else {
        result.scheme = trimmed;
        return result;
    }

    // Parse comma-separated key=value or key="quoted-string" pairs
    var idx: usize = 0;
    while (idx < trimmed.len) {
        // Skip leading whitespace and commas
        while (idx < trimmed.len and (trimmed[idx] == ' ' or trimmed[idx] == ',' or trimmed[idx] == '\t')) : (idx += 1) {}
        if (idx >= trimmed.len) break;

        // Find '='
        const key_start = idx;
        while (idx < trimmed.len and trimmed[idx] != '=' and trimmed[idx] != ',' and trimmed[idx] != ' ') : (idx += 1) {}
        const key = trimmed[key_start..idx];

        while (idx < trimmed.len and trimmed[idx] == ' ') : (idx += 1) {}
        if (idx >= trimmed.len or trimmed[idx] != '=') continue;
        idx += 1; // Skip '='

        while (idx < trimmed.len and trimmed[idx] == ' ') : (idx += 1) {}
        if (idx >= trimmed.len) break;

        var val: []const u8 = "";
        if (trimmed[idx] == '"') {
            idx += 1; // Skip open quote
            const val_start = idx;
            while (idx < trimmed.len and trimmed[idx] != '"') : (idx += 1) {}
            val = trimmed[val_start..idx];
            if (idx < trimmed.len and trimmed[idx] == '"') idx += 1; // Skip close quote
        } else {
            const val_start = idx;
            while (idx < trimmed.len and trimmed[idx] != ',' and trimmed[idx] != ' ') : (idx += 1) {}
            val = trimmed[val_start..idx];
        }

        if (std.ascii.eqlIgnoreCase(key, "realm")) {
            result.realm = val;
        } else if (std.ascii.eqlIgnoreCase(key, "resource_metadata")) {
            result.resource_metadata = val;
        } else if (std.ascii.eqlIgnoreCase(key, "scope")) {
            result.scope = val;
        } else if (std.ascii.eqlIgnoreCase(key, "error")) {
            result.error_code = val;
        } else if (std.ascii.eqlIgnoreCase(key, "error_description")) {
            result.error_description = val;
        }
    }

    return result;
}

/// OAuth 2.0 Protected Resource Metadata document (RFC 9728).
pub const ProtectedResourceMetadata = struct {
    resource: ?[]const u8 = null,
    authorization_servers: []const []const u8 = &.{},
    scopes_supported: ?[]const []const u8 = null,
    bearer_methods_supported: ?[]const []const u8 = null,
    resource_documentation: ?[]const u8 = null,

    /// Releases memory allocated for slice fields.
    pub fn deinit(self: *ProtectedResourceMetadata, allocator: std.mem.Allocator) void {
        if (self.resource) |r| allocator.free(r);
        for (self.authorization_servers) |as_uri| allocator.free(as_uri);
        allocator.free(self.authorization_servers);
        if (self.scopes_supported) |scopes| {
            for (scopes) |s| allocator.free(s);
            allocator.free(scopes);
        }
        if (self.bearer_methods_supported) |methods| {
            for (methods) |m| allocator.free(m);
            allocator.free(methods);
        }
        if (self.resource_documentation) |doc| allocator.free(doc);
    }
};

/// Parses a JSON document into `ProtectedResourceMetadata`.
pub fn parseProtectedResourceMetadata(allocator: std.mem.Allocator, json_bytes: []const u8) !ProtectedResourceMetadata {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_bytes, .{});
    defer parsed.deinit();

    if (parsed.value != .object) return error.InvalidJson;
    const root = parsed.value.object;

    var result: ProtectedResourceMetadata = .{};
    errdefer result.deinit(allocator);

    if (root.get("resource")) |res| {
        if (res == .string) result.resource = try allocator.dupe(u8, res.string);
    }

    if (root.get("authorization_servers")) |auth_servers| {
        if (auth_servers == .array) {
            var list: std.ArrayList([]const u8) = .empty;
            for (auth_servers.array.items) |item| {
                if (item == .string) {
                    try list.append(allocator, try allocator.dupe(u8, item.string));
                }
            }
            result.authorization_servers = try list.toOwnedSlice(allocator);
        }
    }

    if (root.get("scopes_supported")) |scopes| {
        if (scopes == .array) {
            var list: std.ArrayList([]const u8) = .empty;
            for (scopes.array.items) |item| {
                if (item == .string) {
                    try list.append(allocator, try allocator.dupe(u8, item.string));
                }
            }
            result.scopes_supported = try list.toOwnedSlice(allocator);
        }
    }

    if (root.get("bearer_methods_supported")) |methods| {
        if (methods == .array) {
            var list: std.ArrayList([]const u8) = .empty;
            for (methods.array.items) |item| {
                if (item == .string) {
                    try list.append(allocator, try allocator.dupe(u8, item.string));
                }
            }
            result.bearer_methods_supported = try list.toOwnedSlice(allocator);
        }
    }

    if (root.get("resource_documentation")) |doc| {
        if (doc == .string) result.resource_documentation = try allocator.dupe(u8, doc.string);
    }

    return result;
}

/// OAuth 2.0 Authorization Server Metadata document (RFC 8414).
pub const AuthorizationServerMetadata = struct {
    issuer: []const u8,
    token_endpoint: ?[]const u8 = null,
    authorization_endpoint: ?[]const u8 = null,
    jwks_uri: ?[]const u8 = null,
    grant_types_supported: ?[]const []const u8 = null,

    /// Releases memory allocated for slice fields.
    pub fn deinit(self: *AuthorizationServerMetadata, allocator: std.mem.Allocator) void {
        allocator.free(self.issuer);
        if (self.token_endpoint) |te| allocator.free(te);
        if (self.authorization_endpoint) |ae| allocator.free(ae);
        if (self.jwks_uri) |j| allocator.free(j);
        if (self.grant_types_supported) |grants| {
            for (grants) |g| allocator.free(g);
            allocator.free(grants);
        }
    }
};

/// Parses a JSON document into `AuthorizationServerMetadata`.
pub fn parseAuthorizationServerMetadata(allocator: std.mem.Allocator, json_bytes: []const u8) !AuthorizationServerMetadata {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_bytes, .{});
    defer parsed.deinit();

    if (parsed.value != .object) return error.InvalidJson;
    const root = parsed.value.object;

    const issuer_val = root.get("issuer") orelse return error.MissingIssuer;
    if (issuer_val != .string) return error.InvalidIssuer;

    var result: AuthorizationServerMetadata = .{
        .issuer = try allocator.dupe(u8, issuer_val.string),
    };
    errdefer result.deinit(allocator);

    if (root.get("token_endpoint")) |te| {
        if (te == .string) result.token_endpoint = try allocator.dupe(u8, te.string);
    }

    if (root.get("authorization_endpoint")) |ae| {
        if (ae == .string) result.authorization_endpoint = try allocator.dupe(u8, ae.string);
    }

    if (root.get("jwks_uri")) |jwks| {
        if (jwks == .string) result.jwks_uri = try allocator.dupe(u8, jwks.string);
    }

    if (root.get("grant_types_supported")) |grants| {
        if (grants == .array) {
            var list: std.ArrayList([]const u8) = .empty;
            for (grants.array.items) |item| {
                if (item == .string) {
                    try list.append(allocator, try allocator.dupe(u8, item.string));
                }
            }
            result.grant_types_supported = try list.toOwnedSlice(allocator);
        }
    }

    return result;
}

/// Token response from an OAuth 2.0 token endpoint (RFC 6749 section 5.1).
pub const ClientCredentialsTokenResponse = struct {
    access_token: []const u8,
    token_type: []const u8,
    expires_in: ?u64 = null,
    scope: ?[]const u8 = null,

    pub fn deinit(self: *ClientCredentialsTokenResponse, allocator: std.mem.Allocator) void {
        allocator.free(self.access_token);
        allocator.free(self.token_type);
        if (self.scope) |s| allocator.free(s);
    }
};

/// Fetches an OAuth 2.0 access token using the Client Credentials Grant (RFC 6749 section 4.4).
pub fn requestClientCredentialsToken(
    allocator: std.mem.Allocator,
    io: std.Io,
    token_endpoint: []const u8,
    client_id: []const u8,
    client_secret: []const u8,
    scope: ?[]const u8,
) !ClientCredentialsTokenResponse {
    var http_client = httpx.Client.init(allocator, io, .{});
    defer http_client.deinit();

    // Build form-urlencoded request body
    var body_buf: std.ArrayList(u8) = .empty;
    defer body_buf.deinit(allocator);

    try body_buf.appendSlice(allocator, "grant_type=client_credentials&client_id=");
    try body_buf.appendSlice(allocator, client_id);
    try body_buf.appendSlice(allocator, "&client_secret=");
    try body_buf.appendSlice(allocator, client_secret);

    if (scope) |s| {
        try body_buf.appendSlice(allocator, "&scope=");
        try body_buf.appendSlice(allocator, s);
    }

    var headers: [2]httpx.Header = .{
        .{ .name = "Content-Type", .value = "application/x-www-form-urlencoded" },
        .{ .name = "Accept", .value = "application/json" },
    };

    var response = try http_client.post(token_endpoint, .{
        .body = body_buf.items,
        .headers = &headers,
    });
    defer response.deinit();

    if (response.status < 200 or response.status >= 300) {
        return error.TokenRequestFailed;
    }

    const body_text = response.text();
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, body_text, .{});
    defer parsed.deinit();

    if (parsed.value != .object) return error.InvalidJson;
    const root = parsed.value.object;

    const access_token_val = root.get("access_token") orelse return error.MissingAccessToken;
    if (access_token_val != .string) return error.InvalidAccessToken;

    const token_type_val = root.get("token_type") orelse return error.MissingTokenType;
    if (token_type_val != .string) return error.InvalidTokenType;

    var expires_in: ?u64 = null;
    if (root.get("expires_in")) |exp| {
        if (exp == .integer and exp.integer >= 0) {
            expires_in = @intCast(exp.integer);
        }
    }

    var scope_val: ?[]const u8 = null;
    if (root.get("scope")) |sc| {
        if (sc == .string) scope_val = try allocator.dupe(u8, sc.string);
    }

    return .{
        .access_token = try allocator.dupe(u8, access_token_val.string),
        .token_type = try allocator.dupe(u8, token_type_val.string),
        .expires_in = expires_in,
        .scope = scope_val,
    };
}

/// Fetches OAuth Protected Resource Metadata from a metadata URL (RFC 9728).
pub fn fetchProtectedResourceMetadata(
    allocator: std.mem.Allocator,
    io: std.Io,
    metadata_url: []const u8,
) !ProtectedResourceMetadata {
    var http_client = httpx.Client.init(allocator, io, .{});
    defer http_client.deinit();

    var headers: [1]httpx.Header = .{
        .{ .name = "Accept", .value = "application/json" },
    };

    var response = try http_client.get(metadata_url, .{
        .headers = &headers,
    });
    defer response.deinit();

    if (response.status != 200) {
        return error.MetadataFetchFailed;
    }

    return parseProtectedResourceMetadata(allocator, response.text());
}

test "parseWwwAuthenticate with realm and resource_metadata" {
    const header = "Bearer realm=\"mcp\", resource_metadata=\"https://api.example.com/.well-known/oauth-protected-resource\"";
    const parsed = parseWwwAuthenticate(header);

    try std.testing.expectEqualStrings("Bearer", parsed.scheme);
    try std.testing.expectEqualStrings("mcp", parsed.realm.?);
    try std.testing.expectEqualStrings("https://api.example.com/.well-known/oauth-protected-resource", parsed.resource_metadata.?);
    try std.testing.expect(parsed.error_code == null);
}

test "parseWwwAuthenticate with error and description" {
    const header = "Bearer error=\"invalid_token\", error_description=\"The token expired\"";
    const parsed = parseWwwAuthenticate(header);

    try std.testing.expectEqualStrings("Bearer", parsed.scheme);
    try std.testing.expectEqualStrings("invalid_token", parsed.error_code.?);
    try std.testing.expectEqualStrings("The token expired", parsed.error_description.?);
}

test "parseProtectedResourceMetadata" {
    const json =
        \\{
        \\  "resource": "https://api.example.com/mcp",
        \\  "authorization_servers": ["https://auth.example.com"],
        \\  "scopes_supported": ["mcp:tools", "mcp:resources"],
        \\  "bearer_methods_supported": ["header"]
        \\}
    ;

    var meta = try parseProtectedResourceMetadata(std.testing.allocator, json);
    defer meta.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("https://api.example.com/mcp", meta.resource.?);
    try std.testing.expectEqual(@as(usize, 1), meta.authorization_servers.len);
    try std.testing.expectEqualStrings("https://auth.example.com", meta.authorization_servers[0]);
    try std.testing.expectEqual(@as(usize, 2), meta.scopes_supported.?.len);
    try std.testing.expectEqualStrings("mcp:tools", meta.scopes_supported.?[0]);
}

test "parseAuthorizationServerMetadata" {
    const json =
        \\{
        \\  "issuer": "https://auth.example.com",
        \\  "token_endpoint": "https://auth.example.com/token",
        \\  "jwks_uri": "https://auth.example.com/jwks.json"
        \\}
    ;

    var meta = try parseAuthorizationServerMetadata(std.testing.allocator, json);
    defer meta.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("https://auth.example.com", meta.issuer);
    try std.testing.expectEqualStrings("https://auth.example.com/token", meta.token_endpoint.?);
}
