import Foundation

/// A tolerant HTML tokenizer: enough structure to read search-result markup
/// and pull readable text out of a page, without a browser engine. It never
/// executes or fetches anything a page refers to.
enum AppHTMLToken: Equatable {
    case start(name: String, attributes: [String: String], selfClosing: Bool)
    case end(name: String)
    case text(String)
}

enum AppHTML {
    /// Elements whose content is never text: their bodies are skipped
    /// verbatim up to the matching close tag.
    static let rawTextElements: Set<String> = ["script", "style", "noscript", "template",
                                               "textarea"]

    static func tokens(_ html: String) -> [AppHTMLToken] {
        var result: [AppHTMLToken] = []
        let scalars = Array(html.unicodeScalars)
        var index = 0
        var text = String.UnicodeScalarView()
        func flushText() {
            if !text.isEmpty {
                result.append(.text(decodeEntities(String(text))))
                text.removeAll()
            }
        }
        // Literals here are ASCII markup; compare ASCII case-insensitively
        // without building strings per character.
        func lower(_ value: UInt32) -> UInt32 { (65...90).contains(value) ? value + 32 : value }
        func starts(with literal: String, at position: Int) -> Bool {
            var offset = position
            for scalar in literal.unicodeScalars {
                guard offset < scalars.count,
                      lower(scalars[offset].value) == lower(scalar.value)
                else { return false }
                offset += 1
            }
            return true
        }
        func find(_ literal: String, from position: Int) -> Int? {
            guard let first = literal.unicodeScalars.first.map({ lower($0.value) }) else {
                return position
            }
            var offset = position
            while offset < scalars.count {
                if lower(scalars[offset].value) == first, starts(with: literal, at: offset) {
                    return offset
                }
                offset += 1
            }
            return nil
        }

        while index < scalars.count {
            let scalar = scalars[index]
            guard scalar == "<" else {
                text.append(scalar)
                index += 1
                continue
            }
            if starts(with: "<!--", at: index) {
                flushText()
                index = (find("-->", from: index + 4).map { $0 + 3 }) ?? scalars.count
                continue
            }
            if starts(with: "<!", at: index) || starts(with: "<?", at: index) {
                flushText()
                index = (find(">", from: index + 2).map { $0 + 1 }) ?? scalars.count
                continue
            }
            // A tag must begin with a letter or a slash and a letter; anything
            // else is literal text, as browsers treat it.
            let next = index + 1 < scalars.count ? scalars[index + 1] : " "
            let isEnd = next == "/"
            let nameStart = isEnd ? index + 2 : index + 1
            guard nameStart < scalars.count,
                  CharacterSet.letters.contains(scalars[nameStart]) else {
                text.append(scalar)
                index += 1
                continue
            }
            flushText()
            guard let close = findTagEnd(scalars, from: nameStart) else {
                index = scalars.count
                break
            }
            let body = String(String.UnicodeScalarView(scalars[nameStart..<close]))
            index = close + 1
            if isEnd {
                let name = body.split(whereSeparator: { $0.isWhitespace }).first
                    .map { $0.lowercased() } ?? ""
                result.append(.end(name: name))
                continue
            }
            let (name, attributes, selfClosing) = parseTag(body)
            result.append(.start(name: name, attributes: attributes, selfClosing: selfClosing))
            if rawTextElements.contains(name), !selfClosing {
                let closing = "</" + name
                let end = find(closing, from: index) ?? scalars.count
                index = end < scalars.count
                    ? ((find(">", from: end).map { $0 + 1 }) ?? scalars.count)
                    : scalars.count
                result.append(.end(name: name))
            }
        }
        flushText()
        return result
    }

    /// The `>` that ends a tag, skipping any inside quoted attribute values.
    private static func findTagEnd(_ scalars: [Unicode.Scalar], from start: Int) -> Int? {
        var quote: Unicode.Scalar?
        var offset = start
        while offset < scalars.count {
            let scalar = scalars[offset]
            if let open = quote {
                if scalar == open { quote = nil }
            } else if scalar == "\"" || scalar == "'" {
                quote = scalar
            } else if scalar == ">" {
                return offset
            }
            offset += 1
        }
        return nil
    }

    private static func parseTag(_ body: String) -> (String, [String: String], Bool) {
        var scalars = Substring(body)
        var selfClosing = false
        if scalars.hasSuffix("/") {
            selfClosing = true
            scalars = scalars.dropLast()
        }
        let nameEnd = scalars.firstIndex(where: { $0.isWhitespace || $0 == "/" }) ?? scalars.endIndex
        let name = scalars[..<nameEnd].lowercased()
        var attributes: [String: String] = [:]
        var rest = scalars[nameEnd...]
        while true {
            rest = rest.drop(while: { $0.isWhitespace || $0 == "/" })
            guard !rest.isEmpty else { break }
            let keyEnd = rest.firstIndex(where: { $0.isWhitespace || $0 == "=" }) ?? rest.endIndex
            let key = rest[..<keyEnd].lowercased()
            rest = rest[keyEnd...].drop(while: { $0.isWhitespace })
            guard rest.first == "=" else {
                if !key.isEmpty { attributes[key] = "" }
                continue
            }
            rest = rest.dropFirst().drop(while: { $0.isWhitespace })
            let value: Substring
            if let quote = rest.first, quote == "\"" || quote == "'" {
                let afterQuote = rest.dropFirst()
                let end = afterQuote.firstIndex(of: quote) ?? afterQuote.endIndex
                value = afterQuote[..<end]
                rest = end < afterQuote.endIndex ? afterQuote[afterQuote.index(after: end)...] : ""
            } else {
                let end = rest.firstIndex(where: { $0.isWhitespace }) ?? rest.endIndex
                value = rest[..<end]
                rest = rest[end...]
            }
            if !key.isEmpty { attributes[key] = decodeEntities(String(value)) }
        }
        return (name, attributes, selfClosing)
    }

