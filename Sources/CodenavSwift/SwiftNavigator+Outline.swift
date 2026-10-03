import Foundation
import NavShared

/// sourcekit-lsp's `workspace/symbol` is incomplete: it leaves out `let` properties and constants, and members
/// that live in extensions are attributed unreliably. A file's own outline (`documentSymbol`) is complete and
/// cheap, so this builds the missing part on demand: grep the workspace for the files that mention a name, read
/// just those outlines, and flatten them into symbols with their container path.
enum OutlineIndex {
	struct Entry {
		var symbol: DocumentSymbol
		/// The types it is declared in; an extension counts as the type it extends (`extension A.B` -> ["A", "B"]).
		var container: [String]
		var uri: String

		var workspaceSymbol: WorkspaceSymbol {
			WorkspaceSymbol(
				name: symbol.name, kind: symbol.kind, containerName: container.isEmpty ? nil : container.joined(separator: "."),
				uri: uri, range: symbol.selectionRange)
		}
	}

	static let defaultFileLimit = 80
	static let walkLimit = 6000

	/// Swift files under `roots` whose text contains every needle.
	static func files(containing needles: [String], roots: [URL], caseInsensitive: Bool = false, limit: Int = defaultFileLimit) -> [String] {
		let wanted = needles.filter { !$0.isEmpty }
		guard !wanted.isEmpty else { return [] }
		var found: [String] = []
		var seen: Set<String> = []
		var visited = 0
		for root in roots {
			guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { continue }
			for case let url as URL in enumerator {
				if Exclude.directoryNames.contains(url.lastPathComponent) {
					enumerator.skipDescendants()
					continue
				}
				guard url.pathExtension == "swift", !url.lastPathComponent.hasSuffix(".generated.swift") else { continue }
				visited += 1
				if visited > walkLimit { return found }
				guard let data = try? Data(contentsOf: url), let text = String(data: data, encoding: .utf8) else { continue }
				let options: String.CompareOptions = caseInsensitive ? [.caseInsensitive] : []
				guard wanted.allSatisfy({ text.range(of: $0, options: options) != nil }) else { continue }
				let path = url.realPath.path
				guard seen.insert(path).inserted else { continue }
				found.append(path)
				if found.count >= limit { return found }
			}
		}
		return found
	}

	static func flatten(_ tree: [DocumentSymbol], uri: String, container: [String] = []) -> [Entry] {
		var result: [Entry] = []
		for symbol in tree {
			if symbol.kind == SymbolKind.extensionKind {
				result += flatten(symbol.children ?? [], uri: uri, container: container + symbol.name.split(separator: ".").map(String.init))
				continue
			}
			result.append(Entry(symbol: symbol, container: container, uri: uri))
			// Members of types; a function's children are its generic parameters.
			if SymbolKind.types.contains(symbol.kind) {
				result += flatten(symbol.children ?? [], uri: uri, container: container + [symbol.name])
			}
		}
		return result
	}

	/// Whether `container` ends with the path the query named (`Outer.Inner`), or is exactly it when `exact`.
	static func container(_ container: [String], matches wanted: [String], exact: Bool = false) -> Bool {
		if wanted.isEmpty { return !exact || container.isEmpty }
		return exact ? container == wanted : container.count >= wanted.count && Array(container.suffix(wanted.count)) == wanted
	}
}

extension SwiftNavigator {
	var outlineRoots: [URL] { [workspaceRoot] + ProjectKind.localPackageFolders(in: workspaceRoot) }

	/// Outline entries from the files that mention every one of `needles`.
	func outlineEntries(client: LSPClient, mentioning needles: [String], caseInsensitive: Bool = false, onlyIn file: String? = nil) async -> [OutlineIndex.Entry] {
		var paths = OutlineIndex.files(containing: needles, roots: outlineRoots, caseInsensitive: caseInsensitive)
		if let file {
			let canonical = canonicalFileURL(file, relativeTo: workspaceRoot).path
			paths = paths.filter { $0 == canonical }
		}
		var entries: [OutlineIndex.Entry] = []
		for path in paths {
			guard let tree = try? await client.documentSymbol(path) else { continue }
			entries += OutlineIndex.flatten(tree, uri: URL(fileURLWithPath: path).absoluteString)
		}
		return entries
	}

	/// What `workspace/symbol` leaves out, found in the outlines of files that mention `query`: symbols whose
	/// name matches (a substring, case-insensitively) and that are not in `existing` already.
	func outlineSymbols(client: LSPClient, query: String, container: [String], existing: [WorkspaceSymbol]) async -> [WorkspaceSymbol] {
		let parsed = ParsedQuery(query)
		guard RenameName.isIdentifier(parsed.base) else { return [] }
		let known = Set(existing.map { "\($0.location.uri)#\($0.position.line)#\($0.baseName)" })
		let needle = parsed.base.lowercased()
		var result: [WorkspaceSymbol] = []
		for entry in await outlineEntries(client: client, mentioning: [parsed.base], caseInsensitive: true) {
			let name = NavShared.baseName(entry.symbol.name)
			guard name.lowercased().contains(needle), OutlineIndex.container(entry.container, matches: container) else { continue }
			if let signature = parsed.signature, entry.symbol.name != parsed.base + signature { continue }
			guard !known.contains("\(entry.uri)#\(entry.symbol.selectionRange.start.line)#\(name)") else { continue }
			result.append(entry.workspaceSymbol)
		}
		return result
	}

	/// A declaration `workspace/symbol` doesn't list: a `let` property or constant, or a member declared in an
	/// extension. Nil when nothing matches; throws a resolution error when several do.
	func resolveViaOutline(client: LSPClient, query: String, filePath: String?) async throws -> ResolvedSymbol? {
		let parsed = ParsedQuery(query)
		guard RenameName.isIdentifier(parsed.base) else { return nil }
		let needles = parsed.container.isEmpty ? [parsed.base] : [parsed.base, parsed.container.last ?? ""]
		var matches: [OutlineIndex.Entry] = []
		for entry in await outlineEntries(client: client, mentioning: needles, onlyIn: filePath) {
			guard OutlineIndex.container(entry.container, matches: parsed.container, exact: parsed.container.isEmpty) else { continue }
			let isMatch = parsed.signature.map { entry.symbol.name == parsed.base + $0 } ?? (NavShared.baseName(entry.symbol.name) == parsed.base)
			if isMatch, entry.symbol.kind != 26 || !parsed.container.isEmpty { matches.append(entry) }
		}
		if matches.count > 1 {
			let listing = matches.prefix(10).map { formatWorkspaceSymbol($0.workspaceSymbol, workspaceRoot: workspaceRoot) }.joined(separator: "\n")
			throw SymbolResolutionError(
				message: "\(matches.count) symbols match '\(query)'; qualify with the type (`Type.member`) or pass file_path to disambiguate:\n" + listing)
		}
		guard let entry = matches.first else { return nil }
		return ResolvedSymbol(
			name: entry.symbol.name, containerName: entry.container.isEmpty ? nil : entry.container.joined(separator: "."), kind: entry.symbol.kind,
			uri: entry.uri, line: entry.symbol.selectionRange.start.line, column: entry.symbol.selectionRange.start.character)
	}
}
