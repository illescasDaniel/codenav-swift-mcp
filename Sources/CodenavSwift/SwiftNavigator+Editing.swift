import Foundation
import NavShared

// The write tools. Every one of them builds a `Staging` (whole-file texts), then hands it to `finishEdit`,
// which compiles the proposal in memory, refuses it when it introduces errors, writes it atomically and
// journals it for `undo_edit`.

struct JournalEntry: Sendable {
	var id: String
	var title: String
	var plan: EditPlan
	var date: Date
}

enum EditRequirement: String {
	case noNewErrors = "no_new_errors"
	case none
}

enum BuildVerification: String {
	case none, build, auto
}

struct EditOptions {
	var require: EditRequirement = .noNewErrors
	var verify: BuildVerification = .auto
	var dryRun = false

	init() {}

	init(_ arguments: ToolArguments, dryRunDefault: Bool = false) throws {
		if let raw = arguments.string("require") {
			guard let value = EditRequirement(rawValue: raw.lowercased()) else {
				throw ToolInputError("`require` must be `no_new_errors` (default) or `none`, got '\(raw)'.")
			}
			require = value
		}
		if let raw = arguments.string("verify") {
			guard let value = BuildVerification(rawValue: raw.lowercased()) else {
				throw ToolInputError("`verify` must be `auto` (default), `build` or `none`, got '\(raw)'.")
			}
			verify = value
		}
		dryRun = arguments.bool("dry_run", default: dryRunDefault)
	}
}

extension ToolArguments {
	/// A JSON array of objects, sent as an array or as a JSON string (some clients stringify nested values).
	func objects(_ key: String) throws -> [[String: JSONValue]]? {
		guard let value = values[key], value != .null else { return nil }
		var array = value.arrayValue
		if array == nil, case .string(let text) = value,
			let data = text.data(using: .utf8), let decoded = try? JSONDecoder().decode(JSONValue.self, from: data)
		{
			array = decoded.arrayValue ?? (decoded.objectValue != nil ? [decoded] : nil)
		}
		guard let array else { throw ToolInputError("Parameter '\(key)' must be an array of objects.") }
		return try array.map {
			guard let object = $0.objectValue else { throw ToolInputError("Every entry of '\(key)' must be an object.") }
			return object
		}
	}
}

extension SwiftNavigator {
	// MARK: Locking and journal

	/// One write tool at a time, and no reader meanwhile: they show proposed texts to the language server and
	/// put proposals on disk for a build, and anything that looked at the project then would see a change
	/// that may never be applied.
	func withWriteLock<T>(_ body: () async throws -> T) async rethrows -> T {
		await acquire(writer: true)
		defer { release(writer: true) }
		return try await body()
	}

	/// Shared opening of every write tool: workspace, language server, and the write lock.
	func runWrite(_ body: @escaping (LSPClient) async throws -> String) async -> ToolResult {
		await runUnlocked {
			try await withWriteLock {
				await useWorkspace()
				let client = try await liveClient()
				loadJournalIfNeeded()
				await client.clearAllOverlays()  // nothing of an earlier, interrupted proposal may be left in memory
				let notice = takeRecoveryNotice()
				do {
					let text = try await body(client)
					return notice.isEmpty ? text : notice + "\n" + text
				} catch let error as ToolInputError where !notice.isEmpty {
					throw ToolInputError(notice + "\n" + error.message)
				}
			}
		}
	}

	func stagingForWorkspace() -> Staging {
		Staging(root: workspaceRoot, allowedRoots: [workspaceRoot] + ProjectKind.localPackageFolders(in: workspaceRoot))
	}

	// MARK: The pipeline

