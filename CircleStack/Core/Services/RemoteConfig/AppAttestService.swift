//
//  AppAttestService.swift
//  CircleStack
//

import Foundation
import DeviceCheck
import CryptoKit

/// Proves to the Worker that a request came from a genuine, unmodified copy of this
/// app running on real Apple hardware.
///
/// The private key is created inside the Secure Enclave and never leaves it — there is
/// no secret in the binary, in the repository, or anywhere on disk that could be
/// extracted and reused. That is the difference from the shared-key scheme this
/// replaces, where anyone who could reverse the app could forge requests forever.
///
/// The flow:
///   1. `generateKey` mints a Secure Enclave key; the key id is all we keep.
///   2. `attestKey` has Apple vouch for it once. The Worker checks that attestation
///      against Apple's root certificate and stores the public key.
///   3. Every later request carries an assertion signed by that key over the exact
///      request parameters, which the Worker verifies with the stored public key.
///
/// Not available on the Simulator, and unsupported devices fall back to the shared-key
/// path so the app still works.
actor AppAttestService {
    static let shared = AppAttestService()

    private let service = DCAppAttestService.shared
    private let keyIDDefault = "app_attest_key_id"
    private let attestedDefault = "app_attest_registered"

    /// Serialises setup so a burst of config fetches cannot mint several keys.
    private var setupTask: Task<String?, Never>?

    var isSupported: Bool { service.isSupported }

    private var storedKeyID: String? {
        get { UserDefaults.standard.string(forKey: keyIDDefault) }
    }

    private var isRegistered: Bool {
        UserDefaults.standard.bool(forKey: attestedDefault)
    }

    /// Returns a key id that the server has already accepted, registering one if needed.
    private func readyKeyID(endpoint: String) async -> String? {
        if let existing = storedKeyID, isRegistered { return existing }

        if let running = setupTask { return await running.value }

        let task = Task<String?, Never> { [service] in
            do {
                let keyID: String
                if let existing = storedKeyID {
                    keyID = existing
                } else {
                    keyID = try await service.generateKey()
                    UserDefaults.standard.set(keyID, forKey: keyIDDefault)
                    Logger.shared.i("AppAttest", "Generated a new Secure Enclave key")
                }

                // The challenge ties this attestation to one server-issued nonce, so a
                // captured attestation cannot be replayed later.
                guard let challenge = await fetchChallenge(endpoint: endpoint) else {
                    Logger.shared.e("AppAttest", "Could not get a challenge from the server")
                    return nil
                }

                let clientDataHash = Data(SHA256.hash(data: Data(challenge.utf8)))
                let attestation = try await service.attestKey(keyID, clientDataHash: clientDataHash)

                let accepted = await register(
                    endpoint: endpoint,
                    keyID: keyID,
                    challenge: challenge,
                    attestation: attestation
                )

                guard accepted else {
                    // A rejected key is useless; drop it so the next attempt starts clean.
                    UserDefaults.standard.removeObject(forKey: keyIDDefault)
                    return nil
                }

                UserDefaults.standard.set(true, forKey: attestedDefault)
                Logger.shared.i("AppAttest", "Key registered with the server")
                return keyID
            } catch {
                Logger.shared.e("AppAttest", "Attestation failed: \(error.localizedDescription)")
                // A key can only be attested once. If we got here holding one that
                // Apple has already vouched for, it can never be re-registered —
                // drop it so the next attempt starts from a fresh key.
                UserDefaults.standard.removeObject(forKey: keyIDDefault)
                return nil
            }
        }

        setupTask = task
        let result = await task.value
        setupTask = nil
        return result
    }

    /// Signs the request parameters with the Secure Enclave key.
    /// Returns nil when attestation is unavailable, so the caller can fall back.
    func assertion(endpoint: String, event: String, uuid: String) async -> (keyID: String, assertion: String, challenge: String)? {
        guard service.isSupported else { return nil }
        guard let keyID = await readyKeyID(endpoint: endpoint) else { return nil }
        guard let challenge = await fetchChallenge(endpoint: endpoint) else { return nil }

        // The signed payload covers the challenge and the exact request, so an
        // intercepted assertion cannot be reused for a different call.
        let message = "\(challenge)|\(event)|\(uuid)"
        let clientDataHash = Data(SHA256.hash(data: Data(message.utf8)))

        do {
            let signed = try await service.generateAssertion(keyID, clientDataHash: clientDataHash)
            // base64url: these ride in a query string, where a "+" is decoded as a
            // space and the value stops matching what was signed.
            let encodedKeyID = keyID.base64URLEncoded
            let encodedAssertion = signed.base64URLEncoded
            return (keyID: encodedKeyID, assertion: encodedAssertion, challenge: challenge)
        } catch {
            Logger.shared.e("AppAttest", "Could not generate assertion: \(error.localizedDescription)")
            // A failed assertion can mean the Secure Enclave has not finished
            // activating a just-attested key, or that it no longer recognises it.
            // Either way that key cannot safely be reused for a new attestation.
            invalidateRegistration()
            return nil
        }
    }

    /// Forgets the registration so the next request attests again. Used when the
    /// server stops recognising the key — its record can be dropped or migrated.
    ///
    /// The key id goes with it: Apple lets a key be attested exactly once, so
    /// re-attesting the old one fails with `invalidKey`. A fresh key is the only
    /// way back, and a key the server has forgotten is worthless anyway.
    func invalidateRegistration() {
        UserDefaults.standard.set(false, forKey: attestedDefault)
        UserDefaults.standard.removeObject(forKey: keyIDDefault)
    }

    // MARK: - Server calls

    private func fetchChallenge(endpoint: String) async -> String? {
        guard let url = URL(string: "\(endpoint)?action=challenge") else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 6.0
        request.cachePolicy = .reloadIgnoringLocalCacheData

        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            return json?["challenge"] as? String
        } catch {
            Logger.shared.e("AppAttest", "Challenge request failed: \(error.localizedDescription)")
            return nil
        }
    }

    private func register(endpoint: String, keyID: String, challenge: String, attestation: Data) async -> Bool {
        guard let url = URL(string: "\(endpoint)?action=attest") else { return false }

        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.timeoutInterval = 15.0
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "keyId": keyID,
            "challenge": challenge,
            "attestation": attestation.base64EncodedString(),
        ])

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                let detail = String(data: data, encoding: .utf8) ?? ""
                Logger.shared.e("AppAttest", "Server rejected the attestation: \(detail.prefix(200))")
                return false
            }
            return true
        } catch {
            Logger.shared.e("AppAttest", "Registration request failed: \(error.localizedDescription)")
            return false
        }
    }
}

// MARK: - base64url

private extension Data {
    /// URL-safe base64: no "+", "/" or "=", so the value survives a query string
    /// byte for byte.
    ///
    /// `nonisolated` because the project defaults to main-actor isolation, and this
    /// is called from inside AppAttestService, which is its own actor.
    nonisolated var base64URLEncoded: String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

private extension String {
    /// Apple hands back key ids as standard base64; re-encode without touching bytes.
    nonisolated var base64URLEncoded: String {
        replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
