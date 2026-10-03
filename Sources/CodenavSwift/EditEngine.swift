import Foundation
import NavShared

// The write side of codenav: a proposed change is staged as whole-file texts, shown to the language server
// as in-memory documents, compiled (diagnostics before vs after), and only then written to disk atomically,
// with a journal entry so it can be undone.

// MARK: - Plan

struct FileChange: Sendable, Equatable, Codable {
	/// Absolute, canonical path.
	var path: String
	/// The text on disk when the plan was made; nil for a file the plan creates.
	var before: String?
	/// The proposed text; nil for a file the plan deletes.
	var after: String?

	var isCreation: Bool { before == nil && after != nil }
	var isDeletion: Bool { after == nil }
}

struct EditPlan: Sendable {
	var changes: [FileChange] = []
	/// Facts worth telling the agent ("rewrote 4 call sites").
	var notes: [String] = []
	/// Spots the tool found but could not change safely, for a person (or the next call) to handle.
	var manual: [String] = []
	/// Declaration names whose usages the compile check should look at even when the edit didn't show them
	/// changing (a rename's old name, for example).
	var extraNames: Set<String> = []
	var extraFiles: [String] = []

	var isEmpty: Bool { changes.isEmpty }
}

/// Accumulates edits over several steps (an edit, then a fix-it, then a re-indent) as whole-file texts.
struct Staging {
	private struct Entry {
		var original: String?
		var current: String?
	}

	let root: URL
	let allowedRoots: [URL]
	private var entries: [String: Entry] = [:]
	private(set) var notes: [String] = []
	private(set) var manual: [String] = []

	init(root: URL, allowedRoots: [URL]) {
		self.root = root
		self.allowedRoots = allowedRoots.isEmpty ? [root] : allowedRoots
	}

	func canonical(_ filePath: String) -> String {
		canonicalFileURL(filePath, relativeTo: root).path
	}

	func relative(_ path: String) -> String {
		relativePath(path, in: root) ?? displayPathOutside(path, root: root)
	}

	private func validate(_ path: String) throws {
		let url = URL(fileURLWithPath: path)
		guard let base = allowedRoots.first(where: { relativePath(path, in: $0) != nil }) else {
			throw ToolInputError("Refusing to edit \(path): it is outside the workspace.")
		}
		if Exclude.isExcluded(url, root: base) || path.contains("/checkouts/") || path.contains("/DerivedSources/") {
			throw ToolInputError("Refusing to edit \(relative(path)): it is a build product or a dependency checkout.")
		}
	}

	/// The staged text of a file, else its text on disk; nil when it doesn't exist.
	mutating func read(_ filePath: String) throws -> String? {
		let path = canonical(filePath)
		if let entry = entries[path] { return entry.current }
		// Say "outside the workspace" before anything about the text: an edit aimed at /etc/hosts shouldn't
		// be told which of its lines `old_text` matched.
		if !allowedRoots.contains(where: { relativePath(path, in: $0) != nil }) {
			throw ToolInputError("Refusing to edit \(path): it is outside the workspace.")
		}
		guard FileManager.default.fileExists(atPath: path) else { return nil }
		return try readTextFile(URL(fileURLWithPath: path))
	}

	mutating func write(_ text: String?, to filePath: String) throws {
		let path = canonical(filePath)
		try validate(path)
		if entries[path] == nil {
			let original = FileManager.default.fileExists(atPath: path) ? try readTextFile(URL(fileURLWithPath: path)) : nil
			entries[path] = Entry(original: original, current: original)
		}
		var text = text
		if let text0 = text, let original = entries[path]?.original { text = Self.matchingLineEndings(text0, like: original) }
		entries[path]?.current = text
	}

	/// Code the tools generate uses `\n`; a file that is written with `\r\n` throughout stays that way.
	static func matchingLineEndings(_ text: String, like original: String) -> String {
		guard original.contains("\r\n"), !original.replacingOccurrences(of: "\r\n", with: "").contains("\n") else { return text }
		var result = ""
		result.reserveCapacity(text.count + 16)
		var previous: Character?
		for character in text {
			// Swift treats "\r\n" as one Character; a lone "\n" gets its "\r".
			if character == "\n", previous != "\r" {
				result.append("\r\n")
			} else {
				result.append(character)
			}
			previous = character
		}
		return result
	}

