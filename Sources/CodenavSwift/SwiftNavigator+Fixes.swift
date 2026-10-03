import Foundation
import NavShared

// Compiler fix-its, language-server refactorings and conformance stubs. What sourcekit-lsp generates is
// correct but rough: wrong indentation for the file, stub bodies that don't compile, default names.
// These tools clean that up before the usual compile check.

enum GeneratedCode {
	/// Re-indents text a language server generated to the file's style, and makes it fit where it lands.
	static func normalize(_ edits: [TextEdit], in text: String, unit: Indentation.Unit) -> [TextEdit] {
		let index = TextIndex(text)
		return edits.map { edit in
			var newText = edit.newText
			guard newText.contains("\n") else { return edit }
			let line = edit.range.start.line
			let base = Indentation.leading(of: index.lineText(line))
			let startsLine = edit.range.start.character == 0 || edit.range.start.character <= base.utf16.count
			// A block that starts on a line break carries its own first-line indentation.
			if newText.hasPrefix("\n") {
				let rest = String(newText.dropFirst())
				newText = "\n" + restyle(rest, base: base, unit: unit, indentFirstLine: true)
			} else {
				newText = restyle(newText, base: base, unit: unit, indentFirstLine: false)
				// An insertion at the indentation point that ends with a line break pushes the old line to column 0.
				if edit.range.start == edit.range.end, startsLine, newText.hasSuffix("\n") { newText += base }
			}
			return TextEdit(range: edit.range, newText: newText)
		}
	}

	/// `indentFirstLine`: the text starts on a fresh line, so its first line needs the indentation too.
	private static func restyle(_ block: String, base: String, unit: Indentation.Unit, indentFirstLine: Bool) -> String {
		let generated = Indentation.detect(in: block)
		let lines = block.components(separatedBy: "\n")
		let body = indentFirstLine ? lines : Array(lines.dropFirst())
		let flat = body.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.allSatisfy { Indentation.leading(of: $0).isEmpty }
		if flat {
			// No nesting in the text: rebuild it from the braces.
			let rebuilt = Indentation.reindent(block, base: base, unit: unit)
			return indentFirstLine ? base + rebuilt : rebuilt
		}
		// Keep the shape, in the file's unit. The server may or may not already have counted our base indentation.
		return lines.enumerated().map { offset, line in
			if offset == 0, !indentFirstLine { return line }
			guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { return line }
			var leading = Indentation.leading(of: line)
			if !base.isEmpty, leading.hasPrefix(base) { leading = String(leading.dropFirst(base.count)) }
			return base + Indentation.convert(leading, from: generated, to: unit) + line.dropFirst(Indentation.leading(of: line).count)
		}.joined(separator: "\n")
	}

	/// Compiler fix-its leave a blank line before what follows them (`case .x:\n\n}`, a stub block followed
	/// by the line break that was already there): one newline is enough.
	static func trimTrailingBlankLine(_ edits: [TextEdit], in text: String) -> [TextEdit] {
		let index = TextIndex(text)
		return edits.map { edit in
			var newText = edit.newText
			let next = (try? index.offset(edit.range.end)).flatMap { $0 < index.units.count ? index.units[$0] : nil }
			if newText.hasSuffix("\n\n") {
				newText.removeLast()
			} else if newText.hasSuffix("\n"), next == 0x0A || next == 0x0D {
				newText.removeLast()
			}
			return TextEdit(range: edit.range, newText: newText)
		}
	}

	/// A stub the compiler adds for a missing protocol requirement has an empty body, which does not compile
	/// when the function returns a value: give those a `fatalError`.
	static func fillStubBodies(_ text: String, unit: Indentation.Unit) -> String {
		let lines = text.components(separatedBy: "\n")
		var output: [String] = []
		var index = 0
		while index < lines.count {
			let line = lines[index]
			output.append(line)
			let trimmed = line.trimmingCharacters(in: .whitespaces)
			let opensValueBody =
				trimmed.hasSuffix("{") && !trimmed.hasPrefix("//")
				&& ((trimmed.contains("func ") && trimmed.contains("->")) || (trimmed.contains("var ") && trimmed.contains(":") && !trimmed.contains("{ get"))
					|| trimmed.hasPrefix("get") || trimmed.hasPrefix("subscript"))
			if opensValueBody {
				var look = index + 1
				while look < lines.count, lines[look].trimmingCharacters(in: .whitespaces).isEmpty { look += 1 }
				if look < lines.count, lines[look].trimmingCharacters(in: .whitespaces) == "}" {
					let closing = Indentation.leading(of: lines[look])
					output.append(closing + unit.text + "fatalError(\"Not implemented\")")
					index = look  // skip the blank lines, keep the closing brace
					continue
				}
			}
			index += 1
		}
		return output.joined(separator: "\n")
	}
}

