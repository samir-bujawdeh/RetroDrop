// Signs release disk images so RetroDrop's updater can verify them. Run from the repo root:
//
//   swift scripts/update-signing.swift init          # once: create the signing key, print the public key
//   swift scripts/update-signing.swift public-key    # print the public key (goes in Info.plist)
//   swift scripts/update-signing.swift sign <file>   # write <file>.sig (used by scripts/build.sh)
//
// The private key lives in ~/.retrodrop/update-signing-key, outside the repo. Back it up somewhere safe
// (e.g. a password manager): without it you can't publish updates that existing copies will accept.
import CryptoKit
import Foundation

// RETRODROP_SIGNING_KEY points at a different key file (the tests use a throwaway key).
let keyURL = ProcessInfo.processInfo.environment["RETRODROP_SIGNING_KEY"].map { URL(fileURLWithPath: $0) }
    ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".retrodrop/update-signing-key")

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

func loadKey() -> Curve25519.Signing.PrivateKey {
    guard let text = try? String(contentsOf: keyURL, encoding: .utf8),
          let raw = Data(base64Encoded: text.trimmingCharacters(in: .whitespacesAndNewlines)),
          let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: raw)
    else { fail("No signing key at \(keyURL.path). Run: swift scripts/update-signing.swift init") }
    return key
}

let args = CommandLine.arguments.dropFirst()
switch args.first {
case "init":
    if FileManager.default.fileExists(atPath: keyURL.path) { fail("A key already exists at \(keyURL.path). Not overwriting it.") }
    let key = Curve25519.Signing.PrivateKey()
    try! FileManager.default.createDirectory(at: keyURL.deletingLastPathComponent(), withIntermediateDirectories: true,
                                             attributes: [.posixPermissions: 0o700])
    FileManager.default.createFile(atPath: keyURL.path, contents: Data(key.rawRepresentation.base64EncodedString().utf8),
                                   attributes: [.posixPermissions: 0o600])
    print(key.publicKey.rawRepresentation.base64EncodedString())
case "public-key":
    print(loadKey().publicKey.rawRepresentation.base64EncodedString())
case "sign":
    guard let path = args.dropFirst().first, let data = FileManager.default.contents(atPath: path) else { fail("Usage: sign <file>") }
    let signature = try! loadKey().signature(for: data)
    try! Data(signature.base64EncodedString().utf8).write(to: URL(fileURLWithPath: path + ".sig"))
    print("Signed \(path)")
default:
    fail("Usage: update-signing.swift init | public-key | sign <file>")
}
