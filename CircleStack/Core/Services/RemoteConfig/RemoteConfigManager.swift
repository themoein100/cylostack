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
    @Published var isRewardedAdEnabled: Bool = true

    // Remote Update Keys
    @Published var latestVersion: String = "1.0.0"
    @Published var appStoreURL: String = ""
    @Published var privacyURL: String = ""
    @Published var isUpdateRequired: Bool = false

    // Remote Config Endpoint URL (Live Cloudflare Worker)
    var remoteConfigURL: String {
        get {
            UserDefaults.standard.string(forKey: "remote_config_endpoint_url") ?? "https://patient-tooth-4146.m-sadraei2002.workers.dev"
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

    /// Listens for app foreground transitions & polls every 10 seconds for real-time live updates
    private func setupAutoRefresh() {
        // Fetch instantly whenever app comes back from background (e.g. after using Telegram)
        NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.fetchRemoteConfig()
        }

        // Live polling every 10 seconds while app is active
        pollTimer = Timer.scheduledTimer(withTimeInterval: 10.0, repeats: true) { [weak self] _ in
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
        if UserDefaults.standard.object(forKey: "remote_rewarded_enabled") != nil {
            self.isRewardedAdEnabled = UserDefaults.standard.bool(forKey: "remote_rewarded_enabled")
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
        let fullURLString = "\(remoteConfigURL)?event=\(eventType)&uuid=\(deviceUUID ?? "")"

        guard let url = URL(string: fullURLString) else {
            Logger.shared.e("RemoteConfig", "Invalid URL: \(remoteConfigURL)")
            completion?()
            return
        }

        Logger.shared.i("RemoteConfig", "Fetching remote config (\(eventType)) from: \(fullURLString)...")

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

                guard let data = data, let rawJSONString = String(data: data, encoding: .utf8) else {
                    Logger.shared.e("RemoteConfig", "No data or empty string received from remote config endpoint")
                    completion?()
                    return
                }

                Logger.shared.i("RemoteConfig", "Raw response from Cloudflare: \(rawJSONString)")

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

                        let rewardedEnabled: Bool
                        if let boolVal = json["rewarded_ads_enabled"] as? Bool {
                            rewardedEnabled = boolVal
                        } else if let numVal = json["rewarded_ads_enabled"] as? NSNumber {
                            rewardedEnabled = numVal.boolValue
                        } else {
                            rewardedEnabled = adsEnabled
                        }

                        let version = json["latest_version"] as? String ?? self.latestVersion
                        let appstore = json["appstore_url"] as? String ?? self.appStoreURL
                        let privacy = json["privacy_url"] as? String ?? self.privacyURL

                        self.areAdsEnabled = adsEnabled
                        self.isAppOpenAdEnabled = appOpenEnabled
                        self.isRewardedAdEnabled = rewardedEnabled
                        self.latestVersion = version
                        self.appStoreURL = appstore
                        self.privacyURL = privacy

                        // Cache in UserDefaults for instant offline startup
                        UserDefaults.standard.set(adsEnabled, forKey: "remote_ads_enabled")
                        UserDefaults.standard.set(appOpenEnabled, forKey: "remote_app_open_enabled")
                        UserDefaults.standard.set(rewardedEnabled, forKey: "remote_rewarded_enabled")
                        UserDefaults.standard.set(version, forKey: "remote_latest_version")
                        UserDefaults.standard.set(appstore, forKey: "remote_appstore_url")
                        UserDefaults.standard.set(privacy, forKey: "remote_privacy_url")

                        self.evaluateUpdateRequirement()

                        Logger.shared.i("RemoteConfig", "Parsed Remote Config SUCCESS -> ads_enabled: \(adsEnabled), version: \(version), appstore: \(appstore)")
                    }
                } catch {
                    Logger.shared.e("RemoteConfig", "JSON parsing failed: \(error.localizedDescription). Raw data: \(rawJSONString)")
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

    private func isVersion(_ v1: String, greaterThan v2: String) -> Bool {
        return v1.compare(v2, options: .numeric) == .orderedDescending
    }
}
