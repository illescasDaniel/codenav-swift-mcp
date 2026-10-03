import Foundation
import Testing

@testable import CodenavSwift
@testable import NavShared

@Suite struct SwiftScanTests {
	@Test func stringsAndCommentsAreNotCode() {
		let text = "let a = \"{ not code }\" // { nor this\nlet b = 1 /* { */ + 2"
		let scan = SwiftScan(text)
		for (offset, unit) in text.utf16.enumerated() where unit == UInt16(UInt8(ascii: "{")) { #expect(!scan.isCode[offset]) }
		#expect(scan.isCode[text.utf16.count - 1])
	}

	@Test func interpolationAndRawStringsStayStrings() {
		let text = "let s = \"a \\(f(\"x\")) b\"; let r = #\"he said \"hi\" {\"#; let k = 1"
		let scan = SwiftScan(text)
		let tail = (text as NSString).range(of: "let k = 1")
		#expect(scan.isCode[tail.location])
		let brace = (text as NSString).range(of: "{")
		#expect(!scan.isCode[brace.location])
	}

	@Test func multilineStringsEndAtTheirDelimiter() {
		let text = "let s = \"\"\"\n  { \"quoted\"\n  \"\"\"\nlet x = 1"
		let scan = SwiftScan(text)
		#expect(scan.isCode[(text as NSString).range(of: "let x").location])
		#expect(!scan.isCode[(text as NSString).range(of: "{").location])
	}

	@Test func findsTheBodyAndSkipsClosuresInDefaults() throws {
		let text = "func f(a: () -> Void = { }, b: Int) -> Int {\n\treturn b\n}\nlet next = 1"
		let scan = SwiftScan(text)
		let declaration = 0..<((text as NSString).range(of: "}\nlet").location + 1)
		let body = try #require(scan.body(of: declaration, from: 6))
		#expect(scan.text(body.open, body.close + 1) == "{\n\treturn b\n}")
	}

	@Test func aRequirementHasNoBody() {
		let text = "func save(_ user: User) async throws\nvar other: Int { get }"
		let scan = SwiftScan(text)
		#expect(scan.body(of: 0..<36, from: 4) == nil)
	}

	@Test func parameterListSkipsGenericsAndFailableMarks() throws {
		let text = "func run<T: Equatable>(_ x: T, y: [Int: String] = [:]) -> Int"
		let scan = SwiftScan(text)
		let list = try #require(scan.parenthesized(after: 8))
		let parameters = try #require(SignatureEditor.parameters(in: scan, open: list.open, close: list.close))
		#expect(parameters.map(\.key) == ["x", "y"])
		#expect(parameters[1].defaultValue == "[:]")
		let failable = SwiftScan("init?(flag: Bool)")
		#expect(failable.parenthesized(after: 4) != nil)
	}

	@Test func anOpeningBracketCanBeFoundAtTheTopLevel() {
		let scan = SwiftScan("var label: String { name }")
		#expect(scan.firstTopLevel("{", in: 0..<scan.units.count) == ("var label: String { name }" as NSString).range(of: "{").location)
		let nested = SwiftScan("f(a: { 1 }) { 2 }")
		#expect(nested.firstTopLevel("{", in: 0..<nested.units.count) == ("f(a: { 1 }) { 2 }" as NSString).range(of: "{ 2").location)  // after the call, not inside it
		#expect(nested.firstTopLevel("(", in: 0..<nested.units.count) == 1)
	}

	@Test func splitsOnTopLevelCommasOnly() {
		let scan = SwiftScan("a: [1, 2], b: f(x, y), c: Dictionary<String, Int>, d: (Int, Int) -> Void")
		#expect(scan.splitTopLevel(0, scan.units.count).count == 4)
	}

	@Test func docCommentsAreIncludedInWholeLineRanges() {
		let text = "struct A {}\n\n/// Docs\n/// more\nfunc f() {\n}\n\nfunc g() {}\n"
		let index = TextIndex(text)
		let range = LSPRange(start: LSPPosition(line: 4, character: 0), end: LSPPosition(line: 5, character: 1))
		let span = DeclarationRange.wholeLines(of: range, in: index, includingDocComment: true, swallowBlank: true)
		#expect(index.text(from: span.start, to: span.end) == "/// Docs\n/// more\nfunc f() {\n}\n\n")
	}
}

@Suite struct SignatureParameterTests {
	@Test func parsesLabelsNamesTypesAndDefaults() throws {
		let parameter = try #require(SignatureParameter.parse("label name: inout [String: Int] = [:]"))
		#expect(parameter.label == "label")
		#expect(parameter.name == "name")
		#expect(parameter.type == "inout [String: Int]")
		#expect(parameter.defaultValue == "[:]")
		#expect(parameter.rendered == "label name: inout [String: Int] = [:]")
		let single = try #require(SignatureParameter.parse("id: Int"))
		#expect(single.label == "id" && single.name == "id")
		#expect(single.argument("5") == "id: 5")
		#expect(try #require(SignatureParameter.parse("_ user: User")).argument("u") == "u")
		#expect(SignatureParameter.parse("nonsense") == nil)
	}
}

@Suite struct SignatureChangeTests {
	static let old = [
		SignatureParameter(label: "_", name: "user", type: "User", defaultValue: nil),
		SignatureParameter(label: "to", name: "name", type: "String", defaultValue: nil),
	]

