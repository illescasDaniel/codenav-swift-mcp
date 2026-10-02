import Foundation

// Applying LSP-style edits to text, in memory. Positions are 0-based lines and UTF-16 columns, the
// units sourcekit-lsp speaks. Everything here is pure so the edit tools can be tested without a server.

public struct TextEdit: Codable, Sendable, Hashable {
	public var range: LSPRange
	public var newText: String

	public init(range: LSPRange, newText: String) {
		self.range = range
		self.newText = newText
	}

	public init(line: Int, column: Int, endLine: Int, endColumn: Int, newText: String) {
		self.init(
			range: LSPRange(
				start: LSPPosition(line: line, character: column), end: LSPPosition(line: endLine, character: endColumn)),
			newText: newText)
	}
}

public struct TextEditError: Error, Sendable, Equatable {
	public var message: String

	public init(_ message: String) {
		self.message = message
	}
}

/// A text document as UTF-16 units with a line index, so LSP positions map to offsets in O(1).
public struct TextIndex: Sendable {
	public let units: [UInt16]
	/// Offset of the first unit of each line. A trailing line break yields a final empty line, as LSP counts.
	public let lineStarts: [Int]

	public init(_ text: String) {
		units = Array(text.utf16)
		var starts = [0]
		var index = 0
		while index < units.count {
			let unit = units[index]
			if unit == 0x0A {
				starts.append(index + 1)
			} else if unit == 0x0D {
				if index + 1 < units.count, units[index + 1] == 0x0A { index += 1 }
				starts.append(index + 1)
			}
			index += 1
		}
		lineStarts = starts
	}

	public var lineCount: Int { lineStarts.count }

	/// End of the line's content, before its line break.
	public func lineEnd(_ line: Int) -> Int {
		var end = line + 1 < lineStarts.count ? lineStarts[line + 1] : units.count
		while end > lineStarts[line], units[end - 1] == 0x0A || units[end - 1] == 0x0D { end -= 1 }
		return end
	}

	/// Offset for a position; columns past the end of the line clamp to it (LSP says so).
	public func offset(_ position: LSPPosition) throws -> Int {
		guard position.line >= 0, position.line < lineStarts.count else {
			throw TextEditError("line \(position.line + 1) is out of range (the text has \(lineStarts.count) line(s))")
		}
		guard position.character >= 0 else { throw TextEditError("negative column") }
		return min(lineStarts[position.line] + position.character, lineEnd(position.line))
	}

	/// Inverse of `offset`.
	public func position(at offset: Int) -> LSPPosition {
		var low = 0
		var high = lineStarts.count - 1
		while low < high {
			let mid = (low + high + 1) / 2
			if lineStarts[mid] <= offset { low = mid } else { high = mid - 1 }
		}
		return LSPPosition(line: low, character: offset - lineStarts[low])
	}

	public func text(from start: Int, to end: Int) -> String {
		String(decoding: units[start..<end], as: UTF16.self)
	}

	public func text(in range: LSPRange) throws -> String {
		text(from: try offset(range.start), to: try offset(range.end))
	}

	/// The text of a 0-based line, without its line break.
	public func lineText(_ line: Int) -> String {
		guard line >= 0, line < lineStarts.count else { return "" }
		return text(from: lineStarts[line], to: lineEnd(line))
	}
}

public enum TextEditing {
	/// Applies edits (all positions refer to the original text, as in LSP). Overlapping edits are an
	/// error; two inserts at the same spot keep the order they were given in.
	public static func apply(_ edits: [TextEdit], to text: String) throws -> String {
		guard !edits.isEmpty else { return text }
		let index = TextIndex(text)
		var resolved: [(start: Int, end: Int, text: [UInt16], order: Int)] = []
		for (order, edit) in edits.enumerated() {
			let start = try index.offset(edit.range.start)
			let end = try index.offset(edit.range.end)
			guard start <= end else { throw TextEditError("an edit ends before it starts") }
			resolved.append((start, end, Array(edit.newText.utf16), order))
		}
		resolved.sort { ($0.start, $0.end, $0.order) < ($1.start, $1.end, $1.order) }
		for pair in zip(resolved, resolved.dropFirst()) where pair.1.start < pair.0.end {
			let at = index.position(at: pair.1.start)
			throw TextEditError("two edits overlap around line \(at.line + 1)")
		}
		var output: [UInt16] = []
		output.reserveCapacity(index.units.count)
		var cursor = 0
		for edit in resolved {
			output.append(contentsOf: index.units[cursor..<edit.start])
			output.append(contentsOf: edit.text)
			cursor = edit.end
		}
		output.append(contentsOf: index.units[cursor...])
		return String(decoding: output, as: UTF16.self)
	}

