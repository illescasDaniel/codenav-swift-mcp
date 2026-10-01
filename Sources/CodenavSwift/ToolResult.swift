import Foundation

/// What a tool hands back to the MCP layer: text for the agent, plus whether it is a failure
/// (bad input, nothing resolvable, language-server trouble) as opposed to an ordinary answer such
/// as "no references found". Hosts surface `isError` differently, and agents retry on it.
public struct ToolResult: Sendable, Equatable {
	public var text: String
	public var isError: Bool

	public init(_ text: String, isError: Bool = false) {
		self.text = text
		self.isError = isError
	}

	public func contains(_ fragment: String) -> Bool {
		text.contains(fragment)
	}
}
