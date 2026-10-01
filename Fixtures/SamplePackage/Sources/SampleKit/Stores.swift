public actor InMemoryUserStore: UserStore {
	private var users: [User.ID: User] = [:]

	public init() {}

	public func save(_ user: User) async throws {
		users[user.id] = user
	}

	public func load(id: User.ID) async throws -> User? {
		users[id]
	}
}

public struct PoliteGreeter {
	public init() {}
}

extension PoliteGreeter: Greeter {
	public func greet(_ name: String) -> String { "Hello, \(name)" }
	public func greet(_ name: String, loudly: Bool) -> String {
		loudly ? greet(name).uppercased() : greet(name)
	}
}
