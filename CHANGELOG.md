# Changelog

## Unreleased

* **Compiler-checked editing tools**, off unless `CODENAV_SWIFT_WRITE=1`: `rename_symbol`, `change_signature`, `edit_symbol`,
  `insert_member`, `delete_symbol`, `move_symbol`, `add_conformance`, `fix_diagnostics`, `refactor`, `apply_edit`,
  `check_edit` and `undo_edit`. A change is compiled in memory by sourcekit-lsp (diagnostics before vs after, in the edited
  files and every file that uses a changed name), written atomically only when it adds no errors, and journaled for undo.
* Files in modules that depend on a changed module are checked with a real `swift build --build-tests` after writing
  (SwiftPM target graph from `swift package describe`); a build that adds errors puts every file back.
* `verify` (build, and optionally run the tests) and `affected_tests` (the tests that use or reach a symbol, with the
  `swift test --filter` for them) are always available.
* `workspace` reports whether the write tools are on.
* `CODENAV_SWIFT_BUILD_TIMEOUT` bounds builds and test runs.

## 0.1.3

* `--version` and `--help` print and exit instead of waiting for MCP input on stdin.

## 0.1.2

* The server reports its real version in the MCP handshake (0.1.1 still reported 0.1.0).
* Install through Homebrew (`brew install illescasDaniel/tap/codenav-swift-mcp`); the README documents the release process.

## 0.1.1

* `type_at` finds the type definition on sourcekit-lsp from Swift 6.3, which answers `typeDefinition` with nothing for
  local declarations; the type named in the hover text is looked up by name instead.
* Prebuilt macOS binaries (arm64 and x86_64) are attached to each GitHub release, smoke-tested before publishing.
* CI builds and tests on Xcode 26.6.

## 0.1.0

First public release.

* Eleven read-only tools backed by sourcekit-lsp: `symbol_info`, `references`, `callers`, `implementations`, `type_at`,
  `outline`, `search_symbol`, `hover`, `definition`, `diagnostics` and `workspace`.
* Name-based lookups with Swift argument labels (`Type.member(label:)`) and Objective-C selectors; position-based
  lookups take the identifier's text on a line instead of a column.
* Scan-and-verify completion of references, callers and conformances for symbols declared in sibling packages and
  dependency checkouts, with re-exported modules and unverified matches reported separately.
* Mixed Swift / Objective-C / C / C++ projects through sourcekit-lsp's clangd.
* Workspace selection from `CODENAV_SWIFT_WORKSPACE`, the client's MCP roots, `CLAUDE_PROJECT_DIR` or the current
  directory, and build-settings health checks for Xcode projects using xcode-build-server.
