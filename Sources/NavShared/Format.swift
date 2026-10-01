import Foundation

// Formatting helpers for tool responses: locations with snippets, ranked symbol lists,
// diagnostics, outlines, call sites. Everything is plain text meant for an agent to read.

// MARK: - Symbol kinds

/// LSP `SymbolKind` values, labelled the way Swift programmers say them: sourcekit-lsp reports
/// protocols as `Interface`, extensions as `Namespace`, and typealiases as `TypeParameter`.
public enum SymbolKind {
	public static let labels: [Int: String] = [
		0: "Symbol",
		1: "File", 2: "Module", 3: "Extension", 4: "Package", 5: "Class", 6: "Method", 7: "Property", 8: "Field",
		9: "Initializer", 10: "Enum", 11: "Protocol", 12: "Function", 13: "Variable", 14: "Constant", 15: "String",
		16: "Number", 17: "Boolean", 18: "Array", 19: "Object", 20: "Key", 21: "Null", 22: "Case", 23: "Struct",
		24: "Event", 25: "Operator", 26: "TypeAlias",
	]

	public static let `class` = 5, method = 6, property = 7, field = 8, initializer = 9, enumeration = 10
	public static let `protocol` = 11, function = 12, variable = 13, constant = 14, enumCase = 22, structure = 23
	public static let extensionKind = 3

	/// Kinds that declare a type (things other types can inherit from or conform to).
	public static let types: Set<Int> = [5, 10, 11, 23]
	/// Kinds that live inside a type.
	public static let members: Set<Int> = [6, 7, 8, 9, 22]

	/// Extra spellings accepted by `parseKindFilter` on top of the labels above.
	static let aliases: [String: Int] = [
		"interface": 11, "enummember": 22, "typeparameter": 26, "constructor": 9, "init": 9, "namespace": 3,
	]

	public static func label(_ kind: Int?) -> String {
		guard let kind else { return "?" }
		return labels[kind] ?? "Kind\(kind)"
	}
}

public let defaultSearchSymbolLimit = 50
public let defaultDiagnosticsLimit = 200
public let defaultReferenceFileLimit = 25
public let defaultReferencesSnippetLimit = 8

// MARK: - URIs and files

/// The local path a `file:` URI points at (nil for other schemes).
public func uriToPath(_ uri: String) -> String? {
	guard let url = URL(string: uri), url.isFileURL else { return nil }
	return url.path
}

/// Workspace-relative path for a URI; `../sibling/...` for a nearby local package; absolute otherwise.
/// Interfaces that sourcekit-lsp generates for SDK/stdlib symbols live in a temp directory, which is
/// noise: they're shown as `<generated> Swift.String.swiftinterface`.
/// How files of a dependency checkout are displayed: `<dependency> DIC/Sources/DIC/File.swift`.
public let dependencyPrefix = "<dependency> "

/// The `.../checkouts/` directories seen in results, so a displayed `<dependency> Pkg/...` path can be
/// turned back into a real one when an agent passes it as `file_path`.
public enum DependencyRoots {
	private static let lock = NSLock()
	nonisolated(unsafe) private static var roots: [String] = []

	static func register(_ root: String) {
		lock.lock()
		defer { lock.unlock() }
		if !roots.contains(root) { roots.append(root) }
	}

	/// The real path for a `<dependency> Pkg/...` spelling (looked up in `extra` candidates too), else the input.
	public static func expand(_ path: String, extra: [String] = []) -> String {
		guard path.hasPrefix(dependencyPrefix) else { return path }
		let rest = String(path.dropFirst(dependencyPrefix.count))
		lock.lock()
		let known = roots
		lock.unlock()
		for root in known + extra {
			let candidate = root.hasSuffix("/") ? root + rest : root + "/" + rest
			if FileManager.default.fileExists(atPath: candidate) { return candidate }
		}
		return path
	}
}

