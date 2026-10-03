import Foundation
import NavShared

/// What kind of Swift project the workspace is, which decides whether sourcekit-lsp can know build
/// settings (and so resolve across files) without further setup.
public enum ProjectKind: Equatable, Sendable {
	case swiftPackage
	case buildServer
	case compilationDatabase
	/// An Xcode project/workspace with no `buildServer.json`: sourcekit-lsp can't read `.xcodeproj` itself.
	case xcodeWithoutBuildServer(name: String)
	/// No build description at all: files are analysed standalone, so cross-file results are limited.
	case none

	public static func detect(in root: URL) -> ProjectKind {
		let fileManager = FileManager.default
		func exists(_ name: String) -> Bool { fileManager.fileExists(atPath: root.appendingPathComponent(name).path) }
		if exists("Package.swift") { return .swiftPackage }
		if exists("buildServer.json") { return .buildServer }
		if exists("compile_commands.json") || exists("compile_flags.txt") { return .compilationDatabase }
		let entries = (try? fileManager.contentsOfDirectory(atPath: root.path)) ?? []
		if let xcode = entries.sorted().first(where: { $0.hasSuffix(".xcworkspace") })
			?? entries.sorted().first(where: { $0.hasSuffix(".xcodeproj") })
		{
			return .xcodeWithoutBuildServer(name: xcode)
		}
		return .none
	}

	/// Whether starting the language server eagerly (to begin indexing) is worthwhile.
	public var isNavigable: Bool {
		switch self {
		case .none: return false
		default: return true
		}
	}

	public var summary: String {
		switch self {
		case .swiftPackage: return "Swift package (Package.swift)"
		case .buildServer: return "build server (buildServer.json)"
		case .compilationDatabase: return "compilation database"
		case .xcodeWithoutBuildServer(let name): return "Xcode project (\(name)) without buildServer.json"
		case .none: return "no Package.swift, buildServer.json or compilation database"
		}
	}

	/// A project found below the workspace root (`src/Octopus`: Swift package).
	public struct NestedProject: Sendable, Equatable {
		public var directory: String
		public var description: String
	}

	private static let opaqueDirectorySuffixes = [
		".xcodeproj", ".xcworkspace", ".xcassets", ".xcframework", ".framework", ".app", ".bundle", ".lproj", ".playground",
		".xcstrings", ".xcdatamodeld", ".storekit", ".docc", ".appiconset",
	]

	/// Swift projects up to `maxDepth` levels below `root`: a monorepo keeps its package or Xcode
	/// project in `src/App/`, where nothing at the root says so. Build output, dependency checkouts
	/// and bundles are skipped.
	public static func nestedProjects(in root: URL, maxDepth: Int = 3, limit: Int = 6) -> [NestedProject] {
		let fileManager = FileManager.default
		var found: [NestedProject] = []
		var queue: [(url: URL, depth: Int)] = [(root, 0)]
		while !queue.isEmpty, found.count < limit {
			let (directory, depth) = queue.removeFirst()
			let entries = ((try? fileManager.contentsOfDirectory(atPath: directory.path)) ?? []).sorted()
			if depth > 0 {
				let relative = String(directory.path.dropFirst(root.path.count + 1))
				if entries.contains("Package.swift") {
					found.append(NestedProject(directory: relative, description: "Swift package"))
				} else if let xcode = entries.first(where: { $0.hasSuffix(".xcworkspace") }) ?? entries.first(where: { $0.hasSuffix(".xcodeproj") }) {
					found.append(NestedProject(directory: relative, description: "Xcode project \(xcode)"))
				}
			}
			guard depth < maxDepth else { continue }
			for name in entries where !name.hasPrefix(".") && !Exclude.directoryNames.contains(name) {
				if opaqueDirectorySuffixes.contains(where: name.hasSuffix) { continue }
				let url = directory.appendingPathComponent(name)
				var isDirectory: ObjCBool = false
				if fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue {
					queue.append((url, depth + 1))
				}
			}
		}
		return found
	}

