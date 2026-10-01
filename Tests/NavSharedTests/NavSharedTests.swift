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

@Suite struct PathsTests {
	@Test func realPathKeepsPrivatePrefix() {
		let tmp = URL(fileURLWithPath: "/tmp").realPath.path
		#expect(tmp == "/private/tmp")
	}

	@Test func realPathOfParsedFileURLIsADirectory() {
		let url = URL(string: "file:///tmp")!.realPath
		#expect(url.hasDirectoryPath)
		#expect(URL(fileURLWithPath: "x.swift", relativeTo: url).path == "/private/tmp/x.swift")
	}

	@Test func relativePathAcceptsEitherSpelling() {
		let root = URL(fileURLWithPath: "/tmp/ws")
		#expect(relativePath("/private/tmp/ws/Sources/A.swift", in: root) == "Sources/A.swift")
		#expect(relativePath("/tmp/ws/Sources/A.swift", in: root) == "Sources/A.swift")
		#expect(relativePath("/elsewhere/A.swift", in: root) == nil)
	}

	@Test func siblingPackagesShowAsRelative() {
		let root = URL(fileURLWithPath: "/Users/dev/repo/src/Planes")
		#expect(displayPathOutside("/Users/dev/repo/src/Octopus/Sources/X.swift", root: root) == "../Octopus/Sources/X.swift")
		#expect(displayPathOutside("/opt/other/X.swift", root: root) == "/opt/other/X.swift")
	}
}

@Suite struct SelectorFallbackTests {
	@Test func nonProjectBaseDefersToClientRoots() {
		let selector = WorkspaceSelector(
			explicitEnv: "CODENAV_TEST_UNSET", environment: [:], currentDirectory: URL(fileURLWithPath: "/tmp")
		)
		let project = URL(fileURLWithPath: "/tmp/codenav-fixture-project").realPath
		let selection = selector.select(clientRootURIs: ["file:///tmp/codenav-fixture-project"], isProject: { $0 == project })
		#expect(selection.root == project)
		#expect(selection.source == WorkspaceSelector.rootsBecauseNoProjectSource)
	}

	@Test func pinnedWorkspaceIgnoresRoots() {
		let selector = WorkspaceSelector(
			explicitEnv: "PIN", environment: ["PIN": "/tmp"], currentDirectory: URL(fileURLWithPath: "/")
		)
		#expect(selector.select(clientRootURIs: ["file:///usr"]).source == "PIN")
	}
}

@Suite struct RankingExtraTests {
	@Test func dependenciesRankAfterProjectAndTests() {
		let symbols = [
			WorkspaceSymbol(name: "Client", kind: 5, uri: "file:///w/.build/checkouts/Dep/Sources/Client.swift"),
			WorkspaceSymbol(name: "Client", kind: 5, uri: "file:///w/Tests/ClientTests/Client.swift"),
			WorkspaceSymbol(name: "Client", kind: 5, uri: "file:///w/Sources/Client.swift"),
		]
		let uris = rankWorkspaceSymbols(symbols, query: "Client").map(\.location.uri)
		#expect(uris == [
			"file:///w/Sources/Client.swift", "file:///w/Tests/ClientTests/Client.swift",
			"file:///w/.build/checkouts/Dep/Sources/Client.swift",
		])
	}

	@Test func fuzzyOnlyHitsAreLabelledAndShortestFirst() {
		let symbols = [
			WorkspaceSymbol(name: "XxQxxxxLongName", kind: 5, uri: "file:///w/A.swift"),
			WorkspaceSymbol(name: "XQ", kind: 5, uri: "file:///w/B.swift"),
		]
		let listing = formatWorkspaceSymbols(symbols, workspaceRoot: URL(fileURLWithPath: "/w"), query: "xq9", fuzzy: false)
		#expect(listing.contains("closest fuzzy matches"))
		#expect(listing.range(of: "XQ")!.lowerBound < listing.range(of: "XxQxxxxLongName")!.lowerBound)
	}
}

@Suite struct BuildOutputPathTests {
	@Test func derivedSourcesAreLabelledGeneratedAndCountAsDependencies() {
		let uri = "file:///tmp/dd/Build/Intermediates.noindex/App.build/Debug/App.build/DerivedSources/GeneratedStrings.swift"
		#expect(uriToRelative(uri, workspaceRoot: URL(fileURLWithPath: "/work/app")) == "<generated> GeneratedStrings.swift")
		#expect(isDependencyPath(uri))
	}
}

@Suite struct ObjectiveCNamingTests {
	@Test func selectorsFoldToTheirSwiftSpelling() {
		#expect(baseName("loadFileAtPath:error:") == "loadFileAtPath")
		#expect(baseName("greet:") == "greet")
		#expect(matchTier(name: "increment(by:)", query: "incrementBy") == 1)
		#expect(matchTier(name: "incrementBy:", query: "incrementBy") <= 1)
		#expect(ParsedQuery("Greeter.greet:").base == "greet")
		#expect(ParsedQuery("Greeter.greet:").container == ["Greeter"])
	}
}

@Suite struct DependencyCapTests {
	private func symbol(_ name: String, _ path: String) -> WorkspaceSymbol {
		WorkspaceSymbol(
			name: name, kind: 5, uri: "file://\(path)",
			range: LSPRange(start: LSPPosition(line: 1, character: 0), end: LSPPosition(line: 1, character: 1)))
	}

	@Test func dependencyHitsAreCappedAfterProjectOnes() {
		let root = URL(fileURLWithPath: "/work/App")
		let symbols = [symbol("Tensor", "/work/App/Sources/Tensor.swift")]
			+ (0..<5).map { symbol("Tensor\($0)", "/work/App/Pods/Torch/T\($0).h") }
		let capped = formatWorkspaceSymbols(symbols, workspaceRoot: root, query: "Tensor", dependencyLimit: 2)
		#expect(capped.contains("Sources/Tensor.swift"))
		#expect(capped.components(separatedBy: "Pods/").count - 1 == 2)
		#expect(capped.contains("3 more match(es) in dependencies hidden"))
		let all = formatWorkspaceSymbols(symbols, workspaceRoot: root, query: "Tensor")
		#expect(all.components(separatedBy: "Pods/").count - 1 == 5)
	}
}
