import Foundation

// Typed models for the slice of LSP the navigation tools use. Decoding is lenient
// about the alternative shapes servers may answer with (Location vs LocationLink,
// MarkupContent vs MarkedString, ...), so the rest of the code sees one shape.

public struct LSPPosition: Codable, Sendable, Hashable {
	public var line: Int
	public var character: Int

	public init(line: Int, character: Int) {
		self.line = line
		self.character = character
	}
}

public struct LSPRange: Codable, Sendable, Hashable {
	public var start: LSPPosition
	public var end: LSPPosition

	public init(start: LSPPosition, end: LSPPosition) {
		self.start = start
		self.end = end
	}
}

/// A `Location`, or a `LocationLink` flattened to its target (preferring the
/// narrower selection range, which is the symbol's name rather than its whole span).
public struct LSPLocation: Decodable, Sendable, Hashable {
	public var uri: String
	public var range: LSPRange

	public init(uri: String, range: LSPRange) {
		self.uri = uri
		self.range = range
	}

	private enum CodingKeys: String, CodingKey {
		case uri, range, targetUri, targetRange, targetSelectionRange
	}

	public init(from decoder: Decoder) throws {
		let container = try decoder.container(keyedBy: CodingKeys.self)
		if let uri = try container.decodeIfPresent(String.self, forKey: .uri) {
			self.uri = uri
			self.range = try container.decode(LSPRange.self, forKey: .range)
		} else {
			self.uri = try container.decode(String.self, forKey: .targetUri)
			let selection = try container.decodeIfPresent(LSPRange.self, forKey: .targetSelectionRange)
			self.range = try selection ?? container.decode(LSPRange.self, forKey: .targetRange)
		}
	}
}

/// `Location | Location[] | LocationLink[] | null`.
public struct LSPLocationList: Decodable, Sendable {
	public var locations: [LSPLocation]

	public init(from decoder: Decoder) throws {
		let container = try decoder.singleValueContainer()
		if container.decodeNil() {
			locations = []
		} else if let many = try? container.decode([LSPLocation].self) {
			locations = many
		} else {
			locations = [try container.decode(LSPLocation.self)]
		}
	}
}

/// A workspace-wide symbol hit (`SymbolInformation` / `WorkspaceSymbol`).
public struct WorkspaceSymbol: Decodable, Sendable, Hashable {
	public struct Location: Decodable, Sendable, Hashable {
		public var uri: String
		public var range: LSPRange?
	}

	public var name: String
	public var kind: Int
	public var containerName: String?
	public var location: Location

	public init(name: String, kind: Int, containerName: String? = nil, uri: String, range: LSPRange? = nil) {
		self.name = name
		self.kind = kind
		self.containerName = containerName
		self.location = Location(uri: uri, range: range)
	}
}

/// A hierarchical `DocumentSymbol`.
public struct DocumentSymbol: Decodable, Sendable, Hashable {
	public var name: String
	public var detail: String?
	public var kind: Int
	public var range: LSPRange
	public var selectionRange: LSPRange
	public var children: [DocumentSymbol]?
}

/// A call- or type-hierarchy item. `data` is opaque to us but must be echoed back verbatim.
public struct HierarchyItem: Codable, Sendable, Hashable {
	public var name: String
	public var kind: Int
	public var detail: String?
	public var uri: String
	public var range: LSPRange
	public var selectionRange: LSPRange
	public var data: JSONValue?
}

public struct IncomingCall: Decodable, Sendable {
	public var from: HierarchyItem
	public var fromRanges: [LSPRange]
}

public struct LSPDiagnostic: Decodable, Sendable {
	public var range: LSPRange
	public var severity: Int?
	public var code: JSONValue?
	public var message: String
	/// Quick fixes sourcekit-lsp attaches to the diagnostic (`Insert ', overwrite: '`, `Add missing case`, ...).
	public var fixes: [LSPCodeAction] = []
	/// The diagnostic exactly as the server sent it, to hand back in a `codeAction` request's context.
	public var raw: JSONValue?

	public var codeText: String? {
		switch code {
		case .string(let value): return value
		case .int(let value): return String(value)
		default: return nil
		}
	}

