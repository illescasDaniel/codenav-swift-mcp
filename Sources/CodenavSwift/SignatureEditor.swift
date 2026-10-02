import Foundation
import NavShared

/// One parameter of a Swift function or initializer, as written: `_ user: User`, `label name: Int = 3`.
struct SignatureParameter: Equatable {
	/// External label; `_` when the call site has none.
	var label: String
	/// Internal name (equal to the label when only one name is written).
	var name: String
	/// Everything between the colon and the default value: `inout User`, `Int...`, `@escaping () -> Void`.
	var type: String
	var defaultValue: String?

	var isVariadic: Bool { type.hasSuffix("...") }

	/// The name that identifies the parameter to a caller: its label, or its internal name for `_`.
	var key: String { label == "_" ? name : label }

	var rendered: String {
		let names = label == name ? label : "\(label) \(name)"
		return "\(names): \(type)" + (defaultValue.map { " = \($0)" } ?? "")
	}

	/// The argument a call passes for this parameter: `name: value`, or just `value` for `_`.
	func argument(_ value: String) -> String { label == "_" ? value : "\(label): \(value)" }

	static func parse(_ raw: String, scan: SwiftScan? = nil) -> SignatureParameter? {
		let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
		let scan = SwiftScan(text)
		guard let colon = scan.firstTopLevel(":", in: 0..<scan.units.count) else { return nil }
		let names = scan.text(0, colon).split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" }).map(String.init)
		guard (1...2).contains(names.count) else { return nil }
		var rest = (colon + 1)..<scan.units.count
		var defaultValue: String?
		if let equals = scan.firstTopLevel("=", in: rest) {
			defaultValue = scan.text(equals + 1, scan.units.count).trimmingCharacters(in: .whitespacesAndNewlines)
			rest = colon + 1..<equals
		}
		let type = scan.text(rest.lowerBound, rest.upperBound).trimmingCharacters(in: .whitespacesAndNewlines)
		guard !type.isEmpty else { return nil }
		return SignatureParameter(
			label: names[0], name: names.count == 2 ? names[1] : names[0], type: type, defaultValue: defaultValue)
	}
}

struct SignatureError: Error, Equatable {
	var message: String
}

enum SignatureOperation {
	enum Position: Equatable {
		case first, last
		case before(String)
		case after(String)
	}

	/// Add a parameter. `callValue` is what existing call sites pass for it; it can be omitted only when the
	/// parameter has a default value.
	case add(SignatureParameter, position: Position, callValue: String?)
	case remove(key: String)
	case reorder(keys: [String])
	case retype(key: String, type: String)
	/// Set (or, with nil, drop) a parameter's default value.
	case setDefault(key: String, value: String?)
}

/// The outcome of applying operations to a parameter list.
struct SignatureChange {
	struct Entry {
		var parameter: SignatureParameter
		/// Index in the old list, or nil for a parameter the change adds.
		var origin: Int?
		var callValue: String?
	}

	var old: [SignatureParameter]
	var entries: [Entry]

	var new: [SignatureParameter] { entries.map(\.parameter) }

	/// Whether existing calls must be rewritten. Dropping nothing and adding only defaulted parameters at
	/// the end (or in place of nothing) leaves every call valid as it is.
	var needsCallRewrite: Bool {
		let kept = entries.compactMap(\.origin)
		if kept != Array(0..<old.count).filter({ kept.contains($0) }) { return true }  // reordered
		if kept.count != old.count { return true }  // removed
		return entries.contains { $0.origin == nil && ($0.callValue != nil || $0.parameter.defaultValue == nil) }
	}

	static func plan(old: [SignatureParameter], operations: [SignatureOperation]) throws -> SignatureChange {
		var entries = old.enumerated().map { Entry(parameter: $0.element, origin: $0.offset, callValue: nil) }
		func index(_ key: String) throws -> Int {
			if let found = entries.firstIndex(where: { $0.parameter.key == key || $0.parameter.name == key || $0.parameter.label == key }) {
				return found
			}
			let known = entries.map(\.parameter.key).joined(separator: ", ")
			throw SignatureError(message: "no parameter '\(key)' (parameters: \(known.isEmpty ? "none" : known))")
		}
		for operation in operations {
			switch operation {
			case .add(let parameter, let position, let callValue):
				guard !entries.contains(where: { $0.parameter.key == parameter.key }) else {
					throw SignatureError(message: "a parameter '\(parameter.key)' already exists")
				}
				if callValue == nil, parameter.defaultValue == nil {
					throw SignatureError(
						message:
							"parameter '\(parameter.key)' has no default value, so give `call_value` (what existing callers pass for it)"
					)
				}
				let entry = Entry(parameter: parameter, origin: nil, callValue: callValue)
				switch position {
				case .first: entries.insert(entry, at: 0)
				case .last: entries.append(entry)
				case .before(let key): entries.insert(entry, at: try index(key))
				case .after(let key): entries.insert(entry, at: try index(key) + 1)
				}
			case .remove(let key):
				entries.remove(at: try index(key))
			case .reorder(let keys):
				var remaining = entries
				var reordered: [Entry] = []
				for key in keys {
					let at = try index(key)
					let wanted = entries[at]
					guard let position = remaining.firstIndex(where: { $0.parameter.key == wanted.parameter.key }) else {
						throw SignatureError(message: "'\(key)' is listed twice in the new order")
					}
					reordered.append(remaining.remove(at: position))
				}
				entries = reordered + remaining  // parameters not mentioned keep their relative order, after the listed ones
			case .retype(let key, let type):
				entries[try index(key)].parameter.type = type
			case .setDefault(let key, let value):
				entries[try index(key)].parameter.defaultValue = value
			}
		}
		var seen: Set<String> = []
		for entry in entries where !seen.insert(entry.parameter.key).inserted {
			throw SignatureError(message: "two parameters would be called '\(entry.parameter.key)'")
		}
		return SignatureChange(old: old, entries: entries)
	}

