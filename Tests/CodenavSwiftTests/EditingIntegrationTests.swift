import Foundation
import Testing

@testable import CodenavSwift
@testable import NavShared

/// The write tools against a real sourcekit-lsp, on a scratch copy of `Fixtures/SamplePackage`.
/// Skipped when no language server is installed.
@Suite(.serialized, .enabled(if: (try? SourceKitLSPLocator.command()) != nil))
struct EditingIntegrationTests {
	static let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
		.appendingPathComponent("Fixtures/SamplePackage")
	static let canBuild = ToolProcess.swiftExecutable(
		environment: ProcessInfo.processInfo.environment, languageServer: try? SourceKitLSPLocator.command()) != nil

	/// A scratch workspace: a copy of the fixture without its build products, and a navigator on it.
	struct Workspace {
		var root: URL
		var navigator: SwiftNavigator

		init(extraEnvironment: [String: String] = [:]) throws {
			let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("codenav-edit-\(UUID().uuidString)", isDirectory: true)
			try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
			let source = EditingIntegrationTests.fixture
			guard let enumerator = FileManager.default.enumerator(at: source, includingPropertiesForKeys: [.isDirectoryKey]) else {
				throw ToolInputError("cannot read the fixture")
			}
			for case let url as URL in enumerator {
				if url.lastPathComponent == ".build" || url.lastPathComponent == ".swiftpm" {
					enumerator.skipDescendants()
					continue
				}
				let relative = String(url.path.dropFirst(source.path.count + 1))
				let target = temporary.appendingPathComponent(relative)
				if (try url.resourceValues(forKeys: [.isDirectoryKey])).isDirectory == true {
					try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
				} else {
					try FileManager.default.copyItem(at: url, to: target)
				}
			}
			root = temporary.realPath
			var environment = ProcessInfo.processInfo.environment
			environment["CODENAV_SWIFT_WORKSPACE"] = root.path
			environment["CODENAV_SWIFT_WRITE"] = "1"
			environment["CODENAV_SWIFT_INDEX_TIMEOUT"] = "120"
			environment.merge(extraEnvironment) { $1 }
			navigator = SwiftNavigator(environment: environment, currentDirectory: root)
		}

		func call(_ tool: String, _ json: String) async -> ToolResult {
			let object = (try? JSONDecoder().decode([String: JSONValue].self, from: Data(json.utf8))) ?? [:]
			return await ToolCatalog.call(tool, arguments: ToolArguments(object), navigator: navigator)
		}

		func read(_ path: String) throws -> String {
			try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
		}

		func write(_ path: String, _ text: String) throws {
			try text.write(to: root.appendingPathComponent(path), atomically: true, encoding: .utf8)
		}

		func exists(_ path: String) -> Bool { FileManager.default.fileExists(atPath: root.appendingPathComponent(path).path) }

		/// A fresh navigator (as after the MCP client restarted the server) on the same files.
		func restarted() -> SwiftNavigator {
			var environment = ProcessInfo.processInfo.environment
			environment["CODENAV_SWIFT_WORKSPACE"] = root.path
			environment["CODENAV_SWIFT_WRITE"] = "1"
			environment["CODENAV_SWIFT_INDEX_TIMEOUT"] = "120"
			return SwiftNavigator(environment: environment, currentDirectory: root)
		}

		func finish() async {
			await navigator.shutdown()
			try? FileManager.default.removeItem(at: JournalStore(workspace: root).directory)
			try? FileManager.default.removeItem(at: root)
		}
	}

	// MARK: lookups sourcekit-lsp's symbol search can't answer

