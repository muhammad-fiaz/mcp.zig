# Contributing to mcp.zig

Thank you for your interest in contributing to **mcp.zig**! We welcome bug reports, feature suggestions, documentation improvements, and pull requests.

## Ways to Contribute

- **Report bugs** — Open a [GitHub issue](https://github.com/muhammad-fiaz/mcp.zig/issues) with reproduction steps.
- **Suggest features** — Open an issue or start a [discussion](https://github.com/muhammad-fiaz/mcp.zig/discussions).
- **Improve documentation** — Fix or extend anything under `docs/` or `README.md`.
- **Submit pull requests** — Fix bugs or add features.

> **Security vulnerabilities:** do NOT open a public issue. See [SECURITY.md](SECURITY.md) and report privately to **contact@muhammadfiaz.com**.

## Prerequisites

- **Zig 0.17.0** or later (`zig version` to check; [download](https://ziglang.org/download/))
- Git
- (Optional) Bun or Node.js 20+ for building the documentation site

## Getting Started

```bash
git clone https://github.com/muhammad-fiaz/mcp.zig.git
cd mcp.zig
```

### Build

```bash
zig build                  # library
zig build run-all-examples # library + all 14 examples
```

### Test

```bash
zig build test                                   # unit tests (must be 100% green)
zig build test-compile -Dtarget=x86_64-linux    # cross-target compile check
zig build test-compile -Dtarget=x86_64-windows
zig build test-compile -Dtarget=x86_64-macos
```

### Formatting

```bash
zig fmt --check src examples build.zig
```

CI enforces build, tests, example compilation, and formatting. Run all four locally before submitting.

### Documentation

```bash
cd docs
bun install
bun run docs:dev     # local preview
bun run docs:build   # production build
```

## Code Guidelines

- Follow the official Zig style guide (`zig fmt` is authoritative).
- Target **Zig 0.17.0** only — do not add compatibility layers for older toolchains.
- Use `std.testing.allocator` in tests so leaks fail the test.
- Add regression tests for bug fixes, especially around JSON-RPC shapes, protocol negotiation, transport errors, and resource cleanup.
- Document public APIs with `///` doc comments.
- Keep functions focused; prefer explicit error propagation over `catch {}` swallowing.
- Never log secrets, tokens, or full request payloads.

## Pull Request Process

1. Create a branch: `git checkout -b fix/short-description` (or `feat/...`, `docs/...`, `test/...`).
2. Update documentation and examples if behavior changes.
3. Add or update tests; ensure `zig build test` passes.
4. Ensure `zig fmt --check src examples build.zig` passes.
5. Open a PR against `main` with a clear description of what changed and why.

### PR title format

```
type(scope): description

feat(server): add resource template caching
fix(jsonrpc): handle null request IDs
docs(guide): expand HTTP transport section
test(client): cover request cleanup
```

## Project Layout

```
mcp.zig/
├── src/
│   ├── mcp.zig          # Main entry point
│   ├── version.zig      # Library version
│   ├── protocol/        # JSON-RPC, MCP protocol, types, schemas
│   ├── server/          # Server, tools, resources, prompts
│   ├── client/          # Client, roots, sampling, elicitation
│   ├── transport/       # STDIO and HTTP (httpx.zig) transports
│   └── utils/           # Errors, logging, middleware, network, progress
├── examples/            # 14 runnable examples
├── docs/                # VitePress documentation site
└── build.zig            # Build configuration
```

## Questions?

- Open a [discussion](https://github.com/muhammad-fiaz/mcp.zig/discussions)
- Check existing [issues](https://github.com/muhammad-fiaz/mcp.zig/issues)
- Email: **contact@muhammadfiaz.com**

By contributing, you agree that your contributions will be licensed under the MIT License.