	/// The text of the parameter list (without parentheses), laid out like the one it replaces.
	func renderedList(like original: String) -> String {
		Self.layout(new.map(\.rendered), like: original)
	}

	static func layout(_ items: [String], like original: String) -> String {
		guard original.contains("\n"), items.count > 0 else { return items.joined(separator: ", ") }
		// A parameter list spread over lines keeps that shape: each item on its own line at the old indent.
		let lines = original.components(separatedBy: "\n")
		let indent = lines.dropFirst().first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }).map { Indentation.leading(of: $0) } ?? "\t"
		let closing = lines.last.map { Indentation.leading(of: $0) } ?? ""
		let hasLeadingBreak = original.first(where: { !" \t".contains($0) }) == "\n"
		let body = items.map { indent + $0 }.joined(separator: ",\n")
		return hasLeadingBreak ? "\n" + body + "\n" + closing : items.joined(separator: ",\n" + indent)
	}
}

// MARK: - Declaration lists and call sites

enum SignatureEditor {
	/// The parameters of the list between `open` and `close` (the parentheses), or nil when one can't be parsed.
	static func parameters(in scan: SwiftScan, open: Int, close: Int) -> [SignatureParameter]? {
		let pieces = scan.splitTopLevel(open + 1, close)
		var result: [SignatureParameter] = []
		for piece in pieces {
			guard let parameter = SignatureParameter.parse(scan.text(piece.lowerBound, piece.upperBound)) else { return nil }
			result.append(parameter)
		}
		return result
	}

	struct Argument {
		var label: String?
		var text: String
		var expression: String
	}

	/// The arguments of the call whose parentheses are `open`/`close`.
	static func arguments(in scan: SwiftScan, open: Int, close: Int) -> [Argument] {
		scan.splitTopLevel(open + 1, close).map { piece in
			let text = scan.text(piece.lowerBound, piece.upperBound).trimmingCharacters(in: .whitespacesAndNewlines)
			if let colon = scan.firstTopLevel(":", in: piece) {
				let label = scan.text(piece.lowerBound, colon).trimmingCharacters(in: .whitespacesAndNewlines)
				if label.range(of: #"^[A-Za-z_][A-Za-z0-9_]*$"#, options: .regularExpression) != nil {
					let expression = scan.text(colon + 1, piece.upperBound).trimmingCharacters(in: .whitespacesAndNewlines)
					return Argument(label: label, text: text, expression: expression)
				}
			}
			return Argument(label: nil, text: text, expression: text)
		}
	}

	enum CallRewrite: Equatable {
		case rewritten(String)
		case unchanged
		case manual(String)
	}

	/// The new argument list for a call (`original` is the text between the parentheses), or why a person
	/// has to look at it.
	static func rewrite(
		arguments: [Argument], original: String, hasTrailingClosure: Bool, change: SignatureChange
	) -> CallRewrite {
		guard change.needsCallRewrite else { return .unchanged }
		if hasTrailingClosure {
			return .manual("the call ends in a trailing closure, which this change can move")
		}
		if change.old.contains(where: \.isVariadic) { return .manual("the function has a variadic parameter") }
		// Match each written argument to the old parameter it supplies.
		var matched: [Int: Argument] = [:]
		var cursor = 0
		for argument in arguments {
			var found: Int?
			var index = cursor
			while index < change.old.count {
				let parameter = change.old[index]
				let isMatch = argument.label.map { $0 == parameter.label } ?? (parameter.label == "_")
				if isMatch {
					found = index
					break
				}
				guard parameter.defaultValue != nil else { break }  // only a defaulted parameter may be skipped
				index += 1
			}
			guard let found else { return .manual("an argument doesn't line up with the old parameters") }
			matched[found] = argument
			cursor = found + 1
		}
		var output: [String] = []
		for entry in change.entries {
			if let origin = entry.origin {
				if let argument = matched[origin] { output.append(argument.text) }
			} else if let value = entry.callValue {
				output.append(entry.parameter.argument(value))
			}
		}
		return .rewritten(SignatureChange.layout(output, like: original))
	}
}
