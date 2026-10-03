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
		// Only the line breaks sourcekit-lsp counts: `isNewline` would also split on form feed, U+2028 and friends.
		text.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "\n" || $0 == "\r\n" || $0 == "\r" }).map(String.init)
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
		NavShared.baseName(name)
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

	/// What a hover's declaration line says the symbol is: `struct User` -> struct, `func f()` -> function,
	/// `typealias Id = UUID` -> type alias. Nil when the hover isn't a declaration.
	static func kind(fromHover text: String) -> Int? { SymbolKind.infer(fromDeclaration: text) }

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
		of name: String, under roots: [URL], limit: Int, perFile: Bool = false, fileLimit: Int = 4000,
		includeClang: Bool = false, requiringImport module: String? = nil, reexportedVia reexporters: Set<String> = []
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
				let isSwift = last.hasSuffix(".swift") && !last.hasSuffix(".generated.swift")
				guard isSwift || (includeClang && Self.isClangFile(last)) else { continue }
				visited += 1
				if visited > fileLimit { return (found, true) }
				guard let data = try? Data(contentsOf: url), let text = String(data: data, encoding: .utf8), text.contains(name)
				else { continue }
				// A Swift file can only use a declaration from another module if it imports that module.
				if let module, isSwift, !(([module] + reexporters).contains { url.path.contains("/Sources/\($0)/") || importsModule(text, $0) }) {
					continue
				}
				for (offset, line) in sourceLines(text).enumerated() {
					let trimmed = line.trimmingCharacters(in: .whitespaces)
					if trimmed.hasPrefix("//") || trimmed.hasPrefix("*") || trimmed.hasPrefix("/*") || trimmed.hasPrefix("import ")
						|| trimmed.hasPrefix("#import") || trimmed.hasPrefix("#include")
					{
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

	/// The `.swift` files under `roots` that use any of `names` as a whole word outside comments and `import` lines,
	/// in one walk of the tree (a walk per name costs a full read of every file each time). Stops after `fileLimit`
	/// files; `truncated` says there were more.
	static func filesMentioning(anyOf names: [String], under roots: [URL], fileLimit: Int = 4000) -> (paths: [String], truncated: Bool) {
		let valid = names.filter { $0.range(of: #"^[A-Za-z_][A-Za-z0-9_]*$"#, options: .regularExpression) != nil }
		guard !valid.isEmpty,
			let pattern = try? NSRegularExpression(
				pattern: "(?<![A-Za-z0-9_])(?:" + valid.map { NSRegularExpression.escapedPattern(for: $0) }.joined(separator: "|") + ")(?![A-Za-z0-9_])")
		else { return ([], false) }
		var paths: [String] = []
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
				if visited > fileLimit { return (paths, true) }
				guard let data = try? Data(contentsOf: url), let text = String(data: data, encoding: .utf8),
					valid.contains(where: { text.contains($0) })
				else { continue }
				for line in sourceLines(text) {
					let trimmed = line.trimmingCharacters(in: .whitespaces)
					if trimmed.hasPrefix("//") || trimmed.hasPrefix("*") || trimmed.hasPrefix("/*") || trimmed.hasPrefix("import ") { continue }
					if pattern.firstMatch(in: line, range: NSRange(location: 0, length: (line as NSString).length)) != nil {
						paths.append(url.path)
						break
					}
				}
			}
		}
		return (paths, false)
	}

	/// Modules that make `module` visible to whoever imports them (`@_exported import module`), transitively:
	/// an app that only imports `Octopus` still uses `DIC` types when Octopus re-exports DIC.
	static func reexportingModules(of module: String, under roots: [URL], fileLimit: Int = 4000) -> Set<String> {
		guard let pattern = try? NSRegularExpression(
			pattern: #"(?m)^\s*@_exported\s+(?:@\w+\s+)*import\s+(?:(?:struct|class|enum|protocol|func|var|let|typealias)\s+)?([A-Za-z_][A-Za-z0-9_]*)"#)
		else { return [] }
		var exports: [String: Set<String>] = [:]  // re-exporting module -> modules it re-exports
		var visited = 0
		for root in roots {
			guard let enumerator = FileManager.default.enumerator(
				at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
			else { continue }
			for case let url as URL in enumerator {
				if Exclude.directoryNames.contains(url.lastPathComponent) {
					enumerator.skipDescendants()
					continue
				}
				guard url.lastPathComponent.hasSuffix(".swift"), let owner = moduleName(ofPath: url.path) else { continue }
				visited += 1
				if visited > fileLimit { break }
				guard let data = try? Data(contentsOf: url), let text = String(data: data, encoding: .utf8),
					text.contains("@_exported")
				else { continue }
				for match in pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
					if let range = Range(match.range(at: 1), in: text) { exports[owner, default: []].insert(String(text[range])) }
				}
			}
		}
		var reaching: Set<String> = [module]
		var grew = true
		while grew {
			grew = false
			for (owner, exported) in exports where !reaching.contains(owner) && !exported.isDisjoint(with: reaching) {
				reaching.insert(owner)
				grew = true
			}
		}
		reaching.remove(module)
		return reaching
	}

	/// `import M`, `@testable import M`, `import struct M.Type` (not a mention in a comment or string).
	static func importsModule(_ text: String, _ module: String) -> Bool {
		let pattern = "(?m)^\\s*(?:@\\w+(?:\\([^)]*\\))?\\s+)*import\\s+(?:(?:struct|class|enum|protocol|func|var|let|typealias)\\s+)?"
			+ NSRegularExpression.escapedPattern(for: module) + "(?![A-Za-z0-9_])"
		return text.range(of: pattern, options: .regularExpression) != nil
	}

	/// The SwiftPM target a source path belongs to (`.../Sources/<Target>/...`), when it has that layout.
	static func moduleName(ofPath path: String) -> String? {
		guard let range = path.range(of: "/Sources/", options: .backwards) else { return nil }
		let rest = path[range.upperBound...].split(separator: "/", omittingEmptySubsequences: true)
		guard rest.count >= 2 else { return nil }  // a file directly in Sources/ has no target directory
		return String(rest[0])
	}

	/// Objective-C spellings of the Swift declaration on `lines[index]`: the selector an explicit
	/// `@objc(selector:)` names (on that line or the one above), else the usual `base`+`Label` guesses.
	static func objcAliases(declaredAt index: Int, in lines: [String], word: String) -> [String] {
		guard index >= 0, index < lines.count else { return [] }
		for candidate in [lines[index]] + (index > 0 ? [lines[index - 1]] : []) {
			if let range = candidate.range(of: #"@objc\(\s*([A-Za-z_][A-Za-z0-9_]*)"#, options: .regularExpression) {
				let name = candidate[range].drop(while: { $0 != "(" }).dropFirst().trimmingCharacters(in: .whitespaces)
				if name != word { return [name] }
			}
		}
		guard let name = swiftName(declaredOn: lines[index], word: word) else { return [] }
		return objcSpellings(ofSwiftName: name)
	}

	/// `func increment(by amount: Int)` -> `increment(by:)`.
	static func swiftName(declaredOn line: String, word: String) -> String? {
		let pattern = "\\bfunc\\s+" + NSRegularExpression.escapedPattern(for: word) + "\\s*(?:<[^>]*>)?\\s*\\(([^)]*)\\)"
		guard let regex = try? NSRegularExpression(pattern: pattern),
			let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
			let range = Range(match.range(at: 1), in: line)
		else { return nil }
		let parameters = line[range].split(separator: ",").map { parameter -> String in
			let label = parameter.split(whereSeparator: { $0 == " " || $0 == ":" }).first.map(String.init) ?? "_"
			return label + ":"
		}
		return word + "(" + parameters.joined() + ")"
	}

	static func isClangFile(_ fileName: String) -> Bool {
		["m", "mm", "h", "c", "cc", "cpp", "cxx", "hpp"].contains((fileName as NSString).pathExtension.lowercased())
	}

	/// How Objective-C code spells a Swift method exposed with `@objc`: `increment(by:)` is `incrementBy:`
	/// (or `incrementWithBy:`), so a plain-name scan would miss every Objective-C caller. Verification by
	/// the language server discards the guesses that aren't the declaration.
	static func objcSpellings(ofSwiftName name: String) -> [String] {
		let base = NavShared.baseName(name)
		guard let open = name.firstIndex(of: "("), let close = name.lastIndex(of: ")"), open < close else { return [] }
		let labels = name[name.index(after: open)..<close].split(separator: ":").map(String.init)
		guard let first = labels.first, first != "_", let initial = first.first else { return [] }
		let capitalized = initial.uppercased() + first.dropFirst()
		return [base + capitalized, base + "With" + capitalized]
	}

	static func findUsages(of name: String, under root: URL, limit: Int = 1) -> [Occurrence] {
		occurrences(of: name, under: [root], limit: limit, perFile: true).hits
	}

	static func findUsage(of name: String, under root: URL) -> Occurrence? {
		findUsages(of: name, under: root).first
	}
}
