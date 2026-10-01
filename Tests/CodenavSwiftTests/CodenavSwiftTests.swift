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

@Suite struct ObjectiveCScanTests {
	@Test func swiftMethodsAreSpelledTheObjectiveCWay() {
		#expect(PositionResolver.objcSpellings(ofSwiftName: "increment(by:)") == ["incrementBy", "incrementWithBy"])
		#expect(PositionResolver.objcSpellings(ofSwiftName: "reset()").isEmpty)
		#expect(PositionResolver.objcSpellings(ofSwiftName: "greet(_:)").isEmpty)
	}

	@Test func clangSourcesAreScannedOnlyWhenAsked() throws {
		let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("clang-\(UUID().uuidString)")
		try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
		defer { try? FileManager.default.removeItem(at: dir) }
		try "#import \"Foo.h\"\n[x incrementBy:3];\n".write(to: dir.appendingPathComponent("a.m"), atomically: true, encoding: .utf8)
		#expect(PositionResolver.occurrences(of: "incrementBy", under: [dir], limit: 5).hits.isEmpty)
		let hits = PositionResolver.occurrences(of: "incrementBy", under: [dir], limit: 5, includeClang: true).hits
		#expect(hits.map(\.line) == [2])
	}
}

@Suite struct ScanPrefilterTests {
	@Test func importDetection() {
		#expect(PositionResolver.importsModule("import DIC\n", "DIC"))
		#expect(PositionResolver.importsModule("@testable import DIC\n", "DIC"))
		#expect(PositionResolver.importsModule("  import struct DIC.Box\n", "DIC"))
		#expect(!PositionResolver.importsModule("import DICKit\n", "DIC"))
		#expect(!PositionResolver.importsModule("// import DIC\nlet x = 1\n", "DIC"))
	}

	@Test func moduleFromSourcesLayout() {
		#expect(PositionResolver.moduleName(ofPath: "/a/checkouts/DIC/Sources/DIC/Box.swift") == "DIC")
		#expect(PositionResolver.moduleName(ofPath: "/a/Sources/Main.swift") == nil)
		#expect(PositionResolver.moduleName(ofPath: "/a/App/Box.swift") == nil)
	}

	@Test func scanSkipsFilesThatCannotSeeTheModule() throws {
		let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("prefilter-\(UUID().uuidString)")
		try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
		defer { try? FileManager.default.removeItem(at: dir) }
		try "import Lib\nrun()\n".write(to: dir.appendingPathComponent("a.swift"), atomically: true, encoding: .utf8)
		try "func run() {}\nrun()\n".write(to: dir.appendingPathComponent("b.swift"), atomically: true, encoding: .utf8)
		let all = PositionResolver.occurrences(of: "run", under: [dir], limit: 10).hits
		let filtered = PositionResolver.occurrences(of: "run", under: [dir], limit: 10, requiringImport: "Lib").hits
		#expect(all.count == 3)
		#expect(filtered.map { ($0.path as NSString).lastPathComponent } == ["a.swift"])
	}
}

@Suite struct ObjectiveCAliasTests {
	@Test func swiftNameFromDeclarationLine() {
		#expect(PositionResolver.swiftName(declaredOn: "\tpublic func increment(by amount: Int) {", word: "increment") == "increment(by:)")
		#expect(PositionResolver.swiftName(declaredOn: "func move(_ x: Int, to y: Int)", word: "move") == "move(_:to:)")
		#expect(PositionResolver.swiftName(declaredOn: "func reset()", word: "reset") == "reset()")
		#expect(PositionResolver.swiftName(declaredOn: "let reset = 1", word: "reset") == nil)
	}

	@Test func explicitObjcSelectorWins() {
		let lines = ["\t@objc(bumpCounter:)", "\tfunc increment(by amount: Int) {}"]
		#expect(PositionResolver.objcAliases(declaredAt: 1, in: lines, word: "increment") == ["bumpCounter"])
		#expect(PositionResolver.objcAliases(declaredAt: 0, in: ["func increment(by x: Int) {}"], word: "increment")
			== ["incrementBy", "incrementWithBy"])
	}
}

