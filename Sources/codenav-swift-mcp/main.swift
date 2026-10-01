import CodenavSwift
import Foundation
import MCP
import NavShared

let serverVersion = "0.1.0"

func inputSchema(for tool: ToolSpec) -> Value {
	var properties: [String: Value] = [:]
	for parameter in tool.parameters {
		properties[parameter.name] = .object([
			"type": .string(parameter.kind.rawValue),
			"description": .string(parameter.description),
		])
	}
	var schema: [String: Value] = ["type": "object", "properties": .object(properties)]
	let required = tool.parameters.filter(\.required).map { Value.string($0.name) }
	if !required.isEmpty { schema["required"] = .array(required) }
	return .object(schema)
}

/// MCP `Value` → NavShared `JSONValue` (both Codable; the shapes are identical).
func convert(_ arguments: [String: Value]?) -> ToolArguments {
	guard let arguments,
		let data = try? JSONEncoder().encode(arguments),
		let decoded = try? JSONDecoder().decode([String: JSONValue].self, from: data)
	else { return ToolArguments([:]) }
	return ToolArguments(decoded)
}

let server = Server(
	name: "codenav-swift",
	version: serverVersion,
	instructions: ToolCatalog.instructions,
	capabilities: .init(tools: .init(listChanged: false))
)

let navigator = SwiftNavigator(
	rootsProvider: {
		// The client may not support roots, or may never answer: don't let that stall a tool call.
		await withTaskGroup(of: [String]?.self) { group in
			group.addTask { try? await server.listRoots().map(\.uri) }
			group.addTask {
				try? await Task.sleep(for: .seconds(3))
				return nil
			}
			let first = await group.next() ?? nil
			group.cancelAll()
			return first ?? []
		}
	}
)

let toolList = ToolCatalog.tools.map {
	Tool(name: $0.name, description: $0.description, inputSchema: inputSchema(for: $0), annotations: .init(readOnlyHint: true))
}

await server.withMethodHandler(ListTools.self) { _ in .init(tools: toolList) }
await server.withMethodHandler(CallTool.self) { params in
	let text = await ToolCatalog.call(params.name, arguments: convert(params.arguments), navigator: navigator)
	return .init(content: [.text(text: text, annotations: nil, _meta: nil)], isError: false)
}

do {
	try await server.start(transport: StdioTransport())
} catch {
	FileHandle.standardError.write(Data("codenav-swift: failed to start: \(error)\n".utf8))
	exit(1)
}
Task { await navigator.warmUp() }
await server.waitUntilCompleted()
