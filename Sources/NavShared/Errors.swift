import Foundation

/// Expected tool failures, rendered as agent-readable text.
///
/// MCP hosts collapse an error a tool throws into something opaque, hiding actionable
/// causes like a mistyped path. Tools catch everything and return `formatToolError`.

/// The caller asked for something the tool can't serve (unsupported file type, a
/// missing parameter, an ambiguous name, ...). The message is shown verbatim.
public struct ToolInputError: Error, Sendable, Equatable {
	public var message: String

	public init(_ message: String) {
		self.message = message
	}
}

/// JSON-RPC error response from the language server.
public struct LSPRequestError: Error, Sendable {
	public var method: String
	public var code: Int?
	public var message: String

	public init(method: String, code: Int?, message: String) {
		self.method = method
		self.code = code
		self.message = message
	}
}

/// The language server did not answer in time.
public struct LSPTimeoutError: Error, Sendable {
	public var method: String

	public init(method: String) {
		self.method = method
	}
}

/// The language server process ended while a request was pending.
public struct LanguageServerExitedError: Error, Sendable {
	public var message: String

	public init(message: String) {
		self.message = message
	}
}

/// The language server could not be launched at all.
public struct LanguageServerLaunchError: Error, Sendable {
	public var message: String

	public init(message: String) {
		self.message = message
	}
}

/// A tool was asked about a line/column that doesn't exist in the file.
public struct InvalidPositionError: Error, Sendable {
	public var message: String

	public init(message: String) {
		self.message = message
	}
}

public func formatToolError(_ error: Error) -> String {
	switch error {
	case let error as ToolInputError:
		return error.message
	case let error as LSPRequestError:
		return "LSP error on \(error.method): \(error.message)"
	case is LSPTimeoutError:
		return "Language server timed out (it may still be indexing the workspace); retry shortly."
	case let error as LanguageServerExitedError:
		return error.message
	case let error as LanguageServerLaunchError:
		return error.message
	case let error as InvalidPositionError:
		return error.message
	case is CancellationError:
		return "The request was cancelled."
	default:
		return "Unexpected error: \(error.localizedDescription)"
	}
}

/// Reads a UTF-8 text file, mapping failures to errors worth showing an agent.
public func readTextFile(_ url: URL) throws -> String {
	let data: Data
	do {
		data = try Data(contentsOf: url)
	} catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
		throw ToolInputError("File not found: \(url.path) (relative paths resolve against the workspace root).")
	} catch {
		throw ToolInputError("Cannot read \(url.path): \(error.localizedDescription).")
	}
	guard String(data: data, encoding: .utf8) != nil else {
		throw ToolInputError("Cannot read \(url.path) as UTF-8 text.")
	}
	// Not `String(data:encoding:)`'s result: it drops a leading byte-order mark, and an edit would then delete it from the file.
	return String(decoding: data, as: UTF8.self)
}
