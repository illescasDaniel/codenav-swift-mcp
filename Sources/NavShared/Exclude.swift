import Foundation

/// Directory names every workspace walk skips: vendored/generated/build-output trees
/// that are never a project's own source, so scanning them wastes time (and, for
/// the file-change watcher, would report thousands of irrelevant events).
public enum Exclude {
	public static let directoryNames: Set<String> = [
		// SwiftPM / Xcode build output and dependency checkouts
		".build", ".swiftpm", "DerivedData", "SourcePackages", "xcuserdata",
		// Other package managers
		"Pods", "Carthage", "node_modules", "vendor",
		// Generic
		".git", "dist", "build", ".venv", "venv", "__pycache__", ".idea", ".vscode",
	]

	/// Whether `url` sits under an excluded directory name anywhere below `root`.
	public static func isExcluded(_ url: URL, root: URL) -> Bool {
		let rootComponents = root.standardizedFileURL.pathComponents
		let components = url.standardizedFileURL.pathComponents
		let relative = components.starts(with: rootComponents) ? Array(components.dropFirst(rootComponents.count)) : components
		return !directoryNames.isDisjoint(with: relative)
	}
}
