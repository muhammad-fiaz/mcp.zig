---
title: "Contributing"
description: "Contribute to MCP.zig — report bugs, suggest features, improve documentation, and submit pull requests."
keywords: [contributing, pull requests, bug reports, open source, development setup, code guidelines]
---

# Contributing

mcp.zig is maintained by volunteers. Bug reports, documentation fixes, and pull requests are all useful.

## Ways to Contribute

- **Report bugs** — open an issue on the [issue tracker](https://github.com/muhammad-fiaz/mcp.zig/issues)
- **Suggest features** — open an issue or a [discussion](https://github.com/muhammad-fiaz/mcp.zig/discussions)
- **Improve documentation** — the guide lives in `docs/`, the API reference in doc comments under `src/`
- **Submit pull requests** — fixes, tests, and features

For defects in the library itself, `mcp.reportError` prints the issue URL
(`mcp.ISSUES_URL`, defined in `src/report.zig`) along with the error message, so
a failing program tells you where to report it. Security vulnerabilities are
handled separately; see [SECURITY.md](https://github.com/muhammad-fiaz/mcp.zig/blob/main/SECURITY.md).

## Getting Started

### 1. Fork and Clone

```bash
git clone https://github.com/YOUR_USERNAME/mcp.zig.git
cd mcp.zig
```

### 2. Build

```bash
zig build
```

Zig **0.17.0** or later is required. The version this tree is developed against
is pinned in CI (`.github/workflows/ci.yml`).

### 3. Verify

Run the same checks CI runs before you open a pull request:

```bash
# Unit tests for every module
zig build test
zig build test --summary all

# Compile the library and all fifteen examples without running them
zig build run-all-examples

# Formatting; CI fails when this is not clean
zig fmt --check src examples build.zig
zig fmt src examples build.zig   # to apply formatting

# Cross-target validation: compiles the tests and examples for a target that
# cannot run on the host
zig build test-compile -Dtarget=x86_64-linux
zig build test-compile -Dtarget=x86_64-windows
zig build test-compile -Dtarget=x86_64-macos
```

CI runs `zig build test`, `zig build run-all-examples`, and
`zig fmt --check src examples build.zig` on Linux, Windows, and macOS, and
`zig build test-compile` for seven additional targets.

### 4. Make Your Changes

Work on a branch:

```bash
git checkout -b feature/my-new-feature
```

## Protocol Changes

The library implements exactly one protocol revision: `2026-07-28`. Any change
to method names, `_meta` keys, `resultType` values, HTTP headers, or error codes
must be made in `src/protocol/` first, because the client and server both read
those constants. A change that alters the wire format needs a test in the
relevant module and an update to `docs/guide/protocol-version.md`.

Methods removed in this revision — `initialize`, `notifications/initialized`,
`ping`, `logging/setLevel`, `notifications/roots/list_changed`,
`resources/subscribe`, `resources/unsubscribe`, `tasks/result`, and
`tasks/list` — must not be reintroduced. There is no legacy fallback and no
session id.

## Code Guidelines

### Style

- Follow the [Zig language reference](https://ziglang.org/documentation/master/)
- Run `zig fmt src examples build.zig` before committing; CI enforces it
- Use descriptive names for types, functions, and struct fields
- Document every public declaration with a `///` comment, including its
  parameters, return value, and errors
- Keep handler bodies small; move logic into named helpers

### Documentation

```zig
/// Brief description of the function.
///
/// More detailed description if needed.
///
/// ## Parameters
/// - `param1`: Description of param1
/// - `param2`: Description of param2
///
/// ## Returns
/// Description of the return value.
///
/// ## Errors
/// - `error.SomeError`: When this error occurs
pub fn myFunction(param1: Type1, param2: Type2) !ReturnType {
    // ...
}
```

Doc comments are the source of the API reference: `zig build docs` renders them
to `zig-out/docs/`.

### Testing

- Add a test for every new behaviour, in the module that owns it
- Use `std.testing.allocator` so leaks fail the test
- Cover error paths, not only the happy path

```zig
test "my feature works" {
    const allocator = std.testing.allocator;

    // Test implementation
    try std.testing.expect(result == expected);
}
```

Examples are compiled by `zig build run-all-examples`, so a broken example fails
CI even when the unit tests pass.

## Pull Request Process

1. Update documentation if the change is observable
2. Add tests for new behaviour
3. Run the verification commands above
4. Create the pull request against `main`
5. Describe what changed and why in the pull request body

### PR Title Format

```
type(scope): description

Examples:
feat(server): add resource templates support
fix(jsonrpc): handle null request IDs
docs(guide): add advanced usage section
test(client): add connection tests
```

### Types

- `feat` - New feature
- `fix` - Bug fix
- `docs` - Documentation
- `test` - Tests
- `refactor` - Code refactoring
- `chore` - Maintenance

## Development Setup

### Prerequisites

- Zig 0.17.0+
- Git
- Bun, to build the documentation site

### Building Documentation

The site is a [VitePress](https://vitepress.dev) project in `docs/`, with
`bun.lock` pinning its dependencies:

```bash
cd docs
bun install
bun run docs:dev     # local dev server
bun run docs:build   # static build into docs/.vitepress/dist
bun run docs:preview # serve the built site
```

### Project Structure

```
mcp.zig/
├── src/
│   ├── mcp.zig          # Module entry point and re-exports
│   ├── report.zig       # Error reporting and ISSUES_URL
│   ├── protocol/        # Methods, types, JSON-RPC codec, schemas
│   ├── server/          # Server, tools, resources, prompts, HTTP rules
│   ├── client/          # Client, elicitation, roots, sampling
│   ├── transport/       # Transport interface, STDIO and HTTP
│   └── utils/           # Logging, middleware, progress
├── examples/            # Fifteen runnable examples
├── docs/                # VitePress documentation site
└── build.zig            # Build steps: test, docs, examples, test-compile
```

## Code of Conduct

- Be respectful and inclusive
- Welcome newcomers
- Accept constructive criticism
- Focus on what is best for the community

## Questions?

- Open a [discussion](https://github.com/muhammad-fiaz/mcp.zig/discussions)
- Check existing [issues](https://github.com/muhammad-fiaz/mcp.zig/issues)

## License

By contributing, you agree that your contributions are licensed under the MIT License.