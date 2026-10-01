import Foundation
import NavShared

/// Transport-agnostic description of one MCP tool.
public struct ToolSpec: Sendable {
	public struct Parameter: Sendable {
		public enum Kind: String, Sendable { case string, integer, boolean }
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

	public static let tools: [ToolSpec] = [
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

	public static func call(_ name: String, arguments: ToolArguments, navigator: SwiftNavigator) async -> ToolResult {
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
