/// Persists users.
public protocol UserStore: Sendable {
	func save(_ user: User) async throws
	func load(id: User.ID) async throws -> User?
}

public protocol Greeter {
	func greet(_ name: String) -> String
	func greet(_ name: String, loudly: Bool) -> String
}