public func uriToRelative(_ uri: String, workspaceRoot: URL) -> String {
	guard let path = uriToPath(uri) else { return uri }
	if let range = path.range(of: "/DerivedSources/") {
		return "<generated> " + path[range.upperBound...]
	}
	if path.contains("/sourcekit-lsp/GeneratedInterfaces/") {
		return "<generated> " + (path.split(separator: "/").last.map(String.init) ?? path)
	}
	// A SwiftPM/Xcode dependency checkout: `<dependency> DIC/Sources/DIC/File.swift` instead of a
	// path through DerivedData or `.build` (also when `.build` is inside the workspace).
	if let range = path.range(of: "/checkouts/") {
		DependencyRoots.register(String(path[..<range.upperBound]))
		return dependencyPrefix + path[range.upperBound...]
	}
	if let relative = relativePath(path, in: workspaceRoot) { return relative }
	return displayPathOutside(path, root: workspaceRoot)
}

private final class LineCache: @unchecked Sendable {
	struct Key: Hashable {
		var path: String
		var modified: Date
		var size: Int
	}

	private let lock = NSLock()
	private var entries: [Key: [String]] = [:]

	func lines(for path: String) -> [String]? {
		guard let values = try? URL(fileURLWithPath: path).resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
		else { return nil }
		let key = Key(path: path, modified: values.contentModificationDate ?? .distantPast, size: values.fileSize ?? 0)
		lock.lock()
		defer { lock.unlock() }
		if let hit = entries[key] { return hit }
		guard let data = FileManager.default.contents(atPath: path), let text = String(data: data, encoding: .utf8) else {
			return nil
		}
		var lines = LSPClient.splitLines(text)
		if lines.last == "" { lines.removeLast() }
		if entries.count >= 128 { entries.removeAll() }
		entries[key] = lines
		return lines
	}
}

private let lineCache = LineCache()

/// File lines, memoized per (path, mtime, size) so formatting N results from one file reads it once.
public func readLines(of uri: String) -> [String]? {
	uriToPath(uri).flatMap { lineCache.lines(for: $0) }
}

public func snippet(uri: String, startLine: Int, endLine: Int, context: Int = 0) -> String {
	guard let lines = readLines(of: uri), !lines.isEmpty else { return "" }
	let low = max(0, startLine - context)
	let high = min(lines.count, endLine + 1 + context)
	guard low < high else { return "" }
	return (low..<high).map { index in
		let number = String(index + 1)
		return String(repeating: " ", count: max(0, 5 - number.count)) + number + " | " + lines[index]
	}.joined(separator: "\n")
}

public func formatLocation(_ location: LSPLocation, workspaceRoot: URL) -> String {
	let start = location.range.start
	let header = "\(uriToRelative(location.uri, workspaceRoot: workspaceRoot)):\(start.line + 1):\(start.character + 1)"
	let body = snippet(uri: location.uri, startLine: start.line, endLine: location.range.end.line, context: 2)
	return body.isEmpty ? header : "\(header)\n\(body)"
}

// MARK: - Workspace symbols

/// Names sourcekit-lsp invents for macro expansions (e.g. each Swift Testing `@Test` yields
/// several `$s14MyTests11createsUser4TestfMp_…` entries); they are never something to navigate to.
func isGeneratedName(_ name: String) -> Bool {
	name.hasPrefix("$")
}

/// `create(name:)` -> `create`, and the Objective-C selector `loadFileAtPath:error:` -> `loadFileAtPath`.
/// Swift symbol names carry their argument labels; Objective-C ones their colons.
public func baseName(_ name: String) -> String {
	name.firstIndex(where: { $0 == "(" || $0 == ":" }).map { String(name[..<$0]) } ?? name
}

/// Letters and digits only, lowercased: `increment(by:)` and the Objective-C `incrementBy:` it is exported
/// as (and `greet(_:)` / `greet:`) become the same string.
func squashed(_ name: String) -> String {
	String(name.lowercased().filter { $0.isLetter || $0.isNumber })
}

extension WorkspaceSymbol {
	public var baseName: String { NavShared.baseName(name) }

	/// `Container.name`, so a bare `run()` says which type it belongs to.
	public var qualifiedName: String {
		guard let containerName, !containerName.isEmpty else { return name }
		return "\(containerName).\(name)"
	}