	public var isError: Bool { severity == nil || severity == 1 }
	public var isWarning: Bool { severity == 2 }

	private enum CodingKeys: String, CodingKey { case range, severity, code, message, codeActions }

	public init(range: LSPRange, severity: Int?, message: String, code: JSONValue? = nil, fixes: [LSPCodeAction] = []) {
		self.range = range
		self.severity = severity
		self.message = message
		self.code = code
		self.fixes = fixes
	}

	public init(from decoder: Decoder) throws {
		let container = try decoder.container(keyedBy: CodingKeys.self)
		range = try container.decode(LSPRange.self, forKey: .range)
		severity = try container.decodeIfPresent(Int.self, forKey: .severity)
		code = try container.decodeIfPresent(JSONValue.self, forKey: .code)
		message = try container.decode(String.self, forKey: .message)
		fixes = (try? container.decodeIfPresent([LSPCodeAction].self, forKey: .codeActions)) ?? []
		raw = try? decoder.singleValueContainer().decode(JSONValue.self)
	}
}

/// A `CodeAction`: an edit to apply, or a server command to execute (which answers with edits).
public struct LSPCodeAction: Decodable, Sendable {
	public struct Command: Codable, Sendable, Hashable {
		public var title: String?
		public var command: String
		public var arguments: [JSONValue]?
	}

	public var title: String
	public var kind: String?
	public var edit: LSPWorkspaceEdit?
	public var command: Command?

	public init(title: String, kind: String? = nil, edit: LSPWorkspaceEdit? = nil, command: Command? = nil) {
		self.title = title
		self.kind = kind
		self.edit = edit
		self.command = command
	}

	private enum CodingKeys: String, CodingKey { case title, kind, edit, command }

	public init(from decoder: Decoder) throws {
		let container = try decoder.container(keyedBy: CodingKeys.self)
		title = try container.decode(String.self, forKey: .title)
		kind = try container.decodeIfPresent(String.self, forKey: .kind)
		edit = try container.decodeIfPresent(LSPWorkspaceEdit.self, forKey: .edit)
		// `command` is a Command object on an action and a bare string on a bare Command.
		command = try? container.decodeIfPresent(Command.self, forKey: .command)
	}
}

/// Answer to `textDocument/prepareRename`: `Range | { range, placeholder } | { defaultBehavior }`.
public struct PrepareRenameResult: Decodable, Sendable {
	public var range: LSPRange?
	public var placeholder: String?

	private enum CodingKeys: String, CodingKey { case range, placeholder, start, end }

	public init(from decoder: Decoder) throws {
		let container = try decoder.container(keyedBy: CodingKeys.self)
		if let range = try container.decodeIfPresent(LSPRange.self, forKey: .range) {
			self.range = range
		} else if let start = try container.decodeIfPresent(LSPPosition.self, forKey: .start),
			let end = try container.decodeIfPresent(LSPPosition.self, forKey: .end)
		{
			range = LSPRange(start: start, end: end)
		}
		placeholder = try container.decodeIfPresent(String.self, forKey: .placeholder)
	}
}

/// `textDocument/diagnostic` answer: a full report, or "unchanged".
struct DiagnosticReport: Decodable {
	var kind: String?
	var items: [LSPDiagnostic]?
}

/// Hover contents in any of the shapes the spec allows, flattened to text.
public struct HoverResult: Decodable, Sendable {
	public var text: String

	private enum CodingKeys: String, CodingKey { case contents }

	private struct Fragment: Decodable {
		var text: String

		init(from decoder: Decoder) throws {
			let container = try decoder.singleValueContainer()
			if let plain = try? container.decode(String.self) {
				text = plain
			} else {
				let object = try container.decode([String: JSONValue].self)
				text = object["value"]?.stringValue ?? ""
			}
		}
	}

	public init(from decoder: Decoder) throws {
		let container = try decoder.container(keyedBy: CodingKeys.self)
		if let many = try? container.decode([Fragment].self, forKey: .contents) {
			text = many.map(\.text).joined(separator: "\n")
		} else {
			text = try container.decode(Fragment.self, forKey: .contents).text
		}
		text = text.trimmingCharacters(in: .whitespacesAndNewlines)
	}
}
