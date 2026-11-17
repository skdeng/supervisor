import Foundation

/// A JSON value, for tool arguments and schemas that have no fixed shape.
enum JSONValue: Codable, Equatable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: JSONValue].self))
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case let .bool(value): try container.encode(value)
        case let .number(value): try container.encode(value)
        case let .string(value): try container.encode(value)
        case let .array(value): try container.encode(value)
        case let .object(value): try container.encode(value)
        }
    }

    /// The member named `key` of an object; nil for any other kind of value or a missing member.
    subscript(key: String) -> JSONValue? {
        guard case let .object(members) = self else { return nil }
        return members[key]
    }

    var stringValue: String? {
        guard case let .string(value) = self else { return nil }
        return value
    }

    /// The number as an `Int`, when it is a whole number within `Int`'s range.
    var intValue: Int? {
        guard case let .number(value) = self,
              value.isFinite,
              value.rounded(.towardZero) == value,
              value >= Double(Int.min),
              value < Double(Int.max)
        else { return nil }
        return Int(value)
    }

    var objectValue: [String: JSONValue]? {
        guard case let .object(members) = self else { return nil }
        return members
    }
}
