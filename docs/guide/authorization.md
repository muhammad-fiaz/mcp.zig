---
title: "Authorization"
description: "MCP authorization with OAuth 2.1, Bearer tokens, and secure transport authentication."
keywords: [authorization, OAuth 2.1, Bearer tokens, security, authentication, protected resources]
---

# Understanding Authorization in MCP

Authorization in the Model Context Protocol (MCP) secures access to sensitive resources and operations exposed by MCP servers. If your MCP server handles user data or administrative actions, authorization ensures only permitted users can access its endpoints.

MCP uses standardized authorization flows to build trust between MCP clients and MCP servers. Its design follows the conventions outlined for OAuth 2.1.

## When Should You Use Authorization?

While authorization for MCP servers is optional, it is strongly recommended when:

- Your server accesses user-specific data (emails, documents, databases).
- You need to audit who performed which actions.
- Your server grants access to its APIs that require user consent.
- You’re building for enterprise environments with strict access controls.
- You want to implement rate limiting or usage tracking per user.

## Authorization for Local MCP Servers

For MCP servers using the **STDIO transport**, you can use environment-based credentials or credentials provided by third-party libraries embedded directly in the MCP server.

**OAuth flows** are designed for **HTTP-based transports** where the MCP server is remotely-hosted and the client uses OAuth to establish that a user is authorized to access said remote server.

## The Authorization Flow: Step by Step

1.  **Initial Handshake**: When your MCP client first connects, the server responds with a `401 Unauthorized` and tells the client where to find authorization information (Protected Resource Metadata).

    ```http
    HTTP/1.1 401 Unauthorized
    WWW-Authenticate: Bearer realm="mcp", resource_metadata="https://your-server.com/.well-known/oauth-protected-resource"
    ```

2.  **Protected Resource Metadata Discovery**: The client fetches metadata to learn about the authorization server and supported scopes.

    ```json
    {
      "resource": "https://your-server.com/mcp",
      "authorization_servers": ["https://auth.your-server.com"],
      "scopes_supported": ["mcp:tools", "mcp:resources"]
    }
    ```

3.  **Authorization Server Discovery**: The client discovers the authorization server capabilities (endpoints for authorization, token, etc.).

4.  **Client Registration**: The client registers with the authorization server (via Dynamic Client Registration or pre-registration).

5.  **User Authorization**: The client opens a browser to the authorization endpoint. The user logs in and grants permissions. The client receives an authorization code and exchanges it for an access token.

6.  **Making Authenticated Requests**: The client makes requests to the MCP server with the `Authorization` header.
    ```http
    POST /mcp HTTP/1.1
    Authorization: Bearer <token>
    Content-Type: application/json
    ```

The MCP server validates the token and processes the request.

## Using Authorization in mcp.zig

`mcp.zig` provides built-in protocol and client helpers to implement secure authorization flows.

### Client: Setting a Bearer Token

For pre-provisioned or environment-based tokens, set the bearer token directly on the client:

```zig
const std = @import("std");
const mcp = @import("mcp");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var client = mcp.Client.init(allocator, .{});
    defer client.deinit();

    // Attach static Bearer token
    client.setAuthorizationToken("mcp_token_secret_12345");

    try client.connectHttp("https://api.example.com/mcp", .{});
    // All subsequent HTTP requests carry: Authorization: Bearer mcp_token_secret_12345
}
```

### Client: Machine-to-Machine OAuth Client Credentials (RFC 6749)

For service accounts, background workers, and automation, acquire an access token automatically from the OAuth token endpoint:

```zig
const std = @import("std");
const mcp = @import("mcp");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var client = mcp.Client.init(allocator, .{});
    defer client.deinit();

    // Authenticate via OAuth 2.0 client credentials grant
    try client.authenticateWithClientCredentials(
        "https://auth.example.com/oauth/token",
        "mcp-client-id",
        "mcp-client-secret",
        "mcp:tools mcp:resources",
    );

    try client.connectHttp("https://api.example.com/mcp", .{});
}
```

### Parsing `WWW-Authenticate` Challenges

When an HTTP endpoint returns `401 Unauthorized`, parse the challenge to discover resource metadata or error reasons:

