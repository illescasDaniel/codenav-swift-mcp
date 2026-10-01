import Foundation
import NavShared

/// Finds the `sourcekit-lsp` executable to launch.
///
/// Order: an explicit `CODENAV_SWIFT_LSP`; then the active toolchain (`xcrun --find`, which honours
/// `xcode-select`, `DEVELOPER_DIR` and `TOOLCHAINS`, so it matches the compiler the project is built
/// with); then `PATH`; then well-known install locations (swift.org toolchains, swiftly).
public enum SourceKitLSPLocator {
	public static let environmentKey = "CODENAV_SWIFT_LSP"
	public static let argumentsKey = "CODENAV_SWIFT_LSP_ARGS"

	public static func command(environment: [String: String] = ProcessInfo.processInfo.environment) throws -> [String] {
		let extraArguments = (environment[argumentsKey] ?? "").split(whereSeparator: \.isWhitespace).map(String.init)
		return [try executable(environment: environment)] + extraArguments
	}

	static func executable(environment: [String: String]) throws -> String {
		let fileManager = FileManager.default
		if let explicit = environment[environmentKey], !explicit.isEmpty {
			let path = (explicit as NSString).expandingTildeInPath
			guard fileManager.isExecutableFile(atPath: path) else {
				throw LanguageServerLaunchError(message: "\(environmentKey)=\(explicit) is not an executable file.")
			}
			return path
		}
		if let viaXcrun = xcrunFind(environment: environment) { return viaXcrun }
		for directory in (environment["PATH"] ?? "").split(separator: ":") {
			let candidate = "\(directory)/sourcekit-lsp"
			if fileManager.isExecutableFile(atPath: candidate) { return candidate }
		}
		let home = environment["HOME"] ?? NSHomeDirectory()
		for candidate in [
			"/usr/local/bin/sourcekit-lsp",
			"/opt/homebrew/bin/sourcekit-lsp",
			"/usr/bin/sourcekit-lsp",
			"/Library/Developer/Toolchains/swift-latest.xctoolchain/usr/bin/sourcekit-lsp",
			"\(home)/.swiftly/bin/sourcekit-lsp",
		] where fileManager.isExecutableFile(atPath: candidate) {
			return candidate
		}
		throw LanguageServerLaunchError(
			message:
				"sourcekit-lsp not found. It ships with Xcode and with Swift toolchains from swift.org; install one, or set \(environmentKey) to its path."
		)
	}

	private static func xcrunFind(environment: [String: String]) -> String? {
		guard FileManager.default.isExecutableFile(atPath: "/usr/bin/xcrun") else { return nil }
		let process = Process()
		process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
		process.arguments = ["--find", "sourcekit-lsp"]
		process.environment = environment
		let pipe = Pipe()
		process.standardOutput = pipe
		process.standardError = FileHandle.nullDevice
		do { try process.run() } catch { return nil }
		let data = pipe.fileHandleForReading.readDataToEndOfFile()
		process.waitUntilExit()
		guard process.terminationStatus == 0,
			let path = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines), !path.isEmpty
		else { return nil }
		return path
	}
}
