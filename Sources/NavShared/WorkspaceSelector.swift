import Foundation

/// Resolves which directory a navigation server operates on.
///
/// Hosts may spawn stdio MCP processes with a working directory that is not the repo (e.g.
/// Cursor using $HOME). Prefer an explicit override, then Claude Code's injected project dir,
/// then the process's working directory: never a path baked into this binary's install
/// location, since that would silently point every un-configured host at the wrong tree.
public struct WorkspaceSelection: Sendable, Equatable {
	public var root: URL
	public var source: String
}

public final class WorkspaceSelector: Sendable {
	public let explicitEnv: String
	public let base: URL
	public let baseSource: String
	public let pinned: Bool

	public init(
		explicitEnv: String,
		environment: [String: String] = ProcessInfo.processInfo.environment,
		currentDirectory: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
	) {
		self.explicitEnv = explicitEnv
		self.pinned = !(environment[explicitEnv] ?? "").isEmpty
		var chosen: (URL, String)?
		for key in [explicitEnv, "CLAUDE_PROJECT_DIR"] {
			if let raw = environment[key], !raw.isEmpty {
				chosen = (Self.canonical(URL(fileURLWithPath: (raw as NSString).expandingTildeInPath)), key)
				break
			}
		}
		(base, baseSource) = chosen ?? (Self.canonical(currentDirectory), "cwd")
	}

	static func canonical(_ url: URL) -> URL {
		url.realPath
	}

	/// One sentence an agent can act on for a `WorkspaceSelection.source` value.
	public func explain(_ source: String) -> String {
		if source == "client roots" {
			return "client roots (the MCP client reported this checkout/worktree of the same repository as the configured base \(base.path))"
		}
		if source == Self.rootsBecauseNoProjectSource {
			return "client roots (the server's working directory \(base.path) is not a Swift project, so the MCP client's workspace root was used instead)"
		}
		if source == explicitEnv { return "pinned by $\(explicitEnv); client roots are ignored" }
		if source == "CLAUDE_PROJECT_DIR" {
			return "$CLAUDE_PROJECT_DIR (default; the client has not reported another checkout/worktree of this repository)"
		}
		return "server working directory ($\(explicitEnv) and $CLAUDE_PROJECT_DIR are unset)"
	}

	static let rootsBecauseNoProjectSource = "client roots (cwd is not a project)"

	/// Order of authority: the pinned env var (never overridden); then the client's MCP roots, first
	/// one that is the configured base or another worktree/checkout of the same git repository;
	/// then the configured base. A session in some unrelated project must never redirect the server.
	///
	/// The one exception: when the configured base is not a project at all (a host that launches
	/// stdio servers in `$HOME`, say), there is nothing to protect and navigating it would index the
	/// wrong tree, so the client's own roots win, preferring one that is a project.
	public func select(clientRootURIs: [String], isProject: (URL) -> Bool = { _ in true }) -> WorkspaceSelection {
		if pinned { return WorkspaceSelection(root: base, source: baseSource) }
		let roots = Self.rootPaths(clientRootURIs)
		for root in roots where Self.sameRepository(root, base) {
			return WorkspaceSelection(root: root, source: "client roots")
		}
		if !isProject(base), let root = roots.first(where: isProject) ?? roots.first(where: { !Self.isHomeOrRoot($0) }) {
			return WorkspaceSelection(root: root, source: Self.rootsBecauseNoProjectSource)
		}
		return WorkspaceSelection(root: base, source: baseSource)
	}

	/// `/` or the user's home: never a workspace worth handing to a language server.
	public static func isHomeOrRoot(_ url: URL) -> Bool {
		let path = url.realPath.path
		return path == "/" || path == NSHomeDirectory() || path == URL(fileURLWithPath: NSHomeDirectory()).realPath.path
	}

	static func rootPaths(_ uris: [String]) -> [URL] {
		uris.compactMap { uri in
			guard let url = URL(string: uri), url.isFileURL else { return nil }
			return canonical(url)
		}
	}

	private static let commonDirCache = Cache()

	private final class Cache: @unchecked Sendable {
		private let lock = NSLock()
		private var values: [URL: URL?] = [:]

		func value(for key: URL, compute: () -> URL?) -> URL? {
			lock.lock()
			if let hit = values[key] {
				lock.unlock()
				return hit
			}
			lock.unlock()
			let computed = compute()
			lock.lock()
			values[key] = computed
			lock.unlock()
			return computed
		}
	}

	/// The repository's shared `.git` directory for `path` (identical for a checkout and all its
	/// linked worktrees), or nil outside a git repo.
	static func gitCommonDirectory(_ path: URL) -> URL? {
		commonDirCache.value(for: path) {
			let process = Process()
			process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
			process.arguments = ["git", "-C", path.path, "rev-parse", "--git-common-dir"]
			let pipe = Pipe()
			process.standardOutput = pipe
			process.standardError = FileHandle.nullDevice
			do { try process.run() } catch { return nil }
			let data = pipe.fileHandleForReading.readDataToEndOfFile()
			process.waitUntilExit()
			guard process.terminationStatus == 0,
				let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty
			else { return nil }
			let common = text.hasPrefix("/") ? URL(fileURLWithPath: text) : path.appendingPathComponent(text)
			return canonical(common)
		}
	}

	/// True when `a` and `b` are the same directory, or two checkouts/worktrees of one git repository.
	static func sameRepository(_ a: URL, _ b: URL) -> Bool {
		if a == b { return true }
		guard let commonA = gitCommonDirectory(a) else { return false }
		return commonA == gitCommonDirectory(b)
	}
}
