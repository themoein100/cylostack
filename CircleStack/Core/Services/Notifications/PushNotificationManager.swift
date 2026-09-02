//
//  PushNotificationManager.swift
//  CircleStack
//

import Foundation
import UIKit
import UserNotifications
import Combine

/// Owns the player's notification consent and securely registers their current
/// APNs device token with the app's Worker.
@MainActor
final class PushNotificationManager: ObservableObject {
    static let shared = PushNotificationManager()

    @Published private(set) var authorizationStatus: UNAuthorizationStatus = .notDetermined

    private let center = UNUserNotificationCenter.current()
    private let deviceIdentifierKey = "push_notification_device_identifier"
    private let deviceTokenKey = "push_notification_device_token"
    private let notificationPromptedVersionKey = "push_notification_prompted_version"

    private init() {
        Task { await refreshAuthorizationStatus() }
    }

    var isEnabled: Bool {
        authorizationStatus == .authorized || authorizationStatus == .provisional || authorizationStatus == .ephemeral
    }

    func refreshAuthorizationStatus() async {
        authorizationStatus = await center.notificationSettings().authorizationStatus
    }

    /// Requests consent after a player explicitly chooses to receive game updates.
    func enableNotifications() async {
        let settings = await center.notificationSettings()
        authorizationStatus = settings.authorizationStatus

        switch settings.authorizationStatus {
        case .notDetermined:
            let granted = (try? await center.requestAuthorization(options: [.alert, .badge, .sound])) ?? false
            await refreshAuthorizationStatus()
            if granted {
                UIApplication.shared.registerForRemoteNotifications()
            }
        case .authorized, .provisional, .ephemeral:
            UIApplication.shared.registerForRemoteNotifications()
        case .denied:
            break
        @unknown default:
            break
        }
    }

    func registerForRemoteNotificationsIfAllowed() {
        Task {
            await refreshAuthorizationStatus()
            guard isEnabled else { return }
            UIApplication.shared.registerForRemoteNotifications()
        }
    }

    /// Shows Apple's consent dialog once on the first launch of a newly installed
    /// app or a newly installed app version. iOS will never show this dialog again
    /// after a player denies it; in that case the Settings button remains the way
    /// to turn notifications back on.
    func requestAuthorizationOnFirstLaunchOfCurrentVersion() {
        Task {
            let settings = await center.notificationSettings()
            authorizationStatus = settings.authorizationStatus

            guard settings.authorizationStatus == .notDetermined else {
                if isEnabled { UIApplication.shared.registerForRemoteNotifications() }
                return
            }

            let version = currentAppVersion
            guard UserDefaults.standard.string(forKey: notificationPromptedVersionKey) != version else { return }
            UserDefaults.standard.set(version, forKey: notificationPromptedVersionKey)

            let granted = (try? await center.requestAuthorization(options: [.alert, .badge, .sound])) ?? false
            await refreshAuthorizationStatus()
            if granted { UIApplication.shared.registerForRemoteNotifications() }
        }
    }

    func didRegister(deviceToken: Data) {
        let token = deviceToken.map { String(format: "%02x", $0) }.joined()
        UserDefaults.standard.set(token, forKey: deviceTokenKey)
        #if DEBUG
        // Visible only in an Xcode debug run, so the owner can use the bot's
        // one-device test without exposing a real player's token in production.
        Logger.shared.d("Push", "APNs sandbox test token: \(token)")
        #endif
        Task { await upload(deviceToken: token) }
    }

    func clearBadge() {
        UIApplication.shared.applicationIconBadgeNumber = 0
        if #available(iOS 16.0, *) {
            Task {
                do {
                    try await center.setBadgeCount(0)
                } catch {
                    Logger.shared.w("Push", "Could not clear the system badge: \(error.localizedDescription)")
                }
            }
        }
        guard let token = UserDefaults.standard.string(forKey: deviceTokenKey) else { return }
        Task { await clearServerBadge(deviceToken: token) }
    }

    func didFailToRegister(error: Error) {
        Logger.shared.w("Push", "APNs registration failed: \(error.localizedDescription)")
    }

    private func upload(deviceToken: String) async {
        let endpoint = RemoteConfigManager.shared.remoteConfigURL
        let uuid = stableDeviceIdentifier
        let event = "push_token"

        // App Attest occasionally rejects an assertion made immediately after a
        // fresh key registration. Retry with a short gap so a first-launch consent
        // cannot leave the player permanently absent from the notification list.
        var attested: (keyID: String, assertion: String, challenge: String)?
        for attempt in 0..<3 {
            attested = await AppAttestService.shared.assertion(endpoint: endpoint, event: event, uuid: uuid)
            if attested != nil { break }
            if attempt < 2 {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
        guard let attested else {
            // Push registration intentionally has no shared-secret fallback: unlike
            // remote config it writes a device-addressable server record.
            Logger.shared.w("Push", "App Attest unavailable; device token was not uploaded after retries")
            return
        }

        guard var components = URLComponents(string: endpoint) else {
            Logger.shared.e("Push", "Invalid notification registration endpoint")
            return
        }
        components.queryItems = [
            URLQueryItem(name: "action", value: "push-token"),
            URLQueryItem(name: "event", value: event),
            URLQueryItem(name: "uuid", value: uuid),
            URLQueryItem(name: "keyId", value: attested.keyID),
            URLQueryItem(name: "assertion", value: attested.assertion),
            URLQueryItem(name: "challenge", value: attested.challenge),
        ]
        guard let url = components.url else { return }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 12
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "token": deviceToken,
            "environment": apnsEnvironment,
        ])

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { return }
            if http.statusCode == 401 {
                await AppAttestService.shared.invalidateRegistration()
            }
            guard http.statusCode == 200 else {
                Logger.shared.w("Push", "Device token upload was rejected (HTTP \(http.statusCode))")
                return
            }
            Logger.shared.i("Push", "Device notification token registered")
        } catch {
            Logger.shared.w("Push", "Device token upload failed: \(error.localizedDescription)")
        }
    }

    private var stableDeviceIdentifier: String {
        if let identifier = UserDefaults.standard.string(forKey: deviceIdentifierKey) {
            return identifier
        }
        let identifier = UUID().uuidString
        UserDefaults.standard.set(identifier, forKey: deviceIdentifierKey)
        return identifier
    }

    private func clearServerBadge(deviceToken: String) async {
        let endpoint = RemoteConfigManager.shared.remoteConfigURL
        let uuid = stableDeviceIdentifier
        let event = "clear_badge"
        guard let attested = await AppAttestService.shared.assertion(endpoint: endpoint, event: event, uuid: uuid),
              var components = URLComponents(string: endpoint) else { return }
        components.queryItems = [
            URLQueryItem(name: "action", value: "clear-badge"),
            URLQueryItem(name: "event", value: event),
            URLQueryItem(name: "uuid", value: uuid),
            URLQueryItem(name: "keyId", value: attested.keyID),
            URLQueryItem(name: "assertion", value: attested.assertion),
            URLQueryItem(name: "challenge", value: attested.challenge),
        ]
        guard let url = components.url else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 12
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["token": deviceToken])
        _ = try? await URLSession.shared.data(for: request)
    }

    private var currentAppVersion: String {
        let marketing = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
        return "\(marketing)-\(build)"
    }

    private var apnsEnvironment: String {
        #if DEBUG
        "sandbox"
        #else
        "production"
        #endif
    }
}
