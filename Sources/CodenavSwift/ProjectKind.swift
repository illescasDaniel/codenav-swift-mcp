import Foundation

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

	/// What the agent (or user) should know about limited results, if anything.
	public var advice: String? {
		switch self {
		case .xcodeWithoutBuildServer(let name):
			let flag = name.hasSuffix(".xcworkspace") ? "-workspace" : "-project"
			return
				"\(name) has no Package.swift or buildServer.json, so sourcekit-lsp has no build settings and cross-file results will be limited. "
				+ "Generate them once with `xcode-build-server config \(flag) \(name) -scheme <Scheme>` (brew install xcode-build-server), "
				+ "then build that scheme in Xcode so the index store exists."
		case .none:
			return
				"no Package.swift, buildServer.json or compile_commands.json found in the workspace, so sourcekit-lsp analyses files standalone: "
				+ "cross-file navigation will be limited. Point CODENAV_SWIFT_WORKSPACE at the package/project root."
		default:
			return nil
		}
	}
}
