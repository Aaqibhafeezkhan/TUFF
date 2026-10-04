import Foundation

/// The native MiniMax wrapper contains one or more invokes. Parameter strings
/// pass through verbatim; non-string values use JSON, matching its template.
/// This is a delimiter parser, not an XML document reader: shell/file strings
/// may contain unescaped XML characters and entities must remain literal.
public struct MiniMaxToolCallParser: Sendable {
    public static let maximumBytes = 256 * 1024
    private static let maximumCalls = 128

    public init() {}

    public func parse(_ text: String, allowedTools: Set<String>,
                      parameterSchemas: [String: JSONValue] = [:],
                      idGenerator: @Sendable () -> String) throws -> [ParsedToolCall] {
        guard text.utf8.count <= Self.maximumBytes else { throw ToolCallParserError.oversized }
        var body = Substring(text)
        var calls: [ParsedToolCall] = []
        trim(&body)
        while !body.isEmpty {
            guard calls.count < Self.maximumCalls else { throw ToolCallParserError.oversized }
            let name = try attribute("invoke", body: &body)
            guard name.range(of: "^[A-Za-z0-9_-]{1,64}$", options: .regularExpression) != nil
            else { throw ToolCallParserError.malformed }
            guard allowedTools.contains(name) else { throw ToolCallParserError.unknownTool(name) }
            let properties = parameterSchemas[name]?.objectValue?["properties"]?.objectValue ?? [:]
            var arguments: [String: JSONValue] = [:]
            trim(&body)
            while !body.hasPrefix("</invoke>") {
                let key = try attribute("parameter", body: &body)
                guard !key.isEmpty, key.utf8.count <= 256, arguments[key] == nil,
                      !key.contains(where: { $0 == "<" || $0 == ">" || $0.isNewline })
                else { throw ToolCallParserError.malformed }
                guard let close = body.range(of: "</parameter>") else {
                    throw ToolCallParserError.malformed
                }
                let raw = String(body[..<close.lowerBound])
                body = body[close.upperBound...]
                arguments[key] = try value(raw, schema: properties[key])
                trim(&body)
            }
            body.removeFirst("</invoke>".count)
            let value = JSONValue.object(arguments)
            calls.append(ParsedToolCall(id: idGenerator(), name: name, arguments: value,
                                        argumentsJSON: try value.encoded()))
            trim(&body)
        }
        guard !calls.isEmpty else { throw ToolCallParserError.malformed }
        return calls
    }

    private func attribute(_ tag: String, body: inout Substring) throws -> String {
        let opening = "<\(tag) name=\""
        guard body.hasPrefix(opening) else { throw ToolCallParserError.malformed }
        body.removeFirst(opening.count)
        guard let close = body.range(of: "\">") else { throw ToolCallParserError.malformed }
        let name = String(body[..<close.lowerBound])
        guard !name.contains("\"") else { throw ToolCallParserError.malformed }
        body = body[close.upperBound...]
        return name
    }

    private func trim(_ body: inout Substring) {
        while body.first?.isWhitespace == true { body.removeFirst() }
        while body.last?.isWhitespace == true { body.removeLast() }
    }

    private func value(_ raw: String, schema: JSONValue?) throws -> JSONValue {
        // A string-valued argument such as a numeric filename or source file
        // containing JSON must not be reinterpreted as a number/object.
        if schema?.objectValue?["type"] == .string("string") { return .string(raw) }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let first = trimmed.first, "{[-0123456789tfn".contains(first),
           let decoded = try? JSONDecoder().decode(JSONValue.self, from: Data(trimmed.utf8)),
           !isString(decoded) {
            return decoded
        }
        if case .string(let type) = schema?.objectValue?["type"],
           ["object", "array", "number", "integer", "boolean", "null"].contains(type) {
            throw ToolCallParserError.malformed
        }
        return .string(raw)
    }

    private func isString(_ value: JSONValue) -> Bool {
        if case .string = value { return true }
        return false
    }
}
