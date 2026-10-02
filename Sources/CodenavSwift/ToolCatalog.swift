import Foundation
import NavShared

/// Transport-agnostic description of one MCP tool.
public struct ToolSpec: Sendable {
	public struct Parameter: Sendable {
		public enum Kind: String, Sendable { case string, integer, boolean, array }
		public var name: String
		public var kind: Kind
		public var description: String
		public var required: Bool
	}

	public var name: String
	public var description: String
	public var parameters: [Parameter]
}

/// Lenient argument access: models often send numbers as strings or booleans as "true".
public struct ToolArguments: Sendable {
	public var values: [String: JSONValue]

	public init(_ values: [String: JSONValue]) {
		self.values = values
	}

	public func string(_ key: String) -> String? {
		guard let value = values[key] else { return nil }
		switch value {
		case .string(let text): return text.isEmpty ? nil : text
		case .null: return nil
		default: return nil
		}
	}

	/// Optional integer: absent or null is nil; a present value that isn't an integer is an error.
	public func optionalInt(_ key: String) throws -> Int? {
		guard let value = values[key], value != .null else { return nil }
		if case .string(let text) = value, text.trimmingCharacters(in: .whitespaces).isEmpty { return nil }
		return try int(key)
	}

	public func int(_ key: String) throws -> Int {
		guard let value = values[key], value != .null else { throw ToolInputError("Missing required parameter '\(key)'.") }
		if let number = value.intValue { return number }
		if case .string(let text) = value, let number = Int(text.trimmingCharacters(in: .whitespaces)) { return number }
		throw ToolInputError("Parameter '\(key)' must be an integer.")
	}

	public func requiredString(_ key: String) throws -> String {
		guard let text = string(key) else { throw ToolInputError("Missing required parameter '\(key)'.") }
		return text
	}

	public func bool(_ key: String, default fallback: Bool) -> Bool {
		guard let value = values[key] else { return fallback }
		if case .bool(let flag) = value { return flag }
		if case .string(let text) = value {
			switch text.lowercased() {
			case "true", "1", "yes": return true
			case "false", "0", "no": return false
			default: break
			}
		}
		return fallback
	}
}

public enum ToolCatalog {
	static let positionNote =
		"Positions are 1-indexed. `column` is a UTF-16 character offset on the line (not a visual/display column): "
		+ "a leading tab counts as one character, so after a single tab the next character starts at column 2."

	public static let instructions =
		"Code navigation for this Swift codebase, backed by sourcekit-lsp (the same engine as Xcode's index). "
		+ "Prefer this over grepping for symbol definitions/usages: it resolves through the type checker "
		+ "(overloads, protocol witnesses, extensions, inferred types), not just text matching. "
		+ "Swift files, plus the Objective-C/C/C++ sources of a mixed project (.m, .mm, .h, .c, .cpp). Symbol names carry argument labels, e.g. `create(name:)`; a bare `create` "
		+ "works unless overloads make it ambiguous, in which case the candidates are listed. "
		+ "Start with symbol_info (what is X, where is it used) or outline (what's in this file) rather than "
		+ "chaining search_symbol → hover → definition → references by hand; drop to the position tools once "
		+ "you have a specific line to inspect. The first query after startup can take a while if the project "
		+ "is still being indexed; results note when the index was incomplete. Xcode projects need a "
		+ "buildServer.json (see `workspace`). Everywhere a `column` is asked for you can pass `symbol` (the identifier's "
		+ "text on that line) instead. symbol_info/callers/implementations also work from a position "
		+ "(`file_path` + `line` + `symbol`) when a name is ambiguous or the symbol is local. " + positionNote

	/// Added to the server instructions when the write tools are enabled.
	public static let writeInstructions =
		"Editing tools (compiler-checked): prefer them over blind text edits. Every one shows its change to sourcekit-lsp in memory first, "
		+ "refuses to write it when it introduces compile errors, and can be undone with undo_edit. "
		+ "To change what a symbol is called use rename_symbol; to add/remove/reorder parameters use change_signature (it rewrites the call sites); "
		+ "to rewrite a function or its body use edit_symbol (by name, no text to quote); to add a member use insert_member; to remove or move a declaration use "
		+ "delete_symbol / move_symbol; to satisfy a protocol use add_conformance; for compiler suggestions use fix_diagnostics; for sourcekit refactorings use refactor; "
		+ "apply_edit is the general text edit, check_edit its dry run. Code in other modules is only compiled by `verify` (the write tools run it automatically when needed); "
		+ "the result says what was and wasn't checked. When an edit is refused, the errors listed are the ones to fix, then retry."

