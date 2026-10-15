---
title: "Full Client Example"
description: "Exercise every client-side MCP operation against a real in-process server, including tools/call, resources/read and prompts/get."
keywords: [client, round trip, tools/call, resources/read, prompts/get, testing, in-memory transport]
---

# Full Client Example

The other client examples only cover discovery and list operations. This one
wires a real `Client` to a real `Server` over an in-memory transport and
asserts on every response, so a regression in the client or server data plane
fails loudly instead of silently going untested.

## Why this example exists

`simple_client.zig` and `batch_client.zig` call only:

- `server/discover`
- `tools/list`
- `resources/list`
- `prompts/list`

That left `tools/call`, `resources/read` and `prompts/get` without any
end-to-end coverage even though the example servers register around 25 tools.
`full_client.zig` closes that gap.

## How the transport works

`examples/full_client.zig` defines a `Loopback` struct holding the server
pointer and a single pending response buffer, and exposes two vtables over the
same state:

| Vtable | `send` | `receive` |
| --- | --- | --- |
| Client side | dispatches into `Server.handleMessage` | returns the captured response |
| Server side | captures the response | returns the captured response |

One request produces exactly one reply, so a single slot is enough.

::: warning Copy with a long-lived allocator
`Server.sendResponse` serializes the reply, calls `transport.send`, and frees
the buffer immediately afterwards — and the allocator threaded down may be a
per-request arena. The capture therefore copies with **its own** allocator.
Copying with the allocator passed to `send` produces a dangling pointer and a
crash inside the JSON parser.
:::

## What it verifies

```text
[ok] server/discover              resultType=complete
[ok] tools/list                   -> 1 tool(s): greet
[ok] resources/list               -> 1 resource(s): info://server/about
[ok] prompts/list                 -> 1 prompt(s): introduce
[ok] tools/call greet             -> tool returned: Hello, Zig!
[ok] resources/read about         -> resource returned: mcp.zig round-trip server
[ok] prompts/get introduce        -> prompt returned 1 message(s)
```

Each step fails the process with a non-zero exit code if the server returns an
error response, omits `result`, or returns a non-`complete` `resultType`.

## Running

```bash
zig build run-full-client
```

No server process or network access is required: the client and server run in
the same process and communicate over the in-memory transport.

## Related

The same round trip is also covered by a unit test so allocator regressions
(leaks and double frees) are caught by `zig build test`, which the example
itself cannot detect:

- `src/server/server.zig` — `memory: full client/server round trip leaks nothing`
- [Server API](/api/server)
- [Client API](/api/client)