	/// 0-based (line, character) of the identifier. sourcekit-lsp aims the range at the name itself.
	public var position: LSPPosition { location.range?.start ?? LSPPosition(line: 0, character: 0) }
}

public func formatWorkspaceSymbol(_ symbol: WorkspaceSymbol, workspaceRoot: URL) -> String {
	let position = symbol.position
	let path = uriToRelative(symbol.location.uri, workspaceRoot: workspaceRoot)
	return "\(symbol.qualifiedName)  [\(SymbolKind.label(symbol.kind))]  (\(path):\(position.line + 1):\(position.character + 1))"
}

/// Tier for names that only match the language server's fuzzy subsequence search.
let fuzzyTier = 4

/// 0 exact, 1 case-insensitive exact, 2 prefix, 3 substring, 4 fuzzy only. Compared on the base
/// name (without argument labels) unless the query itself names labels.
func matchTier(name: String, query: String) -> Int {
	let candidate = query.contains("(") ? name : baseName(name)
	if candidate == query { return 0 }
	let foldedName = candidate.lowercased()
	let foldedQuery = query.lowercased()
	if foldedName == foldedQuery { return 1 }
	if squashed(name) == squashed(query) { return 1 }
	if foldedName.hasPrefix(foldedQuery) { return 2 }
	if foldedName.contains(foldedQuery) { return 3 }
	return fuzzyTier
}

/// Property/Field symbols rank after declarations within the same match tier, so a broad query
/// doesn't fill the result cap with stored properties and push out the types and functions an
/// agent is usually looking for.
private let lowPriorityKinds: Set<Int> = [7, 8]

private func isTestPath(_ path: String) -> Bool {
	let parts = path.replacingOccurrences(of: "\\", with: "/").split(separator: "/").map(String.init)
	guard let file = parts.last else { return false }
	let directories = parts.dropLast()
	return directories.contains { $0 == "Tests" || $0 == "Test" || $0.hasSuffix("Tests") || $0.hasSuffix("UITests") }
		|| ["Tests.swift", "Test.swift", "Spec.swift", "Mock.swift", "Mocks.swift"].contains { file.hasSuffix($0) }
}

/// Code that belongs to a dependency or the SDK rather than to the project being navigated:
/// package checkouts, build output, DerivedData, Pods, generated SDK interfaces.
public func isDependencyPath(_ uri: String) -> Bool {
	let path = uriToPath(uri) ?? uri
	return ["/checkouts/", "/.build/", "/SourcePackages/", "/DerivedData/", "/Pods/", "/Carthage/", "/Build/Intermediates.noindex/", "/DerivedSources/", ".sdk/", "/sourcekit-lsp/GeneratedInterfaces/"]
		.contains { path.contains($0) }
}

/// Where a symbol lives, for ordering within a match tier: the project's own code, then its tests,
/// then dependencies.
private func locationClass(_ uri: String) -> Int {
	if isDependencyPath(uri) { return 2 }
	return isTestPath(uriToPath(uri) ?? uri) ? 1 : 0
}

/// Exact -> case-insensitive exact -> prefix -> substring -> other; within a tier, the project's own
/// code before tests before dependencies, then declarations before properties/fields; among fuzzy-only
/// hits the shortest name first (a short name is the one that most closely resembles the query).
public func rankWorkspaceSymbols(_ symbols: [WorkspaceSymbol], query: String) -> [WorkspaceSymbol] {
	guard !query.isEmpty else { return symbols }
	let keyed = symbols.enumerated().map { index, symbol in
		let tier = matchTier(name: symbol.name, query: query)
		return (
			symbol,
			[
				tier,
				locationClass(symbol.location.uri),
				lowPriorityKinds.contains(symbol.kind) ? 1 : 0,
				tier == fuzzyTier ? baseName(symbol.name).count : 0,
				index,
			]
		)
	}
	return keyed.sorted { $0.1.lexicographicallyPrecedes($1.1) }.map(\.0)
}