extension LSPClient {
	/// Every quick fix for a diagnostic: the ones sourcekit-lsp attaches to it, plus what `codeAction` offers
	/// for it (missing switch cases and protocol stubs only come that way).
	func quickFixes(_ path: String, for diagnostic: LSPDiagnostic) async -> [LSPCodeAction] {
		var fixes = diagnostic.fixes.filter { $0.edit != nil }
		let asked = (try? await codeActions(path, range: diagnostic.range, diagnostics: [diagnostic], only: ["quickfix"])) ?? []
		for fix in asked where fix.edit != nil && !fixes.contains(where: { $0.title == fix.title }) { fixes.append(fix) }
		return fixes.filter { !$0.title.hasPrefix("Add documentation") }
	}
}

extension SwiftNavigator {
	/// Diagnostics for the files of a staged proposal, as the compiler sees them with the changes in place.
	func diagnoseStaged(_ client: LSPClient, staging: Staging, paths: [String]) async throws -> [String: [LSPDiagnostic]] {
		let plan = staging.plan()
		for change in plan.changes where EditEngine.isSwiftSource(change.path) { await client.setOverlay(change.path, text: change.after ?? "") }
		var result: [String: [LSPDiagnostic]] = [:]
		do {
			await client.touch(plan.changes.map(\.path).filter(EditEngine.isSwiftSource))
			for path in paths { result[path] = try await client.diagnostics(path) }
		} catch {
			await client.clearAllOverlays()
			throw error
		}
		await client.clearAllOverlays()
		await client.touch(plan.changes.map(\.path).filter(EditEngine.isSwiftSource))
		return result
	}

	// MARK: fix_diagnostics

	/// The fix-it to apply: the one the server marks preferred, else the first. A force-unwrap fix-it turns a type
	/// error into a possible crash, so it is only taken when `only` asks for it.
	static func preferredFix(_ fixes: [LSPCodeAction], only: String?) -> LSPCodeAction? {
		let asked = only.map { $0.contains("unwrap") || $0.contains("optional") || $0.contains("!") } ?? false
		let safe = fixes.filter { asked || !$0.title.lowercased().contains("force unwrap") }
		return safe.first { $0.isPreferred == true } ?? safe.first
	}

	public func fixDiagnostics(arguments: ToolArguments) async -> ToolResult {
		await runWrite { client in
			let options = try EditOptions(arguments)
			var staging = self.stagingForWorkspace()
			let filePath = staging.canonical(try self.checkSwiftFile(try arguments.requiredString("file_path")))
			let only = arguments.string("only")?.lowercased()
			let line = try arguments.optionalInt("line")
			let rounds = max(1, min(try arguments.optionalInt("rounds") ?? 3, 6))
			guard try staging.read(filePath) != nil else { throw ToolInputError("\(arguments.string("file_path") ?? filePath) doesn't exist.") }
			var applied: [String] = []
			var skipped: [String] = []
			for _ in 0..<rounds {
				let diagnostics = try await self.diagnoseStaged(client, staging: staging, paths: [filePath])[filePath] ?? []
				guard let text = try staging.read(filePath) else { break }
				let index = TextIndex(text)
				var edits: [TextEdit] = []
				var round: [String] = []
				for diagnostic in diagnostics where !EditEngine.isAnalysisFailure(diagnostic) {
					if let line, diagnostic.range.start.line + 1 != line { continue }
					if let only, !diagnostic.message.lowercased().contains(only), !(diagnostic.codeText ?? "").lowercased().contains(only) { continue }
					let available = await self.fixesInOverlay(client, staging: staging, path: filePath, diagnostic: diagnostic)
					guard let fix = Self.preferredFix(available, only: only),
						let fileEdits = fix.edit?.fileEdits, fileEdits.count == 1, let proposed = fileEdits.values.first,
						fileEdits.keys.first.flatMap({ uriToPath($0) }).map({ staging.canonical($0) }) == filePath
					else {
						skipped.append("\(diagnostic.range.start.line + 1):\(diagnostic.range.start.character + 1) \(diagnostic.message.components(separatedBy: "\n").first ?? diagnostic.message) (no fix-it)")
						continue
					}
					// Skip a fix that collides with one already chosen this round.
					let candidate = GeneratedCode.normalize(GeneratedCode.trimTrailingBlankLine(proposed, in: text), in: text, unit: Indentation.detect(in: text)).map { edit in
						TextEdit(range: edit.range, newText: GeneratedCode.fillStubBodies(edit.newText, unit: Indentation.detect(in: text)))
					}
					if candidate.contains(where: { new in edits.contains { Self.overlaps($0.range, new.range, in: index) } }) { continue }
					edits.append(contentsOf: candidate)
					round.append("\(diagnostic.range.start.line + 1): \(fix.title)")
				}
				if edits.isEmpty { break }
				try staging.apply(edits, to: filePath)
				applied.append(contentsOf: round)
			}
			if applied.isEmpty {
				let reason = skipped.isEmpty ? "The compiler reports nothing in this file that has a fix-it." : "None of the compiler's diagnostics has a fix-it:\n" + skipped.prefix(10).map { "  " + $0 }.joined(separator: "\n")
				return reason
			}
			staging.note("applied \(applied.count) fix-it(s): " + applied.prefix(12).joined(separator: "; "))
			if !skipped.isEmpty { staging.needsAttention("\(skipped.count) diagnostic(s) have no fix-it: " + skipped.prefix(5).joined(separator: "; ")) }
			return try await self.finishEdit(staging, client: client, title: "fix_diagnostics \(self.relative(URL(fileURLWithPath: filePath).absoluteString))", options: options)
		}
	}