	private static func p(_ name: String, _ kind: ToolSpec.Parameter.Kind, _ description: String, required: Bool = false)
		-> ToolSpec.Parameter
	{
		.init(name: name, kind: kind, description: description, required: required)
	}

	private static let filePath = p("file_path", .string, "Path to the source file (.swift, or .m/.mm/.h/.c/.cpp in a mixed project), relative to the workspace root (or absolute).", required: true)
	private static let line = p("line", .integer, "1-indexed line.", required: true)
	private static let column = p(
		"column", .integer, "1-indexed UTF-16 column. Optional when `symbol` is given.")
	private static let symbolOnLine = p(
		"symbol", .string,
		"Alternative to `column`: the identifier's text on `line` (first whole-word occurrence), so no column counting is needed.")
	private static let optionalLine = p(
		"line", .integer,
		"1-indexed line. With `file_path` and `column`/`symbol` this selects the symbol by position instead of by name; "
			+ "with `name` it picks the overload declared on that line.")
	private static let optionalFile = p(
		"file_path", .string, "Disambiguating file, or the file `line` refers to (relative to the workspace, `../Sibling/...` or absolute).")
	private static let positionTargets = [optionalLine, column, symbolOnLine]

	public static let readTools: [ToolSpec] = [
		ToolSpec(
			name: "workspace",
			description:
				"Which directory is codenav navigating, and why? Also reports the project kind (SwiftPM / Xcode) and index state. Use when results look like they come from the wrong checkout/worktree, or empty. For Xcode projects it also checks buildServer.json health and says when to restart the MCP client (after rebuilding this server) or re-run `xcode-build-server config` (after a scheme/project layout change).",
			parameters: []),
		ToolSpec(
			name: "hover",
			description: "Get type/documentation info for the symbol at a position. " + positionNote,
			parameters: [filePath, line, column, symbolOnLine]),
		ToolSpec(
			name: "definition",
			description: "Go to the definition of the symbol at a position. " + positionNote,
			parameters: [filePath, line, column, symbolOnLine]),
		ToolSpec(
			name: "references",
			description:
				"Find all usages of a symbol across the workspace (and, for dependency symbols, the packages that use them). "
				+ "Give a position (`file_path` + `line` + `column`/`symbol`) or just a `name` like symbol_info does "
				+ "(`references(name=\"UserService.create(name:)\")`). " + positionNote,
			parameters: [
				optionalFile, optionalLine, column, symbolOnLine,
				p("name", .string, "Symbol name, or dotted `Type.member`; an alternative to a position."), p("query", .string, "Alias for name."),
				p("include_declaration", .boolean, "Include the declaration itself (default true)."),
			]),
		ToolSpec(
			name: "search_symbol",
			description:
				"Search the whole workspace for a symbol by name (type, function, method, property, ...). "
				+ "Use this to find a symbol's file/position first, then pass it to definition/references/hover. "
				+ "Returned positions point at the identifier. `name` is accepted as an alias for `query`; `Type.member` is accepted. "
				+ "Narrow broad queries with `kind` (SymbolKind labels, comma-separated: `class`, `struct`, `protocol`, `function,method`, ...) "
				+ "and `path` (workspace-relative prefix such as `Sources/`, or a glob). Production code ranks before tests. "
				+ "Loose fuzzy hits whose names don't contain the query are summarised as a count; pass `fuzzy=true` to list them.",
			parameters: [
				p("query", .string, "Symbol name to search for."), p("name", .string, "Alias for query."),
				p("kind", .string, "Comma-separated SymbolKind labels."), p("path", .string, "Path prefix or glob filter."),
				p("fuzzy", .boolean, "List loose fuzzy matches too."),
				p("scope", .string, "`project` (own code only), `dependencies` (pods, package checkouts, SDK headers only) or `all`. Default: project code first, then at most 10 dependency hits."),
			]),
		ToolSpec(
			name: "diagnostics",
			description: "Compiler errors and warnings for a source file.",
			parameters: [filePath]),
		ToolSpec(
			name: "symbol_info",
			description:
				"What is X and where is it used? Example: `symbol_info(name=\"UserService.create(name:)\")`. "
				+ "One-call summary: header, hover text, definition, what a type inherits/conforms to, and references grouped by file. "
				+ "`name` is a symbol name, or dotted `Type.member`; add argument labels to pick one overload. "
				+ "Pass `file_path` to disambiguate; if still ambiguous the candidates are listed. `query` is an alias for `name`.",
			parameters: [
				p("name", .string, "Symbol name."), p("query", .string, "Alias for name."),
				optionalFile, optionalLine, column, symbolOnLine,
				p("include_references", .boolean, "Include grouped references (default true)."),
			]),
		ToolSpec(
			name: "outline",
			description:
				"What's in this file? Indented outline (types, extensions, methods, properties, with line numbers) of a source file. "
				+ "Follow up with hover/definition/references at a listed line, or symbol_info by name.",
			parameters: [filePath]),
		ToolSpec(
			name: "callers",
			description:
				"Who calls this function? Example: `callers(name=\"create(name:)\")`. Narrower than references: only actual call sites. "
				+ "`name` resolves like symbol_info; `query` is an alias.",
			parameters: [
				p("name", .string, "Function/method name."), p("query", .string, "Alias for name."),
				optionalFile, optionalLine, column, symbolOnLine,
			]),
		ToolSpec(
			name: "implementations",
			description:
				"Who implements this? For a protocol: every conforming type (including extension conformances) and refinements; "
				+ "for a class: its subclasses; for a method/property: the overriding or witnessing implementations. "
				+ "`name` resolves like symbol_info; `port_name` and `query` are aliases.",
			parameters: [
				p("name", .string, "Protocol/class/member name."), p("query", .string, "Alias for name."),
				p("port_name", .string, "Alias for name."), optionalFile, optionalLine, column, symbolOnLine,
			]),
		ToolSpec(
			name: "type_at",
			description:
				"What type is this value? The type of the expression or declaration at a position (`file_path` + `line` + `column` "
				+ "or `symbol`), with where that type is defined. Use for inferred `let`/`var`s, closure parameters and call results. "
				+ positionNote,
			parameters: [filePath, line, column, symbolOnLine]),
	]

