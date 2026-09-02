//
//  AdMobManager.swift
//  CircleStack
//
//  Created by Moein on 29/07/2026.
//

import Foundation
import UIKit
import Combine
import GoogleMobileAds
import UserMessagingPlatform
import AppTrackingTransparency

class AdMobManager: NSObject, FullScreenContentDelegate, ObservableObject {
    static let shared = AdMobManager()

    // Debug builds use Google's demo units so development traffic never reaches
    // the live account; Release (TestFlight and App Store) uses the real ones.
    #if DEBUG
    private let interstitialAdUnitID = "ca-app-pub-3940256099942544/4411468910"
    private let rewardedAdUnitID = "ca-app-pub-3940256099942544/1712485313"
    private let appOpenAdUnitID = "ca-app-pub-3940256099942544/5575463023"
    #else
    private let interstitialAdUnitID = "ca-app-pub-8353688568048184/4508138481"
    private let rewardedAdUnitID = "ca-app-pub-8353688568048184/2410136917"
    private let appOpenAdUnitID = "ca-app-pub-8353688568048184/8255811806"
    #endif

    // Interstitial Ad State
    @Published var isAdReady: Bool = false
    @Published var isAdAvailable: Bool = false
    @Published var isAdButtonVisible: Bool = false
    @Published var isLoadingAd: Bool = false

    // Rewarded Ad State
    @Published var isRewardedAdReady: Bool = false
    @Published var isRewardedAdAvailable: Bool = false
    @Published var isRewardedAdButtonVisible: Bool = false
    @Published var isLoadingRewardedAd: Bool = false

    // App Open Ad State
    @Published var isAppOpenAdReady: Bool = false
    @Published var isAppOpenAdAvailable: Bool = false
    @Published var isLoadingAppOpenAd: Bool = false

    private var interstitialAd: InterstitialAd?
    private var rewardedAd: RewardedAd?
    private var appOpenAd: AppOpenAd?

    private var onAdDismissed: (() -> Void)?
    private var onRewardedAdDismissed: (() -> Void)?
    private var onAppOpenAdDismissed: (() -> Void)?

    private var cancellables = Set<AnyCancellable>()
    private var hasStartedSDK = false

    /// True where the law (GDPR) says the player must be able to reopen their
    /// consent choices at any time. Drives the Privacy Options row in Settings,
    /// which stays hidden everywhere else.
    @Published var isPrivacyOptionsRequired: Bool = false

    /// Waits for a `@Published` readiness flag to flip true, or gives up after
    /// `timeout`. Whichever happens first, the timer is invalidated and the
    /// subscription is torn down — the earlier version stored every wait in
    /// `cancellables` and never removed it, so the set grew for the whole session.
    private func awaitReady(
        _ publisher: Published<Bool>.Publisher,
        isAlreadyReady: @autoclosure () -> Bool,
        startLoading: () -> Void,
        timeout: TimeInterval,
        label: String,
        completion: @escaping (Bool) -> Void
    ) {
        guard NetworkMonitor.shared.isConnected else {
            completion(false)
            return
        }

        if isAlreadyReady() {
            completion(true)
            return
        }

        startLoading()

        var hasFinished = false
        var subscription: AnyCancellable?
        var timer: Timer?

        // Runs exactly once, from whichever path gets there first.
        let finish: (Bool) -> Void = { [weak self] ready in
            guard !hasFinished else { return }
            hasFinished = true
            timer?.invalidate()
            if let subscription = subscription {
                self?.cancellables.remove(subscription)
                subscription.cancel()
            }
            completion(ready)
        }

        subscription = publisher
            .dropFirst()
            .filter { $0 }
            .first()
            .receive(on: DispatchQueue.main)
            .sink { _ in
                Logger.shared.i("AdMobManager", "\(label) loaded during wait window")
                finish(true)
            }

        if let subscription = subscription {
            cancellables.insert(subscription)
        }

        timer = Timer.scheduledTimer(withTimeInterval: timeout, repeats: false) { _ in
            Logger.shared.i("AdMobManager", "\(label) wait timed out after \(timeout)s")
            finish(false)
        }
    }