    private static let namedEntities: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": " ",
        "ndash": "-", "mdash": "-", "hellip": "...", "lsquo": "'", "rsquo": "'",
        "ldquo": "\"", "rdquo": "\"", "laquo": "\"", "raquo": "\"", "middot": ".",
        "bull": "*", "copy": "(c)", "reg": "(R)", "trade": "(TM)", "times": "x",
        "eacute": "é", "egrave": "è", "aacute": "á", "agrave": "à", "uuml": "ü",
        "ouml": "ö", "auml": "ä", "szlig": "ß", "ccedil": "ç", "ntilde": "ñ",
        "deg": "°", "euro": "€", "pound": "£", "yen": "¥", "cent": "¢",
    ]

    static func decodeEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }
        var output = ""
        output.reserveCapacity(text.count)
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            guard character == "&",
                  let semicolon = text[index...].prefix(12).firstIndex(of: ";") else {
                output.append(character)
                index = text.index(after: index)
                continue
            }
            let name = text[text.index(after: index)..<semicolon]
            var decoded: String?
            if name.hasPrefix("#x") || name.hasPrefix("#X") {
                decoded = UInt32(name.dropFirst(2), radix: 16)
                    .flatMap(Unicode.Scalar.init).map { String(Character($0)) }
            } else if name.hasPrefix("#") {
                decoded = UInt32(name.dropFirst())
                    .flatMap(Unicode.Scalar.init).map { String(Character($0)) }
            } else {
                decoded = namedEntities[String(name)]
            }
            if let decoded {
                output += decoded
                index = text.index(after: semicolon)
            } else {
                output.append(character)
                index = text.index(after: index)
            }
        }
        return output
    }

    /// Whitespace collapsed to single spaces, trimmed.
    static func collapse(_ text: String) -> String {
        text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }
}

/// Readable text from a page: the article or main element when the page has
/// one with real content, otherwise the body, without navigation, scripts,
/// forms or other chrome.
struct AppHTMLDocumentText: Equatable {
    var title: String?
    var text: String

    private static let skipped: Set<String> = [
        "script", "style", "noscript", "template", "svg", "nav", "header", "footer",
        "aside", "form", "iframe", "button", "select", "textarea", "head", "menu", "dialog",
    ]
    private static let blocks: Set<String> = [
        "p", "div", "section", "article", "main", "br", "li", "ul", "ol", "tr", "table",
        "h1", "h2", "h3", "h4", "h5", "h6", "pre", "blockquote", "dd", "dt", "figure",
        "figcaption", "hr",
    ]
    private static let voidElements: Set<String> = [
        "br", "hr", "img", "input", "meta", "link", "area", "base", "col", "embed",
        "source", "track", "wbr", "param",
    ]

    static func extract(_ html: String) -> AppHTMLDocumentText {
        let tokens = AppHTML.tokens(html)
        let title = titleText(tokens)
        for container in ["article", "main"] {
            if let text = text(tokens, inside: container),
               text.count >= 200 {
                return AppHTMLDocumentText(title: title, text: text)
            }
        }
        return AppHTMLDocumentText(title: title, text: text(tokens, inside: nil) ?? "")
    }

    private static func titleText(_ tokens: [AppHTMLToken]) -> String? {
        var inTitle = false
        var title = ""
        for token in tokens {
            switch token {
            case .start(let name, let attributes, _):
                if name == "title" { inTitle = true }
                if name == "meta", attributes["property"] == "og:title",
                   let content = attributes["content"], !content.isEmpty, title.isEmpty {
                    title = content
                }
            case .end(let name):
                if name == "title", inTitle { inTitle = false }
            case .text(let value):
                if inTitle { title += value }
            }
        }
        let collapsed = AppHTML.collapse(title)
        return collapsed.isEmpty ? nil : collapsed
    }

    /// Text inside the first `container` element (or the whole document when
    /// nil), one line per block element.
    private static func text(_ tokens: [AppHTMLToken], inside container: String?) -> String? {
        var depth = container == nil ? 1 : 0
        var found = container == nil
        var skipDepth = 0
        var lines: [String] = []
        var current = ""
        func breakLine() {
            let line = AppHTML.collapse(current)
            if !line.isEmpty { lines.append(line) }
            current = ""
        }
        for token in tokens {
            switch token {
            case .start(let name, _, let selfClosing):
                let isVoid = selfClosing || voidElements.contains(name)
                if let container, name == container, !isVoid {
                    if depth == 0 && found { continue }
                    if depth == 0 { found = true }
                    depth += 1
                    continue
                }
                guard depth > 0 else { continue }
                if skipped.contains(name), !isVoid { skipDepth += 1 }
                if blocks.contains(name) { breakLine() }
            case .end(let name):
                if let container, name == container, depth > 0 {
                    depth -= 1
                    if depth == 0 { breakLine(); return lines.joined(separator: "\n") }
                    continue
                }
                guard depth > 0 else { continue }
                if skipped.contains(name), skipDepth > 0 { skipDepth -= 1 }
                if blocks.contains(name) { breakLine() }
            case .text(let value):
                guard depth > 0, skipDepth == 0 else { continue }
                current += value
            }
        }
        breakLine()
        return found ? lines.joined(separator: "\n") : nil
    }
}
