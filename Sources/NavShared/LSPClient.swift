import Foundation

// Minimal async LSP client: generic JSON-RPC/LSP wire-protocol plumbing.
//
// Not a general-purpose LSP library: framing and the handful of requests used here
// cover only what the navigation tools need. Language-server-specific bits (how to
// launch it, its languageId) are the caller's responsibility.

/// How far along the language server's background indexing is.
public struct IndexStatus: Sendable, Equatable {
	public var isReady: Bool
	/// Human-readable progress ("Indexing 12 / 40"), when still busy.
	public var detail: String?
}

/// A child process speaking LSP over stdio. Reading is callback-driven and writing goes
/// through a serial queue, so neither blocks the cooperative thread pool.
final class ServerProcess: @unchecked Sendable {
	private let process = Process()
	private let stdinPipe = Pipe()
	private let stdoutPipe = Pipe()
	private let stderrPipe = Pipe()
	private let writeQueue = DispatchQueue(label: "codenav.lsp.write")
	let output: AsyncStream<Data>
	let errorOutput: AsyncStream<Data>

	init(command: [String], workingDirectory: URL, environment: [String: String]?) throws {
		guard let first = command.first else {
			throw LanguageServerLaunchError(message: "No language server command configured.")
		}
		if first.hasPrefix("/") {
			process.executableURL = URL(fileURLWithPath: first)
			process.arguments = Array(command.dropFirst())
		} else {
			process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
			process.arguments = command
		}
		process.currentDirectoryURL = workingDirectory
		if let environment { process.environment = environment }
		process.standardInput = stdinPipe
		process.standardOutput = stdoutPipe
		process.standardError = stderrPipe

		(output, outputContinuation) = ServerProcess.makeStream(stdoutPipe.fileHandleForReading)
		(errorOutput, errorContinuation) = ServerProcess.makeStream(stderrPipe.fileHandleForReading)
		do {
			try process.run()
		} catch {
			throw LanguageServerLaunchError(
				message: "Cannot start language server `\(command.joined(separator: " "))`: \(error.localizedDescription)."
			)
		}
	}

	private let outputContinuation: AsyncStream<Data>.Continuation
	private let errorContinuation: AsyncStream<Data>.Continuation

	private static func makeStream(_ handle: FileHandle) -> (AsyncStream<Data>, AsyncStream<Data>.Continuation) {
		let (stream, continuation) = AsyncStream<Data>.makeStream(bufferingPolicy: .unbounded)
		handle.readabilityHandler = { handle in
			let data = handle.availableData
			if data.isEmpty {
				handle.readabilityHandler = nil
				continuation.finish()
			} else {
				continuation.yield(data)
			}
		}
		return (stream, continuation)
	}

	var isRunning: Bool { process.isRunning }

	func write(_ data: Data) {
		let handle = stdinPipe.fileHandleForWriting
		writeQueue.async {
			// A dead server surfaces through the reader; a failed write here is not actionable.
			try? handle.write(contentsOf: data)
		}
	}

	func terminate() {
		if process.isRunning { process.terminate() }
		stdoutPipe.fileHandleForReading.readabilityHandler = nil
		stderrPipe.fileHandleForReading.readabilityHandler = nil
		outputContinuation.finish()
		errorContinuation.finish()
	}

	func waitUntilExit(timeout: TimeInterval) async {
		let deadline = Date().addingTimeInterval(timeout)
		while process.isRunning, Date() < deadline {
			try? await Task.sleep(nanoseconds: 50_000_000)
		}
		if process.isRunning { kill(process.processIdentifier, SIGKILL) }
	}
}

private enum JSONRPCID: Codable, Hashable {
	case int(Int)
	case string(String)

	init(from decoder: Decoder) throws {
		let container = try decoder.singleValueContainer()
		if let value = try? container.decode(Int.self) {
			self = .int(value)
		} else {
			self = .string(try container.decode(String.self))
		}
	}

	func encode(to encoder: Encoder) throws {
		var container = encoder.singleValueContainer()
		switch self {
		case .int(let value): try container.encode(value)
		case .string(let value): try container.encode(value)
		}
	}
}

private struct IncomingMessage: Decodable {
	struct ErrorBody: Decodable {
		var code: Int?
		var message: String?
	}

	var id: JSONRPCID?
	var method: String?
	var params: JSONValue?
	var error: ErrorBody?
}

private struct ResultEnvelope<Result: Decodable>: Decodable {
	var result: Result?
}

private struct OutgoingRequest<Params: Encodable>: Encodable {
	var jsonrpc = "2.0"
	var id: Int?
	var method: String
	var params: Params
}

private struct OutgoingReply: Encodable {
	struct ErrorBody: Encodable {
		var code: Int
		var message: String
	}

	var jsonrpc = "2.0"
	var id: JSONRPCID
	var result: JSONValue?
	var error: ErrorBody?

	func encode(to encoder: Encoder) throws {
		var container = encoder.container(keyedBy: CodingKeys.self)
		try container.encode(jsonrpc, forKey: .jsonrpc)
		try container.encode(id, forKey: .id)
		if let error {
			try container.encode(error, forKey: .error)
		} else {
			try container.encode(result ?? .null, forKey: .result)  // `result: null` is required, not omittable
		}
	}

	private enum CodingKeys: String, CodingKey { case jsonrpc, id, result, error }
}

