import Foundation
import Testing

@testable import NavShared

@Suite struct ParamsTests {
	@Test func prefersPreferredThenAlias() throws {
		#expect(try resolveNameQuery(preferred: "name", ["name": "A", "query": "B"]) == "A")
		#expect(try resolveNameQuery(preferred: "name", ["name": nil, "query": "B"]) == "B")
	}

	@Test func missingNameExplainsAlias() {
		#expect(throws: ToolInputError.self) { try resolveNameQuery(preferred: "name", example: "Foo", ["name": nil, "query": ""]) }
	}
}

@Suite struct ParsedQueryTests {
	@Test func splitsContainerBaseAndSignature() {
		let parsed = ParsedQuery("Outer.Inner.run(_:loudly:)")
		#expect(parsed.container == ["Outer", "Inner"])
		#expect(parsed.base == "run")
		#expect(parsed.signature == "(_:loudly:)")
	}

	@Test func dropsGenericArguments() {
		let parsed = ParsedQuery("Box<Int>.value")
		#expect(parsed.container == ["Box"])
		#expect(parsed.base == "value")
		#expect(parsed.signature == nil)
	}
}

@Suite struct KindFilterTests {
	@Test func parsesLabelsCaseInsensitively() throws {
		let kinds = try parseKindFilter("Struct, protocol")
		#expect(kinds?.contains(SymbolKind.protocol) == true)
		#expect(kinds?.count == 2)
	}

	@Test func blankIsNoFilter() throws {
		#expect(try parseKindFilter("  ") == nil)
	}

	@Test func unknownKindThrows() {
		#expect(throws: ToolInputError.self) { try parseKindFilter("banana") }
	}
}

@Suite struct RankingTests {
	@Test func exactBeforePrefixBeforeFuzzy_andNoiseDropped() {
		let symbols = [
			WorkspaceSymbol(name: "makeUserServiceFactory()", kind: 12, uri: "file:///w/Sources/A.swift"),
			WorkspaceSymbol(name: "UserServiceTests", kind: 5, uri: "file:///w/Tests/UserServiceTests.swift"),
			WorkspaceSymbol(name: "UserService", kind: 5, uri: "file:///w/Sources/UserService.swift"),
			WorkspaceSymbol(name: "$s7SampleKit11UserServiceC", kind: 5, uri: "file:///w/Sources/UserService.swift"),
		]
		let ranked = filterWorkspaceSymbols(rankWorkspaceSymbols(symbols, query: "UserService"))
		#expect(ranked.first?.name == "UserService")
		#expect(!ranked.contains { $0.name.hasPrefix("$") })
	}
}

@Suite struct NoticeBoardTests {
	@Test func annotatesOnceThenClears() {
		let board = NoticeBoard(serverName: "t", executable: nil)
		board.post("index still running")
		#expect(board.annotate("result").contains("index still running"))
		#expect(board.annotate("result") == "result")
	}

	@Test func duplicateNoticesCollapse() {
		let board = NoticeBoard(serverName: "t", executable: nil)
		board.post("x")
		board.post("x")
		#expect(board.drain() == ["x"])
	}
}

@Suite struct ExcludeTests {
	@Test func buildDirectoriesAreExcluded() {
		#expect(Exclude.directoryNames.contains(".build"))
		#expect(Exclude.directoryNames.contains("DerivedData"))
	}
}

@Suite struct JSONValueTests {
	@Test func lenientAccessors() throws {
		let value = try JSONDecoder().decode(JSONValue.self, from: Data(#"{"a":3,"b":"x"}"#.utf8))
		#expect(value["a"]?.intValue == 3)
		#expect(value["b"]?.stringValue == "x")
	}
}
