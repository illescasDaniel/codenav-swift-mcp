import Foundation

// Path canonicalization shared by workspace selection, the LSP client and result formatting.
//
// Foundation's `resolvingSymlinksInPath()` silently drops a leading `/private`, so `/private/tmp/x`
// becomes `/tmp/x`. sourcekit-lsp reports real paths (`/private/tmp/x`): comparing the two never
// matches, which broke relative paths, `path` filters and `file_path` disambiguation for any
// workspace under a symlink (/tmp, /var, ...). Everything here uses `realpath(3)` instead.

extension URL {
	/// The file URL with every symlink resolved the way the kernel does (`realpath`), falling back to
	/// the standardized URL when the path doesn't exist.
	public var realPath: URL {
		let standardized = standardizedFileURL
		guard isFileURL else { return standardized }
		return standardized.path.withCString { pointer -> URL in
			guard let resolved = realpath(pointer, nil) else { return standardized }
			defer { free(resolved) }
			let real = String(cString: resolved)
			// Ask the filesystem rather than trusting the input URL's flag: a URL parsed from a
			// `file://` string has no trailing slash, and as a "file" it would make relative
			// paths resolve against its parent directory.
			var isDirectory: ObjCBool = false
			FileManager.default.fileExists(atPath: real, isDirectory: &isDirectory)
			return URL(fileURLWithPath: real, isDirectory: isDirectory.boolValue)
		}
	}
}

/// Every spelling of `root`'s path worth trying when stripping it from a result path: the path as
/// given, its real path, and both with/without the `/private` prefix macOS adds to /tmp, /var, /etc.
func rootSpellings(_ root: URL) -> [String] {
	var spellings: [String] = []
	func add(_ path: String) {
		let normalized = path.hasSuffix("/") ? path : path + "/"
		if !spellings.contains(normalized) { spellings.append(normalized) }
	}
	for path in [root.path, root.realPath.path] {
		add(path)
		if path.hasPrefix("/private/") { add(String(path.dropFirst("/private".count))) } else { add("/private" + path) }
	}
	return spellings
}

/// `path` relative to `root`, or nil when it is not inside it.
public func relativePath(_ path: String, in root: URL) -> String? {
	for prefix in rootSpellings(root) where path.hasPrefix(prefix) {
		return String(path.dropFirst(prefix.count))
	}
	return nil
}

/// How a file outside the workspace is shown. A sibling checkout or a local package a couple of
/// levels up (`../Octopus/Sources/...`) is far easier to read, and to pass back as `file_path`,
/// than a long absolute path; anything further away stays absolute.
public func displayPathOutside(_ path: String, root: URL) -> String {
	let rootComponents = root.realPath.pathComponents
	let components = URL(fileURLWithPath: path).pathComponents
	var common = 0
	while common < min(rootComponents.count, components.count), rootComponents[common] == components[common] { common += 1 }
	let up = rootComponents.count - common
	// Sharing only `/` or `/Users` says nothing about the two being related.
	guard common >= 3, up >= 1, up <= 2 else { return path }
	return (Array(repeating: "..", count: up) + components[common...]).joined(separator: "/")
}

/// The canonical file URL for a path as an agent writes it: relative to `root` or absolute, symlinks
/// resolved the way the kernel does. A file that doesn't exist yet resolves its directory instead, so a
/// proposed new file gets the same URL it will have once written.
public func canonicalFileURL(_ filePath: String, relativeTo root: URL) -> URL {
	let url = URL(fileURLWithPath: filePath, relativeTo: root).standardizedFileURL
	if FileManager.default.fileExists(atPath: url.path) { return url.realPath }
	return url.deletingLastPathComponent().realPath.appendingPathComponent(url.lastPathComponent)
}
