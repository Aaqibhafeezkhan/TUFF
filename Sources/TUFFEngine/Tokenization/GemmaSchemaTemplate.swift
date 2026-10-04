/// Extends the installed Gemma declaration macro only for schema nodes its
/// single-type branch cannot render. Union nodes retain their complete JSON
/// Schema in the native key/value notation, including every branch and sibling
/// constraint. Ordinary declarations and conversation framing remain upstream.
enum GemmaSchemaTemplate {
    static func needsExtension(_ schema: JSONValue) -> Bool {
        switch schema {
        case .object(let object):
            if object["anyOf"] != nil || object["oneOf"] != nil { return true }
            if case .array? = object["type"] { return true }
            return object.values.contains(where: needsExtension)
        case .array(let values): return values.contains(where: needsExtension)
        default: return false
        }
    }

    static func extending(_ template: String) -> String? {
        let declaration = "macro format_parameters("
        guard let start = template.range(of: declaration),
              let end = template.range(of: "{%- endmacro -%}", range: start.upperBound..<template.endIndex)
        else { return nil }
        let opening = "{{ key }}:{"
        let closing = #"type:<|"|>{{ value['type'] | upper }}<|"|>}"#
        let body = String(template[start.lowerBound..<end.upperBound])
        guard body.components(separatedBy: opening).count == 2,
              body.components(separatedBy: closing).count == 2 else { return nil }
        let extendedBody = body.replacingOccurrences(of: opening, with: branch + opening)
            .replacingOccurrences(of: closing, with: closing + "{%- endif -%}")
        var extended = template
        extended.replaceSubrange(start.lowerBound..<end.upperBound, with: extendedBody)
        return extended
    }

    private static let branch = #"""
    {%- if value['anyOf'] is defined or value['oneOf'] is defined or (value['type'] is defined and value['type'] is not string) -%}
        {{- key -}}:{{- format_argument(value) -}}
    {%- else -%}
    """#
}