	/// Loose `.swift` files near the root and nothing else: sourcekit-lsp can still analyse them one by one.
	public static func hasLooseSwiftFiles(in root: URL, maxDepth: Int = 2) -> Bool {
		let fileManager = FileManager.default
		var queue: [(url: URL, depth: Int)] = [(root, 0)]
		while !queue.isEmpty {
			let (directory, depth) = queue.removeFirst()
			for name in (try? fileManager.contentsOfDirectory(atPath: directory.path)) ?? [] {
				if name.hasSuffix(".swift") { return true }
				guard depth < maxDepth, !name.hasPrefix("."), !Exclude.directoryNames.contains(name) else { continue }
				queue.append((directory.appendingPathComponent(name), depth + 1))
			}
		}
		return false
	}

	/// The nested projects as a sentence an agent can act on.
	static func nestedAdvice(_ nested: [NestedProject]) -> String {
		guard !nested.isEmpty else { return "" }
		let list = nested.map { "\($0.directory) (\($0.description))" }.joined(separator: "; ")
		return " Projects found below it: \(list). Set CODENAV_SWIFT_WORKSPACE to the one you are working on (an absolute path)"
			+ " or start the MCP client in that directory."
	}

	/// What the agent (or user) should know about limited results, if anything.
	public func advice(in root: URL) -> String? {
		switch self {
		case .xcodeWithoutBuildServer(let name):
			let flag = name.hasSuffix(".xcworkspace") ? "-workspace" : "-project"
			return
				"\(name) has no Package.swift or buildServer.json, so sourcekit-lsp has no build settings and cross-file results will be limited. "
				+ "Generate them once with `xcode-build-server config \(flag) \(name) -scheme <Scheme>` (brew install xcode-build-server), "
				+ "then build that scheme in Xcode so the index store exists."
		case .none:
			return
				"no Package.swift, buildServer.json or compile_commands.json found in \(root.path), so sourcekit-lsp analyses files standalone: "
				+ "cross-file navigation will be limited." + Self.nestedAdvice(Self.nestedProjects(in: root))
				+ (Self.nestedProjects(in: root).isEmpty ? " Point CODENAV_SWIFT_WORKSPACE at the package/project root." : "")
		default:
			return nil
		}
	}

	/// Why an Xcode project's `buildServer.json` may give sourcekit-lsp no usable build settings: the build
	/// root it points at is gone, never compiled any Swift (a relink-only build records nothing), has no index
	/// store, or predates the project's last change. Empty when it looks healthy or the project isn't one.
	public static func buildSettingsProblems(in root: URL) -> [String] {
		outsidePackageProblems(in: root) + buildRootProblems(in: root)
	}

