---
title: "Protocol Version"
description: "MCP protocol version support: this library implements revision 2026-07-28 only, with the stateless per-request model."
keywords: [MCP protocol version, 2026-07-28, stateless protocol, MRTR, tasks extension]
---

# Supported Protocol Version

::: info Official Documentation
This library implements **Model Context Protocol (MCP) version 2026-07-28**.
For the official MCP changelog and full specification, please visit [modelcontextprotocol.io](https://modelcontextprotocol.io/).
:::

`protocol.PROTOCOL_VERSION` is `2026-07-28`. It is the only revision this
library speaks: there is no negotiation down to an earlier revision and no
legacy fallback.

## Key Changes in Protocol 2026-07-28

The following breaking changes were introduced in the MCP specification revision 2026-07-28:

## Breaking Changes

- **Stateless Protocol**: No more `initialize`/`notifications/initialized` handshake. Every request carries `io.modelcontextprotocol/protocolVersion`, `io.modelcontextprotocol/clientCapabilities`, and `io.modelcontextprotocol/clientInfo` in `_meta`; a request missing the version or the capabilities is answered with `-32602`.
- **`server/discover`**: Now a mandatory RPC that servers MUST implement (replaces initialization). Returns `supportedVersions` and `capabilities`, with the server identity under the namespaced `_meta` key `io.modelcontextprotocol/serverInfo`.
- **MRTR (Multi Round-Trip Requests)**: Servers use `InputRequiredResult` with `resultType: "input_required"` and an `inputRequests` field instead of server-initiated JSON-RPC requests (sampling, elicitation, roots). The client answers and retries the original request with a new id, carrying the same params plus `inputResponses` and the opaque `requestState` verbatim.
- **`subscriptions/listen`**: Replaces `resources/subscribe`/`resources/unsubscribe` and the HTTP GET endpoint. The server acknowledges with the subscription id and the subset of the filter it agreed to honour, then keeps the stream open. Change notifications are delivered only to subscribers whose filter admits them, each tagged with the subscription id in `_meta`. The client opens one with `subscriptionsListen(.{ .toolsListChanged = true })` and ends it with `cancel`; the server tears it down with `Server.endSubscription`.
- **No protocol-level sessions** on Streamable HTTP. `Mcp-Session-Id` removed. Servers are stateless per-request.
- **All results carry `resultType`**: `"complete"`, `"input_required"`, or `"task"` (the tasks extension).
- **Removed in this revision**: `ping`, `logging/setLevel` (log level is now per-request via `io.modelcontextprotocol/logLevel` in `_meta`), `notifications/roots/list_changed`, `resources/subscribe`/`resources/unsubscribe`, `Mcp-Session-Id`, and SSE resumability. `tasks/result` and `tasks/list` are replaced by `tasks/get`, `tasks/update` and `tasks/cancel`.
- **New HTTP headers**: `MCP-Protocol-Version`, `Mcp-Method`, `Mcp-Name`, `Mcp-Param-*` (from tool `x-mcp-header` annotations).
- **Caching**: `ttlMs` and `cacheScope` required on `server/discover`, `tools/list`, `prompts/list`, `resources/list`, `resources/templates/list`, `resources/read` results.

## Additions in this revision

These are new capabilities rather than replacements, and mcp.zig implements
each of them:

- **Tasks extension** (`io.modelcontextprotocol/tasks`), declared as an extension
  label on both sides in place of the old per-method task capabilities.
- **`_meta` key naming rules** with a reverse-DNS prefix convention.
- **`icons`** on implementations, tools, prompts, and resources.
- **`outputSchema`** for structured tool results, carried alongside
  `structuredContent`.
- **`completion/complete`** for argument autocompletion.
- **Tool name rules**: 1-128 characters, case-sensitive, alphanumeric plus
  underscore, hyphen, or dot (`mcp.tools.isValidToolName`).

## Implementation notes

- **Server identity**: `serverInfo` is emitted under the namespaced `_meta` key `io.modelcontextprotocol/serverInfo`, not as a top-level result field, matching the 2026-07-28 `DiscoverResult` shape.
- **`resultType`**: every completed result carries `resultType: "complete"`. The client accepts an absent `resultType` from an earlier-protocol server and rejects any value it does not recognise (`complete`, `input_required`, or the tasks extension's `task`) with `error.UnknownResultType`.
- **MRTR retries are not cacheable**: a request carrying `inputResponses` or `requestState` is a retry rather than a fresh call, so its result is emitted **without** `ttlMs`/`cacheScope`. Those fields depend on inputs that are not part of the cache key.
- **Invalid cursors are rejected**: an undecodable `cursor` returns `-32602` rather than silently restarting from the first page. A cursor counts as absent only when the `cursor` member is missing or is not a string.
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
- **Streamable HTTP**: GET endpoint removed, SSE resumability via `Last-Event-ID` removed. Per-request SSE stream lifetime is also not implemented in this library, because the transport interface exchanges whole messages; the HTTP client accepts `text/event-stream` responses, and the server answers one POST with one response.
- **Tasks**: a `tools/call` is augmented through `_meta["io.modelcontextprotocol/task"]` (`{"ttl": <ms>}`), never through a `task` request parameter. The result carries `resultType: "task"`, a `task` snapshot, and `_meta["io.modelcontextprotocol/relatedTask"] = {"taskId": ...}`; progress is pushed as `notifications/tasks` to the subscriptions that listed the task id in `types.SubscriptionFilter.taskIds`. `tasks/get`, `tasks/update` and `tasks/cancel` are refused with `-32021` unless the client declared the extension.
- **Cancellation**: cooperative and poll-based. `notifications/cancelled` records the request id; a handler observes it through `Server.cancellationToken(id)` (`cancelled()`, `keepGoing()`) and the server answers with `-32800`. A synchronous handler that never polls its token cannot be interrupted.
- **Authorization**: the OAuth 2.1 framework and Protected Resource Metadata (RFC 9728) are part of the specification, but **not implemented here**. Only `Client.setAuthorizationToken` (a static bearer token) exists; see [Authorization](/guide/authorization).

## Version Support

| Version    | Status                                                                                  |
| ---------- | --------------------------------------------------------------------------------------- |
| 2026-07-28 | Supported (latest, default; the active revision this library speaks and serves)         |
| 2025-11-25 | Unsupported / Deprecated (older session-based revision; methods removed in 2026-07-28) |
| 2025-06-18 | Unsupported / Deprecated (older session-based revision; methods removed in 2026-07-28) |
| 2025-03-26 | Unsupported / Deprecated (older session-based revision; methods removed in 2026-07-28) |
| 2024-11-05 | Unsupported / Deprecated (initial specification; methods removed in 2026-07-28)        |

Earlier revisions (`2025-11-25`, `2025-06-18`, `2025-03-26`, `2024-11-05`)
are **deprecated and unsupported**. They established a session with an `initialize` handshake and are **not** supported:
the methods they rely on were removed in 2026-07-28. In accordance with the 2026-07-28 specification, `protocol.SUPPORTED_VERSIONS`
and `server/discover` advertise only the revisions the server can actually serve: `["2026-07-28"]`.
Requests specifying older revisions in the `MCP-Protocol-Version` HTTP header or body `_meta` are rejected with
`-32022` (`UnsupportedProtocolVersion`).