	/// Tools that run the compiler or the tests: they change no source, but they do build.
	public static let analysisTools: [ToolSpec] = [
		ToolSpec(
			name: "verify",
			description:
				"Does the project build? Runs the real compiler (`swift build --build-tests` for a SwiftPM package) and reports errors with file and line, "
				+ "which also covers what the language server can't see: other modules that depend on a changed one. Use it after edits made by other means, "
				+ "or before relying on the write tools' in-memory check across modules. `tests` also runs `swift test` (optionally narrowed by `filter`, a regex on test names).",
			parameters: [
				p("tests", .boolean, "Also run the tests after a successful build."),
				p("filter", .string, "With tests: regex on test names (`swift test --filter`)."),
			]),
		ToolSpec(
			name: "affected_tests",
			description:
				"Which tests exercise this? Finds the test functions that use a symbol or reach it through calls (up to `depth` levels), "
				+ "and gives the `swift test --filter` command that runs just those; `run` runs it. Use it after a change instead of running the whole suite.",
			parameters: symbolTarget + [
				p("depth", .integer, "How many call levels to follow from the symbol up to a test (default 3)."),
				p("run", .boolean, "Run those tests."),
			]),
	]

	public static var analysisToolNames: Set<String> { Set(analysisTools.map(\.name)) }

	/// Every tool: read-only, analysis and writing.
	public static var tools: [ToolSpec] { readTools + analysisTools + writeTools }

	/// Names of the tools that change files; they are only offered when writing is enabled.
	public static var writeToolNames: Set<String> { Set(writeTools.map(\.name)) }

	public static let writeEnvironmentKey = "CODENAV_SWIFT_WRITE"

