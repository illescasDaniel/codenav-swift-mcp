import Foundation
import NavShared

/// A member the compiler wrote for a type: it exists, an agent can call it, but no declaration in the source
/// has it, so no outline or symbol search will ever list it (a struct's memberwise `init`, the members of
/// Codable / Equatable / Hashable / RawRepresentable / CaseIterable).
struct SynthesizedMember: Equatable {
	/// How the member is named in an outline: `init(name:age:)`, `encode(to:)`, `allCases`.
	var key: String
	/// The declaration as the compiler prints it, without attributes or body.
	var declaration: String
	/// Why it exists: `memberwise initializer`, `Codable`, ...
	var reason: String
}

/// Reads the output of `swiftc -print-ast`: the source with everything the compiler synthesizes written out.
enum ASTDump {
	struct Header {
		var attributes: [String]
		/// Modifiers, keyword, name and signature, with no attributes and no trailing `{`.
		var text: String
		var hasBody: Bool
		var keyword: String
		var name: String
		var key: String
		/// For a nested enum: its `case` names.
		var cases: [String]
	}

	private static let modifiers: Set<String> = [
		"public", "internal", "private", "fileprivate", "open", "package", "static", "final", "override", "required", "convenience",
		"lazy", "weak", "unowned", "nonisolated", "mutating", "nonmutating", "dynamic", "indirect", "prefix", "postfix", "infix",
		"distributed", "consuming", "borrowing",
	]
	private static let keywords: Set<String> = [
		"init", "init?", "init!", "func", "var", "let", "case", "typealias", "enum", "struct", "class", "actor", "subscript", "deinit",
		"associatedtype", "protocol", "extension",
	]

	private static func indentation(_ line: String) -> Int { line.prefix(while: { $0 == " " }).count }

	/// The lines of the body of the type spelled by `path` (`["Outer", "Inner"]`), and the indentation of its members.
	private static func body(of path: [String], in lines: [String]) -> (range: Range<Int>, indent: Int)? {
		var range = 0..<lines.count
		var indent = 0
		for name in path {
			let pattern = "(?<![A-Za-z0-9_])(struct|class|enum|actor)\\s+" + NSRegularExpression.escapedPattern(for: name) + "(?![A-Za-z0-9_])"
			guard let header = range.first(where: { index in
				let line = lines[index]
				return indentation(line) == indent && line.hasSuffix("{") && line.range(of: pattern, options: .regularExpression) != nil
			}) else { return nil }
			guard let close = ((header + 1)..<range.upperBound).first(where: { indentation(lines[$0]) == indent && lines[$0].trimmingCharacters(in: .whitespaces) == "}" })
			else { return nil }
			range = (header + 1)..<close
			indent += 2
		}
		return (range, indent)
	}

	/// The direct members of a type, as the compiler prints them. Nil when the type isn't in the dump.
	static func members(of path: [String], in dump: String) -> [Header]? {
		let lines = dump.components(separatedBy: "\n")
		guard let (range, indent) = body(of: path, in: lines) else { return nil }
		var result: [Header] = []
		var index = range.lowerBound
		while index < range.upperBound {
			let line = lines[index]
			defer { index += 1 }
			guard indentation(line) == indent, !line.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
			let trimmed = line.trimmingCharacters(in: .whitespaces)
			if trimmed.hasPrefix("}") || trimmed.hasPrefix(")") { continue }
			var header = parse(trimmed)
			if header.hasBody, header.keyword == "enum" {
				var cursor = index + 1
				while cursor < range.upperBound, !(indentation(lines[cursor]) == indent && lines[cursor].trimmingCharacters(in: .whitespaces) == "}") {
					let inner = lines[cursor].trimmingCharacters(in: .whitespaces)
					if indentation(lines[cursor]) == indent + 2, inner.hasPrefix("case ") {
						header.cases.append(String(inner.dropFirst(5)).components(separatedBy: "(")[0].trimmingCharacters(in: .whitespaces))
					}
					cursor += 1
				}
			}
			result.append(header)
		}
		return result
	}

