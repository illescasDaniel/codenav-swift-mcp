import Foundation
import NavShared

/// Turning "this line, this identifier" into the exact position the language server needs, and a
/// position back into a symbol: agents see source lines, they can't count columns.
enum PositionResolver {
	private static func identifierPattern(_ symbol: String) -> NSRegularExpression? {
		let escaped = NSRegularExpression.escapedPattern(for: symbol)
		return try? NSRegularExpression(pattern: "(?<![A-Za-z0-9_])" + escaped + "(?![A-Za-z0-9_])")
	}

	static func sourceLines(_ text: String) -> [String] {
		text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).map(String.init)
	}

	/// The 1-indexed UTF-16 column of `symbol` on `line` (1-indexed) of `text`, whole-word.
	static func column(of symbol: String, onLine line: Int, in text: String, filePath: String) throws -> Int {
		let lines = sourceLines(text)
		guard (1...max(lines.count, 1)).contains(line), line <= lines.count else {
			throw ToolInputError("line \(line) is out of range: \(filePath) has \(lines.count) line(s) (lines are 1-indexed)")
		}
		let lineText = lines[line - 1]
		let whole = NSRange(location: 0, length: (lineText as NSString).length)
		let found: NSRange? =
			identifierPattern(symbol)?.firstMatch(in: lineText, range: whole)?.range
			?? { () -> NSRange? in
				let range = (lineText as NSString).range(of: symbol)
				return range.location == NSNotFound ? nil : range
			}()
		guard let found else {
			throw ToolInputError(
				"'\(symbol)' does not appear on line \(line) of \(filePath): \(lineText.trimmingCharacters(in: .whitespaces))"
			)
		}
		return found.location + 1
	}

	/// `create(name:)` -> `create`; names with no labels are returned unchanged.
	static func baseName(of name: String) -> String {
		name.split(separator: "(").first.map(String.init) ?? name
	}

	/// The identifier touching 1-indexed UTF-16 `column` on `line`.
	static func word(at column: Int, onLine line: Int, in text: String) -> String? {
		let lines = sourceLines(text)
		guard line >= 1, line <= lines.count else { return nil }
		let units = Array(lines[line - 1].utf16)
		func isIdentifier(_ unit: UInt16) -> Bool {
			guard let scalar = Unicode.Scalar(unit) else { return unit > 127 }
			return scalar == "_" || scalar.properties.isAlphabetic || ("0"..."9").contains(scalar)
		}
		var index = min(max(column - 1, 0), units.count)
		if index == units.count || !isIdentifier(units[index]) {
			guard index > 0, isIdentifier(units[index - 1]) else { return nil }
			index -= 1
		}
		var start = index
		var end = index
		while start > 0, isIdentifier(units[start - 1]) { start -= 1 }
		while end + 1 < units.count, isIdentifier(units[end + 1]) { end += 1 }
		return String(decoding: units[start...end], as: UTF16.self)
	}

	private static let modifierWords: Set<String> = [
		"public", "internal", "private", "fileprivate", "open", "package", "static", "final", "lazy", "weak",
		"unowned", "nonisolated", "override", "mutating", "nonmutating", "indirect", "required", "convenience",
		"dynamic", "distributed", "@MainActor", "@objc", "@discardableResult", "@inlinable", "@available",
	]

	private static let keywordKinds: [String: Int] = [
		"class": SymbolKind.class, "actor": SymbolKind.class, "struct": SymbolKind.structure,
		"enum": SymbolKind.enumeration, "protocol": SymbolKind.protocol, "typealias": 26, "associatedtype": 26,
		"func": SymbolKind.function, "init": SymbolKind.initializer, "subscript": SymbolKind.method,
		"case": SymbolKind.enumCase, "var": SymbolKind.variable, "let": SymbolKind.constant,
	]

	/// What a hover's declaration line says the symbol is: `struct User` -> struct, `func f()` -> function,
	/// `typealias Id = UUID` -> type alias. Nil when the hover isn't a declaration.
	static func kind(fromHover text: String) -> Int? {
		let cleaned = text.replacingOccurrences(of: "```swift", with: "").replacingOccurrences(of: "```", with: "")
		for rawLine in cleaned.split(separator: "\n") {
			let tokens = rawLine.split(whereSeparator: { " (<:{=".contains($0) }).map(String.init)
			var index = 0
			while index < tokens.count {
				let token = tokens[index]
				if modifierWords.contains(token) || token.hasPrefix("@") {
					index += 1
					continue
				}
				if token == "class", index + 1 < tokens.count, keywordKinds[tokens[index + 1]] != nil {
					index += 1  // `class func`, `class var`
					continue
				}
				break
			}
			guard index < tokens.count, let kind = keywordKinds[tokens[index]] else { continue }
			return kind
		}
		return nil
	}

	struct Occurrence: Sendable, Hashable {
		var path: String
		/// 1-indexed line and UTF-16 column.
		var line: Int
		var column: Int
	}

	/// Whole-word occurrences of `name` in `.swift` files under `roots`, skipping comment and `import`
	/// lines. `perFile` keeps only the first one per file (enough to locate a name; not to list uses).
	/// Stops at `limit`; `truncated` says there was more. This is the text side of "scan, then ask the
	/// language server which hits really are the symbol", for names the index can't answer for.
	static func occurrences(
		of name: String, under roots: [URL], limit: Int, perFile: Bool = false, fileLimit: Int = 4000
	) -> (hits: [Occurrence], truncated: Bool) {
		guard name.range(of: #"^[A-Za-z_][A-Za-z0-9_]*$"#, options: .regularExpression) != nil,
			let pattern = identifierPattern(name)
		else { return ([], false) }
		var found: [Occurrence] = []
		var visited = 0
		for root in roots {
			guard let enumerator = FileManager.default.enumerator(
				at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
			else { continue }
			for case let url as URL in enumerator {
				let last = url.lastPathComponent
				if Exclude.directoryNames.contains(last) {
					enumerator.skipDescendants()
					continue
				}
				guard last.hasSuffix(".swift"), !last.hasSuffix(".generated.swift") else { continue }
				visited += 1
				if visited > fileLimit { return (found, true) }
				guard let data = try? Data(contentsOf: url), let text = String(data: data, encoding: .utf8), text.contains(name)
				else { continue }
				for (offset, line) in sourceLines(text).enumerated() {
					let trimmed = line.trimmingCharacters(in: .whitespaces)
					if trimmed.hasPrefix("//") || trimmed.hasPrefix("*") || trimmed.hasPrefix("/*") || trimmed.hasPrefix("import ") {
						continue
					}
					let whole = NSRange(location: 0, length: (line as NSString).length)
					for match in pattern.matches(in: line, range: whole) {
						if found.count >= limit { return (found, true) }
						found.append(Occurrence(path: url.path, line: offset + 1, column: match.range.location + 1))
						if perFile { break }
					}
					if perFile, found.last?.path == url.path { break }
				}
			}
		}
		return (found, false)
	}

	static func findUsages(of name: String, under root: URL, limit: Int = 1) -> [Occurrence] {
		occurrences(of: name, under: [root], limit: limit, perFile: true).hits
	}

	static func findUsage(of name: String, under root: URL) -> Occurrence? {
		findUsages(of: name, under: root).first
	}
}