	static let editOptions = [
		p("require", .string, "`no_new_errors` (default): refuse to write when the compile check finds new errors. `none`: write regardless and just report."),
		p("verify", .string, "Whole-project check after writing: `auto` (default: run the build only when files in other modules use a changed name), `build` (always), `none`."),
		p("dry_run", .boolean, "Compile-check and show the diff, but write nothing."),
	]

	static let writeIntro =
		"Compiler-checked edit: the change is shown to sourcekit-lsp in memory first, and is written only when it introduces no new compile errors "
		+ "(diagnostics before vs after, in the edited files and every file in the module that uses a changed name). The result lists new errors with fix-its, "
		+ "a diff, and an id for undo_edit. "

	public static let writeTools: [ToolSpec] = symbolEditTools + [renameTool] + fixTools + [
		ToolSpec(
			name: "check_edit",
			description:
				"What would happen if I made this change? Same input as apply_edit, but never writes: returns the compile-check result and the diff. "
				+ "Use it to try a risky change, or to see the errors it would cause, before committing to it. " + editSpecNote,
			parameters: editParameters(includingOptions: false)),
		ToolSpec(
			name: "apply_edit",
			description:
				writeIntro + "Replaces text, replaces or inserts lines, creates or deletes files, in one or several files at once (all or nothing). " + editSpecNote,
			parameters: editParameters(includingOptions: true)),
		ToolSpec(
			name: "undo_edit",
			description:
				"Undo an edit made by one of the write tools in this session (the newest one by default). Refuses when the files were changed since, unless `force`. `list` shows the applied edits.",
			parameters: [
				p("id", .string, "Edit id from the write tool's result, e.g. `e3`. Default: the newest edit."),
				p("list", .boolean, "List the applied edits instead of undoing one."),
				p("force", .boolean, "Restore even if the files were edited after the change (discards those later edits)."),
			]),
	]

	static let symbolTarget = [
		p("name", .string, "Symbol name, e.g. `UserService.create(name:)` (labels pick an overload; `Type.member` qualifies)."),
		optionalFile, optionalLine, column, symbolOnLine,
	]

	static let symbolEditTools: [ToolSpec] = [
		ToolSpec(
			name: "edit_symbol",
			description:
				writeIntro
				+ "Change a declaration addressed by NAME, with no text to quote: `new_source` replaces the whole declaration (signature, attributes and body; "
				+ "a leading doc comment in it replaces the old one), `new_body` replaces what is between the body's braces (pass the statements without the braces), "
				+ "`old_text`+`new_text` replaces text inside this declaration only. Indentation is adjusted to the file. "
				+ "Example: `edit_symbol(name=\"UserService.create(name:)\", new_body=\"return try await store.save(User(...))\")`.",
			parameters: symbolTarget + [
				p("new_source", .string, "Complete replacement for the declaration."),
				p("new_body", .string, "Replacement for the body's contents (statements, without the surrounding braces)."),
				p("old_text", .string, "Text inside the declaration to replace (must match once)."),
				p("new_text", .string, "Replacement for old_text."),
				p("replace_all", .boolean, "With old_text: replace every occurrence inside the declaration."),
			] + editOptions),
		ToolSpec(
			name: "insert_member",
			description:
				writeIntro
				+ "Add a declaration to a type or extension (`container`), or at the top level of a file (`file_path` without `container`). "
				+ "`position`: `last` (default), `first`, `after:<member>` or `before:<member>`. The code is indented to match its neighbours, "
				+ "with blank lines where the file's style has them. Example: `insert_member(container=\"UserService\", code=\"func delete(id: User.ID) async throws { ... }\", position=\"after:find(id:)\")`.",
			parameters: [
				p("container", .string, "The type (or `Type`, resolved like `name`) to add the member to."),
				p("code", .string, "The declaration(s) to add.", required: true),
				p("position", .string, "`last` (default), `first`, `after:<member>` or `before:<member>`."),
				p("file_path", .string, "With no `container`: the file to add a top-level declaration to. With `container`: disambiguates it."),
				optionalLine, symbolOnLine,
			] + editOptions),
		ToolSpec(
			name: "delete_symbol",
			description:
				writeIntro
				+ "Delete a declaration with its doc comment. Refuses while anything still uses it and lists the usages, so nothing is left dangling; "
				+ "`force` deletes anyway so the compile check shows what breaks. Example: `delete_symbol(name=\"UserService.find(id:)\")`.",
			parameters: symbolTarget + [p("force", .boolean, "Delete even though usages remain.")] + editOptions),
		ToolSpec(
			name: "move_symbol",
			description:
				writeIntro
				+ "Move a top-level declaration (with its doc comment) to another file, creating the file when needed and carrying over the imports. "
				+ "Example: `move_symbol(name=\"Dog\", to_file=\"Sources/SampleKit/Dog.swift\")`.",
			parameters: symbolTarget + [
				p("to_file", .string, "Destination file (created when it doesn't exist).", required: true),
				p("position", .string, "Where in an existing destination: `last` (default), `first`, `after:<symbol>`, `before:<symbol>`."),
			] + editOptions),
	]

