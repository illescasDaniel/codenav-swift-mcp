import Foundation
import Testing

@testable import CodenavSwift
@testable import NavShared

private func symbol(
	_ name: String, kind: Int, lines: ClosedRange<Int>, startColumn: Int = 0, endColumn: Int = 1, children: [DocumentSymbol] = []
) throws -> DocumentSymbol {
	DocumentSymbol(
		name: name, detail: nil, kind: kind,
		range: LSPRange(start: LSPPosition(line: lines.lowerBound, character: startColumn), end: LSPPosition(line: lines.upperBound, character: endColumn)),
		selectionRange: LSPRange(
			start: LSPPosition(line: lines.lowerBound, character: startColumn),
			end: LSPPosition(line: lines.lowerBound, character: startColumn + name.utf16.count)),
		children: children)
}

@Suite struct StagingTests {
	private func makeRoot() throws -> URL {
		let root = FileManager.default.temporaryDirectory.appendingPathComponent("staging-\(UUID().uuidString)", isDirectory: true)
		try FileManager.default.createDirectory(at: root.appendingPathComponent("Sources/App"), withIntermediateDirectories: true)
		return root.realPath
	}

	@Test func stagesEditsAcrossStepsAndReportsOnlyRealChanges() throws {
		let root = try makeRoot()
		defer { try? FileManager.default.removeItem(at: root) }
		try "let a = 1\n".write(to: root.appendingPathComponent("Sources/App/A.swift"), atomically: true, encoding: .utf8)
		var staging = Staging(root: root, allowedRoots: [root])
		try staging.apply([TextEdit(line: 0, column: 8, endLine: 0, endColumn: 9, newText: "2")], to: "Sources/App/A.swift")
		try staging.apply([TextEdit(line: 0, column: 4, endLine: 0, endColumn: 5, newText: "b")], to: "Sources/App/A.swift")
		#expect(try staging.read("Sources/App/A.swift") == "let b = 2\n")
		// Putting the text back is no change at all.
		try staging.write("let a = 1\n", to: "Sources/App/A.swift")
		#expect(staging.plan().isEmpty)
	}

	@Test func createsAndDeletesFiles() throws {
		let root = try makeRoot()
		defer { try? FileManager.default.removeItem(at: root) }
		try "x\n".write(to: root.appendingPathComponent("Sources/App/Old.swift"), atomically: true, encoding: .utf8)
		var staging = Staging(root: root, allowedRoots: [root])
		try staging.write("new\n", to: "Sources/App/New.swift")
		try staging.write(nil, to: "Sources/App/Old.swift")
		let plan = staging.plan()
		#expect(plan.changes.count == 2)
		#expect(plan.changes.first(where: { $0.path.hasSuffix("New.swift") })?.isCreation == true)
		#expect(plan.changes.first(where: { $0.path.hasSuffix("Old.swift") })?.isDeletion == true)
	}

	@Test func refusesDependencyCheckoutsBuildProductsAndOutsidePaths() throws {
		let root = try makeRoot()
		defer { try? FileManager.default.removeItem(at: root) }
		var staging = Staging(root: root, allowedRoots: [root])
		#expect(throws: ToolInputError.self) { try staging.write("x", to: ".build/checkouts/Dep/Sources/Dep/D.swift") }
		#expect(throws: ToolInputError.self) { try staging.write("x", to: "../outside.swift") }
		#expect(throws: ToolInputError.self) { try staging.write("x", to: "/etc/passwd") }
	}

	@Test func refusesEditsToFileOperationsAndMissingFiles() throws {
		let root = try makeRoot()
		defer { try? FileManager.default.removeItem(at: root) }
		var staging = Staging(root: root, allowedRoots: [root])
		var edit = LSPWorkspaceEdit()
		edit.resourceOperations = ["rename file:///a"]
		#expect(throws: ToolInputError.self) { try staging.apply(edit) }
		#expect(throws: ToolInputError.self) { try staging.apply([TextEdit(line: 0, column: 0, endLine: 0, endColumn: 0, newText: "x")], to: "Sources/App/Missing.swift") }
	}

	@Test func windowsLineEndingsStayWindows() {
		let original = "a\r\nb\r\n"
		#expect(Staging.matchingLineEndings("a\nb\nc\n", like: original) == "a\r\nb\r\nc\r\n")
		#expect(Staging.matchingLineEndings("a\r\nb\n", like: original) == "a\r\nb\r\n")
		// A file with unix endings, or mixed ones, is left alone.
		#expect(Staging.matchingLineEndings("a\nb\n", like: "x\ny\n") == "a\nb\n")
		#expect(Staging.matchingLineEndings("a\nb\n", like: "x\r\ny\n") == "a\nb\n")
	}

	@Test func commitIsAtomicRefusesStaleFilesAndRestores() async throws {
		let root = try makeRoot()
		defer { try? FileManager.default.removeItem(at: root) }
		let a = root.appendingPathComponent("Sources/App/A.swift")
		let b = root.appendingPathComponent("Sources/App/B.swift")
		try "a\n".write(to: a, atomically: true, encoding: .utf8)
		try "b\n".write(to: b, atomically: true, encoding: .utf8)
		let engine = EditEngine(client: LSPClient(configuration: .init(workspaceRoot: root, command: ["/nonexistent"], languageID: "swift")), root: root)
		var staging = Staging(root: root, allowedRoots: [root])
		try staging.write("a2\n", to: "Sources/App/A.swift")
		try staging.write("b2\n", to: "Sources/App/B.swift")
		let plan = staging.plan()

		// Someone edits B after the plan was made: nothing is written, not even A.
		try "b-changed\n".write(to: b, atomically: true, encoding: .utf8)
		#expect(throws: ToolInputError.self) { try engine.commit(plan) }
		#expect(try String(contentsOf: a, encoding: .utf8) == "a\n")

		try "b\n".write(to: b, atomically: true, encoding: .utf8)
		try engine.commit(plan)
		#expect(try String(contentsOf: a, encoding: .utf8) == "a2\n")
		#expect(try String(contentsOf: b, encoding: .utf8) == "b2\n")

		// Restoring is refused while a file holds something the plan didn't write.
		try "b3\n".write(to: b, atomically: true, encoding: .utf8)
		#expect(throws: ToolInputError.self) { try engine.restore(plan) }
		try engine.restore(plan, force: true)
		#expect(try String(contentsOf: b, encoding: .utf8) == "b\n")
	}

	@Test func writingKeepsTheFileMode() throws {
		let root = try makeRoot()
		defer { try? FileManager.default.removeItem(at: root) }
		let script = root.appendingPathComponent("Sources/App/run.swift")
		try "x\n".write(to: script, atomically: true, encoding: .utf8)
		try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
		let engine = EditEngine(client: LSPClient(configuration: .init(workspaceRoot: root, command: ["/nonexistent"], languageID: "swift")), root: root)
		var staging = Staging(root: root, allowedRoots: [root])
		try staging.write("y\n", to: "Sources/App/run.swift")
		try engine.commit(staging.plan())
		let mode = try FileManager.default.attributesOfItem(atPath: script.path)[.posixPermissions] as? NSNumber
		#expect(mode?.intValue == 0o755)
	}
}

