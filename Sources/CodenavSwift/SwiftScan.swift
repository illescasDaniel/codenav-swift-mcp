import Foundation
import NavShared

/// Just enough Swift lexing to find the pieces of a declaration the edit tools work on (its body,
/// its parameter list, the arguments of a call) without being fooled by strings or comments.
/// Everything works on UTF-16 offsets, the same units as `TextIndex` and LSP columns.
struct SwiftScan {
	let units: [UInt16]
	/// `true` for units that are code, `false` inside comments and string literals (delimiters included).
	let isCode: [Bool]

	init(_ text: String) {
		self.init(units: Array(text.utf16))
	}

	init(units: [UInt16]) {
		self.units = units
		isCode = Self.codeMask(units)
	}

	private static func ascii(_ character: Character) -> UInt16 { character.asciiValue.map(UInt16.init) ?? 0 }

	private static let slash = ascii("/"), star = ascii("*"), quote = ascii("\""), backslash = ascii("\\")
	private static let hash = ascii("#"), newline: UInt16 = 0x0A, openParen = ascii("("), closeParen = ascii(")")

	static func codeMask(_ u: [UInt16]) -> [Bool] {
		var mask = [Bool](repeating: true, count: u.count)
		var i = 0
		func at(_ index: Int) -> UInt16 { index < u.count ? u[index] : 0 }
		while i < u.count {
			let c = u[i]
			if c == slash, at(i + 1) == slash {
				while i < u.count, u[i] != newline {
					mask[i] = false
					i += 1
				}
				continue
			}
			if c == slash, at(i + 1) == star {
				var depth = 0
				while i < u.count {
					if u[i] == slash, at(i + 1) == star {
						depth += 1
						mask[i] = false
						mask[i + 1] = false
						i += 2
					} else if u[i] == star, at(i + 1) == slash {
						depth -= 1
						mask[i] = false
						mask[i + 1] = false
						i += 2
						if depth == 0 { break }
					} else {
						mask[i] = false
						i += 1
					}
				}
				continue
			}
			// String literal, possibly raw (`#"..."#`) and/or multi-line (`"""`).
			var hashes = 0
			var probe = i
			while at(probe) == hash {
				hashes += 1
				probe += 1
			}
			if at(probe) == quote, hashes == 0 || (probe > i) {
				let multiline = at(probe + 1) == quote && at(probe + 2) == quote
				let openLength = (probe - i) + (multiline ? 3 : 1)
				for k in i..<min(i + openLength, u.count) { mask[k] = false }
				var j = i + openLength
				while j < u.count {
					if u[j] == backslash, hashesMatch(u, j + 1, hashes) {
						// Escape, or an interpolation `\(...)`: skip its contents as part of the string.
						let after = j + 1 + hashes
						if at(after) == openParen {
							var depth = 0
							var k = after
							while k < u.count {
								if u[k] == openParen { depth += 1 }
								if u[k] == closeParen {
									depth -= 1
									if depth == 0 { break }
								}
								k += 1
							}
							for m in j...min(k, u.count - 1) { mask[m] = false }
							j = k + 1
						} else {
							for m in j...min(after, u.count - 1) { mask[m] = false }
							j = after + 1
						}
						continue
					}
					if multiline {
						if u[j] == quote, at(j + 1) == quote, at(j + 2) == quote, hashesMatch(u, j + 3, hashes) {
							for m in j..<min(j + 3 + hashes, u.count) { mask[m] = false }
							j += 3 + hashes
							break
						}
					} else {
						if u[j] == quote, hashesMatch(u, j + 1, hashes) {
							for m in j..<min(j + 1 + hashes, u.count) { mask[m] = false }
							j += 1 + hashes
							break
						}
						if u[j] == newline { break }  // unterminated: don't swallow the rest of the file
					}
					mask[j] = false
					j += 1
				}
				i = max(j, i + 1)
				continue
			}
			i += 1
		}
		return mask
	}

	private static func hashesMatch(_ u: [UInt16], _ start: Int, _ count: Int) -> Bool {
		guard count > 0 else { return true }
		guard start + count <= u.count else { return false }
		return (0..<count).allSatisfy { u[start + $0] == hash }
	}

	func unit(_ character: Character) -> UInt16 { Self.ascii(character) }

	func text(_ start: Int, _ end: Int) -> String {
		String(decoding: units[max(start, 0)..<min(end, units.count)], as: UTF16.self)
	}

	/// The offset of the delimiter matching the opener at `open` (`(`/`[`/`{`/`<`), over code only.
	func matching(openAt open: Int) -> Int? {
		let opener = units[open]
		let closer: UInt16
		switch opener {
		case unit("("): closer = unit(")")
		case unit("["): closer = unit("]")
		case unit("{"): closer = unit("}")
		case unit("<"): closer = unit(">")
		default: return nil
		}
		var depth = 0
		var i = open
		while i < units.count {
			if isCode[i] {
				if units[i] == opener {
					depth += 1
				} else if units[i] == closer, !(closer == unit(">") && i > 0 && units[i - 1] == unit("-")) {
					depth -= 1
					if depth == 0 { return i }
				}
			}
			i += 1
		}
		return nil
	}

	/// The first code character at or after `offset` that isn't whitespace.
	func nextSignificant(from offset: Int, limit: Int? = nil) -> Int? {
		var i = offset
		let end = min(limit ?? units.count, units.count)
		while i < end {
			if isCode[i], !isWhitespace(units[i]) { return i }
			i += 1
		}
		return nil
	}

