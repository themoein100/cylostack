//
//  RemoteConfigManager.swift
//  CircleStack
//
//  Created by Moein on 29/07/2026.
//

import Foundation
import UIKit
import Combine

class RemoteConfigManager: ObservableObject {
    static let shared = RemoteConfigManager()

    // Remote Control Keys
    @Published var areAdsEnabled: Bool = true
    @Published var isAppOpenAdEnabled: Bool = true
    @Published var isInterstitialAdEnabled: Bool = true
    @Published var isRewardedAdEnabled: Bool = true

    // Remote Update Keys
    @Published var latestVersion: String = "1.0.0"
    @Published var appStoreURL: String = ""
    @Published var privacyURL: String = ""
    @Published var isUpdateRequired: Bool = false
    /// When true, the update prompt ignores the snooze timer and cannot be dismissed
    @Published var isForceUpdateEnabled: Bool = false

    // Remote Config Endpoint URL (Live Cloudflare Worker)
    var remoteConfigURL: String {
        get {
            UserDefaults.standard.string(forKey: "remote_config_endpoint_url") ?? "https://patient-tooth-4146.2002-sadraei.workers.dev"
        }
        set {
            UserDefaults.standard.set(newValue, forKey: "remote_config_endpoint_url")
        }
    }

    private var pollTimer: Timer?

    private init() {
        // Load cached settings instantly from local storage (0ms startup latency)
        loadCachedConfig()
        // Start live auto-polling & foreground refresh for sub-second updates!
        setupAutoRefresh()
    }

    /// How often the config is re-fetched while the app is in the foreground.
    ///
    /// This used to be 10 seconds, which cost every player a request every 10s for as
    /// long as they had the app open — real battery and data for a config that changes
    /// a few times a month. The foreground refresh below is what actually makes a
    /// panel change land immediately, so the timer only needs to be a slow backstop.
    private let pollInterval: TimeInterval = 120.0

    /// Listens for app foreground transitions and polls periodically for live updates
    private func setupAutoRefresh() {
        // Fetch instantly whenever app comes back from background (e.g. after using Telegram)
        NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.fetchRemoteConfig()
        }