	mutating func apply(_ edits: [TextEdit], to filePath: String) throws {
		guard let text = try read(filePath) else {
			throw ToolInputError("Cannot edit \(relative(canonical(filePath))): the file doesn't exist.")
		}
		do {
			try write(try TextEditing.apply(edits, to: text), to: filePath)
		} catch let error as TextEditError {
			throw ToolInputError("Cannot apply the edits to \(relative(canonical(filePath))): \(error.message).")
		}
	}

	mutating func apply(_ edit: LSPWorkspaceEdit) throws {
		guard edit.resourceOperations.isEmpty else {
			throw ToolInputError(
				"The language server's edit includes file operations (\(edit.resourceOperations.joined(separator: ", "))), which codenav doesn't apply."
			)
		}
		for (uri, edits) in edit.fileEdits.sorted(by: { $0.key < $1.key }) {
			guard let path = uriToPath(uri) else { continue }
			try apply(edits, to: path)
		}
	}

	mutating func note(_ text: String) { notes.append(text) }
	mutating func needsAttention(_ text: String) { manual.append(text) }

	func plan() -> EditPlan {
		var plan = EditPlan()
		plan.changes = entries.filter { $0.value.original != $0.value.current }.sorted { $0.key < $1.key }
			.map { FileChange(path: $0.key, before: $0.value.original, after: $0.value.current) }
		plan.notes = notes
		plan.manual = manual
		return plan
	}
}

// MARK: - Check report

struct DiagnosticEntry: Sendable {
	var path: String
	var line: Int
	var column: Int
	var severity: Int
	var message: String
	var lineText: String
	var fixTitles: [String]
}

struct CheckReport: Sendable {
	var checkedFiles: [String] = []
	var newErrors: [DiagnosticEntry] = []
	var newWarnings: [DiagnosticEntry] = []
	var fixedErrors = 0
	var fixedWarnings = 0
	/// Errors the checked files already had before the change and still have.
	var existingErrors = 0
	/// Files in other modules that mention a changed declaration: an in-memory check can't see into them.
	var crossModule: [String] = []
	var unchecked: [String] = []
	var names: [String] = []
	/// Files the language server could not analyze at all (broken build settings, a failed build): a clean
	/// answer for them would mean nothing.
	var analysisFailures: [String] = []
	/// Likely problems in edited declarations of files that still have errors (see `FlowLint`).
	var flowWarnings: [String] = []

	var hasNewErrors: Bool { !newErrors.isEmpty }
	var isVerified: Bool { analysisFailures.isEmpty }
}

// MARK: - What a change touched

enum ChangedNames {
	/// Names of declarations whose header (everything up to the body) differs between two versions of a file,
	/// that exist in only one of them, or that the edit moved into another container. Usages of these names
	/// are what a change can break.
	static func compute(before: [DocumentSymbol], beforeText: String, after: [DocumentSymbol], afterText: String) -> Set<String> {
		let old = headers(of: before, text: beforeText)
		let new = headers(of: after, text: afterText)
		var names: Set<String> = []
		for key in Set(old.keys).union(new.keys) where old[key] != new[key] {
			let parts = key.components(separatedBy: "\u{1F}")
			guard let last = parts.last else { continue }
			let base = NavShared.baseName(last)
			if base == "init" {
				if parts.count >= 2 { names.insert(parts[parts.count - 2]) }  // calls spell the type, not `init`
			} else if !base.isEmpty {
				names.insert(base)
			}
		}
		return names
	}

	private static func headers(of symbols: [DocumentSymbol], text: String) -> [String: [String]] {
		let index = TextIndex(text)
		let scan = SwiftScan(text)
		var result: [String: [String]] = [:]
		func walk(_ symbols: [DocumentSymbol], container: [String]) {
			for symbol in symbols {
				guard let start = try? index.offset(symbol.range.start), let end = try? index.offset(symbol.range.end), start <= end
				else { continue }
				var headerEnd = end
				if let body = scan.body(of: start..<end, from: start) { headerEnd = body.open }
				let header = index.text(from: start, to: min(headerEnd, start + 400))
					.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
				let key = (container + [symbol.name]).joined(separator: "\u{1F}")
				result[key, default: []].append(header)
				// A function's children are its generic parameters and local declarations: not API.
				if ![SymbolKind.method, SymbolKind.function, SymbolKind.initializer].contains(symbol.kind) {
					walk(symbol.children ?? [], container: container + [symbol.name])
				}
			}
		}
		walk(symbols, container: [])
		return result
	}
}