	/// Compiles the staged proposal in memory and, unless this is a dry run or it breaks something,
	/// writes it; files that depend on a changed module are then checked with a real build.
	func finishEdit(
		_ staging: Staging, client: LSPClient, title: String, options: EditOptions, extraNames: Set<String> = [],
		extraFiles: [String] = []
	) async throws -> String {
		var plan = staging.plan()
		plan.extraNames.formUnion(extraNames)
		plan.extraFiles.append(contentsOf: extraFiles)
		guard !plan.isEmpty else {
			var text = "Nothing to change: the edit leaves every file as it is."
			if !plan.manual.isEmpty { text += "\n" + manualSection(plan) }
			return text
		}
		let engine = EditEngine(client: client, root: workspaceRoot, graph: await packageGraph(), xcodeModules: xcodeModules())
		var report = try await engine.check(plan)
		if projectKind == .buildServer {
			// Only what makes the compiler guess (fallback arguments, no build root); a missing index store or a newer
			// project file doesn't change what a compile check says.
			report.settingsProblems = ProjectKind.buildRootProblems(in: workspaceRoot).filter {
				$0.contains("fallback arguments") || $0.contains("doesn't exist") || $0.contains("valid JSON")
			}
		}
		let build = buildPlan(report: report, options: options)

		var lines: [String] = []
		let fileCount = plan.changes.count
		if options.dryRun {
			lines.append("\(title): checked, nothing written (\(fileCount) file(s)).")
		}
		var rejected = false
		if !options.dryRun, options.require == .noNewErrors, report.hasNewErrors || !report.isVerified { rejected = true }

		if rejected {
			lines.append(
				report.hasNewErrors
					? "\(title): NOT applied. The change introduces \(report.newErrors.count) compile error(s); no file was modified."
					: "\(title): NOT applied. The change can't be verified (\(report.settingsProblems.isEmpty ? "the language server could not analyze the files" : "the build settings are incomplete")); nothing was modified.")
		}
		lines.append(EditFormat.summary(plan, root: workspaceRoot))
		lines.append(EditFormat.check(report, root: workspaceRoot))
		if engine.graph == nil, projectKind != .swiftPackage, engine.xcodeModules == nil {
			lines.append(
				"Not checked: this isn't a SwiftPM package, so module boundaries are unknown. Files in other targets that use a changed declaration were not compiled here; build the project to be sure.")
		}
		if !plan.notes.isEmpty { lines.append(plan.notes.map { "Note: \($0)" }.joined(separator: "\n")) }
		if !plan.manual.isEmpty { lines.append(manualSection(plan)) }

		if rejected {
			lines.append(
				report.hasNewErrors
					? "Fix what is listed (or pass require=none to write it anyway), then retry. Diff that was rejected:"
					: "Fix the project setup (see above), or pass require=none to write without a compile check. Diff that was rejected:")
			lines.append(EditFormat.diff(plan, root: workspaceRoot))
			throw ToolInputError(lines.joined(separator: "\n"))
		}
		if options.dryRun {
			if build.run {
				// An explicit request: write, build, put everything back.
				let outcome = try await buildOnTemporaryWrite(plan, engine: engine)
				lines.append(outcome.text)
				if outcome.hasNewErrors { lines.append("(Not written: dry run. The errors above would make apply_edit refuse.)") }
			} else if let hint = build.hint {
				lines.append(hint + " Pass verify=build to compile it in a temporary write.")
			}
			lines.append("Diff:\n" + EditFormat.diff(plan, root: workspaceRoot))
			return lines.joined(separator: "\n")
		}

		try engine.commit(plan)
		try? await client.refresh()
		await client.touch(plan.changes.map(\.path).filter(EditEngine.isSwiftSource))
		let id = reserveEditID()
		record(JournalEntry(id: id, title: title, plan: plan, date: Date()))
		lines.insert("\(title): applied as \(id) (\(fileCount) file(s) written).", at: 0)

		if let late = try await checkNewFilesOnDisk(plan, client: client, engine: engine, journalID: id, options: options) {
			lines.append(late)
		}
		if build.run {
			let outcome: BuildOutcome
			do {
				outcome = try await buildAfterWrite(plan, engine: engine)
				try Task.checkCancellation()
			} catch is CancellationError {
				// The caller gave up while the build ran: nothing it didn't see verified stays applied.
				_ = try? engine.restore(plan, skipChanged: true)
				forget(id)
				try? await client.refresh()
				throw CancellationError()
			}
			lines.append(outcome.text)
			if outcome.hasNewErrors, options.require == .noNewErrors {
				forget(id)
				try? await client.refresh()
				lines[0] = "\(title): NOT applied. The build found new errors in code that depends on the change; "
					+ (outcome.diverged.isEmpty ? "every file was put back." : "the files were put back, except the ones listed below that changed meanwhile.")
				lines.append("Fix what is listed (or pass require=none), then retry. Diff that was rejected:")
				lines.append(EditFormat.diff(plan, root: workspaceRoot))
				throw ToolInputError(lines.joined(separator: "\n"))
			}
			if outcome.hasNewErrors {
				let notWritten = try engine.reapply(plan, skipping: Set(outcome.diverged))
				if !notWritten.isEmpty { lines.append(divergedNote(notWritten).trimmingCharacters(in: .newlines)) }
			}
		} else if let hint = build.hint {
			lines.append(hint)
		}
		lines.append("Diff:\n" + EditFormat.diff(plan, root: workspaceRoot))
		lines.append("Undo with undo_edit(id: \"\(id)\").")
		return lines.joined(separator: "\n")
	}