	/// The edits that turn `old` into `new`: one edit covering what differs after trimming the common
	/// prefix and suffix (whole lines, so the result reads like a line diff).
	public static func replacement(from old: String, to new: String) -> TextEdit? {
		guard old != new else { return nil }
		let before = TextIndex(old)
		let after = TextIndex(new)
		var prefix = 0
		let limit = min(before.units.count, after.units.count)
		while prefix < limit, before.units[prefix] == after.units[prefix] { prefix += 1 }
		var suffix = 0
		while suffix < limit - prefix, before.units[before.units.count - 1 - suffix] == after.units[after.units.count - 1 - suffix] {
			suffix += 1
		}
		let start = before.position(at: prefix)
		let end = before.position(at: before.units.count - suffix)
		let newStart = after.units.index(after.units.startIndex, offsetBy: prefix)
		let newEnd = after.units.count - suffix
		return TextEdit(
			range: LSPRange(start: start, end: end), newText: String(decoding: after.units[newStart..<newEnd], as: UTF16.self))
	}

	/// 1-indexed line numbers of every occurrence of `needle` in `text` (start lines), for error messages.
	public static func lines(of needle: String, in text: String) -> [Int] {
		guard !needle.isEmpty else { return [] }
		var result: [Int] = []
		var searchRange = text.startIndex..<text.endIndex
		while let found = text.range(of: needle, options: [], range: searchRange) {
			let line = text[text.startIndex..<found.lowerBound].reduce(1) { $1 == "\n" ? $0 + 1 : $0 }
			result.append(line)
			searchRange = found.upperBound..<text.endIndex
		}
		return result
	}
}

// MARK: - Workspace edits

/// A `WorkspaceEdit` reduced to what the edit tools handle: text edits per file URI. Resource operations
/// (create/rename/delete file) are kept apart, so a caller can refuse what it can't apply safely.
public struct LSPWorkspaceEdit: Decodable, Sendable {
	public var fileEdits: [String: [TextEdit]] = [:]
	public var resourceOperations: [String] = []

	public init() {}

	public init(fileEdits: [String: [TextEdit]]) {
		self.fileEdits = fileEdits
	}

	private enum CodingKeys: String, CodingKey { case changes, documentChanges }

	private struct DocumentChange: Decodable {
		struct Document: Decodable { var uri: String }
		var textDocument: Document?
		var edits: [TextEdit]?
		var kind: String?
		var uri: String?
		var oldUri: String?
		var newUri: String?

		private enum CodingKeys: String, CodingKey { case textDocument, edits, kind, uri, oldUri, newUri }

		init(from decoder: Decoder) throws {
			let container = try decoder.container(keyedBy: CodingKeys.self)
			textDocument = try container.decodeIfPresent(Document.self, forKey: .textDocument)
			kind = try container.decodeIfPresent(String.self, forKey: .kind)
			uri = try container.decodeIfPresent(String.self, forKey: .uri)
			oldUri = try container.decodeIfPresent(String.self, forKey: .oldUri)
			newUri = try container.decodeIfPresent(String.self, forKey: .newUri)
			// Annotated edits carry an extra `annotationId`; the fields we read are the same.
			edits = try container.decodeIfPresent([TextEdit].self, forKey: .edits)
		}
	}

	public init(from decoder: Decoder) throws {
		let container = try decoder.container(keyedBy: CodingKeys.self)
		if let changes = try container.decodeIfPresent([String: [TextEdit]].self, forKey: .changes) {
			for (uri, edits) in changes { fileEdits[uri, default: []].append(contentsOf: edits) }
		}
		if let documentChanges = try container.decodeIfPresent([DocumentChange].self, forKey: .documentChanges) {
			for change in documentChanges {
				if let document = change.textDocument, let edits = change.edits {
					fileEdits[document.uri, default: []].append(contentsOf: edits)
				} else if let kind = change.kind {
					resourceOperations.append("\(kind) \(change.uri ?? change.oldUri ?? "?")")
				}
			}
		}
	}

	public var isEmpty: Bool { fileEdits.values.allSatisfy(\.isEmpty) && resourceOperations.isEmpty }

	public var editCount: Int { fileEdits.values.reduce(0) { $0 + $1.count } }

	public mutating func merge(_ other: LSPWorkspaceEdit) {
		for (uri, edits) in other.fileEdits { fileEdits[uri, default: []].append(contentsOf: edits) }
		resourceOperations.append(contentsOf: other.resourceOperations)
	}
}

// MARK: - Unified diff

