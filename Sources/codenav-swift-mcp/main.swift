import CodenavSwift
import Foundation
import MCP
import NavShared

let serverVersion = "0.2.1"

// A write to a pipe whose reader died (sourcekit-lsp crashed) must fail with an error, not kill this process.
signal(SIGPIPE, SIG_IGN)

// A stdio server has no other command line; answer the usual flags instead of waiting for MCP input.
let commandLineArguments = CommandLine.arguments.dropFirst()
if commandLineArguments.contains(where: { $0 == "--version" || $0 == "-v" }) {
	print("codenav-swift-mcp \(serverVersion)")
	exit(0)
}
if commandLineArguments.contains(where: { $0 == "--help" || $0 == "-h" }) {
	print(
		"""
		codenav-swift-mcp \(serverVersion)
		Compiler-accurate code navigation for Swift codebases, as an MCP server.

		Speaks MCP over stdio and takes no arguments: register it with an MCP client, for example
		  claude mcp add codenav-swift --scope user -- codenav-swift-mcp

		Options:
		  -v, --version  Print the version and exit
		  -h, --help     Print this help and exit

		Documentation: https://github.com/illescasDaniel/codenav-swift-mcp
		""")
	exit(0)
}

func inputSchema(for tool: ToolSpec) -> Value {
	var properties: [String: Value] = [:]
	for parameter in tool.parameters {
		var property: [String: Value] = [
			"type": .string(parameter.kind.rawValue),
			"description": .string(parameter.description),
		]
		if parameter.kind == .array { property["items"] = .object(["type": .string("object")]) }
		properties[parameter.name] = .object(property)
	}
	var schema: [String: Value] = ["type": "object", "properties": .object(properties)]
	let required = tool.parameters.filter(\.required).map { Value.string($0.name) }
	if !required.isEmpty { schema["required"] = .array(required) }
	return .object(schema)
}

/// MCP `Value` → NavShared `JSONValue` (both Codable; the shapes are identical).
func convert(_ arguments: [String: Value]?) throws -> ToolArguments {
	guard let arguments else { return ToolArguments([:]) }
	do {
		let data = try JSONEncoder().encode(arguments)
		return ToolArguments(try JSONDecoder().decode([String: JSONValue].self, from: data))
	} catch {
		throw ToolInputError("The tool arguments couldn't be read: \(error.localizedDescription)")
	}
}

// Tools that change files are opt-in: the server has always been read-only, so upgrading must not change that.
let writesEnabled = ["1", "true", "yes"].contains(ProcessInfo.processInfo.environment[ToolCatalog.writeEnvironmentKey]?.lowercased() ?? "")

let server = Server(
	name: "codenav-swift",
	version: serverVersion,
	instructions: ToolCatalog.instructions + (writesEnabled ? " " + ToolCatalog.writeInstructions : ""),
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

let toolList = (writesEnabled ? ToolCatalog.tools : ToolCatalog.readTools + ToolCatalog.analysisTools).map { spec -> Tool in
	let annotations: Tool.Annotations
	if ToolCatalog.writeToolNames.contains(spec.name) {
		annotations = .init(readOnlyHint: false, destructiveHint: true, idempotentHint: false, openWorldHint: false)
	} else if ToolCatalog.analysisToolNames.contains(spec.name) {
		annotations = .init(readOnlyHint: false, destructiveHint: false, idempotentHint: true, openWorldHint: false)
	} else {
		annotations = .init(readOnlyHint: true)
	}
	return Tool(name: spec.name, description: spec.description, inputSchema: inputSchema(for: spec), annotations: annotations)
}

await server.withMethodHandler(ListTools.self) { _ in .init(tools: toolList) }
await server.withMethodHandler(CallTool.self) { params in
	let arguments: ToolArguments
	do {
		arguments = try convert(params.arguments)
	} catch {
		return .init(content: [.text(text: (error as? ToolInputError)?.message ?? "\(error)", annotations: nil, _meta: nil)], isError: true)
	}
	let result = await ToolCatalog.call(params.name, arguments: arguments, navigator: navigator, writesEnabled: writesEnabled)
	return .init(content: [.text(text: result.text, annotations: nil, _meta: nil)], isError: result.isError)
}

do {
	try await server.start(transport: StdioTransport())
} catch {
	FileHandle.standardError.write(Data("codenav-swift: failed to start: \(error)\n".utf8))
	exit(1)
}
Task { await navigator.warmUp() }
await server.waitUntilCompleted()
