import Foundation

/// Param-name aliases for MCP tools: agents often guess `query` vs `name`.
///
/// Returning a `ToolInputError` (rendered as tool text) beats a schema-validation wall,
/// which historically made agents abandon the MCP after one wrong guess.
public func resolveNameQuery(
	preferred: String = "name",
	example: String = "Foo",
	_ params: KeyValuePairs<String, String?>
) throws -> String {
	var ordered: [(String, String?)] = params.map { ($0.key, $0.value) }
	if !ordered.contains(where: { $0.0 == preferred }) {
		ordered.insert((preferred, nil), at: 0)
	}
	if let value = ordered.first(where: { $0.0 == preferred })?.1, !value.isEmpty {
		return value
	}
	for (key, value) in ordered where key != preferred {
		if let value, !value.isEmpty { return value }
	}
	let others = ordered.map(\.0).filter { $0 != preferred }
	let hint: String
	switch others.count {
	case 0: hint = ""
	case 1: hint = "; `\(others[0])` is accepted as an alias"
	default: hint = "; aliases accepted: " + others.map { "`\($0)`" }.joined(separator: ", ")
	}
	throw ToolInputError("Pass `\(preferred)` (e.g. \(preferred)=\"\(example)\")\(hint).")
}
