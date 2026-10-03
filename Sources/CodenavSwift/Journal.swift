import Foundation
import NavShared

/// Edits that can be undone. Entries are also kept on disk, so `undo_edit` still works after the MCP client
/// restarted the server (the files are in the temporary directory, keyed by workspace).
struct JournalStore {
	let directory: URL
	static let limit = 25

	init(workspace: URL, base: URL = FileManager.default.temporaryDirectory) {
		// A short stable name for the workspace path (FNV-1a), not the path itself.
		var hash: UInt64 = 0xcbf2_9ce4_8422_2325
		for byte in workspace.realPath.path.utf8 { hash = (hash ^ UInt64(byte)) &* 0x100_0000_01b3 }
		directory = base.appendingPathComponent("codenav-swift-undo", isDirectory: true)
			.appendingPathComponent(String(hash, radix: 16), isDirectory: true)
	}

	private struct Record: Codable {
		var id: String
		var title: String
		var date: Date
		var changes: [FileChange]
	}

	func load() -> [JournalEntry] {
		guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return [] }
		let decoder = JSONDecoder()
		return files.filter { $0.pathExtension == "json" }.compactMap { url -> JournalEntry? in
			guard let data = try? Data(contentsOf: url), let record = try? decoder.decode(Record.self, from: data) else { return nil }
			var plan = EditPlan()
			plan.changes = record.changes
			return JournalEntry(id: record.id, title: record.title, plan: plan, date: record.date)
		}.sorted { Self.number($0.id) < Self.number($1.id) }
	}

	static func number(_ id: String) -> Int { Int(id.dropFirst()) ?? 0 }

	func save(_ entry: JournalEntry) {
		try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
		let record = Record(id: entry.id, title: entry.title, date: entry.date, changes: entry.plan.changes)
		if let data = try? JSONEncoder().encode(record) { try? data.write(to: file(entry.id), options: .atomic) }
	}

	func remove(_ id: String) {
		try? FileManager.default.removeItem(at: file(id))
	}

	/// Claims the next free id by creating its file exclusively, so two servers on the same workspace
	/// (two clients) never hand out the same one.
	func reserve(startingAt number: Int) -> String {
		try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
		var candidate = max(number, 1)
		while candidate < number + 10_000 {
			let path = file("e\(candidate)").path
			let descriptor = open(path, O_CREAT | O_EXCL | O_WRONLY, 0o644)
			if descriptor >= 0 {
				close(descriptor)
				return "e\(candidate)"
			}
			if errno != EEXIST { break }
			candidate += 1
		}
		return "e\(max(number, 1))"
	}

	// MARK: Changes written while a build runs

	/// A record of files that are changed on disk without being in the journal yet (a `check_edit` that builds
	/// the proposal). If the process dies meanwhile, the next one restores them.
	struct Pending: Codable {
		var pid: Int32
		var title: String
		var date: Date
		var changes: [FileChange]
	}

	func savePending(_ pending: Pending, token: String) {
		try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
		if let data = try? JSONEncoder().encode(pending) { try? data.write(to: pendingFile(token), options: .atomic) }
	}

	func removePending(_ token: String) {
		try? FileManager.default.removeItem(at: pendingFile(token))
	}

	func loadPending() -> [(token: String, pending: Pending)] {
		guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return [] }
		let decoder = JSONDecoder()
		return files.filter { $0.lastPathComponent.hasPrefix("pending-") && $0.pathExtension == "json" }.compactMap { url in
			guard let data = try? Data(contentsOf: url), let pending = try? decoder.decode(Pending.self, from: data) else { return nil }
			return (String(url.deletingPathExtension().lastPathComponent.dropFirst("pending-".count)), pending)
		}
	}

	private func pendingFile(_ token: String) -> URL { directory.appendingPathComponent("pending-\(token).json") }

	private func file(_ id: String) -> URL { directory.appendingPathComponent("\(id).json") }
}

extension SwiftNavigator {
	/// Reads the on-disk journal the first time it is needed in this process.
	func loadJournalIfNeeded() {
		guard !journalLoaded else { return }
		journalLoaded = true
		recoverStrandedChanges()
		let stored = JournalStore(workspace: workspaceRoot).load()
		guard !stored.isEmpty else { return }
		editJournal = stored + editJournal
		nextEditNumber = max(nextEditNumber, (stored.map { JournalStore.number($0.id) }.max() ?? 0) + 1)
	}

	/// The journal as it is on disk now: entries of other sessions on this workspace included.
	func reloadJournal() {
		let stored = JournalStore(workspace: workspaceRoot).load()
		editJournal = stored
		nextEditNumber = max(nextEditNumber, (stored.map { JournalStore.number($0.id) }.max() ?? 0) + 1)
	}

	func reserveEditID() -> String {
		let id = JournalStore(workspace: workspaceRoot).reserve(startingAt: nextEditNumber)
		nextEditNumber = JournalStore.number(id) + 1
		return id
	}

	func beginPending(_ plan: EditPlan, title: String) -> String {
		let token = UUID().uuidString
		JournalStore(workspace: workspaceRoot).savePending(
			.init(pid: ProcessInfo.processInfo.processIdentifier, title: title, date: Date(), changes: plan.changes), token: token)
		return token
	}

	func endPending(_ token: String) {
		JournalStore(workspace: workspaceRoot).removePending(token)
	}

	/// A previous server died while a proposal was written for a build: put those files back, unless the user
	/// has changed them since, and say so on the next write tool's answer.
	func recoverStrandedChanges() {
		let store = JournalStore(workspace: workspaceRoot)
		for (token, pending) in store.loadPending() {
			if pending.pid != ProcessInfo.processInfo.processIdentifier, kill(pending.pid, 0) == 0 { continue }  // still running elsewhere
			var plan = EditPlan()
			plan.changes = pending.changes
			let name = { (path: String) in EditFormat.relativeName(path, root: self.workspaceRoot) }
			let left = (try? EditEngine.restoreFiles(plan, skipChanged: true, name: name)) ?? plan.changes.map(\.path)
			store.removePending(token)
			let restored = plan.changes.map(\.path).filter { !left.contains($0) }
			var notice = "Recovered: a \(pending.title) was interrupted while its proposal was on disk; "
			notice += restored.isEmpty ? "nothing needed restoring" : "restored " + restored.map(name).joined(separator: ", ")
			if !left.isEmpty { notice += "; left as they are because they changed since: " + left.map(name).joined(separator: ", ") }
			recoveryNotices.append(notice + ".")
		}
	}

	func takeRecoveryNotice() -> String {
		defer { recoveryNotices = [] }
		return recoveryNotices.joined(separator: "\n")
	}

	func record(_ entry: JournalEntry) {
		editJournal.append(entry)
		let store = JournalStore(workspace: workspaceRoot)
		store.save(entry)
		while editJournal.count > JournalStore.limit { store.remove(editJournal.removeFirst().id) }
	}

	func forget(_ id: String) {
		editJournal.removeAll { $0.id == id }
		JournalStore(workspace: workspaceRoot).remove(id)
	}
}