	@Test func addWithDefaultNeedsNoCallRewrite() throws {
		let flag = SignatureParameter(label: "force", name: "force", type: "Bool", defaultValue: "false")
		let change = try SignatureChange.plan(old: Self.old, operations: [.add(flag, position: .last, callValue: nil)])
		#expect(!change.needsCallRewrite)
		#expect(change.new.map(\.key) == ["user", "to", "force"])
	}

	@Test func addWithoutDefaultNeedsAValue() {
		let flag = SignatureParameter(label: "force", name: "force", type: "Bool", defaultValue: nil)
		#expect(throws: SignatureError.self) {
			try SignatureChange.plan(old: Self.old, operations: [.add(flag, position: .last, callValue: nil)])
		}
	}

	@Test func removeReorderRetypeAndErrors() throws {
		let removed = try SignatureChange.plan(old: Self.old, operations: [.remove(key: "to")])
		#expect(removed.new.map(\.key) == ["user"])
		let reordered = try SignatureChange.plan(old: Self.old, operations: [.reorder(keys: ["to", "user"])])
		#expect(reordered.new.map(\.key) == ["to", "user"])
		#expect(reordered.needsCallRewrite)
		let retyped = try SignatureChange.plan(old: Self.old, operations: [.retype(key: "to", type: "Substring")])
		#expect(retyped.new[1].type == "Substring")
		#expect(!retyped.needsCallRewrite)
		#expect(throws: SignatureError.self) { try SignatureChange.plan(old: Self.old, operations: [.remove(key: "nope")]) }
		let clash = SignatureParameter(label: "to", name: "to", type: "Int", defaultValue: "1")
		#expect(throws: SignatureError.self) {
			try SignatureChange.plan(old: Self.old, operations: [.add(clash, position: .last, callValue: nil)])
		}
	}

	@Test func multilineListsKeepTheirShape() throws {
		let original = "\n\t\ta: Int,\n\t\tb: Int\n\t"
		let rendered = SignatureChange.layout(["a: Int", "b: Int", "c: Int"], like: original)
		#expect(rendered == "\n\t\ta: Int,\n\t\tb: Int,\n\t\tc: Int\n\t")
		#expect(SignatureChange.layout(["a: Int", "b: Int"], like: "a: Int") == "a: Int, b: Int")
	}
}

@Suite struct CallRewriteTests {
	private func call(_ text: String, change: SignatureChange, trailing: Bool = false) throws -> SignatureEditor.CallRewrite {
		let scan = SwiftScan(text)
		let open = try #require(text.firstIndex(of: "(")).utf16Offset(in: text)
		let close = try #require(scan.matching(openAt: open))
		let arguments = SignatureEditor.arguments(in: scan, open: open, close: close)
		return SignatureEditor.rewrite(
			arguments: arguments, original: scan.text(open + 1, close), hasTrailingClosure: trailing, change: change)
	}

	@Test func addedParameterGetsTheCallValue() throws {
		let change = try SignatureChange.plan(
			old: SignatureChangeTests.old,
			operations: [.add(.init(label: "force", name: "force", type: "Bool", defaultValue: nil), position: .last, callValue: "false")])
		#expect(try call("rename(copy, to: \"x\")", change: change) == .rewritten("copy, to: \"x\", force: false"))
	}