func targetName(ofPath path: String) -> String? {
	for marker in ["/Sources/", "/Tests/"] {
		guard let range = path.range(of: marker, options: .backwards) else { continue }
		let rest = path[range.upperBound...].split(separator: "/", omittingEmptySubsequences: true)
		if rest.count >= 2 { return marker.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/" + rest[0] }
	}
	return nil
}

// MARK: - Engine

struct EditEngine {
	let client: LSPClient
	let root: URL
	/// The package's targets and their dependencies, when known: decides which files an in-memory check
	/// can speak for.
	var graph: PackageGraph?
	/// For an Xcode project: which module each file compiles into (there is no package graph to ask).
	var xcodeModules: XcodeModules?
	static let maxCheckedDependents = 40
	static let maxNamesScanned = 25

	static func isSwiftSource(_ path: String) -> Bool {
		path.hasSuffix(".swift") && !path.hasSuffix("/Package.swift")
	}

	/// Shows the plan to the language server as in-memory documents and reports how diagnostics change.
	/// The disk is not touched; every overlay is gone again when this returns.
	func check(_ plan: EditPlan) async throws -> CheckReport {
		let report: CheckReport
		do {
			report = try await checkInMemory(plan)
		} catch {
			await client.clearAllOverlays()
			await client.touch(plan.changes.map(\.path).filter(Self.isSwiftSource))
			throw error
		}
		await client.clearAllOverlays()
		// Leave the server's view of the project as the disk has it, not as the proposal had it.
		await client.touch(plan.changes.map(\.path).filter(Self.isSwiftSource))
		return report
	}

	private func checkInMemory(_ plan: EditPlan) async throws -> CheckReport {
		var report = CheckReport()
		let swiftChanges = plan.changes.filter { Self.isSwiftSource($0.path) }
		for change in plan.changes where !Self.isSwiftSource(change.path) {
			report.unchecked.append("\(rel(change.path)) is not a Swift source file, so the compiler didn't look at it")
		}
		for change in swiftChanges where change.isCreation {
			report.unchecked.append(
				"\(rel(change.path)) is new: the build system only knows a file once it exists on disk, so an in-memory check can look clean when it isn't")
		}

		var baseline: [String: [LSPDiagnostic]] = [:]
		var beforeSymbols: [String: [DocumentSymbol]] = [:]
		for change in swiftChanges where change.before != nil {
			baseline[change.path] = (try? await client.diagnostics(change.path)) ?? []
			beforeSymbols[change.path] = (try? await client.documentSymbol(change.path)) ?? []
		}
		for change in swiftChanges { await client.setOverlay(change.path, text: change.after ?? "") }
		await client.touch(swiftChanges.map(\.path))

		var names = plan.extraNames
		var afterSymbols: [String: [DocumentSymbol]] = [:]
		for change in swiftChanges {
			let after = (try? await client.documentSymbol(change.path)) ?? []
			afterSymbols[change.path] = after
			names.formUnion(
				ChangedNames.compute(
					before: beforeSymbols[change.path] ?? [], beforeText: change.before ?? "", after: after,
					afterText: change.after ?? ""))
		}
		names.remove("init")
		let ordered = names.sorted()
		report.names = ordered

		// Files that mention a changed name are where the change can break something.
		let changedPaths = Set(swiftChanges.map(\.path))
		var dependents: [String] = []
		var seen = changedPaths
		for path in plan.extraFiles where Self.isSwiftSource(path) && seen.insert(path).inserted { dependents.append(path) }
		for name in ordered.prefix(Self.maxNamesScanned) {
			let found = PositionResolver.occurrences(of: name, under: [root], limit: 400, perFile: true).hits
			for hit in found where Self.isSwiftSource(hit.path) {
				let path = canonicalFileURL(hit.path, relativeTo: root).path
				if seen.insert(path).inserted { dependents.append(path) }
			}
		}
		if ordered.count > Self.maxNamesScanned {
			report.unchecked.append("only the first \(Self.maxNamesScanned) of \(ordered.count) changed names were searched for usages")
		}

		// sourcekit-lsp sees an in-memory change only inside the module it was made in. A file whose module
		// depends on a changed module would be judged against the old version of that module: its answers
		// are wrong either way, so it is left to a real build.
		let changedModules = Set(swiftChanges.compactMap { moduleName($0.path) })
		var importCache: [String: String] = [:]
		func imports(_ path: String, anyOf modules: Set<String>) -> Bool {
			let text = importCache[path] ?? ((try? readTextFile(URL(fileURLWithPath: path))) ?? "")
			importCache[path] = text
			return modules.contains { PositionResolver.importsModule(text, Self.bareModuleName($0)) }
		}
		func isStale(_ path: String) -> Bool {
			guard let module = moduleName(path) else { return false }
			let others = changedModules.subtracting([module])
			if others.isEmpty { return false }
			if let graph, graph.target(ofPath: path) != nil { return !others.isDisjoint(with: graph.upstream(of: module)) }
			// Without a package graph, a file is judged against the old version of another changed module
			// when it imports that module.
			if xcodeModules != nil { return imports(path, anyOf: others) }
			return true  // no dependency information: assume the worst
		}
		var sameModule: [String] = []
		for path in dependents.sorted() {
			if isStale(path) { report.crossModule.append(path) } else { sameModule.append(path) }
		}
		var checkable: [FileChange] = []
		for change in swiftChanges {
			if isStale(change.path) { report.crossModule.append(change.path) } else { checkable.append(change) }
		}
		if sameModule.count > Self.maxCheckedDependents {
			let skipped = sameModule.count - Self.maxCheckedDependents
			report.unchecked.append("\(skipped) more file(s) mention a changed name and weren't compiled (limit \(Self.maxCheckedDependents))")
			sameModule = Array(sameModule.prefix(Self.maxCheckedDependents))
		}

		var after: [String: [LSPDiagnostic]] = [:]
		for path in checkable.map(\.path) + sameModule {
			do {
				let found = try await client.diagnostics(path)
				if let failure = found.first(where: Self.isAnalysisFailure) {
					report.analysisFailures.append(path)
					report.unchecked.append("\(rel(path)) could not be analyzed by the language server (\(failure.message))")
				}
				after[path] = found.filter { !Self.isAnalysisFailure($0) }
			} catch {
				report.unchecked.append("\(rel(path)) couldn't be checked (\(formatToolError(error)))")
			}
		}

		// Dependents that show problems: were they already broken? Look at them as they are on disk.
		let needBaseline = sameModule.filter { !(after[$0] ?? []).isEmpty && baseline[$0] == nil }
		if !needBaseline.isEmpty {
			for change in swiftChanges { try? await client.clearOverlay(change.path) }
			await client.touch(swiftChanges.map(\.path))
			for path in needBaseline { baseline[path] = ((try? await client.diagnostics(path)) ?? []).filter { !Self.isAnalysisFailure($0) } }
		}

		let texts = Dictionary(uniqueKeysWithValues: swiftChanges.map { ($0.path, $0.after ?? "") })
		// A file with errors never reaches the compiler's flow analysis: look at what the edit touched ourselves.
		for change in checkable {
			guard let newText = change.after, (after[change.path] ?? []).contains(where: { $0.isError }),
				let edit = TextEditing.replacement(from: change.before ?? "", to: newText), let tree = afterSymbols[change.path]
			else { continue }
			let first = edit.range.start.line
			let touched = first...(first + edit.newText.components(separatedBy: "\n").count - 1)
			let index = TextIndex(newText)
			let scan = SwiftScan(newText)
			for symbol in FlowLint.symbols(in: tree, overlapping: touched) {
				for problem in FlowLint.problems(for: symbol, in: newText, index: index, scan: scan) {
					report.flowWarnings.append("\(rel(change.path)):\(symbol.selectionRange.start.line + 1) \(problem)")
				}
			}
		}
		for path in (checkable.map(\.path) + sameModule) where after[path] != nil {
			let current = after[path] ?? []
			let previous = baseline[path] ?? []
			report.checkedFiles.append(path)
			let text = texts[path] ?? ((try? readTextFile(URL(fileURLWithPath: path))) ?? "")
			let lines = PositionResolver.sourceLines(text)
			var remaining = Dictionary(grouping: previous, by: Self.key).mapValues { $0.count }
			for diagnostic in current {
				let key = Self.key(diagnostic)
				if let count = remaining[key], count > 0 {
					remaining[key] = count - 1
					if diagnostic.isError { report.existingErrors += 1 }
					continue
				}
				let line = diagnostic.range.start.line
				var entry = DiagnosticEntry(
					path: path, line: line + 1, column: diagnostic.range.start.character + 1,
					severity: diagnostic.severity ?? 1, message: diagnostic.message,
					lineText: lines.indices.contains(line) ? lines[line] : "",
					fixTitles: diagnostic.fixes.filter { $0.edit != nil }.map(\.title))
				if diagnostic.isError, entry.fixTitles.isEmpty, report.newErrors.count < 8 {
					entry.fixTitles = await client.quickFixes(path, for: diagnostic).map(\.title)
				}
				if diagnostic.isError { report.newErrors.append(entry) } else if diagnostic.isWarning { report.newWarnings.append(entry) }
			}
			for (key, count) in remaining where count > 0 {
				if key.hasPrefix("1|") || key.hasPrefix("nil|") { report.fixedErrors += count } else if key.hasPrefix("2|") { report.fixedWarnings += count }
			}
		}
		return report
	}

	/// sourcekit-lsp's way of saying "I could not build an AST for this file" (a wrong or missing build setup).
	static func isAnalysisFailure(_ diagnostic: LSPDiagnostic) -> Bool {
		diagnostic.message.hasPrefix("Internal SourceKit error")
	}

	private static func key(_ diagnostic: LSPDiagnostic) -> String {
		"\(diagnostic.severity.map(String.init) ?? "nil")|\(diagnostic.message)"
	}

	private func rel(_ path: String) -> String {
		relativePath(path, in: root) ?? displayPathOutside(path, root: root)
	}

	/// The module a source file belongs to: its SwiftPM target, or the `Sources/<T>` / `Tests/<T>` layout.
	func moduleName(_ path: String) -> String? {
		graph?.target(ofPath: path)?.name ?? xcodeModules?.module(ofPath: path) ?? targetName(ofPath: path)
	}

	/// `Sources/Core` and `Tests/CoreTests` are layout names; the module the compiler imports is the part after.
	static func bareModuleName(_ name: String) -> String {
		for prefix in ["Sources/", "Tests/"] where name.hasPrefix(prefix) { return String(name.dropFirst(prefix.count)) }
		return name
	}

	// MARK: Writing

	/// Writes the plan. Refuses (writing nothing) when a file changed on disk since the plan was made;
	/// when a write fails midway, the files already written are put back.
	func commit(_ plan: EditPlan) throws {
		for change in plan.changes {
			let current = FileManager.default.fileExists(atPath: change.path) ? try? readTextFile(URL(fileURLWithPath: change.path)) : nil
			if current != change.before {
				throw ToolInputError(
					"\(rel(change.path)) changed on disk after the edit was prepared, so nothing was written. Re-read the file and retry.")
			}
		}
		var written: [FileChange] = []
		do {
			for change in plan.changes {
				try Self.write(change.after, to: change.path)
				written.append(change)
			}
		} catch {
			for change in written.reversed() { try? Self.write(change.before, to: change.path) }
			throw ToolInputError("Writing failed (\(error.localizedDescription)); the files written so far were restored.")
		}
	}

	/// Puts the files back as they were before the plan. Refuses when a file no longer holds what the plan
	/// wrote (someone edited it since), unless `force`.
	func restore(_ plan: EditPlan, force: Bool = false) throws {
		if !force {
			for change in plan.changes {
				let current = FileManager.default.fileExists(atPath: change.path) ? try? readTextFile(URL(fileURLWithPath: change.path)) : nil
				if current != change.after {
					throw ToolInputError(
						"\(rel(change.path)) was edited after this change, so it is not restored. Pass force=true to restore it anyway (this discards the later edits), or undo by hand."
					)
				}
			}
		}
		for change in plan.changes { try Self.write(change.before, to: change.path) }
	}

	private static func write(_ text: String?, to path: String) throws {
		let url = URL(fileURLWithPath: path)
		guard let text else {
			if FileManager.default.fileExists(atPath: path) { try FileManager.default.removeItem(at: url) }
			return
		}
		try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
		let permissions = (try? FileManager.default.attributesOfItem(atPath: path))?[.posixPermissions]
		try Data(text.utf8).write(to: url, options: .atomic)
		// An atomic write replaces the file: keep its mode (an executable script stays executable).
		if let permissions { try? FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: path) }
	}
}