        // Stop polling in the background — the timer would otherwise keep firing during
        // the brief window before suspension and again on every resume.
        NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.pollTimer?.invalidate()
            self?.pollTimer = nil
        }

        NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.startPolling()
        }

        startPolling()
    }

    private func startPolling() {
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in
            self?.fetchRemoteConfig()
        }
    }

    /// Loads locally cached settings so app never waits for network at launch
    private func loadCachedConfig() {
        if UserDefaults.standard.object(forKey: "remote_ads_enabled") != nil {
            self.areAdsEnabled = UserDefaults.standard.bool(forKey: "remote_ads_enabled")
        }
        if UserDefaults.standard.object(forKey: "remote_app_open_enabled") != nil {
            self.isAppOpenAdEnabled = UserDefaults.standard.bool(forKey: "remote_app_open_enabled")
        }
        if UserDefaults.standard.object(forKey: "remote_interstitial_enabled") != nil {
            self.isInterstitialAdEnabled = UserDefaults.standard.bool(forKey: "remote_interstitial_enabled")
        }
        if UserDefaults.standard.object(forKey: "remote_rewarded_enabled") != nil {
            self.isRewardedAdEnabled = UserDefaults.standard.bool(forKey: "remote_rewarded_enabled")
        }
        if UserDefaults.standard.object(forKey: "remote_force_update") != nil {
            self.isForceUpdateEnabled = UserDefaults.standard.bool(forKey: "remote_force_update")
        }
        if let cachedVersion = UserDefaults.standard.string(forKey: "remote_latest_version") {
            self.latestVersion = cachedVersion
        }
        if let cachedAppStore = UserDefaults.standard.string(forKey: "remote_appstore_url") {
            self.appStoreURL = cachedAppStore
        }
        if let cachedPrivacy = UserDefaults.standard.string(forKey: "remote_privacy_url") {
            self.privacyURL = cachedPrivacy
        }
        evaluateUpdateRequirement()
    }

    /// Asynchronously fetches remote settings & registers install / daily active user metrics
    func fetchRemoteConfig(completion: (() -> Void)? = nil) {
        let isFirstInstall = !UserDefaults.standard.bool(forKey: "has_registered_install")
        if isFirstInstall {
            UserDefaults.standard.set(true, forKey: "has_registered_install")
        }

        var deviceUUID = UserDefaults.standard.string(forKey: "device_analytics_uuid")
        if deviceUUID == nil {
            deviceUUID = UUID().uuidString
            UserDefaults.standard.set(deviceUUID, forKey: "device_analytics_uuid")
        }

        let eventType = isFirstInstall ? "install" : "active"

        guard var components = URLComponents(string: remoteConfigURL) else {
            Logger.shared.e("RemoteConfig", "Invalid endpoint URL")
            completion?()
            return
        }
        components.queryItems = RemoteConfigCrypto.signedQueryItems(
            event: eventType,
            uuid: deviceUUID ?? ""
        )

        guard let url = components.url else {
            Logger.shared.e("RemoteConfig", "Could not build signed request URL")
            completion?()
            return
        }

        Logger.shared.i("RemoteConfig", "Fetching remote config (\(eventType))…")

        var request = URLRequest(url: url)
        request.timeoutInterval = 4.0
        request.cachePolicy = .reloadIgnoringLocalCacheData

        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            DispatchQueue.main.async {
                guard let self = self else { return }

                if let error = error {
                    Logger.shared.e("RemoteConfig", "Network error fetching remote config: \(error.localizedDescription)")
                    completion?()
                    return
                }

                if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                    Logger.shared.e("RemoteConfig", "Endpoint rejected the request (HTTP \(http.statusCode))")
                    completion?()
                    return
                }

                guard let body = data, !body.isEmpty else {
                    Logger.shared.e("RemoteConfig", "Empty response from remote config endpoint")
                    completion?()
                    return
                }

                // The worker replies with an AES-GCM envelope. A body that will not
                // decrypt is either tampered with or not from our worker, so the
                // cached config is kept rather than trusting it.
                guard let data = RemoteConfigCrypto.decrypt(body) else {
                    Logger.shared.e("RemoteConfig", "Could not decrypt config response — keeping cached values")
                    completion?()
                    return
                }

                do {
                    if let json = try JSONSerialization.jsonObject(with: data, options: []) as? [String: Any] {
                        let adsEnabled: Bool
                        if let boolVal = json["ads_enabled"] as? Bool {
                            adsEnabled = boolVal
                        } else if let numVal = json["ads_enabled"] as? NSNumber {
                            adsEnabled = numVal.boolValue
                        } else {
                            adsEnabled = true
                        }

                        let appOpenEnabled: Bool
                        if let boolVal = json["app_open_ads_enabled"] as? Bool {
                            appOpenEnabled = boolVal
                        } else if let numVal = json["app_open_ads_enabled"] as? NSNumber {
                            appOpenEnabled = numVal.boolValue
                        } else {
                            appOpenEnabled = adsEnabled
                        }

                        let interstitialEnabled: Bool
                        if let boolVal = json["interstitial_ads_enabled"] as? Bool {
                            interstitialEnabled = boolVal
                        } else if let numVal = json["interstitial_ads_enabled"] as? NSNumber {
                            interstitialEnabled = numVal.boolValue
                        } else {
                            interstitialEnabled = adsEnabled
                        }

                        let rewardedEnabled: Bool
                        if let boolVal = json["rewarded_ads_enabled"] as? Bool {
                            rewardedEnabled = boolVal
                        } else if let numVal = json["rewarded_ads_enabled"] as? NSNumber {
                            rewardedEnabled = numVal.boolValue
                        } else {
                            rewardedEnabled = adsEnabled
                        }

                        let forceUpdate: Bool
                        if let boolVal = json["force_update"] as? Bool {
                            forceUpdate = boolVal
                        } else if let numVal = json["force_update"] as? NSNumber {
                            forceUpdate = numVal.boolValue
                        } else {
                            forceUpdate = false
                        }

                        let version = json["latest_version"] as? String ?? self.latestVersion
                        let appstore = json["appstore_url"] as? String ?? self.appStoreURL
                        let privacy = json["privacy_url"] as? String ?? self.privacyURL

                        self.areAdsEnabled = adsEnabled
                        self.isAppOpenAdEnabled = appOpenEnabled
                        self.isInterstitialAdEnabled = interstitialEnabled
                        self.isRewardedAdEnabled = rewardedEnabled
                        self.isForceUpdateEnabled = forceUpdate
                        self.latestVersion = version
                        self.appStoreURL = appstore
                        self.privacyURL = privacy

                        // Cache in UserDefaults for instant offline startup
                        UserDefaults.standard.set(adsEnabled, forKey: "remote_ads_enabled")
                        UserDefaults.standard.set(appOpenEnabled, forKey: "remote_app_open_enabled")
                        UserDefaults.standard.set(interstitialEnabled, forKey: "remote_interstitial_enabled")
                        UserDefaults.standard.set(rewardedEnabled, forKey: "remote_rewarded_enabled")
                        UserDefaults.standard.set(forceUpdate, forKey: "remote_force_update")
                        UserDefaults.standard.set(version, forKey: "remote_latest_version")
                        UserDefaults.standard.set(appstore, forKey: "remote_appstore_url")
                        UserDefaults.standard.set(privacy, forKey: "remote_privacy_url")

                        self.evaluateUpdateRequirement()

                        Logger.shared.i("RemoteConfig", "Parsed Remote Config SUCCESS -> ads_enabled: \(adsEnabled), version: \(version), appstore: \(appstore)")
                    }
                } catch {
                    Logger.shared.e("RemoteConfig", "JSON parsing failed: \(error.localizedDescription)")
                }

                completion?()
            }
        }.resume()
    }

    /// Evaluates if an update prompt should be presented to the user
    func evaluateUpdateRequirement() {
        let currentVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
        let isVersionNewer = isVersion(latestVersion, greaterThan: currentVersion)

        if !isVersionNewer {
            self.isUpdateRequired = false
            return
        }

        // Force update bypasses the snooze timer entirely
        if isForceUpdateEnabled {
            self.isUpdateRequired = true
            return
        }

        // Check snooze timestamp
        if let snoozeUntil = UserDefaults.standard.object(forKey: "update_snooze_until") as? Date {
            if Date() < snoozeUntil {
                self.isUpdateRequired = false
                return
            }
        }

        self.isUpdateRequired = true
    }

    /// Snoozes the update prompt for the specified number of days (e.g. 3 days for Later, 2 days for Cancel)
    func snoozeUpdate(days: Int) {
        let snoozeUntil = Date().addingTimeInterval(TimeInterval(days * 86400))
        UserDefaults.standard.set(snoozeUntil, forKey: "update_snooze_until")
        self.isUpdateRequired = false
    }

    /// Compares two dotted version strings component by component.
    ///
    /// A plain `.numeric` string compare gets this wrong whenever the two sides have a
    /// different number of components: it reads "1.0.0" as greater than "1.0" and
    /// prompts every user of 1.0 to update to the build they are already running.
    /// Missing trailing components count as zero, so 1.0 == 1.0.0.
    private func isVersion(_ v1: String, greaterThan v2: String) -> Bool {
        let lhs = v1.split(separator: ".").map { Int($0) ?? 0 }
        let rhs = v2.split(separator: ".").map { Int($0) ?? 0 }

        for index in 0..<max(lhs.count, rhs.count) {
            let left = index < lhs.count ? lhs[index] : 0
            let right = index < rhs.count ? rhs[index] : 0
            if left != right { return left > right }
        }
        return false
    }
}