	static func parse(_ line: String) -> Header {
		var text = line
		var attributes: [String] = []
		while text.hasPrefix("@") {
			let scan = SwiftScan(text)
			var end = 1
			while end < scan.units.count, SwiftNavigator.isIdentifierUnit(scan.units[end]) { end += 1 }
			if end < scan.units.count, scan.units[end] == scan.unit("("), let close = scan.matching(openAt: end) { end = close + 1 }
			attributes.append(scan.text(0, end))
			text = String(text.dropFirst(text.utf16.distance(from: text.utf16.startIndex, to: text.utf16.index(text.utf16.startIndex, offsetBy: end)))).trimmingCharacters(in: .whitespaces)
		}
		let hasBody = text.hasSuffix("{")
		if hasBody { text = String(text.dropLast()).trimmingCharacters(in: .whitespaces) }

		let tokens = text.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
		var cursor = 0
		// `init(name:` is the keyword `init` followed by its parameter list.
		func word(_ token: String) -> String { String(token.prefix(while: { $0 != "(" && $0 != "<" })) }
		while cursor < tokens.count {
			let token = word(tokens[cursor])
			if modifiers.contains(token) { cursor += 1; continue }
			if token == "class", cursor + 1 < tokens.count, ["func", "var", "let"].contains(word(tokens[cursor + 1])) { cursor += 1; continue }
			break
		}
		let keyword = cursor < tokens.count ? word(tokens[cursor]) : ""
		guard keywords.contains(keyword) || keyword.hasPrefix("init") else {
			return Header(attributes: attributes, text: text, hasBody: hasBody, keyword: "", name: "", key: text, cases: [])
		}
		// Everything after the keyword.
		let afterKeyword: String = {
			guard let range = text.range(of: keyword, range: text.index(text.startIndex, offsetBy: 0)..<text.endIndex) else { return "" }
			return String(text[range.upperBound...])
		}()
		var name = ""
		switch keyword {
		case "init", "init?", "init!": name = "init"
		case "func":
			name = String(afterKeyword.drop(while: { $0 == " " }).prefix(while: { $0 != "(" && $0 != "<" && $0 != " " }))
		default:
			name = String(afterKeyword.drop(while: { $0 == " " }).prefix(while: { $0 != ":" && $0 != " " && $0 != "<" && $0 != "=" && $0 != "(" }))
		}
		// A derived function is printed under an internal name and says what it implements.
		var shown = text
		if keyword == "func", let implemented = attributes.first(where: { $0.hasPrefix("@_implements(") }) {
			let inside = implemented.dropFirst("@_implements(".count).dropLast()
			if let comma = inside.firstIndex(of: ",") {
				let real = inside[inside.index(after: comma)...].trimmingCharacters(in: .whitespaces)
				let realBase = real.components(separatedBy: "(")[0]
				if !realBase.isEmpty, let nameRange = shown.range(of: "func " + name) {
					shown.replaceSubrange(nameRange, with: "func " + realBase)
					name = realBase
				}
			}
		}
		var key = name
		if ["init", "init?", "init!", "func"].contains(keyword) || keyword.hasPrefix("init") {
			let scan = SwiftScan(shown)
			let nameStart = (shown as NSString).range(of: keyword == "func" ? "func " + name : keyword).location
			let nameEnd = nameStart + (keyword == "func" ? 5 + name.utf16.count : keyword.utf16.count)
			if let list = scan.parenthesized(after: nameEnd), let parameters = SignatureEditor.parameters(in: scan, open: list.open, close: list.close) {
				key += "(" + parameters.map { $0.label + ":" }.joined() + ")"
			}
		}
		return Header(attributes: attributes, text: shown, hasBody: hasBody, keyword: keyword.hasPrefix("init") ? "init" : keyword, name: name, key: key, cases: [])
	}

	/// What the compiler added: members of the dump that the source outline (`known`) doesn't list.
	static func synthesized(from headers: [Header], known: Set<String>) -> [SynthesizedMember] {
		var result: [SynthesizedMember] = []
		var seen: Set<String> = []
		for header in headers {
			guard !header.keyword.isEmpty, !["deinit", "case", "subscript"].contains(header.keyword) else { continue }
			let isCodingKeys = header.keyword == "enum" && header.name == "CodingKeys"
			if (header.text.hasPrefix("private ") || header.text.hasPrefix("fileprivate ")), !isCodingKeys { continue }
			guard !known.contains(header.key), !known.contains(header.name), seen.insert(header.key).inserted else { continue }
			var declaration = header.text
			if isCodingKeys, !header.cases.isEmpty { declaration += " { case " + header.cases.joined(separator: ", ") + " }" }
			result.append(SynthesizedMember(key: header.key, declaration: declaration, reason: reason(for: header)))
		}
		return result
	}

	static func reason(for header: Header) -> String {
		if let implemented = header.attributes.first(where: { $0.hasPrefix("@_implements(") }) {
			let protocolName = implemented.dropFirst("@_implements(".count).prefix(while: { $0 != "," })
			return String(protocolName)
		}
		switch (header.keyword, header.name) {
		case ("init", "init") where header.text.contains("(from "): return "Decodable"
		case ("func", "encode"): return "Encodable"
		case ("enum", "CodingKeys"): return "Codable"
		case ("func", "hash"), ("var", "hashValue"): return "Hashable"
		case ("var", "rawValue"), ("typealias", "RawValue"): return "RawRepresentable"
		case ("init", "init") where header.text.contains("(rawValue"): return "RawRepresentable"
		case ("var", "allCases"), ("typealias", "AllCases"): return "CaseIterable"
		case ("init", "init") where !header.hasBody: return "memberwise initializer"
		default: return "compiler-generated"
		}
	}
}

