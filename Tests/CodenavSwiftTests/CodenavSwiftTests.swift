import Foundation
import Testing

@testable import CodenavSwift
@testable import NavShared

@Suite struct ToolArgumentsTests {
	@Test func acceptsNumbersAsStrings() throws {
		let arguments = ToolArguments(["line": .string("12"), "column": .int(3)])
		#expect(try arguments.int("line") == 12)
		#expect(try arguments.int("column") == 3)
	}

	@Test func missingRequiredThrows() {
		#expect(throws: ToolInputError.self) { try ToolArguments([:]).requiredString("file_path") }
	}

	@Test func booleansFromStrings() {
		#expect(ToolArguments(["f": .string("false")]).bool("f", default: true) == false)
		#expect(ToolArguments([:]).bool("f", default: true) == true)
	}
}

@Suite struct CatalogTests {
	@Test func exposesAllTools() {
		#expect(ToolCatalog.tools.map(\.name) == [
			"workspace", "hover", "definition", "references", "search_symbol", "diagnostics", "symbol_info", "outline",
			"callers", "implementations", "type_at",
		])
	}
}

@Suite struct ProjectKindTests {
	@Test func detectsSwiftPackage() {
		let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
			.appendingPathComponent("Fixtures/SamplePackage")
		#expect(ProjectKind.detect(in: fixture).isNavigable)
	}

	@Test func emptyDirectoryIsNotNavigable() {
		#expect(!ProjectKind.detect(in: FileManager.default.temporaryDirectory.appendingPathComponent("nonexistent-\(UUID())")).isNavigable)
	}
}

/// Runs against a real sourcekit-lsp; skipped when none is installed.
@Suite(.enabled(if: (try? SourceKitLSPLocator.command()) != nil))
struct IntegrationTests {
	static let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
		.appendingPathComponent("Fixtures/SamplePackage")

	@Test func navigatesFixturePackage() async {
		var environment = ProcessInfo.processInfo.environment
		environment["CODENAV_SWIFT_WORKSPACE"] = Self.fixture.path
		let navigator = SwiftNavigator(environment: environment, currentDirectory: Self.fixture)
		let info = await navigator.symbolInfo(name: "UserService.create", query: nil, filePath: nil)
		#expect(info.contains("create(name:)"))
		#expect(info.contains("UserServiceTests.swift"))
		let impls = await navigator.implementations(name: "UserStore", query: nil, portName: nil, filePath: nil)
		#expect(impls.contains("InMemoryUserStore"))
		#expect(impls.contains("FakeStore"))
		let ambiguous = await navigator.symbolInfo(name: "greet", query: nil, filePath: nil)
		#expect(ambiguous.contains("match 'greet'"))
		#expect(ambiguous.isError)
		#expect(!info.isError)
	}

	@Test func resolvesByPositionAndTextOnLine() async {
		var environment = ProcessInfo.processInfo.environment
		environment["CODENAV_SWIFT_WORKSPACE"] = Self.fixture.path
		let navigator = SwiftNavigator(environment: environment, currentDirectory: Self.fixture)
		let info = await navigator.symbolInfo(
			name: nil, query: nil, filePath: "Sources/SampleApp/main.swift", line: 3, symbol: "UserService", includeReferences: false)
		#expect(info.contains("UserService  [Class]"))
		let type = await navigator.typeAt(filePath: "Sources/SampleApp/main.swift", line: 4, column: nil, symbol: "user")
		#expect(type.contains("struct User"))
		let missing = await navigator.hover(filePath: "Sources/SampleApp/main.swift", line: 4, column: nil, symbol: "nope")
		#expect(missing.isError)
		let sdk = await navigator.symbolInfo(name: "String", query: nil, filePath: nil, includeReferences: false)
		#expect(sdk.contains("[Struct]"))
	}
}

@Suite struct PositionResolverTests {
	@Test func columnOfWholeWordSymbol() throws {
		let text = "let username = user.name\n\tlet user = 1\n"
		#expect(try PositionResolver.column(of: "user", onLine: 1, in: text, filePath: "f.swift") == 16)
		#expect(try PositionResolver.column(of: "user", onLine: 2, in: text, filePath: "f.swift") == 6)
		#expect(throws: ToolInputError.self) { try PositionResolver.column(of: "missing", onLine: 1, in: text, filePath: "f.swift") }
		#expect(throws: ToolInputError.self) { try PositionResolver.column(of: "user", onLine: 9, in: text, filePath: "f.swift") }
	}

	@Test func wordAtColumn() {
		let text = "foo.createUser(name: x)"
		#expect(PositionResolver.word(at: 8, onLine: 1, in: text) == "createUser")
		#expect(PositionResolver.word(at: 15, onLine: 1, in: text) == "createUser")  // just past the end
		#expect(PositionResolver.word(at: 4, onLine: 1, in: text) == "foo")
	}

