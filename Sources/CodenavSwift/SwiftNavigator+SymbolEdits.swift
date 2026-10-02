import Foundation
import NavShared

// Edits addressed by symbol instead of by text: replace a declaration or its body, add a member, delete
// or move a declaration. The language server supplies the exact range of the declaration, so the agent
// never has to quote the text it wants to change, and can't pick the wrong overload.

/// A declaration found through `documentSymbol`, with the text it lives in.
struct Declaration {
	var path: String
	var symbol: DocumentSymbol
	var parents: [DocumentSymbol]
	var siblings: [DocumentSymbol]
	var text: String
	var index: TextIndex
	var scan: SwiftScan
	var unit: Indentation.Unit
	var resolved: ResolvedSymbol

	var startOffset: Int { (try? index.offset(symbol.range.start)) ?? 0 }
	var endOffset: Int { (try? index.offset(symbol.range.end)) ?? index.units.count }
	var selectionEnd: Int { (try? index.offset(symbol.selectionRange.end)) ?? startOffset }
	/// Indentation of the line the declaration starts on.
	var baseIndent: String { Indentation.leading(of: index.lineText(symbol.range.start.line)) }
	var qualifiedName: String { (parents.map(\.name) + [symbol.name]).joined(separator: ".") }

	/// The `{`...`}` of the declaration's body, when it has one.
	var body: (open: Int, close: Int)? { scan.body(of: startOffset..<endOffset, from: selectionEnd) }
}

enum DeclarationLookup {
	static func contains(_ range: LSPRange, _ position: LSPPosition) -> Bool {
		(range.start.line, range.start.character) <= (position.line, position.character)
			&& (position.line, position.character) <= (range.end.line, range.end.character)
	}

	/// The symbol whose name (selection range) is at `position`, with the symbols that enclose it and the
	/// list it belongs to.
	static func find(
		in symbols: [DocumentSymbol], at position: LSPPosition, parents: [DocumentSymbol] = []
	) -> (symbol: DocumentSymbol, parents: [DocumentSymbol], siblings: [DocumentSymbol])? {
		for symbol in symbols where contains(symbol.range, position) {
			if contains(symbol.selectionRange, position) { return (symbol, parents, symbols) }
			if let inner = find(in: symbol.children ?? [], at: position, parents: parents + [symbol]) { return inner }
		}
		return nil
	}

	static let typeKinds: Set<Int> = [5, 10, 11, 23, 3]
	static let callableKinds: Set<Int> = [6, 9, 12]
}

/// Indents `code` to sit at `base`: its first line is returned unindented (it continues text already on
/// the line), every following line carries `base`.
func placeBlock(_ code: String, base: String, unit: Indentation.Unit) -> String {
	var lines = code.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
	while lines.first?.trimmingCharacters(in: .whitespaces).isEmpty == true { lines.removeFirst() }
	while lines.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { lines.removeLast() }
	guard !lines.isEmpty else { return "" }
	lines[0] = String(lines[0].drop(while: { $0 == " " || $0 == "\t" }))
	return Indentation.reindent(lines.joined(separator: "\n"), base: base, unit: unit)
}

extension SwiftNavigator {
	static let positionParameters: [String] = ["name", "file_path", "line", "symbol"]

	/// Resolves the tool's `name` / `file_path`+`line`+`symbol` arguments to a declaration in a workspace file.
	func locateDeclaration(
		_ client: LSPClient, staging: inout Staging, arguments: ToolArguments, example: String
	) async throws -> Declaration {
		let target = try await resolveTarget(
			client, name: arguments.string("name"), query: arguments.string("query"), example: example,
			filePath: arguments.string("file_path"), line: try arguments.optionalInt("line"),
			column: try arguments.optionalInt("column"), symbol: arguments.string("symbol"))
		return try await declaration(for: target.symbol, client: client, staging: &staging)
	}

