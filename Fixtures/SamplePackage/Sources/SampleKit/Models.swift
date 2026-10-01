public struct User: Identifiable, Equatable, Sendable {
	public typealias ID = Int

	public let id: ID
	public var name: String

	public init(id: ID, name: String) {
		self.id = id
		self.name = name
	}
}

public enum Role: String, CaseIterable {
	case admin
	case guest
}

open class Animal {
	public init() {}
	open func speak() -> String { "..." }
}

public final class Dog: Animal {
	public override func speak() -> String { "woof" }
}

public enum Outer {
	public struct Inner {
		public init() {}
		public func run() -> Int { 1 }
	}
}

public protocol Refined: Greeter {}
public struct Shouter: Refined {
	public init() {}
	public func greet(_ name: String) -> String { name.uppercased() }
	public func greet(_ name: String, loudly: Bool) -> String { greet(name) }
}
