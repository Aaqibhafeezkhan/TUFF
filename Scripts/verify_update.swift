import CryptoKit
import Foundation

let feed = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
let archive = CommandLine.arguments[2] == "-" ? nil
    : try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[2]))
let keyText = try String(contentsOfFile: CommandLine.arguments[3], encoding: .utf8)
    .trimmingCharacters(in: .whitespacesAndNewlines)
guard let keyData = Data(base64Encoded: keyText) else { fatalError("Invalid client public key") }
let key = try Curve25519.Signing.PublicKey(rawRepresentation: keyData)
let text = String(decoding: feed, as: UTF8.self)
let expression = try NSRegularExpression(pattern: "<!-- sparkle-signatures:\\nedSignature: ([A-Za-z0-9+/=]+)\\nlength: ([0-9]+)\\n-->\\n?$")
let full = NSRange(text.startIndex..<text.endIndex, in: text)
guard let match = expression.firstMatch(in: text, range: full),
      let signatureRange = Range(match.range(at: 1), in: text),
      let lengthRange = Range(match.range(at: 2), in: text),
      let blockRange = Range(match.range, in: text),
      let signature = Data(base64Encoded: String(text[signatureRange])),
      let length = Int(text[lengthRange]),
      Data(text[..<blockRange.lowerBound].utf8).count == length,
      key.isValidSignature(signature, for: feed.prefix(length)) else { fatalError("Feed signature does not match the client public key") }
let xml = try XMLDocument(data: feed)
if archive == nil {
    print("Feed signature verifies against the client public key")
    exit(0)
}
guard let enclosure = try xml.nodes(forXPath: "/rss/channel/item/enclosure").first as? XMLElement,
      let archiveSignature = enclosure.attribute(forName: "sparkle:edSignature")?.stringValue,
      let decoded = Data(base64Encoded: archiveSignature),
      enclosure.attribute(forName: "length")?.stringValue == String(archive!.count),
      key.isValidSignature(decoded, for: archive!) else { fatalError("Archive signature or length does not match the client public key") }
print("Feed and archive signatures verify against the packaged client public key")
