import Testing
@testable import SampleKit

struct FakeStore: UserStore {
	func save(_ user: User) async throws {}
	func load(id: User.ID) async throws -> User? { nil }
}

@Test func createsUser() async throws {
	let service = UserService(store: FakeStore())
	let user = try await service.create(name: "Bob")
	#expect(user.name == "Bob")
}
