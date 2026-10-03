import Foundation
import Testing

@testable import CodenavSwift
@testable import NavShared

@Suite struct XcodeSupportTests {
	private func temporaryFolder() throws -> URL {
		let url = FileManager.default.temporaryDirectory.appendingPathComponent("codenav-xcode-\(UUID().uuidString)")
		try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
		return url
	}

	@Test func moduleMapComesFromTheSwiftFileLists() throws {
		let root = try temporaryFolder()
		defer { try? FileManager.default.removeItem(at: root) }
		let objects = root.appendingPathComponent("Build/Intermediates.noindex/App.build/Debug-iphonesimulator/App.build/Objects-normal/arm64")
		try FileManager.default.createDirectory(at: objects, withIntermediateDirectories: true)
		try "/work/App/A.swift\n\"/work/App/B.swift\"\n".write(to: objects.appendingPathComponent("App.SwiftFileList"), atomically: true, encoding: .utf8)
		let modules = XcodeModules.load(buildRoot: root.path)
		#expect(modules.module(ofPath: "/work/App/A.swift") == "App")
		#expect(modules.module(ofPath: "/work/App/B.swift") == "App")
		#expect(modules.module(ofPath: "/work/Other.swift") == nil)
	}

	@Test func buildSettingsComeFromBuildServerJSON() throws {
		let root = try temporaryFolder()
		defer { try? FileManager.default.removeItem(at: root) }
		let buildRoot = root.appendingPathComponent("DD")
		try FileManager.default.createDirectory(at: buildRoot.appendingPathComponent("Build/Products/Debug-iphonesimulator"), withIntermediateDirectories: true)
		try FileManager.default.createDirectory(at: root.appendingPathComponent("App.xcodeproj"), withIntermediateDirectories: true)
		let json = "{\"build_root\": \"\(buildRoot.path)\", \"scheme\": \"App\", \"kind\": \"xcode\"}"
		try json.write(to: root.appendingPathComponent("buildServer.json"), atomically: true, encoding: .utf8)
		let build = try #require(XcodeBuild.detect(in: root))
		#expect(build.scheme == "App")
		#expect(build.containerFlag == "-project")
		#expect(build.configuration == "Debug")
		#expect(build.destination == "generic/platform=iOS Simulator")
		#expect(build.arguments(action: "build").contains(buildRoot.path))
	}

	@Test func testsRunOnAConcretePlatformAndCanBeNarrowed() {
		let build = XcodeBuild(scheme: "App", buildRoot: "/dd", containerFlag: "-project", container: "App.xcodeproj", configuration: "Debug", destination: "generic/platform=iOS Simulator")
		let all = build.testArguments(filter: nil)
		#expect(all.first == "test-without-building")
		#expect(all.contains("platform=iOS Simulator"))
		#expect(!all.contains("-quiet"))
		#expect(build.testArguments(filter: "AppTests/Foo/testBar").last == "-only-testing:AppTests/Foo/testBar")
		var device = build
		device.destination = "generic/platform=iOS"
		#expect(device.testDestination == "platform=iOS Simulator")
		device.destination = "platform=macOS"
		#expect(device.testDestination == "platform=macOS")
	}

	@Test func theNewestIPhoneSimulatorIsPickedFromTheListing() {
		let listing = """
			Available destinations for the "App" scheme:
				{ platform:iOS, arch:arm64, id:dvtdevice-DVTiPhonePlaceholder-iphoneos:placeholder, name:Any iOS Device }
				{ platform:iOS Simulator, arch:arm64, id:AAA, OS:18.6, name:iPhone 16 }
				{ platform:iOS Simulator, arch:arm64, id:BBB, OS:27.0, name:iPad Air 11-inch (M4) }
				{ platform:iOS Simulator, arch:arm64, id:CCC, OS:26.5, name:iPhone 17 }
				{ platform:iOS Simulator, arch:arm64, id:DDD, OS:27.0, name:iPhone 17 }
				{ platform:macOS, arch:arm64, id:EEE, name:My Mac }
			Ineligible destinations for the "App" scheme:
				{ platform:iOS Simulator, arch:arm64, id:ZZZ, OS:99.0, name:iPhone 99 }
			"""
		#expect(XcodeBuild.pickDestination(fromListing: listing, platform: "iOS Simulator") == "id=DDD")
		#expect(XcodeBuild.pickDestination(fromListing: listing, platform: "tvOS Simulator") == nil)
	}

