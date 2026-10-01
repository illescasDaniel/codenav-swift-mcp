import Foundation
import NavShared

/// The code-navigation tools, backed by sourcekit-lsp. Every tool returns text and never throws:
/// expected failures (bad path, ambiguous name, ...) are rendered for the agent to act on.
public actor SwiftNavigator {
	/// Supplies the MCP client's workspace roots (`file://` URIs); empty when it has none.
	public typealias RootsProvider = @Sendable () async -> [String]

	public static let workspaceEnvironmentKey = "CODENAV_SWIFT_WORKSPACE"
	public static let indexTimeoutEnvironmentKey = "CODENAV_SWIFT_INDEX_TIMEOUT"
	static let clangExtensions: Set<String> = ["m", "mm", "h", "c", "cc", "cpp", "cxx", "hpp"]
	public static let localPackageFoldersEnvironmentKey = "CODENAV_SWIFT_LOCAL_PACKAGE_FOLDERS"
	public static let requestTimeoutEnvironmentKey = "CODENAV_SWIFT_REQUEST_TIMEOUT"
	static let defaultRequestTimeout: TimeInterval = 60
	static let defaultIndexTimeout: TimeInterval = 30
	static let maxTypeLocations = 3
	static let defaultDependencyHits = 10
	static let maxSubtypesVisited = 300

	public nonisolated let notices: NoticeBoard
	private let environment: [String: String]
	private let selector: WorkspaceSelector
	private let rootsProvider: RootsProvider?
	private let indexTimeout: TimeInterval
	private let requestTimeout: TimeInterval
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
		requestTimeout = environment[Self.requestTimeoutEnvironmentKey].flatMap(TimeInterval.init).flatMap { $0 > 0 ? $0 : nil }
			?? Self.defaultRequestTimeout
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
		let selection = selector.select(clientRootURIs: roots, isProject: { ProjectKind.detect(in: $0).isNavigable })
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
		try requireProject()
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
			environment: nil,
			requestTimeout: requestTimeout,
			// Registering a sibling package makes sourcekit-lsp build and index it on its own (a second,
			// separate index and a `.build` inside that package), so it is opt-in.
			extraWorkspaceFolders: environment[Self.localPackageFoldersEnvironmentKey] == "1"
				? ProjectKind.localPackageFolders(in: root) : []
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
			if let advice = projectKind.advice(in: root) { notices.post(advice) }
			let setup = ProjectKind.buildSettingsProblems(in: root)
			if !setup.isEmpty { notices.post("build settings look incomplete: " + setup.joined(separator: " ")) }
			try await started.refresh()
			return started
		} catch {
			startingClient = nil
			throw error
		}
	}

	/// Starting sourcekit-lsp in `$HOME` or a folder with no Swift in it would index the wrong tree for
	/// minutes and answer nothing useful: say what to do instead.
	private func requireProject() throws {
		guard projectKind == .none else { return }
		let looseSwift = !WorkspaceSelector.isHomeOrRoot(workspaceRoot) && ProjectKind.hasLooseSwiftFiles(in: workspaceRoot)
		if looseSwift { return }
		throw ToolInputError(
			"No Swift project at \(workspaceRoot.path) (chosen because: \(selector.explain(workspaceSource)))."
				+ ProjectKind.nestedAdvice(ProjectKind.nestedProjects(in: workspaceRoot))
				+ " Set CODENAV_SWIFT_WORKSPACE to the package/project root (an absolute path), or start the MCP client there."
		)
	}

	/// Waits for background indexing so references/callers/implementations are complete; says so
	/// when it is still running after the timeout, since those answers are then silently partial.
	private func awaitIndex(_ client: LSPClient) async {
		let status = await client.waitForIndex(timeout: indexTimeout)
		guard !status.isReady else { return }
		let detail = status.detail.map { " (\($0))" } ?? ""
		notices.post(
			"the index is still being built\(detail); references, callers, implementations and symbol search may be incomplete. Retry in a bit."
		)
	}

	/// Name lookups (`workspace/symbol`) answer from the index too, so a query right after startup or
	/// after files changed on disk would otherwise return stale or empty results.
	private func awaitIndexIfBusy(_ client: LSPClient) async {
		await awaitIndex(client)
	}

	/// Validates the extension and turns a displayed `<dependency> Pkg/...` spelling back into a real path.
	@discardableResult
	private func checkSwiftFile(_ filePath: String) throws -> String {
		let ext = (filePath as NSString).pathExtension.lowercased()
		guard ext == "swift" || Self.clangExtensions.contains(ext) else {
			throw ToolInputError(
				"codenav-swift supports Swift files (.swift) and the C-family sources of a mixed project (.m, .mm, .h, .c, .cpp), got '\(filePath)'"
			)
		}
		return DependencyRoots.expand(filePath, extra: dependencyCheckoutDirectories())
	}

	/// Where dependency checkouts can live for this workspace, for resolving `<dependency> ...` paths
	/// before any result has shown one: SwiftPM's `.build/checkouts`, and an Xcode build root's `SourcePackages`.
	private func dependencyCheckoutDirectories() -> [String] {
		var directories = [workspaceRoot.appendingPathComponent(".build/checkouts").path]
		if let data = try? Data(contentsOf: workspaceRoot.appendingPathComponent("buildServer.json")),
			let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
			let buildRoot = json["build_root"] as? String
		{
			directories.append(buildRoot + "/SourcePackages/checkouts")
		}
		return directories
	}

	/// Directories whose sources a text scan covers: the project and its local sibling packages.
	/// For a symbol declared in a dependency checkout, the checkout's own package is scanned too: the
	/// index doesn't know how that package uses its own declarations (its types conforming to its protocols).
	private func scanRoots(declaredIn uri: String) -> [URL] {
		var roots = [workspaceRoot] + ProjectKind.localPackageFolders(in: workspaceRoot)
		if let path = uriToPath(uri), let range = path.range(of: "/checkouts/") {
			let rest = path[range.upperBound...]
			if let package = rest.split(separator: "/").first {
				roots.append(URL(fileURLWithPath: String(path[..<range.upperBound]) + package, isDirectory: true))
			}
		}
		return roots
	}

	/// Runs a tool body, turning any failure into text and appending pending notices.
	func run(_ body: () async throws -> String) async -> ToolResult {
		let text: String
		var failed = false
		do {
			text = try await body()
		} catch let error as SymbolResolutionError {
			text = error.message
			failed = true
		} catch {
			text = formatToolError(error)
			failed = true
		}
		return ToolResult(notices.annotate(text), isError: failed)
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

	/// What explains an empty or "not found" answer when the cause isn't the question: a failed
	/// background build, or a workspace with no build description.
	private func emptyResultHint(_ client: LSPClient) async -> String {
		var parts: [String] = []
		if let first = await client.recentErrors.first {
			parts.append(
				"The language server's background build failed (\(first.prefix(240))), which leaves results empty or partial until the project compiles. `workspace` shows the details."
			)
		}
		if projectKind == .none, let advice = projectKind.advice(in: workspaceRoot) { parts.append(advice) }
		let setup = ProjectKind.buildSettingsProblems(in: workspaceRoot)
		if !setup.isEmpty { parts.append("Build settings look incomplete: " + setup.joined(separator: " ")) }
		return parts.isEmpty ? "" : "\n\n" + parts.joined(separator: "\n")
	}

	/// The 1-indexed column to query: `column` itself, or where `symbol` first appears on the line.
	private func resolveColumn(_ client: LSPClient, filePath: String, line: Int, column: Int?, symbol: String?) async throws -> Int {
		if let column { return column }
		guard let symbol else {
			throw ToolInputError("Pass `column` (1-indexed) or `symbol` (the identifier's text on that line).")
		}
		let text = try readTextFile(await client.resolve(filePath))
		return try PositionResolver.column(of: symbol, onLine: line, in: text, filePath: filePath)
	}

	/// A symbol picked by name, or by the line/identifier it appears on.
	private struct Target {
		var symbol: ResolvedSymbol
		var note: String?
	}

	static let maxListedSites = 25

	private func isOutsideWorkspace(_ uri: String) -> Bool {
		guard let path = uriToPath(uri) else { return true }
		return relativePath(path, in: workspaceRoot) == nil
	}

	/// The declaration the symbol at a position resolves to.
	private func declaration(_ client: LSPClient, file: String, line: Int, column: Int) async -> LSPLocation? {
		try? await client.definition(file, line: line, column: column).first
	}

	/// References for a symbol, plus occurrences matched by name only (`unverified`).
	struct References {
		var locations: [LSPLocation]
		var unverified: [LSPLocation] = []
	}

	/// Where an occurrence's module comes from, when the declaration sits in a package's `Sources/<Target>/`:
	/// a Swift file elsewhere can only use it by importing that module, which cheaply drops most candidates.
	private func moduleToRequire(forDeclarationAt uri: String) -> String? {
		guard isOutsideWorkspace(uri) || isDependencyPath(uri),
			let path = uriToPath(uri)
		else { return nil }
		return PositionResolver.moduleName(ofPath: path)
	}

	/// Objective-C spellings of the Swift method declared at `origin` (an `@objc(selector:)` or the usual guesses).
	private func objcAliases(declaredAt origin: LSPLocation, word: String) -> [String] {
		guard let lines = readLines(of: origin.uri) else { return [] }
		return PositionResolver.objcAliases(declaredAt: origin.range.start.line, in: lines, word: word)
	}

	/// References for the symbol at a position. The index is complete for what the project itself compiles,
	/// but thin for a declaration in a sibling package or a dependency checkout (it sometimes reports only the
	/// declaration). In those cases the answer is completed by scanning the sources for the name and asking
	/// the server which occurrences resolve to this declaration (`UsageScan`).
	private func referencesWithUsageFallback(
		_ client: LSPClient, file: String, line: Int, column: Int, includeDeclaration: Bool = true
	) async throws -> References {
		let direct = try await client.references(file, line: line, column: column, includeDeclaration: includeDeclaration)
		guard let text = try? readTextFile(URL(fileURLWithPath: file)),
			let word = PositionResolver.word(at: column, onLine: line, in: text),
			let origin = await declaration(client, file: file, line: line, column: column),
			direct.count <= 1 || isOutsideWorkspace(origin.uri)
		else { return References(locations: direct) }
		let scan = await UsageScan.uses(
			of: word, aliases: objcAliases(declaredAt: origin, word: word), declaration: origin,
			roots: scanRoots(declaredIn: origin.uri), client: client, module: moduleToRequire(forDeclarationAt: origin.uri))
		var merged = direct
		var seen = Set(direct.map { "\($0.uri)#\($0.range.start.line)#\($0.range.start.character)" })
		for use in scan.uses {
			let location = UsageScan.location(use, name: word)
			guard seen.insert("\(location.uri)#\(location.range.start.line)#\(location.range.start.character)").inserted else { continue }
			if !includeDeclaration, location.uri == origin.uri, location.range.start.line == origin.range.start.line { continue }
			merged.append(location)
		}
		// Names the server couldn't resolve (no build settings for that file): listed apart, never merged in.
		var unverified: [LSPLocation] = []
		for use in scan.unresolved {
			let location = UsageScan.location(use, name: word)
			guard seen.insert("\(location.uri)#\(location.range.start.line)#\(location.range.start.character)").inserted else { continue }
			unverified.append(location)
		}
		if scan.truncated {
			notices.post("'\(word)' occurs in more than \(UsageScan.maxCandidates) places; the text scan stopped early, so references may be incomplete.")
		}
		return References(locations: merged, unverified: unverified)
	}

	static let maxUnverifiedListed = 15

	/// Name-only matches as a compact section, or empty when there are none.
	private func formatUnverified(_ locations: [LSPLocation]) -> String {
		guard !locations.isEmpty else { return "" }
		let shown = locations.prefix(Self.maxUnverifiedListed).map { location in
			"\(relative(location.uri)):\(location.range.start.line + 1):\(location.range.start.character + 1)"
		}
		let more = locations.count > shown.count ? " … and \(locations.count - shown.count) more" : ""
		return "\n\nUnverified (same name, but the language server has no build settings for these files, so they are matched by name only):\n"
			+ shown.joined(separator: "\n") + more
	}

	/// Callers found by scan: each use of the name that resolves to the declaration, attributed to the
	/// function or type that contains it. For callees the call hierarchy can't answer for (dependencies, sibling packages).
	private func scannedCallers(
		_ client: LSPClient, name: String, aliases: [String] = [], origin: LSPLocation
	) async -> (text: String, count: Int) {
		let scan = await UsageScan.uses(
			of: name, aliases: aliases, declaration: origin, roots: scanRoots(declaredIn: origin.uri), client: client,
			module: moduleToRequire(forDeclarationAt: origin.uri))
		struct Key: Hashable { var path: String; var line: Int; var name: String }
		var grouped: [Key: (kind: Int, sites: [Int])] = [:]
		var symbolsByFile: [String: [SymbolNode]] = [:]
		for use in scan.uses {
			if URL(fileURLWithPath: use.path).absoluteString == origin.uri, use.line - 1 == origin.range.start.line { continue }
			if symbolsByFile[use.path] == nil {
				symbolsByFile[use.path] = (try? await client.documentSymbol(use.path)).map(toSymbolTree) ?? []
			}
			guard let owner = UsageScan.enclosing(line: use.line, in: symbolsByFile[use.path] ?? []) else { continue }
			let key = Key(path: use.path, line: owner.line, name: owner.name)
			grouped[key, default: (owner.kind, [])].sites.append(use.line)
		}
		let lines = grouped.sorted { ($0.key.path, $0.key.line) < ($1.key.path, $1.key.line) }.map { key, value in
			let place = relative(URL(fileURLWithPath: key.path).absoluteString)
			let sites = Set(value.sites).sorted().map { "L\($0)" }.joined(separator: ", ")
			return "\(key.name)  [\(SymbolKind.label(value.kind))]  (\(place):\(key.line)) calls at \(sites)"
		}
		var text = lines.joined(separator: "\n")
		if scan.truncated { text += "\n(text scan stopped after \(UsageScan.maxCandidates) candidates; callers may be incomplete)" }
		return (text, lines.count)
	}

	/// Locations as text: the project's own first (SDK headers last), capped, with the remainder counted.
	private func formatSites(_ sites: [LSPLocation]) -> String {
		let ordered = sites.filter { !isExternal($0.uri) && !isDependencyPath($0.uri) }
			+ sites.filter { isExternal($0.uri) || isDependencyPath($0.uri) }
		let shown = ordered.prefix(Self.maxListedSites).map { formatLocation($0, workspaceRoot: workspaceRoot) }
		let more = ordered.count > shown.count ? "\n\n… and \(ordered.count - shown.count) more" : ""
		return shown.joined(separator: "\n\n") + more
	}

	private func isExternal(_ uri: String) -> Bool {
		uri.contains("/sourcekit-lsp/GeneratedInterfaces/") || uri.contains(".sdk/")
	}

	/// By position when `line` plus `column`/`symbol` is given (the symbol under it is whatever the type checker
	/// says: no name lookup, so overloads, locals and members of any type work), otherwise by name.
	private func resolveTarget(
		_ client: LSPClient, name: String?, query: String?, aliases: KeyValuePairs<String, String?> = [:],
		example: String, filePath: String?, line: Int?, column: Int?, symbol: String?
	) async throws -> Target {
		if let line, column != nil || symbol != nil {
			guard let given = filePath else { throw ToolInputError("Pass `file_path` together with `line` and `column`/`symbol`.") }
			let filePath = try checkSwiftFile(given)
			return try await resolvePosition(client, filePath: filePath, line: line, column: column, symbol: symbol)
		}
		if symbol != nil || column != nil {
			throw ToolInputError("`column` and `symbol` need `line` and `file_path`: pass the line the identifier is on.")
		}
		let filePath = filePath.map { DependencyRoots.expand($0, extra: dependencyCheckoutDirectories()) }
		var named: KeyValuePairs<String, String?> = ["name": name, "query": query]
		if !aliases.isEmpty { named = aliases }
		let wanted = try resolveNameQuery(preferred: "name", example: example, named)
		await awaitIndexIfBusy(client)
		do {
			let resolved = try await resolveSymbol(
				client: client, workspaceRoot: workspaceRoot, query: wanted, filePath: filePath, line: line
			)
			return Target(symbol: resolved, note: nil)
		} catch let error as SymbolResolutionError where error.message.hasPrefix("No symbol found matching") {
			let parsed = ParsedQuery(wanted)
			// Types from the SDK or a dependency aren't in the workspace index: find a use of the name instead.
			if parsed.container.isEmpty, parsed.signature == nil,
				let usage = PositionResolver.findUsage(of: parsed.base, under: workspaceRoot),
				let target = try? await resolvePosition(
					client, filePath: usage.path, line: usage.line, column: usage.column, symbol: nil
				)
			{
				let place = "\(relative(URL(fileURLWithPath: usage.path).absoluteString)):\(usage.line)"
				return Target(
					symbol: target.symbol,
					note: "'\(wanted)' isn't declared in the indexed workspace; resolved through its use at \(place)."
						+ (target.note.map { " " + $0 } ?? ""))
			}
			throw SymbolResolutionError(message: error.message + (await emptyResultHint(client)))
		}
	}

	private func resolvePosition(
		_ client: LSPClient, filePath: String, line: Int, column: Int?, symbol: String?
	) async throws -> Target {
		let column = try await resolveColumn(client, filePath: filePath, line: line, column: column, symbol: symbol)
		let file = await client.resolve(filePath).path
		let text = try readTextFile(URL(fileURLWithPath: file))
		let hoverText = try await client.hover(file, line: line, column: column)
		let definitions = try await client.definition(file, line: line, column: column)
		let word = PositionResolver.word(at: column, onLine: line, in: text)
		guard let word, !(hoverText.isEmpty && definitions.isEmpty) else {
			let lineText = PositionResolver.sourceLines(text).dropFirst(line - 1).first ?? ""
			throw SymbolResolutionError(
				message: "No symbol at \(filePath):\(line):\(column) (\(lineText.trimmingCharacters(in: .whitespaces))). "
					+ "Point at an identifier, or pass `symbol` with its text."
			)
		}
		var kind = PositionResolver.kind(fromHover: hoverText) ?? 0
		if let local = definitions.first(where: { !isExternal($0.uri) }) {
			// A declaration site is the stable place for references, call hierarchy and type hierarchy.
			if kind == 0, let declaration = readLines(of: local.uri)?[safe: local.range.start.line] {
				kind = PositionResolver.kind(fromHover: declaration) ?? 0
			}
			let resolved = ResolvedSymbol(
				name: word, containerName: nil, kind: kind, uri: local.uri, line: local.range.start.line,
				column: local.range.start.character
			)
			return Target(symbol: resolved, note: nil)
		}
		let resolved = ResolvedSymbol(
			name: word, containerName: nil, kind: kind, uri: URL(fileURLWithPath: file).absoluteString, line: line - 1,
			column: column - 1
		)
		let note = definitions.isEmpty ? nil : "\(word) is declared outside the project (SDK or a dependency without sources here)."
		return Target(symbol: resolved, note: note)
	}

	// MARK: - Tools

	public func workspace() async -> ToolResult {
		await run {
			await useWorkspace()
			var lines = [
				workspaceRoot.path,
				"chosen because: \(selector.explain(workspaceSource))",
				"project: \(projectKind.summary)",
			]
			if let advice = projectKind.advice(in: workspaceRoot), projectKind == .none || !projectKind.isNavigable {
				lines.append(advice)
			}
			let setupProblems = ProjectKind.buildSettingsProblems(in: workspaceRoot)
			if projectKind == .buildServer {
				lines.append(setupProblems.isEmpty ? "build settings: ok (buildServer.json, build root with a Swift compilation and an index store)" : "build settings: PROBLEMS")
				lines += setupProblems.map { "  - \($0)" }
			}
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
				let harmless = await client.dependencyFailureCount
				if harmless > 0 {
					lines.append(
						"\(harmless) background build task(s) failed on dependency code only (checkouts/.build); that is usually harmless."
					)
				}
			} else {
				lines.append("language server: not started yet (it starts on the first navigation call)")
			}
			return lines.joined(separator: "\n")
		}
	}

	public func hover(filePath: String, line: Int, column: Int?, symbol: String? = nil) async -> ToolResult {
		await run {
			await useWorkspace()
			let filePath = try checkSwiftFile(filePath)
			let client = try await liveClient()
			let column = try await resolveColumn(client, filePath: filePath, line: line, column: column, symbol: symbol)
			var text = try await client.hover(filePath, line: line, column: column)
			if !text.isEmpty { text = await enrichVariableType(text, client: client, filePath: filePath, line: line, column: column) }
			return text.isEmpty ? "No hover information at that position." + (await emptyResultHint(client)) : text
		}
	}

	public func definition(filePath: String, line: Int, column: Int?, symbol: String? = nil) async -> ToolResult {
		await run {
			await useWorkspace()
			let filePath = try checkSwiftFile(filePath)
			let client = try await liveClient()
			let column = try await resolveColumn(client, filePath: filePath, line: line, column: column, symbol: symbol)
			let locations = try await client.definition(filePath, line: line, column: column)
			if locations.isEmpty { return "No definition found at that position." + (await emptyResultHint(client)) }
			// A header declaration before the implementation file (Objective-C reports both).
			let isHeader: (LSPLocation) -> Bool = { ["h", "hpp"].contains((($0.uri as NSString).pathExtension).lowercased()) }
			let ordered = locations.filter(isHeader) + locations.filter { !isHeader($0) }
			return ordered.map { formatLocation($0, workspaceRoot: workspaceRoot) }.joined(separator: "\n\n")
		}
	}

	public func references(
		name: String? = nil, query: String? = nil, filePath: String?, line: Int? = nil, column: Int? = nil,
		symbol: String? = nil, includeDeclaration: Bool = true
	) async -> ToolResult {
		await run {
			await useWorkspace()
			let client = try await liveClient()
			let file: String
			let targetLine: Int
			let targetColumn: Int
			var prefix = ""
			if let line, column != nil || symbol != nil, let given = filePath {
				// A use site or declaration the caller points at.
				let checked = try checkSwiftFile(given)
				targetColumn = try await resolveColumn(client, filePath: checked, line: line, column: column, symbol: symbol)
				file = await client.resolve(checked).path
				targetLine = line
			} else {
				let target = try await resolveTarget(
					client, name: name, query: query, example: "UserService.create(name:)", filePath: filePath, line: line,
					column: column, symbol: symbol)
				file = try path(of: target.symbol.uri)
				targetLine = target.symbol.line + 1
				targetColumn = target.symbol.column + 1
				prefix = target.note.map { $0 + "\n" } ?? ""
			}
			await awaitIndex(client)
			let found = try await referencesWithUsageFallback(
				client, file: file, line: targetLine, column: targetColumn, includeDeclaration: includeDeclaration)
			let text = formatReferences(found.locations, workspaceRoot: workspaceRoot) + formatUnverified(found.unverified)
			return prefix + (found.locations.isEmpty && found.unverified.isEmpty ? text + (await emptyResultHint(client)) : text)
		}
	}

	/// The type of the expression or declaration at a position, and where that type is defined:
	/// `hover` shows the declaration, this answers "what type is this value?".
	public func typeAt(filePath: String, line: Int, column: Int?, symbol: String? = nil) async -> ToolResult {
		await run {
			await useWorkspace()
			let filePath = try checkSwiftFile(filePath)
			let client = try await liveClient()
			let column = try await resolveColumn(client, filePath: filePath, line: line, column: column, symbol: symbol)
			let text = try await client.hover(filePath, line: line, column: column)
			guard !text.isEmpty else { return "No type information at that position." + (await emptyResultHint(client)) }
			let locations = (try? await client.typeDefinition(filePath, line: line, column: column)) ?? []
			let local = locations.filter { !isExternal($0.uri) }.prefix(Self.maxTypeLocations)
			var parts = [text]
			if local.isEmpty {
				parts.append(
					locations.isEmpty
						? "(no type definition reported: the position may be a type itself, a function, or have no declared type)"
						: "Type is defined in the SDK or the standard library.")
			} else {
				parts += local.map(describeTypeDefinition)
			}
			return parts.joined(separator: "\n")
		}
	}

	public func searchSymbol(
		query: String?, name: String?, kind: String?, path: String?, fuzzy: Bool = false, scope: String? = nil
	) async -> ToolResult {
		await run {
			await useWorkspace()
			let kinds = try parseKindFilter(kind)
			let query = try resolveNameQuery(preferred: "query", example: "UserService", ["query": query, "name": name])
			let client = try await liveClient()
			await awaitIndexIfBusy(client)
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
			if symbols.isEmpty { return "No symbols matching '\(query)'." + (await emptyResultHint(client)) }
			let scopeName = (scope ?? "default").lowercased()
			guard ["default", "project", "dependencies", "all"].contains(scopeName) else {
				throw ToolInputError("`scope` must be project, dependencies or all (default: project code first, a few dependency hits after).")
			}
			let scoped = symbols.filter { symbol in
				switch scopeName {
				case "project": return !isDependencyPath(symbol.location.uri)
				case "dependencies": return isDependencyPath(symbol.location.uri)
				default: return true
				}
			}
			let matching = filterSymbols(scoped, workspaceRoot: workspaceRoot, kinds: kinds, path: path)
			if matching.isEmpty {
				let filters = [("kind", kind), ("path", path)].compactMap { key, value in
					value.map { "\(key)='\($0)'" }
				}.joined(separator: ", ")
				return "No symbols matching '\(query)' with \(filters) (\(symbols.count) without the filters)."
			}
			let listing = formatWorkspaceSymbols(
				matching, workspaceRoot: workspaceRoot, query: parsed.name, fuzzy: fuzzy,
				dependencyLimit: scopeName == "default" ? Self.defaultDependencyHits : nil)
			return listing.isEmpty ? "No symbols matching '\(query)'." : listing
		}
	}

	/// `Outer.Inner.member(label:)` -> (["Outer", "Inner"], "member(label:)").
	static func splitQualified(_ query: String) -> (container: [String], name: String) {
		let parsed = ParsedQuery(query)
		return (parsed.container, parsed.base + (parsed.signature ?? ""))
	}

	public func diagnostics(filePath: String) async -> ToolResult {
		await run {
			await useWorkspace()
			let filePath = try checkSwiftFile(filePath)
			let client = try await liveClient()
			let diagnostics = try await client.diagnostics(filePath)
			var text = formatDiagnostics(diagnostics)
			let unresolved = diagnostics.filter { $0.message.contains("Cannot find") && $0.message.contains("in scope") }.count
			if diagnostics.contains(where: { $0.message.hasPrefix("No such module") }) || unresolved >= 3 {
				text += "\n\nThese look like missing build settings for this file rather than real errors (the file is analyzed "
					+ "without its target's SDK and module search paths). With an Xcode project, run a full build and regenerate "
					+ "buildServer.json (`xcode-build-server config`): a build that only relinked doesn't record Swift compile commands."
				let setup = ProjectKind.buildSettingsProblems(in: workspaceRoot)
				if !setup.isEmpty { text += "\nWhat `workspace` found: " + setup.joined(separator: " ") }
			}
			return text
		}
	}

	public func symbolInfo(
		name: String?, query: String?, filePath: String?, line: Int? = nil, column: Int? = nil, symbol: String? = nil,
		includeReferences: Bool = true
	) async -> ToolResult {
		await run {
			await useWorkspace()
			let client = try await liveClient()
			let target = try await resolveTarget(
				client, name: name, query: query, example: "UserService.create(name:)", filePath: filePath, line: line,
				column: column, symbol: symbol)
			let resolved = target.symbol
			let relativePath = relative(resolved.uri)
			let file = try path(of: resolved.uri)
			let line = resolved.line + 1
			let column = resolved.column + 1
			let hoverText = try await client.hover(file, line: line, column: column)
			let definitions = try await client.definition(file, line: line, column: column)
			var found = References(locations: [])
			if includeReferences {
				await awaitIndex(client)
				found = try await referencesWithUsageFallback(client, file: file, line: line, column: column)
			}
			let references = found.locations
			let header = "\(resolved.qualifiedName)  [\(SymbolKind.label(resolved.kind))]  (\(relativePath):\(line):\(column))"
			var parts = [header]
			if let note = target.note { parts.append(note) }
			parts += ["", hoverText.isEmpty ? "No hover information." : hoverText]
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
				parts += ["", "References:", formatReferencesGrouped(references, workspaceRoot: workspaceRoot) + formatUnverified(found.unverified)]
				if references.isEmpty { parts.append(await emptyResultHint(client)) }
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

	public func outline(filePath: String) async -> ToolResult {
		await run {
			await useWorkspace()
			let filePath = try checkSwiftFile(filePath)
			let client = try await liveClient()
			return formatOutline(try await client.documentSymbol(filePath))
		}
	}

	public func callers(
		name: String?, query: String?, filePath: String?, line: Int? = nil, column: Int? = nil, symbol: String? = nil
	) async -> ToolResult {
		await run {
			await useWorkspace()
			let client = try await liveClient()
			let target = try await resolveTarget(
				client, name: name, query: query, example: "UserService.create(name:)", filePath: filePath, line: line,
				column: column, symbol: symbol)
			let resolved = target.symbol
			let file = try path(of: resolved.uri)
			await awaitIndex(client)
			let items = try await client.prepareCallHierarchy(file, line: resolved.line + 1, column: resolved.column + 1)
			var calls: [IncomingCall] = []
			if let item = items.first { calls = try await client.incomingCalls(item) }
			let prefix = target.note.map { $0 + "\n" } ?? ""
			if !calls.isEmpty, !isOutsideWorkspace(resolved.uri) {
				return prefix + formatCallers(calls, workspaceRoot: workspaceRoot)
			}
			// No call hierarchy (a dependency's method) or nothing from it: find the calls by scanning.
			let origin = LSPLocation(
				uri: resolved.uri,
				range: LSPRange(
					start: LSPPosition(line: resolved.line, character: resolved.column),
					end: LSPPosition(line: resolved.line, character: resolved.column)))
			let scanned = await scannedCallers(client, name: PositionResolver.baseName(of: resolved.name), aliases: objcAliases(declaredAt: origin, word: PositionResolver.baseName(of: resolved.name)) + PositionResolver.objcSpellings(ofSwiftName: resolved.name), origin: origin)
			if scanned.count > 0 {
				let fromIndex = calls.isEmpty ? "" : formatCallers(calls, workspaceRoot: workspaceRoot) + "\n"
				return prefix + (calls.isEmpty ? scanned.text : mergeCallerText(fromIndex, scanned.text))
			}
			if items.isEmpty {
				return prefix + "\(resolved.name) has no call hierarchy entry at that position (it may not be a callable), and no calls to it were found in the sources."
			}
			return prefix + formatCallers(calls, workspaceRoot: workspaceRoot) + (calls.isEmpty ? await emptyResultHint(client) : "")
		}
	}

	/// Index callers followed by scan callers not already listed (matched by caller line).
	private func mergeCallerText(_ index: String, _ scanned: String) -> String {
		let known = Set(index.split(separator: "\n").map(String.init))
		let extra = scanned.split(separator: "\n").map(String.init).filter { line in
			!known.contains { $0.hasPrefix(line.components(separatedBy: " calls at ").first ?? line) }
		}
		return (index.split(separator: "\n").map(String.init) + extra).joined(separator: "\n")
	}

	/// Types that conform to a protocol / inherit from a class (transitively, through refining
	/// protocols and subclasses), or the members that implement or override a protocol requirement /
	/// class member.
	public func implementations(
		name: String?, query: String?, portName: String?, filePath: String?, line: Int? = nil, column: Int? = nil,
		symbol: String? = nil
	) async -> ToolResult {
		await run {
			await useWorkspace()
			let client = try await liveClient()
			let target = try await resolveTarget(
				client, name: name, query: query, aliases: ["name": name, "query": query, "port_name": portName],
				example: "UserStore", filePath: filePath, line: line, column: column, symbol: symbol)
			let resolved = target.symbol
			let file = try path(of: resolved.uri)
			await awaitIndex(client)
			let line = resolved.line + 1
			let column = resolved.column + 1
			let prefix = target.note.map { $0 + "\n\n" } ?? ""
			if SymbolKind.types.contains(resolved.kind) {
				return prefix + (try await formatSubtypes(of: resolved, client: client, file: file, line: line, column: column))
			}
			let locations = try await client.implementation(file, line: line, column: column)
				.filter { !($0.uri == resolved.uri && $0.range.start.line == resolved.line) }
			if locations.isEmpty {
				return prefix + "No implementations or overrides of \(resolved.qualifiedName) found." + (await emptyResultHint(client))
			}
			let heading = "\(locations.count) implementation(s) of \(resolved.qualifiedName):"
			return prefix + heading + "\n\n" + formatSites(locations)
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
		var unverifiedNote = ""
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
			// The real path folds a header reachable through two include directories into one.
			let realURI = uriToPath(sub.uri).map { URL(fileURLWithPath: $0).realPath.path } ?? sub.uri
			guard seen.insert("\(realURI)#\(sub.name)#\(sub.selectionRange.start.line)").inserted else { continue }
			visited += 1
			let position = "\(relative(sub.uri)):\(sub.selectionRange.start.line + 1):\(sub.selectionRange.start.character + 1)"
			if Self.isExtensionConformance(sub) {
				// `Type: Protocol` declared in an extension; sourcekit-lsp has no item for the type itself here.
				let typeName = sub.name.components(separatedBy: ":").first ?? sub.name
				entries.append(Entry(depth: depth, text: "\(typeName)  [conformance in extension]  (\(position))"))
			} else {
				// A class extension or category has no name of its own in Objective-C.
				let shownName = sub.name.isEmpty ? "(class extension)" : sub.name
				entries.append(Entry(depth: depth, text: "\(shownName)  [\(SymbolKind.label(sub.kind))]  (\(position))"))
				stack.append(contentsOf: try await client.subtypes(sub).reversed().map { (item: $0, depth: depth + 1) })
			}
		}

		let verb = resolved.kind == SymbolKind.protocol ? "conform to or refine" : "inherit from"
		if resolved.kind == SymbolKind.protocol {
			// The type hierarchy misses retroactive conformances (`extension Dep.Type: Proto`): the protocol's
			// name on a type or extension header line that resolves to it is a conformance site too.
			let known = Set(entries.map(\.text))
			let origin = LSPLocation(
				uri: resolved.uri,
				range: LSPRange(
					start: LSPPosition(line: resolved.line, character: resolved.column),
					end: LSPPosition(line: resolved.line, character: resolved.column)))
			let scan = await UsageScan.uses(
				of: resolved.name, declaration: origin, roots: scanRoots(declaredIn: origin.uri), client: client,
				module: moduleToRequire(forDeclarationAt: origin.uri))
			var symbolsByFile: [String: [SymbolNode]] = [:]
			var added = Set<String>()
			var unverified = false
			for (use, verified) in scan.uses.map({ ($0, true) }) + scan.unresolved.map({ ($0, false) }) {
				if verified, use.path == uriToPath(resolved.uri), use.line - 1 == resolved.line { continue }
				if symbolsByFile[use.path] == nil {
					symbolsByFile[use.path] = (try? await client.documentSymbol(use.path)).map(toSymbolTree) ?? []
				}
				guard let owner = UsageScan.enclosing(line: use.line, in: symbolsByFile[use.path] ?? []), owner.isHeader
				else { continue }
				// `extension Proto { … }` names the protocol without conforming: it must follow a `:`.
				if let text = try? readTextFile(URL(fileURLWithPath: use.path)) {
					let lines = PositionResolver.sourceLines(text)
					guard use.line <= lines.count, lines[use.line - 1].utf16.prefix(use.column - 1).contains(0x3A)
					else { continue }
				}
				let position = "\(relative(URL(fileURLWithPath: use.path).absoluteString)):\(owner.line):\(use.column)"
				let isExtension = owner.kind == SymbolKind.extensionKind
				let kind = isExtension ? "conformance in extension" : SymbolKind.label(owner.kind)
				let text = "\(owner.name)  [\(kind)\(verified ? "" : ", unverified")]  (\(position))"
				let alreadyListed = known.contains { $0.contains("(\(position.components(separatedBy: ":").dropLast().joined(separator: ":"))") }
				// Headers reachable through symlinked include directories are one site.
				let siteKey = "\(URL(fileURLWithPath: use.path).realPath.path):\(owner.line):\(use.column)"
				if !alreadyListed, added.insert(siteKey).inserted {
					entries.append(Entry(depth: 0, text: text))
					if !verified { unverified = true }
				}
			}
			if unverified {
				unverifiedNote = "\n(unverified: the language server couldn't resolve the name there, usually because that file's build settings are unknown, so these are matched by name only)"
			}
		}
		if entries.isEmpty {
			// Without a type hierarchy the conformance sites are still known.
			let sites = try await client.implementation(file, line: line, column: column)
			if sites.isEmpty {
				let hint =
					resolved.kind == SymbolKind.protocol
					? " Conformances declared in an extension of a type from another module (`extension Dep.Type: \(resolved.name)`) may not be reported here; `references` lists them."
					: ""
				return "No types \(verb) \(resolved.qualifiedName)." + hint
			}
			return "\(sites.count) site(s) that \(verb) \(resolved.qualifiedName):\n\n"
				+ formatSites(sites)
		}
		let list = entries.map { String(repeating: "  ", count: $0.depth) + $0.text }
		let note = visited >= Self.maxSubtypesVisited ? "\n… stopped after \(Self.maxSubtypesVisited) types" : ""
		return "\(entries.count) type(s) \(verb) \(resolved.qualifiedName):\n" + list.joined(separator: "\n") + note + unverifiedNote
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

private extension Array {
	subscript(safe index: Int) -> Element? {
		indices.contains(index) ? self[index] : nil
	}
}
