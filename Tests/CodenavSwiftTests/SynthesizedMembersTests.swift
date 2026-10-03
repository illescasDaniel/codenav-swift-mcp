import Foundation
import Testing

@testable import CodenavSwift
@testable import NavShared

/// Excerpts of `swiftc -print-ast` (Swift 6.3) for a Codable/Equatable/Hashable struct, a String enum and a class.
/// Headers are verbatim; bodies are shortened.
private let dump = """
	import Foundation

	public struct Person : Codable, Equatable, Hashable {
	  public let name: String
	  public var age: Int
	  @_hasInitialValue internal var nick: String? = nil
	  private enum CodingKeys : CodingKey {
	    case name
	    case age
	    case nick
	    private init?(stringValue: String) {
	      return nil
	    }
	    fileprivate func hash(into hasher: inout Hasher) {
	    }
	  }
	  @_implements(Equatable, ==(_:_:)) public static func __derived_struct_equals(_ a: Person, _ b: Person) -> Bool {
	    return true
	  }
	  public func encode(to encoder: any Encoder) throws {
	  }
	  public func hash(into hasher: inout Hasher) {
	  }
	  public var hashValue: Int {
	    get {
	      return _hashValue(for: self)
	    }
	  }
	  public init(from decoder: any Decoder) throws {
	  }
	  internal init(name: String, age: Int, nick: String? = nil)
	}

	public enum Level : String, CaseIterable {
	  case low
	  case high
	  @inlinable public init?(rawValue: String) {
	    return nil
	  }
	  public typealias AllCases = [Level]
	  public typealias RawValue = String
	  nonisolated public static var allCases: [Level] {
	    get {
	      return [Level.low, Level.high]
	    }
	  }
	  public var rawValue: String {
	    @inlinable get {
	      return "low"
	    }
	  }
	}

	@_hasMissingDesignatedInitializers public final class Box {
	  final internal var v: Int
	  internal init(v: Int) {
	    self.v = v
	  }
	  deinit {
	  }
	}

	public enum Outer {
	  public struct Inner : Equatable {
	    public var x: Int
	    @_implements(Equatable, ==(_:_:)) public static func __derived_struct_equals(_ a: Outer.Inner, _ b: Outer.Inner) -> Bool {
	      return true
	    }
	    internal init(x: Int)
	  }
	}
	"""

