import Foundation
import NavShared

/// What a rename was asked to call the symbol, checked against what it is called now.
struct RenameName: Equatable {
	var base: String
	/// Argument labels, when the new name spells them (`make(named:)`); nil keeps the old labels.
	var labels: [String]?

	static let swiftKeywords: Set<String> = [
		"associatedtype", "class", "deinit", "enum", "extension", "fileprivate", "func", "import", "init", "inout", "internal", "let",
		"open", "operator", "private", "precedencegroup", "protocol", "public", "rethrows", "static", "struct", "subscript",
		"typealias", "var", "break", "case", "catch", "continue", "default", "defer", "do", "else", "fallthrough", "for", "guard", "if",
		"in", "repeat", "return", "throw", "switch", "where", "while", "Any", "as", "await", "false", "is", "nil", "self", "Self",
		"super", "throws", "true", "try",
	]

	/// Parses `make`, `make(named:)`, `make(_:to:)` or a backticked name.
	static func parse(_ raw: String) throws -> RenameName {
		let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !text.isEmpty else { throw ToolInputError("`new_name` is empty.") }
		var base = text
		var labels: [String]?
		if let open = text.firstIndex(of: "(") {
			guard text.hasSuffix(")") else { throw ToolInputError("'\(raw)' is not a valid Swift name: expected something like `make(named:)`.") }
			base = String(text[..<open])
			let inside = text[text.index(after: open)..<text.index(before: text.endIndex)]
			labels = inside.split(separator: ":", omittingEmptySubsequences: false).dropLast().map { String($0).trimmingCharacters(in: .whitespaces) }
			if inside.isEmpty { labels = [] }
			if !inside.isEmpty, !inside.hasSuffix(":") {
				throw ToolInputError("'\(raw)': every argument label ends with a colon, e.g. `make(named:)`, `make(_:to:)`.")
			}
			for label in labels ?? [] where label != "_" && !isIdentifier(label) {
				throw ToolInputError("'\(label)' is not a valid argument label in '\(raw)'.")
			}
		}
		let backticked = base.hasPrefix("`") && base.hasSuffix("`") && base.count > 2
		if backticked { base = String(base.dropFirst().dropLast()) }
		guard isIdentifier(base) else { throw ToolInputError("'\(base)' is not a valid Swift identifier.") }
		if swiftKeywords.contains(base), !backticked {
			throw ToolInputError("'\(base)' is a Swift keyword. If you really want it as a name, write it in backticks: `\(base)`.")
		}
		return RenameName(base: backticked ? "`\(base)`" : base, labels: labels)
	}