	@Test func kindFromHover() {
		#expect(PositionResolver.kind(fromHover: "```swift\npublic struct User: Sendable\n```") == SymbolKind.structure)
		#expect(PositionResolver.kind(fromHover: "```swift\nfinal class Box\n```") == SymbolKind.class)
		#expect(PositionResolver.kind(fromHover: "```swift\nclass func make() -> Box\n```") == SymbolKind.function)
		#expect(PositionResolver.kind(fromHover: "```swift\n@MainActor func run()\n```") == SymbolKind.function)
		#expect(PositionResolver.kind(fromHover: "```swift\ntypealias Id = UUID\n```") == 26)
		#expect(PositionResolver.kind(fromHover: "```swift\nprotocol Store\n```") == SymbolKind.protocol)
		#expect(PositionResolver.kind(fromHover: "not a declaration") == nil)
	}
}

@Suite struct ProjectDiscoveryTests {
	@Test func findsNestedPackageAndRefusesPlainFolder() throws {
		let root = FileManager.default.temporaryDirectory.appendingPathComponent("codenav-nested-\(UUID())")
		let package = root.appendingPathComponent("src/App")
		try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
		try "// swift-tools-version: 5.9".write(to: package.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
		defer { try? FileManager.default.removeItem(at: root) }
		#expect(ProjectKind.detect(in: root) == .none)
		#expect(ProjectKind.nestedProjects(in: root).map(\.directory) == ["src/App"])
		#expect(ProjectKind.none.advice(in: root)?.contains("src/App") == true)
	}
}

@Suite struct LocalPackageTests {
	@Test func findsSiblingPackagesFromXcodeProjectAndManifest() throws {
		let base = FileManager.default.temporaryDirectory.appendingPathComponent("codenav-local-\(UUID())")
		let app = base.appendingPathComponent("App")
		let library = base.appendingPathComponent("Lib")
		let xcodeproj = app.appendingPathComponent("App.xcodeproj")
		try FileManager.default.createDirectory(at: xcodeproj, withIntermediateDirectories: true)
		try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
		defer { try? FileManager.default.removeItem(at: base) }
		try """
			/* Begin XCLocalSwiftPackageReference section */
			\t\tABC /* XCLocalSwiftPackageReference "../Lib" */ = {
			\t\t\tisa = XCLocalSwiftPackageReference;
			\t\t\trelativePath = ../Lib;
			\t\t};
			""".write(to: xcodeproj.appendingPathComponent("project.pbxproj"), atomically: true, encoding: .utf8)
		#expect(ProjectKind.localPackageFolders(in: app).map(\.lastPathComponent) == ["Lib"])
		try #".package(path: "../Lib")"#.write(to: app.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
		#expect(ProjectKind.localPackageFolders(in: app).count == 1)  // de-duplicated
	}
}

@Suite struct UsageScanTests {
	@Test func occurrencesAreWholeWordAndSkipCommentsAndImports() throws {
		let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("scan-\(UUID().uuidString)")
		try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
		defer { try? FileManager.default.removeItem(at: dir) }
		try "import Foo\n// Foo here\nlet a = Foo()\nlet b = FooBar()\nFoo.run()\n"
			.write(to: dir.appendingPathComponent("a.swift"), atomically: true, encoding: .utf8)
		let (hits, truncated) = PositionResolver.occurrences(of: "Foo", under: [dir], limit: 10)
		#expect(!truncated)
		#expect(hits.map(\.line) == [3, 5])
	}

	@Test func enclosingFindsCallableAndTypeHeader() {
		let method = SymbolNode(name: "run()", kind: 6, startLine: 4, endLine: 6, selectionLine: 4, selectionColumn: 6, children: [])
		let type = SymbolNode(name: "Box", kind: 23, startLine: 2, endLine: 8, selectionLine: 2, selectionColumn: 7, children: [method])
		#expect(UsageScan.enclosing(line: 6, in: [type])?.name == "Box.run()")
		let header = UsageScan.enclosing(line: 3, in: [type])
		#expect(header?.name == "Box")
		#expect(header?.isHeader == true)
	}

	@Test func dependencySpellingExpandsAgainstCandidates() throws {
		let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("deps-\(UUID().uuidString)")
		let file = dir.appendingPathComponent("Pkg/Sources/A.swift")
		try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
		try "".write(to: file, atomically: true, encoding: .utf8)
		defer { try? FileManager.default.removeItem(at: dir) }
		#expect(DependencyRoots.expand("<dependency> Pkg/Sources/A.swift", extra: [dir.path]) == file.path)
		#expect(DependencyRoots.expand("<dependency> Pkg/Missing.swift", extra: [dir.path]) == "<dependency> Pkg/Missing.swift")
		#expect(DependencyRoots.expand("plain.swift") == "plain.swift")
	}
}