/// The memberwise initializer worked out from the stored properties, for when the compiler can't be asked.
enum InferredMembers {
	/// A stored property that takes part in the memberwise initializer.
	struct Stored {
		var symbol: DocumentSymbol
		/// The type as written; nil when it is inferred from the initial value (`var count = 0`).
		var type: String?
		/// The initial value as written, for a `var` that has one (it becomes a default argument).
		var initial: String?
	}

	/// The properties of a struct in declaration order, or nil when it has no memberwise initializer (not a
	/// struct, or it declares an initializer itself).
	static func storedProperties(of symbol: DocumentSymbol, in text: String) -> [Stored]? {
		guard symbol.kind == SymbolKind.structure else { return nil }
		let children = symbol.children ?? []
		if children.contains(where: { $0.kind == SymbolKind.initializer }) { return nil }  // an explicit init removes the memberwise one
		let index = TextIndex(text)
		var result: [Stored] = []
		for child in children where [SymbolKind.property, SymbolKind.field, SymbolKind.variable, SymbolKind.constant].contains(child.kind) {
			guard let start = try? index.offset(child.range.start), let end = try? index.offset(child.range.end) else { return nil }
			let declaration = index.text(from: start, to: end)
			let line = index.lineText(child.range.start.line)
			if line.range(of: #"\b(static|class|lazy)\b"#, options: .regularExpression) != nil { continue }
			let scan = SwiftScan(declaration)
			let nameEnd = (try? index.offset(child.selectionRange.end)).map { $0 - start } ?? 0
			let equals = scan.firstTopLevel("=", in: nameEnd..<scan.units.count)
			// A computed property (a body without an initial value) isn't stored.
			if equals == nil, scan.firstTopLevel("{", in: nameEnd..<scan.units.count) != nil { continue }
			let isLet = line.range(of: #"\blet\b"#, options: .regularExpression) != nil
			if isLet, equals != nil { continue }  // a constant with a value can't be set
			var type: String?
			if let colon = scan.nextSignificant(from: nameEnd), scan.units[colon] == scan.unit(":") {
				var typeEnd = scan.units.count
				if let equals { typeEnd = equals }
				if let brace = scan.firstTopLevel("{", in: (colon + 1)..<typeEnd) { typeEnd = brace }
				type = scan.text(colon + 1, typeEnd).trimmingCharacters(in: .whitespacesAndNewlines)
			}
			let initial = equals.map { scan.text($0 + 1, scan.units.count).trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "\n")[0] }
			result.append(Stored(symbol: child, type: type, initial: initial))
		}
		return result
	}

	/// The properties whose type isn't written and has to come from elsewhere.
	static func untypedProperties(of symbol: DocumentSymbol, in text: String) -> [DocumentSymbol] {
		(storedProperties(of: symbol, in: text) ?? []).filter { $0.type == nil }.map(\.symbol)
	}

	/// `types` supplies the properties whose type isn't written (name -> type). Nil when one is still missing.
	static func memberwiseInit(for symbol: DocumentSymbol, in text: String, types: [String: String] = [:]) -> SynthesizedMember? {
		guard let stored = storedProperties(of: symbol, in: text) else { return nil }
		var parameters: [String] = []
		for property in stored {
			guard let type = property.type ?? types[property.symbol.name] else { return nil }
			parameters.append("\(property.symbol.name): \(type)" + (property.initial.map { " = " + $0 } ?? ""))
		}
		let key = "init(" + stored.map { $0.symbol.name + ":" }.joined() + ")"
		return SynthesizedMember(key: key, declaration: "internal init(" + parameters.joined(separator: ", ") + ")", reason: "memberwise initializer")
	}

	/// The type a hover reports for a property: `public var count: Int` -> `Int`.
	static func type(fromHover hover: String, property name: String) -> String? {
		for line in hover.components(separatedBy: "\n") {
			let trimmed = line.trimmingCharacters(in: .whitespaces)
			guard trimmed.range(of: "(?<![A-Za-z0-9_])(var|let)\\s+" + NSRegularExpression.escapedPattern(for: name) + "\\s*:", options: .regularExpression) != nil else { continue }
			let scan = SwiftScan(trimmed)
			guard let nameRange = trimmed.range(of: name), let colon = scan.nextSignificant(from: trimmed.utf16.distance(from: trimmed.startIndex, to: nameRange.upperBound)),
				scan.units[colon] == scan.unit(":")
			else { continue }
			var end = scan.units.count
			if let equals = scan.firstTopLevel("=", in: (colon + 1)..<end) { end = equals }
			if let brace = scan.firstTopLevel("{", in: (colon + 1)..<end) { end = brace }
			let type = scan.text(colon + 1, end).trimmingCharacters(in: .whitespacesAndNewlines)
			return type.isEmpty ? nil : type
		}
		return nil
	}
}