    override init() {
        super.init()

        // Each ad format is gated by the global switch AND its own remote flag,
        // so the Telegram panel can turn a single format off independently.
        let interstitialRemote = Publishers.CombineLatest(
            RemoteConfigManager.shared.$areAdsEnabled,
            RemoteConfigManager.shared.$isInterstitialAdEnabled
        ).map { global, specific in global && specific }

        let rewardedRemote = Publishers.CombineLatest(
            RemoteConfigManager.shared.$areAdsEnabled,
            RemoteConfigManager.shared.$isRewardedAdEnabled
        ).map { global, specific in global && specific }

        let appOpenRemote = Publishers.CombineLatest(
            RemoteConfigManager.shared.$areAdsEnabled,
            RemoteConfigManager.shared.$isAppOpenAdEnabled
        ).map { global, specific in global && specific }

        // Listen to Network changes & Remote Config & update availability reactively
        Publishers.CombineLatest3($isAdReady, NetworkMonitor.shared.$isConnected, interstitialRemote)
            .map { ready, connected, remoteEnabled in ready && connected && remoteEnabled }
            .receive(on: DispatchQueue.main)
            .assign(to: &$isAdAvailable)

        Publishers.CombineLatest3($isRewardedAdReady, NetworkMonitor.shared.$isConnected, rewardedRemote)
            .map { ready, connected, remoteEnabled in ready && connected && remoteEnabled }
            .receive(on: DispatchQueue.main)
            .assign(to: &$isRewardedAdAvailable)

        Publishers.CombineLatest3($isAppOpenAdReady, NetworkMonitor.shared.$isConnected, appOpenRemote)
            .map { ready, connected, remoteEnabled in ready && connected && remoteEnabled }
            .receive(on: DispatchQueue.main)
            .assign(to: &$isAppOpenAdAvailable)

        // دکمه تبلیغ: فقط نیاز به اینترنت + ریموت دارد (نیازی به لود بودن تبلیغ نیست)
        Publishers.CombineLatest(NetworkMonitor.shared.$isConnected, interstitialRemote)
            .map { connected, remoteEnabled in connected && remoteEnabled }
            .receive(on: DispatchQueue.main)
            .assign(to: &$isAdButtonVisible)

        Publishers.CombineLatest(NetworkMonitor.shared.$isConnected, rewardedRemote)
            .map { connected, remoteEnabled in connected && remoteEnabled }
            .receive(on: DispatchQueue.main)
            .assign(to: &$isRewardedAdButtonVisible)

        // Auto-retry ad loading when network re-connects
        NetworkMonitor.shared.$isConnected
            .dropFirst()
            .filter { $0 == true }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                if self?.isAdReady == false && self?.isLoadingAd == false {
                    self?.loadInterstitialAd()
                }
                if self?.isRewardedAdReady == false && self?.isLoadingRewardedAd == false {
                    self?.loadRewardedAd()
                }
                if self?.isAppOpenAdReady == false && self?.isLoadingAppOpenAd == false {
                    self?.loadAppOpenAd()
                }
            }
            .store(in: &cancellables)
    }

    /// Starts the Mobile Ads SDK — but only once, and only after the consent
    /// state says we may request ads. Calling it again is a no-op, so every
    /// path out of the consent flow can call it without double-starting.
    func initialize() {
        guard !hasStartedSDK else { return }

        guard ConsentInformation.shared.canRequestAds else {
            Logger.shared.i("AdMobManager", "Consent does not allow ad requests yet. SDK start deferred.")
            return
        }

        hasStartedSDK = true
        MobileAds.shared.audioVideoManager.isAudioSessionApplicationManaged = true
        MobileAds.shared.start(completionHandler: { [weak self] status in
            Logger.shared.i("AdMobManager", "AdMob SDK Initialized")
            DispatchQueue.main.async {
                self?.loadAppOpenAd()
                self?.loadInterstitialAd()
                self?.loadRewardedAd()
            }
        })
    }

    // MARK: - GDPR Consent (User Messaging Platform)

    func requestGDPRConsentIfNeeded(from rootViewController: UIViewController? = nil, completion: @escaping () -> Void) {
        let parameters = RequestParameters()

        #if DEBUG
        // Flip to true on a Debug build to be treated as an EEA user, so the
        // consent form and the Privacy Options row can be exercised from here.
        // Debug-only by construction — Release never sees this branch.
        let simulateEEAGeography = false
        if simulateEEAGeography {
            let debugSettings = DebugSettings()
            debugSettings.geography = .EEA
            parameters.debugSettings = debugSettings
        }
        #endif

        ConsentInformation.shared.requestConsentInfoUpdate(with: parameters) { [weak self] error in
            DispatchQueue.main.async {
                if let error = error {
                    // Do not show ATT if UMP did not finish. Otherwise a transient
                    // network error could put Apple's tracking prompt before the
                    // GDPR flow, which is the wrong order and confusing for players.
                    // The next Splash appearance retries the UMP request first.
                    Logger.shared.e("AdMobManager", "GDPR consent info update failed: \(error.localizedDescription)")
                    self?.refreshPrivacyOptionsRequirement()
                    self?.initialize()
                    completion()
                    return
                }

                let vc = rootViewController ?? self?.getTopViewController()
                ConsentForm.loadAndPresentIfRequired(from: vc) { dismissError in
                    DispatchQueue.main.async {
                        if let dismissError = dismissError {
                            Logger.shared.e("AdMobManager", "GDPR consent form presentation failed: \(dismissError.localizedDescription)")
                        } else {
                            Logger.shared.i("AdMobManager", "GDPR consent form handled successfully.")
                        }

                        self?.refreshPrivacyOptionsRequirement()

                        // Apple requires the ATT prompt to come after the UMP
                        // form, never before it.
                        self?.requestTrackingAuthorizationIfNeeded {
                            self?.initialize()
                            completion()
                        }
                    }
                }
            }
        }
    }

    private func refreshPrivacyOptionsRequirement() {
        isPrivacyOptionsRequired = ConsentInformation.shared.privacyOptionsRequirementStatus == .required
    }

    /// Reopens the consent form so the player can change or withdraw what they
    /// agreed to. Consent may go from granted to denied here, so the ad state is
    /// re-read afterwards rather than assumed.
    func presentPrivacyOptionsForm(from rootViewController: UIViewController? = nil, completion: (() -> Void)? = nil) {
        let vc = rootViewController ?? getTopViewController()
        ConsentForm.presentPrivacyOptionsForm(from: vc) { [weak self] error in
            DispatchQueue.main.async {
                if let error = error {
                    Logger.shared.e("AdMobManager", "Privacy options form failed: \(error.localizedDescription)")
                } else {
                    Logger.shared.i("AdMobManager", "Privacy options form dismissed.")
                }

                self?.refreshPrivacyOptionsRequirement()

                // If consent was only just granted, the SDK may still be waiting
                // to start; initialize() is a no-op when it already has.
                self?.initialize()
                completion?()
            }
        }
    }

    /// Shows Apple's App Tracking Transparency prompt once, if the user has not
    /// answered it yet. Either answer is fine — the game plays the same, and
    /// AdMob falls back to non-personalized ads when tracking is denied.
    private func requestTrackingAuthorizationIfNeeded(completion: @escaping () -> Void) {
        guard ATTrackingManager.trackingAuthorizationStatus == .notDetermined else {
            completion()
            return
        }

        // The system silently drops the prompt unless the app is foreground-active.
        guard UIApplication.shared.applicationState == .active else {
            completion()
            return
        }

        ATTrackingManager.requestTrackingAuthorization { status in
            DispatchQueue.main.async {
                Logger.shared.i("AdMobManager", "ATT authorization status: \(status.rawValue)")
                completion()
            }
        }
    }

    // MARK: - Interstitial Ad

    func loadInterstitialAd() {
        guard hasStartedSDK else {
            Logger.shared.i("AdMobManager", "Interstitial request deferred until consent completes.")
            return
        }

        guard NetworkMonitor.shared.isConnected else {
            Logger.shared.i("AdMobManager", "Device offline. Skipping interstitial ad load request.")
            isAdReady = false
            return
        }

        guard !isLoadingAd else { return }
        isLoadingAd = true

        let request = Request()
        InterstitialAd.load(with: interstitialAdUnitID, request: request) { [weak self] ad, error in
            DispatchQueue.main.async {
                self?.isLoadingAd = false
                if let error = error {
                    Logger.shared.e("AdMobManager", "Failed to load interstitial ad: \(error.localizedDescription)")
                    self?.isAdReady = false
                    return
                }

                Logger.shared.i("AdMobManager", "Interstitial ad loaded successfully")
                self?.interstitialAd = ad
                self?.interstitialAd?.fullScreenContentDelegate = self
                self?.isAdReady = true
            }
        }
    }

    func showInterstitial(from rootViewController: UIViewController? = nil, onDismissed: @escaping () -> Void) {
        guard RemoteConfigManager.shared.areAdsEnabled,
              RemoteConfigManager.shared.isInterstitialAdEnabled else {
            Logger.shared.i("AdMobManager", "Interstitial disabled by remote config. Proceeding instantly.")
            onDismissed()
            return
        }

        guard NetworkMonitor.shared.isConnected, let ad = interstitialAd else {
            Logger.shared.i("AdMobManager", "Interstitial ad unavailable or device offline. Proceeding instantly.")
            onDismissed()
            if NetworkMonitor.shared.isConnected {
                loadInterstitialAd()
            }
            return
        }

        var hasHandledCompletion = false
        let completionGate = {
            guard !hasHandledCompletion else { return }
            hasHandledCompletion = true
            onDismissed()
        }

        // A pending callback from an earlier presentation would be silently dropped
        // here, leaving its caller waiting forever. Settle it first.
        onAdDismissed?()
        self.onAdDismissed = completionGate

        let vc = rootViewController ?? getTopViewController()
        if let topVC = vc {
            ad.present(from: topVC)
        } else {
            Logger.shared.e("AdMobManager", "Could not find root view controller to present ad")
            completionGate()
        }
    }

    // MARK: - Rewarded Ad

    func loadRewardedAd() {
        guard hasStartedSDK else {
            Logger.shared.i("AdMobManager", "Rewarded request deferred until consent completes.")
            return
        }

        guard NetworkMonitor.shared.isConnected else {
            Logger.shared.i("AdMobManager", "Device offline. Skipping rewarded ad load request.")
            isRewardedAdReady = false
            return
        }

        guard !isLoadingRewardedAd else { return }
        isLoadingRewardedAd = true

        let request = Request()
        RewardedAd.load(with: rewardedAdUnitID, request: request) { [weak self] ad, error in
            DispatchQueue.main.async {
                self?.isLoadingRewardedAd = false
                if let error = error {
                    Logger.shared.e("AdMobManager", "Failed to load rewarded ad: \(error.localizedDescription)")
                    self?.isRewardedAdReady = false
                    return
                }

                Logger.shared.i("AdMobManager", "Rewarded ad loaded successfully")
                self?.rewardedAd = ad
                self?.rewardedAd?.fullScreenContentDelegate = self
                self?.isRewardedAdReady = true
            }
        }
    }

    func showRewardedAd(from rootViewController: UIViewController? = nil, onRewardEarned: @escaping (Bool) -> Void) {
        guard RemoteConfigManager.shared.areAdsEnabled,
              RemoteConfigManager.shared.isRewardedAdEnabled else {
            Logger.shared.i("AdMobManager", "Rewarded ad disabled by remote config.")
            DispatchQueue.main.async { onRewardEarned(false) }
            return
        }

        guard NetworkMonitor.shared.isConnected, let ad = rewardedAd else {
            Logger.shared.i("AdMobManager", "Rewarded ad unavailable or device offline.")
            DispatchQueue.main.async {
                onRewardEarned(false)
            }
            if NetworkMonitor.shared.isConnected {
                loadRewardedAd()
            }
            return
        }

        var didEarnReward = false

        let vc = rootViewController ?? getTopViewController()
        if let topVC = vc {
            // Settle any pending callback so its caller is never left hanging.
            onRewardedAdDismissed?()
            self.onRewardedAdDismissed = { [weak self] in
                DispatchQueue.main.async {
                    onRewardEarned(didEarnReward)
                    self?.loadRewardedAd()
                }
            }
            ad.present(from: topVC) {
                didEarnReward = true
                Logger.shared.i("AdMobManager", "Rewarded ad user completed watching reward!")
            }
        } else {
            DispatchQueue.main.async {
                onRewardEarned(false)
            }
        }
    }

    func waitForRewardedAdOrTimeout(maxWaitDuration: TimeInterval = 6.0, completion: @escaping (Bool) -> Void) {
        awaitReady($isRewardedAdReady,
                   isAlreadyReady: isRewardedAdReady,
                   startLoading: { if !isLoadingRewardedAd { loadRewardedAd() } },
                   timeout: maxWaitDuration,
                   label: "Rewarded ad",
                   completion: completion)
    }

    // MARK: - App Open Ad

    func loadAppOpenAd() {
        guard hasStartedSDK else {
            Logger.shared.i("AdMobManager", "App-open request deferred until consent completes.")
            return
        }

        guard NetworkMonitor.shared.isConnected else {
            Logger.shared.i("AdMobManager", "Device offline. Skipping app open ad load request.")
            isAppOpenAdReady = false
            return
        }

        guard !isLoadingAppOpenAd else { return }
        isLoadingAppOpenAd = true

        let request = Request()
        AppOpenAd.load(with: appOpenAdUnitID, request: request) { [weak self] ad, error in
            DispatchQueue.main.async {
                self?.isLoadingAppOpenAd = false
                if let error = error {
                    Logger.shared.e("AdMobManager", "Failed to load app open ad: \(error.localizedDescription)")
                    self?.isAppOpenAdReady = false
                    return
                }

                Logger.shared.i("AdMobManager", "App open ad loaded successfully")
                self?.appOpenAd = ad
                self?.appOpenAd?.fullScreenContentDelegate = self
                self?.isAppOpenAdReady = true
            }
        }
    }

    func showAppOpenAd(from rootViewController: UIViewController? = nil, onDismissed: @escaping () -> Void) {
        guard RemoteConfigManager.shared.areAdsEnabled,
              RemoteConfigManager.shared.isAppOpenAdEnabled else {
            Logger.shared.i("AdMobManager", "App open ad disabled by remote config. Proceeding instantly.")
            onDismissed()
            return
        }

        guard NetworkMonitor.shared.isConnected, let ad = appOpenAd else {
            Logger.shared.i("AdMobManager", "App open ad unavailable or device offline. Proceeding instantly.")
            onDismissed()
            if NetworkMonitor.shared.isConnected {
                loadAppOpenAd()
            }
            return
        }

        var hasHandledCompletion = false
        let completionGate = {
            guard !hasHandledCompletion else { return }
            hasHandledCompletion = true
            onDismissed()
        }

        onAppOpenAdDismissed?()
        self.onAppOpenAdDismissed = completionGate

        let vc = rootViewController ?? getTopViewController()
        if let topVC = vc {
            ad.present(from: topVC)
        } else {
            Logger.shared.e("AdMobManager", "Could not find root view controller for app open ad")
            completionGate()
        }
    }

    func waitForAppOpenAdOrTimeout(maxWaitDuration: TimeInterval = 4.0, completion: @escaping (Bool) -> Void) {
        awaitReady($isAppOpenAdReady,
                   isAlreadyReady: isAppOpenAdReady,
                   startLoading: { if !isLoadingAppOpenAd { loadAppOpenAd() } },
                   timeout: maxWaitDuration,
                   label: "App open ad",
                   completion: completion)
    }

    // MARK: - Adaptive Waiting (Interstitial)

    func waitForAdOrTimeout(maxWaitDuration: TimeInterval = 4.0, completion: @escaping (Bool) -> Void) {
        awaitReady($isAdReady,
                   isAlreadyReady: isAdReady,
                   startLoading: { if !isLoadingAd { loadInterstitialAd() } },
                   timeout: maxWaitDuration,
                   label: "Interstitial ad",
                   completion: completion)
    }

    // MARK: - FullScreenContentDelegate

    func adDidDismissFullScreenContent(_ ad: FullScreenPresentingAd) {
        Logger.shared.i("AdMobManager", "Ad did dismiss full screen content")

        if ad is InterstitialAd {
            interstitialAd = nil
            isAdReady = false
            loadInterstitialAd()

            let callback = onAdDismissed
            onAdDismissed = nil
            callback?()
        } else if ad is AppOpenAd {
            appOpenAd = nil
            isAppOpenAdReady = false
            loadAppOpenAd()

            let callback = onAppOpenAdDismissed
            onAppOpenAdDismissed = nil
            callback?()
        } else if ad is RewardedAd {
            rewardedAd = nil
            isRewardedAdReady = false
            loadRewardedAd()

            let callback = onRewardedAdDismissed
            onRewardedAdDismissed = nil
            callback?()
        }
    }

    func ad(_ ad: FullScreenPresentingAd, didFailToPresentFullScreenContentWithError error: Error) {
        Logger.shared.e("AdMobManager", "Ad failed to present: \(error.localizedDescription)")

        if ad is InterstitialAd {
            interstitialAd = nil
            isAdReady = false
            loadInterstitialAd()

            let callback = onAdDismissed
            onAdDismissed = nil
            callback?()
        } else if ad is AppOpenAd {
            appOpenAd = nil
            isAppOpenAdReady = false
            loadAppOpenAd()

            let callback = onAppOpenAdDismissed
            onAppOpenAdDismissed = nil
            callback?()
        } else if ad is RewardedAd {
            rewardedAd = nil
            isRewardedAdReady = false
            loadRewardedAd()

            let callback = onRewardedAdDismissed
            onRewardedAdDismissed = nil
            callback?()
        }
    }

    private func getTopViewController() -> UIViewController? {
        // `UIApplication.shared.windows` is deprecated and picks arbitrarily across
        // scenes. Walk the connected scenes instead, preferring the active one.
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first

        guard let rootVC = scene?.windows.first(where: { $0.isKeyWindow })?.rootViewController
                ?? scene?.windows.first?.rootViewController else {
            Logger.shared.e("AdMobManager", "No window scene available to present from")
            return nil
        }

        var topVC = rootVC
        while let presentedVC = topVC.presentedViewController, !presentedVC.isBeingDismissed {
            topVC = presentedVC
        }
        return topVC
    }
}
