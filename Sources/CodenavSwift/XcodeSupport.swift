import Foundation
import NavShared

// Xcode projects have no `swift package describe`, but the build that xcode-build-server points at leaves
// enough behind to answer the same two questions: which module does a file belong to, and how do I build
// the scheme from here.

/// What `buildServer.json` and the project folder say about how to build an Xcode scheme.
struct XcodeBuild: Sendable, Equatable {
	var scheme: String
	var buildRoot: String
	/// `-workspace X` or `-project X`.
	var containerFlag: String
	var container: String
	var configuration: String
	var destination: String

	static func detect(in root: URL) -> XcodeBuild? {
		guard !FileManager.default.fileExists(atPath: root.appendingPathComponent("Package.swift").path),
			let data = try? Data(contentsOf: root.appendingPathComponent("buildServer.json")),
			let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
			let buildRoot = json["build_root"] as? String, let scheme = json["scheme"] as? String
		else { return nil }
		guard let (flag, container) = containerFromBuildServer(json["workspace"] as? String, root: root) ?? containerInFolder(root)
		else { return nil }
		// The build products folder says which configuration and SDK the index was built for
		// (`Debug-iphonesimulator`); building for another would not refresh what the index reads.
		let products = ((try? FileManager.default.contentsOfDirectory(atPath: buildRoot + "/Build/Products")) ?? []).sorted()
		let folder = products.first { $0.contains("-") } ?? products.first
		var configuration = "Debug"
		var destination = "generic/platform=iOS Simulator"
		if let folder {
			if let dash = folder.firstIndex(of: "-") {
				configuration = String(folder[..<dash])
				let sdk = String(folder[folder.index(after: dash)...])
				destination = Self.destination(forSDK: sdk)
			} else {
				configuration = folder
				destination = "platform=macOS"
			}
		}
		return XcodeBuild(
			scheme: scheme, buildRoot: buildRoot, containerFlag: flag, container: container, configuration: configuration,
			destination: destination)
	}

	/// The project or workspace `buildServer.json` names (`workspace` may be an `.xcodeproj`'s inner
	/// `project.xcworkspace`, and the project may live in a subfolder of the repository).
	static func containerFromBuildServer(_ path: String?, root: URL) -> (String, String)? {
		guard var path, !path.isEmpty else { return nil }
		if !path.hasPrefix("/") { path = root.appendingPathComponent(path).path }
		if path.hasSuffix(".xcodeproj/project.xcworkspace") { path = (path as NSString).deletingLastPathComponent }
		guard FileManager.default.fileExists(atPath: path) else { return nil }
		return (path.hasSuffix(".xcworkspace") ? "-workspace" : "-project", path)
	}

	/// Fallback: the first workspace (else project) in the folder itself.
	static func containerInFolder(_ root: URL) -> (String, String)? {
		let entries = ((try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []).sorted()
		if let workspace = entries.first(where: { $0.hasSuffix(".xcworkspace") }) { return ("-workspace", workspace) }
		if let project = entries.first(where: { $0.hasSuffix(".xcodeproj") }) { return ("-project", project) }
		return nil
	}

	static func destination(forSDK sdk: String) -> String {
		switch sdk {
		case "iphoneos": return "generic/platform=iOS"
		case "iphonesimulator": return "generic/platform=iOS Simulator"
		case "appletvos": return "generic/platform=tvOS"
		case "appletvsimulator": return "generic/platform=tvOS Simulator"
		case "watchos": return "generic/platform=watchOS"
		case "watchsimulator": return "generic/platform=watchOS Simulator"
		case "xros": return "generic/platform=visionOS"
		case "xrsimulator": return "generic/platform=visionOS Simulator"
		default: return "generic/platform=iOS Simulator"
		}
	}

	/// Tests need a concrete platform: `generic/platform=iOS Simulator` builds, but can't run anything.
	var testDestination: String {
		guard destination.hasPrefix("generic/platform=") else { return destination }
		var platform = String(destination.dropFirst("generic/platform=".count))
		if platform == "iOS" || platform == "tvOS" || platform == "watchOS" || platform == "visionOS" { platform += " Simulator" }
		return "platform=" + platform
	}

	/// A concrete destination from `xcodebuild -showdestinations`: the newest OS, an iPhone before other devices.
	/// Nil when the listing has none for this platform (a partial `platform=…` spec is the fallback).
	static func pickDestination(fromListing listing: String, platform: String) -> String? {
		struct Candidate { var id: String; var os: [Int]; var name: String }
		var candidates: [Candidate] = []
		for line in listing.components(separatedBy: "\n") {
			if line.contains("Ineligible destinations") { break }
			guard line.contains("{"), line.contains("platform:\(platform),") || line.contains("platform:\(platform) ") else { continue }
			func field(_ key: String) -> String? {
				guard let range = line.range(of: key + ":") else { return nil }
				let rest = line[range.upperBound...]
				let end = rest.firstIndex(where: { $0 == "," || $0 == "}" }) ?? rest.endIndex
				return rest[..<end].trimmingCharacters(in: .whitespaces)
			}
			guard let id = field("id"), !id.contains("placeholder"), let name = field("name") else { continue }
			candidates.append(Candidate(id: id, os: (field("OS") ?? "").split(separator: ".").compactMap { Int($0) }, name: name))
		}
		let best = candidates.max { a, b in
			let (aPhone, bPhone) = (a.name.hasPrefix("iPhone"), b.name.hasPrefix("iPhone"))
			if aPhone != bPhone { return !aPhone }
			if a.os != b.os { return a.os.lexicographicallyPrecedes(b.os) }
			return a.name > b.name
		}
		return best.map { "id=" + $0.id }
	}

	/// Runs the tests of the products `build-for-testing` just made. `filter` is an `-only-testing` identifier
	/// (`Target`, `Target/Class` or `Target/Class/method`); `destination` replaces the generic one.
	func testArguments(filter: String?, destination concrete: String? = nil) -> [String] {
		var result = arguments(action: "test-without-building")
		if let index = result.firstIndex(of: "-destination") { result[index + 1] = concrete ?? testDestination }
		result.removeAll { $0 == "-quiet" }
		if let filter, !filter.isEmpty { result.append("-only-testing:" + filter) }
		return result
	}

	func arguments(action: String) -> [String] {
		[
			action, containerFlag, container, "-scheme", scheme, "-configuration", configuration, "-destination", destination,
			"-derivedDataPath", buildRoot, "-skipPackagePluginValidation", "-skipMacroValidation", "-quiet",
		]
	}
}

/// Which module each source file compiles into, read from the build the build server points at: Xcode
/// leaves a `<Module>.SwiftFileList` next to each target's object files.
struct XcodeModules: Sendable {
	private(set) var moduleByFile: [String: String] = [:]

