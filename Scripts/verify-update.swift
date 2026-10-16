// Checks an update archive against the EdDSA key a built app will check it with.
//
//   swift Scripts/verify-update.swift <zip> <appcast.xml> <DockFixer.app>
//
// Sparkle on a user's Mac accepts an update only if the signature in the
// appcast verifies with SUPublicEDKey from the bundle it is replacing. The
// release workflow signs with a key from its secrets and builds with a public
// key from the Makefile; if the two ever stop being a pair, every update is
// refused, on every machine, with no way to send a fix through the updater.
// `sign_update --verify` cannot catch that, because it derives the public key
// from the same private one. So the check is done here with the key read back
// out of the bundle that is about to be published — the one the next release
// will be checked against.
import CryptoKit
import Foundation

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("verify-update: \(message)\n".utf8))
    exit(1)
}

let args = CommandLine.arguments
guard args.count == 4 else { fail("usage: verify-update.swift <zip> <appcast.xml> <DockFixer.app>") }
let (zipPath, appcastPath, appPath) = (args[1], args[2], args[3])

guard let archive = FileManager.default.contents(atPath: zipPath) else { fail("cannot read \(zipPath)") }
guard let appcast = try? String(contentsOfFile: appcastPath, encoding: .utf8) else { fail("cannot read \(appcastPath)") }
guard let info = NSDictionary(contentsOfFile: appPath + "/Contents/Info.plist"),
      let keyText = info["SUPublicEDKey"] as? String, !keyText.isEmpty
else { fail("no SUPublicEDKey in \(appPath)") }

func attribute(_ name: String) -> String? {
    guard let range = appcast.range(of: "\(name)=\"([^\"]*)\"", options: .regularExpression) else { return nil }
    return String(appcast[range].dropFirst(name.count + 2).dropLast())
}
guard let signatureText = attribute("sparkle:edSignature") else { fail("no sparkle:edSignature in \(appcastPath)") }
guard let lengthText = attribute("length"), Int(lengthText) == archive.count else {
    fail("length in the appcast does not match the archive (\(archive.count) bytes)")
}

guard let keyData = Data(base64Encoded: keyText),
      let key = try? Curve25519.Signing.PublicKey(rawRepresentation: keyData)
else { fail("SUPublicEDKey is not an Ed25519 public key") }
guard let signature = Data(base64Encoded: signatureText) else { fail("edSignature is not base64") }

guard key.isValidSignature(signature, for: archive) else {
    fail("the signature does not verify with the app's SUPublicEDKey — the signing secret and ED_PUBLIC_KEY are not a pair")
}
print("verify-update: \(zipPath) verifies with SUPublicEDKey \(keyText)")
