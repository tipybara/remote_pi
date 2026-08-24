import Foundation

/// A JSON value of unknown shape.
///
/// The wire has three genuinely free-form slots — `tool_request.args`,
/// `tool_result.result`, and the whole raw body an `action_ok` carries so a
/// control action can grow fields without a new type here. Everything else is
/// typed.
///
/// ## Why not `[String: Any]`
///
/// `Any` is not `Sendable`, and this module is compiled under Swift 6 strict
/// concurrency: a `[String: Any]` stored on a message would make every frame
/// non-`Sendable` and stop it crossing an actor boundary. It is also not
/// `Equatable`, which kills every "decode, re-encode, compare" wire test.
///
/// ## Number fidelity
///
/// ``int(_:)`` and ``double(_:)`` are separate cases on purpose. Every
/// timestamp on this wire is epoch **milliseconds** — `1780000000000` — which
/// survives a `Double` exactly but comes back out of a naive re-encode as
/// `1.78e+12`. The Pi's `JSON.parse` would accept that; a human reading a
/// packet dump would not, and `tokens_before` / `created_at` comparisons in
/// tests would start failing on formatting rather than on value.
public enum AnyJSON: Hashable, Sendable {
    case null
    case bool(Bool)
    case int(Int64)
    case double(Double)
    case string(String)
    case array([AnyJSON])
    case object([String: AnyJSON])
}

// MARK: - Accessors

extension AnyJSON {
    public var isNull: Bool {
        if case .null = self { return true }
        return false
    }

    public var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    public var boolValue: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }

    /// An integer, accepting a `Double` that happens to be integral — the Pi
    /// emits `created_at` through `JSON.stringify(Date.now())`, which is always
    /// integral, but a value that round-tripped through a `Double` somewhere
    /// upstream must not read as absent.
    public var intValue: Int64? {
        switch self {
        case .int(let value): return value
        case .double(let value) where value.rounded() == value: return Int64(value)
        default: return nil
        }
    }

    public var doubleValue: Double? {
        switch self {
        case .int(let value): return Double(value)
        case .double(let value): return value
        default: return nil
        }
    }

    public var arrayValue: [AnyJSON]? {
        if case .array(let value) = self { return value }
        return nil
    }

    public var objectValue: [String: AnyJSON]? {
        if case .object(let value) = self { return value }
        return nil
    }

    /// Member lookup on an object; `nil` for a non-object or a missing key.
    public subscript(key: String) -> AnyJSON? {
        objectValue?[key]
    }
}

// MARK: - Codable

extension AnyJSON: Codable {
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
            return
        }
        // Order matters. `Bool` first: JSONDecoder is backed by `NSNumber` on
        // Apple platforms, where `true` and `1` share a representation, and
        // trying `Int64` first would turn every `working: true` into `1`.
        if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int64.self) {
            self = .int(value)
        } else if let value = try? container.decode(Double.self) {
            self = .double(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([AnyJSON].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: AnyJSON].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container, debugDescription: "unrepresentable JSON value")
        }
    }

    public func encode(to encoder: any Encoder) throws {
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
}

// MARK: - JSONSerialization bridge

extension AnyJSON {
    /// Wraps a `JSONSerialization` value. Used where a frame is already a
    /// `[String: Any]` — ``ControlFrame/parse(_:)`` and ``ControlReply/parse(_:)``
    /// take that shape because they need key-presence, which `Codable` hides.
    public init(jsonObject: Any) {
        switch jsonObject {
        case is NSNull:
            self = .null
        case let number as NSNumber:
            // `NSNumber` is the one place absent type information really bites:
            // `NSNumber(value: true) as? Bool` succeeds *and* `as? Int` succeeds.
            // Only the CoreFoundation type id separates them, and getting this
            // wrong turns `working: true` into `working: 1`, which the relay's
            // `as_bool()` reads as *absent* — a silently-dropped patch field.
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                self = .bool(number.boolValue)
            } else if CFNumberIsFloatType(number as CFNumber) {
                self = .double(number.doubleValue)
            } else {
                self = .int(number.int64Value)
            }
        case let value as String:
            self = .string(value)
        case let value as [Any]:
            self = .array(value.map(AnyJSON.init(jsonObject:)))
        case let value as [String: Any]:
            self = .object(value.mapValues(AnyJSON.init(jsonObject:)))
        default:
            self = .null
        }
    }

    /// The `JSONSerialization` representation.
    public var jsonObject: Any {
        switch self {
        case .null: return NSNull()
        case .bool(let value): return value
        case .int(let value): return value
        case .double(let value): return value
        case .string(let value): return value
        case .array(let value): return value.map(\.jsonObject)
        case .object(let value): return value.mapValues(\.jsonObject)
        }
    }
}

// MARK: - Literals (test ergonomics)

extension AnyJSON: ExpressibleByNilLiteral {
    public init(nilLiteral: ()) { self = .null }
}

extension AnyJSON: ExpressibleByBooleanLiteral {
    public init(booleanLiteral value: Bool) { self = .bool(value) }
}

extension AnyJSON: ExpressibleByIntegerLiteral {
    public init(integerLiteral value: Int64) { self = .int(value) }
}

extension AnyJSON: ExpressibleByFloatLiteral {
    public init(floatLiteral value: Double) { self = .double(value) }
}

extension AnyJSON: ExpressibleByStringLiteral {
    public init(stringLiteral value: String) { self = .string(value) }
}

extension AnyJSON: ExpressibleByArrayLiteral {
    public init(arrayLiteral elements: AnyJSON...) { self = .array(elements) }
}

extension AnyJSON: ExpressibleByDictionaryLiteral {
    public init(dictionaryLiteral elements: (String, AnyJSON)...) {
        self = .object(Dictionary(elements, uniquingKeysWith: { _, last in last }))
    }
}