	var isEmpty: Bool { moduleByFile.isEmpty }

	static func load(buildRoot: String) -> XcodeModules {
		var result = XcodeModules()
		let fileManager = FileManager.default
		// The normal build wins over the indexing build, which is the only place test targets show up.
		for intermediates in ["/Index.noindex/Build/Intermediates.noindex", "/Build/Intermediates.noindex"] {
			guard let enumerator = fileManager.enumerator(atPath: buildRoot + intermediates) else { continue }
			for case let entry as String in enumerator where entry.hasSuffix(".SwiftFileList") {
				let module = ((entry as NSString).lastPathComponent as NSString).deletingPathExtension
				guard let text = try? String(contentsOfFile: buildRoot + intermediates + "/" + entry, encoding: .utf8) else { continue }
				for line in text.split(separator: "\n") {
					let path = line.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "\"", with: "")
					if path.hasPrefix("/") {
						result.moduleByFile[URL(fileURLWithPath: path).standardizedFileURL.path] = module
					}
				}
			}
		}
		return result
	}

	func files(inModule name: String) -> [String] {
		// The normal and the indexing build each generate the same files (GeneratedAssetSymbols.swift…): one copy only.
		var generated: Set<String> = []
		return moduleByFile.filter { $0.value == name }.map(\.key).sorted { !$0.contains("/Index.noindex/") && $1.contains("/Index.noindex/") || $0 < $1 && $0.contains("/Index.noindex/") == $1.contains("/Index.noindex/") }
			.filter { path in !path.contains("/DerivedSources/") || generated.insert((path as NSString).lastPathComponent).inserted }
	}

	func module(ofPath path: String) -> String? {
		moduleByFile[path] ?? moduleByFile[URL(fileURLWithPath: path).resolvingSymlinksInPath().path]
	}
}

extension BuildRunner {
	static func runXcode(_ build: XcodeBuild, xcodebuild: String, root: URL, environment: [String: String], timeout: TimeInterval) async -> BuildResult {
		// xcode-build-server takes compile arguments from the newest build log. A build of ours that finds
		// everything up to date leaves a log with no Swift compilation, which would make the next language
		// server session fall back to bogus arguments; those logs (and only the ones this run created) go.
		let logs = build.buildRoot + "/Logs/Build"
		let logsBefore = Set(logFiles(in: logs))
		defer {
			for name in Set(logFiles(in: logs)).subtracting(logsBefore) where !ProjectKind.logRecordsSwiftCompilation(atPath: logs + "/" + name) {
				try? FileManager.default.removeItem(atPath: logs + "/" + name)
			}
		}
		var action = "build-for-testing"
		var output = await ToolProcess.run(xcodebuild, arguments: build.arguments(action: action), directory: root, environment: environment, timeout: timeout)
		// A scheme without a test action can't build for testing.
		if output.status != 0, output.combined.contains("not currently configured for the test action") {
			action = "build"
			output = await ToolProcess.run(xcodebuild, arguments: build.arguments(action: action), directory: root, environment: environment, timeout: timeout)
		}
		let diagnostics = parse(output.combined)
		let tail = output.combined.components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.suffix(6)
			.joined(separator: "\n")
		return BuildResult(
			command: "xcodebuild \(action) -scheme \(build.scheme)", status: output.status, timedOut: output.timedOut,
			seconds: output.seconds, errors: diagnostics.filter { $0.severity == "error" },
			warnings: diagnostics.filter { $0.severity == "warning" }.count, tail: tail)
	}
}

extension BuildRunner {
	fileprivate static func logFiles(in directory: String) -> [String] {
		((try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? []).filter { $0.hasSuffix(".xcactivitylog") }
	}
}

extension SwiftNavigator {
	func xcodeBuild() -> XcodeBuild? {
		projectKind == .buildServer ? XcodeBuild.detect(in: workspaceRoot) : nil
	}

	func xcodebuildExecutable() -> String? {
		FileManager.default.isExecutableFile(atPath: "/usr/bin/xcodebuild") ? "/usr/bin/xcodebuild" : nil
	}

	/// File → module map for an Xcode project, cached until the build root's contents change shape.
	func xcodeModules() -> XcodeModules? {
		guard let build = xcodeBuild() else { return nil }
		if let cache = xcodeModulesCache, cache.buildRoot == build.buildRoot, Date().timeIntervalSince(cache.when) < 30 {
			return cache.modules.isEmpty ? nil : cache.modules
		}
		let modules = XcodeModules.load(buildRoot: build.buildRoot)
		xcodeModulesCache = (build.buildRoot, Date(), modules)
		return modules.isEmpty ? nil : modules
	}
}