@Suite struct FileEditSpecTests {
	@Test func parsesEveryEditKindAndTheSingleEditShorthand() throws {
		let edits = try FileEditSpec.parse(ToolArguments([
			"edits": .array([
				["file_path": "a.swift", "old_text": "x", "new_text": "y", "replace_all": true],
				["file_path": "a.swift", "start_line": .int(3), "end_line": .int(4), "new_text": "z"],
				["file_path": "a.swift", "insert_after_line": .int(0), "new_text": "import Foundation"],
				["file_path": "b.swift", "content": "struct B {}"],
				["file_path": "c.swift", "delete": true],
			])
		]))
		#expect(edits.count == 5)
		let single = try FileEditSpec.parse(ToolArguments(["file_path": "a.swift", "old_text": "x", "new_text": "y"]))
		#expect(single.count == 1)
		// Some clients send nested values as a JSON string.
		let stringly = try FileEditSpec.parse(ToolArguments(["edits": .string(#"[{"file_path":"a.swift","old_text":"x","new_text":"y"}]"#)]))
		#expect(stringly.count == 1)
		#expect(throws: ToolInputError.self) { try FileEditSpec.parse(ToolArguments([:])) }
		#expect(throws: ToolInputError.self) { try FileEditSpec.parse(ToolArguments(["file_path": "a.swift"])) }
		#expect(throws: ToolInputError.self) { try FileEditSpec.parse(ToolArguments(["file_path": "a.swift", "old_text": "x"])) }
	}

	private func apply(_ spec: FileEditSpec, to text: String) throws -> String {
		let root = FileManager.default.temporaryDirectory.appendingPathComponent("spec-\(UUID().uuidString)", isDirectory: true).realPath
		try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
		defer { try? FileManager.default.removeItem(at: root) }
		try text.write(to: root.appendingPathComponent("f.swift"), atomically: true, encoding: .utf8)
		var staging = Staging(root: root, allowedRoots: [root])
		_ = try spec.apply(to: &staging)
		return try staging.read("f.swift") ?? ""
	}

	@Test func replaceTextNeedsOneMatchUnlessAll() throws {
		#expect(try apply(.replaceText(path: "f.swift", old: "b", new: "B", all: false), to: "a b c\n") == "a B c\n")
		#expect(throws: ToolInputError.self) { try apply(.replaceText(path: "f.swift", old: "a", new: "A", all: false), to: "a a\n") }
		#expect(try apply(.replaceText(path: "f.swift", old: "a", new: "A", all: true), to: "a a\n") == "A A\n")
		#expect(throws: ToolInputError.self) { try apply(.replaceText(path: "f.swift", old: "zzz", new: "A", all: false), to: "a a\n") }
	}

	@Test func indentationDifferencesAreToleratedWhenTheMatchIsUnique() throws {
		let text = "struct S {\n\tfunc f() {\n\t\tprint(1)\n\t}\n}\n"
		// The agent quoted it with spaces; the file uses tabs.
		let result = try apply(
			.replaceText(path: "f.swift", old: "    func f() {\n        print(1)\n    }", new: "    func f() {\n        print(2)\n    }", all: false), to: text)
		#expect(result == "struct S {\n\tfunc f() {\n\t\tprint(2)\n\t}\n}\n")
	}

	@Test func theErrorSaysWhereTheFirstLineAppears() {
		let text = "func a() {}\nfunc b() {}\n"
		do {
			_ = try apply(.replaceText(path: "f.swift", old: "func b() {\n}", new: "x", all: false), to: text)
			Issue.record("expected an error")
		} catch let error as ToolInputError {
			#expect(error.message.contains("line(s) 2"))
		} catch {
			Issue.record("unexpected \(error)")
		}
	}

	@Test func lineEditsReplaceInsertAndDelete() throws {
		let text = "one\ntwo\nthree\n"
		#expect(try apply(.replaceLines(path: "f.swift", start: 2, end: 2, new: "TWO"), to: text) == "one\nTWO\nthree\n")
		#expect(try apply(.replaceLines(path: "f.swift", start: 2, end: 3, new: ""), to: text) == "one\n")
		#expect(try apply(.replaceLines(path: "f.swift", start: 2, end: 1, new: "inserted"), to: text) == "one\ninserted\ntwo\nthree\n")
		#expect(try apply(.insertAfterLine(path: "f.swift", line: 0, new: "top"), to: text) == "top\none\ntwo\nthree\n")
		#expect(try apply(.insertAfterLine(path: "f.swift", line: 3, new: "end"), to: text) == "one\ntwo\nthree\nend\n")
		#expect(try apply(.insertAfterLine(path: "f.swift", line: 2, new: "end"), to: "one\ntwo") == "one\ntwo\nend\n")
		#expect(throws: ToolInputError.self) { try apply(.replaceLines(path: "f.swift", start: 9, end: 9, new: "x"), to: text) }
		#expect(throws: ToolInputError.self) { try apply(.insertAfterLine(path: "f.swift", line: 9, new: "x"), to: text) }
	}

	@Test func createRefusesToOverwriteWithoutSayingSo() throws {
		#expect(throws: ToolInputError.self) { try apply(.create(path: "f.swift", content: "x", overwrite: false), to: "old\n") }
		#expect(try apply(.create(path: "f.swift", content: "x", overwrite: true), to: "old\n") == "x\n")
	}
}

@Suite struct RenameNameTests {
	@Test func parsesBaseNamesAndLabels() throws {
		#expect(try RenameName.parse("make") == RenameName(base: "make", labels: nil))
		#expect(try RenameName.parse("make(named:)") == RenameName(base: "make", labels: ["named"]))
		#expect(try RenameName.parse("make(_:to:)") == RenameName(base: "make", labels: ["_", "to"]))
		#expect(try RenameName.parse("make()") == RenameName(base: "make", labels: []))
		#expect(try RenameName.parse("`class`") == RenameName(base: "`class`", labels: nil))
	}

	@Test func rejectsKeywordsAndNonIdentifiers() {
		#expect(throws: ToolInputError.self) { try RenameName.parse("class") }
		#expect(throws: ToolInputError.self) { try RenameName.parse("1abc") }
		#expect(throws: ToolInputError.self) { try RenameName.parse("a b") }
		#expect(throws: ToolInputError.self) { try RenameName.parse("") }
		#expect(throws: ToolInputError.self) { try RenameName.parse("make(named)") }
		#expect(throws: ToolInputError.self) { try RenameName.parse("make(1x:)") }
	}

	@Test func keepsTheOldLabelsOrChecksTheirNumber() throws {
		let old = ParsedQuery("create(name:)")
		#expect(try RenameName.parse("make").full(replacing: old) == "make(name:)")
		#expect(try RenameName.parse("make(named:)").full(replacing: old) == "make(named:)")
		#expect(throws: ToolInputError.self) { try RenameName.parse("make(a:b:)").full(replacing: old) }
		#expect(throws: ToolInputError.self) { try RenameName.parse("make()").full(replacing: old) }
		// A property or type has no labels to give.
		#expect(try RenameName.parse("title").full(replacing: ParsedQuery("name")) == "title")
		#expect(throws: ToolInputError.self) { try RenameName.parse("title(x:)").full(replacing: ParsedQuery("name")) }
	}
}

@Suite struct MemberInsertionTests {
	static let text = "struct S {\n\tvar a = 1\n\tvar b = 2\n\n\tfunc f() {\n\t\tprint(1)\n\t}\n}\n"

	private func container(text: String = Self.text) throws -> SwiftNavigator.MemberContainer {
		let scan = SwiftScan(text)
		let open = (text as NSString).range(of: "{").location
		let close = try #require(scan.matching(openAt: open))
		let children = [
			try symbol("a", kind: SymbolKind.property, lines: 1...1, startColumn: 1, endColumn: 10),
			try symbol("b", kind: SymbolKind.property, lines: 2...2, startColumn: 1, endColumn: 10),
			try symbol("f()", kind: SymbolKind.method, lines: 4...6, startColumn: 1, endColumn: 2),
		]
		return SwiftNavigator.MemberContainer(children: children, body: (open, close), baseIndent: "", isFile: false)
	}

	private func insert(_ code: String, at position: String, text: String = Self.text) throws -> String {
		let edit = try SwiftNavigator.memberInsertion(
			code, container: try container(text: text), position: position, text: text, index: TextIndex(text), unit: .tab)
		return try TextEditing.apply([edit], to: text)
	}

	@Test func lastGoesBeforeTheClosingBraceWithABlankLine() throws {
		#expect(try insert("func g() {}", at: "last") == "struct S {\n\tvar a = 1\n\tvar b = 2\n\n\tfunc f() {\n\t\tprint(1)\n\t}\n\n\tfunc g() {}\n}\n")
	}

	@Test func aPropertyAfterAPropertyNeedsNoBlankLine() throws {
		#expect(try insert("var a2 = 0", at: "after:a") == "struct S {\n\tvar a = 1\n\tvar a2 = 0\n\tvar b = 2\n\n\tfunc f() {\n\t\tprint(1)\n\t}\n}\n")
	}

	@Test func firstGoesRightAfterTheOpeningBrace() throws {
		#expect(try insert("var z = 0", at: "first") == "struct S {\n\tvar z = 0\n\tvar a = 1\n\tvar b = 2\n\n\tfunc f() {\n\t\tprint(1)\n\t}\n}\n")
	}

	@Test func beforeAMethodGetsABlankLineAfterIt() throws {
		let result = try insert("func e() {}", at: "before:f")
		#expect(result == "struct S {\n\tvar a = 1\n\tvar b = 2\n\n\tfunc e() {}\n\n\tfunc f() {\n\t\tprint(1)\n\t}\n}\n")
	}

	@Test func multilineCodeIsIndentedToTheMembers() throws {
		let result = try insert("func g() {\n    if x {\n        y()\n    }\n}", at: "last")
		#expect(result.contains("\n\tfunc g() {\n\t\tif x {\n\t\t\ty()\n\t\t}\n\t}\n}\n"))
	}

	@Test func anEmptyOneLineContainerIsExpanded() throws {
		let text = "struct E {}\n"
		let scan = SwiftScan(text)
		let container = SwiftNavigator.MemberContainer(children: [], body: (9, try #require(scan.matching(openAt: 9))), baseIndent: "", isFile: false)
		let edit = try SwiftNavigator.memberInsertion("var x = 1", container: container, position: "last", text: text, index: TextIndex(text), unit: .tab)
		#expect(try TextEditing.apply([edit], to: text) == "struct E {\n\tvar x = 1\n}\n")
	}

	@Test func unknownOrAmbiguousAnchorsAreErrors() throws {
		#expect(throws: ToolInputError.self) { try insert("var x = 1", at: "after:nope") }
		#expect(throws: ToolInputError.self) { try insert("var x = 1", at: "sideways") }
		#expect(throws: ToolInputError.self) { try insert("var x = 1", at: "after") }
	}

	@Test func importsInsideConditionalCompilationAreSkippedAsAWhole() throws {
		let plain = importLayout(of: ["import A", "@testable import B", "", "struct S {}"])
		#expect(plain.end == 2 && plain.topLevel == ["import A", "@testable import B"])
		let lines = ["import A", "#if canImport(UIKit)", "import UIKit", "#endif", "", "struct S {}"]
		let layout = importLayout(of: lines)
		#expect(layout.end == 4, "new code goes after #endif, not inside the branch")
		#expect(layout.topLevel == ["import A"], "a conditional import is not copied unguarded")
		#expect(importLayout(of: ["struct S {}"]).end == 0)
		let text = lines.joined(separator: "\n") + "\n"
		let file = SwiftNavigator.MemberContainer(children: [], body: nil, baseIndent: "", isFile: true)
		let first = try SwiftNavigator.memberInsertion("struct Z {}", container: file, position: "first", text: text, index: TextIndex(text), unit: .tab)
		#expect(try TextEditing.apply([first], to: text).contains("#endif\n\nstruct Z {}\n"))
	}

	@Test func topLevelAppendAndFirstAfterImports() throws {
		let text = "import Foundation\nimport OSLog\n\nstruct A {}\n"
		let file = SwiftNavigator.MemberContainer(children: [try symbol("A", kind: SymbolKind.structure, lines: 3...3, endColumn: 12)], body: nil, baseIndent: "", isFile: true)
		let last = try SwiftNavigator.memberInsertion("struct B {}", container: file, position: "last", text: text, index: TextIndex(text), unit: .tab)
		#expect(try TextEditing.apply([last], to: text) == "import Foundation\nimport OSLog\n\nstruct A {}\n\nstruct B {}\n")
		let first = try SwiftNavigator.memberInsertion("struct Z {}", container: file, position: "first", text: text, index: TextIndex(text), unit: .tab)
		#expect(try TextEditing.apply([first], to: text) == "import Foundation\nimport OSLog\n\nstruct Z {}\n\nstruct A {}\n")
		let noTrailingNewline = "struct A {}"
		let appended = try SwiftNavigator.memberInsertion("struct B {}", container: file, position: "last", text: noTrailingNewline, index: TextIndex(noTrailingNewline), unit: .tab)
		#expect(try TextEditing.apply([appended], to: noTrailingNewline) == "struct A {}\n\nstruct B {}\n")
	}
}

@Suite struct DeclarationLookupTests {
	@Test func findsTheSymbolWhoseNameIsAtAPosition() throws {
		let method = try symbol("run()", kind: SymbolKind.method, lines: 3...5, startColumn: 1, endColumn: 2)
		let type = try symbol("S", kind: SymbolKind.structure, lines: 0...6, startColumn: 0, endColumn: 1, children: [method])
		let found = DeclarationLookup.find(in: [type], at: LSPPosition(line: 3, character: 2))
		#expect(found?.symbol.name == "run()")
		#expect(found?.parents.map(\.name) == ["S"])
		#expect(DeclarationLookup.find(in: [type], at: LSPPosition(line: 0, character: 0))?.symbol.name == "S")
		#expect(DeclarationLookup.find(in: [type], at: LSPPosition(line: 4, character: 5)) == nil)
	}

	@Test func changedNamesComeFromDeclarationHeaders() throws {
		let before = "struct S {\n\tfunc f(a: Int) { print(a) }\n\tfunc g() {}\n}\n"
		let bodyOnly = "struct S {\n\tfunc f(a: Int) { print(a + 1) }\n\tfunc g() {}\n}\n"
		let signature = "struct S {\n\tfunc f(a: Int, b: Int) { print(a) }\n\tfunc g() {}\n}\n"
		func symbols(_ text: String) throws -> [DocumentSymbol] {
			let lines = text.components(separatedBy: "\n")
			let f = try symbol(lines[1].contains("b: Int") ? "f(a:b:)" : "f(a:)", kind: SymbolKind.method, lines: 1...1, startColumn: 1, endColumn: lines[1].utf16.count)
			let g = try symbol("g()", kind: SymbolKind.method, lines: 2...2, startColumn: 1, endColumn: lines[2].utf16.count)
			return [try symbol("S", kind: SymbolKind.structure, lines: 0...3, endColumn: 1, children: [f, g])]
		}
		#expect(ChangedNames.compute(before: try symbols(before), beforeText: before, after: try symbols(bodyOnly), afterText: bodyOnly).isEmpty)
		#expect(ChangedNames.compute(before: try symbols(before), beforeText: before, after: try symbols(signature), afterText: signature) == ["f"])
	}
}

@Suite struct GeneratedCodeTests {
	@Test func flatExtractedCodeIsRebuiltFromItsBraces() {
		let text = "struct S {\n\tfunc f() {\n\t\tlet x = 1\n\t}\n}\n"
		let edit = TextEdit(line: 1, column: 1, endLine: 1, endColumn: 1, newText: "fileprivate func extracted() -> Int {\nreturn 1\n}\n\n")
		let result = GeneratedCode.normalize([edit], in: text, unit: .tab)
		#expect(result[0].newText == "fileprivate func extracted() -> Int {\n\t\treturn 1\n\t}\n\n\t")
	}

	@Test func spaceIndentedStubsBecomeTabsInATabFile() {
		let text = "extension S: P {\n}\n"
		let stub = "\n    func f() -> Int {\n        \n    }\n"
		let edit = TextEdit(line: 0, column: 16, endLine: 0, endColumn: 16, newText: stub)
		let tidy = GeneratedCode.normalize([edit], in: text, unit: .tab)[0].newText
		#expect(tidy == "\n\tfunc f() -> Int {\n        \n\t}\n")
	}

	@Test func emptyBodiesThatMustReturnGetAFatalError() {
		let stub = "\n\tfunc f() -> Int {\n        \n\t}\n\n\tfunc g() {\n\t}\n\n\tvar x: Int {\n\n\t}\n"
		let filled = GeneratedCode.fillStubBodies(stub, unit: .tab)
		#expect(filled.contains("func f() -> Int {\n\t\tfatalError(\"Not implemented\")\n\t}"))
		#expect(filled.contains("func g() {\n\t}"))  // returns nothing: an empty body compiles
		#expect(filled.contains("var x: Int {\n\t\tfatalError(\"Not implemented\")\n\t}"))
	}

	@Test func aDoubledBlankLineAtTheEndOfAnInsertionIsTrimmed() {
		let text = "switch r {\ncase .a: break\n}\n"
		let blankEnd = TextEdit(line: 2, column: 0, endLine: 2, endColumn: 0, newText: "case .b:\n\n")
		#expect(GeneratedCode.trimTrailingBlankLine([blankEnd], in: text)[0].newText == "case .b:\n")
		let beforeNewline = TextEdit(line: 0, column: 10, endLine: 0, endColumn: 10, newText: "\n\tx\n")
		#expect(GeneratedCode.trimTrailingBlankLine([beforeNewline], in: text)[0].newText == "\n\tx")
	}

	@Test func extractedNamesAreReplacedConsistently() {
		let text = "func extractedFunc(_ a: Int) -> Int { a }\nlet x = extractedFunc(1)"
		#expect(SwiftNavigator.renameGenerated(text, to: "make") == "func make(_ a: Int) -> Int { a }\nlet x = make(1)")
		#expect(SwiftNavigator.renameGenerated("let extractedExpr = 1", to: "value") == "let value = 1")
		#expect(SwiftNavigator.renameGenerated("let extractor = 1", to: "value") == "let extractor = 1")
		// The caller's own identifiers that merely start with "extracted" stay.
		#expect(SwiftNavigator.renameGenerated("let extractedData = extractedFunc()", to: "go") == "let extractedData = go()")
	}
}

@Suite struct BuildSupportTests {
	@Test func parsesCompilerDiagnosticsOnceEvenWhenPrintedTwice() {
		let output = """
			Building for debugging...
			/tmp/p/Sources/App/main.swift:4:48: error: missing argument for parameter 'admin' in call
			2 |
			  |                                                `- error: missing argument for parameter 'admin' in call
			/tmp/p/Sources/App/main.swift:4:48: error: missing argument for parameter 'admin' in call
			/tmp/p/Sources/Lib/L.swift:10:5: warning: variable 'x' was never used
			error: fatalError
			"""
		let parsed = BuildRunner.parse(output)
		#expect(parsed.count == 2)
		#expect(parsed[0].line == 4 && parsed[0].column == 48 && parsed[0].severity == "error")
		#expect(parsed[1].severity == "warning")
	}

	@Test func newErrorsIgnoreLineShiftsButCountRepeats() {
		func error(_ file: String, _ line: Int, _ message: String) -> BuildDiagnostic {
			BuildDiagnostic(path: "/p/\(file)", line: line, column: 1, severity: "error", message: message)
		}
		func result(_ errors: [BuildDiagnostic]) -> BuildResult {
			BuildResult(command: "swift build", status: 1, timedOut: false, seconds: 1, errors: errors, warnings: 0, tail: "")
		}
		let baseline = result([error("A.swift", 3, "boom")])
		let after = result([error("A.swift", 30, "boom"), error("A.swift", 31, "boom"), error("B.swift", 1, "new")])
		let fresh = SwiftNavigator.newErrors(after, comparedTo: baseline)
		#expect(fresh.count == 2)
		#expect(fresh.contains { $0.message == "new" })
	}

	@Test func readsTheTargetGraphFromSwiftPMDescribe() throws {
		let json = """
			{"name":"P","path":"/p","targets":[
			 {"name":"Lib","path":"Sources/Lib","type":"library","sources":["A.swift","Sub/B.swift"]},
			 {"name":"App","path":"Sources/App","type":"executable","target_dependencies":["Lib"]},
			 {"name":"LibTests","path":"Tests/LibTests","type":"test","target_dependencies":["Lib"]},
			 {"name":"Tool","path":"Sources/Tool","type":"executable","target_dependencies":["App"]}]}
			"""
		let graph = try #require(PackageGraph.parse(json: Data(json.utf8), root: URL(fileURLWithPath: "/p")))
		#expect(graph.target(ofPath: "/p/Sources/Lib/A.swift")?.name == "Lib")
		#expect(graph.targets.first { $0.name == "Lib" }?.sources == ["/p/Sources/Lib/A.swift", "/p/Sources/Lib/Sub/B.swift"])
		#expect(graph.target(ofPath: "/p/Sources/Lib") ==  graph.targets.first { $0.name == "Lib" })
		#expect(graph.target(ofPath: "/p/Sources/Libx/A.swift") == nil)
		#expect(graph.upstream(of: "Tool") == ["App", "Lib"])
		#expect(graph.upstream(of: "Lib").isEmpty)
		#expect(PackageGraph.parse(json: Data("{}".utf8), root: URL(fileURLWithPath: "/p")) == nil)
	}

	@Test func theSwiftDriverIsFoundNextToTheLanguageServer() throws {
		let directory = FileManager.default.temporaryDirectory.appendingPathComponent("tc-\(UUID().uuidString)", isDirectory: true)
		try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
		defer { try? FileManager.default.removeItem(at: directory) }
		let swift = directory.appendingPathComponent("swift")
		try "#!/bin/sh\n".write(to: swift, atomically: true, encoding: .utf8)
		try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: swift.path)
		#expect(ToolProcess.swiftExecutable(environment: [:], languageServer: [directory.appendingPathComponent("sourcekit-lsp").path]) == swift.path)
	}

	@Test func theProcessRunnerCapturesOutputExitCodeAndTimeouts() async {
		let ok = await ToolProcess.run("/bin/sh", arguments: ["-c", "echo out; echo err 1>&2; exit 3"], directory: URL(fileURLWithPath: "/"), timeout: 10)
		#expect(ok.stdout == "out\n" && ok.stderr == "err\n" && ok.status == 3 && !ok.timedOut)
		let slow = await ToolProcess.run("/bin/sh", arguments: ["-c", "sleep 30"], directory: URL(fileURLWithPath: "/"), timeout: 0.3)
		#expect(slow.timedOut)
		#expect(slow.seconds < 10)
	}
}

@Suite struct CheckReportFormattingTests {
	@Test func aCleanReportSaysSoAndAnUnverifiedOneDoesNot() {
		let root = URL(fileURLWithPath: "/p")
		var report = CheckReport()
		report.checkedFiles = ["/p/A.swift"]
		#expect(EditFormat.check(report, root: root).contains("✓ no new errors"))
		report.analysisFailures = ["/p/A.swift"]
		let text = EditFormat.check(report, root: root)
		#expect(text.contains("NOT VERIFIED"))
		#expect(!text.contains("✓"))
	}

	@Test func newErrorsAreListedWithTheirLineAndFixIts() {
		let root = URL(fileURLWithPath: "/p")
		var report = CheckReport()
		report.checkedFiles = ["/p/A.swift"]
		report.newErrors = [
			DiagnosticEntry(path: "/p/A.swift", line: 12, column: 3, severity: 1, message: "Missing argument\nsecond line", lineText: "\t\tcall()", fixTitles: ["Insert ', x: '"])
		]
		report.crossModule = ["/p/Tests/T.swift"]
		report.existingErrors = 2
		let text = EditFormat.check(report, root: root)
		#expect(text.contains("A.swift:12:3 error: Missing argument"))
		#expect(!text.contains("second line"))
		#expect(text.contains("12 | call()"))
		#expect(text.contains("fix-it: Insert ', x: '"))
		#expect(text.contains("Tests/T.swift"))
		#expect(text.contains("2 error(s) were already there"))
	}

	@Test func diffsAreCappedAndSummariesCountLines() {
		let root = URL(fileURLWithPath: "/p")
		let old = (1...300).map { "line \($0)" }.joined(separator: "\n") + "\n"
		let new = (1...300).map { "LINE \($0)" }.joined(separator: "\n") + "\n"
		var plan = EditPlan()
		plan.changes = [FileChange(path: "/p/A.swift", before: old, after: new), FileChange(path: "/p/B.swift", before: nil, after: "x\ny\n"), FileChange(path: "/p/C.swift", before: "c\n", after: nil)]
		let diff = EditFormat.diff(plan, root: root, limit: 20)
		#expect(diff.contains("diff truncated"))
		let summary = EditFormat.summary(plan, root: root)
		#expect(summary.contains("A.swift: +300 −300"))
		#expect(summary.contains("B.swift: new file (+2 lines)"))
		#expect(summary.contains("C.swift: deleted"))
	}
}

@Suite struct JournalStoreTests {
	@Test func entriesSurviveAndAreNumberedOnAfterARestart() throws {
		let base = FileManager.default.temporaryDirectory.appendingPathComponent("journal-\(UUID().uuidString)", isDirectory: true)
		defer { try? FileManager.default.removeItem(at: base) }
		let workspace = FileManager.default.temporaryDirectory
		let store = JournalStore(workspace: workspace, base: base)
		var plan = EditPlan()
		plan.changes = [FileChange(path: "/p/A.swift", before: "a\n", after: "b\n"), FileChange(path: "/p/New.swift", before: nil, after: "n\n")]
		store.save(JournalEntry(id: "e10", title: "rename", plan: plan, date: Date()))
		store.save(JournalEntry(id: "e2", title: "edit", plan: plan, date: Date()))
		let loaded = JournalStore(workspace: workspace, base: base).load()
		#expect(loaded.map(\.id) == ["e2", "e10"])  // numeric order, not alphabetical
		#expect(loaded[1].plan.changes == plan.changes)
		#expect(loaded[1].plan.changes[1].isCreation)
		store.remove("e2")
		#expect(store.load().map(\.id) == ["e10"])
		// Another workspace has its own journal.
		#expect(JournalStore(workspace: URL(fileURLWithPath: "/somewhere/else"), base: base).load().isEmpty)
	}
}

@Suite struct JournalPruneTests {
	@Test func theOldestEntriesGoWhenThereAreTooManyOrTheyAreTooBig() throws {
		let base = FileManager.default.temporaryDirectory.appendingPathComponent("journal-\(UUID().uuidString)", isDirectory: true)
		defer { try? FileManager.default.removeItem(at: base) }
		let store = JournalStore(workspace: FileManager.default.temporaryDirectory, base: base)
		var plan = EditPlan()
		plan.changes = [FileChange(path: "/p/A.swift", before: "a\n", after: "b\n")]
		for number in 1...(JournalStore.limit + 5) {
			store.save(JournalEntry(id: "e\(number)", title: "t", plan: plan, date: Date()))
		}
		let ids = store.load().map(\.id)
		#expect(ids.count == JournalStore.limit)
		#expect(ids.first == "e6" && ids.last == "e\(JournalStore.limit + 5)")
	}
}

@Suite struct WriteSafetyTests {
	private func plan(in root: URL) -> EditPlan {
		var plan = EditPlan()
		plan.changes = [
			FileChange(path: root.appendingPathComponent("A.swift").path, before: "a\n", after: "A\n"),
			FileChange(path: root.appendingPathComponent("B.swift").path, before: "b\n", after: "B\n"),
		]
		return plan
	}

	private func scratch() throws -> URL {
		let root = FileManager.default.temporaryDirectory.appendingPathComponent("safety-\(UUID().uuidString)", isDirectory: true)
		try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
		return root.realPath
	}

	@Test func aRestoreAfterABuildLeavesFilesSomebodyElseChanged() throws {
		let root = try scratch()
		defer { try? FileManager.default.removeItem(at: root) }
		let plan = plan(in: root)
		for change in plan.changes { try change.after!.write(toFile: change.path, atomically: true, encoding: .utf8) }
		// The user saved B in their editor while the build ran.
		try "mine\n".write(toFile: plan.changes[1].path, atomically: true, encoding: .utf8)
		let skipped = try EditEngine.restoreFiles(plan, skipChanged: true) { $0 }
		#expect(skipped == [plan.changes[1].path])
		#expect(try String(contentsOfFile: plan.changes[0].path, encoding: .utf8) == "a\n")
		#expect(try String(contentsOfFile: plan.changes[1].path, encoding: .utf8) == "mine\n")
		// The strict restore still refuses, and a restore of a file that is already back is not an error.
		#expect(throws: ToolInputError.self) { try EditEngine.restoreFiles(plan) { $0 } }
		try "b\n".write(toFile: plan.changes[1].path, atomically: true, encoding: .utf8)
		#expect(try EditEngine.restoreFiles(plan) { $0 }.isEmpty)
	}

	@Test func writingTheProposalAgainSkipsWhatChangedMeanwhile() async throws {
		let root = try scratch()
		defer { try? FileManager.default.removeItem(at: root) }
		let plan = plan(in: root)
		for change in plan.changes { try change.before!.write(toFile: change.path, atomically: true, encoding: .utf8) }
		try "mine\n".write(toFile: plan.changes[1].path, atomically: true, encoding: .utf8)
		let engine = EditEngine(client: LSPClient(configuration: .init(workspaceRoot: root, command: ["true"], languageID: "swift")), root: root)
		let notWritten = try engine.reapply(plan)
		#expect(notWritten == [plan.changes[1].path])
		#expect(try String(contentsOfFile: plan.changes[0].path, encoding: .utf8) == "A\n")
		#expect(try String(contentsOfFile: plan.changes[1].path, encoding: .utf8) == "mine\n")
	}

	@Test func journalIdsAreNeverHandedOutTwice() throws {
		let base = FileManager.default.temporaryDirectory.appendingPathComponent("journal-\(UUID().uuidString)", isDirectory: true)
		defer { try? FileManager.default.removeItem(at: base) }
		let workspace = FileManager.default.temporaryDirectory
		// Two servers on one workspace, both believing the next number is 1.
		let first = JournalStore(workspace: workspace, base: base).reserve(startingAt: 1)
		let second = JournalStore(workspace: workspace, base: base).reserve(startingAt: 1)
		#expect(first == "e1" && second == "e2")
		// A reserved id that was never filled in is not a journal entry.
		#expect(JournalStore(workspace: workspace, base: base).load().isEmpty)
	}

	@Test func strandedProposalsAreFoundAndPutBackByTheNextServer() throws {
		let base = FileManager.default.temporaryDirectory.appendingPathComponent("journal-\(UUID().uuidString)", isDirectory: true)
		let root = try scratch()
		defer {
			try? FileManager.default.removeItem(at: base)
			try? FileManager.default.removeItem(at: root)
		}
		let plan = plan(in: root)
		for change in plan.changes { try change.after!.write(toFile: change.path, atomically: true, encoding: .utf8) }
		let store = JournalStore(workspace: root, base: base)
		// A process that no longer exists (pid 2^30 is never in use) left this behind.
		store.savePending(.init(pid: 1 << 30, title: "check_edit verify=build", date: Date(), changes: plan.changes), token: "t")
		#expect(store.loadPending().count == 1)
		for (token, pending) in store.loadPending() {
			var stranded = EditPlan()
			stranded.changes = pending.changes
			#expect(try EditEngine.restoreFiles(stranded, skipChanged: true) { $0 }.isEmpty)
			store.removePending(token)
		}
		#expect(try String(contentsOfFile: plan.changes[0].path, encoding: .utf8) == "a\n")
		#expect(store.loadPending().isEmpty)
	}
}

@Suite struct FlowLintTests {
	private func problems(_ source: String, name: String = "f()", kind: Int = SymbolKind.function) throws -> [String] {
		let index = TextIndex(source)
		let scan = SwiftScan(source)
		let lines = source.components(separatedBy: "\n")
		let nameColumn = (lines[0] as NSString).range(of: NSRegularExpression.escapedPattern(for: NavShared.baseName(name))).location
		let symbol = DocumentSymbol(
			name: name, detail: nil, kind: kind,
			range: LSPRange(start: LSPPosition(line: 0, character: 0), end: LSPPosition(line: lines.count - 1, character: lines.last?.utf16.count ?? 0)),
			selectionRange: LSPRange(
				start: LSPPosition(line: 0, character: nameColumn),
				end: LSPPosition(
					line: 0,
					character: kind == SymbolKind.property
						? nameColumn + name.utf16.count : (lines[0] as NSString).range(of: ")", options: .backwards).upperBound)),
			children: nil)
		return FlowLint.problems(for: symbol, in: source, index: index, scan: scan)
	}

	@Test func flagsAnEmptyBodyAndAMultiStatementBodyWithoutReturn() throws {
		#expect(try problems("func f() -> Int {\n}").first?.contains("body is empty") == true)
		#expect(try problems("func f() -> Int {\n\tlet a = 1\n\tprint(a)\n}").first?.contains("no `return`") == true)
	}

	@Test func leavesLegitimateBodiesAlone() throws {
		#expect(try problems("func f() -> Int { 1 }").isEmpty)  // implicit return
		#expect(try problems("func f() -> Int {\n\tlet a = 1\n\treturn a\n}").isEmpty)
		#expect(try problems("func f() -> Int {\n\tfatalError(\"no\")\n}").isEmpty)
		#expect(try problems("func f() throws -> Int {\n\tlet a = 1\n\tthrow E()\n}").isEmpty)
		#expect(try problems("func f() -> Int {\n\tswitch x {\n\tcase 1: 1\n\tdefault: 2\n\t}\n}").isEmpty)
		#expect(try problems("func f() -> Int {\n\tx\n\t\t.y()\n\t\t.z()\n}").isEmpty)  // one expression over three lines
		#expect(try problems("func f() {\n\tlet a = 1\n\tprint(a)\n}").isEmpty)  // returns nothing
		#expect(try problems("func f() -> Int {\n\ta +\n\t\tb +\n\t\tc\n}").isEmpty)  // operator at the end of a line
		#expect(try problems("func f() -> Int {\n\tcond\n\t\t? 1\n\t\t: 2\n}").isEmpty)
		#expect(try problems("func f() -> Void {\n}").isEmpty)
		#expect(try problems("func f() -> some View {\n\tText(\"a\")\n\tText(\"b\")\n}").isEmpty)  // result builder
		#expect(try problems("func f() -> Int {\n\t// return later\n\tlet s = \"return\"\n\tprint(s)\n}").first?.contains("no `return`") == true)  // words in comments and strings don't count
	}

	@Test func computedPropertiesAreCheckedUnlessTheyHaveAccessors() throws {
		#expect(try problems("var x: Int {\n}", name: "x", kind: SymbolKind.property).first?.contains("empty") == true)
		#expect(try problems("var x: Int {\n\tget { 1 }\n\tset { }\n}", name: "x", kind: SymbolKind.property).isEmpty)
	}
}

@Suite struct OutlineIndexTests {
	private func sym(_ name: String, _ kind: Int, line: Int, children: [DocumentSymbol] = []) -> DocumentSymbol {
		DocumentSymbol(
			name: name, detail: nil, kind: kind,
			range: LSPRange(start: LSPPosition(line: line, character: 0), end: LSPPosition(line: line + 1, character: 1)),
			selectionRange: LSPRange(start: LSPPosition(line: line, character: 4), end: LSPPosition(line: line, character: 4 + name.utf16.count)),
			children: children)
	}

	@Test func extensionMembersBelongToTheExtendedTypeAndFunctionsHideTheirChildren() {
		let tree = [
			sym("Outer", SymbolKind.structure, line: 0, children: [
				sym("Inner", SymbolKind.structure, line: 1, children: [sym("x", SymbolKind.property, line: 2)]),
				sym("f()", SymbolKind.method, line: 3, children: [sym("T", 26, line: 3)]),
			]),
			sym("Outer.Inner", SymbolKind.extensionKind, line: 8, children: [sym("limit", SymbolKind.property, line: 9)]),
			sym("maxRetries", SymbolKind.variable, line: 12),
		]
		let entries = OutlineIndex.flatten(tree, uri: "file:///a.swift")
		func entry(_ name: String) -> OutlineIndex.Entry? { entries.first { $0.symbol.name == name } }
		#expect(entry("x")?.container == ["Outer", "Inner"])
		#expect(entry("limit")?.container == ["Outer", "Inner"])  // declared in `extension Outer.Inner`
		#expect(entry("maxRetries")?.container == [])
		#expect(entry("T") == nil)  // a generic parameter of a function
		#expect(entries.contains { $0.symbol.kind == SymbolKind.extensionKind } == false)
		#expect(entry("limit")?.workspaceSymbol.containerName == "Outer.Inner")
	}

	@Test func containersMatchBySuffixOrExactly() {
		#expect(OutlineIndex.container(["Outer", "Inner"], matches: ["Inner"]))
		#expect(OutlineIndex.container(["Outer", "Inner"], matches: ["Outer", "Inner"]))
		#expect(!OutlineIndex.container(["Outer", "Inner"], matches: ["Outer"]))
		#expect(OutlineIndex.container([], matches: [], exact: true))
		#expect(!OutlineIndex.container(["A"], matches: [], exact: true))
		#expect(OutlineIndex.container(["A"], matches: []))
	}

	private func makeTree() throws -> URL {
		let root = FileManager.default.temporaryDirectory.appendingPathComponent("outline-\(UUID().uuidString)", isDirectory: true).realPath
		try FileManager.default.createDirectory(at: root.appendingPathComponent("Sources"), withIntermediateDirectories: true)
		try FileManager.default.createDirectory(at: root.appendingPathComponent(".build/checkouts/D"), withIntermediateDirectories: true)
		try "struct Profile {}\nlet maxRetries = 3\n".write(to: root.appendingPathComponent("Sources/A.swift"), atomically: true, encoding: .utf8)
		try "extension Profile { static let limit = 1 }\n".write(to: root.appendingPathComponent("Sources/B.swift"), atomically: true, encoding: .utf8)
		try "let maxRetries = 9\n".write(to: root.appendingPathComponent(".build/checkouts/D/C.swift"), atomically: true, encoding: .utf8)
		try "// maxretries\n".write(to: root.appendingPathComponent("Sources/D.txt"), atomically: true, encoding: .utf8)
		return root
	}

	/// Pretends the files are old, so the cache is allowed to trust them.
	private func age(_ root: URL) throws {
		let old = Date().addingTimeInterval(-3600)
		for name in ["Sources/A.swift", "Sources/B.swift"] {
			try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: root.appendingPathComponent(name).path)
		}
	}

	@Test func filesAreFoundByWhatTheyMentionAndSkipBuildDirectories() throws {
		let root = try makeTree()
		defer { try? FileManager.default.removeItem(at: root) }
		func names(_ needles: [String], substring: Bool = false) -> [String] {
			OutlineFileIndex().files(containing: needles, roots: [root], substring: substring).map { ($0 as NSString).lastPathComponent }.sorted()
		}
		#expect(names(["maxRetries"]) == ["A.swift"])
		#expect(names(["Profile", "limit"]) == ["B.swift"])
		#expect(names(["Profile"]) == ["A.swift", "B.swift"])
		#expect(names(["MAXRETRIES"]) == ["A.swift"])  // a prefilter: case doesn't matter, the outline decides
		#expect(names(["retr"]) == [])  // exact identifiers by default
		#expect(names(["retr"], substring: true) == ["A.swift"])
		#expect(names([]) == [])
	}

	@Test func untouchedFilesAreNotReadAgain() throws {
		let root = try makeTree()
		defer { try? FileManager.default.removeItem(at: root) }
		try age(root)
		let index = OutlineFileIndex()
		_ = index.files(containing: ["profile"], roots: [root], substring: false)
		#expect(index.filesRead == 2)
		_ = index.files(containing: ["maxretries"], roots: [root], substring: false)
		_ = index.files(containing: ["limit"], roots: [root], substring: true)
		#expect(index.filesRead == 2)  // answered from memory
	}

	@Test func aFileEditedJustNowIsNeverServedFromTheCache() throws {
		let root = try makeTree()
		defer { try? FileManager.default.removeItem(at: root) }
		try age(root)
		let index = OutlineFileIndex()
		#expect(index.files(containing: ["maxretries"], roots: [root], substring: false).count == 1)
		let file = root.appendingPathComponent("Sources/A.swift")
		// A same-length edit made right away: the size is unchanged and the timestamp may not have moved a whole tick,
		// so only the rule "recently modified files are re-read" separates this from a stale answer.
		try "struct Profile {}\nlet fresh12345 = 3\n".write(to: file, atomically: true, encoding: .utf8)
		#expect(index.files(containing: ["fresh12345"], roots: [root], substring: false).count == 1)
		#expect(index.files(containing: ["maxretries"], roots: [root], substring: false).isEmpty)
		try "struct Profile {}\nlet other6789 = 3\n".write(to: file, atomically: true, encoding: .utf8)
		#expect(index.files(containing: ["other6789"], roots: [root], substring: false).count == 1)
		#expect(index.files(containing: ["fresh12345"], roots: [root], substring: false).isEmpty)
	}

	@Test func deletedFilesLeaveTheCacheAndNewOnesAppear() throws {
		let root = try makeTree()
		defer { try? FileManager.default.removeItem(at: root) }
		try age(root)
		let index = OutlineFileIndex()
		#expect(index.files(containing: ["profile"], roots: [root], substring: false).count == 2)
		try FileManager.default.removeItem(at: root.appendingPathComponent("Sources/B.swift"))
		try "struct Profile2 {}\n".write(to: root.appendingPathComponent("Sources/E.swift"), atomically: true, encoding: .utf8)
		#expect(index.files(containing: ["profile"], roots: [root], substring: false).map { ($0 as NSString).lastPathComponent } == ["A.swift"])
		#expect(index.files(containing: ["profile2"], roots: [root], substring: false).map { ($0 as NSString).lastPathComponent } == ["E.swift"])
	}

	@Test func tokensAreLowercasedIdentifiersWithoutNumbers() {
		let tokens = OutlineFileIndex.tokens(in: Data("let maxRetries = 3_000 + café_1 // Hello World2\n0xFF".utf8))
		#expect(tokens == ["let", "maxretries", "café_1", "hello", "world2"])
	}

}

@Suite struct RenameDisplayAndDependencyTests {
	@Test func showsNoArgumentFunctionsWithParentheses() {
		#expect(SwiftNavigator.displayName("reload", noArguments: true) == "reload()")
		#expect(SwiftNavigator.displayName("reload()", noArguments: true) == "reload()")
		#expect(SwiftNavigator.displayName("make(named:)", noArguments: false) == "make(named:)")
		#expect(SwiftNavigator.displayName("logger", noArguments: false) == "logger")
	}

	@Test func explainsEditsThatReachIntoDependencies() throws {
		let root = FileManager.default.temporaryDirectory.appendingPathComponent("staging-\(UUID().uuidString)", isDirectory: true).realPath
		try FileManager.default.createDirectory(at: root.appendingPathComponent("DerivedData/SourcePackages/checkouts/Dep"), withIntermediateDirectories: true)
		defer { try? FileManager.default.removeItem(at: root) }
		var staging = Staging(root: root, allowedRoots: [root])
		let dependency = root.appendingPathComponent("DerivedData/SourcePackages/checkouts/Dep/D.swift")
		let edit = LSPWorkspaceEdit(fileEdits: [dependency.absoluteString: [TextEdit(line: 0, column: 0, endLine: 0, endColumn: 0, newText: "x")]])
		do {
			try staging.apply(edit)
			Issue.record("expected a refusal")
		} catch let error as ToolInputError {
			#expect("\(error)".contains("implements or overrides a requirement"))
		}
	}
}

@Suite struct ProcessCancellationTests {
	@Test func aCancelledToolCallKillsTheBuildInsteadOfWaitingForIt() async throws {
		let started = Date()
		let task = Task {
			await ToolProcess.run("/bin/sh", arguments: ["-c", "sleep 30; echo done"], directory: FileManager.default.temporaryDirectory, timeout: 60)
		}
		try await Task.sleep(nanoseconds: 300_000_000)
		task.cancel()
		let output = await task.value
		#expect(Date().timeIntervalSince(started) < 10)
		#expect(!output.timedOut)
		#expect(!output.stdout.contains("done"))
	}
}

@Suite struct ReadWriteGateTests {
	private func navigator() -> SwiftNavigator {
		SwiftNavigator(environment: [:], currentDirectory: FileManager.default.temporaryDirectory)
	}

	private actor Log {
		var events: [String] = []
		func add(_ event: String) { events.append(event) }
	}

	@Test func readersShareAndAWriterWaitsForThemAndKeepsLaterReadersOut() async throws {
		let navigator = navigator()
		let log = Log()
		await navigator.acquire(writer: false)
		await navigator.acquire(writer: false)  // two readers at once
		let writer = Task {
			await navigator.acquire(writer: true)
			await log.add("writer in")
			try? await Task.sleep(nanoseconds: 50_000_000)
			await log.add("writer out")
			await navigator.release(writer: true)
		}
		try await Task.sleep(nanoseconds: 50_000_000)
		let late = Task {
			await navigator.acquire(writer: false)
			await log.add("late reader in")
			await navigator.release(writer: false)
		}
		try await Task.sleep(nanoseconds: 50_000_000)
		#expect(await log.events.isEmpty, "the writer must wait for both readers, and the later reader for the writer")
		await navigator.release(writer: false)
		try await Task.sleep(nanoseconds: 30_000_000)
		#expect(await log.events.isEmpty)
		await navigator.release(writer: false)
		await writer.value
		await late.value
		#expect(await log.events == ["writer in", "writer out", "late reader in"])
	}

	@Test func aReadToolWaitsForARunningWriteTool() async throws {
		let navigator = navigator()
		let log = Log()
		let write = Task {
			await navigator.withWriteLock {
				await log.add("write start")
				try? await Task.sleep(nanoseconds: 100_000_000)
				await log.add("write end")
			}
		}
		try await Task.sleep(nanoseconds: 30_000_000)
		let read = await navigator.run {
			await log.add("read")
			return "ok"
		}
		await write.value
		#expect(read.text == "ok")
		#expect(await log.events == ["write start", "write end", "read"])
	}
}

@Suite struct CheckAccuracyTests {
	@Test func buildDiagnosticsOfSameNamedFilesInDifferentFoldersAreDistinct() {
		let a = BuildDiagnostic(path: "/p/Models/Item.swift", line: 1, column: 1, severity: "error", message: "boom")
		let b = BuildDiagnostic(path: "/p/Views/Item.swift", line: 1, column: 1, severity: "error", message: "boom")
		#expect(a.identity != b.identity)
	}

	@Test func linkerAndCErrorsAreParsed() {
		let output = """
			/p/Sources/C/a.c:3:5: error: unknown type name 'foo'
			ld: symbol(s) not found for architecture arm64
			"""
		let parsed = BuildRunner.parse(output)
		#expect(parsed.count == 2)
		#expect(parsed.contains { $0.path == "(link)" })
	}

	@Test func forceUnwrapFixItsAreSkippedUnlessAsked() {
		let unwrap = LSPCodeAction(title: "Force unwrap the optional")
		let other = LSPCodeAction(title: "Add 'try'")
		#expect(SwiftNavigator.preferredFix([unwrap, other], only: nil)?.title == "Add 'try'")
		#expect(SwiftNavigator.preferredFix([unwrap], only: nil) == nil)
		#expect(SwiftNavigator.preferredFix([unwrap], only: "unwrap")?.title == unwrap.title)
	}

	@Test func testFilesAreRecognisedByNameNotSubstring() {
		#expect(SwiftNavigator.isTestFile("/p/Tests/AppTests/X.swift"))
		#expect(SwiftNavigator.isTestFile("/p/App/StoreTests.swift"))
	}
}

@Suite struct IdentifierTests {
	@Test func unicodeIdentifiersAreAccepted() {
		#expect(RenameName.isIdentifier("größe"))
		#expect(RenameName.isIdentifier("名前"))
		#expect(!RenameName.isIdentifier("1abc"))
		#expect(!RenameName.isIdentifier("a-b"))
	}
}

@Suite struct DeprecatedAliasTests {
	@Test func anObjcSelectorIsNotCopiedToTheForwardingAlias() throws {
		let source = "@objc(doIt:) func old(_ x: Int) {\n}"
		let lines = source.components(separatedBy: "\n")
		let column = (lines[0] as NSString).range(of: "old").location
		let symbol = DocumentSymbol(
			name: "old(_:)", detail: nil, kind: SymbolKind.method,
			range: LSPRange(start: LSPPosition(line: 0, character: 0), end: LSPPosition(line: 1, character: 1)),
			selectionRange: LSPRange(start: LSPPosition(line: 0, character: column), end: LSPPosition(line: 0, character: column + 3)),
			children: nil)
		let alias = try #require(
			SwiftNavigator.deprecatedAlias(for: symbol, parents: [], text: source, index: TextIndex(source), newFull: "new(_:)", newBase: "new"))
		#expect(!alias.contains("@objc"))
		#expect(alias.contains("func old(_ x: Int) { new(x) }"))
	}
}

@Suite struct LocateTests {
	@Test func indentationInsensitiveMatchingStaysOutOfMultilineStrings() throws {
		let text = "let s = \"\"\"\n    hello\n    world\n    \"\"\"\nfunc f() {\n\tprint(1)\n}\n"
		#expect(throws: ToolInputError.self) {
			_ = try FileEditSpec.locate("hello\nworld", new: "bye\nworld", in: text, path: "a.swift", all: false)
		}
		// Ordinary code still matches loosely.
		let edits = try FileEditSpec.locate("print(1)", new: "print(2)", in: text, path: "a.swift", all: false)
		#expect(edits.count == 1)
		let loose = try FileEditSpec.locate("func f() {\nprint(1)\n}", new: "func f() {\nprint(2)\n}", in: text, path: "a.swift", all: false)
		#expect(loose.count == 1)
	}
}
