---
title: "Protocol Version"
description: "MCP protocol version support including 2026-07-28, 2025-11-25, and earlier versions with stateless per-request model."
keywords: [MCP protocol version, 2026-07-28, 2025-11-25, stateless protocol, backward compatibility]
---

# Supported Protocol Version

::: info Official Documentation
This library implements **Model Context Protocol (MCP) version 2026-07-28**.
For the official MCP changelog and full specification, please visit [modelcontextprotocol.io](https://modelcontextprotocol.io/).
:::

## Key Changes in Protocol 2026-07-28

The following breaking changes were introduced in the MCP specification revision 2026-07-28:

## Breaking Changes

- **Stateless Protocol**: No more `initialize`/`notifications/initialized` handshake. Every request carries `io.modelcontextprotocol/protocolVersion`, `io.modelcontextprotocol/clientCapabilities`, and optionally `io.modelcontextprotocol/clientInfo` in `_meta`.
- **`server/discover`**: Now a mandatory RPC that servers MUST implement (replaces initialization). Returns `supportedVersions`, `capabilities`, `serverInfo`.
- **MRTR (Multi Round-Trip Requests)**: Servers use `InputRequiredResult` with `resultType: "input_required"` and `inputRequests` field instead of server-initiated JSON-RPC requests (sampling, elicitation, roots). Client retries original request with `inputResponses`.
- **`subscriptions/listen`**: Replaces `resources/subscribe`/`resources/unsubscribe` and HTTP GET endpoint. Uses long-lived POST-response streams with notification filters.
- **No protocol-level sessions** on Streamable HTTP. `Mcp-Session-Id` removed. Servers are stateless per-request.
- **All results carry `resultType`**: `"complete"` or `"input_required"`.
- **Deprecated features**: Roots, Sampling, Logging (still functional but new implementations should not adopt). HTTP+SSE transport deprecated. `ping`, `logging/setLevel`, `notifications/roots/list_changed` removed.
- **New HTTP headers**: `MCP-Protocol-Version`, `Mcp-Method`, `Mcp-Name`, `Mcp-Param-*` (from tool `x-mcp-header` annotations).
- **Caching**: `ttlMs` and `cacheScope` required on `server/discover`, `tools/list`, `prompts/list`, `resources/list`, `resources/templates/list`, `resources/read` results.

## Implementation notes

- **Server identity**: `serverInfo` is emitted under the namespaced `_meta` key `io.modelcontextprotocol/serverInfo`, not as a top-level result field, matching the 2026-07-28 `DiscoverResult` shape.
- **`resultType`**: every completed result carries `resultType: "complete"`.
- **Caching hints**: emitted automatically on the six cacheable operations. Defaults are `ttlMs = 300000` / `cacheScope = "public"` for lists and `server/discover`, and `ttlMs = 60000` / `cacheScope = "private"` for `resources/read`. Override them through the server's `cache` configuration:

  ```zig
  var server = mcp.Server.init(allocator, .{
      .name = "my-server",
      .version = "1.0.0",
      .cache = .{
          .ttl_ms = 60_000,
          .scope = .private,
          .read_ttl_ms = 0,
          .read_scope = .private,
      },
  });
  ```

  Negative `ttl_ms` values are clamped to `0` (immediately stale).
- **Deterministic ordering**: `tools/list`, `prompts/list`, `resources/list`, and `resources/templates/list` return entries sorted by name so clients can cache and diff lists reliably.
- **Error codes restructured**: `-32020` (HeaderMismatch), `-32021` (MissingRequiredClientCapability), `-32022` (UnsupportedProtocolVersion).
- **Streamable HTTP**: GET endpoint removed, SSE resumability via `Last-Event-ID` removed.
- **OAuth 2.1** authorization framework with Protected Resource Metadata (RFC 9728).
- **`_meta` key naming rules** with reverse DNS prefix convention.
- **`icons` property** added to implementations, tools, prompts, resources.
- **Tool names**: 1-128 chars, case-sensitive, alphanumeric + underscore/hyphen/dot.
- **`outputSchema`** for structured tool results with `structuredContent` field.
- **Completion**: `completion/complete` method for argument autocompletion.
- **Caching utility** with TTL-based freshness and cache scope.

## Backward Compatibility

This library maintains backward compatibility with older protocol versions:

| Version    | Status        |
| ---------- | ------------- |
| 2026-07-28 | Supported  |
| 2025-11-25 | Compatible |
| 2025-06-18 | Compatible |
| 2025-03-26 | Compatible |
| 2024-11-05 | Compatible |