public actor LSPClient {
	public struct Configuration: Sendable {
		public var workspaceRoot: URL
		public var command: [String]
		public var languageID: String
		/// File suffixes (lowercased, with the dot) whose on-disk changes `refresh()` reports to
		/// the server via `workspace/didChangeWatchedFiles`.
		public var watchSuffixes: Set<String>
		/// File names (matched anywhere under the workspace) that alter how the server resolves
		/// the project: servers read them once at startup, so a change restarts the server.
		public var configNames: Set<String>
		public var environment: [String: String]?
		/// How long an ordinary request may take. A cold workspace-wide query can legitimately take
		/// a while while the index is first built, so this is generous.
		public var requestTimeout: TimeInterval
		/// Further directories to register as workspace folders: local packages that live outside the
		/// root (`../Octopus`), whose sources the server otherwise treats as loose files.
		public var extraWorkspaceFolders: [URL]

		public init(
			workspaceRoot: URL,
			command: [String],
			languageID: String,
			watchSuffixes: Set<String> = [],
			configNames: Set<String> = [],
			environment: [String: String]? = nil,
			requestTimeout: TimeInterval = 60,
			extraWorkspaceFolders: [URL] = []
		) {
			self.requestTimeout = requestTimeout
			self.extraWorkspaceFolders = extraWorkspaceFolders
			self.workspaceRoot = workspaceRoot
			self.command = command
			self.languageID = languageID
			self.watchSuffixes = watchSuffixes
			self.configNames = configNames
			self.environment = environment
		}
	}

	private struct OpenFile {
		var version: Int
		var modified: Date
		var size: Int
		var text: String
	}

	private struct FileStamp: Equatable {
		var modified: Date
		var size: Int
	}

	private struct ProgressInfo {
		var title: String
		var message: String?
		var percentage: Int?
	}

	private enum FileChange: Int { case created = 1, changed, deleted }

	/// LSP `ContentModified` (-32801) and `ServerCancelled` (-32802): both mean "ask again".
	private static let retryableCodes: Set<Int> = [-32801, -32802]
	private static let contentModifiedBackoff: [TimeInterval] = [0.1, 0.25, 0.5]
	private static let stderrTailLines = 10
	private static let pushDiagnosticsTimeout: TimeInterval = 5

	public let configuration: Configuration
	private let onNotice: (@Sendable (String) -> Void)?
	private let onRestart: (@Sendable () async -> Void)?

	private var process: ServerProcess?
	private var readerTask: Task<Void, Never>?
	private var stderrTask: Task<Void, Never>?
	private var started = false
	private var startTask: Task<Void, Error>?
	private var nextID = 0
	private var buffer = Data()
	private var pending: [Int: CheckedContinuation<Data, Error>] = [:]
	private var timeouts: [Int: Task<Void, Never>] = [:]
	private var stderrTail: [String] = []
	private var errorLog: [String] = []
	/// Lines of each running background task (sourcekit-lsp tags every log line of one task with the
	/// same three-emoji prefix), so a failing task's compiler errors can be shown with its exit code.
	private var taskLines: [String: [String]] = [:]
	private var taskOrder: [String] = []
	private var dependencyFailures = 0

	private var openFiles: [String: OpenFile] = [:]
	/// Documents whose text lives only in memory (a proposed edit being checked): `ensureOpen` and
	/// `refresh` leave them alone instead of re-reading the disk.
	private var overlays: Set<String> = []
	/// Collects the edits a server asks us to apply (`workspace/applyEdit`) while a command runs.
	private var capturedEdits: LSPWorkspaceEdit?
	private var pushedDiagnostics: [String: [LSPDiagnostic]] = [:]
	private var diagnosticWaiters: [String: [CheckedContinuation<Void, Never>]] = [:]
	private var diagnosticsArrived: Set<String> = []
	private var symbolCache: [String: (version: Int, symbols: [DocumentSymbol])] = [:]

	private var watchSnapshot: [URL: FileStamp]?
	private var configSnapshot: [URL: FileStamp]?
	private var refreshInProgress = false

	private var activeProgress: [String: ProgressInfo] = [:]
	private var lastActivity = Date()

	public init(
		configuration: Configuration,
		onNotice: (@Sendable (String) -> Void)? = nil,
		onRestart: (@Sendable () async -> Void)? = nil
	) {
		self.configuration = configuration
		self.onNotice = onNotice
		self.onRestart = onRestart
	}

	public var isAlive: Bool { process?.isRunning ?? false }

	/// Recent background-build failures the server logged, with the compiler error behind each one.
	/// Failures that only concern dependency code (checkouts, `.build`) are left out: they are the
	/// norm and say nothing about the project's own sources.
	public var recentErrors: [String] { errorLog }

	/// How many background tasks failed on dependency code only (reported separately as harmless).
	public var dependencyFailureCount: Int { dependencyFailures }

	// MARK: - Lifecycle

	public func start() async throws {
		guard !started else { return }
		// Several callers can arrive while the handshake is still awaiting: they share one start.
		if let startTask { return try await startTask.value }
		let task = Task { try await self.launchServer() }
		startTask = task
		defer { startTask = nil }
		try await task.value
	}

	private func launchServer() async throws {
		stderrTail.removeAll()
		let server = try ServerProcess(
			command: configuration.command,
			workingDirectory: configuration.workspaceRoot,
			environment: configuration.environment
		)
		process = server
		buffer = Data()
		readerTask = Task { [weak self] in
			for await chunk in server.output {
				await self?.consume(chunk)
			}
			await self?.serverClosed(server)
		}
		stderrTask = Task { [weak self] in
			var partial = Data()
			for await chunk in server.errorOutput {
				partial.append(chunk)
				while let newline = partial.firstIndex(of: 0x0A) {
					let line = String(decoding: partial[partial.startIndex..<newline], as: UTF8.self)
					partial.removeSubrange(partial.startIndex...newline)
					await self?.recordStderr(line)
				}
				if partial.count > 64 * 1024 {  // a server that never prints a newline must not grow this without bound
					await self?.recordStderr(String(decoding: partial.prefix(2000), as: UTF8.self) + "…")
					partial.removeAll()
				}
			}
		}
		let rootURI = configuration.workspaceRoot.absoluteString
		let capabilities: JSONValue = [
			"textDocument": [
				"synchronization": ["didSave": true],
				"publishDiagnostics": [:],
				"documentSymbol": ["hierarchicalDocumentSymbolSupport": true],
				"callHierarchy": [:],
				"typeHierarchy": [:],
				"implementation": ["linkSupport": true],
				"typeDefinition": ["linkSupport": true],
				"definition": ["linkSupport": true],
				"hover": ["contentFormat": ["markdown", "plaintext"]],
				"diagnostic": ["dynamicRegistration": false],
				"codeAction": [
					"codeActionLiteralSupport": [
						"codeActionKind": [
							"valueSet": ["quickfix", "refactor", "refactor.extract", "refactor.inline", "refactor.rewrite", "source"]
						]
					]
				],
				"rename": ["prepareSupport": true],
			],
			"workspace": [
				"applyEdit": true,
				"workspaceEdit": ["documentChanges": true],
				"workspaceFolders": true,
				"didChangeWatchedFiles": ["dynamicRegistration": true],
				"symbol": [:],
			],
			"window": ["workDoneProgress": true],
		]
		_ = try await requestData(
			"initialize",
			params: [
				"processId": .int(Int(ProcessInfo.processInfo.processIdentifier)),
				"rootUri": .string(rootURI),
				"capabilities": capabilities,
				"workspaceFolders": .array(
					([configuration.workspaceRoot] + configuration.extraWorkspaceFolders).map {
						["uri": .string($0.absoluteString), "name": .string($0.lastPathComponent)]
					}),
			],
			timeout: 60
		)
		notify("initialized", params: [:])
		started = true
		lastActivity = Date()
		// Returns once the build system has loaded the project, which is also when any
		// background indexing it needs gets scheduled (so progress tracking can take over).
		_ = try? await requestData("workspace/synchronize", params: ["index": true], timeout: 30)
		lastActivity = Date()
	}

	public func stop() async {
		guard let server = process else { return }
		if started {
			_ = try? await requestData("shutdown", params: JSONValue.null, timeout: 5)
			notify("exit", params: JSONValue.null)
		}
		failPending(LanguageServerExitedError(message: exitMessage()))
		readerTask?.cancel()
		stderrTask?.cancel()
		server.terminate()
		await server.waitUntilExit(timeout: 3)
		readerTask = nil
		stderrTask = nil
		process = nil
		started = false
	}

	/// Stops the server and starts it again with no memory of the old session.
	public func restart() async throws {
		await stop()
		pending = [:]
		pushedDiagnostics = [:]
		diagnosticsArrived = []
		openFiles = [:]
		// The new server knows none of the documents the old one held: an overlay left in this set would make
		// `ensureOpen` believe a proposal is still open there, and never send it.
		overlays = []
		capturedEdits = nil
		buffer = Data()
		for waiters in diagnosticWaiters.values { for waiter in waiters { waiter.resume() } }
		diagnosticWaiters = [:]
		symbolCache = [:]
		activeProgress = [:]
		try await start()
		await onRestart?()
	}

	// MARK: - Wire protocol

	private func recordStderr(_ line: String) {
		guard !line.isEmpty else { return }
		stderrTail.append(line)
		if stderrTail.count > Self.stderrTailLines { stderrTail.removeFirst() }
	}

	private func exitMessage() -> String {
		var message = "language server exited: \(configuration.command.joined(separator: " "))"
		if !stderrTail.isEmpty {
			message += "\nIts last stderr output:\n" + stderrTail.joined(separator: "\n")
		}
		return message
	}

	private func serverClosed(_ server: ServerProcess) async {
		// stdout closing usually means the process died; its last words are on stderr.
		try? await Task.sleep(nanoseconds: 300_000_000)
		// After a restart the old reader finishes late: its requests are gone, the new server's are not its to fail.
		guard process === server else { return }
		failPending(LanguageServerExitedError(message: exitMessage()))
	}

	private func failPending(_ error: Error) {
		let waiting = pending
		pending = [:]
		for task in timeouts.values { task.cancel() }
		timeouts = [:]
		for continuation in waiting.values { continuation.resume(throwing: error) }
	}

	private func consume(_ chunk: Data) {
		buffer.append(chunk)
		let separator = Data("\r\n\r\n".utf8)
		while let headerEnd = buffer.range(of: separator) {
			let header = String(decoding: buffer[buffer.startIndex..<headerEnd.lowerBound], as: UTF8.self)
			var length = 0
			for line in header.split(separator: "\r\n") where line.lowercased().hasPrefix("content-length") {
				length = Int(line.split(separator: ":", maxSplits: 1).last?.trimmingCharacters(in: .whitespaces) ?? "") ?? 0
			}
			let bodyStart = headerEnd.upperBound
			guard buffer.distance(from: bodyStart, to: buffer.endIndex) >= length else { return }
			let body = Data(buffer[bodyStart..<buffer.index(bodyStart, offsetBy: length)])
			buffer.removeSubrange(buffer.startIndex..<buffer.index(bodyStart, offsetBy: length))
			dispatch(body)
		}
	}

	private func dispatch(_ body: Data) {
		guard let message = try? JSONDecoder().decode(IncomingMessage.self, from: body) else { return }
		switch (message.id, message.method) {
		case (let id?, let method?):
			replyToServerRequest(id: id, method: method, params: message.params)
		case (let id?, nil):
			guard case .int(let key) = id, let continuation = pending.removeValue(forKey: key) else { return }
			timeouts.removeValue(forKey: key)?.cancel()
			if let error = message.error {
				continuation.resume(
					throwing: LSPRequestError(method: "", code: error.code, message: error.message ?? "unknown error")
				)
			} else {
				continuation.resume(returning: body)
			}
		case (nil, let method?):
			handleNotification(method: method, params: message.params)
		default:
			break
		}
	}

	/// Answer a server->client request so the server never waits on us
	/// (`workspace/configuration`, `client/registerCapability`, progress creation, ...).
	private func replyToServerRequest(id: JSONRPCID, method: String, params: JSONValue?) {
		var reply = OutgoingReply(id: id)
		switch method {
		case "workspace/configuration":
			let count = params?["items"]?.arrayValue?.count ?? 0
			reply.result = .array(Array(repeating: .null, count: count))
		case "window/workDoneProgress/create":
			if let token = params?["token"] {
				activeProgress[Self.tokenKey(token)] = ProgressInfo(title: "starting", message: nil, percentage: nil)
				lastActivity = Date()
			}
			reply.result = .null
		case "workspace/applyEdit":
			if capturedEdits != nil, let json = params?["edit"], let edit = try? JSONValue.decode(LSPWorkspaceEdit.self, from: json) {
				capturedEdits?.merge(edit)
				reply.result = ["applied": .bool(true)]
			} else {
				reply.result = ["applied": .bool(false)]
			}
		case "client/registerCapability", "client/unregisterCapability", "workspace/diagnostic/refresh",
			"workspace/semanticTokens/refresh", "workspace/inlayHint/refresh", "workspace/codeLens/refresh",
			"workspace/tests/refresh", "workspace/playgrounds/refresh", "window/showMessageRequest":
			reply.result = .null
		default:
			reply.error = .init(code: -32601, message: "Method not found: \(method)")
		}
		send(reply)
	}

	private static func tokenKey(_ token: JSONValue) -> String {
		switch token {
		case .string(let value): return value
		case .int(let value): return String(value)
		default: return "?"
		}
	}

	private func handleNotification(method: String, params: JSONValue?) {
		switch method {
		case "textDocument/publishDiagnostics":
			guard let uri = params?["uri"]?.stringValue else { return }
			let items = (params?["diagnostics"]).flatMap { try? JSONValue.decode([LSPDiagnostic].self, from: $0) } ?? []
			pushedDiagnostics[uri] = items
			diagnosticsArrived.insert(uri)
			resumeDiagnosticWaiters(uri)
		case "$/progress":
			guard let token = params?["token"], let value = params?["value"] else { return }
			let key = Self.tokenKey(token)
			lastActivity = Date()
			switch value["kind"]?.stringValue {
			case "begin":
				activeProgress[key] = ProgressInfo(
					title: value["title"]?.stringValue ?? "working",
					message: value["message"]?.stringValue,
					percentage: value["percentage"]?.intValue
				)
			case "report":
				var info = activeProgress[key] ?? ProgressInfo(title: "working", message: nil, percentage: nil)
				if let message = value["message"]?.stringValue { info.message = message }
				if let percentage = value["percentage"]?.intValue { info.percentage = percentage }
				activeProgress[key] = info
			case "end":
				activeProgress.removeValue(forKey: key)
			default:
				break
			}
		case "window/logMessage":
			guard let message = params?["message"]?.stringValue else { return }
			recordLog(message, isError: params?["type"]?.intValue == 1)
		default:
			break
		}
	}

	private static let dependencyPathMarkers = ["/checkouts/", "/.build/", "/SourcePackages/", "/DerivedData/", "/.swiftpm/"]

	/// `🟥🟩🟪 Finished with exit code 1 ...` -> ("🟥🟩🟪", rest). nil for a message with no task tag.
	static func splitTaskTag(_ line: String) -> (tag: String, rest: String)? {
		guard let space = line.firstIndex(of: " ") else { return nil }
		let tag = line[..<space]
		guard tag.count == 3, tag.unicodeScalars.allSatisfy({ $0.value > 0x2000 }) else { return nil }
		return (String(tag), String(line[line.index(after: space)...]))
	}

	/// Keeps each task's output until it finishes; when it finishes badly, records the compiler error
	/// that explains it. The failure line itself (`Finished with exit code 1`) says nothing useful,
	/// and the error is logged separately, at a lower severity, under the same task tag.
	private func recordLog(_ message: String, isError: Bool) {
		let lines = message.components(separatedBy: "\n")
		guard let tag = lines.first.flatMap(Self.splitTaskTag)?.tag else {
			if isError { appendError(String(message.prefix(500))) }
			return
		}
		var buffer = taskLines[tag] ?? []
		if taskLines[tag] == nil {
			taskOrder.append(tag)
			if taskOrder.count > 40 { taskLines.removeValue(forKey: taskOrder.removeFirst()) }
		}
		for line in lines {
			let text = Self.splitTaskTag(line).map(\.rest) ?? line
			if !text.isEmpty { buffer.append(text) }
		}
		if buffer.count > 120 { buffer.removeFirst(buffer.count - 120) }
		taskLines[tag] = buffer

		guard let finished = buffer.last(where: { $0.hasPrefix("Finished with exit code ") }) else { return }
		taskLines.removeValue(forKey: tag)
		taskOrder.removeAll { $0 == tag }
		guard !finished.hasPrefix("Finished with exit code 0 ") else { return }
		let errors = buffer.filter { $0.contains(": error:") || $0.hasPrefix("error: ") }
		let specific = errors.filter { !$0.contains("command failed with exit code") }
		var seen: Set<String> = []
		let unique = (specific.isEmpty ? errors : specific).filter { seen.insert($0).inserted }
		let isDependencyOnly = !unique.isEmpty && unique.allSatisfy { line in Self.dependencyPathMarkers.contains { line.contains($0) } }
		if isDependencyOnly {
			dependencyFailures += 1
			return
		}
		if unique.isEmpty {
			let title = buffer.first.map { String($0.prefix(80)) } ?? "background task"
			appendError("\(title): \(finished)")
			return
		}
		// One clean `File.swift:3:12: error: ...` line per distinct compiler error, workspace-relative.
		var reasons = unique.prefix(2).map { line -> String in
			var text = line
			for prefix in rootSpellings(configuration.workspaceRoot) { text = text.replacingOccurrences(of: prefix, with: "") }
			return String(text.prefix(300))
		}
		if unique.count > 2 { reasons.append("(+\(unique.count - 2) more)") }
		appendError(reasons.joined(separator: " | "))
	}

	private func appendError(_ message: String) {
		if !errorLog.contains(message) { errorLog.append(message) }
		if errorLog.count > 5 { errorLog.removeFirst() }
	}

	private func send<Message: Encodable>(_ message: Message) {
		guard let process, let body = try? JSONEncoder.lsp.encode(message) else { return }
		var framed = Data("Content-Length: \(body.count)\r\n\r\n".utf8)
		framed.append(body)
		process.write(framed)
	}

	private func notify(_ method: String, params: JSONValue) {
		send(OutgoingRequest(id: nil, method: method, params: params))
	}

	private func requestData(_ method: String, params: JSONValue, timeout: TimeInterval? = nil) async throws -> Data {
		let timeout = timeout ?? configuration.requestTimeout
		for delay in Self.contentModifiedBackoff {
			do {
				return try await requestOnce(method, params: params, timeout: timeout)
			} catch let error as LSPRequestError where Self.retryableCodes.contains(error.code ?? 0) {
				try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
			}
		}
		return try await requestOnce(method, params: params, timeout: timeout)
	}

	private func requestOnce(_ method: String, params: JSONValue, timeout: TimeInterval) async throws -> Data {
		guard process != nil else { throw LanguageServerExitedError(message: exitMessage()) }
		nextID += 1
		let id = nextID
		do {
			// A cancelled tool call stops waiting, and tells the server it needn't finish the work.
			return try await withTaskCancellationHandler {
				try await withCheckedThrowingContinuation { continuation in
					pending[id] = continuation
					timeouts[id] = Task { [weak self] in
						try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
						guard !Task.isCancelled else { return }
						await self?.expire(id, method: method)
					}
					send(OutgoingRequest(id: id, method: method, params: params))
				}
			} onCancel: {
				Task { await self.cancelRequest(id) }
			}
		} catch let error as LSPRequestError {
			throw LSPRequestError(method: method, code: error.code, message: error.message)
		}
	}

	private func cancelRequest(_ id: Int) {
		guard let continuation = pending.removeValue(forKey: id) else { return }
		timeouts.removeValue(forKey: id)?.cancel()
		notify("$/cancelRequest", params: ["id": .int(id)])
		continuation.resume(throwing: CancellationError())
	}

	private func expire(_ id: Int, method: String) {
		timeouts.removeValue(forKey: id)
		pending.removeValue(forKey: id)?.resume(throwing: LSPTimeoutError(method: method))
	}

	/// Sends a request and decodes its `result` (nil when the server answered `null`).
	private func request<Result: Decodable>(
		_ method: String, params: JSONValue, as type: Result.Type = Result.self, timeout: TimeInterval? = nil
	) async throws -> Result? {
		let data = try await requestData(method, params: params, timeout: timeout)
		do {
			return try JSONDecoder().decode(ResultEnvelope<Result>.self, from: data).result
		} catch {
			throw LSPRequestError(method: method, code: nil, message: "unexpected response shape (\(error.localizedDescription))")
		}
	}

	// MARK: - Index readiness

	/// Waits until the server has stopped indexing, or `timeout` passes. Workspace-wide answers
	/// (references, callers, implementations) rest on the index and are silently incomplete
	/// while it is still being built, so those tools wait first and report what they got.
	public func waitForIndex(timeout: TimeInterval, settle: TimeInterval = 0.5) async -> IndexStatus {
		let deadline = Date().addingTimeInterval(timeout)
		while true {
			let quiet = Date().timeIntervalSince(lastActivity) >= settle
			if activeProgress.isEmpty, quiet { return IndexStatus(isReady: true, detail: nil) }
			if Date() >= deadline { return IndexStatus(isReady: false, detail: indexDetail()) }
			try? await Task.sleep(nanoseconds: 100_000_000)
		}
	}

	/// What the server is busy with right now, or nil when idle.
	public func indexProgressDescription() -> String? {
		activeProgress.isEmpty ? nil : indexDetail()
	}

	private func indexDetail() -> String? {
		guard let info = activeProgress.values.first else { return nil }
		var text = info.title
		if let message = info.message { text += " \(message)" }
		if let percentage = info.percentage { text += " (\(percentage)%)" }
		return text
	}

	// MARK: - Document sync

	public func resolve(_ filePath: String) -> URL {
		canonicalFileURL(filePath, relativeTo: configuration.workspaceRoot)
	}

	@discardableResult
	public func ensureOpen(_ filePath: String) async throws -> String {
		let url = resolve(filePath)
		let uri = url.absoluteString
		if overlays.contains(uri) { return uri }
		let stamp = try Self.stamp(of: url)
		if let known = openFiles[uri], known.modified == stamp.modified, known.size == stamp.size { return uri }
		let text = try readTextFile(url)
		diagnosticsArrived.remove(uri)
		lastActivity = Date()
		if let known = openFiles[uri] {
			// The previous version's pushed diagnostics describe text that no longer exists.
			pushedDiagnostics.removeValue(forKey: uri)
			let version = known.version + 1
			notify(
				"textDocument/didChange",
				params: [
					"textDocument": ["uri": .string(uri), "version": .int(version)],
					"contentChanges": [["text": .string(text)]],
				]
			)
			openFiles[uri] = OpenFile(version: version, modified: stamp.modified, size: stamp.size, text: text)
		} else {
			notify(
				"textDocument/didOpen",
				params: [
					"textDocument": [
						"uri": .string(uri), "languageId": .string(Self.languageID(for: url, default: configuration.languageID)), "version": 1, "text": .string(text),
					]
				]
			)
			openFiles[uri] = OpenFile(version: 1, modified: stamp.modified, size: stamp.size, text: text)
		}
		return uri
	}

	/// The LSP language of a file by extension, so Objective-C and C sources in a mixed project are
	/// served by sourcekit-lsp's clang side instead of being parsed as Swift.
	static func languageID(for url: URL, default fallback: String) -> String {
		switch url.pathExtension.lowercased() {
		case "m", "h": "objective-c"
		case "mm": "objective-cpp"
		case "c": "c"
		case "cpp", "cc", "cxx", "hpp": "cpp"
		default: fallback
		}
	}

	private static func stamp(of url: URL) throws -> FileStamp {
		do {
			let values = try url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
			return FileStamp(modified: values.contentModificationDate ?? .distantPast, size: values.fileSize ?? 0)
		} catch {
			throw ToolInputError("File not found: \(url.path) (relative paths resolve against the workspace root).")
		}
	}

	private func closeDocument(_ uri: String) {
		notify("textDocument/didClose", params: ["textDocument": ["uri": .string(uri)]])
		openFiles.removeValue(forKey: uri)
		pushedDiagnostics.removeValue(forKey: uri)
		diagnosticsArrived.remove(uri)
		symbolCache.removeValue(forKey: uri)  // reopening restarts versions at 1, which could falsely match
	}

	// MARK: - Change detection

	private struct Scan: Sendable {
		var sources: [URL: FileStamp]
		var configs: [URL: FileStamp]
	}

	/// (mtime, size) of every watched source file and every config file. Runs on every tool call,
	/// so it resolves the root once, and it skips nested checkouts: a directory holding a `.git`
	/// entry below the root is another repository or linked worktree, whose files are neither this
	/// workspace's nor cheap to stat.
	private static func scanWatched(root: URL, suffixes: Set<String>, configNames: Set<String>) -> Scan {
		var scan = Scan(sources: [:], configs: [:])
		if suffixes.isEmpty && configNames.isEmpty { return scan }
		let fileManager = FileManager.default
		let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .contentModificationDateKey, .fileSizeKey]
		let root = root.realPath
		var stack = [root]
		while let directory = stack.popLast() {
			guard let entries = try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys) else {
				continue
			}
			if directory != root, entries.contains(where: { $0.lastPathComponent == ".git" }) { continue }
			for entry in entries {
				let name = entry.lastPathComponent
				guard let values = try? entry.resourceValues(forKeys: Set(keys)) else { continue }
				if values.isDirectory == true, values.isSymbolicLink != true {
					if !Exclude.directoryNames.contains(name) { stack.append(entry) }
					continue
				}
				let isConfig = configNames.contains(name)
				if !isConfig, !suffixes.contains("." + entry.pathExtension.lowercased()) { continue }
				let stamp = FileStamp(modified: values.contentModificationDate ?? .distantPast, size: values.fileSize ?? 0)
				let key = values.isSymbolicLink == true ? entry.realPath : entry
				if isConfig { scan.configs[key] = stamp } else { scan.sources[key] = stamp }
			}
		}
		return scan
	}

	/// Brings the language server's view of the disk up to date.
	///
	/// Servers only see what a client tells them: a document opened with `didOpen` is frozen at
	/// that text, and files created/edited/deleted behind the server's back (by the agent's own
	/// edits, git, a formatter) are invisible to workspace-wide answers. Call this before every
	/// tool call; it costs one stat walk. Open documents are re-synced (or closed when deleted),
	/// and watched files that appeared/changed/vanished since the last call are reported via
	/// `workspace/didChangeWatchedFiles`. A change to a config file restarts the server instead
	/// (it only reads those at startup).
	public func refresh() async throws {
		while refreshInProgress { try await Task.sleep(nanoseconds: 20_000_000) }
		refreshInProgress = true
		defer { refreshInProgress = false }

		let root = configuration.workspaceRoot
		let suffixes = configuration.watchSuffixes
		let names = configuration.configNames
		let scan = await Task.detached(priority: .utility) {
			Self.scanWatched(root: root, suffixes: suffixes, configNames: names)
		}.value

		let previousConfigs = configSnapshot
		configSnapshot = scan.configs
		if let previousConfigs, previousConfigs != scan.configs {
			let touched = Set(previousConfigs.keys).symmetricDifference(scan.configs.keys)
				.union(scan.configs.filter { previousConfigs[$0.key] != $0.value }.keys)
			let names = Set(touched.map(\.lastPathComponent)).sorted()
			watchSnapshot = scan.sources
			try await restart()
			onNotice?("restarted the language server because \(names.joined(separator: ", ")) changed")
			return
		}

		var changes: [JSONValue] = []
		if let previous = watchSnapshot {
			for (url, stamp) in scan.sources {
				if previous[url] == nil {
					changes.append(Self.change(url, .created))
				} else if previous[url] != stamp {
					changes.append(Self.change(url, .changed))
				}
			}
			for url in previous.keys where scan.sources[url] == nil {
				changes.append(Self.change(url, .deleted))
			}
		}
		watchSnapshot = scan.sources
		if !changes.isEmpty {
			lastActivity = Date()
			notify("workspace/didChangeWatchedFiles", params: ["changes": .array(changes)])
		}
		for (uri, _) in openFiles {
			guard !overlays.contains(uri), let url = URL(string: uri) else { continue }
			if FileManager.default.fileExists(atPath: url.path) {
				try await ensureOpen(url.path)
			} else {
				closeDocument(uri)
			}
		}
	}

	private static func change(_ url: URL, _ type: FileChange) -> JSONValue {
		["uri": .string(url.absoluteString), "type": .int(type.rawValue)]
	}

	// MARK: - In-memory documents

	/// Shows the server `text` for a file without touching the disk, so diagnostics, hover and
	/// references answer for the proposed version. Pair with `clearOverlay`.
	public func setOverlay(_ filePath: String, text: String) {
		let uri = resolve(filePath).absoluteString
		diagnosticsArrived.remove(uri)
		pushedDiagnostics.removeValue(forKey: uri)
		lastActivity = Date()
		if let known = openFiles[uri] {
			let version = known.version + 1
			notify(
				"textDocument/didChange",
				params: ["textDocument": ["uri": .string(uri), "version": .int(version)], "contentChanges": [["text": .string(text)]]])
			openFiles[uri] = OpenFile(version: version, modified: known.modified, size: known.size, text: text)
		} else {
			notify(
				"textDocument/didOpen",
				params: [
					"textDocument": [
						"uri": .string(uri), "languageId": .string(Self.languageID(for: URL(string: uri) ?? resolve(filePath), default: configuration.languageID)),
						"version": 1, "text": .string(text),
					]
				])
			openFiles[uri] = OpenFile(version: 1, modified: .distantPast, size: -1, text: text)
		}
		overlays.insert(uri)
	}

	/// Goes back to the on-disk text (or closes the document when the file doesn't exist).
	public func clearOverlay(_ filePath: String) async throws {
		let url = resolve(filePath)
		let uri = url.absoluteString
		guard overlays.remove(uri) != nil else { return }
		if FileManager.default.fileExists(atPath: url.path) {
			openFiles[uri]?.modified = .distantPast
			openFiles[uri]?.size = -1
			try await ensureOpen(url.path)
		} else {
			closeDocument(uri)
		}
	}

	public func clearAllOverlays() async {
		for uri in overlays {
			if let url = URL(string: uri) { try? await clearOverlay(url.path) }
		}
	}

	/// Asks for the diagnostics of files and drops the answer. sourcekit-lsp only folds a changed document
	/// into what other files see once something has been requested of that document, so after changing or
	/// reverting documents this is what makes the other files' answers current instead of cached.
	public func touch(_ filePaths: [String]) async {
		for path in filePaths { _ = try? await diagnostics(path) }
	}

	public func hasOverlay(_ filePath: String) -> Bool {
		overlays.contains(resolve(filePath).absoluteString)
	}

	/// The text the server currently holds for a file, when it is an in-memory version.
	public func overlayText(_ filePath: String) -> String? {
		let uri = resolve(filePath).absoluteString
		return overlays.contains(uri) ? openFiles[uri]?.text : nil
	}

	// MARK: - LSP calls used by the tools

	private func positionParams(_ uri: String, line: Int, column: Int) -> JSONValue {
		["textDocument": ["uri": .string(uri)], "position": ["line": .int(line - 1), "character": .int(column - 1)]]
	}

	/// Rejects a position outside the file, so a typo isn't answered with an empty result
	/// indistinguishable from "nothing there".
	private func checkPosition(uri: String, filePath: String, line: Int, column: Int) throws {
		guard let text = openFiles[uri]?.text else { return }
		var lines = Self.splitLines(text)
		if lines.count > 1, lines.last == "" { lines.removeLast() }  // the "line" after the final newline isn't pointable
		guard (1...max(lines.count, 1)).contains(line) else {
			throw InvalidPositionError(
				message: "line \(line) is out of range: \(filePath) has \(lines.count) line(s) (lines are 1-indexed)"
			)
		}
		let width = lines[line - 1].utf16.count
		guard (1...(width + 1)).contains(column) else {
			throw InvalidPositionError(
				message:
					"column \(column) is out of range: line \(line) of \(filePath) is \(width) character(s) long (columns are 1-indexed UTF-16 offsets; a tab counts as one)"
			)
		}
	}

	static func splitLines(_ text: String) -> [String] {
		var lines: [String] = []
		var current = ""
		var previousWasCR = false
		for character in text.unicodeScalars {
			switch character {
			case "\r":
				lines.append(current)
				current = ""
				previousWasCR = true
			case "\n":
				if previousWasCR { previousWasCR = false; continue }
				lines.append(current)
				current = ""
			default:
				previousWasCR = false
				current.unicodeScalars.append(character)
			}
		}
		lines.append(current)
		return lines
	}

	private func positional<Result: Decodable>(
		_ method: String, _ filePath: String, line: Int, column: Int, extra: [String: JSONValue] = [:],
		as type: Result.Type
	) async throws -> Result? {
		let uri = try await ensureOpen(filePath)
		try checkPosition(uri: uri, filePath: filePath, line: line, column: column)
		var params = positionParams(uri, line: line, column: column).objectValue ?? [:]
		params.merge(extra) { $1 }
		return try await request(method, params: .object(params), as: type)
	}

	public func hover(_ filePath: String, line: Int, column: Int) async throws -> String {
		try await positional("textDocument/hover", filePath, line: line, column: column, as: HoverResult.self)?.text ?? ""
	}

	public func definition(_ filePath: String, line: Int, column: Int) async throws -> [LSPLocation] {
		try await positional("textDocument/definition", filePath, line: line, column: column, as: LSPLocationList.self)?
			.locations ?? []
	}

	public func typeDefinition(_ filePath: String, line: Int, column: Int) async throws -> [LSPLocation] {
		try await positional("textDocument/typeDefinition", filePath, line: line, column: column, as: LSPLocationList.self)?
			.locations ?? []
	}

	public func implementation(_ filePath: String, line: Int, column: Int) async throws -> [LSPLocation] {
		try await positional("textDocument/implementation", filePath, line: line, column: column, as: LSPLocationList.self)?
			.locations ?? []
	}

	public func references(_ filePath: String, line: Int, column: Int, includeDeclaration: Bool = true) async throws
		-> [LSPLocation]
	{
		try await positional(
			"textDocument/references", filePath, line: line, column: column,
			extra: ["context": ["includeDeclaration": .bool(includeDeclaration)]], as: [LSPLocation].self
		) ?? []
	}

	public func workspaceSymbol(_ query: String) async throws -> [WorkspaceSymbol] {
		let symbols = try await request("workspace/symbol", params: ["query": .string(query)], as: [WorkspaceSymbol].self) ?? []
		return symbols.map(Self.refiningNullKind)
	}

	/// The index reports some declarations (typealiases from a dependency, for one) with the placeholder kind
	/// `Null`; the declaration line says what they really are.
	private static func refiningNullKind(_ symbol: WorkspaceSymbol) -> WorkspaceSymbol {
		guard symbol.kind == 21, let line = symbol.location.range?.start.line,
			let text = readLines(of: symbol.location.uri).flatMap({ $0.indices.contains(line) ? $0[line] : nil }), let kind = SymbolKind.infer(fromDeclaration: text)
		else { return symbol }
		var refined = symbol
		refined.kind = kind
		return refined
	}

	public func documentSymbol(_ filePath: String) async throws -> [DocumentSymbol] {
		let uri = try await ensureOpen(filePath)
		guard let version = openFiles[uri]?.version else { return [] }
		if let hit = symbolCache[uri], hit.version == version { return hit.symbols }
		let symbols =
			try await request(
				"textDocument/documentSymbol", params: ["textDocument": ["uri": .string(uri)]], as: [DocumentSymbol].self
			) ?? []
		symbolCache[uri] = (version, symbols)
		return symbols
	}

	public func prepareCallHierarchy(_ filePath: String, line: Int, column: Int) async throws -> [HierarchyItem] {
		let uri = try await ensureOpen(filePath)
		return try await request(
			"textDocument/prepareCallHierarchy", params: positionParams(uri, line: line, column: column),
			as: [HierarchyItem].self
		) ?? []
	}

	public func incomingCalls(_ item: HierarchyItem) async throws -> [IncomingCall] {
		try await request("callHierarchy/incomingCalls", params: ["item": try JSONValue.encode(item)], as: [IncomingCall].self)
			?? []
	}

	public func prepareTypeHierarchy(_ filePath: String, line: Int, column: Int) async throws -> [HierarchyItem] {
		let uri = try await ensureOpen(filePath)
		return try await request(
			"textDocument/prepareTypeHierarchy", params: positionParams(uri, line: line, column: column),
			as: [HierarchyItem].self
		) ?? []
	}

	public func supertypes(_ item: HierarchyItem) async throws -> [HierarchyItem] {
		try await request("typeHierarchy/supertypes", params: ["item": try JSONValue.encode(item)], as: [HierarchyItem].self)
			?? []
	}

	public func subtypes(_ item: HierarchyItem) async throws -> [HierarchyItem] {
		try await request("typeHierarchy/subtypes", params: ["item": try JSONValue.encode(item)], as: [HierarchyItem].self)
			?? []
	}

	/// Quick fixes and refactorings offered for a range. `diagnostics` are the ones the range is about.
	public func codeActions(
		_ filePath: String, range: LSPRange, diagnostics: [LSPDiagnostic] = [], only: [String]? = nil
	) async throws -> [LSPCodeAction] {
		let uri = try await ensureOpen(filePath)
		var context: [String: JSONValue] = ["diagnostics": .array(diagnostics.compactMap(\.raw))]
		if let only { context["only"] = .array(only.map { .string($0) }) }
		return try await request(
			"textDocument/codeAction",
			params: ["textDocument": ["uri": .string(uri)], "range": try JSONValue.encode(range), "context": .object(context)],
			as: [LSPCodeAction].self) ?? []
	}

	/// Runs a server command (a refactoring) and returns the edits it asks the client to apply.
	public func executeCommand(_ command: LSPCodeAction.Command) async throws -> LSPWorkspaceEdit {
		capturedEdits = LSPWorkspaceEdit()
		defer { capturedEdits = nil }
		_ = try await request(
			"workspace/executeCommand",
			params: ["command": .string(command.command), "arguments": .array(command.arguments ?? [])], as: JSONValue.self)
		return capturedEdits ?? LSPWorkspaceEdit()
	}

	public func prepareRename(_ filePath: String, line: Int, column: Int) async throws -> PrepareRenameResult? {
		try await positional("textDocument/prepareRename", filePath, line: line, column: column, as: PrepareRenameResult.self)
	}

	/// The edits renaming the symbol at a position to `newName` (`make(named:)` renames argument labels too).
	public func rename(_ filePath: String, line: Int, column: Int, newName: String) async throws -> LSPWorkspaceEdit {
		try await positional(
			"textDocument/rename", filePath, line: line, column: column, extra: ["newName": .string(newName)],
			as: LSPWorkspaceEdit.self) ?? LSPWorkspaceEdit()
	}

	public func diagnostics(_ filePath: String) async throws -> [LSPDiagnostic] {
		let uri = try await ensureOpen(filePath)
		let cached = pushedDiagnostics[uri] ?? []
		let report: DiagnosticReport?
		do {
			report = try await request(
				"textDocument/diagnostic", params: ["textDocument": ["uri": .string(uri)]], as: DiagnosticReport.self
			)
		} catch is LSPRequestError {
			// Push-only servers reject pull. If the document was just (re)synced, the push for
			// this version hasn't necessarily arrived yet: wait for it rather than report the
			// previous version's (or an empty) result.
			if !diagnosticsArrived.contains(uri) { await waitForPushedDiagnostics(uri) }
			return pushedDiagnostics[uri] ?? []
		}
		if report?.kind == "unchanged" { return cached }
		// A pull answer for the current version is authoritative, empty included.
		return report?.items ?? cached
	}

	private func waitForPushedDiagnostics(_ uri: String) async {
		if diagnosticsArrived.contains(uri) { return }
		let timer = Task { [weak self] in
			try? await Task.sleep(nanoseconds: UInt64(Self.pushDiagnosticsTimeout * 1_000_000_000))
			await self?.resumeDiagnosticWaiters(uri)
		}
		await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
			diagnosticWaiters[uri, default: []].append(continuation)
		}
		timer.cancel()
	}

	private func resumeDiagnosticWaiters(_ uri: String) {
		for waiter in diagnosticWaiters.removeValue(forKey: uri) ?? [] { waiter.resume() }
	}
}

extension JSONEncoder {
	static let lsp: JSONEncoder = {
		let encoder = JSONEncoder()
		encoder.outputFormatting = [.withoutEscapingSlashes]
		return encoder
	}()
}

extension JSONValue {
	static func encode<Value: Encodable>(_ value: Value) throws -> JSONValue {
		try JSONDecoder().decode(JSONValue.self, from: JSONEncoder.lsp.encode(value))
	}

	static func decode<Value: Decodable>(_ type: Value.Type, from json: JSONValue) throws -> Value {
		try JSONDecoder().decode(type, from: JSONEncoder.lsp.encode(json))
	}
}
