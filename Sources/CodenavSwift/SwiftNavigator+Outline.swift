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
	func outlineEntries(client: LSPClient, mentioning needles: [String], substring: Bool = false, onlyIn file: String? = nil) async -> [OutlineIndex.Entry] {
		var paths = outlineFileIndex.files(containing: needles, roots: outlineRoots, substring: substring)
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
		for entry in await outlineEntries(client: client, mentioning: [parsed.base], substring: true) {
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

/// Which Swift files mention which identifiers, kept between searches so a lookup doesn't re-read the whole
/// workspace each time.
///
/// It is only ever a *prefilter*: the files it names are then asked for their outlines, which are read fresh,
/// so a stale or loose entry can cost an extra outline request but never a wrong answer. It is kept safe by:
///  * trusting an entry only while the file's modification time and size are unchanged, and never one for a
///    file modified in the last few seconds (a coarse timestamp can hide a quick second edit);
///  * dropping entries for files that no longer exist;
///  * a cap on how many identifiers it holds (past it, files are simply re-read each time).
final class OutlineFileIndex {
	private struct Entry {
		var modified: Date
		var size: Int
		/// The file's identifiers, lowercased.
		var tokens: Set<String>
	}

	static let maxCachedTokens = 1_000_000
	static let hotInterval: TimeInterval = 3

	private var entries: [String: Entry] = [:]
	private var cachedTokens = 0
	/// How many files were read from disk so far (for tests and diagnostics).
	private(set) var filesRead = 0

	func clear() {
		entries.removeAll()
		cachedTokens = 0
	}

	/// Swift files under `roots` that mention every needle. A needle matches an identifier exactly, or, with
	/// `substring`, anywhere inside one; both ignore case (the caller verifies against the outlines).
	func files(containing needles: [String], roots: [URL], substring: Bool, limit: Int = OutlineIndex.defaultFileLimit) -> [String] {
		let wanted = needles.filter { !$0.isEmpty }.map { $0.lowercased() }
		guard !wanted.isEmpty else { return [] }
		var found: [String] = []
		var seen: Set<String> = []
		var visited = 0
		var completed = true
		var live: Set<String> = []
		walk: for root in roots {
			guard let enumerator = FileManager.default.enumerator(
				at: root, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey], options: [.skipsHiddenFiles])
			else { continue }
			for case let url as URL in enumerator {
				if Exclude.directoryNames.contains(url.lastPathComponent) {
					enumerator.skipDescendants()
					continue
				}
				guard url.pathExtension == "swift", !url.lastPathComponent.hasSuffix(".generated.swift") else { continue }
				visited += 1
				if visited > OutlineIndex.walkLimit {
					completed = false
					break walk
				}
				let key = url.path
				live.insert(key)
				let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
				let modified = values?.contentModificationDate ?? .distantPast
				let size = values?.fileSize ?? -1
				let tokens: Set<String>
				if let cached = entries[key], cached.modified == modified, cached.size == size,
					Date().timeIntervalSince(modified) > Self.hotInterval
				{
					tokens = cached.tokens
				} else {
					guard let data = try? Data(contentsOf: url) else { continue }
					filesRead += 1
					tokens = Self.tokens(in: data)
					store(Entry(modified: modified, size: size, tokens: tokens), for: key)
				}
				let matches = wanted.allSatisfy { needle in
					substring ? tokens.contains { $0.contains(needle) } : tokens.contains(needle)
				}
				guard matches, found.count < limit else { continue }
				let path = url.realPath.path
				if seen.insert(path).inserted { found.append(path) }
			}
		}
		if completed { evict(keeping: live) }
		return found
	}

	private func store(_ entry: Entry, for key: String) {
		cachedTokens -= entries[key]?.tokens.count ?? 0
		if cachedTokens + entry.tokens.count > Self.maxCachedTokens {
			entries.removeValue(forKey: key)
			return
		}
		entries[key] = entry
		cachedTokens += entry.tokens.count
	}

	private func evict(keeping live: Set<String>) {
		for key in entries.keys where !live.contains(key) {
			cachedTokens -= entries[key]?.tokens.count ?? 0
			entries.removeValue(forKey: key)
		}
	}

	/// The distinct identifiers in a file (lowercased), skipping numbers.
	static func tokens(in data: Data) -> Set<String> {
		var result: Set<String> = []
		data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
			var start = -1
			var scratch: [UInt8] = []
			func flush(_ end: Int) {
				guard start >= 0 else { return }
				defer { start = -1 }
				let first = buffer[start]
				if first >= 48, first <= 57 { return }  // a number, not an identifier
				scratch.removeAll(keepingCapacity: true)
				for index in start..<end {
					let byte = buffer[index]
					scratch.append(byte >= 65 && byte <= 90 ? byte + 32 : byte)
				}
				result.insert(String(decoding: scratch, as: UTF8.self))
			}
			for index in 0..<buffer.count {
				let byte = buffer[index]
				let isIdentifier = (byte >= 48 && byte <= 57) || (byte >= 65 && byte <= 90) || (byte >= 97 && byte <= 122) || byte == 95 || byte >= 0x80
				if isIdentifier {
					if start < 0 { start = index }
				} else {
					flush(index)
				}
			}
			flush(buffer.count)
		}
		return result
	}
}