	static func isIdentifier(_ text: String) -> Bool {
		text.range(of: #"^[A-Za-z_][A-Za-z0-9_]*$"#, options: .regularExpression) != nil
	}

	/// The full name to hand the language server, given what the symbol is called now.
	func full(replacing old: ParsedQuery) throws -> String {
		if let labels {
			// `reload()` for a function the query named without its (empty) label list is the same name.
			if labels.isEmpty, old.signature == nil { return base }
			guard let signature = old.signature else {
				throw ToolInputError("'\(old.base)' has no argument labels, so the new name can't have any: use `\(base)`.")
			}
			let oldCount = signature.dropFirst().dropLast().split(separator: ":", omittingEmptySubsequences: true).count
			guard labels.count == oldCount else {
				throw ToolInputError(
					"A rename can't change the number of parameters (\(old.base)\(signature) has \(oldCount), the new name has \(labels.count)). Use change_signature to add, remove or reorder parameters."
				)
			}
			return base + "(" + labels.map { $0 + ":" }.joined() + ")"
		}
		return base + (old.signature ?? "")
	}
}

extension SwiftNavigator {
	public func renameSymbol(arguments: ToolArguments) async -> ToolResult {
		await runWrite { client in
			let options = try EditOptions(arguments)
			var staging = self.stagingForWorkspace()
			let requested = try RenameName.parse(try arguments.requiredString("new_name"))
			let target = try await self.resolveTarget(
				client, name: arguments.string("name"), query: arguments.string("query"), example: "UserService.create(name:)",
				filePath: arguments.string("file_path"), line: try arguments.optionalInt("line"),
				column: try arguments.optionalInt("column"), symbol: arguments.string("symbol"))
			let resolved = target.symbol
			guard let path = uriToPath(resolved.uri), !self.isOutsideWorkspace(resolved.uri) || relativePath(path, in: self.workspaceRoot) != nil else {
				throw ToolInputError("\(resolved.qualifiedName) is declared outside the workspace (\(self.relative(resolved.uri))), so it can't be renamed.")
			}
			await self.awaitIndex(client)
			let line = resolved.line + 1
			let column = resolved.column + 1
			guard let prepared = try? await client.prepareRename(path, line: line, column: column) else {
				throw ToolInputError("\(resolved.qualifiedName) can't be renamed here (it is declared in the SDK or a dependency, or is not a renamable symbol).")
			}
			let oldFull = prepared.placeholder ?? resolved.name
			let old = ParsedQuery(oldFull)
			if old.base == "init" || old.base == "subscript" || old.base == "deinit" {
				throw ToolInputError("Initializers and subscripts can't be renamed. To change their parameters use change_signature.")
			}
			let newFull = try requested.full(replacing: old)
			guard newFull != oldFull else { throw ToolInputError("'\(oldFull)' is already called that.") }

			// The declaration, when it is a member we can see (not a local).
			let symbols = try await client.documentSymbol(path)
			let found = DeclarationLookup.find(in: symbols, at: LSPPosition(line: resolved.line, character: resolved.column))
			let original = try staging.read(path) ?? ""
			let originalIndex = TextIndex(original)

			if let found {
				if let clash = found.siblings.first(where: { $0.name == newFull && $0.range != found.symbol.range }) {
					throw ToolInputError(
						"Renaming to '\(newFull)' would collide with the existing \(SymbolKind.label(clash.kind).lowercased()) '\(clash.name)' at \(self.relative(resolved.uri)):\(clash.selectionRange.start.line + 1) in the same scope.")
				}
				if DeclarationLookup.typeKinds.contains(found.symbol.kind), found.parents.isEmpty {
					let others = try await client.workspaceSymbol(requested.base)
						.filter { SymbolKind.types.contains($0.kind) && $0.baseName == requested.base }
					if let other = others.first {
						staging.needsAttention("a type named '\(requested.base)' already exists (\(self.relative(other.location.uri)):\((other.location.range?.start.line ?? 0) + 1)); references may become ambiguous if both are visible together")
					}
				}
			}

			var edit = try await client.rename(path, line: line, column: column, newName: newFull)
			guard !edit.isEmpty else {
				throw ToolInputError("The language server returned no edits for renaming '\(oldFull)'. Is the index ready (`workspace`)? Is the symbol in a file that belongs to a build target?")
			}

			// Optional forwarding alias so existing callers (other packages) keep compiling.
			if arguments.bool("keep_deprecated_alias", default: false) {
				if let found, let alias = Self.deprecatedAlias(for: found.symbol, parents: found.parents, text: original, index: originalIndex, newFull: newFull, newBase: requested.base) {
					let uri = URL(fileURLWithPath: staging.canonical(path)).absoluteString
					let key = edit.fileEdits.keys.first { uriToPath($0).map { staging.canonical($0) } == staging.canonical(path) } ?? uri
					let end = originalIndex.position(at: (try? originalIndex.offset(found.symbol.range.end)) ?? 0)
					edit.fileEdits[key, default: []].append(TextEdit(range: LSPRange(start: end, end: end), newText: alias))
					staging.note("left a deprecated forwarding declaration `\(oldFull)` that calls `\(newFull)`")
				} else {
					staging.needsAttention("keep_deprecated_alias supports functions, methods, properties with a written-out type, and non-generic types; no alias was added for this one")
				}
			}
			// A stored property is also the label of the synthesized memberwise initializer, which the language
			// server doesn't follow: `Type(old: …)` calls become `Type(new: …)`.
			if let found, old.base != requested.base {
				let labels = try await self.memberwiseLabelEdits(
					client, symbol: found.symbol, parents: found.parents, path: path, oldBase: old.base, newBase: requested.base, existing: edit, staging: &staging)
				for (uri, edits) in labels.edits { edit.fileEdits[uri, default: []] += edits }
				if labels.count > 0 { staging.note("also updated \(labels.count) memberwise-initializer label(s) `\(old.base):` → `\(requested.base):`") }
			}
			try staging.apply(edit)

			// What the rename can't know about.
			let baseChanged = old.base != requested.base
			if baseChanged {
				let mentions = try self.mentions(of: old.base, staging: &staging)
				if !mentions.comments.isEmpty {
					staging.needsAttention(
						"`\(old.base)` still appears in \(mentions.comments.count) comment/string(s), left as they are: "
							+ Self.perFile(mentions.comments)
							+ " (strings such as #selector names, JSON keys or storyboard identifiers are not updated by a rename)")
				}
				let inactive = mentions.code.filter { $0.condition != nil }
				if !inactive.isEmpty {
					let conditions = Set(inactive.compactMap(\.condition)).sorted().prefix(3).map { "`\($0)`" }.joined(separator: ", ")
					staging.needsAttention(
						"\(inactive.count) of the remaining `\(old.base)` position(s) are inside conditional compilation (\(conditions)): the compiler only sees the branches active in this build, so these are likely real references the rename missed, and the in-memory check and a Debug build can pass while another configuration breaks: "
							+ Self.perFile(inactive))
				}
				if !mentions.code.isEmpty {
					let shown = Self.perFile(mentions.code)
					staging.needsAttention(
						"`\(old.base)` still appears in \(mentions.code.count) code position(s) (other symbols with the same name, or places the compiler couldn't resolve, such as Objective-C; a conforming type or caller in a module the language server can't see into belongs here): \(shown)")
				}
			}
			if let found {
				Self.semanticWarnings(
					for: found.symbol, parents: found.parents, text: original, index: originalIndex, newFull: newFull,
					aliasKept: arguments.bool("keep_deprecated_alias", default: false), staging: &staging)
			}
			// The language server takes `reload` for a no-argument function; show it the way the user wrote it.
			let shownOld = Self.displayName(oldFull, noArguments: resolved.qualifiedName.hasSuffix("()"))
			let shownNew = Self.displayName(newFull, noArguments: requested.labels?.isEmpty == true)
			staging.note("renamed \(shownOld) → \(shownNew) across \(staging.plan().changes.count) file(s)")
			return try await self.finishEdit(
				staging, client: client, title: "rename_symbol \(resolved.qualifiedName) → \(shownNew)", options: options,
				extraNames: baseChanged ? [old.base] : [])
		}
	}