	private func manualSection(_ plan: EditPlan) -> String {
		"Needs a look (not changed):\n" + plan.manual.prefix(15).map { "  - \($0)" }.joined(separator: "\n")
			+ (plan.manual.count > 15 ? "\n  … and \(plan.manual.count - 15) more" : "")
	}

	/// A new file only gets build settings once it is on disk. After writing, ask the compiler about it for
	/// real, and take the whole change back if it introduced errors there.
	private func checkNewFilesOnDisk(
		_ plan: EditPlan, client: LSPClient, engine: EditEngine, journalID: String, options: EditOptions
	) async throws -> String? {
		var created = plan.changes.filter { $0.isCreation && EditEngine.isSwiftSource($0.path) }
		guard !created.isEmpty else { return nil }
		// In an Xcode project a new file belongs to no target until Xcode (or a build, for a synchronized folder)
		// says so: the compiler would read it with guessed arguments and report "No such module" for valid code.
		var unknownToXcode: [String] = []
		if projectKind != .swiftPackage {
			let modules = xcodeModules()
			unknownToXcode = created.map(\.path).filter { modules?.module(ofPath: $0) == nil }
			created.removeAll { unknownToXcode.contains($0.path) }
		}
		let xcodeNote = unknownToXcode.isEmpty ? nil
			: "New file(s) " + unknownToXcode.map { EditFormat.relativeName($0, root: workspaceRoot) }.joined(separator: ", ")
			+ " are not in an Xcode target that the build knows yet, so they were not compile-checked here. Add them to a target in Xcode (a synchronized folder picks them up by itself) and run `verify`."
		guard !created.isEmpty else { return xcodeNote }
		try? await client.refresh()
		_ = await client.waitForIndex(timeout: 8)
		var problems: [DiagnosticEntry] = []
		var checkedAny = false
		for change in created {
			guard let diagnostics = try? await client.diagnostics(change.path) else { continue }
			if diagnostics.contains(where: EditEngine.isAnalysisFailure) { continue }  // no verdict, not an error
			checkedAny = true
			let lines = PositionResolver.sourceLines(change.after ?? "")
			for diagnostic in diagnostics where diagnostic.isError {
				let line = diagnostic.range.start.line
				problems.append(
					DiagnosticEntry(
						path: change.path, line: line + 1, column: diagnostic.range.start.character + 1, severity: 1,
						message: diagnostic.message, lineText: lines.indices.contains(line) ? lines[line] : "",
						fixTitles: diagnostic.fixes.map(\.title)))
			}
		}
		guard checkedAny else {
			return ["New file(s) written, but the language server hasn't picked them up yet; run `diagnostics` on them or `verify`.", xcodeNote]
				.compactMap { $0 }.joined(separator: "\n")
		}
		if problems.isEmpty { return (["New file check (after writing): ✓ no errors."] + [xcodeNote].compactMap { $0 }).joined(separator: "\n") }
		var text = "New file check (after writing): ✗ \(problems.count) error(s):\n"
			+ problems.prefix(10).map { EditFormat.entry($0, root: workspaceRoot) }.joined(separator: "\n")
		if options.require == .noNewErrors {
			let left = try engine.restore(plan, skipChanged: true)
			forget(journalID)
			text += "\nThe whole change was rolled back (require=no_new_errors)." + divergedNote(left)
			throw ToolInputError("Edit \(journalID) rolled back.\n" + text)
		}
		return text
	}

	// MARK: check_edit / apply_edit

