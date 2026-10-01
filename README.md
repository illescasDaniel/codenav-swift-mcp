# codenav-swift-mcp

Code navigation for Swift codebases as an [MCP](https://modelcontextprotocol.io) server, backed by
[sourcekit-lsp](https://github.com/swiftlang/sourcekit-lsp). A Swift port of `codenav-mcp`: the same
tools, with type-checker-accurate answers (overloads, protocol witnesses, extensions, inferred types)
instead of text matching.

## Tools

| Tool | What it does |
| --- | --- |
| `workspace` | Which directory is navigated and why; project kind; language server |
| `symbol_info` | One-call summary for a name or a position: hover, definition, conformances, grouped references |
| `type_at` | The type of the value/declaration at a position, and where that type is defined |
| `outline` | Indented outline of a file (types, extensions, members, line numbers) |
| `search_symbol` | Workspace symbol search with `kind`/`path` filters; production code ranks before tests |
| `hover`, `definition`, `references` | Position-based (1-indexed line, UTF-16 column, or `symbol` = the identifier's text on that line) |
| `callers` | Actual call sites of a function (call hierarchy) |
| `implementations` | Conforming types of a protocol (incl. extension conformances), subclasses, overrides |
| `diagnostics` | Compiler errors/warnings for a file |

Swift specifics: symbol names carry argument labels (`create(name:)`); a bare `create` works unless
overloads make it ambiguous, then the candidates are listed. `Type.member` and `Outer.Inner.member` are accepted.

Every tool that takes a `column` also takes `symbol` instead, and `symbol_info`, `callers` and `implementations`
accept `file_path` + `line` + `symbol` (or `column`) in place of a name, which resolves locals, overloads that
share labels, and SDK types such as `String` through the type checker. `file_path` may be relative, `../Sibling/...`
or absolute. Failures (bad input, ambiguous or unknown names, server errors) are returned with MCP `isError` set.

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
then `CLAUDE_PROJECT_DIR`, then the current directory. When that directory is not a Swift project (a host
that launches servers in `$HOME`), the client's roots are used; if no Swift project can be found the tools say
so and list projects found below the directory instead of indexing the wrong tree.

## Environment

| Variable | Meaning |
| --- | --- |
| `CODENAV_SWIFT_WORKSPACE` | Pin the workspace directory |
| `CODENAV_SWIFT_LSP` | Path to a specific `sourcekit-lsp` |
| `CODENAV_SWIFT_LSP_ARGS` | Extra arguments for it |
| `CODENAV_SWIFT_INDEX_TIMEOUT` | Seconds to wait for background indexing (a notice is appended if it's still running) |
| `CODENAV_SWIFT_REQUEST_TIMEOUT` | Seconds an individual language-server request may take (default 60) |

## Notes

* sourcekit-lsp builds into `.build` of the workspace on first use; the first query can be slow on large projects.
* Type aliases are not returned by `workspace/symbol`; use `outline` or a position lookup for those.
* A failed background build (visible in `workspace`) leaves results empty or partial; empty answers mention it.

## Tests

```bash
swift test
```

The integration test runs a real sourcekit-lsp against `Fixtures/SamplePackage` and is skipped if none is installed.
