---
title: "Server Concepts"
description: "Core MCP server concepts: tools, resources, prompts, and how servers expose capabilities to AI applications."
keywords: [MCP server, tools, resources, prompts, capabilities, server features]
---

# Understanding MCP Servers

MCP servers are programs that expose specific capabilities to AI applications through standardized protocol interfaces.

In revision `2026-07-28` a server is stateless per request. `server/discover` is
the entry point and returns `supportedVersions`, `capabilities`, and the server
identity under `_meta["io.modelcontextprotocol/serverInfo"]`; there is no
`initialize` handshake and no session id. Every subsequent request is
independent, and every result carries a `resultType` of `"complete"`,
`"input_required"`, or `"task"`.

## Core Server Features

Servers provide functionality through three building blocks:

| Feature       | Explanation                                                        | Who controls it |
| :------------ | :----------------------------------------------------------------- | :-------------- |
| **Tools**     | Functions that the LLM can actively call. Used to perform actions. | Model           |
| **Resources** | Passive data sources for read-only access to context info.         | Application     |
| **Prompts**   | Pre-built instruction templates for users (e.g. slash commands).   | User            |

### Tools

Tools enable AI models to perform actions. Each tool defines a specific operation with typed inputs (JSON Schema) and outputs.

- **list**: Discover available tools (`tools/list`).
- **call**: Execute a specific tool (`tools/call`).

`inputSchema` and `outputSchema` are complete JSON Schema 2020-12 documents.
Keywords the typed helpers cannot express — `$ref`, `$defs`, `allOf`,
`additionalProperties`, bounds — are supplied verbatim through
`InputSchema.fromJson(value)` or `ToolBuilder.inputSchemaFromRaw(value)`, so
nothing is silently dropped on the wire. When a tool declares an
`outputSchema`, its result may also carry `structuredContent`.

Example definition:

```json
{
  "name": "searchFlights",
  "description": "Search for available flights",
  "inputSchema": { "type": "object", "properties": { "origin": { "type": "string" } }, "required": ["origin"] }
}
```

### Resources

Resources provide structured access to information (files, databases, APIs) as context.

- **Direct Resources**: Fixed URIs (e.g., `file:///path/doc.md`).
- **Resource Templates**: Dynamic URIs (e.g., `travel://activities/{city}`).
- **Operations**: list, read, template listing, plus `subscriptions/listen` for updates.

`resources/subscribe` and `resources/unsubscribe` were removed in this revision.
A client opens one long-lived stream with `subscriptions/listen` and filters what
it receives; the server delivers each matching notification tagged with that
subscription's id and tears the stream down with `Server.endSubscription` or when
the client cancels it.

### Prompts

Prompts are user-controlled templates (like "Plan a vacation"). They help structure interactions.

- **list**: Discover prompts.
- **get**: Retrieve prompt details and arguments.

## Pagination and caching

Every `*/list` method accepts an opaque `cursor` and answers with `nextCursor`
while pages remain. The server's `page_size` is `0` by default, which returns
everything in one page and omits `nextCursor` entirely. An undecodable cursor is
a client mistake and is answered with `-32602`, not an internal error.

Results for `server/discover`, `tools/list`, `prompts/list`, `resources/list`,
`resources/templates/list`, and `resources/read` carry the mandatory caching
hints `ttlMs` and `cacheScope` (`"public"` or `"private"`). The server omits them
on an MRTR retry, whose inputs are not part of the cache key.

## Needing input from the client

A tool, resource, or prompt handler that cannot finish without client input
returns `error.InputRequired`. The server turns that into a result with
`resultType: "input_required"` carrying an `inputRequests` map and an opaque
`requestState`; the client answers and retries the original request with a new
id. This replaces the server-initiated requests of earlier revisions.

## Long-running work

The tasks extension (`io.modelcontextprotocol/tasks`) is opt-in. A client augments
a `tools/call` with `_meta["io.modelcontextprotocol/task"] = {"ttl": <ms>}`; the
server answers with `resultType: "task"` and a task snapshot, repeats the id under
`_meta["io.modelcontextprotocol/relatedTask"]`, and pushes `notifications/tasks` as
the task moves. The client observes the outcome with `tasks/get`, answers a task
blocked on input with `tasks/update`, and stops it with `tasks/cancel`.
`tasks/*` is refused with `-32021` unless both sides declared the extension.

## Bringing Servers Together

The power of MCP emerges when multiple servers work together. For example, a Travel Server, Weather Server, and Calendar Server can be combined by the Host to fulfill a complex user request like "Plan my vacation".

## Extensions & MCP Apps

Servers can extend core functionality by advertising supported extensions in `capabilities.extensions` during `server/discover`. The most prominent extension is **MCP Apps** (`io.modelcontextprotocol/ui`), allowing servers to deliver interactive HTML applications (`text/html;profile=mcp-app`) that render inline in host applications like Claude Desktop, Zed, and Goose.

For complete details, see the [Extensions & MCP Apps Guide](/guide/extensions).