	static let renameTool = ToolSpec(
		name: "rename_symbol",
		description:
			writeIntro
			+ "Rename a symbol everywhere it is used, through the type checker (overloads, protocol witnesses and overrides, extensions, labels), not text matching. "
			+ "`new_name` is the base name (`make`, which keeps the labels) or the full name with labels (`make(named:)`, `make(_:to:)`); "
			+ "the number of labels can't change (use change_signature for that). Checks the name (keywords, validity, collisions in the same scope), "
			+ "then lists what a rename can't follow: the old name left in comments and strings, Codable keys that would change, Objective-C/runtime exposure, public API. "
			+ "`keep_deprecated_alias` leaves a deprecated forwarding function under the old name. Example: `rename_symbol(name=\"UserService.create(name:)\", new_name=\"make(named:)\")`.",
		parameters: symbolTarget + [
			p("new_name", .string, "The new name: `make` or `make(named:)`.", required: true),
			p("keep_deprecated_alias", .boolean, "For functions and methods: keep the old name as a deprecated function that calls the new one."),
		] + editOptions)

	static let fixTools: [ToolSpec] = [
		ToolSpec(
			name: "change_signature",
			description:
				writeIntro
				+ "Change a function's, method's or initializer's parameters AND every call site, found through the type checker; overrides and protocol witnesses change with it. "
				+ "`operations` is a list: {op:\"add\", param:\"overwrite: Bool = false\", position:\"last\"|\"first\"|\"before:x\"|\"after:x\", call_value:\"false\"} "
				+ "(call_value is what existing callers pass; optional when the parameter has a default), {op:\"remove\", param:\"flag\"}, {op:\"reorder\", order:[\"b\",\"a\"]}, "
				+ "{op:\"retype\", param:\"x\", type:\"Int\"}, {op:\"default\", param:\"x\", value:\"3\"} (omit value to drop the default). "
				+ "Calls it can't rewrite safely (a trailing closure, a function used as a value) are listed for you; uses of a removed parameter inside the body show up in the compile check. "
				+ "To only rename labels use rename_symbol.",
			parameters: symbolTarget + [
				p("operations", .array, "List of operations (see the tool description)."),
				p("op", .string, "Single-operation shorthand: add, remove, retype or default."),
				p("param", .string, "Single-operation shorthand: the parameter (for `add`: its declaration)."),
				p("type", .string, "Single-operation shorthand for `retype`."),
				p("value", .string, "Single-operation shorthand for `default`."),
				p("position", .string, "Single-operation shorthand for `add`."),
				p("call_value", .string, "Single-operation shorthand for `add`."),
			] + editOptions),
		ToolSpec(
			name: "fix_diagnostics",
			description:
				writeIntro
				+ "Apply the compiler's own fix-its in a file (missing `case`s in a switch, `var` → `let`, missing labels, `override`, protocol stubs...), "
				+ "re-indented to the file's style; repeats up to `rounds` times as fixing one thing reveals the next. `only` narrows to diagnostics containing that text, "
				+ "`line` to one line. Diagnostics without a fix-it are listed, not guessed at. Example: `fix_diagnostics(file_path=\"Sources/App/Store.swift\", only=\"exhaustive\")`.",
			parameters: [
				p("file_path", .string, "The file to fix.", required: true),
				p("only", .string, "Only diagnostics whose message or code contains this text."),
				p("line", .integer, "Only diagnostics on this 1-indexed line."),
				p("rounds", .integer, "Maximum rounds of fix-then-recompile (default 3)."),
			] + editOptions),
		ToolSpec(
			name: "refactor",
			description:
				writeIntro
				+ "Run one of sourcekit-lsp's refactorings: Extract Method, Extract Expression, Extract Repeated Expression, Convert Function to Async, Generate Memberwise Initializer, "
				+ "Add Equatable conformance... Select the code with `line` (+`end_line`) and `selection` (the exact text on those lines), or `symbol`/`column`. "
				+ "Without `action` it lists what is available there. The generated code is re-indented to the file, and `new_name` replaces the default name (`extractedFunc`). "
				+ "Example: `refactor(file_path=\"Sources/A.swift\", line=11, selection=\"User(id: name.count, name: name)\", action=\"Extract Method\", new_name=\"makeUser\")`.",
			parameters: [
				p("file_path", .string, "The file.", required: true),
				p("line", .integer, "First line of the selection (1-indexed).", required: true),
				p("end_line", .integer, "Last line of the selection (default: `line`)."),
				p("selection", .string, "The exact code to select, found within those lines."),
				p("column", .integer, "1-indexed UTF-16 start column of the selection."), p("end_column", .integer, "End column."),
				symbolOnLine,
				p("action", .string, "Title (or part of it) of the refactoring to run; omit to list the available ones."),
				p("new_name", .string, "Name for what the refactoring creates (an extracted function or constant)."),
			] + editOptions),
		ToolSpec(
			name: "add_conformance",
			description:
				writeIntro
				+ "Make a type conform to a protocol: adds `extension Type: Protocol` (or, with `inline`, adds it to the type's own declaration) and has the compiler write the stubs for the missing "
				+ "requirements, indented to the file; stubs that return a value get `fatalError(\"Not implemented\")` so the code compiles and you fill them in with edit_symbol. "
				+ "Example: `add_conformance(type=\"Dog\", protocol=\"CustomStringConvertible\")`.",
			parameters: [
				p("type", .string, "The class, struct, enum or actor (resolved like `name`)."),
				p("protocol", .string, "The protocol to conform to.", required: true),
				p("inline", .boolean, "Add to the type's declaration instead of a new extension."),
				p("stubs", .boolean, "Generate stubs for the missing requirements (default true)."),
				p("extension_file", .string, "Put the extension in this file (created if needed) instead of after the type."),
				optionalFile, optionalLine, symbolOnLine,
			] + editOptions),
	]

