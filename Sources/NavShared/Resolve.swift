import Foundation

// Name-based symbol resolution shared by the composite tools (`symbol_info`, `callers`,
// `implementations`): a `workspace/symbol` lookup with tiered ranking and disambiguation by
// container / `file_path` / argument labels, so those tools take a name instead of a
// hand-computed position.
//
// Swift specifics this accounts for: symbol names carry argument labels (`create(name:)`),
// so overloads are distinct symbols and `create` alone may be ambiguous; sourcekit-lsp reports
// each symbol's dotted container (`Outer.Inner`), which makes `Type.member` lookups a filter
// rather than a document-symbol walk; members can be inherited from a superclass or a protocol
// extension, which only the type hierarchy knows about.

/// No single confident match for a name-based symbol query: not found, or ambiguous.
public struct SymbolResolutionError: Error, Sendable, Equatable {
	public var message: String

	public init(message: String) {
		self.message = message
	}
}

public struct ResolvedSymbol: Sendable {
	/// Symbol name as the server reports it, e.g. `create(name:)`.
	public var name: String
	public var containerName: String?
	public var kind: Int
	public var uri: String
	/// 0-based, aimed at the identifier.
	public var line: Int
	public var column: Int

	public init(name: String, containerName: String?, kind: Int, uri: String, line: Int, column: Int) {
		self.name = name
		self.containerName = containerName
		self.kind = kind
		self.uri = uri
		self.line = line
		self.column = column
	}

	public var qualifiedName: String {
		guard let containerName, !containerName.isEmpty else { return name }
		return "\(containerName).\(name)"
	}
}

private let maxSupertypesVisited = 64
private let maxCandidatesListed = 10

/// A query like `UserService.create(name:)` split into its parts.
public struct ParsedQuery: Equatable, Sendable {
	public var container: [String]
	public var base: String
	/// `(name:)` including parentheses, when the caller spelled out argument labels.
	public var signature: String?

	public init(_ raw: String) {
		var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
		text = text.replacingOccurrences(of: "<[^<>]*>", with: "", options: .regularExpression)  // drop generic arguments
		if let open = text.firstIndex(of: "(") {
			signature = String(text[open...]).replacingOccurrences(of: " ", with: "")
			text = String(text[..<open])
		} else {
			signature = nil
		}
		var parts = text.split(separator: ".", omittingEmptySubsequences: true).map(String.init)
		base = parts.popLast() ?? text
		container = parts
	}
}

extension WorkspaceSymbol {
	fileprivate func matches(container path: [String]) -> Bool {
		guard !path.isEmpty else { return true }
		let joined = path.joined(separator: ".")
		guard let containerName, !containerName.isEmpty else { return false }
		return containerName == joined || containerName.hasSuffix("." + joined)
	}

	fileprivate func matches(file: String, workspaceRoot: URL) -> Bool {
		// Exact: the caller's path (relative to the workspace, `../Sibling/...`, or absolute) names this very file.
		if let actual = uriToPath(location.uri),
			URL(fileURLWithPath: file, relativeTo: workspaceRoot).realPath.path == URL(fileURLWithPath: actual).realPath.path
		{
			return true
		}
		// Loose: a trailing part of the path (`Models/User.swift`).
		let relative = uriToRelative(location.uri, workspaceRoot: workspaceRoot)
		let target = (file as NSString).standardizingPath.replacingOccurrences(of: "\\", with: "/")
		return relative == target || relative.hasSuffix("/" + target) || target.hasSuffix("/" + relative)
	}

	fileprivate var resolved: ResolvedSymbol {
		ResolvedSymbol(
			name: name, containerName: containerName, kind: kind, uri: location.uri, line: position.line,
			column: position.character
		)
	}
}

private func candidateLines(_ candidates: [WorkspaceSymbol], workspaceRoot: URL) -> String {
	candidates.prefix(maxCandidatesListed).map { formatWorkspaceSymbol($0, workspaceRoot: workspaceRoot) }
		.joined(separator: "\n")
}

private func ambiguous(_ query: String, _ candidates: [WorkspaceSymbol], workspaceRoot: URL) -> SymbolResolutionError {
	let sameContainer = Set(candidates.map { $0.containerName ?? "" }).count == 1
	let hint: String
	let distinctNames = Set(candidates.map(\.name))
	if sameContainer, distinctNames.count == 1, candidates.allSatisfy({ $0.name.contains("(") }) {
		// Same labels, so only the parameter types differ: labels can't help, a position can.
		hint =
			"these overloads share the same argument labels and differ only by parameter types; "
			+ "pass file_path and `line` (the declaration line listed below) to pick one"
	} else if sameContainer, distinctNames.count > 1, candidates.allSatisfy({ $0.name.contains("(") }) {
		hint = "these are overloads; include the argument labels, e.g. \(candidates[0].qualifiedName)"
	} else if Set(candidates.map(\.location.uri)).count > 1 {
		hint = "qualify with the type (`Type.member`) or pass file_path to disambiguate"
	} else {
		hint = "use search_symbol to get the exact line/column, then hover/definition/references with that position"
	}
	let more = candidates.count > maxCandidatesListed ? "\n… and \(candidates.count - maxCandidatesListed) more" : ""
	return SymbolResolutionError(
		message: "\(candidates.count) symbols match '\(query)'; \(hint):\n"
			+ candidateLines(candidates, workspaceRoot: workspaceRoot) + more
	)
}

