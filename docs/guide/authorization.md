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
    GET /mcp HTTP/1.1
    Authorization: Bearer <token>
    ```

The MCP server validates the token and processes the request.