	static let editSpecNote =
		"`edits` is a list; each entry is one of: {file_path, old_text, new_text[, replace_all]} (old_text must match exactly once; indentation differences are tolerated), "
		+ "{file_path, start_line, end_line, new_text} (replace those lines, 1-indexed inclusive; omit end_line for one line), "
		+ "{file_path, insert_after_line, new_text} (0 = top of file), {file_path, content[, overwrite]} (create a file), {file_path, delete: true}. "
		+ "Entries apply in order, each to the result of the previous ones. For a single edit you may put its fields at the top level instead of `edits`."

	static func editParameters(includingOptions: Bool) -> [ToolSpec.Parameter] {
		var parameters = [
			p("edits", .array, "List of edits (see the tool description). Each is an object with `file_path` plus the fields of one edit kind."),
			p("file_path", .string, "Single-edit shorthand: the file."),
			p("old_text", .string, "Single-edit shorthand: text to replace (must match exactly once)."),
			p("new_text", .string, "Single-edit shorthand: replacement text."),
		]
		if includingOptions { parameters += editOptions.filter { $0.name != "dry_run" } }
		return parameters
	}

	public static func call(
		_ name: String, arguments: ToolArguments, navigator: SwiftNavigator, writesEnabled: Bool = true
	) async -> ToolResult {
		if writeToolNames.contains(name), !writesEnabled {
			return ToolResult(
				"'\(name)' changes files, and writing is switched off. Set \(writeEnvironmentKey)=1 in the MCP server's environment to enable the write tools.",
				isError: true)
		}
		return await dispatch(name, arguments: arguments, navigator: navigator)
	}