	/// Quick fixes for a diagnostic of the staged text: the staged file has to be what the server holds while it answers.
	func fixesInOverlay(_ client: LSPClient, staging: Staging, path: String, diagnostic: LSPDiagnostic) async -> [LSPCodeAction] {
		for change in staging.plan().changes where EditEngine.isSwiftSource(change.path) { await client.setOverlay(change.path, text: change.after ?? "") }
		let fixes = await client.quickFixes(path, for: diagnostic)
		await client.clearAllOverlays()
		return fixes
	}

	static func overlaps(_ a: LSPRange, _ b: LSPRange, in index: TextIndex) -> Bool {
		guard let a0 = try? index.offset(a.start), let a1 = try? index.offset(a.end), let b0 = try? index.offset(b.start), let b1 = try? index.offset(b.end)
		else { return true }
		if a0 == a1, b0 == b1 { return false }
		return a0 < b1 && b0 < a1 || (a0 == b0)
	}

	// MARK: refactor

	public func refactor(arguments: ToolArguments) async -> ToolResult {
		await runWrite { client in
			let options = try EditOptions(arguments)
			var staging = self.stagingForWorkspace()
			let filePath = staging.canonical(try self.checkSwiftFile(try arguments.requiredString("file_path")))
			guard let text = try staging.read(filePath) else { throw ToolInputError("\(arguments.string("file_path") ?? filePath) doesn't exist.") }
			let index = TextIndex(text)
			let line = try arguments.int("line")
			let endLine = try arguments.optionalInt("end_line") ?? line
			guard line >= 1, endLine >= line, endLine <= index.lineCount else {
				throw ToolInputError("Lines \(line)-\(endLine) are out of range (the file has \(index.lineCount) line(s)).")
			}
			let range: LSPRange
			if let selection = arguments.values["selection"]?.stringValue, !selection.isEmpty {
				let from = index.lineStarts[line - 1]
				let to = endLine < index.lineStarts.count ? index.lineStarts[endLine] : index.units.count
				let window = index.text(from: from, to: to) as NSString
				var found: [NSRange] = []
				var search = NSRange(location: 0, length: window.length)
				while true {
					let hit = window.range(of: selection, options: [], range: search)
					if hit.location == NSNotFound { break }
					found.append(hit)
					search = NSRange(location: hit.upperBound, length: window.length - hit.upperBound)
				}
				guard found.count == 1 else {
					throw ToolInputError(found.isEmpty
						? "`selection` text was not found on lines \(line)-\(endLine). Copy it exactly from the file."
						: "`selection` appears \(found.count) times on lines \(line)-\(endLine); narrow `line`/`end_line` or include more text.")
				}
				range = LSPRange(start: index.position(at: from + found[0].location), end: index.position(at: from + found[0].upperBound))
			} else if let column = try arguments.optionalInt("column") ?? arguments.string("symbol").map({ try PositionResolver.column(of: $0, onLine: line, in: text, filePath: filePath) }) {
				let start = LSPPosition(line: line - 1, character: column - 1)
				let endColumn = try arguments.optionalInt("end_column")
				range = LSPRange(start: start, end: LSPPosition(line: endLine - 1, character: (endColumn ?? column) - 1))
			} else {
				// A whole line (its code, without the indentation).
				let content = index.lineText(line - 1)
				let indent = Indentation.leading(of: content).utf16.count
				range = LSPRange(
					start: LSPPosition(line: line - 1, character: indent),
					end: LSPPosition(line: endLine - 1, character: index.lineText(endLine - 1).utf16.count))
			}

			let candidates = try await client.codeActions(filePath, range: range, only: ["refactor"]).filter { $0.kind?.hasPrefix("refactor") ?? true }
			let wanted = arguments.string("action")
			guard let wanted else {
				if candidates.isEmpty { return "No refactoring is offered for that range. Try a wider `selection`, or a different line." }
				return "Refactorings available there (pass one as `action`):\n" + candidates.map { "  - \($0.title)" }.joined(separator: "\n")
			}
			let exact = candidates.filter { $0.title.lowercased() == wanted.lowercased() }
			let partial = candidates.filter { $0.title.lowercased().contains(wanted.lowercased()) }
			let chosen = exact.first ?? (partial.count == 1 ? partial[0] : nil)
			guard let chosen else {
				throw ToolInputError(partial.isEmpty
					? "No refactoring called '\(wanted)' is offered there. Available: " + (candidates.map(\.title).joined(separator: ", ").isEmpty ? "none" : candidates.map(\.title).joined(separator: ", "))
					: "'\(wanted)' matches several refactorings: " + partial.map(\.title).joined(separator: ", "))
			}
			var edit = LSPWorkspaceEdit()
			if let direct = chosen.edit { edit.merge(direct) }
			if let command = chosen.command { edit.merge(try await client.executeCommand(command)) }
			guard !edit.isEmpty else { throw ToolInputError("'\(chosen.title)' produced no edits here.") }

			// Tidy up what the server generated: indentation, and the default name it picks.
			let newName = arguments.string("new_name")
			var tidied = LSPWorkspaceEdit()
			for (uri, edits) in edit.fileEdits {
				guard let path = uriToPath(uri), let fileText = try staging.read(staging.canonical(path)) else { continue }
				var normalized = GeneratedCode.normalize(edits, in: fileText, unit: Indentation.detect(in: fileText))
				if let newName {
					guard RenameName.isIdentifier(newName) else { throw ToolInputError("'\(newName)' is not a valid Swift identifier.") }
					normalized = normalized.map { TextEdit(range: $0.range, newText: Self.renameGenerated($0.newText, to: newName)) }
				}
				tidied.fileEdits[uri] = normalized
			}
			try staging.apply(tidied)
			return try await self.finishEdit(staging, client: client, title: "refactor \(chosen.title)", options: options)
		}
	}

