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

/// OAuth 2.0 Authorization Server Metadata document (RFC 8414 & OpenID Connect Discovery 1.0).
pub const AuthorizationServerMetadata = struct {
    issuer: []const u8,
    token_endpoint: ?[]const u8 = null,
    authorization_endpoint: ?[]const u8 = null,
    jwks_uri: ?[]const u8 = null,
    registration_endpoint: ?[]const u8 = null,
    scopes_supported: ?[]const []const u8 = null,
    response_types_supported: ?[]const []const u8 = null,
    grant_types_supported: ?[]const []const u8 = null,
    code_challenge_methods_supported: ?[]const []const u8 = null,
    client_id_metadata_document_supported: bool = false,

    /// Releases memory allocated for slice fields.
    pub fn deinit(self: *AuthorizationServerMetadata, allocator: std.mem.Allocator) void {
        allocator.free(self.issuer);
        if (self.token_endpoint) |te| allocator.free(te);
        if (self.authorization_endpoint) |ae| allocator.free(ae);
        if (self.jwks_uri) |j| allocator.free(j);
        if (self.registration_endpoint) |re| allocator.free(re);
        if (self.scopes_supported) |scopes| {
            for (scopes) |s| allocator.free(s);
            allocator.free(scopes);
        }
        if (self.response_types_supported) |responses| {
            for (responses) |r| allocator.free(r);
            allocator.free(responses);
        }
        if (self.grant_types_supported) |grants| {
            for (grants) |g| allocator.free(g);
            allocator.free(grants);
        }
        if (self.code_challenge_methods_supported) |methods| {
            for (methods) |m| allocator.free(m);
            allocator.free(methods);
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

    if (root.get("registration_endpoint")) |re| {
        if (re == .string) result.registration_endpoint = try allocator.dupe(u8, re.string);
    }

    if (root.get("client_id_metadata_document_supported")) |cimd| {
        if (cimd == .bool) result.client_id_metadata_document_supported = cimd.bool;
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

    if (root.get("response_types_supported")) |responses| {
        if (responses == .array) {
            var list: std.ArrayList([]const u8) = .empty;
            for (responses.array.items) |item| {
                if (item == .string) {
                    try list.append(allocator, try allocator.dupe(u8, item.string));
                }
            }
            result.response_types_supported = try list.toOwnedSlice(allocator);
        }
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

    if (root.get("code_challenge_methods_supported")) |methods| {
        if (methods == .array) {
            var list: std.ArrayList([]const u8) = .empty;
            for (methods.array.items) |item| {
                if (item == .string) {
                    try list.append(allocator, try allocator.dupe(u8, item.string));
                }
            }
            result.code_challenge_methods_supported = try list.toOwnedSlice(allocator);
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
    return requestClientCredentialsTokenWithResource(allocator, io, token_endpoint, client_id, client_secret, scope, null);
}

/// Fetches an OAuth 2.0 access token using the Client Credentials Grant with optional RFC 8707 Resource Indicator.
pub fn requestClientCredentialsTokenWithResource(
    allocator: std.mem.Allocator,
    io: std.Io,
    token_endpoint: []const u8,
    client_id: []const u8,
    client_secret: []const u8,
    scope: ?[]const u8,
    resource: ?[]const u8,
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

    if (resource) |r| {
        try body_buf.appendSlice(allocator, "&resource=");
        try body_buf.appendSlice(allocator, r);
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

/// Decomposed URL components.
pub const DecomposedUrl = struct {
    scheme: []const u8,
    host: []const u8,
    path: []const u8,
};

/// Decomposes a URL into scheme, host, and path components.
pub fn decomposeUrl(url: []const u8) ?DecomposedUrl {
    const scheme_end = std.mem.indexOf(u8, url, "://") orelse return null;
    const scheme = url[0..scheme_end];
    const after_scheme = url[scheme_end + 3 ..];
    const path_start = std.mem.indexOfScalar(u8, after_scheme, '/');
    if (path_start) |idx| {
        const host = after_scheme[0..idx];
        var path = after_scheme[idx..];
        if (path.len > 1 and path[path.len - 1] == '/') {
            path = path[0 .. path.len - 1];
        }
        return .{
            .scheme = scheme,
            .host = host,
            .path = path,
        };
    } else {
        return .{
            .scheme = scheme,
            .host = after_scheme,
            .path = "",
        };
    }
}

/// Discovers Protected Resource Metadata (RFC 9728) using WWW-Authenticate challenge or fallback well-known URIs.
pub fn discoverProtectedResourceMetadata(
    allocator: std.mem.Allocator,
    io: std.Io,
    mcp_endpoint_url: []const u8,
    www_authenticate_header: ?[]const u8,
) !ProtectedResourceMetadata {
    if (www_authenticate_header) |hdr| {
        const challenge = parseWwwAuthenticate(hdr);
        if (challenge.resource_metadata) |meta_url| {
            if (fetchProtectedResourceMetadata(allocator, io, meta_url)) |meta| {
                return meta;
            } else |_| {}
        }
    }

    const decomp = decomposeUrl(mcp_endpoint_url) orelse return error.InvalidUrl;

    if (decomp.path.len > 1 and !std.mem.eql(u8, decomp.path, "/")) {
        const subpath_url = try std.fmt.allocPrint(
            allocator,
            "{s}://{s}/.well-known/oauth-protected-resource{s}",
            .{ decomp.scheme, decomp.host, decomp.path },
        );
        defer allocator.free(subpath_url);

        if (fetchProtectedResourceMetadata(allocator, io, subpath_url)) |meta| {
            return meta;
        } else |_| {}
    }

    const root_url = try std.fmt.allocPrint(
        allocator,
        "{s}://{s}/.well-known/oauth-protected-resource",
        .{ decomp.scheme, decomp.host },
    );
    defer allocator.free(root_url);

    return fetchProtectedResourceMetadata(allocator, io, root_url);
}

/// Discovers and validates OAuth 2.0 / OpenID Connect Authorization Server Metadata (RFC 8414 & OIDC Discovery).
pub fn discoverAuthorizationServerMetadata(
    allocator: std.mem.Allocator,
    io: std.Io,
    issuer_url: []const u8,
) !AuthorizationServerMetadata {
    const decomp = decomposeUrl(issuer_url) orelse return error.InvalidIssuerUrl;

    var http_client = httpx.Client.init(allocator, io, .{});
    defer http_client.deinit();

    var headers: [1]httpx.Header = .{
        .{ .name = "Accept", .value = "application/json" },
    };

    var candidate_urls: std.ArrayList([]const u8) = .empty;
    defer {
        for (candidate_urls.items) |u| allocator.free(u);
        candidate_urls.deinit(allocator);
    }

    if (decomp.path.len > 1 and !std.mem.eql(u8, decomp.path, "/")) {
        try candidate_urls.append(allocator, try std.fmt.allocPrint(allocator, "{s}://{s}/.well-known/oauth-authorization-server{s}", .{ decomp.scheme, decomp.host, decomp.path }));
        try candidate_urls.append(allocator, try std.fmt.allocPrint(allocator, "{s}://{s}/.well-known/openid-configuration{s}", .{ decomp.scheme, decomp.host, decomp.path }));
        try candidate_urls.append(allocator, try std.fmt.allocPrint(allocator, "{s}://{s}{s}/.well-known/openid-configuration", .{ decomp.scheme, decomp.host, decomp.path }));
    } else {
        try candidate_urls.append(allocator, try std.fmt.allocPrint(allocator, "{s}://{s}/.well-known/oauth-authorization-server", .{ decomp.scheme, decomp.host }));
        try candidate_urls.append(allocator, try std.fmt.allocPrint(allocator, "{s}://{s}/.well-known/openid-configuration", .{ decomp.scheme, decomp.host }));
    }

    for (candidate_urls.items) |candidate_url| {
        var response = http_client.get(candidate_url, .{
            .headers = &headers,
        }) catch continue;
        defer response.deinit();

        if (response.status == 200) {
            var meta = parseAuthorizationServerMetadata(allocator, response.text()) catch continue;
            const trimmed_meta = std.mem.trimRight(u8, meta.issuer, "/");
            const trimmed_expected = std.mem.trimRight(u8, issuer_url, "/");
            if (!std.mem.eql(u8, trimmed_meta, trimmed_expected)) {
                meta.deinit(allocator);
                return error.IssuerMismatch;
            }
            return meta;
        }
    }

    return error.AuthorizationServerDiscoveryFailed;
}

/// OAuth Client ID Metadata Document (draft-ietf-oauth-client-id-metadata-document).
pub const ClientIdMetadataDocument = struct {
    client_id: []const u8,
    client_name: []const u8,
    client_uri: ?[]const u8 = null,
    logo_uri: ?[]const u8 = null,
    redirect_uris: []const []const u8 = &.{},
    grant_types: ?[]const []const u8 = null,
    response_types: ?[]const []const u8 = null,
    token_endpoint_auth_method: []const u8 = "none",

    pub fn deinit(self: *ClientIdMetadataDocument, allocator: std.mem.Allocator) void {
        allocator.free(self.client_id);
        allocator.free(self.client_name);
        if (self.client_uri) |u| allocator.free(u);
        if (self.logo_uri) |l| allocator.free(l);
        for (self.redirect_uris) |ru| allocator.free(ru);
        allocator.free(self.redirect_uris);
        if (self.grant_types) |grants| {
            for (grants) |g| allocator.free(g);
            allocator.free(grants);
        }
        if (self.response_types) |responses| {
            for (responses) |r| allocator.free(r);
            allocator.free(responses);
        }
    }

    pub fn validate(self: ClientIdMetadataDocument) bool {
        if (!std.mem.startsWith(u8, self.client_id, "https://")) return false;
        const after_scheme = self.client_id[8..];
        const slash_idx = std.mem.indexOfScalar(u8, after_scheme, '/') orelse return false;
        if (slash_idx >= after_scheme.len - 1) return false;
        if (self.client_name.len == 0) return false;
        if (self.redirect_uris.len == 0) return false;
        return true;
    }
};

/// Parses a JSON document into `ClientIdMetadataDocument`.
pub fn parseClientIdMetadataDocument(allocator: std.mem.Allocator, json_bytes: []const u8) !ClientIdMetadataDocument {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_bytes, .{});
    defer parsed.deinit();

    if (parsed.value != .object) return error.InvalidJson;
    const root = parsed.value.object;

    const id_val = root.get("client_id") orelse return error.MissingClientId;
    if (id_val != .string) return error.InvalidClientId;

    const name_val = root.get("client_name") orelse return error.MissingClientName;
    if (name_val != .string) return error.InvalidClientName;

    var result: ClientIdMetadataDocument = .{
        .client_id = try allocator.dupe(u8, id_val.string),
        .client_name = try allocator.dupe(u8, name_val.string),
    };
    errdefer result.deinit(allocator);

    if (root.get("client_uri")) |cu| {
        if (cu == .string) result.client_uri = try allocator.dupe(u8, cu.string);
    }
    if (root.get("logo_uri")) |lu| {
        if (lu == .string) result.logo_uri = try allocator.dupe(u8, lu.string);
    }
    if (root.get("token_endpoint_auth_method")) |am| {
        if (am == .string) result.token_endpoint_auth_method = am.string;
    }

    if (root.get("redirect_uris")) |ru| {
        if (ru == .array) {
            var list: std.ArrayList([]const u8) = .empty;
            for (ru.array.items) |item| {
                if (item == .string) {
                    try list.append(allocator, try allocator.dupe(u8, item.string));
                }
            }
            result.redirect_uris = try list.toOwnedSlice(allocator);
        }
    }

    if (root.get("grant_types")) |gt| {
        if (gt == .array) {
            var list: std.ArrayList([]const u8) = .empty;
            for (gt.array.items) |item| {
                if (item == .string) {
                    try list.append(allocator, try allocator.dupe(u8, item.string));
                }
            }
            result.grant_types = try list.toOwnedSlice(allocator);
        }
    }

    if (root.get("response_types")) |rt| {
        if (rt == .array) {
            var list: std.ArrayList([]const u8) = .empty;
            for (rt.array.items) |item| {
                if (item == .string) {
                    try list.append(allocator, try allocator.dupe(u8, item.string));
                }
            }
            result.response_types = try list.toOwnedSlice(allocator);
        }
    }

    if (!result.validate()) return error.InvalidClientIdMetadata;
    return result;
}

/// PKCE Code Verifier & Challenge Pair (RFC 7636 / OAuth 2.1).
pub const PkcePair = struct {
    verifier: [43]u8,
    challenge: [43]u8,
    method: []const u8 = "S256",
};

/// Generates a PKCE code verifier and S256 challenge pair using cryptographically secure random bytes.
pub fn generatePkce(random: std.Random) PkcePair {
    var raw_bytes: [32]u8 = undefined;
    random.bytes(&raw_bytes);

    var verifier: [43]u8 = undefined;
    _ = std.base64.url_safe_no_pad.Encoder.encode(&verifier, &raw_bytes);

    var sha_digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(&verifier, &sha_digest, .{});

    var challenge: [43]u8 = undefined;
    _ = std.base64.url_safe_no_pad.Encoder.encode(&challenge, &sha_digest);

    return .{
        .verifier = verifier,
        .challenge = challenge,
        .method = "S256",
    };
}

/// Verifies a PKCE S256 code challenge against the provided code verifier.
pub fn verifyPkce(verifier: []const u8, expected_challenge: []const u8) bool {
    var sha_digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(verifier, &sha_digest, .{});

    var computed_challenge: [43]u8 = undefined;
    _ = std.base64.url_safe_no_pad.Encoder.encode(&computed_challenge, &sha_digest);

    return std.mem.eql(u8, &computed_challenge, expected_challenge);
}

/// Validates that a token audience claim matches the MCP server's resource URI (RFC 8707 / RFC 9728).
pub fn validateTokenAudience(token_audience: []const u8, expected_resource_uri: []const u8) bool {
    const trimmed_aud = std.mem.trim(u8, token_audience, "/");
    const trimmed_exp = std.mem.trim(u8, expected_resource_uri, "/");
    return std.mem.eql(u8, trimmed_aud, trimmed_exp);
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

test "decomposeUrl with and without path" {
    const url1 = decomposeUrl("https://auth.example.com/tenant1").?;
    try std.testing.expectEqualStrings("https", url1.scheme);
    try std.testing.expectEqualStrings("auth.example.com", url1.host);
    try std.testing.expectEqualStrings("/tenant1", url1.path);

    const url2 = decomposeUrl("https://auth.example.com").?;
    try std.testing.expectEqualStrings("https", url2.scheme);
    try std.testing.expectEqualStrings("auth.example.com", url2.host);
    try std.testing.expectEqualStrings("", url2.path);

    const url3 = decomposeUrl("http://localhost:8080/mcp/").?;
    try std.testing.expectEqualStrings("http", url3.scheme);
    try std.testing.expectEqualStrings("localhost:8080", url3.host);
    try std.testing.expectEqualStrings("/mcp", url3.path);
}

test "parseClientIdMetadataDocument and validation" {
    const json =
        \\{
        \\  "client_id": "https://app.example.com/oauth/client-metadata.json",
        \\  "client_name": "Example MCP Client",
        \\  "redirect_uris": ["http://127.0.0.1:3000/callback"],
        \\  "grant_types": ["authorization_code"],
        \\  "token_endpoint_auth_method": "none"
        \\}
    ;

    var cimd = try parseClientIdMetadataDocument(std.testing.allocator, json);
    defer cimd.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("https://app.example.com/oauth/client-metadata.json", cimd.client_id);
    try std.testing.expectEqualStrings("Example MCP Client", cimd.client_name);
    try std.testing.expectEqual(@as(usize, 1), cimd.redirect_uris.len);
    try std.testing.expectEqualStrings("http://127.0.0.1:3000/callback", cimd.redirect_uris[0]);
    try std.testing.expect(cimd.validate());
}

test "generatePkce and verifyPkce" {
    var prng = std.Random.DefaultPrng.init(12345);
    const pkce = generatePkce(prng.random());

    try std.testing.expectEqual(@as(usize, 43), pkce.verifier.len);
    try std.testing.expectEqual(@as(usize, 43), pkce.challenge.len);
    try std.testing.expectEqualStrings("S256", pkce.method);

    try std.testing.expect(verifyPkce(&pkce.verifier, &pkce.challenge));
    try std.testing.expect(!verifyPkce("invalid_verifier_0123456789012345678901234567", &pkce.challenge));
}

test "validateTokenAudience" {
    try std.testing.expect(validateTokenAudience("https://api.example.com/mcp", "https://api.example.com/mcp"));
    try std.testing.expect(validateTokenAudience("https://api.example.com/mcp/", "https://api.example.com/mcp"));
    try std.testing.expect(!validateTokenAudience("https://attacker.example.com/mcp", "https://api.example.com/mcp"));
}
