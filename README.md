# codenav-swift-mcp

Compiler-accurate code navigation for Swift codebases, as an [MCP](https://modelcontextprotocol.io) server.

AI coding agents usually find their way around a codebase with `grep`. That works until it doesn't: in
Swift, `save` matches every `save` in the project, an overload hides behind identical text, protocol witnesses
live in extensions in other files, and a `let user = try await service.create(...)` never spells out its type.
**codenav-swift-mcp** gives the agent the same engine Xcode uses,
[sourcekit-lsp](https://github.com/swiftlang/sourcekit-lsp), behind a handful of tools that take a **symbol
name** instead of a hand-counted line and column. Answers come from the type checker, so they cover overloads,
protocol witnesses, extensions and inferred types.

* **Ask by name.** `symbol_info(name: "UserService.create(name:)")` returns the signature, docs, definition and every
  reference, grouped by file, in one call. Argument labels pick an overload.
* **Ask by line.** Every position tool also takes `symbol`, the identifier's text on that line, so the agent
  never counts columns.
* **Who conforms, who overrides, who calls.** Protocol conformances (including ones declared in extensions),
  subclass trees, overriding methods and real call sites, not text matches.
* **Works past the index.** Symbols from sibling packages and dependency checkouts are verified with a
  *scan + verify* pass, and calls that cross the Swift/Objective-C boundary are followed in both directions.
* **Says what's wrong with your setup.** A stale `buildServer.json`, a relink-only build, a failed background build,
  or a workspace with no Swift project are reported with the command that fixes them.
* **Read-only by default.** The navigation tools never edit your code. [Compiler-checked editing tools](#editing-opt-in)
  (rename, change a signature, edit a symbol, ...) exist too, and are off until you set `CODENAV_SWIFT_WRITE=1`.

## What it looks like

Real output from the bundled [`Fixtures/SamplePackage`](Fixtures/SamplePackage).

**"What is this method and where is it used?"**: one call instead of search → hover → definition → references:

```text
> symbol_info(name: "UserService.create(name:)")

UserService.create(name:)  [Method]  (Sources/SampleKit/UserService.swift:10:14)

    public func create(name: String) async throws -> User

Creates a user and saves it.

Definition:
Sources/SampleKit/UserService.swift:10:14
    9 | 	/// Creates a user and saves it.
   10 | 	public func create(name: String) async throws -> User {
   11 | 		let user = User(id: name.count, name: name)

References:
3 reference(s) in 3 file(s):
Sources/SampleApp/main.swift: L4
Sources/SampleKit/UserService.swift: L10
Tests/SampleKitTests/UserServiceTests.swift: L11
```

**"Who conforms to this protocol?"**: including the conformance written in an extension, and types that conform
through a refining protocol:

```text
> implementations(name: "Greeter")

3 type(s) conform to or refine Greeter:
PoliteGreeter  [conformance in extension]  (Sources/SampleKit/Stores.swift:19:11)
Refined  [Protocol]  (Sources/SampleKit/Models.swift:34:17)
  Shouter  [Struct]  (Sources/SampleKit/Models.swift:35:15)
```

**"Who actually calls this requirement?"**: calls through `any UserStore`, attributed to the calling method:

```text
> callers(name: "UserStore.save(_:)")

UserService.create(name:)  [Method]  (Sources/SampleKit/UserService.swift:10) calls at L12
UserService.rename(_:to:)  [Method]  (Sources/SampleKit/UserService.swift:22) calls at L25
```

**"What type is this inferred `let`?"**: no column counting, just the identifier's text on the line:

```text
> type_at(file_path: "Sources/SampleApp/main.swift", line: 4, symbol: "user")

@MainActor let user: User
Type defined at Sources/SampleKit/Models.swift:1:15
  public struct User: Identifiable, Equatable, Sendable {
```

**Ambiguity is reported, not guessed.** A bare name that matches several overloads lists them, so the agent can pick one:

```text
> callers(name: "greet(_:)")

3 symbols match 'greet(_:)'; qualify with the type (`Type.member`) or pass file_path to disambiguate:
Shouter.greet(_:)  [Method]  (Sources/SampleKit/Models.swift:37:14)
Greeter.greet(_:)  [Method]  (Sources/SampleKit/Ports.swift:8:7)
PoliteGreeter.greet(_:)  [Method]  (Sources/SampleKit/Stores.swift:20:14)
```

**Across languages.** In a mixed project, an Objective-C class hierarchy is navigable from Swift and back
(`Fixtures/MixedPackage`):

```text
> implementations(name: "Counter")

1 type(s) inherit from Counter:
Doubler  [Class]  (Sources/Bridge/Doubler.m:6:17)
```

## Tools

| Tool | What it answers |
| --- | --- |
| `symbol_info` | *What is X and where is it used?* Hover, definition, conformances, the members the compiler wrote for a type (`[Auto-Generated]`), and references grouped by file, by name or by position |
| `references` | Every usage of a symbol, by position or by `name` (`references(name: "UserService.create(name:)")`) |
| `callers` | Actual call sites of a function, attributed to the calling function (call hierarchy) |
| `implementations` | Conforming types of a protocol (incl. extension conformances), subclasses, overriding/witnessing members |
| `type_at` | The type of the value or declaration at a position, and where that type is defined |
| `outline` | Indented outline of a file: types, extensions, members, line ranges; `synthesized` adds the members the compiler writes for its types |
| `search_symbol` | Workspace symbol search with `kind`, `path` and `scope` filters; production code ranks before tests |
| `hover`, `definition` | Position-based: 1-indexed `line`, plus a UTF-16 `column` or `symbol` (the identifier's text on that line) |
| `diagnostics` | Compiler errors and warnings for a file, with a hint when they look like missing build settings |
| `workspace` | Which directory is navigated and why, the project kind, index state, build-settings health and whether the write tools are on |
| `verify` | *Does it build?* Runs `swift build --build-tests` (and, with `tests`, `swift test`) and reports errors with file and line |
| `affected_tests` | *Which tests exercise this?* Test functions that use a symbol or reach it through calls, and the `swift test --filter` for them |

Names carry Swift argument labels (`create(name:)`). A bare `create` works unless overloads make it ambiguous;
`Type.member` and `Outer.Inner.member` are accepted, and so are Objective-C selectors (`incrementBy:` finds
`increment(by:)`). `symbol_info`, `callers` and `implementations` also accept `file_path` + `line` + `symbol` in place
of a name, which resolves locals, overloads that share labels, and SDK types such as `String` through the type
checker. `file_path` may be relative to the workspace, `../Sibling/...` or absolute. Failures (bad input, ambiguous
or unknown names, server errors) are returned with MCP `isError` set.

## Editing (opt-in)

An agent that edits with text replacement finds out what it broke later. These tools turn an edit into something the
compiler has already looked at: the change is shown to sourcekit-lsp **in memory**, compiled, compared with the
diagnostics from before, and written only if it introduces no new errors. Off by default; enable them with
`CODENAV_SWIFT_WRITE=1` in the server's environment (`claude mcp add codenav-swift --scope user -e CODENAV_SWIFT_WRITE=1 -- codenav-swift-mcp`).

| Tool | What it does |
| --- | --- |
| `rename_symbol` | Renames through the type checker (overloads, witnesses, overrides, labels). Rejects keywords, wrong label counts and collisions, then lists what a rename can't follow: the name left in comments and strings, Codable keys that would change, Objective-C exposure. `keep_deprecated_alias` leaves a deprecated forwarding declaration: a function that calls the new one, a property that forwards, or a `typealias` for a type |
| `change_signature` | Adds, removes, reorders, retypes or re-defaults parameters **and rewrites every call site** (trailing closures included, while the closure stays last); overrides and protocol witnesses change with it, and a witness pulls in the requirement it implements |
| `edit_symbol` | Replaces a declaration, or only its body, addressed by name: no text to quote, no wrong overload |
| `insert_member` | Adds a member to a type or extension (`first`, `last`, `after:x`, `before:x`), or a top-level declaration, indented like its neighbours |
| `delete_symbol`, `move_symbol` | Delete refuses while anything still uses the symbol and lists the usages; move carries the doc comment to another file (top-level declarations, with only the imports they need) or into another type (`to_container`, members) |
| `add_conformance` | `extension T: P` (or inline) with the compiler's stubs, re-indented, returning stubs as `fatalError` so it compiles |
| `fix_diagnostics` | Applies the compiler's own fix-its in a file, re-checking between rounds |
| `refactor` | sourcekit-lsp's Extract Method / Expression, Convert to Async, Memberwise Init... with tidy indentation and your name for the result |
| `apply_edit`, `check_edit` | General text edits (replace, line ranges, create, delete; several files at once, all or nothing). `check_edit` is the dry run |
| `undo_edit` | Puts back what an earlier edit changed (refuses if the files were edited since, unless `force`) |

Every one of them takes `dry_run`, `require` (`no_new_errors` by default, or `none`) and `verify` (`auto`, `build`, `none`).

```text
> rename_symbol(name: "UserStore.save(_:)", new_name: "persist")

rename_symbol UserStore.save(_:) → persist(_:): applied as e2 (4 file(s) written).
  Sources/SampleKit/Ports.swift: +1 −1
  Sources/SampleKit/Stores.swift: +1 −1
  Sources/SampleKit/UserService.swift: +2 −2
  Tests/SampleKitTests/UserServiceTests.swift: +1 −1
Compile check (sourcekit-lsp, in memory, 3 file(s)): ✓ no new errors
Not checked in memory: 1 file(s) in modules that depend on a changed module (Tests/SampleKitTests/UserServiceTests.swift): ...
Note: it is a protocol requirement: conforming types' implementations were renamed with it
Build (swift build --build-tests, 1.3s): ✓ succeeded
Undo with undo_edit(id: "e2").
```

A change that breaks something is refused, with the errors and their fix-its, and nothing is written:

```text
> change_signature(name: "UserStore.save(_:)", operations: [{op: "add", param: "overwrite: Bool"}])

Can't change the signature: parameter 'overwrite' has no default value, so give `call_value` ...

> apply_edit(file_path: "Sources/SampleKit/Ports.swift", old_text: "func save(_ user: User) async throws",
             new_text: "func save(_ user: User, overwrite: Bool) async throws")

apply_edit: NOT applied. The change introduces 3 compile error(s); no file was modified.
Compile check (sourcekit-lsp, in memory, 3 file(s)): ✗ 3 new error(s)
  Sources/SampleKit/Stores.swift:1:14 error: Type 'InMemoryUserStore' does not conform to protocol 'UserStore'
  Sources/SampleKit/UserService.swift:12:28 error: Missing argument for parameter 'overwrite' in call
      fix-it: Insert ', overwrite: '
```

### What "checked" means

The check has two tiers, and every result says which ones ran:

1. **In memory (sourcekit-lsp).** The edited files and every file in the same module that mentions a changed
   declaration are compiled with the proposal in place, before and after; only *new* errors count. On the fixtures it
   takes a fraction of a second to a couple of seconds once the server is warm. A new file can't be judged until it exists, so it is written and checked right after, and
   the whole change is rolled back if it has errors.
2. **A real build.** sourcekit-lsp cannot see an in-memory change across module boundaries, so files in modules that
   depend on a changed one (the app, the tests) are *not* judged in memory; instead the package is built after
   writing (`verify=auto`). If the build adds errors, every file is put back. Errors that were already there are
   recognised and don't block. `check_edit verify=build` does the same in a temporary write that is always undone.

### Xcode projects

With a `buildServer.json` from xcode-build-server, the second tier is `xcodebuild build-for-testing` (falling back to
`build` for a scheme without a test action) on the scheme in that file, with the project's own DerivedData, so builds are
incremental and keep the index store current. Module boundaries come from the `.SwiftFileList` of each target in that build;
a file is left to the build when it imports a module the edit changed. Tried on a real app with a local package
(`rename_symbol` on a protocol requirement across the package, the app and its tests: about 5 s for the build).

* Close Xcode's own build while an edit runs: both use the same DerivedData.
* Test targets of a local package that the scheme doesn't build (`swift test` only) are not compiled by this tier.
  Idea for later: an opt-in text-based fallback for `rename_symbol` that renames whole-word mentions in those
  files (today they are only listed under "Needs a look"); it needs care not to touch unrelated same-named symbols.
* `verify tests=true` on an Xcode project runs `xcodebuild test-without-building` on a simulator (macOS for Mac schemes); `filter` takes an `-only-testing` identifier.

Limits worth knowing:

* While a file has type errors, the Swift compiler skips flow analysis (missing returns, uninitialized variables), so
  a check on a file that already had errors is incomplete; the result says so. For the declarations an edit touched,
  a small heuristic looks for the commonest case (a function that returns a value but has an empty body or no
  `return`) and lists what it finds as *possible* problems; it can't replace the compiler, and it doesn't look for
  uninitialized variables.
* Files changed on disk while a build checks a proposal are never overwritten when the proposal is put back (they are listed
  instead), and a proposal stranded by a crashed server is restored and reported the next time a tool runs.
  Tool calls take a reader/writer lock, so reads never see a proposal that is still being checked, and cancelling a call
  stops its language-server request or build.
* A new Swift file in an Xcode project that no target contains yet is written but not compile-checked (the result says
  so); add it to a target, or use a synchronized folder, and run `verify`.
* `fix_diagnostics` takes the fix-it the compiler marks as preferred and skips "force unwrap" fix-its unless `only` asks for them.
* Diagnostics are compared by severity and message, not by line text, so an error that was already there is never
  reported as new, at the cost of not noticing an identical error added next to it.
* `change_signature` warns when an argument it drops from a call looks like a call (its side effects stop happening).
* The loose (indentation-insensitive) `old_text` match never touches a multiline string literal; copy that text exactly.
* `change_signature` leaves a function used as a value (`map(service.create)`), a trailing closure that the change
  would have to move into the parentheses, and calls it can't match to the old parameters, for you; each is listed.
* If the language server can't analyze a file at all (broken build settings), the change is reported **not verified**
  and refused rather than waved through. `workspace` shows why.
* `undo_edit` history is kept on disk (in the temporary directory, per workspace, the last 25 edits, at most 64 MB), so it survives a
  restart of the server, but not clearing temp files; git remains the real safety net.
* Edits are limited to the workspace and its local packages; dependency checkouts and build products are refused.
* File modes, `\r\n` line endings and a leading byte-order mark are preserved.

## Requirements

* macOS 13 or later.
* A Swift toolchain at runtime (Xcode or one from [swift.org](https://www.swift.org/install/)). It ships `sourcekit-lsp`,
  which codenav finds with `xcrun`, then `PATH`, then the usual install locations. Swift 6.3 or newer is recommended;
  older sourcekit-lsp versions answer some queries with less detail.
* Swift 6.2 or newer (Xcode 26+) only to build from source. The prebuilt binaries need no compiler.
* Swift packages work out of the box. Xcode projects need a `buildServer.json`; see [Xcode projects](#xcode-projects).

## Installation

### Homebrew (recommended)

```bash
brew install illescasDaniel/tap/codenav-swift-mcp
```

This installs a prebuilt binary (arm64 or Intel, picked automatically) with no compiler
needed, and puts `codenav-swift-mcp` on your `PATH`. Update it with `brew upgrade codenav-swift-mcp`; `codenav-swift-mcp --version` shows what is installed. The binaries are
the same ones attached to each [GitHub release](https://github.com/illescasDaniel/codenav-swift-mcp/releases).

### Build from source

Needs Swift 6.2 or newer (Xcode 26+). Build the server once:

```bash
git clone https://github.com/illescasDaniel/codenav-swift-mcp.git
```

```bash
cd codenav-swift-mcp && swift build -c release
```

The binary is `.build/release/codenav-swift-mcp`. Keep that absolute path handy for the client configuration below.
`pwd` inside the clone prints the directory to put in front of it.

The examples below use `codenav-swift-mcp`, which works after a Homebrew install. For a source build, replace it with
the absolute path to the binary. Apps that don't inherit your shell's `PATH` (Cursor, for example) need the absolute
path either way: `$(brew --prefix)/bin/codenav-swift-mcp`, typically `/opt/homebrew/bin/codenav-swift-mcp`.

### Claude Code

Register it for every project (`--scope user`):

```bash
claude mcp add codenav-swift --scope user -- codenav-swift-mcp
```

Claude Code starts the server in your project directory and also sets `CLAUDE_PROJECT_DIR`, so no further
configuration is needed. Run `/mcp` inside Claude Code to check that `codenav-swift` is connected.

To share the server with a team through the repository instead, add it to the project's `.mcp.json`:

```json
{
  "mcpServers": {
    "codenav-swift": {
      "command": "codenav-swift-mcp"
    }
  }
}
```

### Cursor

Add the server to `~/.cursor/mcp.json` (all projects) or to `.cursor/mcp.json` in a project:

```json
{
  "mcpServers": {
    "codenav-swift": {
      "command": "/opt/homebrew/bin/codenav-swift-mcp",
      "env": {
        "CODENAV_SWIFT_WORKSPACE": "${workspaceFolder}"
      }
    }
  }
}
```

Cursor may start MCP servers in your home directory, so `CODENAV_SWIFT_WORKSPACE` points the server at the open
project. Without it, codenav falls back to the client's workspace roots, then lists any Swift projects it finds
instead of indexing the wrong tree. Enable the server under **Cursor Settings → MCP**.

### Other MCP clients

codenav-swift-mcp is a plain stdio server with no arguments. The workspace is chosen from `CODENAV_SWIFT_WORKSPACE`,
then the client's MCP roots (when they are the same git repository), then `CLAUDE_PROJECT_DIR`, then the current
directory. When that directory is not a Swift project, the client's roots are used. The `workspace` tool says
which directory was picked and why.

## Xcode projects

sourcekit-lsp can't read an `.xcodeproj` by itself; [xcode-build-server](https://github.com/SolaWing/xcode-build-server)
bridges the two:

```bash
brew install xcode-build-server
```

```bash
xcode-build-server config -project App.xcodeproj -scheme App
```

Then **build the scheme once in Xcode** so the index store exists. The `workspace` tool reports
`build settings: ok`, or lists what is wrong and the command to fix it.

* Put `buildServer.json` in a directory that **contains every local package** the project uses. For
  `src/App/App.xcodeproj` plus `src/Lib`, run `xcode-build-server config -project src/App/App.xcodeproj -scheme App`
  from the repository root. xcode-build-server only serves files below the directory that holds `buildServer.json`;
  for a package outside it, hover, definition and references come back empty. `workspace` flags this.
* Re-run `xcode-build-server config` after a scheme or project-layout change (a new scheme, a moved project, a new
  local package), then build once in Xcode. codenav restarts sourcekit-lsp when `buildServer.json` changes.
* A build that only relinked records no Swift compile commands; files then get fallback arguments and bogus
  "No such module" errors. `workspace` and `diagnostics` detect this; touch a Swift file and build again.

## Configuration

All optional.

| Variable | Meaning |
| --- | --- |
| `CODENAV_SWIFT_WORKSPACE` | Pin the workspace directory (absolute path); client roots are then ignored |
| `CODENAV_SWIFT_LSP` | Path to a specific `sourcekit-lsp` |
| `CODENAV_SWIFT_LSP_ARGS` | Extra arguments for it, whitespace-separated |
| `CODENAV_SWIFT_INDEX_TIMEOUT` | Seconds to wait for background indexing before answering (default 30); a notice says when results may be partial |
| `CODENAV_SWIFT_REQUEST_TIMEOUT` | Seconds an individual language-server request may take (default 60) |
| `CODENAV_SWIFT_AST` | `0` stops codenav asking the compiler for [auto-generated members](#auto-generated-members); the memberwise `init` is then worked out from the source |
| `CODENAV_SWIFT_AST_TIMEOUT` | Seconds `swiftc -print-ast` may take (default 30) |
| `CODENAV_SWIFT_WRITE` | `1` enables the [editing tools](#editing-opt-in). Off by default |
| `CODENAV_SWIFT_BUILD_TIMEOUT` | Seconds a `swift build` / `swift test` run by `verify` or an edit may take (default 600); the whole process tree is killed after that |
| `CODENAV_SWIFT_LOCAL_PACKAGE_FOLDERS` | `1` registers local sibling packages as extra language-server workspace folders. Off by default: sourcekit-lsp then builds and indexes each package on its own (slow, large `.build`) |

## How it works

codenav runs one sourcekit-lsp process per workspace and starts it as soon as the MCP client connects, so indexing
is underway before the first question. Before each call it stats the workspace and tells the server about files
created, changed or deleted on disk, so answers keep up with the agent's own edits. Workspace-wide answers wait
for background indexing, up to `CODENAV_SWIFT_INDEX_TIMEOUT`.

### Cross-package and dependency symbols

The index is thin for declarations in a sibling package or a dependency checkout. For those, `references`,
`symbol_info`, `callers` and `implementations` complete the answer with a *scan + verify* pass: every whole-word
occurrence of the name in the project and its local packages is checked with the server's `definition`, and only
those that lead back to the declaration are kept.

* A Swift file is only scanned if it imports the declaring module, or a module that re-exports it with
  `@_exported import`, or lives in that module's own `Sources/<Target>/`. This skips most candidates in large projects.
* Conformances written as `extension Dep.Type: Proto` are found the same way.
* Names the server can't resolve in a file (the file isn't part of any build target, or sits in an inactive
  `#if` branch) are listed separately under `Unverified`, never mixed into the verified results.
* Scans stop after 600 candidates, with a note. `<dependency> Pkg/...` paths shown in results are accepted as `file_path`.

### Mixed Swift / Objective-C / C++ projects

`.m`, `.mm`, `.h`, `.c` and `.cpp` files are opened with their own language id, so sourcekit-lsp's built-in clangd
serves them (with the same build settings as Swift). Calls, references and subclasses cross the language boundary
in both directions. Objective-C selectors fold to their Swift spelling (`incrementBy:` finds `increment(by:)`; a full
selector such as `loadImageWithURL:options:progress:completed:` picks an overload). For Swift methods called from
Objective-C the scan searches the `@objc(selector:)` name when there is one, else the usual `base`+`Label` spellings.
`definition` lists a header declaration before its implementation.

### Auto-generated members

Some members exist but are never written down: a struct's memberwise `init` (which is `internal` even in a `public`
struct), and the members of `Codable`, `Equatable`, `Hashable`, `RawRepresentable` and `CaseIterable`. They have no
declaration, so no outline or symbol search lists them, and an agent can't tell that `User(name:age:)` is callable.
`symbol_info` on a struct, enum or class asks the compiler (`swiftc -print-ast` over the type's module, cached until a
source file changes) and lists what it added, marked `[Auto-Generated: <why>]`:

```text
> symbol_info(name: "Person")
...
Auto-generated by the compiler (the source has no declaration for these):
  internal init(name: String, age: Int, nick: String? = nil)  [Auto-Generated: memberwise initializer]
  public func encode(to encoder: any Encoder) throws  [Auto-Generated: Encodable]
  public init(from decoder: any Decoder) throws  [Auto-Generated: Decodable]
  private enum CodingKeys : CodingKey { case name, age, nick }  [Auto-Generated: Codable]
```

`symbol_info(name: "Person.init(name:age:nick:)")` or `Person.encode(to:)` answers for such a member directly, and
`outline(synthesized: true)` adds the list for every type in a file. The compiler is only asked for types that can have
such members (a struct or class without an explicit `init`, or one that conforms to one of those protocols). Needs
`swiftc` next to the toolchain in use and, for a type that imports other modules of the package, a build so those
modules exist; when the compiler can't be used the memberwise `init` is worked out from the stored properties (asking
the language server's hover for any type the source doesn't write, such as `var count = 0`) and the answer says so. For an Xcode project only the type's own file is compiled, so types that depend on other files fall
back to that too.

## Troubleshooting

* **Empty or partial results.** Run `workspace`: it shows the chosen directory, whether indexing is still running,
  recent background-build errors (a project that doesn't compile leaves results empty), and build-settings problems
  for Xcode projects. Empty answers repeat the relevant part.
* **The first query is slow.** sourcekit-lsp builds into the workspace's `.build` on first use; on a large project
  that takes a while. Later queries are fast.
* **Wrong project.** Set `CODENAV_SWIFT_WORKSPACE` to the package or project root.
* **Rebuilt codenav-swift-mcp?** Restart the MCP client: it launches the binary once per session. codenav notices
  when its own binary changed and says so on every call until then.
* **Type aliases** are not returned by `workspace/symbol`; use `outline` or a position lookup for those.

## Development

```bash
swift build
```

```bash
swift test
```

The integration tests run a real sourcekit-lsp against [`Fixtures/SamplePackage`](Fixtures/SamplePackage) and
[`Fixtures/MixedPackage`](Fixtures/MixedPackage), and are skipped when none is installed.

## Releasing

Releases are built by GitHub Actions; the formula in the Homebrew tap is bumped by hand.

1. Set `serverVersion` in [`Sources/codenav-swift-mcp/main.swift`](Sources/codenav-swift-mcp/main.swift) and add a
   section for the version to [`CHANGELOG.md`](CHANGELOG.md). The release notes are taken from that section.
2. Commit, push, then tag and push the tag:

   ```bash
   git tag -a v0.1.2 -m "0.1.2" && git push origin v0.1.2
   ```

   The [Release workflow](.github/workflows/release.yml) checks that the tag matches `serverVersion`, builds arm64 and
   x86_64 binaries on macOS, smoke-tests each one on a matching runner, and publishes a GitHub release with the
   tarballs and their `.sha256` files.
3. Bump the formula in [illescasDaniel/homebrew-tap](https://github.com/illescasDaniel/homebrew-tap). In
   `Formula/codenav-swift-mcp.rb`, update the version in both `url`s and replace both `sha256` values with the contents
   of the release's `.sha256` files (`gh release download v0.1.2 -p '*.sha256'`). Then check and push:

   ```bash
   brew audit --strict illescasDaniel/tap/codenav-swift-mcp && brew reinstall illescasDaniel/tap/codenav-swift-mcp && brew test codenav-swift-mcp
   ```

   Users get the new version with `brew upgrade codenav-swift-mcp`. If the tap clone on your machine is stale, run
   `git -C "$(brew --repository illescasDaniel/tap)" pull` first.

The release builds with the Xcode version pinned in the workflow (`xcode-select` step); update it when GitHub's
`macos-*` images drop that Xcode. Hosted runners may lag behind the Swift version you develop with.

## Author

Created by **Daniel Illescas Romero** ([contact@daniel-ir.eu](mailto:contact@daniel-ir.eu)).
Bug reports and pull requests are welcome on [GitHub](https://github.com/illescasDaniel/codenav-swift-mcp/issues).

## License

[MIT](LICENSE) © 2026 Daniel Illescas Romero