	/// `extractedFunc` / `extractedExpr` -> the name the caller asked for.
	static func renameGenerated(_ text: String, to name: String) -> String {
		text.replacingOccurrences(of: #"\bextracted(Func|Expr|Expression|Function|Method|Variable|Var|Property|Closure)\b"#, with: name, options: .regularExpression)
	}

	// MARK: add_conformance

	public func addConformance(arguments: ToolArguments) async -> ToolResult {
		await runWrite { client in
			let options = try EditOptions(arguments)
			var staging = self.stagingForWorkspace()
			let proto = try arguments.requiredString("protocol")
			guard RenameName.isIdentifier(proto.replacingOccurrences(of: ".", with: "_")) else { throw ToolInputError("'\(proto)' is not a valid protocol name.") }
			var args = arguments
			if let type = arguments.string("type") { args.values["name"] = .string(type) }
			let declaration = try await self.locateDeclaration(client, staging: &staging, arguments: args, example: "UserService")
			guard [SymbolKind.class, SymbolKind.structure, SymbolKind.enumeration].contains(declaration.symbol.kind) else {
				throw ToolInputError("\(declaration.qualifiedName) is a \(SymbolKind.label(declaration.symbol.kind)); add_conformance works on classes, structs, enums and actors.")
			}
			let index = declaration.index
			let inline = arguments.bool("inline", default: false)
			let stubs = arguments.bool("stubs", default: true)
			let typeName = declaration.qualifiedName
			let extensionHeader = "extension \(typeName): \(proto) {"
			// Everything is worked out in the type's own file (a file that doesn't exist yet has no build settings,
			// so the compiler can't write stubs there); an `extension_file` only receives the finished block.
			var work = staging
			if inline {
				let scan = declaration.scan
				var cursor = declaration.selectionEnd
				if let next = scan.nextSignificant(from: cursor), scan.units[next] == scan.unit("<"), let close = scan.matching(openAt: next) { cursor = close + 1 }
				guard let body = declaration.body else { throw ToolInputError("\(declaration.qualifiedName) has no body.") }
				let header = scan.text(cursor, body.open)
				let whereAt = header.range(of: " where ").map { cursor + header.utf16.distance(from: header.startIndex, to: $0.lowerBound) }
				let insertionPoint = whereAt ?? (cursor + (header.replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression)).utf16.count)
				let hasInheritance = header.trimmingCharacters(in: .whitespaces).hasPrefix(":")
				if hasInheritance, header.range(of: "(?<![A-Za-z0-9_])\(NSRegularExpression.escapedPattern(for: proto))(?![A-Za-z0-9_])", options: .regularExpression) != nil {
					throw ToolInputError("\(declaration.qualifiedName) already declares \(proto).")
				}
				try work.apply([Self.edit(index, from: insertionPoint, to: insertionPoint, hasInheritance ? ", \(proto)" : ": \(proto)")], to: declaration.path)
			} else {
				// After the outermost enclosing type: an extension can't be declared inside another type's body.
				let endLine = (declaration.parents.first ?? declaration.symbol).range.end.line
				let at = endLine + 1 < index.lineStarts.count ? index.lineStarts[endLine + 1] : index.units.count
				let prefix = (at == index.units.count && !declaration.text.hasSuffix("\n")) ? "\n\n" : "\n"
				try work.apply([Self.edit(index, from: at, to: at, prefix + extensionHeader + "\n}\n")], to: declaration.path)
			}

			if stubs {
				for _ in 0..<2 {
					guard let current = try work.read(declaration.path) else { break }
					let diagnostics = try await self.diagnoseStaged(client, staging: work, paths: [declaration.path])[declaration.path] ?? []
					let base = proto.components(separatedBy: ".").last ?? proto
					guard let missing = diagnostics.first(where: { $0.message.contains("does not conform to protocol '\(base)'") }),
						let fix = await self.fixesInOverlay(client, staging: work, path: declaration.path, diagnostic: missing).first(where: { $0.title.lowercased().contains("stub") }),
						let proposed = fix.edit?.fileEdits.values.first
					else { break }
					let unit = Indentation.detect(in: current)
					let tidy = GeneratedCode.normalize(GeneratedCode.trimTrailingBlankLine(proposed, in: current), in: current, unit: unit).map {
						TextEdit(range: $0.range, newText: GeneratedCode.fillStubBodies($0.newText, unit: unit))
					}
					try work.apply(tidy, to: declaration.path)
				}
				staging.note("requirement stubs were generated by the compiler; bodies that return a value are `fatalError(\"Not implemented\")`, ready to fill in")
			}

			if !inline, let destinationArgument = arguments.string("extension_file") {
				let destination = staging.canonical(try self.checkSwiftFile(destinationArgument))
				guard destination != declaration.path else { throw ToolInputError("`extension_file` is the type's own file; leave it out to put the extension there.") }
				guard let built = try work.read(declaration.path), let start = built.range(of: extensionHeader) else {
					throw ToolInputError("Internal error: the extension was not found after generating it.")
				}
				let startOffset = built.utf16.distance(from: built.startIndex, to: start.lowerBound)
				let scan = SwiftScan(built)
				guard let close = scan.matching(openAt: startOffset + extensionHeader.utf16.count - 1) else { throw ToolInputError("Internal error: unbalanced extension.") }
				let block = scan.text(startOffset, close + 1) + "\n"
				if let existing = try staging.read(destination) {
					let prefix = existing.isEmpty || existing.hasSuffix("\n\n") ? "" : (existing.hasSuffix("\n") ? "\n" : "\n\n")
					try staging.write(existing + prefix + block, to: destination)
				} else {
					let imports = importLayout(of: declaration.text.components(separatedBy: "\n")).topLevel
					try staging.write((imports.isEmpty ? "" : imports.joined(separator: "\n") + "\n\n") + block, to: destination)
					staging.note("\(destinationArgument) is a new file; it is compile-checked after it is written.")
				}
			} else {
				staging = work
			}
			return try await self.finishEdit(
				staging, client: client, title: "add_conformance \(declaration.qualifiedName): \(proto)", options: options, extraNames: [declaration.symbol.name])
		}
	}
}