	/// `workspace/symbol` omits `let` properties and loses extension members; the outlines of the files that
	/// mention a name have them.
	@Test func letPropertiesExtensionMembersAndTopLevelConstantsAreFoundByName() async throws {
		let workspace = try Workspace()
		try workspace.write("Sources/SampleKit/Profile.swift", "public struct Profile {\n\tpublic var displayName: String\n\tpublic let id: Int = 1\n}\n\npublic let maxRetries = 3\n")
		try workspace.write("Sources/SampleKit/ProfileExt.swift", "extension Profile {\n\tpublic static let limit: Int = 10\n\tpublic var shortName: String { displayName }\n}\n")
		try workspace.write("Sources/SampleKit/Dup.swift", "let id = 7\n")

		let search = await workspace.call("search_symbol", #"{"query":"limit"}"#)
		#expect(search.contains("Profile.limit  [Property]  (Sources/SampleKit/ProfileExt.swift:2:"))
		let qualified = await workspace.call("search_symbol", #"{"query":"Profile.limit"}"#)
		#expect(qualified.contains("Profile.limit"))
		let ids = await workspace.call("search_symbol", #"{"query":"id","path":"Sources/SampleKit/Profile.swift"}"#)
		#expect(ids.contains("Profile.id"))

		for (name, fragment) in [("Profile.id", "Profile.swift:3"), ("Profile.limit", "ProfileExt.swift:2"), ("Profile.shortName", "ProfileExt.swift:3"), ("maxRetries", "Profile.swift:6")] {
			let info = await workspace.call("symbol_info", "{\"name\":\"\(name)\",\"include_references\":false}")
			#expect(!info.isError, "\(name)")
			#expect(info.contains(fragment), "\(name) should resolve to \(fragment)")
		}
		// A bare name is the top-level one; `file_path` picks between several.
		let bare = await workspace.call("symbol_info", #"{"name":"id","include_references":false}"#)
		#expect(bare.contains("Dup.swift:1"))
		let missing = await workspace.call("symbol_info", #"{"name":"Profile.nope"}"#)
		#expect(missing.isError)

		let rename = await workspace.call("rename_symbol", #"{"name":"Profile.limit","new_name":"cap","verify":"none"}"#)
		#expect(!rename.isError)
		#expect(try workspace.read("Sources/SampleKit/ProfileExt.swift").contains("static let cap"))
		await workspace.finish()
	}

	// MARK: members the compiler writes

	static let personSource =
		"import Foundation\npublic struct Person: Codable, Equatable, Hashable {\n\tpublic let name: String\n\tpublic var age: Int\n\tvar nick: String? = nil\n}\npublic enum Level: String, CaseIterable { case low, high }\npublic struct Plain { var a: Int }\npublic struct Explicit { var a: Int; init(a: Int) { self.a = a } }\n"

	@Test(.enabled(if: EditingIntegrationTests.canBuild))
	func membersTheCompilerWritesAreListedAndMarkedAutoGenerated() async throws {
		let workspace = try Workspace()
		try workspace.write("Sources/SampleKit/Person.swift", Self.personSource)

		let person = await workspace.call("symbol_info", #"{"name":"Person","include_references":false}"#)
		#expect(person.contains("Auto-generated by the compiler (the source has no declaration for these):"))
		#expect(person.contains("internal init(name: String, age: Int, nick: String? = nil)  [Auto-Generated: memberwise initializer]"))
		#expect(person.contains("public func encode(to encoder: any Encoder) throws  [Auto-Generated: Encodable]"))
		#expect(person.contains("public init(from decoder: any Decoder) throws  [Auto-Generated: Decodable]"))
		#expect(person.contains("public static func ==(_ a: Person, _ b: Person) -> Bool  [Auto-Generated: Equatable]"))
		#expect(person.contains("[Auto-Generated: Hashable]"))
		#expect(person.contains("private enum CodingKeys : CodingKey { case name, age, nick }"))

		let level = await workspace.call("symbol_info", #"{"name":"Level","include_references":false}"#)
		#expect(level.contains("public init?(rawValue: String)  [Auto-Generated: RawRepresentable]"))
		#expect(level.contains("allCases: [Level]  [Auto-Generated: CaseIterable]"))

		// An explicit initializer replaces the memberwise one; a plain struct gets an internal one.
		let explicit = await workspace.call("symbol_info", #"{"name":"Explicit","include_references":false}"#)
		#expect(!explicit.contains("Auto-Generated"))
		let plain = await workspace.call("symbol_info", #"{"name":"Plain","include_references":false}"#)
		#expect(plain.contains("internal init(a: Int)  [Auto-Generated: memberwise initializer]"))

		// Members asked for by name have no declaration; the answer says what they are.
		let byName = await workspace.call("symbol_info", #"{"name":"Person.init(name:age:nick:)"}"#)
		#expect(!byName.isError)
		#expect(byName.text.hasPrefix("Person.init(name:age:nick:)  [Auto-Generated: memberwise initializer]"))
		#expect(byName.contains("no declaration of it exists in the source"))
		let encode = await workspace.call("symbol_info", #"{"name":"Person.encode(to:)"}"#)
		#expect(encode.contains("[Auto-Generated: Encodable]"))
		let missing = await workspace.call("symbol_info", #"{"name":"Person.nope"}"#)
		#expect(missing.isError)

		let outline = await workspace.call("outline", #"{"file_path":"Sources/SampleKit/Person.swift"}"#)
		#expect(!outline.contains("Auto-Generated"))  // opt-in
		let withSynthesized = await workspace.call("outline", #"{"file_path":"Sources/SampleKit/Person.swift","synthesized":true}"#)
		#expect(withSynthesized.contains("[Auto-Generated: memberwise initializer]"))
		await workspace.finish()
	}

	@Test(.enabled(if: EditingIntegrationTests.canBuild))
	func theListingFollowsEditsToTheType() async throws {
		let workspace = try Workspace()
		try workspace.write("Sources/SampleKit/Plain.swift", "public struct Plain { var a: Int }\n")
		let first = await workspace.call("symbol_info", #"{"name":"Plain","include_references":false}"#)
		#expect(first.contains("internal init(a: Int)"))
		// The cached listing must not outlive the file it describes.
		try workspace.write("Sources/SampleKit/Plain.swift", "public struct Plain { var a: Int; var b: String = \"x\" }\n")
		let second = await workspace.call("symbol_info", #"{"name":"Plain","include_references":false}"#)
		#expect(second.contains("internal init(a: Int, b: String = \"x\")"))
		#expect(!second.contains("internal init(a: Int)  ["))
		await workspace.finish()
	}

	@Test func withoutTheCompilerTheMemberwiseInitIsWorkedOutAndSaysSo() async throws {
		let workspace = try Workspace(extraEnvironment: ["CODENAV_SWIFT_AST": "0"])
		try workspace.write("Sources/SampleKit/Person.swift", Self.personSource)
		let person = await workspace.call("symbol_info", #"{"name":"Person","include_references":false}"#)
		#expect(person.contains("worked out from the stored properties"))
		#expect(person.contains("turned off with CODENAV_SWIFT_AST=0"))
		#expect(person.contains("internal init(name: String, age: Int, nick: String? = nil)  [Auto-Generated: memberwise initializer]"))
		#expect(!person.contains("encode(to"))  // not guessed
		let level = await workspace.call("symbol_info", #"{"name":"Level","include_references":false}"#)
		#expect(level.contains("Auto-generated members of Level: not listed (turned off"))

		// A property whose type isn't written: the language server's hover knows it.
		try workspace.write(
			"Sources/SampleKit/Counter.swift", "public struct Counter {\n\tvar count = 0\n\tvar ratio = 0.5\n\tvar label = \"x\"\n\tlet id: Int\n}\n")
		let counter = await workspace.call("symbol_info", #"{"name":"Counter","include_references":false}"#)
		#expect(counter.contains("internal init(count: Int = 0, ratio: Double = 0.5, label: String = \"x\", id: Int)  [Auto-Generated: memberwise initializer]"))
		await workspace.finish()
	}

	// MARK: apply_edit / check_edit / undo_edit

	@Test func aBreakingEditIsRefusedAndAHarmlessOneAppliedAndUndone() async throws {
		let workspace = try Workspace()
		let original = try workspace.read("Sources/SampleKit/Ports.swift")

		// Adding a parameter to a protocol requirement breaks its conformers and callers.
		let breaking = #"{"file_path":"Sources/SampleKit/Ports.swift","old_text":"func save(_ user: User) async throws","new_text":"func save(_ user: User, overwrite: Bool) async throws","verify":"none"}"#
		let checked = await workspace.call("check_edit", breaking)
		#expect(!checked.isError)
		#expect(checked.contains("nothing written"))
		#expect(checked.contains("3 new error(s)"))
		#expect(checked.contains("Stores.swift:1:14"))
		#expect(checked.contains("fix-it: Insert ', overwrite: '"))
		#expect(try workspace.read("Sources/SampleKit/Ports.swift") == original)

		let refused = await workspace.call("apply_edit", breaking)
		#expect(refused.isError)
		#expect(refused.contains("NOT applied"))
		#expect(try workspace.read("Sources/SampleKit/Ports.swift") == original)

		let harmless = await workspace.call(
			"apply_edit", #"{"file_path":"Sources/SampleKit/UserService.swift","old_text":"/// Creates a user and saves it.","new_text":"/// Creates a user, saves it and returns it."}"#)
		#expect(!harmless.isError)
		#expect(harmless.contains("applied as e1"))
		#expect(harmless.contains("✓ no new errors"))
		#expect(try workspace.read("Sources/SampleKit/UserService.swift").contains("returns it."))

		let undone = await workspace.call("undo_edit", "{}")
		#expect(undone.contains("Undid e1"))
		#expect(try workspace.read("Sources/SampleKit/UserService.swift").contains("/// Creates a user and saves it."))
		#expect(await workspace.call("undo_edit", #"{"list":true}"#).contains("No edits to undo"))
		await workspace.finish()
	}

	@Test func undoStillWorksAfterTheServerRestarted() async throws {
		let workspace = try Workspace()
		let applied = await workspace.call(
			"apply_edit", #"{"file_path":"Sources/SampleKit/UserService.swift","old_text":"Creates and finds users.","new_text":"Users."}"#)
		#expect(applied.contains("applied as e1"))
		await workspace.navigator.shutdown()

		let again = workspace.restarted()
		let arguments = ToolArguments([:])
		let listed = await again.undoEdit(id: nil, list: true, force: false)
		#expect(listed.contains("e1"))
		let undone = await ToolCatalog.call("undo_edit", arguments: arguments, navigator: again)
		#expect(undone.contains("Undid e1"))
		#expect(try workspace.read("Sources/SampleKit/UserService.swift").contains("Creates and finds users."))
		// Numbering continues instead of reusing an id that is still on record.
		let next = await ToolCatalog.call(
			"apply_edit", arguments: ToolArguments(["file_path": "Sources/SampleKit/UserService.swift", "old_text": "Creates and finds users.", "new_text": "Users."]),
			navigator: again)
		#expect(next.contains("applied as e2"))
		await again.shutdown()
		await workspace.finish()
	}

	@Test func undoRefusesWhenTheFileChangedSinceUnlessForced() async throws {
		let workspace = try Workspace()
		_ = await workspace.call("apply_edit", #"{"file_path":"Sources/SampleKit/UserService.swift","old_text":"Creates and finds users.","new_text":"Users."}"#)
		let path = "Sources/SampleKit/UserService.swift"
		try workspace.write(path, try workspace.read(path) + "\n// later edit\n")
		let refused = await workspace.call("undo_edit", "{}")
		#expect(refused.isError)
		#expect(refused.contains("edited after this change"))
		let forced = await workspace.call("undo_edit", #"{"force":true}"#)
		#expect(!forced.isError)
		#expect(try workspace.read(path).contains("Creates and finds users."))
		await workspace.finish()
	}

	@Test func newFilesAreCheckedAfterTheyExistAndRolledBackWhenBroken() async throws {
		let workspace = try Workspace()
		let good = await workspace.call(
			"apply_edit", #"{"edits":[{"file_path":"Sources/SampleKit/Extras.swift","content":"public struct Extras {\n\tpublic init() {}\n}"}]}"#)
		#expect(!good.isError)
		#expect(good.contains("New file check (after writing): ✓"))
		#expect(workspace.exists("Sources/SampleKit/Extras.swift"))

		let bad = await workspace.call(
			"apply_edit", #"{"edits":[{"file_path":"Sources/SampleKit/Broken.swift","content":"public struct Broken {\n\tpublic func f() -> String { 42 }\n}"}]}"#)
		#expect(bad.isError)
		#expect(bad.contains("rolled back"))
		#expect(!workspace.exists("Sources/SampleKit/Broken.swift"))
		await workspace.finish()
	}

	@Test func requireNoneWritesAnywayAndReportsTheErrors() async throws {
		let workspace = try Workspace()
		let forced = await workspace.call(
			"apply_edit",
			#"{"file_path":"Sources/SampleKit/Ports.swift","old_text":"func save(_ user: User) async throws","new_text":"func save(_ user: User, overwrite: Bool) async throws","require":"none","verify":"none"}"#)
		#expect(!forced.isError)
		#expect(forced.contains("applied as e1"))
		#expect(forced.contains("new error(s)"))
		#expect(try workspace.read("Sources/SampleKit/Ports.swift").contains("overwrite: Bool"))
		await workspace.finish()
	}

	/// sourcekit-lsp only refreshes what depends on a changed document once that document is asked about. A
	/// check that skipped this judged a dependent against its cached, pre-change state: a protocol and its
	/// conformer changed together left the callers looking healthy (and "already broken" before the change).
	@Test func aChangeToSeveralFilesIsJudgedFreshNotFromTheServersCache() async throws {
		let workspace = try Workspace()
		let both =
			#"{"edits":[{"file_path":"Sources/SampleKit/Ports.swift","old_text":"func save(_ user: User) async throws","new_text":"func save(_ user: User, overwrite: Bool) async throws"},{"file_path":"Sources/SampleKit/Stores.swift","old_text":"public func save(_ user: User) async throws","new_text":"public func save(_ user: User, overwrite: Bool) async throws"}],"verify":"none"}"#
		let first = await workspace.call("check_edit", both)
		#expect(first.contains("2 new error(s)"))
		#expect(first.contains("UserService.swift:12"))
		#expect(!first.contains("already there"))
		// Asking again, and then about a smaller change, must not be affected by what the first check left behind.
		let again = await workspace.call("check_edit", both)
		#expect(again.contains("2 new error(s)"))
		let single = await workspace.call(
			"check_edit",
			#"{"file_path":"Sources/SampleKit/Ports.swift","old_text":"func save(_ user: User) async throws","new_text":"func save(_ user: User, overwrite: Bool) async throws","verify":"none"}"#)
		#expect(single.contains("3 new error(s)"))
		let clean = await workspace.call(
			"check_edit", #"{"file_path":"Sources/SampleKit/UserService.swift","old_text":"Creates and finds users.","new_text":"Users.","verify":"none"}"#)
		#expect(clean.contains("✓ no new errors"))
		#expect(!clean.contains("already there"))
		await workspace.finish()
	}

	@Test func editsToSeveralFilesAreAllOrNothing() async throws {
		let workspace = try Workspace()
		let result = await workspace.call(
			"apply_edit",
			#"{"edits":[{"file_path":"Sources/SampleKit/Models.swift","old_text":"public var name: String","new_text":"public var fullName: String"},{"file_path":"Sources/SampleKit/Ports.swift","old_text":"this text is not there","new_text":"x"}]}"#)
		#expect(result.isError)
		#expect(result.contains("was not found"))
		#expect(try workspace.read("Sources/SampleKit/Models.swift").contains("public var name: String"))
		await workspace.finish()
	}

	@Test func nothingOutsideTheWorkspaceOrInBuildProductsCanBeEdited() async throws {
		let workspace = try Workspace()
		let outside = await workspace.call("apply_edit", #"{"edits":[{"file_path":"/etc/hosts","old_text":"localhost","new_text":"x"}]}"#)
		#expect(outside.isError)
		#expect(outside.contains("outside the workspace"))
		let checkout = await workspace.call("apply_edit", #"{"edits":[{"file_path":".build/checkouts/Dep/Sources/Dep/D.swift","content":"x"}]}"#)
		#expect(checkout.isError)
		await workspace.finish()
	}

	// MARK: edit_symbol, insert_member, delete_symbol, move_symbol

	@Test func symbolsAreEditedByNameWithoutQuotingText() async throws {
		let workspace = try Workspace()
		let body = await workspace.call(
			"edit_symbol",
			#"{"name":"UserService.find(id:)","new_body":"let user = try await store.load(id: id)\nreturn user","verify":"none"}"#)
		#expect(!body.isError)
		let service = try workspace.read("Sources/SampleKit/UserService.swift")
		#expect(service.contains("\tpublic func find(id: User.ID) async throws -> User? {\n\t\tlet user = try await store.load(id: id)\n\t\treturn user\n\t}"))

		let source = await workspace.call(
			"edit_symbol",
			#"{"name":"Dog","new_source":"/// A good boy.\npublic final class Dog: Animal {\n    public override func speak() -> String { \"woof!\" }\n}","verify":"none"}"#)
		#expect(!source.isError)
		let models = try workspace.read("Sources/SampleKit/Models.swift")
		#expect(models.contains("/// A good boy.\npublic final class Dog: Animal {\n\tpublic override func speak() -> String { \"woof!\" }\n}"))

		let scoped = await workspace.call(
			"edit_symbol", #"{"name":"UserService.create(name:)","old_text":"name.count","new_text":"name.count + 1","verify":"none"}"#)
		#expect(!scoped.isError)
		#expect(try workspace.read("Sources/SampleKit/UserService.swift").contains("User(id: name.count + 1"))

		let broken = await workspace.call("edit_symbol", #"{"name":"Dog","new_body":"return 5","verify":"none"}"#)
		#expect(broken.isError)
		#expect(broken.contains("new error"))
		let ambiguous = await workspace.call("edit_symbol", #"{"name":"Dog","new_body":"x","new_source":"y"}"#)
		#expect(ambiguous.isError)
		await workspace.finish()
	}

	@Test func membersAreInsertedWhereAskedAndMatchTheFilesStyle() async throws {
		let workspace = try Workspace()
		let after = await workspace.call(
			"insert_member",
			#"{"container":"UserService","code":"public func delete(id: User.ID) async throws {\n    _ = try await find(id: id)\n}","position":"after:find(id:)","verify":"none"}"#)
		#expect(!after.isError)
		#expect(try workspace.read("Sources/SampleKit/UserService.swift").contains(
			"\t}\n\n\tpublic func delete(id: User.ID) async throws {\n\t\t_ = try await find(id: id)\n\t}\n}"))

		let property = await workspace.call("insert_member", #"{"container":"User","code":"public var isAdmin: Bool { false }","verify":"none"}"#)
		#expect(!property.isError)
		#expect(try workspace.read("Sources/SampleKit/Models.swift").contains("\t}\n\n\tpublic var isAdmin: Bool { false }\n}"))

		let topLevel = await workspace.call("insert_member", #"{"file_path":"Sources/SampleKit/Models.swift","code":"public struct Tag {}","verify":"none"}"#)
		#expect(!topLevel.isError)
		#expect(try workspace.read("Sources/SampleKit/Models.swift").hasSuffix("}\n\npublic struct Tag {}\n"))

		let notAType = await workspace.call("insert_member", #"{"container":"UserService.find(id:)","code":"var x = 1"}"#)
		#expect(notAType.isError)
		await workspace.finish()
	}

	@Test func aMemberIsInsertedIntoTheTypeSelectedByFileAndLine() async throws {
		let workspace = try Workspace()
		let added = await workspace.call(
			"insert_member",
			#"{"file_path":"Sources/SampleKit/UserService.swift","line":2,"symbol":"UserService","code":"public func ping() -> Bool { true }","position":"first","verify":"none"}"#)
		#expect(!added.isError, "\(added.text)")
		// Inside the class (its first member), not appended at the end of the file.
		let service = try workspace.read("Sources/SampleKit/UserService.swift")
		#expect(service.contains("public final class UserService {\n\tpublic func ping() -> Bool { true }"))
		await workspace.finish()
	}

	@Test func aNestedTypeGetsItsConformanceAfterTheOutermostType() async throws {
		let workspace = try Workspace()
		let result = await workspace.call("add_conformance", #"{"type":"Outer.Inner","protocol":"Sendable","stubs":false,"verify":"none"}"#)
		#expect(!result.isError, "\(result.text)")
		let models = try workspace.read("Sources/SampleKit/Models.swift")
		#expect(models.contains("\t}\n}\n\nextension Outer.Inner: Sendable {\n}\n"))
		await workspace.finish()
	}

	@Test func aUsedSymbolIsNotDeletedAnUnusedOneIs() async throws {
		let workspace = try Workspace()
		let used = await workspace.call("delete_symbol", #"{"name":"UserService.create(name:)"}"#)
		#expect(used.isError)
		#expect(used.contains("still used"))
		#expect(used.contains("main.swift"))
		#expect(try workspace.read("Sources/SampleKit/UserService.swift").contains("func create(name:"))

		let unused = await workspace.call("delete_symbol", #"{"name":"Role","verify":"none"}"#)
		#expect(!unused.isError)
		let models = try workspace.read("Sources/SampleKit/Models.swift")
		#expect(!models.contains("enum Role"))
		#expect(models.contains("open class Animal"))
		#expect(!models.contains("}\n\n\n"))
		await workspace.finish()
	}

	@Test func aDeclarationMovesToANewFileWithItsImports() async throws {
		let workspace = try Workspace()
		let moved = await workspace.call("move_symbol", #"{"name":"Dog","to_file":"Sources/SampleKit/Dog.swift","verify":"none"}"#)
		#expect(!moved.isError)
		#expect(moved.contains("New file check (after writing): ✓"))
		#expect(try workspace.read("Sources/SampleKit/Dog.swift") == "public final class Dog: Animal {\n\tpublic override func speak() -> String { \"woof\" }\n}\n")
		#expect(!(try workspace.read("Sources/SampleKit/Models.swift")).contains("class Dog"))
		let member = await workspace.call("move_symbol", #"{"name":"UserService.find(id:)","to_file":"Sources/SampleKit/Other.swift"}"#)
		#expect(member.isError)
		#expect(member.contains("to_container"))
		await workspace.finish()
	}

	// MARK: rename_symbol

	@Test func renamingAStoredPropertyFollowsTheMemberwiseInitializerLabel() async throws {
		let workspace = try Workspace()
		try workspace.write("Sources/SampleKit/Pet.swift", "struct Pet {\n\tlet nickname: String\n\tvar age: Int\n}\n")
		try workspace.write(
			"Sources/SampleKit/PetUse.swift",
			"func makePet() -> Pet {\n\tPet(\n\t\tnickname: \"Rex\",\n\t\tage: 3\n\t)\n}\nfunc other() -> Pet { Pet(nickname: \"A\", age: 1) }\n")
		let renamed = await workspace.call("rename_symbol", #"{"name":"Pet.nickname","new_name":"alias","verify":"none"}"#)
		#expect(!renamed.isError)
		let use = try workspace.read("Sources/SampleKit/PetUse.swift")
		#expect(use.contains("alias: \"Rex\""))
		#expect(use.contains("Pet(alias: \"A\""))
		#expect(!use.contains("nickname"))
		await workspace.finish()
	}

	@Test func renamesFollowOverloadsWitnessesAndLabelsAndTellWhatTheyCouldNotFollow() async throws {
		let workspace = try Workspace()
		var service = try workspace.read("Sources/SampleKit/UserService.swift")
		service = service.replacingOccurrences(of: "/// Creates a user and saves it.", with: "/// Creates a user and saves it. See `create(name:)`.")
		try workspace.write("Sources/SampleKit/UserService.swift", service)
		try workspace.write("Sources/SampleKit/Profile.swift", "public struct Profile: Codable {\n\tpublic var displayName: String\n}\n")

		let renamed = await workspace.call("rename_symbol", #"{"name":"UserService.create(name:)","new_name":"make(named:)","verify":"none"}"#)
		#expect(!renamed.isError)
		#expect(renamed.contains("renamed create(name:) → make(named:)"))
		#expect(renamed.contains("still appears in 1 comment/string"))
		#expect(try workspace.read("Sources/SampleApp/main.swift").contains("service.make(named: \"Ada\")"))
		#expect(try workspace.read("Tests/SampleKitTests/UserServiceTests.swift").contains("service.make(named: \"Bob\")"))
		#expect(try workspace.read("Sources/SampleKit/UserService.swift").contains("public func make(named: String)"))

		let codable = await workspace.call("rename_symbol", #"{"name":"Profile.displayName","new_name":"fullName","dry_run":true}"#)
		#expect(codable.contains("CHANGES THE JSON KEY"))

		let witness = await workspace.call("rename_symbol", #"{"name":"UserStore.save(_:)","new_name":"persist","verify":"none"}"#)
		#expect(!witness.isError)
		#expect(try workspace.read("Sources/SampleKit/Stores.swift").contains("func persist(_ user: User)"))
		#expect(try workspace.read("Sources/SampleKit/Ports.swift").contains("func persist(_ user: User)"))
		await workspace.finish()
	}

	@Test func badRenamesAreRefusedBeforeAnythingIsChanged() async throws {
		let workspace = try Workspace()
		let labels = await workspace.call("rename_symbol", #"{"name":"UserService.create(name:)","new_name":"make(a:b:)"}"#)
		#expect(labels.isError && labels.contains("change_signature"))
		let keyword = await workspace.call("rename_symbol", #"{"name":"UserService.create(name:)","new_name":"class"}"#)
		#expect(keyword.isError && keyword.contains("keyword"))
		let collision = await workspace.call("rename_symbol", #"{"name":"UserService.create(name:)","new_name":"find(id:)"}"#)
		#expect(collision.isError && collision.contains("collide"))
		let sdk = await workspace.call("rename_symbol", #"{"name":"String","new_name":"Text"}"#)
		#expect(sdk.isError)
		#expect(try workspace.read("Sources/SampleKit/UserService.swift").contains("func create(name: String)"))
		await workspace.finish()
	}

	@Test func aDeprecatedAliasKeepsTheOldNameWorking() async throws {
		let workspace = try Workspace()
		let result = await workspace.call(
			"rename_symbol", #"{"name":"UserService.find(id:)","new_name":"lookup","keep_deprecated_alias":true,"verify":"none"}"#)
		#expect(!result.isError)
		let service = try workspace.read("Sources/SampleKit/UserService.swift")
		#expect(service.contains("public func lookup(id: User.ID) async throws -> User? {"))
		#expect(service.contains("@available(*, deprecated, renamed: \"lookup(id:)\")\n\tpublic func find(id: User.ID) async throws -> User? { try await lookup(id: id) }"))
		await workspace.finish()
	}

	@Test func aDeprecatedAliasForwardsWithTheNewArgumentLabels() async throws {
		let workspace = try Workspace()
		try workspace.write("Sources/SampleKit/Scroller.swift", "public struct Scroller {\n\tpublic func scrollTo(_ value: Int) {}\n}\n")
		let result = await workspace.call(
			"rename_symbol", #"{"name":"Scroller.scrollTo(_:)","new_name":"scroll(to:)","keep_deprecated_alias":true,"verify":"none"}"#)
		#expect(!result.isError)
		let text = try workspace.read("Sources/SampleKit/Scroller.swift")
		#expect(text.contains("public func scroll(to value: Int) {}"))
		#expect(text.contains("public func scrollTo(_ value: Int) { scroll(to: value) }"))
		await workspace.finish()
	}

	@Test func leftoverMentionsInConditionalCompilationAreCalledOut() async throws {
		let workspace = try Workspace()
		try workspace.write(
			"Sources/SampleKit/Flagged.swift",
			"public func ping() {}\n\npublic func use() {\n#if !DEBUG\n\tping()\n#endif\n}\n")
		let result = await workspace.call("rename_symbol", #"{"name":"ping()","new_name":"pong","dry_run":true}"#)
		#expect(result.contains("conditional compilation"))
		#expect(result.contains("#if !DEBUG"))
		await workspace.finish()
	}

	@Test func typesAndPropertiesKeepDeprecatedAliases() async throws {
		let workspace = try Workspace()
		try workspace.write("Sources/SampleKit/Profile.swift", "public struct Profile {\n\tpublic var displayName: String\n\tpublic static let limit: Int = 3\n}\n")
		let property = await workspace.call(
			"rename_symbol", #"{"name":"Profile.displayName","new_name":"fullName","keep_deprecated_alias":true,"verify":"none"}"#)
		#expect(!property.isError)
		let profile = try workspace.read("Sources/SampleKit/Profile.swift")
		#expect(profile.contains("\t@available(*, deprecated, renamed: \"fullName\")\n\tpublic var displayName: String {\n\t\tget { fullName }\n\t\tset { fullName = newValue }\n\t}"))
		// `let` properties aren't in workspace/symbol; they are found through the type's outline.
		let letProperty = await workspace.call("rename_symbol", #"{"name":"Profile.limit","new_name":"cap","dry_run":true}"#)
		#expect(!letProperty.isError)
		#expect(letProperty.contains("limit → cap") || letProperty.contains("limit"))
		let constant = await workspace.call(
			"rename_symbol", #"{"name":"Profile.limit","new_name":"maximum","keep_deprecated_alias":true,"verify":"none"}"#)
		#expect(!constant.isError)
		#expect(try workspace.read("Sources/SampleKit/Profile.swift").contains("public static var limit: Int { maximum }"))
		// A computed property: the alias takes the declared type, not the accessor that follows it.
		try workspace.write("Sources/SampleKit/Computed.swift", "public struct Computed {\n\tpublic var shortName: String { \"x\" }\n}\n")
		let computed = await workspace.call(
			"rename_symbol", #"{"name":"Computed.shortName","new_name":"brief","keep_deprecated_alias":true,"verify":"none"}"#)
		#expect(!computed.isError)
		// Get-only stays get-only: no setter is invented.
		#expect(try workspace.read("Sources/SampleKit/Computed.swift").contains("public var shortName: String { brief }"))
		let type = await workspace.call("rename_symbol", #"{"name":"Dog","new_name":"Hound","keep_deprecated_alias":true,"verify":"none"}"#)
		#expect(!type.isError)
		let models = try workspace.read("Sources/SampleKit/Models.swift")
		#expect(models.contains("public final class Hound: Animal"))
		#expect(models.contains("@available(*, deprecated, renamed: \"Hound\")\npublic typealias Dog = Hound"))
		await workspace.finish()
	}

	@Test func membersMoveBetweenTypesInOneFileOrAcrossFiles() async throws {
		let workspace = try Workspace()
		try workspace.write(
			"Sources/SampleKit/Repo.swift",
			"public final class Repo {\n\tpublic init() {}\n}\n\nextension UserService {\n\tpublic func ping() -> Int { 1 }\n}\n")
		let moved = await workspace.call("move_symbol", #"{"name":"UserService.ping()","to_container":"Repo","verify":"none"}"#)
		#expect(!moved.isError)
		let repo = try workspace.read("Sources/SampleKit/Repo.swift")
		#expect(repo.contains("public init() {}\n\n\tpublic func ping() -> Int { 1 }\n}"))
		#expect(!repo.contains("extension UserService {\n\tpublic func ping"))

		// Same file: one declaration's member into another type of the same file.
		let sameFile = await workspace.call("move_symbol", #"{"name":"Dog.speak()","to_container":"Animal","verify":"none","require":"none"}"#)
		#expect(!sameFile.isError)
		let models = try workspace.read("Sources/SampleKit/Models.swift")
		#expect(models.components(separatedBy: "\"woof\"").count == 2)  // moved, not copied
		let woof = try #require(models.range(of: "\"woof\""))
		let dog = try #require(models.range(of: "public final class Dog"))
		#expect(woof.lowerBound < dog.lowerBound)  // now inside Animal, which comes first

		let usesSelf = await workspace.call("move_symbol", #"{"name":"UserService.find(id:)","to_container":"Repo","verify":"none"}"#)
		#expect(usesSelf.isError)
		#expect(usesSelf.contains("Cannot find 'store' in scope"))
		let topLevel = await workspace.call("move_symbol", #"{"name":"Dog","to_container":"Repo"}"#)
		#expect(topLevel.isError && topLevel.contains("top-level"))
		let both = await workspace.call("move_symbol", #"{"name":"Dog","to_container":"Repo","to_file":"Sources/SampleKit/X.swift"}"#)
		#expect(both.isError && both.contains("exactly one"))
		await workspace.finish()
	}

	@Test func aFileThatStillHasErrorsGetsTheFlowLintForWhatWasEdited() async throws {
		let workspace = try Workspace()
		try workspace.write("Sources/SampleKit/Sw.swift", "public func describe(_ r: Role) -> Int {\n\tswitch r {\n\tcase .admin: return 1\n\t}\n}\n")
		let result = await workspace.call(
			"insert_member",
			#"{"file_path":"Sources/SampleKit/Sw.swift","code":"public func g(_ x: Int) -> Int {\n    let y = x + 1\n    print(y)\n}","require":"none","verify":"none"}"#)
		#expect(result.contains("Possible problems the compiler can't report"))
		#expect(result.contains("g returns Int but has 2 statements and no `return`"))
		await workspace.finish()
	}

	// MARK: change_signature

	@Test func addingAParameterRewritesEveryCallAcrossModulesAndWitnesses() async throws {
		let workspace = try Workspace()
		try workspace.write(
			"Sources/SampleKit/Bulk.swift",
			"extension UserService {\n\tpublic func bulk(_ names: [String]) async throws {\n\t\tfor name in names {\n\t\t\t_ = try await create(name: name)\n\t\t}\n\t\t_ = try await create(\n\t\t\tname: \"x\"\n\t\t)\n\t}\n}\n")
		let result = await workspace.call(
			"change_signature",
			#"{"name":"UserStore.save(_:)","operations":[{"op":"add","param":"overwrite: Bool","call_value":"true"}],"verify":"none"}"#)
		#expect(!result.isError)
		#expect(result.contains("3 declaration(s)"))
		#expect(try workspace.read("Sources/SampleKit/Ports.swift").contains("func save(_ user: User, overwrite: Bool) async throws"))
		#expect(try workspace.read("Sources/SampleKit/Stores.swift").contains("public func save(_ user: User, overwrite: Bool) async throws"))
		#expect(try workspace.read("Tests/SampleKitTests/UserServiceTests.swift").contains("func save(_ user: User, overwrite: Bool) async throws {}"))
		let service = try workspace.read("Sources/SampleKit/UserService.swift")
		#expect(service.contains("try await store.save(user, overwrite: true)"))
		#expect(service.contains("try await store.save(copy, overwrite: true)"))

		let multiline = await workspace.call(
			"change_signature",
			#"{"name":"UserService.create(name:)","operations":[{"op":"add","param":"admin: Bool","call_value":"false"}],"verify":"none"}"#)
		#expect(!multiline.isError)
		let bulk = try workspace.read("Sources/SampleKit/Bulk.swift")
		#expect(bulk.contains("_ = try await create(name: name, admin: false)"))
		#expect(bulk.contains("_ = try await create(\n\t\t\tname: \"x\",\n\t\t\tadmin: false\n\t\t)"))
		#expect(try workspace.read("Sources/SampleApp/main.swift").contains("service.create(name: \"Ada\", admin: false)"))
		await workspace.finish()
	}

	@Test func callsWithTrailingClosuresAreRewrittenWhenTheClosureStaysLast() async throws {
		let workspace = try Workspace()
		try workspace.write(
			"Sources/SampleKit/Loader.swift",
			"public func load(_ id: Int, then done: @escaping (Int) -> Void) { done(id) }\n\npublic func useLoader() {\n\tload(1) { print($0) }\n\tload(2, then: { print($0) })\n}\n")
		let before = await workspace.call(
			"change_signature",
			#"{"name":"load(_:then:)","operations":[{"op":"add","param":"force: Bool","position":"before:then","call_value":"true"}],"verify":"none"}"#)
		#expect(!before.isError)
		let loader = try workspace.read("Sources/SampleKit/Loader.swift")
		#expect(loader.contains("public func load(_ id: Int, force: Bool, then done: @escaping (Int) -> Void)"))
		#expect(loader.contains("\tload(1, force: true) { print($0) }"))
		#expect(loader.contains("\tload(2, force: true, then: { print($0) })"))

		// An added parameter after the closure would force the closure into the parentheses: left for a person.
		let after = await workspace.call(
			"change_signature",
			#"{"name":"load(_:force:then:)","operations":[{"op":"add","param":"extra: Int","call_value":"0"}],"verify":"none"}"#)
		#expect(after.contains("trailing closure would have to move") || after.isError)
		await workspace.finish()
	}

	@Test func aDefaultedParameterLeavesCallersAlone() async throws {
		let workspace = try Workspace()
		let result = await workspace.call(
			"change_signature", #"{"name":"UserService.create(name:)","operations":[{"op":"add","param":"admin: Bool = false"}],"verify":"none"}"#)
		#expect(!result.isError)
		#expect(result.contains("rewrote 0 call site(s)"))
		#expect(try workspace.read("Sources/SampleApp/main.swift").contains("service.create(name: \"Ada\")"))
		#expect(try workspace.read("Sources/SampleKit/UserService.swift").contains("create(name: String, admin: Bool = false)"))
		await workspace.finish()
	}

	@Test func aWitnessIsChangedTogetherWithTheRequirementItImplements() async throws {
		let workspace = try Workspace()
		let result = await workspace.call(
			"change_signature",
			#"{"name":"PoliteGreeter.greet(_:loudly:)","operations":[{"op":"reorder","order":["loudly","_"]}],"verify":"none"}"#)
		#expect(!result.isError)
		#expect(result.contains("implements Greeter.greet(_:loudly:)"))
		#expect(try workspace.read("Sources/SampleKit/Ports.swift").contains("func greet(loudly: Bool, _ name: String) -> String"))
		#expect(try workspace.read("Sources/SampleApp/main.swift").contains("greet(loudly: true, user.name)"))
		await workspace.finish()
	}

	@Test func aChangeThatNeedsAHumanIsRefusedWithTheCompilersErrors() async throws {
		let workspace = try Workspace()
		let result = await workspace.call(
			"change_signature", #"{"name":"PoliteGreeter.greet(_:loudly:)","operations":[{"op":"remove","param":"loudly"}],"verify":"none"}"#)
		#expect(result.isError)
		#expect(result.contains("Invalid redeclaration") || result.contains("Cannot find 'loudly'"))
		#expect(try workspace.read("Sources/SampleKit/Stores.swift").contains("loudly: Bool"))
		let bad = await workspace.call("change_signature", #"{"name":"UserService.create(name:)","operations":[{"op":"remove","param":"nope"}]}"#)
		#expect(bad.isError && bad.contains("no parameter 'nope'"))
		let missingValue = await workspace.call("change_signature", #"{"name":"UserService.create(name:)","operations":[{"op":"add","param":"x: Int"}]}"#)
		#expect(missingValue.isError && missingValue.contains("call_value"))
		await workspace.finish()
	}

	// MARK: fix_diagnostics, add_conformance, refactor

	@Test func compilerFixItsAreAppliedAndWhatRemainsIsReported() async throws {
		let workspace = try Workspace()
		try workspace.write("Sources/SampleKit/Sw.swift", "public func describe(_ r: Role) -> Int {\n\tswitch r {\n\tcase .admin: return 1\n\t}\n}\n")
		let result = await workspace.call("fix_diagnostics", #"{"file_path":"Sources/SampleKit/Sw.swift","require":"none"}"#)
		#expect(!result.isError)
		#expect(result.contains("Add missing case"))
		let fixed = try workspace.read("Sources/SampleKit/Sw.swift")
		#expect(fixed.contains("\tcase .guest:"))
		#expect(!fixed.contains("break\n\n"))
		let nothing = await workspace.call("fix_diagnostics", #"{"file_path":"Sources/SampleKit/Models.swift"}"#)
		#expect(nothing.contains("nothing in this file that has a fix-it"))
		await workspace.finish()
	}

	@Test func conformancesGetCompilableStubsInTheFilesStyle() async throws {
		let workspace = try Workspace()
		let extensionResult = await workspace.call("add_conformance", #"{"type":"Dog","protocol":"Greeter","verify":"none"}"#)
		#expect(!extensionResult.isError)
		let models = try workspace.read("Sources/SampleKit/Models.swift")
		#expect(models.contains("extension Dog: Greeter {\n\tpublic func greet(_ name: String) -> String {\n\t\tfatalError(\"Not implemented\")\n\t}"))
		#expect(!models.contains("\n\n}\n\npublic enum Outer"))

		try workspace.write("Sources/SampleKit/Pet.swift", "public struct Pet {\n\tpublic var name: String\n}\n")
		let inline = await workspace.call("add_conformance", #"{"type":"Pet","protocol":"Hashable","inline":true,"verify":"none"}"#)
		#expect(!inline.isError)
		#expect(try workspace.read("Sources/SampleKit/Pet.swift").hasPrefix("public struct Pet: Hashable {"))

		let separate = await workspace.call(
			"add_conformance", #"{"type":"Pet","protocol":"CustomStringConvertible","extension_file":"Sources/SampleKit/Pet+Description.swift","verify":"none"}"#)
		#expect(!separate.isError)
		#expect(try workspace.read("Sources/SampleKit/Pet+Description.swift").contains("extension Pet: CustomStringConvertible {"))
		await workspace.finish()
	}

	@Test func refactoringsAreListedAndRunWithTidyOutput() async throws {
		let workspace = try Workspace()
		let listed = await workspace.call("refactor", #"{"file_path":"Sources/SampleKit/UserService.swift","line":11,"selection":"User(id: name.count, name: name)"}"#)
		#expect(listed.contains("Extract Method"))
		let extracted = await workspace.call(
			"refactor",
			#"{"file_path":"Sources/SampleKit/UserService.swift","line":11,"selection":"User(id: name.count, name: name)","action":"Extract Method","new_name":"makeUser","verify":"none"}"#)
		#expect(!extracted.isError)
		let service = try workspace.read("Sources/SampleKit/UserService.swift")
		#expect(service.contains("\tfileprivate func makeUser(_ name: String) -> User {\n\t\treturn User(id: name.count, name: name)\n\t}\n\n\t/// Creates a user and saves it."))
		#expect(service.contains("let user = makeUser(name)"))
		let unknown = await workspace.call("refactor", #"{"file_path":"Sources/SampleKit/UserService.swift","line":11,"action":"Reticulate Splines"}"#)
		#expect(unknown.isError)
		await workspace.finish()
	}

	// MARK: the build tier

	@Test(.enabled(if: EditingIntegrationTests.canBuild))
	func codeInDependentModulesIsCompiledByARealBuild() async throws {
		let workspace = try Workspace()
		// Inside the module nothing is wrong; the app and the tests (other modules) can no longer see it.
		let edit = #"{"file_path":"Sources/SampleKit/UserService.swift","old_text":"public func create(name: String)","new_text":"func create(name: String)"}"#
		let dryRun = await workspace.call("check_edit", String(edit.dropLast()) + #","verify":"build"}"#)
		#expect(dryRun.contains("✓ no new errors"))
		#expect(dryRun.contains("Not checked in memory"))
		#expect(dryRun.contains("inaccessible due to 'internal'"))
		#expect(try workspace.read("Sources/SampleKit/UserService.swift").contains("public func create(name: String)"))

		let refused = await workspace.call("apply_edit", edit)
		#expect(refused.isError)
		#expect(refused.contains("every file was put back"))
		#expect(try workspace.read("Sources/SampleKit/UserService.swift").contains("public func create(name: String)"))

		let renamed = await workspace.call("rename_symbol", #"{"name":"UserService.create(name:)","new_name":"make(named:)"}"#)
		#expect(!renamed.isError)
		#expect(renamed.contains("Build (swift build --build-tests"))
		#expect(renamed.contains("✓ succeeded"))

		let verified = await workspace.call("verify", #"{"tests":true}"#)
		#expect(verified.contains("✓ succeeded"))
		#expect(verified.contains("Tests (swift test"))
		#expect(!verified.contains("✗"))
		await workspace.finish()
	}

	@Test(.enabled(if: EditingIntegrationTests.canBuild))
	func affectedTestsFollowCallsFromTheTests() async throws {
		let workspace = try Workspace()
		let direct = await workspace.call("affected_tests", #"{"name":"UserService.create(name:)"}"#)
		#expect(direct.contains("createsUser()"))
		#expect(direct.contains("swift test --filter 'createsUser'"))
		let throughCalls = await workspace.call("affected_tests", #"{"name":"UserStore.save(_:)"}"#)
		#expect(throughCalls.contains("createsUser()"))
		let none = await workspace.call("affected_tests", #"{"name":"Role"}"#)
		#expect(none.contains("No test found"))
		await workspace.finish()
	}

	@Test(.enabled(if: EditingIntegrationTests.canBuild))
	func verifyReportsBuildErrorsWithLocations() async throws {
		let workspace = try Workspace()
		try workspace.write("Sources/SampleKit/Oops.swift", "public func oops() -> Int { \"not an int\" }\n")
		let result = await workspace.call("verify", "{}")
		#expect(result.contains("✗ failed"))
		#expect(result.contains("Sources/SampleKit/Oops.swift:1:"))
		await workspace.finish()
	}
}

@Suite struct WriteToolCatalogTests {
	@Test func writeToolsAreOptInAndAnnotatedByTheCatalog() async {
		let names = ToolCatalog.writeTools.map(\.name)
		#expect(names == [
			"edit_symbol", "insert_member", "delete_symbol", "move_symbol", "rename_symbol", "change_signature", "fix_diagnostics", "refactor",
			"add_conformance", "check_edit", "apply_edit", "undo_edit",
		])
		#expect(ToolCatalog.analysisTools.map(\.name) == ["verify", "affected_tests"])
		#expect(Set(ToolCatalog.tools.map(\.name)).count == ToolCatalog.tools.count)
		let navigator = SwiftNavigator(environment: [:], currentDirectory: FileManager.default.temporaryDirectory)
		let refused = await ToolCatalog.call("apply_edit", arguments: ToolArguments(["file_path": "a.swift", "old_text": "x", "new_text": "y"]), navigator: navigator, writesEnabled: false)
		#expect(refused.isError)
		#expect(refused.contains("CODENAV_SWIFT_WRITE=1"))
		// Read tools stay available either way.
		let workspace = await ToolCatalog.call("workspace", arguments: ToolArguments([:]), navigator: navigator, writesEnabled: false)
		#expect(workspace.contains("write tools: off"))
	}

	@Test func everyToolHasADescriptionAndWellFormedParameters() {
		for tool in ToolCatalog.tools {
			#expect(tool.description.count > 40, "\(tool.name) needs a real description")
			#expect(Set(tool.parameters.map(\.name)).count == tool.parameters.count, "\(tool.name) repeats a parameter")
			for parameter in tool.parameters { #expect(!parameter.description.isEmpty, "\(tool.name).\(parameter.name)") }
		}
		for name in ToolCatalog.writeToolNames.subtracting(["undo_edit"]) {
			let tool = ToolCatalog.tools.first { $0.name == name }
			#expect(tool?.parameters.contains { $0.name == "dry_run" } == true || name == "apply_edit" || name == "check_edit", "\(name) should offer dry_run")
		}
	}
}