	func declaration(for resolved: ResolvedSymbol, client: LSPClient, staging: inout Staging) async throws -> Declaration {
		guard let path = uriToPath(resolved.uri) else { throw ToolInputError("'\(resolved.uri)' is not a local file.") }
		guard relativePath(path, in: workspaceRoot) != nil || !isOutsideWorkspace(resolved.uri) else {
			throw ToolInputError("\(resolved.qualifiedName) is declared in \(relative(resolved.uri)), outside the workspace, so it can't be edited.")
		}
		guard let text = try staging.read(path) else { throw ToolInputError("\(path) doesn't exist.") }
		let symbols = try await client.documentSymbol(path)
		let position = LSPPosition(line: resolved.line, character: resolved.column)
		guard let found = DeclarationLookup.find(in: symbols, at: position) else {
			throw ToolInputError(
				"Couldn't find the declaration of \(resolved.qualifiedName) in \(relative(resolved.uri)) at \(resolved.line + 1):\(resolved.column + 1). Is it a local variable or a synthesized member?")
		}
		return Declaration(
			path: staging.canonical(path), symbol: found.symbol, parents: found.parents, siblings: found.siblings, text: text,
			index: TextIndex(text), scan: SwiftScan(text), unit: Indentation.detect(in: text), resolved: resolved)
	}

	static func edit(_ index: TextIndex, from start: Int, to end: Int, _ text: String) -> TextEdit {
		TextEdit(range: LSPRange(start: index.position(at: start), end: index.position(at: end)), newText: text)
	}

	// MARK: edit_symbol

	public func editSymbol(arguments: ToolArguments) async -> ToolResult {
		await runWrite { client in
			let options = try EditOptions(arguments)
			var staging = self.stagingForWorkspace()
			let declaration = try await self.locateDeclaration(client, staging: &staging, arguments: arguments, example: "UserService.create(name:)")
			let newSource = arguments.values["new_source"]?.stringValue
			let newBody = arguments.values["new_body"]?.stringValue
			let oldText = arguments.values["old_text"]?.stringValue
			let newText = arguments.values["new_text"]?.stringValue
			let modes = [newSource != nil, newBody != nil, oldText != nil].filter { $0 }.count
			guard modes == 1 else {
				throw ToolInputError(
					"Give exactly one of: `new_source` (replace the whole declaration), `new_body` (replace what is between its braces), or `old_text`+`new_text` (replace text inside the declaration only).")
			}
			let index = declaration.index
			let title = "edit_symbol \(declaration.qualifiedName)"
			if let newSource {
				try self.replaceDeclaration(declaration, with: newSource, staging: &staging)
			} else if let newBody {
				try self.replaceBody(declaration, with: newBody, staging: &staging)
			} else if let oldText {
				guard let newText else { throw ToolInputError("`old_text` also needs `new_text`.") }
				let slice = index.text(from: declaration.startOffset, to: declaration.endOffset)
				let edits = try FileEditSpec.locate(oldText, new: newText, in: slice, path: "\(declaration.qualifiedName) (\(self.relative(declaration.resolved.uri)))", all: arguments.bool("replace_all", default: false))
				// The slice starts mid-line: shift its positions back into the file.
				let shifted = try edits.map { edit -> TextEdit in
					func move(_ position: LSPPosition) throws -> LSPPosition {
						let sliceIndex = TextIndex(slice)
						let offset = try sliceIndex.offset(position)
						return index.position(at: declaration.startOffset + offset)
					}
					return TextEdit(range: LSPRange(start: try move(edit.range.start), end: try move(edit.range.end)), newText: edit.newText)
				}
				try staging.apply(shifted, to: declaration.path)
			}
			return try await self.finishEdit(staging, client: client, title: title, options: options)
		}
	}

	func replaceDeclaration(_ declaration: Declaration, with source: String, staging: inout Staging) throws {
		let index = declaration.index
		let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
		let hasDoc = trimmed.hasPrefix("///") || trimmed.hasPrefix("/**") || trimmed.hasPrefix("/*")
		let base = declaration.baseIndent
		let placed = placeBlock(source, base: base, unit: declaration.unit)
		guard !placed.isEmpty else { throw ToolInputError("`new_source` is empty; use delete_symbol to remove a declaration.") }
		if hasDoc {
			// The new text carries its own doc comment: it replaces the old one too.
			let first = DeclarationRange.docCommentStart(above: declaration.symbol.range.start.line, in: index)
			let start = index.lineStarts[first]
			try staging.apply([Self.edit(index, from: start, to: declaration.endOffset, base + placed)], to: declaration.path)
		} else {
			try staging.apply([Self.edit(index, from: declaration.startOffset, to: declaration.endOffset, placed)], to: declaration.path)
		}
	}