	/// xcode-build-server only advertises the directory holding `buildServer.json` as its source tree, so
	/// sourcekit-lsp gets no build settings for a local package that lives outside it (hover, definition and
	/// references on its declarations come back empty, although the app's own files resolve into it).
	private static func outsidePackageProblems(in root: URL) -> [String] {
		guard !FileManager.default.fileExists(atPath: root.appendingPathComponent("Package.swift").path),
			let data = try? Data(contentsOf: root.appendingPathComponent("buildServer.json")),
			let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
			json["build_root"] is String
		else { return [] }
		let outside = localPackageFolders(in: root)
		guard !outside.isEmpty else { return [] }
		var ancestor = root.realPath.pathComponents
		for package in outside {
			let components = package.pathComponents
			var common = 0
			while common < min(ancestor.count, components.count), ancestor[common] == components[common] { common += 1 }
			ancestor = Array(ancestor[..<common])
		}
		let ancestorURL = URL(fileURLWithPath: NSString.path(withComponents: ancestor), isDirectory: true)
		let entries = ((try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []).sorted()
		let flag = entries.contains { $0.hasSuffix(".xcworkspace") } ? "-workspace" : "-project"
		let name = entries.first { $0.hasSuffix(".xcworkspace") } ?? entries.first { $0.hasSuffix(".xcodeproj") } ?? "<name>"
		func below(_ path: String) -> String {
			let base = ancestorURL.path.hasSuffix("/") ? ancestorURL.path : ancestorURL.path + "/"
			return path.hasPrefix(base) ? String(path.dropFirst(base.count)) : path
		}
		let projectPath = root.realPath.path == ancestorURL.path ? name : below(root.realPath.path) + "/" + name
		let scheme = (json["scheme"] as? String) ?? "<Scheme>"
		let names = outside.map { below($0.path) }
		return [
			"local package(s) \(names.joined(separator: ", ")) are outside \(root.path), the directory holding buildServer.json, "
				+ "so sourcekit-lsp has no build settings for their files (hover, definition and references there come back empty). "
				+ "Move the build server up to a directory that contains them: `cd \(ancestorURL.path) && xcode-build-server config \(flag) \(projectPath) -scheme \(scheme)`, "
				+ "delete \(root.path)/buildServer.json, and set CODENAV_SWIFT_WORKSPACE (or the MCP client's root) to \(ancestorURL.path)."
		]
	}

	static func buildRootProblems(in root: URL) -> [String] {
		let fileManager = FileManager.default
		let configURL = root.appendingPathComponent("buildServer.json")
		guard !fileManager.fileExists(atPath: root.appendingPathComponent("Package.swift").path),
			let data = try? Data(contentsOf: configURL)
		else { return [] }
		guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
			return ["buildServer.json isn't valid JSON; regenerate it with `xcode-build-server config`."]
		}
		guard let buildRoot = json["build_root"] as? String else { return [] }  // not an xcode-build-server file
		let regenerate = "Build the scheme fully in Xcode (or `xcodebuild build`), then regenerate with `xcode-build-server config -project|-workspace <name> -scheme <Scheme>`."
		var isDirectory: ObjCBool = false
		guard fileManager.fileExists(atPath: buildRoot, isDirectory: &isDirectory), isDirectory.boolValue else {
			return ["buildServer.json points at build_root \(buildRoot), which doesn't exist (DerivedData was cleaned or the project moved). " + regenerate]
		}
		var problems: [String] = []
		if !fileManager.fileExists(atPath: buildRoot + "/Index.noindex/DataStore") {
			problems.append("the build root has no index store (Index.noindex/DataStore): references, callers and implementations will be empty until the scheme is built in Xcode.")
		}
		if !hasSwiftCompilation(under: buildRoot + "/Build/Intermediates.noindex") {
			problems.append("no Swift compilation was recorded in the build root, so files get fallback arguments (bogus \"No such module\" errors). A relink-only build leaves nothing: run a full build. " + regenerate)
		}
		let logs = buildRoot + "/Logs/Build"
		let logDates = ((try? fileManager.contentsOfDirectory(atPath: logs)) ?? []).filter { $0.hasSuffix(".xcactivitylog") }
			.compactMap { name -> (path: String, date: Date)? in
				(try? fileManager.attributesOfItem(atPath: logs + "/" + name))?[.modificationDate].flatMap { $0 as? Date }
					.map { (logs + "/" + name, $0) }
			}
		let newestLog = logDates.max { $0.date < $1.date }
		let lastBuild = newestLog?.date
		// xcode-build-server derives compile arguments from the newest build log, so a later build that only relinked
		// (or was up to date) leaves Swift files with fallback arguments although earlier builds compiled them.
		if let newestLog, !logRecordsSwiftCompilation(atPath: newestLog.path) {
			problems.append("the most recent build log has no Swift compilation (the last build only relinked, was up to date, or failed before compiling), so files get fallback arguments (bogus \"No such module\" errors). Touch a Swift file or run `xcodebuild clean build`, then regenerate with `xcode-build-server config -project|-workspace <name> -scheme <Scheme>`.")
		}
		if let lastBuild, let project = projectModificationDate(in: root), project > lastBuild.addingTimeInterval(1) {
			problems.append("the project file changed after the last build (files or targets may have been added since). Rebuild so the build settings cover them.")
		}
		return problems
	}