	public func editFiles(arguments: ToolArguments, dryRun: Bool) async -> ToolResult {
		await runWrite { client in
			var options = try EditOptions(arguments)
			options.dryRun = dryRun
			var staging = self.stagingForWorkspace()
			let specs = try FileEditSpec.parse(arguments)
			var touched: [String] = []
			for spec in specs { touched.append(contentsOf: try spec.apply(to: &staging)) }
			let title = dryRun ? "check_edit" : "apply_edit"
			return try await self.finishEdit(staging, client: client, title: title, options: options)
		}
	}

	// MARK: undo_edit

	public func undoEdit(id: String?, list: Bool, force: Bool) async -> ToolResult {
		await runUnlocked {
			try await withWriteLock {
				await useWorkspace()
				loadJournalIfNeeded()
				reloadJournal()  // another session on this workspace may have added or removed entries
				if list || editJournal.isEmpty {
					guard !editJournal.isEmpty else { return "No edits to undo." }
					return "Applied edits (newest last):\n" + editJournal.map {
						"  \($0.id)  \($0.title): " + $0.plan.changes.map { EditFormat.relativeName($0.path, root: workspaceRoot) }.joined(separator: ", ")
					}.joined(separator: "\n")
				}
				let entry: JournalEntry
				if let id {
					guard let found = editJournal.first(where: { $0.id == id }) else {
						throw ToolInputError("No edit '\(id)' in the journal. Applied edits: " + editJournal.map(\.id).joined(separator: ", "))
					}
					entry = found
				} else {
					entry = editJournal[editJournal.count - 1]
				}
				let client = try await liveClient()
				let engine = EditEngine(client: client, root: workspaceRoot)
				try engine.restore(entry.plan, force: force)
				forget(entry.id)
				try? await client.refresh()
				await resyncXcodeIndex()  // (the write lock is held) the build that checked the edit left the index describing it
				return "Undid \(entry.id) (\(entry.title)): restored "
					+ entry.plan.changes.map { EditFormat.relativeName($0.path, root: workspaceRoot) }.joined(separator: ", ") + "."
			}
		}
	}
}

extension EditFormat {
	static func relativeName(_ path: String, root: URL) -> String {
		relativePath(path, in: root) ?? displayPathOutside(path, root: root)
	}
}

// MARK: - File edit specs

/// One entry of `edits` for check_edit / apply_edit.
enum FileEditSpec {
	case replaceText(path: String, old: String, new: String, all: Bool)
	case replaceLines(path: String, start: Int, end: Int, new: String)
	case insertAfterLine(path: String, line: Int, new: String)
	case create(path: String, content: String, overwrite: Bool)
	case delete(path: String)

	static func parse(_ arguments: ToolArguments) throws -> [FileEditSpec] {
		var objects = try arguments.objects("edits") ?? []
		if objects.isEmpty {
			// A single edit can be given at the top level.
			objects = [arguments.values]
		}
		guard !objects.isEmpty, objects.contains(where: { $0["file_path"] != nil }) else {
			throw ToolInputError(
				"Pass `edits`: a list of {file_path, old_text, new_text} (or start_line/end_line, insert_after_line, content, delete).")
		}
		return try objects.map(parseOne)
	}

	private static func parseOne(_ object: [String: JSONValue]) throws -> FileEditSpec {
		let arguments = ToolArguments(object)
		let path = try arguments.requiredString("file_path")
		let newText = object["new_text"]?.stringValue ?? object["new_string"]?.stringValue
		if arguments.bool("delete", default: false) { return .delete(path: path) }
		if let content = object["content"]?.stringValue {
			return .create(path: path, content: content, overwrite: arguments.bool("overwrite", default: false))
		}
		if let old = object["old_text"]?.stringValue ?? object["old_string"]?.stringValue {
			guard let newText else { throw ToolInputError("An edit with old_text also needs new_text (use \"\" to delete the text).") }
			return .replaceText(path: path, old: old, new: newText, all: arguments.bool("replace_all", default: false))
		}
		if let start = try arguments.optionalInt("start_line") {
			guard let newText else { throw ToolInputError("An edit with start_line also needs new_text (use \"\" to delete the lines).") }
			let end = try arguments.optionalInt("end_line") ?? start
			return .replaceLines(path: path, start: start, end: end, new: newText)
		}
		if let after = try arguments.optionalInt("insert_after_line") {
			guard let newText else { throw ToolInputError("An edit with insert_after_line also needs new_text.") }
			return .insertAfterLine(path: path, line: after, new: newText)
		}
		throw ToolInputError(
			"Edit for \(path) says nothing to do: give old_text+new_text, start_line(+end_line)+new_text, insert_after_line+new_text, content (to create) or delete=true."
		)
	}