	@Test func removedAndReorderedArgumentsFollowTheirParameters() throws {
		let removed = try SignatureChange.plan(old: SignatureChangeTests.old, operations: [.remove(key: "user")])
		#expect(try call("rename(copy, to: name)", change: removed) == .rewritten("to: name"))
		let reordered = try SignatureChange.plan(old: SignatureChangeTests.old, operations: [.reorder(keys: ["to", "user"])])
		#expect(try call("rename(f(a, b), to: [1, 2])", change: reordered) == .rewritten("to: [1, 2], f(a, b)"))
	}

	@Test func skippedDefaultedParametersStayOmitted() throws {
		let old = [
			SignatureParameter(label: "a", name: "a", type: "Int", defaultValue: nil),
			SignatureParameter(label: "b", name: "b", type: "Int", defaultValue: "0"),
			SignatureParameter(label: "c", name: "c", type: "Int", defaultValue: nil),
		]
		let change = try SignatureChange.plan(old: old, operations: [.reorder(keys: ["c", "b", "a"])])
		#expect(try call("f(a: 1, c: 3)", change: change) == .rewritten("c: 3, a: 1"))
	}

	@Test func unchangedTrailingClosureAndMismatches() throws {
		let harmless = try SignatureChange.plan(
			old: SignatureChangeTests.old,
			operations: [.add(.init(label: "force", name: "force", type: "Bool", defaultValue: "false"), position: .last, callValue: nil)])
		#expect(try call("rename(copy, to: \"x\")", change: harmless) == .unchanged)
		let removed = try SignatureChange.plan(old: SignatureChangeTests.old, operations: [.remove(key: "to")])
		// No parameter takes a closure here, so a trailing closure can't belong to this function.
		if case .manual = try call("rename(copy) { }", change: removed, trailing: true) {} else { Issue.record("expected manual") }
		if case .manual = try call("rename(copy, wrong: 1)", change: removed) {} else { Issue.record("expected manual") }
	}
}

@Suite struct TrailingClosureRewriteTests {
	static let old = [
		SignatureParameter(label: "_", name: "id", type: "Int", defaultValue: nil),
		SignatureParameter(label: "then", name: "done", type: "@escaping (Int) -> Void", defaultValue: nil),
	]

	private func call(_ text: String, change: SignatureChange) throws -> SignatureEditor.CallRewrite {
		let scan = SwiftScan(text)
		let open = (text as NSString).range(of: "(").location
		let close = try #require(scan.matching(openAt: open))
		return SignatureEditor.rewrite(
			arguments: SignatureEditor.arguments(in: scan, open: open, close: close), original: scan.text(open + 1, close),
			hasTrailingClosure: true, change: change)
	}

	@Test func aParameterAddedBeforeTheClosureKeepsItTrailing() throws {
		let change = try SignatureChange.plan(
			old: Self.old,
			operations: [.add(.init(label: "force", name: "force", type: "Bool", defaultValue: nil), position: .before("then"), callValue: "true")])
		#expect(try call("load(5) { print($0) }", change: change) == .rewritten("5, force: true"))
	}

	@Test func removingAnArgumentBeforeTheClosureLeavesTheClosureAlone() throws {
		let change = try SignatureChange.plan(old: Self.old, operations: [.remove(key: "id")])
		#expect(try call("load(5) { print($0) }", change: change) == .rewritten(""))
	}

	@Test func theClosureParameterMustStayLastAndMustNotBeDropped() throws {
		let after = try SignatureChange.plan(
			old: Self.old,
			operations: [.add(.init(label: "force", name: "force", type: "Bool", defaultValue: nil), position: .last, callValue: "true")])
		if case .manual = try call("load(5) { }", change: after) {} else { Issue.record("expected manual") }
		let dropped = try SignatureChange.plan(old: Self.old, operations: [.remove(key: "then")])
		if case .manual = try call("load(5) { }", change: dropped) {} else { Issue.record("expected manual") }
		let reordered = try SignatureChange.plan(old: Self.old, operations: [.reorder(keys: ["then", "id"])])
		if case .manual = try call("load(5) { }", change: reordered) {} else { Issue.record("expected manual") }
	}
}