	func isWhitespace(_ u: UInt16) -> Bool { u == 0x20 || u == 0x09 || u == 0x0A || u == 0x0D }

	/// `{` ... `}` of the body of the declaration spanning `declaration`, the first `{` outside any
	/// parentheses after `from` (a closure in a default argument sits inside them). Nil for a
	/// declaration without a body (protocol requirement, stored property).
	func body(of declaration: Range<Int>, from: Int) -> (open: Int, close: Int)? {
		var depth = 0
		var i = from
		while i < min(declaration.upperBound, units.count) {
			if isCode[i] {
				let c = units[i]
				if c == unit("(") || c == unit("[") { depth += 1 }
				if c == unit(")") || c == unit("]") { depth -= 1 }
				if c == unit("{"), depth <= 0, let close = matching(openAt: i), close < declaration.upperBound { return (i, close) }
				if c == unit("{"), depth <= 0 { return nil }
			}
			i += 1
		}
		return nil
	}

	/// The `(`...`)` that follows `from`, skipping generic parameters (`run<T>(` ) and `?`/`!` (`init?(`).
	func parenthesized(after from: Int, limit: Int? = nil) -> (open: Int, close: Int)? {
		guard var i = nextSignificant(from: from, limit: limit) else { return nil }
		if units[i] == unit("<"), let close = matching(openAt: i) {
			guard let next = nextSignificant(from: close + 1, limit: limit) else { return nil }
			i = next
		}
		while i < units.count, units[i] == unit("?") || units[i] == unit("!") {
			guard let next = nextSignificant(from: i + 1, limit: limit) else { return nil }
			i = next
		}
		guard units[i] == unit("("), let close = matching(openAt: i) else { return nil }
		return (i, close)
	}

	/// Splits `start..<end` at commas that sit outside any (), [], {} or <>, and outside strings.
	func splitTopLevel(_ start: Int, _ end: Int) -> [Range<Int>] {
		var pieces: [Range<Int>] = []
		var depth = 0
		var pieceStart = start
		var i = start
		while i < end {
			if isCode[i] {
				let c = units[i]
				if c == unit("(") || c == unit("[") || c == unit("{") || c == unit("<") { depth += 1 }
				if c == unit(")") || c == unit("]") || c == unit("}") { depth -= 1 }
				if c == unit(">"), !(i > 0 && units[i - 1] == unit("-")) { depth -= 1 }
				if c == unit(","), depth == 0 {
					pieces.append(pieceStart..<i)
					pieceStart = i + 1
				}
			}
			i += 1
		}
		if text(pieceStart, end).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, pieces.isEmpty { return [] }
		pieces.append(pieceStart..<end)
		return pieces
	}

	/// Offset of the first top-level occurrence of `character` in `range` (outside brackets and strings). An
	/// opening bracket is itself a top-level occurrence when it isn't inside another.
	func firstTopLevel(_ character: Character, in range: Range<Int>) -> Int? {
		var depth = 0
		for i in range where isCode[i] {
			let c = units[i]
			if depth == 0, c == unit(character) { return i }
			if c == unit("(") || c == unit("[") || c == unit("{") || c == unit("<") { depth += 1 }
			if c == unit(")") || c == unit("]") || c == unit("}") { depth -= 1 }
			if c == unit(">"), !(i > 0 && units[i - 1] == unit("-")) { depth -= 1 }
		}
		return nil
	}
}

// MARK: - Declaration ranges

enum DeclarationRange {
	/// The 0-based line the declaration's doc comment starts on (`///` lines or a `/** */` block right above
	/// it), or `line` itself when it has none.
	static func docCommentStart(above line: Int, in index: TextIndex) -> Int {
		var start = line
		var cursor = line - 1
		while cursor >= 0 {
			let text = index.lineText(cursor).trimmingCharacters(in: .whitespaces)
			if text.hasPrefix("///") {
				start = cursor
				cursor -= 1
			} else if text.hasSuffix("*/") {
				// Walk up to the line that opens the block.
				var open = cursor
				while open >= 0, !index.lineText(open).contains("/*") { open -= 1 }
				guard open >= 0, index.lineText(open).trimmingCharacters(in: .whitespaces).hasPrefix("/*") else { break }
				start = open
				cursor = open - 1
			} else {
				break
			}
		}
		return start
	}

	/// Offsets covering whole lines: from the start of the first line (or of its doc comment) to the end of
	/// the last line including its line break, plus one following blank line when `swallowBlank` is set, so
	/// deleting a declaration doesn't leave a double gap.
	static func wholeLines(
		of range: LSPRange, in index: TextIndex, includingDocComment: Bool, swallowBlank: Bool
	) -> (start: Int, end: Int) {
		let first = includingDocComment ? docCommentStart(above: range.start.line, in: index) : range.start.line
		let start = index.lineStarts[first]
		var lastLine = range.end.line
		var end = lastLine + 1 < index.lineStarts.count ? index.lineStarts[lastLine + 1] : index.units.count
		if swallowBlank, lastLine + 1 < index.lineStarts.count,
			index.lineText(lastLine + 1).trimmingCharacters(in: .whitespaces).isEmpty,
			lastLine + 2 < index.lineStarts.count || index.lineEnd(lastLine + 1) < index.units.count
		{
			lastLine += 1
			end = lastLine + 1 < index.lineStarts.count ? index.lineStarts[lastLine + 1] : index.units.count
		}
		return (start, end)
	}
}