	/// Applies the edit to the staged texts (each edit sees the result of the ones before it).
	func apply(to staging: inout Staging) throws -> [String] {
		switch self {
		case .create(let path, let content, let overwrite):
			if try staging.read(path) != nil, !overwrite {
				throw ToolInputError("\(path) already exists. Edit it with old_text/new_text, or pass overwrite=true to replace it entirely.")
			}
			try staging.write(content.hasSuffix("\n") || content.isEmpty ? content : content + "\n", to: path)
			return [path]
		case .delete(let path):
			guard try staging.read(path) != nil else { throw ToolInputError("Cannot delete \(path): the file doesn't exist.") }
			try staging.write(nil, to: path)
			return [path]
		case .replaceText(let path, let old, let new, let all):
			guard let text = try staging.read(path) else { throw ToolInputError("Cannot edit \(path): the file doesn't exist.") }
			guard !old.isEmpty else { throw ToolInputError("old_text is empty; use insert_after_line or content to add text.") }
			let found = try Self.locate(old, new: new, in: text, path: path, all: all)
			try staging.apply(found, to: path)
			return [path]
		case .replaceLines(let path, let start, let end, let new):
			guard let text = try staging.read(path) else { throw ToolInputError("Cannot edit \(path): the file doesn't exist.") }
			let index = TextIndex(text)
			let lineCount = index.lineCount - (text.hasSuffix("\n") ? 1 : 0)
			guard start >= 1, start <= lineCount + 1, end >= start - 1, end <= lineCount else {
				throw ToolInputError("Lines \(start)-\(end) are out of range: \(path) has \(lineCount) line(s) (1-indexed, end_line inclusive).")
			}
			let from = index.lineStarts[start - 1]
			let to = end < index.lineStarts.count ? index.lineStarts[end] : index.units.count
			var replacement = new
			if !replacement.isEmpty, !replacement.hasSuffix("\n"), to < index.units.count || text.hasSuffix("\n") { replacement += "\n" }
			let edit = TextEdit(
				range: LSPRange(start: index.position(at: from), end: index.position(at: to)), newText: replacement)
			try staging.apply([edit], to: path)
			return [path]
		case .insertAfterLine(let path, let line, let new):
			guard let text = try staging.read(path) else { throw ToolInputError("Cannot edit \(path): the file doesn't exist.") }
			let index = TextIndex(text)
			let lineCount = index.lineCount - (text.hasSuffix("\n") ? 1 : 0)
			guard line >= 0, line <= lineCount else {
				throw ToolInputError("insert_after_line \(line) is out of range: \(path) has \(lineCount) line(s) (0 inserts at the top).")
			}
			var insertion = new.hasSuffix("\n") ? new : new + "\n"
			var offset = line < index.lineStarts.count ? index.lineStarts[line] : index.units.count
			if line == lineCount, !text.isEmpty, !text.hasSuffix("\n") {
				insertion = "\n" + insertion
				offset = index.units.count
			}
			let at = index.position(at: offset)
			try staging.apply([TextEdit(range: LSPRange(start: at, end: at), newText: insertion)], to: path)
			return [path]
		}
	}