```zig
const mcp = @import("mcp");

const header = "Bearer realm=\"mcp\", resource_metadata=\"https://api.example.com/.well-known/oauth-protected-resource\"";
const challenge = mcp.auth.parseWwwAuthenticate(header);

if (std.mem.eql(u8, challenge.scheme, "Bearer")) {
    if (challenge.resource_metadata) |meta_url| {
        // Discovered Protected Resource Metadata URL
    }
}
```

### Protected Resource Metadata Discovery (RFC 9728)

Fetch authorization server information using the complete fallback probing order (WWW-Authenticate challenge -> sub-path well-known URI -> root well-known URI):

```zig
// Discovers metadata via 401 challenge header or automatic fallback probing
var meta = try client.discoverProtectedResourceEndpoint(
    "https://api.example.com/public/mcp",
    www_authenticate_header, // null or header from initial 401 response
);
defer meta.deinit(allocator);

for (meta.authorization_servers) |as_url| {
    std.debug.print("Discovered Authorization Server: {s}\n", .{as_url});
}
```

### Authorization Server Metadata Discovery (RFC 8414 & OpenID Connect)

Discover and validate authorization server capabilities. The client probes OAuth 2.0 and OIDC discovery endpoints in priority order and validates that the metadata's `issuer` strictly matches the target issuer (mitigating mix-up attacks):

```zig
var as_meta = try client.discoverAuthorizationServer("https://auth.example.com/tenant1");
defer as_meta.deinit(allocator);

std.debug.print("Token endpoint: {?s}\n", .{as_meta.token_endpoint});
std.debug.print("Supports CIMD: {}\n", .{as_meta.client_id_metadata_document_supported});
```

### Client ID Metadata Documents (CIMD)

For clients with no pre-existing relationship with the authorization server, MCP uses Client ID Metadata Documents (CIMD). The `client_id` is an HTTPS URL resolving to a client metadata document:

```zig
const cimd_json =
    \\{
    \\  "client_id": "https://app.example.com/oauth/client-metadata.json",
    \\  "client_name": "Example MCP Client",
    \\  "redirect_uris": ["http://127.0.0.1:3000/callback"],
    \\  "grant_types": ["authorization_code"],
    \\  "token_endpoint_auth_method": "none"
    \\}
;

var doc = try mcp.auth.parseClientIdMetadataDocument(allocator, cimd_json);
defer doc.deinit(allocator);

if (doc.validate()) {
    std.debug.print("Client ID URL: {s}\n", .{doc.client_id});
}
```

### PKCE (RFC 7636 / OAuth 2.1)

MCP clients use Proof Key for Code Exchange (PKCE) with the `S256` challenge method to protect authorization codes from interception:

```zig
var prng = std.Random.DefaultPrng.init(seed);
const pkce = mcp.auth.generatePkce(prng.random());

// Attach code_challenge to authorization URL:
// &code_challenge={pkce.challenge}&code_challenge_method=S256

// Verify code_verifier upon exchanging authorization code:
if (mcp.auth.verifyPkce(&pkce.verifier, &pkce.challenge)) {
    // Valid verifier matching challenge
}
```

### Token Audience Validation & Resource Indicators (RFC 8707)

MCP servers validate that incoming tokens were specifically issued for them:

```zig
// Server validation:
const is_valid = mcp.auth.validateTokenAudience(
    token_aud_claim,
    "https://api.example.com/mcp",
);
if (!is_valid) return error.Unauthorized;

// Client request with RFC 8707 Resource Indicator:
try client.authenticateWithClientCredentialsResource(
    "https://auth.example.com/token",
    client_id,
    client_secret,
    "mcp:tools",
    "https://api.example.com/mcp", // Resource Indicator
);
```

## Authorization Extensions

In addition to core interactive OAuth 2.1 authorization, MCP defines supplementary authorization extensions:

- **OAuth Client Credentials** (`io.modelcontextprotocol/oauth-client-credentials`): Used for machine-to-machine integrations, background services, and CI/CD pipelines without user interaction. Built into `mcp.Client.authenticateWithClientCredentials` and `mcp.Client.authenticateWithClientCredentialsResource`.
- **Enterprise-Managed Authorization** (`io.modelcontextprotocol/enterprise-managed-authorization`): Enables organizations to enforce centralized access control and SSO policies via enterprise identity providers (IdPs like Okta or Azure AD) using Identity Assertion JWTs (ID-JAG).

Learn more in the [Extensions & MCP Apps Guide](/guide/extensions).



