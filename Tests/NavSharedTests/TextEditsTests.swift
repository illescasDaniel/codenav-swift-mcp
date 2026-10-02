import Foundation
import Testing

@testable import NavShared

@Suite struct TextIndexTests {
	@Test func mapsPositionsAndOffsetsBothWays() throws {
		let index = TextIndex("ab\ncd\r\nef\rgh")
		#expect(index.lineCount == 4)
		#expect(try index.offset(LSPPosition(line: 1, character: 1)) == 4)
		#expect(try index.offset(LSPPosition(line: 2, character: 0)) == 7)
		#expect(try index.offset(LSPPosition(line: 3, character: 2)) == 12)
		#expect(index.position(at: 4) == LSPPosition(line: 1, character: 1))
		#expect(index.lineText(1) == "cd")
		#expect(index.lineText(2) == "ef")
	}

	@Test func columnsPastTheEndClampAndLinesPastTheEndThrow() throws {
		let index = TextIndex("abc\nde")
		#expect(try index.offset(LSPPosition(line: 0, character: 99)) == 3)
		#expect(throws: TextEditError.self) { try index.offset(LSPPosition(line: 5, character: 0)) }
	}

	@Test func columnsAreUTF16() throws {
		// "😀" is two UTF-16 units: the column after it is 2, not 1.
		let text = "😀x"
		let index = TextIndex(text)
		#expect(try index.offset(LSPPosition(line: 0, character: 2)) == 2)
		let edited = try TextEditing.apply([TextEdit(line: 0, column: 2, endLine: 0, endColumn: 3, newText: "y")], to: text)
		#expect(edited == "😀y")
	}
}

@Suite struct TextEditingTests {
	@Test func appliesSeveralEditsAgainstTheOriginalPositions() throws {
		let text = "let a = 1\nlet b = 2\n"
		let edits = [
			TextEdit(line: 1, column: 4, endLine: 1, endColumn: 5, newText: "bee"),
			TextEdit(line: 0, column: 4, endLine: 0, endColumn: 5, newText: "ay"),
		]
		#expect(try TextEditing.apply(edits, to: text) == "let ay = 1\nlet bee = 2\n")
	}

	@Test func insertsAtTheSameSpotKeepTheirOrder() throws {
		let edits = [
			TextEdit(line: 0, column: 0, endLine: 0, endColumn: 0, newText: "A"),
			TextEdit(line: 0, column: 0, endLine: 0, endColumn: 0, newText: "B"),
		]
		#expect(try TextEditing.apply(edits, to: "x") == "ABx")
	}

	@Test func overlappingEditsAreRejected() {
		let edits = [
			TextEdit(line: 0, column: 0, endLine: 0, endColumn: 3, newText: "x"),
			TextEdit(line: 0, column: 2, endLine: 0, endColumn: 4, newText: "y"),
		]
		#expect(throws: TextEditError.self) { try TextEditing.apply(edits, to: "abcdef") }
	}

	@Test func windowsLineEndingsSurvive() throws {
		let text = "a\r\nb\r\nc"
		let edited = try TextEditing.apply([TextEdit(line: 1, column: 0, endLine: 1, endColumn: 1, newText: "B")], to: text)
		#expect(edited == "a\r\nB\r\nc")
	}

	@Test func replacementIsTheMinimalCoveringEdit() throws {
		let old = "one\ntwo\nthree\n"
		let new = "one\n2\nthree\n"
		let edit = try #require(TextEditing.replacement(from: old, to: new))
		#expect(try TextEditing.apply([edit], to: old) == new)
		#expect(TextEditing.replacement(from: old, to: old) == nil)
	}

	@Test func findsLinesOfAnOccurrence() {
		#expect(TextEditing.lines(of: "x", in: "x\ny\nx x\n") == [1, 3, 3])
	}
}

@Suite struct WorkspaceEditDecodingTests {
	@Test func decodesChangesAndDocumentChanges() throws {
		let json = """
			{"changes": {"file:///a.swift": [{"range": {"start": {"line": 0, "character": 0}, "end": {"line": 0, "character": 1}}, "newText": "x"}]},
			 "documentChanges": [
			   {"textDocument": {"uri": "file:///b.swift", "version": 1}, "edits": [{"range": {"start": {"line": 1, "character": 0}, "end": {"line": 1, "character": 0}}, "newText": "y", "annotationId": "z"}]},
			   {"kind": "create", "uri": "file:///c.swift"}
			 ]}
			"""
		let edit = try JSONDecoder().decode(LSPWorkspaceEdit.self, from: Data(json.utf8))
		#expect(edit.fileEdits["file:///a.swift"]?.first?.newText == "x")
		#expect(edit.fileEdits["file:///b.swift"]?.first?.newText == "y")
		#expect(edit.resourceOperations == ["create file:///c.swift"])
		#expect(edit.editCount == 2)
	}