@Suite struct BuildSettingsHealthTests {
	private func project(buildRoot: String?) throws -> URL {
		let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("health-\(UUID().uuidString)")
		try FileManager.default.createDirectory(at: root.appendingPathComponent("App.xcodeproj"), withIntermediateDirectories: true)
		try "".write(to: root.appendingPathComponent("App.xcodeproj/project.pbxproj"), atomically: true, encoding: .utf8)
		let config = buildRoot.map { "{\"build_root\": \"\($0)\", \"name\": \"xcode build server\"}" } ?? "{}"
		try config.write(to: root.appendingPathComponent("buildServer.json"), atomically: true, encoding: .utf8)
		return root
	}

	@Test func missingBuildRootIsReported() throws {
		let root = try project(buildRoot: "/nonexistent/DerivedData/App-abc")
		defer { try? FileManager.default.removeItem(at: root) }
		let problems = ProjectKind.buildSettingsProblems(in: root)
		#expect(problems.count == 1)
		#expect(problems[0].contains("doesn't exist"))
	}

	@Test func relinkOnlyBuildRootIsReportedAndFullOneIsClean() throws {
		let derived = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("derived-\(UUID().uuidString)")
		let root = try project(buildRoot: derived.path)
		defer {
			try? FileManager.default.removeItem(at: root)
			try? FileManager.default.removeItem(at: derived)
		}
		try FileManager.default.createDirectory(at: derived.appendingPathComponent("Index.noindex/DataStore"), withIntermediateDirectories: true)
		try FileManager.default.createDirectory(at: derived.appendingPathComponent("Build/Intermediates.noindex/App"), withIntermediateDirectories: true)
		let relink = ProjectKind.buildSettingsProblems(in: root)
		#expect(relink.count == 1)
		#expect(relink[0].contains("relink-only"))
		try "".write(
			to: derived.appendingPathComponent("Build/Intermediates.noindex/App/App.SwiftFileList"), atomically: true, encoding: .utf8)
		#expect(ProjectKind.buildSettingsProblems(in: root).isEmpty)
	}

	@Test func swiftPackagesAndForeignConfigsAreNotChecked() throws {
		let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
			.appendingPathComponent("Fixtures/SamplePackage")
		#expect(ProjectKind.buildSettingsProblems(in: fixture).isEmpty)
		let root = try project(buildRoot: nil)
		defer { try? FileManager.default.removeItem(at: root) }
		#expect(ProjectKind.buildSettingsProblems(in: root).isEmpty)  // no build_root: not an xcode-build-server file
	}
}

/// A SwiftPM package with an Objective-C target and a Swift caller, through the real language server.
@Suite(.enabled(if: (try? SourceKitLSPLocator.command()) != nil))
struct MixedLanguageIntegrationTests {
	static let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
		.appendingPathComponent("Fixtures/MixedPackage")

	private func navigator() -> SwiftNavigator {
		var environment = ProcessInfo.processInfo.environment
		environment["CODENAV_SWIFT_WORKSPACE"] = Self.fixture.path
		return SwiftNavigator(environment: environment, currentDirectory: Self.fixture)
	}

	@Test func objectiveCSymbolsAreNavigableFromSwiftAndBack() async {
		let navigator = navigator()
		let outline = await navigator.outline(filePath: "Sources/Bridge/Counter.m")
		#expect(outline.contains("-incrementBy:"))
		// A Swift spelling finds the Objective-C selector.
		let callers = await navigator.callers(name: "Counter.increment(by:)", query: nil, filePath: nil)
		#expect(callers.contains("bump(_:)"))
		#expect(callers.contains("Doubler"))
		let impls = await navigator.implementations(name: "Resettable", query: nil, portName: nil, filePath: nil)
		#expect(impls.contains("Doubler"))
		let definition = await navigator.definition(filePath: "Sources/App/main.swift", line: 4, column: nil, symbol: "increment")
		#expect(definition.contains("incrementBy:"))
	}

	@Test func referencesAcceptAName() async {
		let navigator = navigator()
		let byName = await navigator.references(name: "Counter", filePath: nil)
		#expect(byName.contains("Sources/App/main.swift"))
		#expect(byName.contains("Doubler.m"))
		let noTarget = await navigator.references(filePath: nil)
		#expect(noTarget.isError)
	}

	@Test func searchScopeIsValidated() async {
		let navigator = navigator()
		let project = await navigator.searchSymbol(query: "Counter", name: nil, kind: nil, path: nil, scope: "project")
		#expect(project.contains("Counter.h"))
		let bad = await navigator.searchSymbol(query: "Counter", name: nil, kind: nil, path: nil, scope: "nope")
		#expect(bad.isError)
	}
}