	/// The edits replacing `old` with `new`: an exact match, or, failing that, a unique match that ignores
	/// differences in indentation (the new text is re-indented to fit).
	static func locate(_ old: String, new: String, in text: String, path: String, all: Bool) throws -> [TextEdit] {
		let index = TextIndex(text)
		let hay = text as NSString
		var ranges: [NSRange] = []
		var search = NSRange(location: 0, length: hay.length)
		while true {
			let found = hay.range(of: old, options: [], range: search)
			if found.location == NSNotFound { break }
			ranges.append(found)
			search = NSRange(location: found.upperBound, length: hay.length - found.upperBound)
		}
		func edit(_ range: NSRange, _ replacement: String) -> TextEdit {
			TextEdit(
				range: LSPRange(start: index.position(at: range.location), end: index.position(at: range.upperBound)),
				newText: replacement)
		}
		if ranges.count == 1 || (all && !ranges.isEmpty) { return ranges.map { edit($0, new) } }
		if ranges.count > 1 {
			let lines = TextEditing.lines(of: old, in: text).map(String.init).joined(separator: ", ")
			throw ToolInputError(
				"old_text matches \(ranges.count) places in \(path) (lines \(lines)). Add surrounding lines to make it unique, or set replace_all=true.")
		}
		// No exact match: compare line by line, ignoring leading/trailing whitespace.
		let wanted = old.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
		let trimmedWanted = Array(wanted.drop(while: { $0.isEmpty }).reversed().drop(while: { $0.isEmpty }).reversed())
		if !trimmedWanted.isEmpty {
			var starts: [Int] = []
			let lineCount = index.lineCount
			var line = 0
			while line + trimmedWanted.count <= lineCount {
				if (0..<trimmedWanted.count).allSatisfy({ index.lineText(line + $0).trimmingCharacters(in: .whitespaces) == trimmedWanted[$0] }) {
					starts.append(line)
				}
				line += 1
			}
			if starts.count == 1 {
				let first = starts[0]
				let last = first + trimmedWanted.count - 1
				// Re-indenting inside a multiline string literal would change the string's value: only an exact match may touch it.
				let before = index.text(from: 0, to: (try? index.offset(LSPPosition(line: first, character: 0))) ?? 0)
				let insideRegion = index.text(from: (try? index.offset(LSPPosition(line: first, character: 0))) ?? 0, to: (try? index.offset(LSPPosition(line: last, character: index.lineText(last).utf16.count))) ?? 0)
				if before.components(separatedBy: "\"\"\"").count % 2 == 0 || insideRegion.contains("\"\"\"") {
					throw ToolInputError(
						"old_text doesn't match exactly, and the closest match (line \(first + 1)) is in or next to a multiline string literal, where indentation is part of the value. Copy the text exactly, including its indentation.")
				}
				let unit = Indentation.detect(in: text)
				let fileIndent = Indentation.leading(of: index.lineText(first))
				let oldIndent = Indentation.leading(of: old.components(separatedBy: "\n").first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) ?? "")
				var replacement = new
				if !new.isEmpty {
					let dedented = new.components(separatedBy: "\n").enumerated().map { offset, line in
						offset > 0 && line.hasPrefix(oldIndent) ? String(line.dropFirst(oldIndent.count)) : line
					}.joined(separator: "\n")
					replacement = Indentation.reindent(
						dedented.trimmingCharacters(in: .whitespaces) == "" ? "" : String(dedented.drop(while: { $0 == " " || $0 == "\t" })),
						base: fileIndent, unit: unit, sourceUnit: Indentation.detect(in: old))
					replacement = fileIndent + replacement
				}
				let range = LSPRange(
					start: LSPPosition(line: first, character: 0),
					end: LSPPosition(line: last, character: index.lineText(last).utf16.count))
				return [TextEdit(range: range, newText: replacement)]
			}
			if starts.count > 1 {
				throw ToolInputError(
					"old_text doesn't match exactly, and ignoring indentation it matches \(starts.count) places in \(path) (lines \(starts.map { String($0 + 1) }.joined(separator: ", "))). Add surrounding lines.")
			}
		}
		// Help the caller see what is actually there.
		var hint = ""
		if let firstWanted = trimmedWanted.first {
			let near = (0..<index.lineCount).filter { index.lineText($0).contains(firstWanted) }.prefix(3)
			if !near.isEmpty {
				hint = " The first line of old_text does appear at line(s) " + near.map { String($0 + 1) }.joined(separator: ", ")
					+ ": " + near.map { "`" + index.lineText($0).trimmingCharacters(in: .whitespaces).prefix(80) + "`" }.joined(separator: " ")
					+ "; the following lines differ."
			}
		}
		throw ToolInputError("old_text was not found in \(path).\(hint) Re-read the file and copy the text exactly.")
	}
}