/// Drops macro-generated names and identical repeats, keeping input order (call after ranking).
public func filterWorkspaceSymbols(_ symbols: [WorkspaceSymbol]) -> [WorkspaceSymbol] {
	struct Identity: Hashable {
		var name: String
		var container: String?
		var kind: Int
		var uri: String
		var line: Int
	}
	var seen: Set<Identity> = []
	return symbols.filter { symbol in
		guard !isGeneratedName(symbol.name) else { return false }
		return seen.insert(
			Identity(name: symbol.name, container: symbol.containerName, kind: symbol.kind, uri: symbol.location.uri, line: symbol.position.line)
		).inserted
	}
}

/// `"class"` / `"struct,protocol"` (case-insensitive kind labels) -> kind numbers; nil/blank -> no
/// filter. Unknown labels throw, listing the valid ones.
public func parseKindFilter(_ kind: String?) throws -> Set<Int>? {
	guard let kind, !kind.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
	var byLabel = Dictionary(uniqueKeysWithValues: SymbolKind.labels.map { ($0.value.lowercased(), $0.key) })
	byLabel.merge(SymbolKind.aliases) { $1 }
	var wanted: Set<Int> = []
	for part in kind.split(separator: ",") {
		let label = part.trimmingCharacters(in: .whitespaces).lowercased()
		if label.isEmpty { continue }
		guard let value = byLabel[label] else {
			let valid = SymbolKind.labels.values.map { $0.lowercased() }.sorted().joined(separator: ", ")
			throw ToolInputError("unknown symbol kind '\(part.trimmingCharacters(in: .whitespaces))'; use one or more of: \(valid)")
		}
		wanted.insert(value)
	}
	return wanted.isEmpty ? nil : wanted
}

private func pathFilterMatches(_ relativePath: String, pattern: String) -> Bool {
	var pattern = pattern.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "\\", with: "/")
	if pattern.hasPrefix("./") { pattern.removeFirst(2) }
	if pattern.contains(where: { "*?[".contains($0) }) {
		return fnmatch(pattern, relativePath, 0) == 0
	}
	return relativePath.hasPrefix(pattern)
}

/// Keeps symbols of the given kinds under `path` (workspace-relative prefix, or a glob such as
/// `Sources/**/*.swift` when it contains `*?[`).
public func filterSymbols(
	_ symbols: [WorkspaceSymbol], workspaceRoot: URL, kinds: Set<Int>? = nil, path: String? = nil
) -> [WorkspaceSymbol] {
	let path = path?.trimmingCharacters(in: .whitespaces)
	let hasPath = !(path ?? "").isEmpty
	if kinds == nil, !hasPath { return symbols }
	return symbols.filter { symbol in
		if let kinds, !kinds.contains(symbol.kind) { return false }
		if hasPath, let path,
			!pathFilterMatches(uriToRelative(symbol.location.uri, workspaceRoot: workspaceRoot), pattern: path)
		{
			return false
		}
		return true
	}
}

/// Ranked, capped listing. Unless `fuzzy`, loose subsequence-only hits (tier 4) are hidden whenever
/// a name really contains the query somewhere (tiers 0-3): language servers pad `Store` with every
/// name that happens to contain those letters in order, which reads as if they all matched. With no
/// real match the fuzzy hits stay (abbreviations like `UsrSvc`).
public func formatWorkspaceSymbols(
	_ symbols: [WorkspaceSymbol], workspaceRoot: URL, query: String = "", limit: Int = defaultSearchSymbolLimit,
	fuzzy: Bool = false
) -> String {
	guard !symbols.isEmpty else { return "" }
	var ranked = filterWorkspaceSymbols(rankWorkspaceSymbols(symbols, query: query))
	var hiddenFuzzy = 0
	var onlyFuzzy = false
	if !query.isEmpty {
		let real = ranked.filter { matchTier(name: $0.name, query: query) < fuzzyTier }
		if real.isEmpty {
			onlyFuzzy = true
		} else if !fuzzy {
			hiddenFuzzy = ranked.count - real.count
			ranked = real
		}
	}
	let shown = Array(ranked.prefix(max(0, limit)))
	var lines = shown.map { formatWorkspaceSymbol($0, workspaceRoot: workspaceRoot) }
	if onlyFuzzy {
		// Every hit is a loose subsequence match: say so, or they read as if they all contained the query.
		lines.insert("No symbol name contains '\(query)'; these are the closest fuzzy matches (closest first):", at: 0)
	}
	let omitted = ranked.count - shown.count
	if omitted > 0 {
		lines.append("… and \(omitted) more (showing first \(shown.count)); narrow with kind=… or path=…")
	}
	if hiddenFuzzy > 0 {
		lines.append(
			"(\(hiddenFuzzy) looser fuzzy match\(hiddenFuzzy == 1 ? "" : "es") whose names don't contain '\(query)' hidden; pass fuzzy=true to list them)"
		)
	}
	return lines.joined(separator: "\n")
}