	func replaceBody(_ declaration: Declaration, with source: String, staging: inout Staging) throws {
		guard let body = declaration.body else {
			throw ToolInputError("\(declaration.qualifiedName) has no body to replace (a protocol requirement or a stored property); use `new_source`.")
		}
		var inner = source.replacingOccurrences(of: "\r\n", with: "\n")
		let trimmed = inner.trimmingCharacters(in: .whitespacesAndNewlines)
		let scan = SwiftScan(trimmed)
		if trimmed.hasPrefix("{"), trimmed.hasSuffix("}"), scan.matching(openAt: 0) == trimmed.utf16.count - 1 {
			inner = String(trimmed.dropFirst().dropLast())  // the caller included the braces
		}
		let base = declaration.baseIndent
		let oldBody = declaration.index.text(from: body.open, to: body.close + 1)
		let lines = inner.components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
		let replacement: String
		if lines.isEmpty {
			replacement = "{}"
		} else if lines.count == 1, !oldBody.contains("\n") {
			replacement = "{ \(lines[0].trimmingCharacters(in: .whitespaces)) }"
		} else {
			let bodyIndent = base + declaration.unit.text
			replacement = "{\n" + bodyIndent + placeBlock(inner, base: bodyIndent, unit: declaration.unit) + "\n" + base + "}"
		}
		try staging.apply([Self.edit(declaration.index, from: body.open, to: body.close + 1, replacement)], to: declaration.path)
	}

	// MARK: insert_member