public enum UnifiedDiff {
	/// A unified diff of two texts with `context` lines around each change, or "" when they are equal.
	public static func make(old: String, new: String, path: String, context: Int = 2) -> String {
		guard old != new else { return "" }
		let a = splitKeepingEmptyTail(old)
		let b = splitKeepingEmptyTail(new)
		let ops = diffOperations(a, b)
		let hunks = group(ops, context: context)
		var out = ["--- a/\(path)", "+++ b/\(path)"]
		for hunk in hunks {
			let oldCount = hunk.filter { $0.kind != .insert }.count
			let newCount = hunk.filter { $0.kind != .delete }.count
			let oldStart = hunk.first(where: { $0.kind != .insert })?.oldLine ?? (hunk.first?.oldLine ?? 0)
			let newStart = hunk.first(where: { $0.kind != .delete })?.newLine ?? (hunk.first?.newLine ?? 0)
			out.append("@@ -\(oldCount == 0 ? oldStart - 1 : oldStart),\(oldCount) +\(newCount == 0 ? newStart - 1 : newStart),\(newCount) @@")
			for op in hunk {
				switch op.kind {
				case .equal: out.append(" " + op.text)
				case .delete: out.append("-" + op.text)
				case .insert: out.append("+" + op.text)
				}
			}
		}
		return out.joined(separator: "\n")
	}

	/// Number of added and removed lines.
	public static func stats(old: String, new: String) -> (added: Int, removed: Int) {
		let ops = diffOperations(splitKeepingEmptyTail(old), splitKeepingEmptyTail(new))
		return (ops.filter { $0.kind == .insert }.count, ops.filter { $0.kind == .delete }.count)
	}

	private struct Operation {
		enum Kind { case equal, delete, insert }
		var kind: Kind
		var text: String
		/// 1-indexed position in the old / new text this operation is at.
		var oldLine: Int
		var newLine: Int
	}

	private static func splitKeepingEmptyTail(_ text: String) -> [String] {
		if text.isEmpty { return [] }
		var lines = text.components(separatedBy: "\n")
		if lines.last == "" { lines.removeLast() }
		return lines
	}

	private static func diffOperations(_ a: [String], _ b: [String]) -> [Operation] {
		var prefix = 0
		while prefix < a.count, prefix < b.count, a[prefix] == b[prefix] { prefix += 1 }
		var suffix = 0
		while suffix < a.count - prefix, suffix < b.count - prefix, a[a.count - 1 - suffix] == b[b.count - 1 - suffix] { suffix += 1 }
		let midA = Array(a[prefix..<(a.count - suffix)])
		let midB = Array(b[prefix..<(b.count - suffix)])

		var ops: [Operation] = []
		for index in 0..<prefix { ops.append(Operation(kind: .equal, text: a[index], oldLine: index + 1, newLine: index + 1)) }
		var oldLine = prefix + 1
		var newLine = prefix + 1
		func emit(_ kind: Operation.Kind, _ text: String) {
			ops.append(Operation(kind: kind, text: text, oldLine: oldLine, newLine: newLine))
			if kind != .insert { oldLine += 1 }
			if kind != .delete { newLine += 1 }
		}
		if midA.count * midB.count > 4_000_000 {
			// Too big for the quadratic table: report the middle as replaced wholesale.
			midA.forEach { emit(.delete, $0) }
			midB.forEach { emit(.insert, $0) }
		} else {
			let width = midB.count + 1
			var table = [Int32](repeating: 0, count: (midA.count + 1) * width)
			if !midA.isEmpty, !midB.isEmpty {
				for i in stride(from: midA.count - 1, through: 0, by: -1) {
					for j in stride(from: midB.count - 1, through: 0, by: -1) {
						table[i * width + j] =
							midA[i] == midB[j] ? table[(i + 1) * width + j + 1] + 1 : max(table[(i + 1) * width + j], table[i * width + j + 1])
					}
				}
			}
			var i = 0
			var j = 0
			while i < midA.count || j < midB.count {
				if i < midA.count, j < midB.count, midA[i] == midB[j] {
					emit(.equal, midA[i])
					i += 1
					j += 1
				} else if i < midA.count, j == midB.count || table[(i + 1) * width + j] >= table[i * width + j + 1] {
					emit(.delete, midA[i])  // deletions first, as unified diffs conventionally read
					i += 1
				} else {
					emit(.insert, midB[j])
					j += 1
				}
			}
		}
		for index in (a.count - suffix)..<a.count {
			ops.append(Operation(kind: .equal, text: a[index], oldLine: oldLine, newLine: newLine))
			oldLine += 1
			newLine += 1
		}
		return ops
	}

	private static func group(_ ops: [Operation], context: Int) -> [[Operation]] {
		let changed = ops.indices.filter { ops[$0].kind != .equal }
		guard !changed.isEmpty else { return [] }
		var hunks: [[Operation]] = []
		var start = max(changed[0] - context, 0)
		var end = min(changed[0] + context, ops.count - 1)
		for index in changed.dropFirst() {
			if index - context <= end + 1 {
				end = min(index + context, ops.count - 1)
			} else {
				hunks.append(Array(ops[start...end]))
				start = max(index - context, 0)
				end = min(index + context, ops.count - 1)
			}
		}
		hunks.append(Array(ops[start...end]))
		return hunks
	}
}

