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

	private func file(_ id: String) -> URL { directory.appendingPathComponent("\(id).json") }
}

extension SwiftNavigator {
	/// Reads the on-disk journal the first time it is needed in this process.
	func loadJournalIfNeeded() {
		guard !journalLoaded else { return }
		journalLoaded = true
		let stored = JournalStore(workspace: workspaceRoot).load()
		guard !stored.isEmpty else { return }
		editJournal = stored + editJournal
		nextEditNumber = max(nextEditNumber, (stored.map { JournalStore.number($0.id) }.max() ?? 0) + 1)
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
