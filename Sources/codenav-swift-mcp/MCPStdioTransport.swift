import Foundation
import Logging
import MCP

/// Adapts initialization to the Swift MCP SDK's string-only experimental capabilities.
actor MCPStdioTransport: Transport {
	private let stdio = StdioTransport()

	nonisolated var logger: Logger { stdio.logger }

	func connect() async throws { try await stdio.connect() }
	func disconnect() async { await stdio.disconnect() }
	func send(_ data: Data) async throws { try await stdio.send(data) }

	func receive() -> AsyncThrowingStream<Data, Error> {
		AsyncThrowingStream { continuation in
			let task = Task {
				do {
					for try await message in await stdio.receive() {
						continuation.yield(Self.adaptInitialize(message))
					}
					continuation.finish()
				} catch {
					continuation.finish(throwing: error)
				}
			}
			continuation.onTermination = { _ in task.cancel() }
		}
	}

	private static func adaptInitialize(_ data: Data) -> Data {
		guard var request = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
			request["method"] as? String == Initialize.name,
			var parameters = request["params"] as? [String: Any],
			var capabilities = parameters["capabilities"] as? [String: Any],
			let experimental = capabilities["experimental"] as? [String: Any]
		else { return data }

		// CodeNav does not use experimental capabilities. Keep the values the SDK can decode.
		let supported = experimental.compactMapValues { $0 as? String }
		guard supported.count != experimental.count else { return data }
		capabilities["experimental"] = supported
		parameters["capabilities"] = capabilities
		request["params"] = parameters
		return (try? JSONSerialization.data(withJSONObject: request)) ?? data
	}
}