@Suite struct ASTDumpTests {
	private func synthesized(_ path: [String], known: Set<String>) throws -> [SynthesizedMember] {
		ASTDump.synthesized(from: try #require(ASTDump.members(of: path, in: dump)), known: known)
	}

	@Test func aStructWithConformancesShowsEverythingTheCompilerAdded() throws {
		let members = try synthesized(["Person"], known: ["name", "age", "nick"])
		let byKey = Dictionary(uniqueKeysWithValues: members.map { ($0.key, $0) })
		#expect(byKey["init(name:age:nick:)"]?.declaration == "internal init(name: String, age: Int, nick: String? = nil)")
		#expect(byKey["init(name:age:nick:)"]?.reason == "memberwise initializer")
		#expect(byKey["init(from:)"]?.reason == "Decodable")
		#expect(byKey["encode(to:)"]?.reason == "Encodable")
		#expect(byKey["hash(into:)"]?.reason == "Hashable")
		#expect(byKey["hashValue"]?.reason == "Hashable")
		// A derived function is shown under the name it implements, not its internal one.
		#expect(byKey["==(_:_:)"]?.declaration == "public static func ==(_ a: Person, _ b: Person) -> Bool")
		#expect(byKey["==(_:_:)"]?.reason == "Equatable")
		#expect(byKey["CodingKeys"]?.declaration == "private enum CodingKeys : CodingKey { case name, age, nick }")
		// What the source declares is not repeated; private helpers are left out.
		#expect(byKey["name"] == nil && byKey["age"] == nil)
		#expect(!members.contains { $0.declaration.contains("stringValue") })
	}

	@Test func anExplicitInitIsNotReportedAsGenerated() throws {
		#expect(try synthesized(["Box"], known: ["v", "init(v:)"]).isEmpty)
		// Whereas a missing one shows up (here the outline simply doesn't list it).
		#expect(try synthesized(["Box"], known: ["v"]).map(\.key) == ["init(v:)"])
	}

	@Test func enumsGetRawValueAndAllCases() throws {
		let members = try synthesized(["Level"], known: ["low", "high"])
		#expect(Set(members.map(\.key)) == ["init(rawValue:)", "AllCases", "RawValue", "allCases", "rawValue"])
		#expect(members.first { $0.key == "allCases" }?.reason == "CaseIterable")
		#expect(members.first { $0.key == "init(rawValue:)" }?.reason == "RawRepresentable")
		#expect(members.first { $0.key == "init(rawValue:)" }?.declaration == "public init?(rawValue: String)")
	}

	@Test func nestedTypesAreFoundByPathAndUnknownOnesAreNil() throws {
		let members = try synthesized(["Outer", "Inner"], known: ["x"])
		#expect(Set(members.map(\.key)) == ["init(x:)", "==(_:_:)"])
		#expect(ASTDump.members(of: ["Inner"], in: dump) == nil)  // only at the top level by itself
		#expect(ASTDump.members(of: ["Missing"], in: dump) == nil)
	}

	@Test func headersAreTakenApart() {
		let header = ASTDump.parse("@_implements(Equatable, ==(_:_:)) public static func __derived_struct_equals(_ a: P, _ b: P) -> Bool {")
		#expect(header.keyword == "func" && header.hasBody)
		#expect(header.key == "==(_:_:)")
		let failable = ASTDump.parse("@inlinable public init?(rawValue: String) {")
		#expect(failable.key == "init(rawValue:)" && failable.keyword == "init")
		let classMethod = ASTDump.parse("class func make(with x: Int) -> Self")
		#expect(classMethod.key == "make(with:)" && !classMethod.hasBody)
		let property = ASTDump.parse("final internal var v: Int")
		#expect(property.keyword == "var" && property.name == "v")
		#expect(ASTDump.parse("something unexpected").keyword == "")
	}
}

@Suite struct InferredMembersTests {
	private func structSymbol(_ name: String, lines: [String], children: [(String, Int, Int)]) -> (DocumentSymbol, String) {
		let text = lines.joined(separator: "\n") + "\n"
		let kids = children.map { name, kind, line -> DocumentSymbol in
			let column = (lines[line] as NSString).range(of: name).location
			return DocumentSymbol(
				name: name, detail: nil, kind: kind,
				range: LSPRange(start: LSPPosition(line: line, character: 1), end: LSPPosition(line: line, character: lines[line].utf16.count)),
				selectionRange: LSPRange(start: LSPPosition(line: line, character: column), end: LSPPosition(line: line, character: column + name.utf16.count)),
				children: nil)
		}
		let symbol = DocumentSymbol(
			name: name, detail: nil, kind: SymbolKind.structure,
			range: LSPRange(start: LSPPosition(line: 0, character: 0), end: LSPPosition(line: lines.count - 1, character: 1)),
			selectionRange: LSPRange(start: LSPPosition(line: 0, character: 7), end: LSPPosition(line: 0, character: 7 + name.utf16.count)), children: kids)
		return (symbol, text)
	}

	@Test func theMemberwiseInitIsWorkedOutFromStoredProperties() throws {
		let (symbol, text) = structSymbol(
			"User",
			lines: ["struct User {", "\tlet name: String", "\tvar age: Int", "\tvar nick: String? = nil", "\tlet id: Int = 1", "\tstatic var count = 0", "\tvar label: String { name }", "}"],
			children: [("name", 7, 1), ("age", 7, 2), ("nick", 7, 3), ("id", 7, 4), ("count", 7, 5), ("label", 7, 6)])
		let member = try #require(InferredMembers.memberwiseInit(for: symbol, in: text))
		#expect(member.declaration == "internal init(name: String, age: Int, nick: String? = nil)")
		#expect(member.key == "init(name:age:nick:)")
		#expect(member.reason == "memberwise initializer")
	}

