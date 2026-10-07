import Foundation

/// Citations in an answer, checked against the sources the app retrieved.
///
/// A citation is `[n]`, `[n, m]` or a run of them. Only numbers the app
/// assigned to a source of this chat are valid; anything else stays plain
/// text and is counted, so a fabricated reference is never made to look like
/// a link.
public enum AppCitations {
    public static let scheme = "tuff-source"

    public struct Check: Equatable, Sendable {
        public var valid: [Int]
        public var invalid: [Int]
    }

    private static let groupPattern = try! NSRegularExpression(
        pattern: #"\[(\d{1,4}(?:\s*,\s*\d{1,4})*)\](?!\()"#)

    /// Ranges of `text` outside fenced and inline code.
    private static func prose(_ text: String) -> [Range<String.Index>] {
        var ranges: [Range<String.Index>] = []
        var cursor = text.startIndex
        var start = text.startIndex
        var inFence = false
        var inInline = false
        while cursor < text.endIndex {
            if text[cursor...].hasPrefix("```") {
                if !inFence && !inInline { ranges.append(start..<cursor) }
                inFence.toggle()
                cursor = text.index(cursor, offsetBy: 3)
                if !inFence { start = cursor }
                continue
            }
            if !inFence, text[cursor] == "`" {
                if !inInline { ranges.append(start..<cursor) }
                inInline.toggle()
                cursor = text.index(after: cursor)
                if !inInline { start = cursor }
                continue
            }
            cursor = text.index(after: cursor)
        }
        if !inFence && !inInline { ranges.append(start..<text.endIndex) }
        return ranges.filter { !$0.isEmpty }
    }

    public static func check(_ text: String, sources: [AppSource]) -> Check {
        let known = Set(sources.map(\.id))
        var valid: [Int] = [], invalid: [Int] = []
        for range in prose(text) {
            let piece = String(text[range])
            let nsRange = NSRange(piece.startIndex..., in: piece)
            for match in groupPattern.matches(in: piece, range: nsRange) {
                guard let inner = Range(match.range(at: 1), in: piece) else { continue }
                for number in piece[inner].split(separator: ",")
                    .compactMap({ Int($0.trimmingCharacters(in: .whitespaces)) }) {
                    if known.contains(number) {
                        if !valid.contains(number) { valid.append(number) }
                    } else if !invalid.contains(number) {
                        invalid.append(number)
                    }
                }
            }
        }
        return Check(valid: valid, invalid: invalid)
    }

    /// Each valid citation number in already-rendered text, with its range.
    /// Links are attached after Markdown rendering rather than written into
    /// the source, because escaped brackets read as display math there.
    /// The caller skips ranges that render as code.
    public static func numberRanges(in text: String, sources: [AppSource])
        -> [(range: NSRange, number: Int)] {
        let known = Set(sources.map(\.id))
        guard !known.isEmpty else { return [] }
        let digits = try! NSRegularExpression(pattern: #"\d{1,4}"#)
        var found: [(NSRange, Int)] = []
        let whole = NSRange(text.startIndex..., in: text)
        for match in groupPattern.matches(in: text, range: whole) {
            let inner = match.range(at: 1)
            for number in digits.matches(in: text, range: inner) {
                guard let range = Range(number.range, in: text),
                      let value = Int(text[range]), known.contains(value) else { continue }
                found.append((number.range, value))
            }
        }
        return found
    }

    public static func url(for number: Int) -> URL {
        URL(string: "\(scheme):\(number)")!
    }

    /// The source a `tuff-source:` link names.
    public static func source(for url: URL, in sources: [AppSource]) -> AppSource? {
        guard url.scheme == scheme,
              let number = Int(url.absoluteString.dropFirst(scheme.count + 1)) else { return nil }
        return sources.first { $0.id == number }
    }
}
