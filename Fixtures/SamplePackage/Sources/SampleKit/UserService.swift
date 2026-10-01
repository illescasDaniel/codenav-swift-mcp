/// Creates and finds users.
public final class UserService {
	private let store: any UserStore

	public init(store: any UserStore) {
		self.store = store
	}

	/// Creates a user and saves it.
	public func create(name: String) async throws -> User {
		let user = User(id: name.count, name: name)
		try await store.save(user)
		return user
	}

	public func find(id: User.ID) async throws -> User? {
		try await store.load(id: id)
	}
}

extension UserService {
	public func rename(_ user: User, to name: String) async throws -> User {
		var copy = user
		copy.name = name
		try await store.save(copy)
		return copy
	}
}
