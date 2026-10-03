# Changelog

## Unreleased

* The in-memory check finds the files that use a changed name in one pass over the tree for all names (it walked the tree
  once per name, for at most 25 names); up to 200 changed names are searched. Added tests for multiple trailing closures in
  `change_signature` and for memberwise-initializer labels on a property rename; the README lists the new safety behaviour.

* The loose (indentation-insensitive) `old_text` match refuses to touch a multiline string literal, where indentation is part of
  the value; the flow lint no longer counts the continuation lines of an expression broken after an operator as statements;
  a `keep_deprecated_alias` forwarder no longer copies `@objc(selector:)` or `@IBAction` (it would register a second selector);
  the undo journal is also pruned by size (64 MB), not only by count.

* Files that start with a UTF-8 byte-order mark keep it when an edit tool rewrites them (it was silently dropped before);
  `change_signature` warns when an argument it drops from a call looks like a call (its side effects no longer happen);
  `rename_symbol` warns about the JSON key change when `Codable` is declared in a separate `extension`; `callers`, `type_hierarchy`
  and `symbol_info` reject an out-of-range position instead of answering "nothing there".

* Accuracy and robustness pass: new Swift files in an Xcode project that no target contains yet are no longer rolled back
  (they get a note to add them to a target); build comparisons tell same-named files in different folders apart; linker and
  C/Objective-C errors are parsed from builds; the newest `Build/Products` folder is used; `fix_diagnostics` prefers the
  server's preferred fix-it and skips force-unwrap fix-its unless `only` asks; `edit_symbol new_body` with a trailing `//`
  comment no longer swallows the closing brace; brace counting understands escapes, raw strings and block comments; edits
  never split an emoji or a CRLF; a final-newline-only change shows in diffs; non-ASCII identifiers are valid rename targets;
  a failing `prepareRename` reports the server's error. Known trade-off: diagnostics are compared by severity and message,
  not line text, so an unchanged pre-existing error is never reported as new.

* Fixes from a trial on a real Xcode app: the project kind is re-detected on every tool call, so a `buildServer.json`
  generated after the MCP started is picked up (before, cross-module detection, `verify=build` and the module checks stayed
  off and a correct rename of a property used from the test target was rejected); the in-memory compile check says
  "NOT VERIFIED" (and refuses to write unless `require=none`) when the build settings are incomplete, instead of printing
  "no new errors" or a wall of bogus ones; `keep_deprecated_alias` calls the new name with the NEW argument labels
  (`scrollTo(_:)` → `scroll(to:)` produced a forwarder that didn't compile); `rename_symbol` calls out leftover mentions that sit
  inside `#if` blocks the current build doesn't compile (a Release-only call site survived a rename that built fine in Debug).
* Fixes from trying the tools on three real Xcode projects: `verify` and the build checks find the project from
  `buildServer.json`'s `workspace` (a project in a subfolder such as `src/App/App.xcodeproj` used to be "not buildable");
  `rename_symbol` on a stored property also updates `Type(old: …)` memberwise-initializer labels the language server
  doesn't follow; `swiftc -print-ast` gets the project's SDK and sibling files, so synthesized members work on Xcode
  projects (and on macOS 27); `callers` shows `#Preview` and property-wrapper/macro-generated callers by what they come from;
  `affected_tests` says when test files have no build settings yet instead of "no test found", and gives `-only-testing`
  filters (and `run=true` works) for Xcode projects; `rename_symbol` accepts `new_name="reload()"` for a no-argument function.
* `verify tests=true` runs an Xcode project's tests (`xcodebuild test-without-building` on the newest iPhone simulator the scheme
  supports; `filter` is an `-only-testing` identifier). Previously it only built.
* Fixed the SwiftPM package graph never matching files when the package sits behind a symlink (`/var` vs `/private/var`, as
  in temp folders): compiler-written members were then missing from `symbol_info`, and a cross-file change could slip
  through the in-memory check. A file added after the graph was cached now refreshes it.
* **Compiler-checked editing tools**, off unless `CODENAV_SWIFT_WRITE=1`: `rename_symbol`, `change_signature`, `edit_symbol`,
  `insert_member`, `delete_symbol`, `move_symbol`, `add_conformance`, `fix_diagnostics`, `refactor`, `apply_edit`,
  `check_edit` and `undo_edit`. A change is compiled in memory by sourcekit-lsp (diagnostics before vs after, in the edited
  files and every file that uses a changed name), written atomically only when it adds no errors, and journaled for undo.
* Files in modules that depend on a changed module are checked with a real `swift build --build-tests` after writing
  (SwiftPM target graph from `swift package describe`); a build that adds errors puts every file back.
* **Xcode projects** (found on a real app with a local package): module boundaries come from the `.SwiftFileList` files of the
  build `buildServer.json` points at, so a change to a package type no longer fails on its app-side conformer; files in
  dependent modules are checked with `xcodebuild build-for-testing` (scheme, project and destination from `buildServer.json`,
  the same DerivedData). A build of a temporarily written or undone change is followed by one of the restored files so
  Xcode's index store never keeps describing a change that isn't there, and build logs of ours with no Swift compilation are
  removed so xcode-build-server keeps finding compile arguments.
* `rename_symbol` lists leftover mentions per file; `change_signature` refuses an operation key it doesn't read (an
  `add` with `default` used to drop the default silently); an edit aimed outside the workspace is refused as such.
* `verify` (build, and optionally run the tests) and `affected_tests` (the tests that use or reach a symbol, with the
  `swift test --filter` for them) are always available.
* `workspace` reports whether the write tools are on.
* `CODENAV_SWIFT_BUILD_TIMEOUT` bounds builds and test runs.
* `undo_edit` history is kept on disk (per workspace, last 25 edits) and survives a server restart.
* `change_signature` rewrites calls that end in a trailing closure when the closure parameter stays last.
* `rename_symbol keep_deprecated_alias` also covers properties (forwarding accessor) and types (`typealias`).
* `move_symbol to_container` moves a member into another type or extension, in the same or another file.
* Name lookups and `search_symbol` find what sourcekit-lsp's `workspace/symbol` leaves out: `let` properties and constants
  (`User.id`, `static let limit`), members declared in extensions in other files, and top-level `let`s. They are read from
  the outlines of the files that mention the name, so a `Type.member` or bare-name lookup in any tool (rename, references,
  change_signature, ...) now resolves them.
* The outline lookups that back the above keep a per-file cache of identifiers (modification time + size, files edited in
  the last seconds are always re-read, capped memory), so a search no longer re-reads the whole workspace: about 10x
  faster on a 5,000-file tree. It only prefilters which outlines to read, so it can't change an answer.
* `symbol_info` lists the members the compiler writes for a type and the source never declares (memberwise `init`,
  Codable / Equatable / Hashable / RawRepresentable / CaseIterable members), marked `[Auto-Generated]`, using
  `swiftc -print-ast`; `Type.init(...)` and `Type.encode(to:)` lookups answer for them, and `outline` takes `synthesized`.
  Falls back to working out the memberwise `init` when the compiler can't be used, taking the types of properties the
  source doesn't write (`var count = 0`) from the language server's hover.
* `rename_symbol keep_deprecated_alias` no longer gives a get-only computed property a setter.
* A file that still has errors gets a heuristic check for missing returns in the declarations an edit touched, since the
  compiler skips flow analysis there.

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
