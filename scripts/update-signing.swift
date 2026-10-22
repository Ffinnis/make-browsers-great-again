import CryptoKit
import Foundation

func fail(_ message: String) -> Never {
    FileHandle.standardError.write((message + "\n").data(using: .utf8)!)
    exit(1)
}

func privateKey() -> Curve25519.Signing.PrivateKey {
    guard let raw = ProcessInfo.processInfo.environment["MBGA_UPDATE_KEY"].flatMap({ Data(base64Encoded: $0) }),
          let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: raw)
    else { fail("MBGA_UPDATE_KEY must hold the base64 private key") }
    return key
}

let args = CommandLine.arguments.dropFirst()
switch args.first {
case "generate":
    let key = Curve25519.Signing.PrivateKey()
    print(key.rawRepresentation.base64EncodedString())
    print(key.publicKey.rawRepresentation.base64EncodedString())
case "public-key":
    print(privateKey().publicKey.rawRepresentation.base64EncodedString())
case "sign":
    guard let path = args.dropFirst().first, let handle = FileHandle(forReadingAtPath: path) else {
        fail("usage: sign <file>")
    }
    var hash = SHA256()
    while case let chunk = handle.readData(ofLength: 1 << 20), !chunk.isEmpty {
        hash.update(data: chunk)
    }
    let digest = Data(hash.finalize())
    print(digest.map { String(format: "%02x", $0) }.joined())
    print(try privateKey().signature(for: digest).base64EncodedString())
default:
    fail("usage: update-signing.swift generate | public-key | sign <file>")
}
