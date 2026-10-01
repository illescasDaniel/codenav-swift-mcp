import Foundation
import NavShared

/// Answers for symbols the index can't see completely (declared in a dependency checkout or a sibling
/// package, or reported thinly): find every whole-word occurrence of the name in the project's
/// sources by text, then ask the language server `definition` for each one and keep those that lead
/// back to the declaration. The index isn't consulted, so the answer is complete for everything the
/// scan covers, at the cost of one request per candidate.
struct UsageScan {
	static let maxCandidates = 600
	static let concurrency = 6

	struct Result {
		var uses: [PositionResolver.Occurrence]
		/// Occurrences the server couldn't resolve at all (no definition): usually files whose compiler
		/// arguments are unknown. They may or may not be uses of the declaration.
		var unresolved: [PositionResolver.Occurrence] = []
		var truncated: Bool
		var candidates: Int
	}

	/// Occurrences of `name` whose definition is `declaration` (same file, same line).
	static func uses(
		of name: String, aliases: [String] = [], declaration: LSPLocation, roots: [URL], client: LSPClient,
		module: String? = nil
	) async -> Result {
		// Objective-C and C sources are scanned too: they can use a Swift declaration (spelled `aliases`).
		var candidates: [PositionResolver.Occurrence] = []
		var truncated = false
		let reexporters = module.map { PositionResolver.reexportingModules(of: $0, under: roots) } ?? []
		for spelling in [name] + aliases {
			let found = PositionResolver.occurrences(
				of: spelling, under: roots, limit: maxCandidates - candidates.count, includeClang: true,
				requiringImport: module, reexportedVia: reexporters)
			candidates += found.hits
			truncated = truncated || found.truncated
			if candidates.count >= maxCandidates { truncated = true; break }
		}
		var verified: [PositionResolver.Occurrence] = []
		var unresolved: [PositionResolver.Occurrence] = []
		var next = 0
		await withTaskGroup(of: (PositionResolver.Occurrence, Bool)?.self) { group in
			func launch() {
				guard next < candidates.count else { return }
				let candidate = candidates[next]
				next += 1
				group.addTask {
					guard let target = try? await client.definition(candidate.path, line: candidate.line, column: candidate.column)
					else { return nil }
					if target.isEmpty { return (candidate, false) }
					guard target.contains(where: { $0.uri == declaration.uri && $0.range.start.line == declaration.range.start.line })
					else { return nil }
					return (candidate, true)
				}
			}
			for _ in 0..<concurrency { launch() }
			while let result = await group.next() {
				if let (candidate, resolved) = result { if resolved { verified.append(candidate) } else { unresolved.append(candidate) } }
				launch()
			}
		}
		verified.sort { ($0.path, $0.line, $0.column) < ($1.path, $1.line, $1.column) }
		unresolved.sort { ($0.path, $0.line, $0.column) < ($1.path, $1.line, $1.column) }
		return Result(uses: verified, unresolved: unresolved, truncated: truncated, candidates: candidates.count)
	}

	static func location(_ occurrence: PositionResolver.Occurrence, name: String) -> LSPLocation {
		LSPLocation(
			uri: URL(fileURLWithPath: occurrence.path).absoluteString,
			range: LSPRange(
				start: LSPPosition(line: occurrence.line - 1, character: occurrence.column - 1),
				end: LSPPosition(line: occurrence.line - 1, character: occurrence.column - 1 + name.utf16.count)))
	}

	/// A use's enclosing declaration, from the file's document symbols: the innermost callable (or the
	/// type, when the use is in a header or a stored-property initializer), qualified by its types.
	struct Enclosing: Sendable {
		var name: String
		var kind: Int
		var line: Int  // 1-indexed
		var isHeader: Bool
	}

	private static let callable: Set<Int> = [6, 7, 8, 9, 12, 13, 14]

	static func enclosing(line: Int, in nodes: [SymbolNode]) -> Enclosing? {
		let target = line - 1
		func walk(_ nodes: [SymbolNode], types: [String]) -> Enclosing? {
			for node in nodes where node.startLine <= target && target <= node.endLine {
				let chain = SymbolKind.types.contains(node.kind) || node.kind == SymbolKind.extensionKind
					? types + [node.name.replacingOccurrences(of: "extension ", with: "")] : types
				if let inner = walk(node.children, types: chain) { return inner }
				let qualified = (types + [node.name]).joined(separator: ".")
				let isTypeLike = SymbolKind.types.contains(node.kind) || node.kind == SymbolKind.extensionKind
				if isTypeLike {
					return Enclosing(
						name: (chain.last ?? node.name), kind: node.kind, line: node.selectionLine + 1,
						isHeader: node.selectionLine == target)
				}
				if callable.contains(node.kind) {
					return Enclosing(name: qualified, kind: node.kind, line: node.selectionLine + 1, isHeader: false)
				}
			}
			return nil
		}
		return walk(nodes, types: [])
	}
}