	/// `name` with `()` appended when it names a function that takes no arguments and doesn't already show them.
	static func displayName(_ name: String, noArguments: Bool) -> String {
		noArguments && !name.contains("(") ? name + "()" : name
	}

	/// Edits for the calls of a struct's synthesized memberwise initializer that pass `oldBase:` for the renamed
	/// stored property. Nothing when the property isn't a stored member of a struct without its own `init`.
	func memberwiseLabelEdits(
		_ client: LSPClient, symbol: DocumentSymbol, parents: [DocumentSymbol], path: String, oldBase: String, newBase: String, existing: LSPWorkspaceEdit,
		staging: inout Staging
	) async throws -> (edits: [String: [TextEdit]], count: Int) {
		let storedKinds = [SymbolKind.property, SymbolKind.field, SymbolKind.variable, SymbolKind.constant]
		guard storedKinds.contains(symbol.kind), let parent = parents.last, parent.kind == SymbolKind.structure,
			!(parent.children ?? []).contains(where: { $0.kind == SymbolKind.initializer })
		else { return ([:], 0) }
		let original = try staging.read(path) ?? ""
		// Computed properties are not initializer parameters.
		let originalIndex = TextIndex(original)
		let declaration = originalIndex.text(
			from: (try? originalIndex.offset(symbol.range.start)) ?? 0, to: (try? originalIndex.offset(symbol.range.end)) ?? 0)
		let declScan = SwiftScan(declaration)
		let isComputed = declScan.firstTopLevel("{", in: 0..<declScan.units.count).map { brace in
			declScan.firstTopLevel("=", in: 0..<brace) == nil
		} ?? false
		if isComputed || declaration.range(of: #"\bstatic\b|\bclass\b"#, options: .regularExpression) != nil { return ([:], 0) }

		let references = try await client.references(
			path, line: parent.selectionRange.start.line + 1, column: parent.selectionRange.start.character + 1, includeDeclaration: false)
		let typeName = NavShared.baseName(parent.name)
		var result: [String: [TextEdit]] = [:]
		var count = 0
		var seen: Set<String> = []
		for reference in references {
			guard let file = uriToPath(reference.uri), let text = try staging.read(file) else { continue }
			let index = TextIndex(text)
			let scan = SwiftScan(text)
			// A call of the initializer is reported at the start of the type name, as an empty range.
			guard let begin = try? index.offset(reference.range.start), begin + typeName.utf16.count <= scan.units.count,
				scan.text(begin, begin + typeName.utf16.count) == typeName
			else { continue }
			let end = begin + typeName.utf16.count
			guard let call = scan.parenthesized(after: end) else { continue }
			// `Type(` directly; anything between the name and the parenthesis other than generics means it isn't a call.
			let between = scan.text(end, call.open).trimmingCharacters(in: .whitespacesAndNewlines)
			guard between.isEmpty || (between.hasPrefix("<") && between.hasSuffix(">")) else { continue }
			for piece in scan.splitTopLevel(call.open + 1, call.close) {
				guard let colon = scan.firstTopLevel(":", in: piece) else { continue }
				let labelText = scan.text(piece.lowerBound, colon)
				guard labelText.trimmingCharacters(in: .whitespacesAndNewlines) == oldBase else { continue }
				let leading = labelText.count - labelText.drop(while: { $0.isWhitespace || $0.isNewline }).count
				let start = piece.lowerBound + labelText.prefix(leading).utf16.count
				let range = LSPRange(start: index.position(at: start), end: index.position(at: start + oldBase.utf16.count))
				let key = existing.fileEdits.keys.first { uriToPath($0).map { staging.canonical($0) } == staging.canonical(file) } ?? reference.uri
				let covered = existing.fileEdits[key]?.contains { $0.range == range } ?? false
				guard !covered, seen.insert("\(key):\(start)").inserted else { continue }
				result[key, default: []].append(TextEdit(range: range, newText: newBase))
				count += 1
			}
		}
		return (result, count)
	}

	// MARK: Mentions the rename didn't touch

	struct Mention {
		var path: String
		var line: Int
		/// The innermost `#if` / `#elseif` / `#else` line this mention sits under, when it is in conditional compilation.
		var condition: String?
	}

	/// For each line (0-based) inside a conditional-compilation block, the directive that opened its innermost branch.
	static func conditionalContext(of text: String) -> [Int: String] {
		var stack: [String] = []
		var result: [Int: String] = [:]
		for (number, rawLine) in text.components(separatedBy: "\n").enumerated() {
			let line = rawLine.trimmingCharacters(in: .whitespaces)
			if line.hasPrefix("#if") {
				stack.append(line)
			} else if line.hasPrefix("#elseif") || line.hasPrefix("#else") {
				if !stack.isEmpty { stack[stack.count - 1] = line }
			} else if line.hasPrefix("#endif") {
				if !stack.isEmpty { stack.removeLast() }
			} else if let top = stack.last {
				result[number] = top
			}
		}
		return result
	}

	/// Whole-word occurrences of `word` left in the (staged) sources, split into those in code and those in
	/// comments or string literals.
	/// `File.swift (3: L10, L22, L40), Other.swift (1: L7)`: one entry per file, so a file that was missed stands out.
	static func perFile(_ mentions: [Mention], files: Int = 8) -> String {
		var order: [String] = []
		var lines: [String: [Int]] = [:]
		for mention in mentions {
			if lines[mention.path] == nil { order.append(mention.path) }
			lines[mention.path, default: []].append(mention.line)
		}
		let shown = order.prefix(files).map { path -> String in
			let all = lines[path] ?? []
			return "\(path) (\(all.count): " + all.prefix(3).map { "L\($0)" }.joined(separator: ", ") + (all.count > 3 ? ", …" : "") + ")"
		}
		return shown.joined(separator: ", ") + (order.count > files ? " … and \(order.count - files) more file(s)" : "")
	}

	func mentions(of word: String, staging: inout Staging, limit: Int = 200) throws -> (code: [Mention], comments: [Mention]) {
		var code: [Mention] = []
		var comments: [Mention] = []
		let pattern = try NSRegularExpression(pattern: "(?<![A-Za-z0-9_])" + NSRegularExpression.escapedPattern(for: word) + "(?![A-Za-z0-9_])")
		let roots = [workspaceRoot] + ProjectKind.localPackageFolders(in: workspaceRoot)
		var seen: Set<String> = []
		var visited = 0
		for root in roots {
			guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { continue }
			for case let url as URL in enumerator {
				if Exclude.directoryNames.contains(url.lastPathComponent) {
					enumerator.skipDescendants()
					continue
				}
				guard url.pathExtension == "swift" else { continue }
				let path = url.realPath.path
				guard seen.insert(path).inserted else { continue }
				visited += 1
				if visited > 4000 || code.count + comments.count > limit { return (code, comments) }
				let text: String
				if let staged = try staging.read(path) { text = staged } else { continue }
				guard text.contains(word) else { continue }
				let scan = SwiftScan(text)
				let index = TextIndex(text)
				let conditional = Self.conditionalContext(of: text)
				let relativeName = EditFormat.relativeName(path, root: workspaceRoot)
				for match in pattern.matches(in: text, range: NSRange(location: 0, length: (text as NSString).length)) {
					let line = index.position(at: match.range.location).line + 1
					let trimmed = index.lineText(line - 1).trimmingCharacters(in: .whitespaces)
					if trimmed.hasPrefix("import ") { continue }
					if scan.isCode[match.range.location] {
						code.append(Mention(path: relativeName, line: line, condition: conditional[line - 1]))
					} else {
						comments.append(Mention(path: relativeName, line: line, condition: nil))
					}
				}
			}
		}
		return (code, comments)
	}

	// MARK: Warnings that need the declaration

	static func semanticWarnings(
		for symbol: DocumentSymbol, parents: [DocumentSymbol], text: String, index: TextIndex, newFull: String, aliasKept: Bool = false,
		staging: inout Staging
	) {
		let header = index.text(from: (try? index.offset(symbol.range.start)) ?? 0, to: min((try? index.offset(symbol.range.end)) ?? 0, ((try? index.offset(symbol.range.start)) ?? 0) + 300))
		let firstLines = header.components(separatedBy: "\n").prefix(3).joined(separator: " ")
		let ownerHeader: String = {
			guard let parent = parents.last else { return "" }
			let start = (try? index.offset(parent.range.start)) ?? 0
			return index.text(from: start, to: min(start + 300, index.units.count)).components(separatedBy: "{").first ?? ""
		}()
		let isStoredProperty = [SymbolKind.property, SymbolKind.field, SymbolKind.variable, SymbolKind.constant].contains(symbol.kind)
		if isStoredProperty, ["Codable", "Decodable", "Encodable"].contains(where: { ownerHeader.contains($0) }) {
			let hasKeys = (parents.last?.children ?? []).contains { $0.name == "CodingKeys" }
			staging.needsAttention(
				hasKeys
					? "\(parents.last?.name ?? "the type") is Codable and has CodingKeys: update the matching `case` there (the encoded key is what CodingKeys say, so the JSON stays the same only if you keep its raw value)"
					: "\(parents.last?.name ?? "the type") is Codable with synthesized coding: renaming this property CHANGES THE JSON KEY it is encoded as. Add `CodingKeys` with the old raw value if the wire format must stay")
		}
		if firstLines.contains("@objc") || firstLines.contains("@IBOutlet") || firstLines.contains("@IBAction") || firstLines.contains("dynamic ")
			|| firstLines.contains("@NSManaged") || ownerHeader.contains("@objcMembers") || ownerHeader.contains("NSObject")
		{
			staging.needsAttention("this declaration is visible to Objective-C or the runtime (selector strings, Interface Builder connections, KVC/KVO key paths, Core Data) which a rename can't follow")
		}
		if firstLines.range(of: #"\b(public|open)\b"#, options: .regularExpression) != nil {
			staging.note(
				aliasKept
					? "this is public API: callers in other packages keep working through the deprecated forwarding declaration"
					: "this is public API: callers in other packages will break (use keep_deprecated_alias=true to leave a forwarding declaration)")
		}
		if parents.last?.kind == SymbolKind.protocol {
			staging.note("it is a protocol requirement: conforming types' implementations were renamed with it")
		}
	}

	/// A deprecated declaration under the old name that forwards to the new one, to insert after the renamed
	/// declaration: a function that calls it, a property that reads and writes it, or a `typealias` for a type.
	/// Nil when the kind of declaration (or how it is written) can't be forwarded.
	static func deprecatedAlias(
		for symbol: DocumentSymbol, parents: [DocumentSymbol], text: String, index: TextIndex, newFull: String, newBase: String
	) -> String? {
		guard parents.last?.kind != SymbolKind.protocol,
			let start = try? index.offset(symbol.range.start), let end = try? index.offset(symbol.range.end),
			let selectionStart = try? index.offset(symbol.selectionRange.start)
		else { return nil }
		let scan = SwiftScan(text)
		let base = Indentation.leading(of: index.lineText(symbol.range.start.line))
		let oldBase = NavShared.baseName(symbol.name)
		let attribute = "@available(*, deprecated, renamed: \"\(newFull)\")"
		let firstLine = index.lineText(symbol.range.start.line)
		let access = accessModifier(in: firstLine)

		switch symbol.kind {
		case SymbolKind.method, SymbolKind.function:
			guard let body = scan.body(of: start..<end, from: selectionStart),
				let list = scan.parenthesized(after: selectionStart + oldBase.utf16.count),
				let parameters = SignatureEditor.parameters(in: scan, open: list.open, close: list.close),
				!parameters.contains(where: \.isVariadic)
			else { return nil }
			let header = index.text(from: start, to: body.open).trimmingCharacters(in: .whitespacesAndNewlines)
			let tail = scan.text(list.close + 1, body.open)
			var prefix = ""
			if tail.contains("throws") { prefix += "try " }
			if tail.contains("async") { prefix += "await " }
			// The call uses the NEW argument labels: a rename like `scrollTo(_:)` → `scroll(to:)` changes them.
			let newLabels = argumentLabels(of: newFull)
			let arguments = parameters.enumerated().map { offset, parameter -> String in
				let value = parameter.type.hasPrefix("inout ") ? "&" + parameter.name : parameter.name
				let label = newLabels.flatMap { offset < $0.count ? $0[offset] : nil } ?? parameter.label
				return label == "_" ? value : "\(label): \(value)"
			}.joined(separator: ", ")
			return "\n\n\(base)\(attribute)\n\(base)\(header) { \(prefix)\(newBase)(\(arguments)) }"

		case SymbolKind.class, SymbolKind.structure, SymbolKind.enumeration, SymbolKind.protocol:
			// `typealias Old = New`; a generic type would need its parameters repeated.
			let header = index.text(from: selectionStart, to: min(selectionStart + oldBase.utf16.count + 1, index.units.count))
			if header.hasSuffix("<") { return nil }
			let qualifier = access.map { $0 + " " } ?? ""
			return "\n\n\(base)\(attribute)\n\(base)\(qualifier)typealias \(oldBase) = \(newBase)"

		case SymbolKind.property, SymbolKind.field, SymbolKind.variable, SymbolKind.constant:
			// A stored property becomes a deprecated computed one that forwards; it needs its type written out.
			let declaration = index.text(from: start, to: end)
			let declScan = SwiftScan(declaration)
			let nameEnd = selectionStart - start + oldBase.utf16.count
			guard let colon = declScan.nextSignificant(from: nameEnd), declScan.units[colon] == declScan.unit(":") else { return nil }
			var typeEnd = declScan.units.count
			if let equals = declScan.firstTopLevel("=", in: (colon + 1)..<typeEnd) { typeEnd = equals }
			if let brace = declScan.firstTopLevel("{", in: (colon + 1)..<typeEnd) { typeEnd = brace }
			let type = declScan.text(colon + 1, typeEnd).trimmingCharacters(in: .whitespacesAndNewlines)
			guard !type.isEmpty else { return nil }
			// Read-only when it is a `let` or a computed property with no setter.
			let hasAccessors = declScan.firstTopLevel("{", in: nameEnd..<declScan.units.count) != nil
			let observers = declaration.range(of: #"\b(willSet|didSet)\b"#, options: .regularExpression) != nil
			let hasSetter = declaration.range(of: #"\bset\b"#, options: .regularExpression) != nil
			let isConstant = symbol.kind == SymbolKind.constant || firstLine.range(of: #"\blet\b"#, options: .regularExpression) != nil
				|| (hasAccessors && !observers && !hasSetter && declScan.firstTopLevel("=", in: nameEnd..<declScan.units.count) == nil)
			let modifiers = ["static", "class", "nonisolated"].filter { firstLine.range(of: "\\b\($0)\\b", options: .regularExpression) != nil }
			let prefix = ((access.map { [$0] } ?? []) + modifiers).joined(separator: " ")
			let keyword = (prefix.isEmpty ? "" : prefix + " ") + "var"
			let unit = Indentation.detect(in: text).text
			let accessors = isConstant ? "{ \(newBase) }" : "{\n\(base)\(unit)get { \(newBase) }\n\(base)\(unit)set { \(newBase) = newValue }\n\(base)}"
			return "\n\n\(base)\(attribute)\n\(base)\(keyword) \(oldBase): \(type) \(accessors)"

		default:
			return nil
		}
	}

	/// The argument labels a full name spells (`scroll(to:)` → ["to"], `f(_:b:)` → ["_", "b"]); nil when it spells none.
	static func argumentLabels(of fullName: String) -> [String]? {
		guard let open = fullName.firstIndex(of: "("), fullName.hasSuffix(")") else { return nil }
		let inside = fullName[fullName.index(after: open)..<fullName.index(before: fullName.endIndex)]
		return inside.split(separator: ":", omittingEmptySubsequences: false).dropLast().map { String($0).trimmingCharacters(in: .whitespaces) }
	}

	/// The access level written on a declaration line (`open` is forwarded as `public`).
	static func accessModifier(in line: String) -> String? {
		for keyword in ["open", "public", "package", "internal", "fileprivate", "private"]
		where line.range(of: "(?<![A-Za-z0-9_])\(keyword)(?![A-Za-z0-9_])", options: .regularExpression) != nil {
			return keyword == "open" ? "public" : keyword
		}
		return nil
	}
}