	@Test func anExplicitInitOrAnInferredTypeMeansNoGuess() {
		let (withInit, text1) = structSymbol(
			"A", lines: ["struct A {", "\tvar x: Int", "\tinit() { x = 0 }", "}"], children: [("x", 7, 1), ("init(", 9, 2)])
		#expect(InferredMembers.memberwiseInit(for: withInit, in: text1) == nil)
		let (inferred, text2) = structSymbol("B", lines: ["struct B {", "\tvar x = 1", "}"], children: [("x", 7, 1)])
		#expect(InferredMembers.memberwiseInit(for: inferred, in: text2) == nil)  // `var x = 1`: the type isn't written, so don't guess
		let (classLike, text3) = structSymbol("C", lines: ["struct C {", "\tvar y: Int", "}"], children: [("y", 7, 1)])
		var notAStruct = classLike
		notAStruct.kind = SymbolKind.class
		#expect(InferredMembers.memberwiseInit(for: notAStruct, in: text3) == nil)
	}
}

@Suite struct InferredTypesTests {
	@Test func propertiesWithoutAWrittenTypeAreNamedSoTheirTypeCanBeAsked() {
		let lines = ["struct C {", "\tvar count = 0", "\tvar ratio = 0.5", "\tlet name: String", "\tvar tags: [String] = []", "}"]
		let text = lines.joined(separator: "\n") + "\n"
		func property(_ name: String, _ line: Int) -> DocumentSymbol {
			let column = (lines[line] as NSString).range(of: name).location
			return DocumentSymbol(
				name: name, detail: nil, kind: SymbolKind.property,
				range: LSPRange(start: LSPPosition(line: line, character: 1), end: LSPPosition(line: line, character: lines[line].utf16.count)),
				selectionRange: LSPRange(start: LSPPosition(line: line, character: column), end: LSPPosition(line: line, character: column + name.utf16.count)),
				children: nil)
		}
		let symbol = DocumentSymbol(
			name: "C", detail: nil, kind: SymbolKind.structure,
			range: LSPRange(start: LSPPosition(line: 0, character: 0), end: LSPPosition(line: 5, character: 1)),
			selectionRange: LSPRange(start: LSPPosition(line: 0, character: 7), end: LSPPosition(line: 0, character: 8)),
			children: [property("count", 1), property("ratio", 2), property("name", 3), property("tags", 4)])
		#expect(InferredMembers.untypedProperties(of: symbol, in: text).map(\.name) == ["count", "ratio"])
		#expect(InferredMembers.memberwiseInit(for: symbol, in: text) == nil)
		// With the types the language server reported, the init is complete, defaults included.
		let member = InferredMembers.memberwiseInit(for: symbol, in: text, types: ["count": "Int", "ratio": "Double"])
		#expect(member?.declaration == "internal init(count: Int = 0, ratio: Double = 0.5, name: String, tags: [String] = [])")
		#expect(member?.key == "init(count:ratio:name:tags:)")
		// One type still missing: no init rather than a wrong one.
		#expect(InferredMembers.memberwiseInit(for: symbol, in: text, types: ["count": "Int"]) == nil)
	}

	@Test func theTypeIsReadFromAHover() {
		#expect(InferredMembers.type(fromHover: "```swift\npublic var count: Int\n```", property: "count") == "Int")
		#expect(InferredMembers.type(fromHover: "```swift\nvar items: [String : Int] = [:]\n```\n\nDocs.", property: "items") == "[String : Int]")
		#expect(InferredMembers.type(fromHover: "```swift\nlet handler: (Int) -> Void\n```", property: "handler") == "(Int) -> Void")
		#expect(InferredMembers.type(fromHover: "```swift\nvar total: Int { get }\n```", property: "total") == "Int")
		#expect(InferredMembers.type(fromHover: "```swift\nvar other: Int\n```", property: "count") == nil)
		#expect(InferredMembers.type(fromHover: "", property: "count") == nil)
	}
}