/// Resolve a name (`Type`, `member`, `Type.member`, `Outer.Inner.member`, `member(label:)`,
/// `Type.init(id:name:)`) to a single symbol position.
///
/// Throws `SymbolResolutionError` when nothing matches or several symbols tie on an exact name:
/// callers should pass `file_path`, qualify the name, or add argument labels to disambiguate
/// rather than guess.
public func resolveSymbol(
	client: LSPClient, workspaceRoot: URL, query: String, filePath: String? = nil, line: Int? = nil
) async throws -> ResolvedSymbol {
	let parsed = ParsedQuery(query)
	guard !parsed.base.isEmpty else { throw SymbolResolutionError(message: "No symbol found matching '\(query)'.") }

	let found = try await client.workspaceSymbol(parsed.base)
	// Same ranking and noise filtering as search_symbol, so a macro-generated twin never makes a name ambiguous.
	let ranked = filterWorkspaceSymbols(rankWorkspaceSymbols(found, query: parsed.base))
	var exact = ranked.filter { matchTier(name: $0.name, query: parsed.base) <= 1 }
	// Prefer a case-exact match over a merely case-insensitive one, e.g. `userService` vs `UserService`.
	let caseExact = exact.filter { $0.baseName == parsed.base }
	if !caseExact.isEmpty { exact = caseExact }
	if let signature = parsed.signature {
		exact = exact.filter { $0.name == parsed.base + signature }
	}

	var candidates = exact.filter { $0.matches(container: parsed.container) }
	if candidates.isEmpty, !parsed.container.isEmpty {
		candidates = try await inheritedCandidates(client: client, workspaceRoot: workspaceRoot, among: exact, parsed: parsed)
	}

	if let filePath {
		let narrowed = candidates.filter { $0.matches(file: filePath, workspaceRoot: workspaceRoot) }
		if !candidates.isEmpty, narrowed.isEmpty {
			// Silently answering with a symbol from a different file than the one the caller
			// named would be a confidently wrong result.
			throw SymbolResolutionError(
				message: "No symbol '\(query)' in '\(filePath)'; \(candidates.count) match(es) elsewhere:\n"
					+ candidateLines(candidates, workspaceRoot: workspaceRoot)
			)
		}
		candidates = narrowed
	}

	if let line {
		// 1-indexed declaration line: tells apart overloads that share labels.
		let onLine = candidates.filter { $0.position.line + 1 == line }
		if !candidates.isEmpty, onLine.isEmpty {
			throw SymbolResolutionError(
				message: "No symbol '\(query)' declared on line \(line); candidates:\n"
					+ candidateLines(candidates, workspaceRoot: workspaceRoot)
			)
		}
		candidates = onLine
	}

	switch candidates.count {
	case 0:
		throw notFound(query, parsed: parsed, anyMember: !exact.isEmpty)
	case 1:
		return candidates[0].resolved
	default:
		throw ambiguous(query, candidates, workspaceRoot: workspaceRoot)
	}
}

private func notFound(_ query: String, parsed: ParsedQuery, anyMember: Bool) -> SymbolResolutionError {
	if !parsed.container.isEmpty, anyMember {
		return SymbolResolutionError(
			message: "No symbol found matching '\(query)': '\(parsed.base)' exists, but not inside '\(parsed.container.joined(separator: "."))'."
		)
	}
	if parsed.signature != nil {
		return SymbolResolutionError(
			message: "No symbol found matching '\(query)'. Argument labels must match exactly (`greet(_:loudly:)`); try the name without them to list the overloads."
		)
	}
	return SymbolResolutionError(message: "No symbol found matching '\(query)'.")
}

/// `Type.member` where `member` is inherited: a method from a superclass, or a default
/// implementation in a protocol extension. Walks `typeHierarchy/supertypes` breadth-first
/// (MRO-like for the common case) from the container type and keeps candidates whose own
/// container is one of the supertypes. Empty when the server has no type hierarchy support.
private func inheritedCandidates(
	client: LSPClient, workspaceRoot: URL, among exact: [WorkspaceSymbol], parsed: ParsedQuery
) async throws -> [WorkspaceSymbol] {
	guard let typeName = parsed.container.last, !exact.isEmpty else { return [] }
	let typeQuery = parsed.container.dropLast()
	let types = try await client.workspaceSymbol(typeName)
		.filter { SymbolKind.types.contains($0.kind) && $0.baseName == typeName && $0.matches(container: Array(typeQuery)) }
	guard let type = types.first else { return [] }

	var queue: [HierarchyItem]
	do {
		guard let path = uriToPath(type.location.uri) else { return [] }
		queue = try await client.prepareTypeHierarchy(path, line: type.position.line + 1, column: type.position.character + 1)
	} catch is LSPRequestError {
		return []
	}
	var seen: Set<String> = []
	while !queue.isEmpty, seen.count < maxSupertypesVisited {
		let item = queue.removeFirst()
		let supers: [HierarchyItem]
		do { supers = try await client.supertypes(item) } catch is LSPRequestError { continue }
		for sup in supers {
			guard seen.insert(sup.uri + "#" + sup.name).inserted else { continue }
			queue.append(sup)
			let found = exact.filter { ($0.containerName ?? "").split(separator: ".").last.map(String.init) == sup.name }
			if !found.isEmpty { return found }
		}
	}
	return []
}
