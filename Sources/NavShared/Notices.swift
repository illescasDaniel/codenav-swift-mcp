import Foundation

/// Out-of-band messages for the agent, appended to tool results.
///
/// Two kinds: one-shot notices posted while a call runs (e.g. "restarted the language
/// server because buildServer.json changed") and a sticky one while the server's own
/// executable differs from what it started with. A stdio MCP server can't reload itself
/// (the client's `initialize` handshake happens once), so the most it can do about a
/// rebuilt binary is say so on every call.
public final class NoticeBoard: @unchecked Sendable {
	public let serverName: String
	private let lock = NSLock()
	private var pending: [String] = []
	private let executable: URL?
	private let startedWith: Stamp?
	private let recheckInterval: TimeInterval
	private var checkedAt = Date()
	private var stale = false

	private struct Stamp: Equatable {
		var modified: Date
		var size: Int
	}

	public init(serverName: String, executable: URL? = NoticeBoard.currentExecutable(), recheckInterval: TimeInterval = 2) {
		self.serverName = serverName
		self.executable = executable
		self.recheckInterval = recheckInterval
		self.startedWith = executable.flatMap(NoticeBoard.stamp)
	}

	public static func currentExecutable() -> URL? {
		Bundle.main.executableURL ?? CommandLine.arguments.first.map { URL(fileURLWithPath: $0) }
	}

	private static func stamp(_ url: URL) -> Stamp? {
		guard let values = try? url.resolvingSymlinksInPath().resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]),
			let modified = values.contentModificationDate, let size = values.fileSize
		else { return nil }
		return Stamp(modified: modified, size: size)
	}

	public func post(_ message: String) {
		lock.lock()
		defer { lock.unlock() }
		if !pending.contains(message) { pending.append(message) }
	}

	/// A stat per tool call adds up; a few seconds' lag in noticing a rebuild is fine.
	public func codeIsStale() -> Bool {
		lock.lock()
		defer { lock.unlock() }
		let now = Date()
		if now.timeIntervalSince(checkedAt) >= recheckInterval {
			checkedAt = now
			if let startedWith, let executable {
				stale = NoticeBoard.stamp(executable).map { $0 != startedWith } ?? true
			}
		}
		return stale
	}

	/// One-shot notices posted since the last call, plus the sticky stale-code line.
	public func drain() -> [String] {
		lock.lock()
		var notices = pending
		pending = []
		lock.unlock()
		if codeIsStale() {
			notices.append("the \(serverName) server's own binary changed since it started; restart the MCP servers to use the new version.")
		}
		return notices
	}

	public func annotate(_ text: String) -> String {
		let notices = drain()
		guard !notices.isEmpty else { return text }
		return text + notices.map { "\n\n[\(serverName)] \($0)" }.joined()
	}
}
