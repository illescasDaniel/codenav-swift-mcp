import Foundation
import NavShared

/// While a file has type errors the Swift compiler never gets to flow analysis, so a function that forgets to
/// return a value goes unreported. This is a deliberately conservative stand-in for the most common case, used
/// only on declarations an edit touched, in files that still have errors.
enum FlowLint {
	static func problems(for symbol: DocumentSymbol, in text: String, index: TextIndex, scan: SwiftScan) -> [String] {
		guard [SymbolKind.method, SymbolKind.function, SymbolKind.property].contains(symbol.kind),
			let start = try? index.offset(symbol.range.start), let end = try? index.offset(symbol.range.end),
			let selectionEnd = try? index.offset(symbol.selectionRange.end),
			let body = scan.body(of: start..<end, from: selectionEnd)
		else { return [] }
		let header = scan.text(selectionEnd, body.open)
		let declaration = scan.text(start, selectionEnd)
		let returnType: String
		if symbol.kind == SymbolKind.property {
			guard let colon = header.firstIndex(of: ":") else { return [] }
			returnType = String(header[header.index(after: colon)...])
		} else {
			guard let arrow = header.range(of: "->", options: .backwards) else { return [] }
			returnType = String(header[arrow.upperBound...])
		}
		let type = returnType.components(separatedBy: " where ")[0].trimmingCharacters(in: .whitespacesAndNewlines)
		if type.isEmpty || ["Void", "()", "Never"].contains(type) || type.hasPrefix("some ") || type.hasPrefix("any View") { return [] }
		// Result builders return the sum of their statements.
		if declaration.contains("Builder") || header.contains("Builder") { return [] }

		// The body with comments and strings blanked, so keywords inside them don't count.
		var code = ""
		for offset in (body.open + 1)..<body.close {
			code += scan.isCode[offset] ? String(UnicodeScalar(scan.units[offset]).map(Character.init) ?? " ") : " "
		}
		let lines = code.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
		let name = NavShared.baseName(symbol.name)
		if lines.isEmpty { return ["\(name) returns \(type) but its body is empty"] }
		// An accessor block (`get`/`set`/`willSet`/`didSet`) is a different shape; leave it to the compiler.
		if symbol.kind == SymbolKind.property, lines.contains(where: { $0.hasPrefix("get") || $0.hasPrefix("set") || $0.hasPrefix("willSet") || $0.hasPrefix("didSet") }) { return [] }
		let exits = ["return", "throw", "fatalError", "preconditionFailure", "assertionFailure", "exit("]
		if exits.contains(where: { containsWord($0, in: code) }) { return [] }
		// A single expression (or `if`/`switch` expression) is an implicit return.
		let first = lines[0].split(whereSeparator: { " ({".contains($0) }).first.map(String.init) ?? ""
		if ["if", "switch", "do"].contains(first) { return [] }
		var statements = 0
		var depth = 0
		var continues = false  // the previous line ended mid-expression (`a +`, `x,`, `cond ?`)
		let leaders = [".", "?", ":", "&&", "||", "+", "-", "*", "/", "==", "!=", "<", ">", "=", "??", "as ", "as?", "as!", "is ", "}", ")", "]"]
		for line in lines {
			if depth == 0, !continues, !leaders.contains(where: { line.hasPrefix($0) }) { statements += 1 }
			depth += line.reduce(0) { $0 + ("{([".contains($1) ? 1 : "})]".contains($1) ? -1 : 0) }
			depth = max(depth, 0)
			continues = line.last.map { "+-*/&|?:,<>.".contains($0) } ?? false
		}
		return statements > 1 ? ["\(name) returns \(type) but has \(statements) statements and no `return`"] : []
	}

	private static func containsWord(_ word: String, in text: String) -> Bool {
		let pattern = word.hasSuffix("(") ? NSRegularExpression.escapedPattern(for: word) : "(?<![A-Za-z0-9_])" + NSRegularExpression.escapedPattern(for: word) + "(?![A-Za-z0-9_])"
		return text.range(of: pattern, options: .regularExpression) != nil
	}

	/// Every symbol of a tree that overlaps the 0-based `lines`.
	static func symbols(in tree: [DocumentSymbol], overlapping lines: ClosedRange<Int>) -> [DocumentSymbol] {
		var result: [DocumentSymbol] = []
		for symbol in tree where symbol.range.start.line <= lines.upperBound && symbol.range.end.line >= lines.lowerBound {
			result.append(symbol)
			if ![SymbolKind.method, SymbolKind.function].contains(symbol.kind) { result += symbols(in: symbol.children ?? [], overlapping: lines) }
		}
		return result
	}
}
