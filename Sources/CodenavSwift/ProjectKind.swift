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
}
