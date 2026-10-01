import SampleKit

let service = UserService(store: InMemoryUserStore())
let user = try await service.create(name: "Ada")
print(user.name, PoliteGreeter().greet(user.name, loudly: true))