// MARK: - Formatting

enum EditFormat {
	static let maxDiagnosticsShown = 12
	static let maxDiffLines = 120

	static func entry(_ entry: DiagnosticEntry, root: URL) -> String {
		let path = relativePath(entry.path, in: root) ?? displayPathOutside(entry.path, root: root)
		let severity = entry.severity == 2 ? "warning" : "error"
		let firstLine = entry.message.components(separatedBy: .newlines).first ?? entry.message
		var text = "  \(path):\(entry.line):\(entry.column) \(severity): \(firstLine)"
		let snippet = entry.lineText.trimmingCharacters(in: .whitespaces)
		if !snippet.isEmpty { text += "\n      \(entry.line) | \(snippet.prefix(160))" }
		if !entry.fixTitles.isEmpty { text += "\n      fix-it: " + entry.fixTitles.joined(separator: "; ") }
		return text
	}

	static func diff(_ plan: EditPlan, root: URL, limit: Int = maxDiffLines) -> String {
		var lines: [String] = []
		for change in plan.changes {
			let path = relativePath(change.path, in: root) ?? displayPathOutside(change.path, root: root)
			if change.isDeletion {
				lines.append("--- a/\(path)\n+++ /dev/null\n(file deleted, \((change.before ?? "").components(separatedBy: "\n").count) lines)")
			} else {
				lines.append(UnifiedDiff.make(old: change.before ?? "", new: change.after ?? "", path: path))
			}
		}
		let all = lines.joined(separator: "\n").components(separatedBy: "\n")
		if all.count <= limit { return all.joined(separator: "\n") }
		return all.prefix(limit).joined(separator: "\n") + "\n… diff truncated (\(all.count - limit) more lines)"
	}

