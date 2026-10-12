# Pull Request

## Summary

<!-- What does this change and why? Link related issues: Fixes #123 -->

## Type

<!-- Mark the relevant option with [x] -->

- [ ] Bug fix (`fix:`)
- [ ] New feature (`feat:`)
- [ ] Documentation (`docs:`)
- [ ] Tests (`test:`)
- [ ] Refactor / chore (`refactor:` / `chore:`)

## Area

<!-- Mark all that apply -->

- [ ] Server
- [ ] Client
- [ ] Transport (STDIO / HTTP)
- [ ] Protocol / JSON-RPC
- [ ] Tools / Resources / Prompts
- [ ] Middleware / Utils
- [ ] Examples
- [ ] Documentation
- [ ] Build / CI / GitHub templates

## Verification

<!-- Must all be checked before requesting review -->

- [ ] `zig build test` passes (93+ tests, no leaks)
- [ ] `zig build run-all-examples` succeeds
- [ ] `zig fmt --check src examples build.zig` passes
- [ ] Docs build passes (`bun run docs:build` in `docs/`) if docs changed
- [ ] Added/updated regression tests for behavior changes
- [ ] No protocol behavior change, or compatibility impact is documented

## Protocol impact

<!-- Delete if not applicable: does this change MCP 2026-07-28 behavior, wire format, or supported versions? -->

## Screenshots / output

<!-- Paste relevant test output, example runs, or rendered docs if helpful -->

```text

```