// MARK: - Diagnostics

private let severityLabels: [Int: String] = [1: "error", 2: "warning", 3: "info", 4: "hint"]

/// One diagnostic as `L:C [severity code] first line`, with further message lines indented on their
/// own lines so every line that doesn't start with whitespace is exactly one diagnostic.
public func formatDiagnostic(_ item: LSPDiagnostic) -> String {
	let severity = item.severity.flatMap { severityLabels[$0] } ?? "?"
	let tag = item.codeText.map { $0.isEmpty ? severity : "\(severity) \($0)" } ?? severity
	let lines = item.message.components(separatedBy: CharacterSet.newlines)
	let header = "\(item.range.start.line + 1):\(item.range.start.character + 1) [\(tag)] \(lines.first ?? "")"
	return ([header] + lines.dropFirst().map { "    \($0)" }).joined(separator: "\n")
}

/// Capped, so a badly broken file can't flood the caller with an unbounded wall of text.
public func formatDiagnostics(_ items: [LSPDiagnostic], limit: Int = defaultDiagnosticsLimit) -> String {
	guard !items.isEmpty else { return "No diagnostics." }
	let shown = items.prefix(max(0, limit))
	var lines = shown.map(formatDiagnostic)
	if items.count > shown.count { lines.append("… and \(items.count - shown.count) more (showing first \(shown.count))") }
	return lines.joined(separator: "\n")
}

// MARK: - References

/// Compact `path: L12, L40, …` grouping (no snippets) for `symbol_info`, where full per-location
/// snippets would make a one-call summary too long to be useful. `withColumns` keeps the column
/// (`L12:4`) so a follow-up position-based call can still target the hit precisely.
public func formatReferencesGrouped(
	_ locations: [LSPLocation], workspaceRoot: URL, fileLimit: Int = defaultReferenceFileLimit, withColumns: Bool = false
) -> String {
	guard !locations.isEmpty else { return "No references found." }
	struct Spot: Hashable, Comparable {
		var line: Int
		var column: Int
		static func < (lhs: Spot, rhs: Spot) -> Bool { (lhs.line, lhs.column) < (rhs.line, rhs.column) }
	}
	var groups: [String: Set<Spot>] = [:]
	for location in locations {
		let path = uriToRelative(location.uri, workspaceRoot: workspaceRoot)
		groups[path, default: []].insert(Spot(line: location.range.start.line + 1, column: location.range.start.character + 1))
	}
	let total = groups.values.reduce(0) { $0 + $1.count }
	let files = groups.sorted { $0.key < $1.key }
	let shown = files.prefix(fileLimit)
	var lines = ["\(total) reference(s) in \(files.count) file(s):"]
	for (path, spots) in shown {
		let tags = spots.sorted().map { withColumns ? "L\($0.line):\($0.column)" : "L\($0.line)" }
		lines.append("\(path): " + tags.joined(separator: ", "))
	}
	if files.count > shown.count { lines.append("… and \(files.count - shown.count) more file(s)") }
	return lines.joined(separator: "\n")
}

/// Full per-location snippets for a small number of hits; above `snippetLimit`, the compact grouped
/// listing (with columns) so a symbol with 20+ call sites doesn't flood the reply.
public func formatReferences(
	_ locations: [LSPLocation], workspaceRoot: URL, snippetLimit: Int = defaultReferencesSnippetLimit
) -> String {
	guard !locations.isEmpty else { return "No references found at that position." }
	if locations.count <= snippetLimit {
		return sortedLocations(locations).map { formatLocation($0, workspaceRoot: workspaceRoot) }.joined(separator: "\n\n")
	}
	let grouped = formatReferencesGrouped(locations, workspaceRoot: workspaceRoot, withColumns: true)
	return "(compact list: \(locations.count) > \(snippetLimit) hits)\n\(grouped)"
}

