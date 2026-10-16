---
title: "Client Concepts"
description: "Core MCP client concepts: connecting to servers, discovery, and invoking tools, resources, and prompts."
keywords: [MCP client, elicitation, roots, sampling, client features, server connection]
---

# Understanding MCP Clients

MCP clients are instantiated by host applications to communicate with MCP servers. Each client handles one direct communication with one server.

In revision `2026-07-28` there is no initialization handshake: a client connects, calls `server/discover`, and then issues independent requests that each repeat the protocol version and the client's capabilities in `_meta`. mcp.zig exposes this as `Client.connectStdio`, `Client.connectHttp`, and `Client.discover`.

## Receiving results

Client request helpers such as `discover`, `listTools`, `callTool`, and
`readResource` return `!void`: they write the request to the transport and do
not hand back a JSON-RPC id. Results arrive as separate messages, and the
supported way to collect one is:

- `handleMessage(payload)` takes one raw JSON-RPC message, resolves the matching
  pending request, and stores its final result.
- `takeResult(id)` returns the owned raw JSON of that result — which the caller
  must `free` — or `null` while the request is still outstanding.

The exception is the MRTR-driven trio, `callToolResolved`, `readResourceResolved`
and `getPromptResolved`, which return `!i64` because an `input_required` round
produces a retry under a new id and the caller needs the original one to collect
the final result.

## Core Client Features

In addition to using context from servers, clients provide features _to_ servers to enable richer interactions.

| Feature         | Explanation                                                              | Example                                          |
| :-------------- | :----------------------------------------------------------------------- | :----------------------------------------------- |
| **Elicitation** | Enables servers to request information from users during interactions.   | Asking for a missing booking detail.             |
| **Roots**       | Allows clients to specify filesystem boundaries/directories of interest. | "Travel Planning Workspace" folder.              |
| **Sampling**    | Allows servers to request LLM completions through the client (Agentic).  | A server asking the LLM to pick the best flight. |

### Elicitation

Elicitation allows servers to pause operations and ask the user for input (e.g., via a UI form).

- **Protocol**: `elicitation/create` (with `notifications/elicitation/complete` on completion)
- **Flow**: Server requests -> Client shows UI -> User inputs -> Client returns execution.
- **Client API**: `enableElicitation()` (form and URL), `enableElicitationForm()`, or `enableElicitationUrl()`.

### Roots

Roots communicate filesystem access boundaries. They are deprecated in
`2026-07-28` but still supported.

- **Protocol**: `roots/list`
- Roots are advisory boundaries (folders) telling the server where to focus.
- The capability is presence-only: `enableRoots()` takes no arguments, there is
  no `listChanged` flag, and `notifications/roots/list_changed` was removed, so
  the server ignores it. The client has no `notifyRootsChanged`.

### Sampling

Sampling enables servers to perform AI tasks using the Host's LLM connection. It
is deprecated in `2026-07-28` but still supported.

- **Protocol**: `sampling/createMessage`
- **Control**: Puts the client/user in control of permissions, costs, and model selection.
- **Human-in-the-loop**: Users can review sampling requests.
- **Client API**: `enableSampling()`, or `enableSamplingAdvanced(context, tools_support)`
  to advertise optional context and tools support.

Both Roots and Sampling are reachable in practice through Multi Round-Trip
Requests: a server that needs either one asks for it inside an `input_required`
result's `inputRequests` map, and the client answers through `tasks/update` or
an MRTR retry rather than by handling an out-of-band server-initiated request.