	public func insertMember(arguments: ToolArguments) async -> ToolResult {
		await runWrite { client in
			let options = try EditOptions(arguments)
			var staging = self.stagingForWorkspace()
			guard let code = arguments.values["code"]?.stringValue, !code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
				throw ToolInputError("Missing required parameter 'code' (the declaration to add).")
			}
			let position = arguments.string("position") ?? "last"
			let containerName = arguments.string("container")
			let edit: TextEdit
			let path: String
			let title: String
			if containerName != nil || (arguments.string("name") != nil) || (arguments.string("line") != nil) {
				var args = arguments
				if let containerName { args.values["name"] = .string(containerName) }
				let declaration = try await self.locateDeclaration(client, staging: &staging, arguments: args, example: "UserService")
				guard DeclarationLookup.typeKinds.contains(declaration.symbol.kind) else {
					throw ToolInputError("\(declaration.qualifiedName) is a \(SymbolKind.label(declaration.symbol.kind)), not a type or extension: pass the type to add the member to.")
				}
				guard let body = declaration.body else { throw ToolInputError("\(declaration.qualifiedName) has no body to add a member to.") }
				let container = MemberContainer(
					children: (declaration.symbol.children ?? []).filter { $0.kind != 26 || $0.range.start.line != declaration.symbol.range.start.line },
					body: body, baseIndent: declaration.baseIndent, isFile: false)
				edit = try Self.memberInsertion(code, container: container, position: position, text: declaration.text, index: declaration.index, unit: declaration.unit)
				path = declaration.path
				title = "insert_member into \(declaration.qualifiedName)"
			} else if let filePath = arguments.string("file_path") {
				let absolute = staging.canonical(try self.checkSwiftFile(filePath))
				guard let text = try staging.read(absolute) else { throw ToolInputError("\(filePath) doesn't exist; use apply_edit with `content` to create it.") }
				let symbols = try await client.documentSymbol(absolute)
				let container = MemberContainer(children: symbols, body: nil, baseIndent: "", isFile: true)
				edit = try Self.memberInsertion(code, container: container, position: position, text: text, index: TextIndex(text), unit: Indentation.detect(in: text))
				path = absolute
				title = "insert_member into \(self.relative(URL(fileURLWithPath: absolute).absoluteString))"
			} else {
				throw ToolInputError("Pass `container` (the type to add the member to), or `file_path` to add a top-level declaration.")
			}
			try staging.apply([edit], to: path)
			return try await self.finishEdit(staging, client: client, title: title, options: options)
		}
	}

	struct MemberContainer {
		var children: [DocumentSymbol]
		var body: (open: Int, close: Int)?
		var baseIndent: String
		var isFile: Bool
	}

	private static let compactStart = try! NSRegularExpression(pattern: #"^\s*((@\w+(\([^)]*\))?|public|private|fileprivate|internal|open|static|final|lazy|weak|let|var|case|typealias|nonisolated)\s+)+"#)

	static func isCompact(_ code: String) -> Bool {
		let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
		return !trimmed.contains("\n") && !trimmed.contains("{") && !trimmed.contains("func ")
	}

	static func isCompact(_ symbol: DocumentSymbol, in index: TextIndex) -> Bool {
		symbol.range.start.line == symbol.range.end.line && !index.lineText(symbol.range.start.line).contains("{")
	}

	static func memberInsertion(
		_ code: String, container: MemberContainer, position: String, text: String, index: TextIndex, unit: Indentation.Unit
	) throws -> TextEdit {
		let members = container.children.filter { $0.kind != 26 || container.isFile }
		let memberIndent: String
		if container.isFile {
			memberIndent = ""
		} else if let first = members.first {
			memberIndent = Indentation.leading(of: index.lineText(first.range.start.line))
		} else {
			memberIndent = container.baseIndent + unit.text
		}
		let placed = memberIndent + placeBlock(code, base: memberIndent, unit: unit)
		let compactNew = isCompact(code)
		func blank(_ line: Int) -> Bool { line < 0 || line >= index.lineCount || index.lineText(line).trimmingCharacters(in: .whitespaces).isEmpty }
		func lineStart(_ line: Int) -> Int { line < index.lineStarts.count ? index.lineStarts[line] : index.units.count }

		var spec = position.trimmingCharacters(in: .whitespaces)
		var anchorName: String?
		if let colon = spec.firstIndex(of: ":") {
			anchorName = String(spec[spec.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
			spec = String(spec[..<colon]).lowercased()
		} else {
			spec = spec.lowercased()
		}
		func anchor() throws -> DocumentSymbol {
			guard let anchorName, !anchorName.isEmpty else { throw ToolInputError("`position` \(spec): needs a member name, e.g. `after:create(name:)`.") }
			let matches = members.filter { $0.name == anchorName || NavShared.baseName($0.name) == anchorName }
			guard !matches.isEmpty else {
				throw ToolInputError("No member '\(anchorName)' to put it \(spec). Members: " + members.map(\.name).joined(separator: ", "))
			}
			guard matches.count == 1 else {
				throw ToolInputError("'\(anchorName)' matches \(matches.count) members; include argument labels, e.g. `\(matches[0].name)`.")
			}
			return matches[0]
		}

		switch spec {
		case "last":
			if container.isFile {
				var prefix = ""
				if !text.isEmpty, !text.hasSuffix("\n") { prefix = "\n" }
				if !text.isEmpty, !blank(index.lineCount - (text.hasSuffix("\n") ? 2 : 1)) { prefix += "\n" }
				let at = index.position(at: index.units.count)
				return TextEdit(range: LSPRange(start: at, end: at), newText: prefix + placed + "\n")
			}
			guard let body = container.body else { throw ToolInputError("The container has no body.") }
			let closeLine = index.position(at: body.close).line
			let beforeClose = index.text(from: lineStart(closeLine), to: body.close)
			if beforeClose.trimmingCharacters(in: .whitespaces).isEmpty {
				let hasContent = !index.text(from: body.open + 1, to: lineStart(closeLine)).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
				let lastCompact = members.last.map { isCompact($0, in: index) } ?? false
				let needBlank = hasContent && !blank(closeLine - 1) && !(compactNew && lastCompact)
				let at = index.position(at: lineStart(closeLine))
				return TextEdit(range: LSPRange(start: at, end: at), newText: (needBlank ? "\n" : "") + placed + "\n")
			}
			guard index.text(from: body.open + 1, to: body.close).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
				throw ToolInputError("The container's body is on a single line with content; use edit_symbol to rewrite it.")
			}
			return edit(index, from: body.open + 1, to: body.close, "\n" + placed + "\n" + container.baseIndent)
		case "first":
			if container.isFile {
				var afterImports = 0
				for line in 0..<index.lineCount {
					let trimmed = index.lineText(line).trimmingCharacters(in: .whitespaces)
					if trimmed.hasPrefix("import ") || trimmed.hasPrefix("@testable import ") || trimmed.hasPrefix("@_exported import ") || trimmed.hasPrefix("@preconcurrency import ") {
						afterImports = line + 1
					}
				}
				let at = index.position(at: lineStart(afterImports))
				let followedByCode = afterImports < index.lineCount && !blank(afterImports)
				return TextEdit(
					range: LSPRange(start: at, end: at),
					newText: (afterImports > 0 ? "\n" : "") + placed + "\n" + (followedByCode ? "\n" : ""))
			}
			guard let body = container.body else { throw ToolInputError("The container has no body.") }
			let openLine = index.position(at: body.open).line
			guard index.text(from: body.open + 1, to: index.lineEnd(openLine)).trimmingCharacters(in: .whitespaces).isEmpty,
				body.close >= lineStart(openLine + 1)
			else { throw ToolInputError("The container's body starts on the same line as its brace; use edit_symbol to rewrite it.") }
			let hasContent = !members.isEmpty
			let firstCompact = members.first.map { isCompact($0, in: index) } ?? false
			let at = index.position(at: lineStart(openLine + 1))
			return TextEdit(range: LSPRange(start: at, end: at), newText: placed + "\n" + (hasContent && !(compactNew && firstCompact) ? "\n" : ""))
		case "after":
			let member = try anchor()
			let nextLine = member.range.end.line + 1
			let nextIsClose = nextLine < index.lineCount && index.lineText(nextLine).trimmingCharacters(in: .whitespaces).hasPrefix("}")
			let compactPair = compactNew && isCompact(member, in: index)
			let blankBefore = !compactPair
			let blankAfter = !blank(nextLine) && !nextIsClose && !compactPair
			let at = index.position(at: lineStart(nextLine))
			var prefix = blankBefore ? "\n" : ""
			if nextLine >= index.lineCount, !text.hasSuffix("\n") { prefix = "\n" + prefix }
			return TextEdit(range: LSPRange(start: at, end: at), newText: prefix + placed + "\n" + (blankAfter ? "\n" : ""))
		case "before":
			let member = try anchor()
			let first = DeclarationRange.docCommentStart(above: member.range.start.line, in: index)
			let compactPair = compactNew && isCompact(member, in: index)
			let previous = first - 1
			let previousIsOpen = previous >= 0 && index.lineText(previous).trimmingCharacters(in: .whitespaces).hasSuffix("{")
			let blankBefore = previous >= 0 && !blank(previous) && !previousIsOpen && !compactPair
			let at = index.position(at: lineStart(first))
			return TextEdit(range: LSPRange(start: at, end: at), newText: (blankBefore ? "\n" : "") + placed + "\n" + (compactPair ? "" : "\n"))
		default:
			throw ToolInputError("`position` must be `last`, `first`, `after:<member>` or `before:<member>`, got '\(position)'.")
		}
	}

	// MARK: delete_symbol

	public func deleteSymbol(arguments: ToolArguments) async -> ToolResult {
		await runWrite { client in
			let options = try EditOptions(arguments)
			var staging = self.stagingForWorkspace()
			let declaration = try await self.locateDeclaration(client, staging: &staging, arguments: arguments, example: "UserService.find(id:)")
			let index = declaration.index
			let range = declaration.symbol.range
			if let shared = declaration.siblings.first(where: { sibling in
				sibling.range != range && sibling.range.start.line <= range.end.line && sibling.range.end.line >= range.start.line
			}) {
				throw ToolInputError(
					"\(declaration.qualifiedName) shares a line with \(shared.name); use edit_symbol on the enclosing declaration to remove just one of them.")
			}
			await self.awaitIndex(client)
			let found = try await self.referencesWithUsageFallback(
				client, file: declaration.path, line: declaration.resolved.line + 1, column: declaration.resolved.column + 1,
				includeDeclaration: false)
			let outside = found.locations.filter { location in
				guard let path = uriToPath(location.uri) else { return true }
				return !(canonicalFileURL(path, relativeTo: self.workspaceRoot).path == declaration.path
					&& (range.start.line...range.end.line).contains(location.range.start.line))
			}
			if !outside.isEmpty, !arguments.bool("force", default: false) {
				throw ToolInputError(
					"\(declaration.qualifiedName) is still used, so it was not deleted:\n"
						+ formatReferencesGrouped(outside, workspaceRoot: self.workspaceRoot, withColumns: true)
						+ "\nChange those usages first (apply_edit / edit_symbol), or pass force=true to delete it anyway and see what breaks.")
			}
			let span = DeclarationRange.wholeLines(of: range, in: index, includingDocComment: true, swallowBlank: true)
			try staging.apply([Self.edit(index, from: span.start, to: span.end, "")], to: declaration.path)
			if !outside.isEmpty { staging.note("\(outside.count) usage(s) of \(declaration.qualifiedName) remain, so the compile check below lists what broke.") }
			return try await self.finishEdit(
				staging, client: client, title: "delete_symbol \(declaration.qualifiedName)", options: options,
				extraNames: [NavShared.baseName(declaration.symbol.name)])
		}
	}

	// MARK: move_symbol

	public func moveSymbol(arguments: ToolArguments) async -> ToolResult {
		await runWrite { client in
			let options = try EditOptions(arguments)
			var staging = self.stagingForWorkspace()
			let toFile = try arguments.requiredString("to_file")
			let declaration = try await self.locateDeclaration(client, staging: &staging, arguments: arguments, example: "Dog")
			guard declaration.parents.isEmpty else {
				throw ToolInputError("\(declaration.qualifiedName) is a member of \(declaration.parents.last?.name ?? "a type"); only top-level declarations can be moved. Use insert_member to add it elsewhere, then delete_symbol.")
			}
			let destination = staging.canonical(try self.checkSwiftFile(toFile))
			guard destination != declaration.path else { throw ToolInputError("\(declaration.qualifiedName) is already in that file.") }
			let index = declaration.index
			let range = declaration.symbol.range
			let snippetSpan = DeclarationRange.wholeLines(of: range, in: index, includingDocComment: true, swallowBlank: false)
			let snippet = index.text(from: snippetSpan.start, to: snippetSpan.end).trimmingCharacters(in: .newlines)
			let removal = DeclarationRange.wholeLines(of: range, in: index, includingDocComment: true, swallowBlank: true)
			let imports = declaration.text.components(separatedBy: "\n").filter {
				let line = $0.trimmingCharacters(in: .whitespaces)
				return line.hasPrefix("import ") || line.hasPrefix("@testable import ") || line.hasPrefix("@_exported import ") || line.hasPrefix("@preconcurrency import ")
			}
			try staging.apply([Self.edit(index, from: removal.start, to: removal.end, "")], to: declaration.path)

			if let existing = try staging.read(destination) {
				let have = Set(existing.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) })
				let missing = imports.filter { !have.contains($0.trimmingCharacters(in: .whitespaces)) }
				let symbols = try await client.documentSymbol(destination)
				let edit = try Self.memberInsertion(
					snippet, container: MemberContainer(children: symbols, body: nil, baseIndent: "", isFile: true),
					position: arguments.string("position") ?? "last", text: existing, index: TextIndex(existing),
					unit: Indentation.detect(in: existing))
				try staging.apply([edit], to: destination)
				if !missing.isEmpty, let current = try staging.read(destination) {
					var lines = current.components(separatedBy: "\n")
					let lastImport = lines.lastIndex { $0.trimmingCharacters(in: .whitespaces).hasPrefix("import ") || $0.trimmingCharacters(in: .whitespaces).hasPrefix("@testable import ") }
					if let lastImport {
						lines.insert(contentsOf: missing, at: lastImport + 1)
					} else {
						lines.insert(contentsOf: missing + [""], at: 0)
					}
					try staging.write(lines.joined(separator: "\n"), to: destination)
					staging.note("added import(s) to \(toFile) that \(declaration.qualifiedName) may need: " + missing.map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: ", "))
				}
			} else {
				let header = imports.isEmpty ? "" : imports.joined(separator: "\n") + "\n\n"
				try staging.write(header + snippet + "\n", to: destination)
				staging.note("\(toFile) is a new file; it is compile-checked after it is written.")
			}
			if snippet.contains("private ") || snippet.hasPrefix("fileprivate") {
				staging.note("\(declaration.qualifiedName) is private/fileprivate: code left behind in the old file can no longer use it.")
			}
			return try await self.finishEdit(
				staging, client: client, title: "move_symbol \(declaration.qualifiedName)", options: options,
				extraNames: [NavShared.baseName(declaration.symbol.name)])
		}
	}
}
