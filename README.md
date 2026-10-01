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
| `search_symbol` | Workspace symbol search with `kind`/`path`/`scope` filters; production code ranks before tests, and only the first 10 dependency hits are listed unless `scope=dependencies` or `all` |
| `hover`, `definition` | Position-based (1-indexed line, UTF-16 column, or `symbol` = the identifier's text on that line) |
| `references` | By position as above, or by `name` like `symbol_info` (`references(name="UserService.create(name:)")`) |
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

  Put `buildServer.json` in a directory that **contains every local package** the project uses
  (`XCLocalSwiftPackageReference`), e.g. the repository root for `src/App/App.xcodeproj` plus `src/Lib`:
  `xcode-build-server config -project src/App/App.xcodeproj -scheme App` run from the root. xcode-build-server only
  serves files below the directory that holds `buildServer.json`; for a package outside it, sourcekit-lsp has no build
  settings and hover, definition and references on its declarations come back empty. `workspace` flags this and prints
  the command to run.

## Build and register

```bash
swift build -c release
claude mcp add codenav-swift -- "$PWD/.build/release/codenav-swift-mcp"
```

The workspace is chosen from `CODENAV_SWIFT_WORKSPACE`, then the MCP client's roots (same git repo),
then `CLAUDE_PROJECT_DIR`, then the current directory. When that directory is not a Swift project (a host
that launches servers in `$HOME`), the client's roots are used; if no Swift project can be found the tools say
so and list projects found below the directory instead of indexing the wrong tree.

## Keeping it working

* **Restart the MCP client** (Claude Code, etc.) after rebuilding `codenav-swift-mcp` itself with `swift build -c release`:
  the client launches the binary once per session and only loads tools at startup.
* **Re-run `xcode-build-server config -project|-workspace <name> -scheme <Scheme>`** after a scheme or project layout change
  (a new scheme, a moved project, a new local package), then build the scheme once in Xcode so the index store is current.
  The `workspace` tool repeats this tip and reports when `buildServer.json` or its build root has gone stale.

## Environment

| Variable | Meaning |
| --- | --- |
| `CODENAV_SWIFT_WORKSPACE` | Pin the workspace directory |
| `CODENAV_SWIFT_LSP` | Path to a specific `sourcekit-lsp` |
| `CODENAV_SWIFT_LSP_ARGS` | Extra arguments for it |
| `CODENAV_SWIFT_INDEX_TIMEOUT` | Seconds to wait for background indexing (a notice is appended if it's still running) |
| `CODENAV_SWIFT_REQUEST_TIMEOUT` | Seconds an individual language-server request may take (default 60) |
| `CODENAV_SWIFT_LOCAL_PACKAGE_FOLDERS` | `1` registers local sibling packages as extra language-server workspace folders. Off by default: sourcekit-lsp then builds and indexes each package on its own (slow, large `.build`). |

## Notes

* sourcekit-lsp builds into `.build` of the workspace on first use; the first query can be slow on large projects.
* Type aliases are not returned by `workspace/symbol`; use `outline` or a position lookup for those.
* A failed background build (visible in `workspace`) leaves results empty or partial; empty answers mention it.

## Tests

```bash
swift test
```

The integration test runs a real sourcekit-lsp against `Fixtures/SamplePackage` and is skipped if none is installed.

## Cross-package and dependency symbols

The index is thin for declarations in a sibling package or a dependency checkout. For those, `references`,
`symbol_info`, `callers` and `implementations` complete the answer with a *scan + verify* pass: every whole-word
occurrence of the name in the project and its local packages is checked with the server's `definition`, and only
those leading back to the declaration are kept. Conformances written as `extension Dep.Type: Proto` are found
the same way (marked `unverified` when the server can't resolve the name in that file). Results over 600 candidates
are truncated with a note. `<dependency> Pkg/...` paths shown in results are accepted as `file_path`.

## Mixed Swift / Objective-C / C++ projects

`.m`, `.mm`, `.h`, `.c` and `.cpp` files are opened with their own language id, so sourcekit-lsp's built-in clangd
serves them (it needs the same build index as Swift). Calls, references and subclasses cross the language boundary
in both directions. Objective-C selectors fold to their Swift spelling (`incrementBy:` finds `increment(by:)`; a full
selector such as `loadImageWithURL:options:progress:completed:` picks an overload), `definition` lists a header
declaration before its implementation, and the text scan used for dependencies also covers Objective-C/C sources.

## Setup checks

For an Xcode project with a `buildServer.json`, `workspace` reports `build settings: ok` or lists what is wrong: the
`build_root` is gone, it has no index store, no Swift was ever compiled in it (a relink-only build records nothing, so
files get fallback arguments and bogus "No such module" errors), or the project changed after the last build. The same
findings are appended to empty results and to `diagnostics` output, and posted once when the server starts.

## Scan details

- A Swift file is only scanned for a dependency's symbol if it imports that module, or a module that re-exports it with
  `@_exported import` (an app importing only `Octopus`, which re-exports `DIC`, still uses DIC types), or lives in the
  module's own `Sources/<Target>/`, which skips most candidates in large projects. The module is taken from the `Sources/<Target>/` directory, so a package without that layout isn't prefiltered.
- Names the language server can't resolve in a file (the file isn't part of any build target, e.g. a dependency's tests)
  are listed separately under `Unverified` in `references` and `symbol_info`, never mixed into the verified list.
- For Swift methods called from Objective-C the scan searches the `@objc(selector:)` name when there is one, else the
  usual `base`+`Label` spellings. `Type.increment(by:)` also finds the Objective-C `incrementBy:`.