	@Test func diagnosticsCarryTheirQuickFixes() throws {
		let json = """
			{"range": {"start": {"line": 11, "character": 27}, "end": {"line": 11, "character": 27}}, "severity": 1,
			 "message": "Missing argument for parameter 'overwrite' in call",
			 "codeActions": [{"title": "Insert ', overwrite: '", "kind": "quickfix",
			   "edit": {"changes": {"file:///a.swift": [{"range": {"start": {"line": 11, "character": 27}, "end": {"line": 11, "character": 27}}, "newText": ", overwrite: "}]}}}]}
			"""
		let diagnostic = try JSONDecoder().decode(LSPDiagnostic.self, from: Data(json.utf8))
		#expect(diagnostic.isError)
		#expect(diagnostic.fixes.count == 1)
		#expect(diagnostic.fixes[0].edit?.fileEdits["file:///a.swift"]?.first?.newText == ", overwrite: ")
		#expect(diagnostic.raw != nil)
	}
}

@Suite struct UnifiedDiffTests {
	@Test func showsChangedLinesWithContext() {
		let old = "a\nb\nc\nd\ne\nf\ng\n"
		let new = "a\nb\nC\nd\ne\nf\ng\n"
		let diff = UnifiedDiff.make(old: old, new: new, path: "x.swift", context: 1)
		#expect(diff.contains("--- a/x.swift"))
		#expect(diff.contains("-c\n+C"))
		#expect(diff.contains("@@ -2,3 +2,3 @@"))
		#expect(!diff.contains(" a\n"))
	}

	@Test func separateChangesBecomeSeparateHunks() {
		let old = (1...20).map(String.init).joined(separator: "\n") + "\n"
		let new = old.replacingOccurrences(of: "\n2\n", with: "\ntwo\n").replacingOccurrences(of: "\n19\n", with: "\nnineteen\n")
		let diff = UnifiedDiff.make(old: old, new: new, path: "n", context: 1)
		#expect(diff.components(separatedBy: "@@ -").count == 3)
	}

	@Test func pureInsertionAndDeletionCounts() {
		#expect(UnifiedDiff.stats(old: "a\nb\n", new: "a\nx\ny\nb\n") == (2, 0))
		#expect(UnifiedDiff.stats(old: "a\nb\nc\n", new: "a\n") == (0, 2))
		#expect(UnifiedDiff.make(old: "same", new: "same", path: "p") == "")
	}

	@Test func newFileIsAllAdditions() {
		let diff = UnifiedDiff.make(old: "", new: "a\nb\n", path: "new.swift")
		#expect(diff.contains("+a\n+b"))
		#expect(diff.contains("@@ -0,0 +1,2 @@"))
	}
}

@Suite struct IndentationTests {
	@Test func detectsTabsAndSpaceWidths() {
		#expect(Indentation.detect(in: "struct A {\n\tvar x = 1\n\tfunc f() {\n\t\treturn\n\t}\n}\n") == .tab)
		#expect(Indentation.detect(in: "struct A {\n  var x = 1\n  func f() {\n    return\n  }\n}\n") == .spaces(2))
		#expect(Indentation.detect(in: "struct A {\n    var x = 1\n}\n") == .spaces(4))
		#expect(Indentation.detect(in: "let a = 1\n") == .spaces(4))
	}

	@Test func flatGeneratedCodeIsNestedByItsBraces() {
		let flat = "func f() -> Int {\nif x {\nreturn 1\n}\nreturn 2\n}"
		let result = Indentation.reindent(flat, base: "\t", unit: .tab)
		#expect(result == "func f() -> Int {\n\t\tif x {\n\t\t\treturn 1\n\t\t}\n\t\treturn 2\n\t}")
	}

	@Test func indentedCodeKeepsItsShapeButTakesTheFilesUnit() {
		let spaced = "func f() {\n    if x {\n        y()\n    }\n}"
		let result = Indentation.reindent(spaced, base: "\t", unit: .tab, sourceUnit: .spaces(4))
		#expect(result == "func f() {\n\t\tif x {\n\t\t\ty()\n\t\t}\n\t}")
	}

	@Test func braceDeltaIgnoresStringsAndComments() {
		#expect(Indentation.braceDelta("let s = \"{\" // }") == 0)
		#expect(Indentation.braceDelta("foo(bar) {") == 1)
		#expect(Indentation.braceDelta("}") == -1)
	}
}