private func sortedLocations(_ locations: [LSPLocation]) -> [LSPLocation] {
	locations.sorted {
		($0.uri, $0.range.start.line, $0.range.start.character) < ($1.uri, $1.range.start.line, $1.range.start.character)
	}
}

// MARK: - Outline

/// A document symbol normalized for printing and searching: 0-based lines, children in file order.
public struct SymbolNode: Sendable {
	public var name: String
	public var kind: Int
	public var startLine: Int
	public var endLine: Int
	public var selectionLine: Int
	public var selectionColumn: Int
	public var children: [SymbolNode]
}

public func toSymbolTree(_ symbols: [DocumentSymbol]) -> [SymbolNode] {
	symbols.map { symbol in
		SymbolNode(
			name: symbol.name,
			kind: symbol.kind,
			startLine: symbol.range.start.line,
			endLine: symbol.range.end.line,
			selectionLine: symbol.selectionRange.start.line,
			selectionColumn: symbol.selectionRange.start.character,
			children: toSymbolTree(symbol.children ?? [])
		)
	}.sorted { $0.startLine < $1.startLine }
}

/// sourcekit-lsp lists a generic parameter (`T` in `func f<T>()`) as a type-alias child of its
/// declaration. It sits on the declaration's own line after the name, unlike a real `typealias`
/// member, which has a line of its own: those would only clutter every generic method.
private func isGenericParameter(_ node: SymbolNode, in parent: SymbolNode?) -> Bool {
	guard node.kind == 26, let parent else { return false }
	return node.startLine == parent.selectionLine && node.selectionColumn > parent.selectionColumn
}

/// Indented `name  [Kind]  :start-end` tree. The end line lets an agent judge a member's size
/// ("is this method worth reading in full?") without a separate call. Extensions print as
/// `extension Name`.
public func formatOutline(_ symbols: [DocumentSymbol], indent: String = "  ") -> String {
	guard !symbols.isEmpty else { return "No symbols found." }
	var lines: [String] = []
	func walk(_ nodes: [SymbolNode], depth: Int, parent: SymbolNode? = nil) {
		for node in nodes {
			if isGenericParameter(node, in: parent) { continue }
			// clangd lists the locals of an Objective-C/C method as children; Swift's outline never does.
			if node.kind == 13, let parent, [6, 9, 12].contains(parent.kind) { continue }
			let start = node.startLine + 1
			let end = node.endLine + 1
			let span = start == end ? ":\(start)" : ":\(start)-\(end)"
			let name = node.kind == SymbolKind.extensionKind ? "extension \(node.name)" : node.name
			lines.append("\(String(repeating: indent, count: depth))\(name)  [\(SymbolKind.label(node.kind))]  \(span)")
			walk(node.children, depth: depth + 1, parent: node)
		}
	}
	walk(toSymbolTree(symbols), depth: 0)
	return lines.joined(separator: "\n")
}

// MARK: - Call hierarchy

/// `caller  [Kind]  (path:line) calls at L.., L..`: the caller's own position plus every call-site
/// line within it, so an agent sees who calls a function without imports/type-only usages mixed in
/// (unlike `references`).
public func formatCallers(_ calls: [IncomingCall], workspaceRoot: URL) -> String {
	guard !calls.isEmpty else { return "No callers found." }
	return calls.map { call in
		let path = uriToRelative(call.from.uri, workspaceRoot: workspaceRoot)
		let callerLine = call.from.selectionRange.start.line + 1
		let sites = Set(call.fromRanges.map { $0.start.line + 1 }).sorted().map { "L\($0)" }
		return "\(call.from.name)  [\(SymbolKind.label(call.from.kind))]  (\(path):\(callerLine)) calls at "
			+ (sites.isEmpty ? "L\(callerLine)" : sites.joined(separator: ", "))
	}.joined(separator: "\n")
}