	/// Whether a gzip-compressed `.xcactivitylog` mentions a Swift compile step. Unreadable logs count as yes so a
	/// format change can't produce a false alarm.
	static func logRecordsSwiftCompilation(atPath path: String) -> Bool {
		let process = Process()
		process.executableURL = URL(fileURLWithPath: "/usr/bin/gzip")
		process.arguments = ["-dc", path]
		let pipe = Pipe()
		process.standardOutput = pipe
		process.standardError = FileHandle.nullDevice
		guard (try? process.run()) != nil else { return true }
		let markers = ["SwiftDriver", "SwiftCompile", "-module-name"].map { Data($0.utf8) }
		let overlap = markers.map(\.count).max() ?? 0
		var found = false
		var tail = Data()
		var sawOutput = false
		while true {
			let chunk = pipe.fileHandleForReading.readData(ofLength: 1 << 20)
			if chunk.isEmpty { break }
			sawOutput = true
			if found { continue }  // keep draining so gzip can exit
			let window = tail + chunk
			if markers.contains(where: { window.range(of: $0) != nil }) { found = true }
			tail = window.suffix(overlap)
		}
		process.waitUntilExit()
		return found || !sawOutput
	}

	private static func hasSwiftCompilation(under directory: String) -> Bool {
		guard let enumerator = FileManager.default.enumerator(atPath: directory) else { return false }
		var visited = 0
		for case let entry as String in enumerator {
			visited += 1
			if visited > 20000 { return true }  // a large tree has certainly compiled something
			if entry.hasSuffix(".SwiftFileList") { return true }
		}
		return false
	}

	private static func projectModificationDate(in root: URL) -> Date? {
		let entries = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
		return entries.filter { $0.hasSuffix(".xcodeproj") }.compactMap { entry in
			(try? FileManager.default.attributesOfItem(atPath: root.path + "/" + entry + "/project.pbxproj"))?[.modificationDate] as? Date
		}.max()
	}

	/// Local packages the project depends on that live outside `root`: `XCLocalSwiftPackageReference`
	/// entries of an Xcode project and `.package(path:)` dependencies of a Package.swift. sourcekit-lsp
	/// only builds a proper index view of directories registered as workspace folders.
	public static func localPackageFolders(in root: URL) -> [URL] {
		let fileManager = FileManager.default
		var relativePaths: [String] = []
		func matches(_ pattern: String, in text: String, group: Int = 1) -> [String] {
			guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
			let range = NSRange(text.startIndex..., in: text)
			return regex.matches(in: text, range: range).compactMap { match in
				Range(match.range(at: group), in: text).map { String(text[$0]) }
			}
		}
		for entry in (try? fileManager.contentsOfDirectory(atPath: root.path)) ?? [] where entry.hasSuffix(".xcodeproj") {
			let file = root.appendingPathComponent(entry).appendingPathComponent("project.pbxproj")
			guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
			relativePaths += matches(#"isa = XCLocalSwiftPackageReference;\s*relativePath = ([^;]+);"#, in: text)
				.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "\" ")) }
		}
		if let manifest = try? String(contentsOf: root.appendingPathComponent("Package.swift"), encoding: .utf8) {
			relativePaths += matches(#"\.package\(\s*(?:name:\s*"[^"]*",\s*)?path:\s*"([^"]+)""#, in: manifest)
		}
		let rootPath = root.realPath.path + "/"
		var seen: Set<String> = []
		return relativePaths.compactMap { relative in
			let url = URL(fileURLWithPath: relative, relativeTo: root.realPath).realPath
			var isDirectory: ObjCBool = false
			guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue,
				!(url.path + "/").hasPrefix(rootPath), seen.insert(url.path).inserted
			else { return nil }
			return url
		}
	}
}
