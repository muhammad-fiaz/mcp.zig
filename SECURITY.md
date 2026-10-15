# Security Policy

## Reporting a Vulnerability

**Do not open a public GitHub issue for security vulnerabilities.**

Report privately by email to **contact@muhammadfiaz.com** with:

- A description of the vulnerability and its potential impact
- Steps to reproduce (minimal example preferred)
- Affected version(s) of mcp.zig and your Zig toolchain version
- Any relevant logs (redact secrets, tokens, and private data first)

What to expect:

- Acknowledgment of your report
- Coordinated handling and a fix in a subsequent release
- Public credit if you wish (optional)

Please allow reasonable time for a fix before any public disclosure.

## Supported Versions

| Version | Status                |
| ------- | --------------------- |
| 0.0.9   | Supported             |

Security fixes are released for the latest version only. Older releases are unsupported; please upgrade.

## Scope and Boundaries

mcp.zig is a protocol library. When deploying MCP servers built with it, operators remain responsible for transport-level controls outside the library's scope (TLS termination, reverse proxies, firewalling, secret storage).

Defenses implemented by the library:

- HTTP request bodies are bounded (`maxBody`, 4 MiB default) and oversized STDIO messages are rejected.
- Unknown methods and malformed JSON-RPC produce error responses; internal failures return generic `500` / `Internal error` messages without stack or state details.
- Server request logging records method names only, never credentials or full payloads.
- Per-request arenas reclaim transient allocations on the server message path.

Out of scope for the library itself: authentication policy, authorization decisions, TLS configuration, and sandboxing of tool handlers — these belong to the application built on top of mcp.zig.

## Contact

- Security reports: **contact@muhammadfiaz.com**
- General questions: [discussions](https://github.com/muhammad-fiaz/mcp.zig/discussions)
