import CryptoKit
import Foundation
let key = Curve25519.Signing.PrivateKey()
let privateMaterial = key.rawRepresentation
try Data(privateMaterial.base64EncodedString().utf8).write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: CommandLine.arguments[1])
try Data(key.publicKey.rawRepresentation.base64EncodedString().utf8).write(to: URL(fileURLWithPath: CommandLine.arguments[2]))