	static func summary(_ plan: EditPlan, root: URL) -> String {
		plan.changes.map { change in
			let path = relativePath(change.path, in: root) ?? displayPathOutside(change.path, root: root)
			if change.isCreation { return "  \(path): new file (+\(UnifiedDiff.stats(old: "", new: change.after ?? "").added) lines)" }
			if change.isDeletion { return "  \(path): deleted" }
			let stats = UnifiedDiff.stats(old: change.before ?? "", new: change.after ?? "")
			return "  \(path): +\(stats.added) −\(stats.removed)"
		}.joined(separator: "\n")
	}

	static func check(_ report: CheckReport, root: URL) -> String {
		var lines: [String] = []
		let checked = "\(report.checkedFiles.count) file(s)"
		let rel = { (path: String) in relativePath(path, in: root) ?? displayPathOutside(path, root: root) }
		if !report.isVerified {
			lines.append("Compile check (sourcekit-lsp, in memory, \(checked)): ⚠ NOT VERIFIED, the language server could not analyze \(report.analysisFailures.count) file(s); run `workspace` to see why (build settings, a failing build).")
		}
		if report.hasNewErrors {
			lines.append("Compile check (sourcekit-lsp, in memory, \(checked)): ✗ \(report.newErrors.count) new error(s)")
			for entry in report.newErrors.prefix(maxDiagnosticsShown) { lines.append(Self.entry(entry, root: root)) }
			if report.newErrors.count > maxDiagnosticsShown { lines.append("  … and \(report.newErrors.count - maxDiagnosticsShown) more") }
		} else if report.isVerified {
			lines.append("Compile check (sourcekit-lsp, in memory, \(checked)): ✓ no new errors")
		}
		if !report.newWarnings.isEmpty {
			lines.append("\(report.newWarnings.count) new warning(s):")
			for entry in report.newWarnings.prefix(5) { lines.append(Self.entry(entry, root: root)) }
			if report.newWarnings.count > 5 { lines.append("  … and \(report.newWarnings.count - 5) more") }
		}
		var tail: [String] = []
		if report.fixedErrors > 0 { tail.append("fixed \(report.fixedErrors) error(s)") }
		if report.fixedWarnings > 0 { tail.append("fixed \(report.fixedWarnings) warning(s)") }
		if report.existingErrors > 0 {
			tail.append("\(report.existingErrors) error(s) were already there; while a file has errors the compiler skips later analysis (missing returns, uninitialized variables), so this check may be incomplete for it")
		}
		if !tail.isEmpty { lines.append(tail.joined(separator: "; ")) }
		if !report.crossModule.isEmpty {
			let shown = report.crossModule.prefix(6).map(rel).joined(separator: ", ")
			let more = report.crossModule.count > 6 ? " and \(report.crossModule.count - 6) more" : ""
			lines.append(
				"Not checked in memory: \(report.crossModule.count) file(s) in modules that depend on a changed module (\(shown)\(more)): the language server can't see changes across modules, so only a build can judge them."
			)
		}
		for reason in report.unchecked { lines.append("Not checked: \(reason).") }
		if !report.flowWarnings.isEmpty {
			lines.append("Possible problems the compiler can't report while these files have errors (missing returns):")
			lines += report.flowWarnings.prefix(6).map { "  \($0)" }
		}
		return lines.joined(separator: "\n")
	}
}
