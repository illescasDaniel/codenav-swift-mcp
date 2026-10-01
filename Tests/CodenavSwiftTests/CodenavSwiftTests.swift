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
			"callers", "implementations",
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
	}
}
