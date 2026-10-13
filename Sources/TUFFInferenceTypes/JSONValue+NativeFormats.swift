import Foundation

extension JSONValue {
    public func jinjaSendableValue() throws -> any Sendable {
        switch self {
        case .object(let value):
            return try value.mapValues { try $0.jinjaSendableValue() }
        case .array(let value):
            return try value.map { try $0.jinjaSendableValue() }
        case .string(let value):
            return value
        case .integer(let value):
            guard let value = Int(exactly: value) else {
                throw ToolCallParserError.malformed
            }
            return value
        case .unsignedInteger(let value):
            guard let value = Int(exactly: value) else {
                throw ToolCallParserError.malformed
            }
            return value
        case .decimal(let value):
            let text = NSDecimalNumber(decimal: value).stringValue
            guard let double = Double(text),
                  double.isFinite,
                  let roundTrip = Decimal(
                    string: String(double),
                    locale: Locale(identifier: "en_US_POSIX")),
                  roundTrip == value else {
                throw ToolCallParserError.malformed
            }
            return double
        case .number(let value):
            return value
        case .bool(let value):
            return value
        case .null:
            return Optional<String>.none as String?
        }
    }

    public func gemmaToolArgumentBody() throws -> String {
        guard case .object(let value) = self else {
            throw ToolCallParserError.malformed
        }
        return try value.keys.sorted().map { key in
            guard GemmaToolCallParser.isRepresentableObjectKey(key) else {
                throw ToolCallParserError.malformed
            }
            return "\(key):\(try value[key]!.gemmaToolValue())"
        }.joined(separator: ",")
    }

    private func gemmaToolValue() throws -> String {
        switch self {
        case .object:
            return "{\(try gemmaToolArgumentBody())}"
        case .array(let value):
            return "[\(try value.map { try $0.gemmaToolValue() }.joined(separator: ","))]"
        case .string(let value):
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.withoutEscapingSlashes]
            return String(decoding: try encoder.encode(value), as: UTF8.self)
        case .integer(let value):
            return String(value)
        case .unsignedInteger(let value):
            return String(value)
        case .decimal(let value):
            return NSDecimalNumber(decimal: value).stringValue
        case .number(let value):
            guard value.isFinite else {
                throw ToolCallParserError.malformed
            }
            return String(value)
        case .bool(let value):
            return value ? "true" : "false"
        case .null:
            return "null"
        }
    }
}
