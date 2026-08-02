//
//  RemoteConfigCrypto.swift
//  CircleStack
//

import Foundation
import CryptoKit

/// Signs outgoing config requests and decrypts the responses.
///
/// TLS already protects this traffic on the wire; this layer exists for a different
/// reason. The config endpoint is a public URL, so without it anyone who knew the
/// address could read the config and — worse — forge analytics hits and inflate the
/// install and daily-active counts. Signing makes the worker reject anything that
/// did not come from the app, and encrypting the response keeps the config itself
/// from being readable by casually hitting the URL.
///
/// Known limitation: the shared secret ships inside the app binary, so a determined
/// person can extract it. This raises the cost from "paste a URL in a browser" to
/// "reverse engineer the app"; it is deliberately not treated as real authentication.
enum RemoteConfigCrypto {

    /// Shared with the Cloudflare Worker, where it lives as the APP_SECRET secret.
    /// Kept in Secrets.swift, which is gitignored, so the value never reaches the
    /// repository — see Secrets.swift.template for how to set it up.
    private static var sharedSecret: String { Secrets.remoteConfig }

    private static var key: SymmetricKey {
        SymmetricKey(data: SHA256.hash(data: Data(sharedSecret.utf8)))
    }

    /// Query items proving this request came from the app: a timestamp plus an
    /// HMAC over the same fields the worker recomputes.
    static func signedQueryItems(event: String, uuid: String) -> [URLQueryItem] {
        let timestamp = String(Int(Date().timeIntervalSince1970))
        let message = "\(event)|\(uuid)|\(timestamp)"

        let signature = HMAC<SHA256>.authenticationCode(
            for: Data(message.utf8),
            using: SymmetricKey(data: Data(sharedSecret.utf8))
        )

        return [
            URLQueryItem(name: "event", value: event),
            URLQueryItem(name: "uuid", value: uuid),
            URLQueryItem(name: "ts", value: timestamp),
            URLQueryItem(name: "sig", value: signature.map { String(format: "%02x", $0) }.joined()),
        ]
    }

    private struct Envelope: Decodable {
        let v: Int
        let iv: String
        let data: String
    }

    /// Unwraps an AES-256-GCM envelope back into the raw config JSON.
    /// Returns nil if the body is not a valid envelope or fails authentication —
    /// a tampered payload is indistinguishable from a corrupt one, and both are
    /// discarded rather than partially trusted.
    static func decrypt(_ body: Data) -> Data? {
        guard let envelope = try? JSONDecoder().decode(Envelope.self, from: body) else {
            return nil
        }
        guard envelope.v == 1,
              let iv = Data(base64Encoded: envelope.iv),
              let ciphertext = Data(base64Encoded: envelope.data) else {
            return nil
        }

        // GCM appends its 16-byte authentication tag to the ciphertext.
        guard ciphertext.count > 16 else { return nil }
        let tagIndex = ciphertext.index(ciphertext.endIndex, offsetBy: -16)

        guard let box = try? AES.GCM.SealedBox(
            nonce: try AES.GCM.Nonce(data: iv),
            ciphertext: ciphertext[..<tagIndex],
            tag: ciphertext[tagIndex...]
        ) else {
            return nil
        }

        return try? AES.GCM.open(box, using: key)
    }
}
