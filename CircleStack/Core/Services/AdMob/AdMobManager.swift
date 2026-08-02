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

class AdMobManager: NSObject, FullScreenContentDelegate, ObservableObject {
    static let shared = AdMobManager()

    // Google AdMob Interstitial, Rewarded & App Open Test Unit IDs
    #if DEBUG
    private let interstitialAdUnitID = "ca-app-pub-3940256099942544/4411468910"
    private let rewardedAdUnitID = "ca-app-pub-3940256099942544/1712485313"
    private let appOpenAdUnitID = "ca-app-pub-3940256099942544/5575463023"
    #else
    private let interstitialAdUnitID = "ca-app-pub-3940256099942544/4411468910"
    private let rewardedAdUnitID = "ca-app-pub-3940256099942544/1712485313"
    private let appOpenAdUnitID = "ca-app-pub-3940256099942544/5575463023"
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

    override init() {
        super.init()

        // Listen to Network changes & Remote Config & update availability reactively
        Publishers.CombineLatest3($isAdReady, NetworkMonitor.shared.$isConnected, RemoteConfigManager.shared.$areAdsEnabled)
            .map { ready, connected, remoteEnabled in ready && connected && remoteEnabled }
            .receive(on: DispatchQueue.main)
            .assign(to: &$isAdAvailable)

        Publishers.CombineLatest3($isRewardedAdReady, NetworkMonitor.shared.$isConnected, RemoteConfigManager.shared.$areAdsEnabled)
            .map { ready, connected, remoteEnabled in ready && connected && remoteEnabled }
            .receive(on: DispatchQueue.main)
            .assign(to: &$isRewardedAdAvailable)

        Publishers.CombineLatest3($isAppOpenAdReady, NetworkMonitor.shared.$isConnected, RemoteConfigManager.shared.$areAdsEnabled)
            .map { ready, connected, remoteEnabled in ready && connected && remoteEnabled }
            .receive(on: DispatchQueue.main)
            .assign(to: &$isAppOpenAdAvailable)

        // دکمه تبلیغ: فقط نیاز به اینترنت + ریموت دارد (نیازی به لود بودن تبلیغ نیست)
        Publishers.CombineLatest(NetworkMonitor.shared.$isConnected, RemoteConfigManager.shared.$areAdsEnabled)
            .map { connected, remoteEnabled in connected && remoteEnabled }
            .receive(on: DispatchQueue.main)
            .assign(to: &$isAdButtonVisible)

        Publishers.CombineLatest(NetworkMonitor.shared.$isConnected, RemoteConfigManager.shared.$areAdsEnabled)
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

    func initialize() {
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

        ConsentInformation.shared.requestConsentInfoUpdate(with: parameters) { [weak self] error in
            DispatchQueue.main.async {
                if let error = error {
                    Logger.shared.e("AdMobManager", "GDPR consent info update failed: \(error.localizedDescription)")
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

                        if ConsentInformation.shared.canRequestAds {
                            MobileAds.shared.audioVideoManager.isAudioSessionApplicationManaged = true
                            MobileAds.shared.start(completionHandler: nil)
                        }

                        completion()
                    }
                }
            }
        }
    }

    // MARK: - Interstitial Ad

    func loadInterstitialAd() {
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
        guard NetworkMonitor.shared.isConnected else {
            completion(false)
            return
        }

        if isRewardedAdReady {
            completion(true)
            return
        }

        if !isLoadingRewardedAd {
            loadRewardedAd()
        }

        var hasTriggered = false
        let timer = Timer.scheduledTimer(withTimeInterval: maxWaitDuration, repeats: false) { [weak self] _ in
            guard !hasTriggered else { return }
            hasTriggered = true
            Logger.shared.i("AdMobManager", "Rewarded ad wait timed out after \(maxWaitDuration)s.")
            completion(self?.isRewardedAdReady ?? false)
        }

        $isRewardedAdReady
            .dropFirst()
            .filter { $0 }
            .first()
            .receive(on: DispatchQueue.main)
            .sink { _ in
                guard !hasTriggered else { return }
                hasTriggered = true
                timer.invalidate()
                Logger.shared.i("AdMobManager", "Rewarded ad loaded dynamically during wait window!")
                completion(true)
            }
            .store(in: &cancellables)
    }

    // MARK: - App Open Ad

    func loadAppOpenAd() {
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
        guard NetworkMonitor.shared.isConnected else {
            completion(false)
            return
        }

        if isAppOpenAdReady {
            completion(true)
            return
        }

        if !isLoadingAppOpenAd {
            loadAppOpenAd()
        }

        var hasTriggered = false
        let timer = Timer.scheduledTimer(withTimeInterval: maxWaitDuration, repeats: false) { [weak self] _ in
            guard !hasTriggered else { return }
            hasTriggered = true
            Logger.shared.i("AdMobManager", "App open ad wait timed out after \(maxWaitDuration)s.")
            completion(self?.isAppOpenAdReady ?? false)
        }

        $isAppOpenAdReady
            .dropFirst()
            .filter { $0 }
            .first()
            .receive(on: DispatchQueue.main)
            .sink { _ in
                guard !hasTriggered else { return }
                hasTriggered = true
                timer.invalidate()
                Logger.shared.i("AdMobManager", "App open ad loaded dynamically during wait window!")
                completion(true)
            }
            .store(in: &cancellables)
    }

    // MARK: - Adaptive Waiting (Interstitial)

    func waitForAdOrTimeout(maxWaitDuration: TimeInterval = 4.0, completion: @escaping (Bool) -> Void) {
        guard NetworkMonitor.shared.isConnected else {
            completion(false)
            return
        }

        if isAdReady {
            completion(true)
            return
        }

        if !isLoadingAd {
            loadInterstitialAd()
        }

        var hasTriggered = false
        let timer = Timer.scheduledTimer(withTimeInterval: maxWaitDuration, repeats: false) { [weak self] _ in
            guard !hasTriggered else { return }
            hasTriggered = true
            Logger.shared.i("AdMobManager", "Ad wait timed out after \(maxWaitDuration)s. Continuing startup.")
            completion(self?.isAdReady ?? false)
        }

        $isAdReady
            .dropFirst()
            .filter { $0 }
            .first()
            .receive(on: DispatchQueue.main)
            .sink { _ in
                guard !hasTriggered else { return }
                hasTriggered = true
                timer.invalidate()
                Logger.shared.i("AdMobManager", "Ad loaded dynamically during wait window!")
                completion(true)
            }
            .store(in: &cancellables)
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
        guard let scene = UIApplication.shared.connectedScenes.first(where: { $0.activationState == .foregroundActive }) as? UIWindowScene,
              let rootVC = scene.windows.first(where: { $0.isKeyWindow })?.rootViewController else {
            return UIApplication.shared.windows.first(where: { $0.isKeyWindow })?.rootViewController
        }

        var topVC = rootVC
        while let presentedVC = topVC.presentedViewController {
            topVC = presentedVC
        }
        return topVC
    }
}
