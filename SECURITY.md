# Security Policy

## Reporting a Vulnerability

**Do not open a public GitHub issue for a security vulnerability.**

Send the report by email to **contact@muhammadfiaz.com**. That address is the
private channel published by this repository in
`.github/ISSUE_TEMPLATE/config.yml` and `CONTRIBUTING.md`.

Include:

- What the vulnerability is, and what an attacker gains from it
- The smallest reproduction you can manage — a request body, a config
  combination, or a handler that triggers it
- The affected version: `mcp.VERSION` of the library, and your Zig toolchain
  version
- Relevant logs, with tokens, credentials, and private paths redacted first

For ordinary bugs, use the public issue tracker instead. `mcp.reportError`
prints that URL (`mcp.ISSUES_URL`, from `src/report.zig`) whenever an
application surfaces an error it believes may be a library defect. That module
performs no network access of its own.

## Supported Versions

| Version | Status                                          |
| ------- | ----------------------------------------------- |
| 0.0.9   | Current version                                 |
| 0.0.8   | Previous release; upgrade advised               |

## Scope and Boundaries

mcp.zig is a protocol library. Operators deploying a server built with it remain
responsible for everything outside it — TLS termination, reverse proxies,
firewalling, credential storage, and rate limiting at the network edge.

Implemented in the library:

- **Bounded input** — the HTTP server caps request bodies with httpx's `maxBody`
  (set from `Server.max_http_body_size`, 4 MiB), and the STDIO transport
  rejects messages at or beyond `max_message_size` (4 MiB by default) with
  `error.MessageTooLarge`.
- **Streamable HTTP conformance** — `MCP-Protocol-Version`, `Mcp-Method`,
  `Mcp-Name`, and `Mcp-Param-*` headers are validated against the JSON-RPC body
  before a request is dispatched; a mismatch is `-32020` and an unsupported
  protocol version is `-32022`. The MCP endpoint answers `POST` only, and
  answers anything else with `405`. Header values that cannot be sent safely as
  plain ASCII are base64-encoded with the spec's `=?base64?<base64>?=`
  sentinel and decoded again before comparison.
- **Schema-aware parameter headers** — when the tool's `inputSchema` is
  available, `x-mcp-header` annotations decide exactly which `Mcp-Param-*`
  headers are required and what they must agree with, so a header cannot smuggle
  an argument the schema does not declare.
- **DNS-rebinding protection** — when the server binds to a loopback host, only
  loopback `Origin` values are accepted (`403 Forbidden` otherwise). Requests
  without an `Origin` header are allowed.
- **Bounded error disclosure** — unknown methods return `-32601` and
  unparseable messages a JSON-RPC parse error, without echoing the input. HTTP
  failures return a generic `500` body; stack traces and internal state are not
  returned to the client.
- **Minimal logging** — the server writes `Received request: <method>` to stderr
  for each request. Request and response payloads, credentials, and tokens are
  not logged.
- **Scoped allocation** — `Server.handleMessage` serves each message from a
  per-request arena that is released once the response has been written.

Deliberately not implemented, and therefore your responsibility:

- **Authorization** — the HTTP client sends a bearer token via
  `Client.setAuthorizationToken`. There is no OAuth 2.1 or OIDC discovery, no
  `WWW-Authenticate` challenge parsing, no PKCE, dynamic client registration,
  refresh, or step-up. An unauthenticated HTTP endpoint is unauthenticated.
- **Long-lived streams** — per-request SSE stream lifetime for Streamable HTTP
  is not implemented, so do not rely on a server-held stream to bound access to
  a subscription.
- **Handler isolation** — tool, resource, and prompt handlers run in-process
  with the server's full privileges. Sandbox them, and gate them on your own
  authorization checks.
- **Secrets in configuration** — tokens are held in memory for the client's
  lifetime. Do not log them or include them in error messages.

## Contact

- Security reports (private): **contact@muhammadfiaz.com**
- Defects and feature requests: [issue tracker](https://github.com/muhammad-fiaz/mcp.zig/issues)
- Questions: [discussions](https://github.com/muhammad-fiaz/mcp.zig/discussions)