import Foundation
import CryptoKit

guard CommandLine.arguments.count == 3 else { fatalError("Pass a private key file and expected public key.") }
let encoded = try String(contentsOfFile: CommandLine.arguments[1], encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
guard let seed = Data(base64Encoded: encoded), seed.count == 32 else { fatalError("Expected a Sparkle Ed25519 seed exported by generate_keys.") }
let key = try Curve25519.Signing.PrivateKey(rawRepresentation: seed)
guard key.publicKey.rawRepresentation.base64EncodedString() == CommandLine.arguments[2] else { fatalError("The private update key does not match release.json.") }
print("Update signing key matches its public verification key.")