	@Test func aPackageIsNotAnXcodeBuild() throws {
		let root = try temporaryFolder()
		defer { try? FileManager.default.removeItem(at: root) }
		try "// swift-tools-version: 5.9".write(to: root.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
		try "{\"build_root\": \"/x\", \"scheme\": \"S\"}".write(to: root.appendingPathComponent("buildServer.json"), atomically: true, encoding: .utf8)
		#expect(XcodeBuild.detect(in: root) == nil)
	}

	@Test func layoutNamesAreReducedToTheModuleName() {
		#expect(EditEngine.bareModuleName("Sources/Core") == "Core")
		#expect(EditEngine.bareModuleName("Tests/CoreTests") == "CoreTests")
		#expect(EditEngine.bareModuleName("GamesLibrary") == "GamesLibrary")
	}

	@Test func mentionsAreListedPerFile() {
		let mentions = [
			SwiftNavigator.Mention(path: "A.swift", line: 1), SwiftNavigator.Mention(path: "A.swift", line: 2),
			SwiftNavigator.Mention(path: "B.swift", line: 9),
		]
		#expect(SwiftNavigator.perFile(mentions) == "A.swift (2: L1, L2), B.swift (1: L9)")
	}

	@Test func anOperationKeyItDoesNotReadIsRefused() throws {
		let add: JSONValue = .object(["op": .string("add"), "param": .string("x: Int"), "default": .string("1")])
		let arguments = ToolArguments(["name": .string("f()"), "operations": .array([add])])
		#expect(throws: ToolInputError.self) { _ = try SwiftNavigator.signatureOperations(arguments) }
		let fine: JSONValue = .object(["op": .string("add"), "param": .string("x: Int = 1")])
		_ = try SwiftNavigator.signatureOperations(ToolArguments(["operations": .array([fine])]))
	}

	@Test func theContainerComesFromTheWorkspaceBuildServerNames() throws {
		let root = try temporaryFolder()
		defer { try? FileManager.default.removeItem(at: root) }
		let buildRoot = root.appendingPathComponent("DD")
		try FileManager.default.createDirectory(at: buildRoot.appendingPathComponent("Build/Products/Debug-iphonesimulator"), withIntermediateDirectories: true)
		let project = root.appendingPathComponent("src/App/App.xcodeproj")
		try FileManager.default.createDirectory(at: project.appendingPathComponent("project.xcworkspace"), withIntermediateDirectories: true)
		let json = "{\"build_root\": \"\(buildRoot.path)\", \"scheme\": \"App\", \"workspace\": \"\(project.path)/project.xcworkspace\"}"
		try json.write(to: root.appendingPathComponent("buildServer.json"), atomically: true, encoding: .utf8)
		let build = try #require(XcodeBuild.detect(in: root))
		#expect(build.containerFlag == "-project")
		#expect(build.container == project.path)
	}

	@Test func swiftcGetsTheSDKOfTheDestination() {
		#expect(SwiftNavigator.sdkName(forDestination: "generic/platform=iOS Simulator") == "iphonesimulator")
		#expect(SwiftNavigator.sdkName(forDestination: "platform=macOS") == "macosx")
		#expect(SwiftNavigator.targetTriple(sdk: "iphonesimulator", majorVersion: "26") == "arm64-apple-ios26.0-simulator")
		#expect(SwiftNavigator.targetTriple(sdk: "macosx", majorVersion: "27") == nil)
	}

	@Test func aRenameToAnEmptyLabelListIsTheSameAsTheBareName() throws {
		let requested = try RenameName.parse("reload()")
		#expect(try requested.full(replacing: ParsedQuery("loadData")) == "reload")
	}

	@Test func generatedCallersAreNamedAfterWhatTheyComeFromAndFolded() {
		func call(_ name: String, kind: Int, line: Int) -> IncomingCall {
			let range = LSPRange(start: LSPPosition(line: line, character: 0), end: LSPPosition(line: line, character: 1))
			let item = HierarchyItem(name: name, kind: kind, uri: "file:///w/A.swift", range: range, selectionRange: range)
			return IncomingCall(from: item, fromRanges: [range])
		}
		let text = formatCallers(
			[
				call("$s6Planes0024ViewswiftPreviewfMf_15PreviewRegistryfMu_.makePreview()", kind: 6, line: 77),
				call("App.$model", kind: 7, line: 13), call("App.model", kind: 7, line: 13),
			], workspaceRoot: URL(fileURLWithPath: "/w"))
		#expect(text.contains("#Preview"))
		#expect(!text.contains("$s6Planes"))
		#expect(text.components(separatedBy: "\n").count == 2)
		#expect(text.contains("App.model"))
	}
}