// MARK: - Indentation

public enum Indentation {
	/// How a file indents: a tab, or this many spaces.
	public enum Unit: Sendable, Equatable {
		case tab
		case spaces(Int)

		public var text: String {
			switch self {
			case .tab: return "\t"
			case .spaces(let count): return String(repeating: " ", count: count)
			}
		}
	}

	/// The indentation unit the file uses most, from its indented lines (4 spaces when it can't tell).
	public static func detect(in text: String) -> Unit {
		var tabs = 0
		var spaceWidths: [Int: Int] = [:]
		var previousIndent = 0
		for line in text.split(separator: "\n", omittingEmptySubsequences: true).prefix(2000) {
			guard let first = line.first, first == "\t" || first == " " else {
				previousIndent = 0
				continue
			}
			if first == "\t" {
				tabs += 1
				continue
			}
			let width = line.prefix(while: { $0 == " " }).count
			if line.dropFirst(width).isEmpty { continue }
			let step = abs(width - previousIndent)
			if step >= 2, step <= 8 { spaceWidths[step, default: 0] += 1 }
			previousIndent = width
		}
		let spaces = spaceWidths.values.reduce(0, +)
		if tabs > 0, tabs >= spaces { return .tab }
		if let best = spaceWidths.max(by: { $0.value < $1.value || ($0.value == $1.value && $0.key > $1.key) }) { return .spaces(best.key) }
		return .spaces(4)
	}

	/// The leading whitespace of a line.
	public static func leading(of line: String) -> String {
		String(line.prefix(while: { $0 == " " || $0 == "\t" }))
	}

	/// Re-indents a block of code to sit at `base`. Language servers hand back generated code with
	/// whatever indentation suits them (none at all, or four spaces in a tab-indented file):
	///  * if the block is flat (nothing but its first line is indented) the nesting is rebuilt from the braces;
	///  * otherwise its relative indentation is kept, converted to the file's unit.
	/// The first line is returned without `base`: it continues text already on the line.
	public static func reindent(_ block: String, base: String, unit: Unit, sourceUnit: Unit? = nil) -> String {
		let lines = block.components(separatedBy: "\n")
		guard lines.count > 1 else { return block }
		let rest = lines.dropFirst().filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
		let flat = rest.allSatisfy { leading(of: $0).isEmpty }
		var output: [String] = [lines[0]]
		if flat {
			var depth = Self.braceDelta(lines[0])
			for line in lines.dropFirst() {
				let trimmed = line.trimmingCharacters(in: .whitespaces)
				if trimmed.isEmpty {
					output.append("")
					continue
				}
				let closing = trimmed.hasPrefix("}") || trimmed.hasPrefix(")") || trimmed.hasPrefix("]")
				let level = max(depth - (closing ? 1 : 0), 0)
				output.append(base + String(repeating: unit.text, count: level) + trimmed)
				depth = max(depth + braceDelta(trimmed), 0)
			}
			return output.joined(separator: "\n")
		}
		let guess = sourceUnit ?? detect(in: lines.dropFirst().joined(separator: "\n"))
		let common = rest.map { leading(of: $0) }.min(by: { $0.count < $1.count }) ?? ""
		for line in lines.dropFirst() {
			if line.trimmingCharacters(in: .whitespaces).isEmpty {
				output.append("")
				continue
			}
			let relative = String(leading(of: line).dropFirst(common.count))
			output.append(base + convert(relative, from: guess, to: unit) + line.drop(while: { $0 == " " || $0 == "\t" }))
		}
		return output.joined(separator: "\n")
	}

	/// Net `{`/`(`/`[` minus closers on a line, ignoring string literals and `//` comments.
	public static func braceDelta(_ line: String) -> Int {
		var delta = 0
		var inString = false
		var previous: Character = " "
		for character in line {
			if inString {
				if character == "\"", previous != "\\" { inString = false }
			} else if character == "\"" {
				inString = true
			} else if character == "/", previous == "/" {
				break
			} else if "{([".contains(character) {
				delta += 1
			} else if "})]".contains(character) {
				delta -= 1
			}
			previous = character
		}
		return delta
	}

	/// Leading whitespace of `relative` re-expressed in another unit.
	public static func convert(_ relative: String, from: Unit, to: Unit) -> String {
		guard from != to else { return relative }
		var levels = 0
		var pendingSpaces = 0
		for character in relative {
			if character == "\t" {
				levels += 1
			} else {
				pendingSpaces += 1
				if case .spaces(let width) = from, width > 0, pendingSpaces == width {
					levels += 1
					pendingSpaces = 0
				}
			}
		}
		return String(repeating: to.text, count: levels) + String(repeating: " ", count: pendingSpaces)
	}
}
