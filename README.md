# codenav-swift-mcp

Code navigation for Swift codebases as an [MCP](https://modelcontextprotocol.io) server, backed by
[sourcekit-lsp](https://github.com/swiftlang/sourcekit-lsp). A Swift port of `codenav-mcp`: the same
tools, with type-checker-accurate answers (overloads, protocol witnesses, extensions, inferred types)
instead of text matching.

## Tools

| Tool | What it does |
| --- | --- |
| `workspace` | Which directory is navigated and why; project kind; language server |
| `symbol_info` | One-call summary for a name: hover, definition, conformances, grouped references |
| `outline` | Indented outline of a file (types, extensions, members, line numbers) |
| `search_symbol` | Workspace symbol search with `kind`/`path` filters; production code ranks before tests |
| `hover`, `definition`, `references` | Position-based (1-indexed line, UTF-16 column) |
| `callers` | Actual call sites of a function (call hierarchy) |
| `implementations` | Conforming types of a protocol (incl. extension conformances), subclasses, overrides |
| `diagnostics` | Compiler errors/warnings for a file |

Swift specifics: symbol names carry argument labels (`create(name:)`); a bare `create` works unless
overloads make it ambiguous, then the candidates are listed. `Type.member` and `Outer.Inner.member` are accepted.

## Requirements

* macOS 13+, Swift 6.1 toolchain (Xcode 16.4+ or swift.org), which ships `sourcekit-lsp`.
* SwiftPM packages work out of the box. **Xcode projects** need a `buildServer.json`:

  ```bash
  brew install xcode-build-server
  xcode-build-server config -project App.xcodeproj -scheme App
  ```

  Also build the project once in Xcode so the index store exists.

## Build and register

```bash
swift build -c release
claude mcp add codenav-swift -- "$PWD/.build/release/codenav-swift-mcp"
```

The workspace is chosen from `CODENAV_SWIFT_WORKSPACE`, then the MCP client's roots (same git repo),
then `CLAUDE_PROJECT_DIR`, then the current directory.

## Environment

| Variable | Meaning |
| --- | --- |
| `CODENAV_SWIFT_WORKSPACE` | Pin the workspace directory |
| `CODENAV_SWIFT_LSP` | Path to a specific `sourcekit-lsp` |
| `CODENAV_SWIFT_LSP_ARGS` | Extra arguments for it |
| `CODENAV_SWIFT_INDEX_TIMEOUT` | Seconds to wait for background indexing (a notice is appended if it's still running) |

## Notes

* sourcekit-lsp builds into `.build` of the workspace on first use; the first query can be slow on large projects.
* Type aliases are not returned by `workspace/symbol`; use `outline` or a position lookup for those.

## Tests

```bash
swift test
```

The integration test runs a real sourcekit-lsp against `Fixtures/SamplePackage` and is skipped if none is installed.