	private static func dispatch(_ name: String, arguments: ToolArguments, navigator: SwiftNavigator) async -> ToolResult {
		do {
			let optionalColumn = { try arguments.optionalInt("column") }
			switch name {
			case "workspace":
				return await navigator.workspace()
			case "hover":
				return await navigator.hover(
					filePath: try arguments.requiredString("file_path"), line: try arguments.int("line"),
					column: try optionalColumn(), symbol: arguments.string("symbol"))
			case "definition":
				return await navigator.definition(
					filePath: try arguments.requiredString("file_path"), line: try arguments.int("line"),
					column: try optionalColumn(), symbol: arguments.string("symbol"))
			case "references":
				return await navigator.references(
					name: arguments.string("name"), query: arguments.string("query"), filePath: arguments.string("file_path"),
					line: try arguments.optionalInt("line"), column: try optionalColumn(), symbol: arguments.string("symbol"),
					includeDeclaration: arguments.bool("include_declaration", default: true))
			case "type_at":
				return await navigator.typeAt(
					filePath: try arguments.requiredString("file_path"), line: try arguments.int("line"),
					column: try optionalColumn(), symbol: arguments.string("symbol"))
			case "search_symbol":
				return await navigator.searchSymbol(
					query: arguments.string("query"), name: arguments.string("name"), kind: arguments.string("kind"),
					path: arguments.string("path"), fuzzy: arguments.bool("fuzzy", default: false),
					scope: arguments.string("scope"))
			case "diagnostics":
				return await navigator.diagnostics(filePath: try arguments.requiredString("file_path"))
			case "symbol_info":
				return await navigator.symbolInfo(
					name: arguments.string("name"), query: arguments.string("query"), filePath: arguments.string("file_path"),
					line: try arguments.optionalInt("line"), column: try optionalColumn(), symbol: arguments.string("symbol"),
					includeReferences: arguments.bool("include_references", default: true))
			case "outline":
				return await navigator.outline(filePath: try arguments.requiredString("file_path"))
			case "callers":
				return await navigator.callers(
					name: arguments.string("name"), query: arguments.string("query"), filePath: arguments.string("file_path"),
					line: try arguments.optionalInt("line"), column: try optionalColumn(), symbol: arguments.string("symbol"))
			case "implementations":
				return await navigator.implementations(
					name: arguments.string("name"), query: arguments.string("query"), portName: arguments.string("port_name"),
					filePath: arguments.string("file_path"), line: try arguments.optionalInt("line"),
					column: try optionalColumn(), symbol: arguments.string("symbol"))
			case "check_edit":
				return await navigator.editFiles(arguments: arguments, dryRun: true)
			case "apply_edit":
				return await navigator.editFiles(arguments: arguments, dryRun: false)
			case "verify":
				return await navigator.verify(tests: arguments.bool("tests", default: false), filter: arguments.string("filter"))
			case "affected_tests":
				return await navigator.affectedTests(arguments: arguments)
			case "change_signature":
				return await navigator.changeSignature(arguments: arguments)
			case "fix_diagnostics":
				return await navigator.fixDiagnostics(arguments: arguments)
			case "refactor":
				return await navigator.refactor(arguments: arguments)
			case "add_conformance":
				return await navigator.addConformance(arguments: arguments)
			case "rename_symbol":
				return await navigator.renameSymbol(arguments: arguments)
			case "edit_symbol":
				return await navigator.editSymbol(arguments: arguments)
			case "insert_member":
				return await navigator.insertMember(arguments: arguments)
			case "delete_symbol":
				return await navigator.deleteSymbol(arguments: arguments)
			case "move_symbol":
				return await navigator.moveSymbol(arguments: arguments)
			case "undo_edit":
				return await navigator.undoEdit(
					id: arguments.string("id"), list: arguments.bool("list", default: false), force: arguments.bool("force", default: false))
			default:
				return ToolResult("Unknown tool '\(name)'.", isError: true)
			}
		} catch let error as ToolInputError {
			return ToolResult(formatToolError(error), isError: true)
		} catch {
			return ToolResult("Error: \(error)", isError: true)
		}
	}
}
