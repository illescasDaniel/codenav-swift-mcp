import Foundation

/// A dynamically typed JSON value. Used for LSP payloads that are opaque to us
/// (e.g. a hierarchy item's `data`, which must round-trip untouched) and for
/// tool arguments.
public enum JSONValue: Sendable, Hashable, Codable {
	case null
	case bool(Bool)
	case int(Int)
	case double(Double)
	case string(String)
	case array([JSONValue])
	case object([String: JSONValue])

	public init(from decoder: Decoder) throws {
		let container = try decoder.singleValueContainer()
		if container.decodeNil() {
			self = .null
		} else if let value = try? container.decode(Bool.self) {
			self = .bool(value)
		} else if let value = try? container.decode(Int.self) {
			self = .int(value)
		} else if let value = try? container.decode(Double.self) {
			self = .double(value)
		} else if let value = try? container.decode(String.self) {
			self = .string(value)
		} else if let value = try? container.decode([JSONValue].self) {
			self = .array(value)
		} else {
			self = .object(try container.decode([String: JSONValue].self))
		}
	}

	public func encode(to encoder: Encoder) throws {
		var container = encoder.singleValueContainer()
		switch self {
		case .null: try container.encodeNil()
		case .bool(let value): try container.encode(value)
		case .int(let value): try container.encode(value)
		case .double(let value): try container.encode(value)
		case .string(let value): try container.encode(value)
		case .array(let value): try container.encode(value)
		case .object(let value): try container.encode(value)
		}
	}

	public var stringValue: String? {
		if case .string(let value) = self { return value }
		return nil
	}

	/// Integers, whole doubles and numeric strings ("12"): agents are loose about numbers.
	public var intValue: Int? {
		switch self {
		case .int(let value): return value
		case .double(let value): return value.rounded() == value ? Int(exactly: value) : nil
		case .string(let value): return Int(value.trimmingCharacters(in: .whitespaces))
		default: return nil
		}
	}

	/// Booleans and the strings "true"/"false" (case-insensitive).
	public var boolValue: Bool? {
		switch self {
		case .bool(let value): return value
		case .string(let value):
			switch value.lowercased() {
			case "true": return true
			case "false": return false
			default: return nil
			}
		default: return nil
		}
	}

	public var arrayValue: [JSONValue]? {
		if case .array(let value) = self { return value }
		return nil
	}

	public var objectValue: [String: JSONValue]? {
		if case .object(let value) = self { return value }
		return nil
	}

	public subscript(key: String) -> JSONValue? {
		objectValue?[key]
	}
}

extension JSONValue: ExpressibleByNilLiteral, ExpressibleByBooleanLiteral, ExpressibleByIntegerLiteral,
	ExpressibleByFloatLiteral, ExpressibleByStringLiteral, ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral
{
	public init(nilLiteral: ()) { self = .null }
	public init(booleanLiteral value: Bool) { self = .bool(value) }
	public init(integerLiteral value: Int) { self = .int(value) }
	public init(floatLiteral value: Double) { self = .double(value) }
	public init(stringLiteral value: String) { self = .string(value) }
	public init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
	public init(dictionaryLiteral elements: (String, JSONValue)...) {
		self = .object(Dictionary(uniqueKeysWithValues: elements))
	}
}
