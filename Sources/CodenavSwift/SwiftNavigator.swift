import Foundation
import NavShared

/// The code-navigation tools, backed by sourcekit-lsp. Every tool returns text and never throws:
/// expected failures (bad path, ambiguous name, ...) are rendered for the agent to act on.
public actor SwiftNavigator {
	/// Supplies the MCP client's workspace roots (`file://` URIs); empty when it has none.
	public typealias RootsProvider = @Sendable () async -> [String]

	public static let workspaceEnvironmentKey = "CODENAV_SWIFT_WORKSPACE"
	public static let indexTimeoutEnvironmentKey = "CODENAV_SWIFT_INDEX_TIMEOUT"
	static let defaultIndexTimeout: TimeInterval = 30
	static let maxTypeLocations = 3
	static let maxSubtypesVisited = 300

	public nonisolated let notices: NoticeBoard
	private let environment: [String: String]
	private let selector: WorkspaceSelector
	private let rootsProvider: RootsProvider?
	private let indexTimeout: TimeInterval
	private let commandOverride: [String]?

	private var workspaceRoot: URL
	private var workspaceSource: String
	private var projectKind: ProjectKind
	private var client: LSPClient?
	private var startingClient: Task<LSPClient, Error>?

	public init(
		environment: [String: String] = ProcessInfo.processInfo.environment,
		currentDirectory: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath),
		rootsProvider: RootsProvider? = nil,
		notices: NoticeBoard = NoticeBoard(serverName: "codenav-swift"),
		languageServerCommand: [String]? = nil
	) {
		self.environment = environment
		self.rootsProvider = rootsProvider
		self.notices = notices
		self.commandOverride = languageServerCommand
		selector = WorkspaceSelector(
			explicitEnv: Self.workspaceEnvironmentKey, environment: environment, currentDirectory: currentDirectory
		)
		workspaceRoot = selector.base
		workspaceSource = selector.baseSource
		projectKind = ProjectKind.detect(in: selector.base)
		indexTimeout = environment[Self.indexTimeoutEnvironmentKey].flatMap(TimeInterval.init) ?? Self.defaultIndexTimeout
	}

	// MARK: - Workspace and client lifecycle

	/// Starts the language server ahead of the first tool call, so background indexing is already
	/// underway by the time an agent asks something. Skipped for directories with no Swift project.
	public func warmUp() async {
		await useWorkspace()
		guard projectKind.isNavigable else { return }
		_ = try? await liveClient()
	}

	/// Called first by every tool: re-targets the server when the client reports another
	/// checkout/worktree of the same repository.
	private func useWorkspace() async {
		let roots = selector.pinned ? [] : await (rootsProvider?() ?? [])
		let selection = selector.select(clientRootURIs: roots)
		guard selection.root != workspaceRoot else { return }
		await stopClient()
		workspaceRoot = selection.root
		workspaceSource = selection.source
		projectKind = ProjectKind.detect(in: selection.root)
	}

	private func stopClient() async {
		startingClient?.cancel()
		startingClient = nil
		if let client { await client.stop() }
		client = nil
	}

	private func liveClient() async throws -> LSPClient {
		if let existing = client {
			if await existing.isAlive {
				try await existing.refresh()
				return existing
			}
			await existing.stop()  // reap the dead server instead of leaking it
			client = nil
		}
		if let starting = startingClient {
			let started = try await starting.value
			try await started.refresh()
			return started
		}
		let root = workspaceRoot
		let notices = notices
		let command = try commandOverride ?? SourceKitLSPLocator.command(environment: environment)
		let configuration = LSPClient.Configuration(
			workspaceRoot: root,
			command: command,
			languageID: "swift",
			watchSuffixes: [".swift"],
			// sourcekit-lsp reads these once at startup. (Package.swift is a watched .swift file:
			// it reloads the package itself, with no restart.)
			configNames: ["buildServer.json", "compile_commands.json", "compile_flags.txt"],
			environment: nil
		)
		let task = Task { () -> LSPClient in
			let newClient = LSPClient(configuration: configuration, onNotice: { notices.post($0) })
			try await newClient.start()
			return newClient
		}
		startingClient = task
		do {
			let started = try await task.value
			client = started
			startingClient = nil
			if let advice = projectKind.advice { notices.post(advice) }
			try await started.refresh()
			return started
		} catch {
			startingClient = nil
			throw error
		}
	}

	/// Waits for background indexing so references/callers/implementations are complete; says so
	/// when it is still running after the timeout, since those answers are then silently partial.
	private func awaitIndex(_ client: LSPClient) async {
		let status = await client.waitForIndex(timeout: indexTimeout)
		guard !status.isReady else { return }
		let detail = status.detail.map { " (\($0))" } ?? ""
		notices.post(
			"the index is still being built\(detail); references, callers and implementations may be incomplete. Retry in a bit."
		)
	}

	private func checkSwiftFile(_ filePath: String) throws {
		guard (filePath as NSString).pathExtension.lowercased() == "swift" else {
			throw ToolInputError("codenav-swift only supports Swift files (.swift), got '\(filePath)'")
		}
	}

	/// Runs a tool body, turning any failure into text and appending pending notices.
	func run(_ body: () async throws -> String) async -> String {
		let text: String
		do {
			text = try await body()
		} catch let error as SymbolResolutionError {
			text = error.message
		} catch {
			text = formatToolError(error)
		}
		return notices.annotate(text)
	}

	private func relative(_ uri: String) -> String {
		uriToRelative(uri, workspaceRoot: workspaceRoot)
	}

	private func path(of uri: String) throws -> String {
		guard let path = uriToPath(uri) else {
			throw ToolInputError("'\(uri)' is not a local file.")
		}
		return path
	}

	// MARK: - Tools

	public func workspace() async -> String {
		await run {
			await useWorkspace()
			var lines = [
				workspaceRoot.path,
				"chosen because: \(selector.explain(workspaceSource))",
				"project: \(projectKind.summary)",
			]
			if let command = try? commandOverride ?? SourceKitLSPLocator.command(environment: environment) {
				lines.append("language server: \(command.joined(separator: " "))")
			}
			if let client, await client.isAlive {
				let state = await client.indexProgressDescription().map { "indexing: \($0)" } ?? "ready"
				lines.append("index: \(state)")
				let errors = await client.recentErrors
				if !errors.isEmpty {
					lines.append("recent language-server errors (a failed background build explains empty results):")
					lines += errors.map { "  \($0)" }
				}
			} else {
				lines.append("language server: not started yet (it starts on the first navigation call)")
			}
			return lines.joined(separator: "\n")
		}
	}

	public func hover(filePath: String, line: Int, column: Int) async -> String {
		await run {
			await useWorkspace()
			try checkSwiftFile(filePath)
			let client = try await liveClient()
			var text = try await client.hover(filePath, line: line, column: column)
			if !text.isEmpty { text = await enrichVariableType(text, client: client, filePath: filePath, line: line, column: column) }
			return text.isEmpty ? "No hover information at that position." : text
		}
	}

	public func definition(filePath: String, line: Int, column: Int) async -> String {
		await run {
			await useWorkspace()
			try checkSwiftFile(filePath)
			let client = try await liveClient()
			let locations = try await client.definition(filePath, line: line, column: column)
			if locations.isEmpty { return "No definition found at that position." }
			return locations.map { formatLocation($0, workspaceRoot: workspaceRoot) }.joined(separator: "\n\n")
		}
	}

	public func references(filePath: String, line: Int, column: Int, includeDeclaration: Bool = true) async -> String {
		await run {
			await useWorkspace()
			try checkSwiftFile(filePath)
			let client = try await liveClient()
			await awaitIndex(client)
			let locations = try await client.references(
				filePath, line: line, column: column, includeDeclaration: includeDeclaration
			)
			return formatReferences(locations, workspaceRoot: workspaceRoot)
		}
	}

	public func searchSymbol(
		query: String?, name: String?, kind: String?, path: String?, fuzzy: Bool = false
	) async -> String {
		await run {
			await useWorkspace()
			let kinds = try parseKindFilter(kind)
			let query = try resolveNameQuery(preferred: "query", example: "UserService", ["query": query, "name": name])
			let client = try await liveClient()
			// sourcekit-lsp matches plain names; `Type.member` is that member name filtered by container.
			let parsed = Self.splitQualified(query)
			var symbols = try await client.workspaceSymbol(parsed.name)
			if !parsed.container.isEmpty {
				let wanted = parsed.container.joined(separator: ".")
				symbols = symbols.filter { symbol in
					guard let container = symbol.containerName else { return false }
					return container == wanted || container.hasSuffix("." + wanted)
				}
			}
			if symbols.isEmpty { return "No symbols matching '\(query)'." }
			let matching = filterSymbols(symbols, workspaceRoot: workspaceRoot, kinds: kinds, path: path)
			if matching.isEmpty {
				let filters = [("kind", kind), ("path", path)].compactMap { key, value in
					value.map { "\(key)='\($0)'" }
				}.joined(separator: ", ")
				return "No symbols matching '\(query)' with \(filters) (\(symbols.count) without the filters)."
			}
			let listing = formatWorkspaceSymbols(matching, workspaceRoot: workspaceRoot, query: parsed.name, fuzzy: fuzzy)
			return listing.isEmpty ? "No symbols matching '\(query)'." : listing
		}
	}

	/// `Outer.Inner.member(label:)` -> (["Outer", "Inner"], "member(label:)").
	static func splitQualified(_ query: String) -> (container: [String], name: String) {
		let parsed = ParsedQuery(query)
		return (parsed.container, parsed.base + (parsed.signature ?? ""))
	}

	public func diagnostics(filePath: String) async -> String {
		await run {
			await useWorkspace()
			try checkSwiftFile(filePath)
			let client = try await liveClient()
			return formatDiagnostics(try await client.diagnostics(filePath))
		}
	}

	public func symbolInfo(name: String?, query: String?, filePath: String?, includeReferences: Bool = true) async -> String {
		await run {
			await useWorkspace()
			let name = try resolveNameQuery(preferred: "name", example: "UserService.create(name:)", ["name": name, "query": query])
			let client = try await liveClient()
			let resolved = try await resolveSymbol(client: client, workspaceRoot: workspaceRoot, query: name, filePath: filePath)
			let relativePath = relative(resolved.uri)
			let file = try path(of: resolved.uri)
			let line = resolved.line + 1
			let column = resolved.column + 1
			let hoverText = try await client.hover(file, line: line, column: column)
			let definitions = try await client.definition(file, line: line, column: column)
			var references: [LSPLocation] = []
			if includeReferences {
				await awaitIndex(client)
				references = try await client.references(file, line: line, column: column)
			}
			let header = "\(resolved.qualifiedName)  [\(SymbolKind.label(resolved.kind))]  (\(relativePath):\(line):\(column))"
			var parts = [header, "", hoverText.isEmpty ? "No hover information." : hoverText]
			if SymbolKind.types.contains(resolved.kind), let supers = try? await supertypeLine(client, file: file, line: line, column: column) {
				parts += ["", supers]
			}
			parts += [
				"", "Definition:",
				definitions.isEmpty
					? "No definition found."
					: definitions.map { formatLocation($0, workspaceRoot: workspaceRoot) }.joined(separator: "\n\n"),
			]
			if includeReferences {
				parts += ["", "References:", formatReferencesGrouped(references, workspaceRoot: workspaceRoot)]
			}
			return parts.joined(separator: "\n")
		}
	}

	/// `Inherits / conforms to: Identifiable, Equatable, Sendable` for a type; nil when it has none
	/// the server can report.
	private func supertypeLine(_ client: LSPClient, file: String, line: Int, column: Int) async throws -> String? {
		var names: [String] = []
		for item in try await client.prepareTypeHierarchy(file, line: line, column: column) {
			names += try await client.supertypes(item).map(\.name)
		}
		let unique = names.reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
		return unique.isEmpty ? nil : "Inherits / conforms to: " + unique.joined(separator: ", ")
	}

	public func outline(filePath: String) async -> String {
		await run {
			await useWorkspace()
			try checkSwiftFile(filePath)
			let client = try await liveClient()
			return formatOutline(try await client.documentSymbol(filePath))
		}
	}

	public func callers(name: String?, query: String?, filePath: String?) async -> String {
		await run {
			await useWorkspace()
			let name = try resolveNameQuery(preferred: "name", example: "UserService.create(name:)", ["name": name, "query": query])
			let client = try await liveClient()
			let resolved = try await resolveSymbol(client: client, workspaceRoot: workspaceRoot, query: name, filePath: filePath)
			let file = try path(of: resolved.uri)
			await awaitIndex(client)
			let items = try await client.prepareCallHierarchy(file, line: resolved.line + 1, column: resolved.column + 1)
			guard let item = items.first else {
				return "\(resolved.name) has no call hierarchy entry at that position (it may not be a callable)."
			}
			return formatCallers(try await client.incomingCalls(item), workspaceRoot: workspaceRoot)
		}
	}

	/// Types that conform to a protocol / inherit from a class (transitively, through refining
	/// protocols and subclasses), or the members that implement or override a protocol requirement /
	/// class member.
	public func implementations(name: String?, query: String?, portName: String?, filePath: String?) async -> String {
		await run {
			await useWorkspace()
			let name = try resolveNameQuery(
				preferred: "name", example: "UserStore", ["name": name, "query": query, "port_name": portName]
			)
			let client = try await liveClient()
			let resolved = try await resolveSymbol(client: client, workspaceRoot: workspaceRoot, query: name, filePath: filePath)
			let file = try path(of: resolved.uri)
			await awaitIndex(client)
			let line = resolved.line + 1
			let column = resolved.column + 1
			if SymbolKind.types.contains(resolved.kind) {
				return try await formatSubtypes(of: resolved, client: client, file: file, line: line, column: column)
			}
			let locations = try await client.implementation(file, line: line, column: column)
				.filter { !($0.uri == resolved.uri && $0.range.start.line == resolved.line) }
			if locations.isEmpty { return "No implementations or overrides of \(resolved.qualifiedName) found." }
			let heading = "\(locations.count) implementation(s) of \(resolved.qualifiedName):"
			return heading + "\n\n" + locations.map { formatLocation($0, workspaceRoot: workspaceRoot) }.joined(separator: "\n\n")
		}
	}

	private func formatSubtypes(
		of resolved: ResolvedSymbol, client: LSPClient, file: String, line: Int, column: Int
	) async throws -> String {
		struct Entry {
			var depth: Int
			var text: String
		}
		var entries: [Entry] = []
		var seen: Set<String> = []
		var visited = 0
		let roots = try await client.prepareTypeHierarchy(file, line: line, column: column)

		// Iterative pre-order walk: a stack of not-yet-recorded subtypes.
		var stack: [(item: HierarchyItem, depth: Int)] = []
		for root in roots.reversed() {
			stack.append(contentsOf: try await client.subtypes(root).reversed().map { (item: $0, depth: 0) })
		}
		while let (sub, depth) = stack.popLast() {
			guard visited < Self.maxSubtypesVisited else { break }
			guard seen.insert("\(sub.uri)#\(sub.name)#\(sub.selectionRange.start.line)").inserted else { continue }
			visited += 1
			let position = "\(relative(sub.uri)):\(sub.selectionRange.start.line + 1):\(sub.selectionRange.start.character + 1)"
			if Self.isExtensionConformance(sub) {
				// `Type: Protocol` declared in an extension; sourcekit-lsp has no item for the type itself here.
				let typeName = sub.name.components(separatedBy: ":").first ?? sub.name
				entries.append(Entry(depth: depth, text: "\(typeName)  [conformance in extension]  (\(position))"))
			} else {
				entries.append(Entry(depth: depth, text: "\(sub.name)  [\(SymbolKind.label(sub.kind))]  (\(position))"))
				stack.append(contentsOf: try await client.subtypes(sub).reversed().map { (item: $0, depth: depth + 1) })
			}
		}

		let verb = resolved.kind == SymbolKind.protocol ? "conform to or refine" : "inherit from"
		if entries.isEmpty {
			// Without a type hierarchy the conformance sites are still known.
			let sites = try await client.implementation(file, line: line, column: column)
			if sites.isEmpty { return "No types \(verb) \(resolved.qualifiedName)." }
			return "\(sites.count) site(s) that \(verb) \(resolved.qualifiedName):\n\n"
				+ sites.map { formatLocation($0, workspaceRoot: workspaceRoot) }.joined(separator: "\n\n")
		}
		let list = entries.map { String(repeating: "  ", count: $0.depth) + $0.text }
		let note = visited >= Self.maxSubtypesVisited ? "\n… stopped after \(Self.maxSubtypesVisited) types" : ""
		return "\(entries.count) type(s) \(verb) \(resolved.qualifiedName):\n" + list.joined(separator: "\n") + note
	}

	/// sourcekit-lsp reports `extension Foo: Bar` conformances as a hierarchy item named `Foo: Bar`
	/// with kind `Null` and an "Extension at File.swift:N" detail.
	static func isExtensionConformance(_ item: HierarchyItem) -> Bool {
		item.name.contains(": ") && (item.detail ?? "").hasPrefix("Extension")
	}

	// MARK: - Hover enrichment

	/// A variable's hover is just its declaration (`let user: User`), which says nothing about where
	/// the type lives. Add the type's definition site, its header line and the first line of its doc comment.
	private func enrichVariableType(_ text: String, client: LSPClient, filePath: String, line: Int, column: Int) async -> String {
		guard Self.isVariableHover(text) else { return text }
		guard let locations = try? await client.typeDefinition(filePath, line: line, column: column) else { return text }
		let described =
			locations
			.filter { !$0.uri.contains("/sourcekit-lsp/GeneratedInterfaces/") && !$0.uri.contains(".sdk/") }
			.prefix(Self.maxTypeLocations)
			.map(describeTypeDefinition)
		return described.isEmpty ? text : ([text] + described).joined(separator: "\n")
	}

	static func isVariableHover(_ text: String) -> Bool {
		guard text.count < 400 else { return false }
		let declaration = text.replacingOccurrences(of: "```swift", with: "").replacingOccurrences(of: "```", with: "")
			.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !declaration.contains("\n\n") else { return false }  // has prose: a documented declaration
		return declaration.range(
			of: #"^((public|internal|private|fileprivate|open|static|final|lazy|weak|unowned|nonisolated|@\w+(\([^)]*\))?)\s+)*(let|var)\s"#,
			options: .regularExpression
		) != nil
	}

	private func describeTypeDefinition(_ location: LSPLocation) -> String {
		let position = location.range.start
		var lines = ["Type defined at \(relative(location.uri)):\(position.line + 1):\(position.character + 1)"]
		guard let source = readLines(of: location.uri), position.line < source.count else { return lines.joined(separator: "\n") }
		lines.append("  " + source[position.line].trimmingCharacters(in: .whitespaces))
		var index = position.line - 1
		while index >= 0, source[index].trimmingCharacters(in: .whitespaces).hasPrefix("@") { index -= 1 }  // attributes
		var doc: [String] = []
		while index >= 0, source[index].trimmingCharacters(in: .whitespaces).hasPrefix("///") {
			doc.insert(source[index].trimmingCharacters(in: .whitespaces), at: 0)
			index -= 1
		}
		if let first = doc.first(where: { !$0.dropFirst(3).trimmingCharacters(in: .whitespaces).isEmpty }) {
			lines.append("  " + first)
		}
		return lines.joined(separator: "\n")
	}
}
