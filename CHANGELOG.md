# Changelog

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
