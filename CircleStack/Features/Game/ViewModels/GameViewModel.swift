//
//  GameViewModel.swift
//  CircleStack
//
//  Created by Moein on 27/07/2026.
//

import SwiftUI
import SpriteKit
import Combine

class GameViewModel: ObservableObject {
    // Current gameplay state
    @Published var isPlayingGame = false
    @Published var showGameOver = false
    @Published var currentScore = 0
    @Published var currentCombo = 0
    @Published var finalGameScore = 0

    /// What the last finished run paid out, so the game-over card can say so.
    @Published var lastOutcome = PlayerStore.RunOutcome()

    private let store: PlayerStore
    var selectedBg: BgTheme

    // Game Scene reference
    var gameScene: GameScene?
    private var activeCoordinator: GameCoordinator?

    /// The record that stood when the current run started. Captured per run so the
    /// game-over payout is judged against it, even though the best is now saved live.
    private var bestAtRunStart = 0

    var lastScore: Int { store.lastScore }
    var highScore: Int { store.currentBest }

    init(store: PlayerStore = .shared, selectedBg: BgTheme) {
        self.store = store
        self.selectedBg = selectedBg
        Logger.shared.i("GameVM", "Initialized game session VM.")
    }

    func updateTheme(bg: BgTheme) {
        self.selectedBg = bg
        gameScene?.currentBg = bg
    }

    /// Pushes the current material and difficulty into the scene. Called before every
    /// run so a change made in Settings takes effect on the very next game.
    private func applyLoadout() {
        gameScene?.currentMaterial = store.selectedMaterial
        gameScene?.difficulty = store.settings
    }

    func setupGameScene() {
        guard gameScene == nil else {
            applyLoadout()
            return
        }
        Logger.shared.i("GameVM", "Configuring new SpriteKit GameScene")
        let scene = GameScene(size: CGSize(width: UIScreen.main.bounds.width,
                                           height: UIScreen.main.bounds.height))

        let coord = GameCoordinator()
        coord.onScoreUpdated = { [weak self] score, combo in
            guard let self = self else { return }
            self.currentScore = score
            self.currentCombo = combo
            // Persist a new best the instant it is reached, so the record survives even
            // if this run never reaches game over (quit, backgrounded, or killed).
            self.store.recordLiveScore(score)
        }
        coord.onPerfectHit = { [weak self] combo in
            self?.store.registerPerfect(combo: combo)
        }
        coord.onGameOver = { [weak self] finalScore in
            self?.handleGameOver(finalScore: finalScore)
        }

        scene.gameDelegate = coord
        scene.currentBg = selectedBg
        scene.currentMaterial = store.selectedMaterial
        scene.difficulty = store.settings

        self.activeCoordinator = coord
        self.gameScene = scene
    }

    /// Revive state
    @Published var adRevivesUsed: Int = 0
    @Published var adsWatchedForRevive: Int = 0

    /// Free Coin Ad Progress (0/2 or 1/2 watched)
    @Published var freeCoinAdProgress: Int = 0
    @Published var isFreeCoinAdLoading: Bool = false
    @Published var showFreeCoinRewardDialog: Bool = false

    /// Returns required ad count for next ad revive in current game run:
    /// 1st ad revive (adRevivesUsed 0): 1 Rewarded Ad
    /// 2nd ad revive (adRevivesUsed 1): 2 Rewarded Ads
    /// 3rd+ (adRevivesUsed >= 2): No ad revives (use coins or start again)
    var requiredAdsForRevive: Int {
        if adRevivesUsed == 0 {
            return 1
        } else if adRevivesUsed == 1 {
            return 2
        } else {
            return 0
        }
    }

    /// نمایش دکمه: فقط اینترنت وصل + تبلیغات ریموت روشن (نیازی به لود تبلیغ نیست)
    var canShowAdReviveButton: Bool {
        RemoteConfigManager.shared.areAdsEnabled &&
        RemoteConfigManager.shared.isRewardedAdEnabled &&
        NetworkMonitor.shared.isConnected &&
        requiredAdsForRevive > 0
    }

    /// تبلیغ واقعاً آماده‌ی پخش است (برای اجرا)
    var canReviveWithAd: Bool {
        canShowAdReviveButton && AdMobManager.shared.isRewardedAdReady
    }

    /// Coin revives taken in the current run. Resets with every new run.
    @Published private(set) var coinRevivesUsed: Int = 0

    /// What the next coin revive costs: two for the first, one more each time
    /// after. Carrying a run further and further has to get harder to justify,
    /// otherwise a large balance turns any run into an unbounded one.
    var coinReviveCost: Int {
        2 + coinRevivesUsed
    }

    var canReviveWithCoins: Bool {
        store.coins >= coinReviveCost
    }

    func watchAdForFreeCoin() {
        guard store.canEarnCoinFromAd else { return }

        if freeCoinAdProgress == 0 {
            // Watch 1st Ad
            guard AdMobManager.shared.isRewardedAdReady else { return }
            AdMobManager.shared.showRewardedAd { [weak self] earnedReward in
                guard let self = self else { return }
                if earnedReward {
                    self.freeCoinAdProgress = 1
                    withAnimation {
                        self.isFreeCoinAdLoading = true
                    }

                    // Wait for Ad #2 to finish loading, then automatically launch Ad #2!
                    AdMobManager.shared.waitForRewardedAdOrTimeout(maxWaitDuration: 6.0) { [weak self] ready in
                        guard let self = self else { return }
                        withAnimation {
                            self.isFreeCoinAdLoading = false
                        }
                        if ready {
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                                self?.watchAdForFreeCoin()
                            }
                        } else {
                            Logger.shared.w("GameVM", "Failed to load 2nd rewarded ad in time.")
                        }
                    }
                }
            }
        } else if freeCoinAdProgress == 1 {
            // Watch 2nd Ad
            guard AdMobManager.shared.isRewardedAdReady else { return }
            AdMobManager.shared.showRewardedAd { [weak self] earnedReward in
                guard let self = self else { return }
                if earnedReward {
                    self.freeCoinAdProgress = 0
                    self.store.recordCoinAdClaim()

                    // Present sleek celebration reward dialog!
                    withAnimation(.spring(response: 0.4, dampingFraction: 0.75)) {
                        self.showFreeCoinRewardDialog = true
                    }
                    Logger.shared.i("GameVM", "Earned 1 free coin from watching 2 rewarded ads!")
                } else {
                    self.freeCoinAdProgress = 0
                }
            }
        }
    }

    func launchGame() {
        setupGameScene()
        applyLoadout()

        // Settle the colour and rebuild the stack *before* the scene is on screen, so
        // the first frame the player sees is already the run's real colour.
        gameScene?.prepareRun()

        Logger.shared.i("GameVM", "Launching active game...")
        bestAtRunStart = store.currentBest
        currentScore = 0
        currentCombo = 0
        adRevivesUsed = 0
        coinRevivesUsed = 0
        adsWatchedForRevive = 0
        showGameOver = false
        withAnimation(.easeInOut(duration: 0.25)) {
            isPlayingGame = true
        }

        // Let the crossfade land before the disc starts sweeping
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.gameScene?.startGame()
        }
    }

    func restartGame() {
        Logger.shared.i("GameVM", "Restarting game stack...")
        applyLoadout()
        bestAtRunStart = store.currentBest
        // Advance to the next colour so the new run feels fresh, then consume it.
        gameScene?.advanceRunHue()
        gameScene?.prepareRun()

        withAnimation(.easeInOut(duration: 0.3)) {
            showGameOver = false
            currentScore = 0
            currentCombo = 0
            adRevivesUsed = 0
            coinRevivesUsed = 0
            adsWatchedForRevive = 0
        }
        gameScene?.startGame()
    }

    func quitGame() {
        Logger.shared.i("GameVM", "Quitting active game session back to home")
        withAnimation(.easeInOut(duration: 0.25)) {
            isPlayingGame = false
            showGameOver = false
        }
        gameScene?.resetGame()
    }

    func watchAdForRevive() {
        guard canReviveWithAd else { return }
        AdMobManager.shared.showRewardedAd { [weak self] earnedReward in
            guard let self = self, earnedReward else { return }
            self.adsWatchedForRevive += 1
            if self.adsWatchedForRevive >= self.requiredAdsForRevive {
                let isFirstAdRevive = (self.adRevivesUsed == 0)
                self.adRevivesUsed += 1
                self.adsWatchedForRevive = 0
                let reviveType: GameScene.ReviveType = isFirstAdRevive ? .adOne : .adTwo
                self.reviveGame(type: reviveType)
            } else {
                // Show loading transition while waiting for 2nd ad to finish preloading from Google
                withAnimation {
                    self.isFreeCoinAdLoading = true
                }
                AdMobManager.shared.waitForRewardedAdOrTimeout(maxWaitDuration: 6.0) { [weak self] ready in
                    guard let self = self else { return }
                    withAnimation {
                        self.isFreeCoinAdLoading = false
                    }
                    if ready {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                            self?.watchAdForRevive()
                        }
                    } else {
                        Logger.shared.w("GameVM", "Failed to load 2nd rewarded ad for revive.")
                    }
                }
            }
        }
    }

    func reviveWithCoins() {
        let cost = coinReviveCost
        guard store.spendCoins(cost) else { return }
        coinRevivesUsed += 1
        Logger.shared.i("GameVM", "Player spent \(cost) coins to revive (next costs \(coinReviveCost))")
        adsWatchedForRevive = 0
        reviveGame(type: .coins)
    }

    func reviveGame(type: GameScene.ReviveType = .adOne) {
        Logger.shared.i("GameVM", "Reviving game run (type \(type))...")
        withAnimation(.easeInOut(duration: 0.3)) {
            showGameOver = false
        }
        gameScene?.reviveGame(reviveType: type)
    }

    private func handleGameOver(finalScore: Int) {
        Logger.shared.i("GameVM", "Game ended! Final stack score: \(finalScore)")

        finalGameScore = finalScore
        lastOutcome = store.recordRun(score: finalScore, bestBeforeRun: bestAtRunStart)

        if lastOutcome.isRecord {
            Logger.shared.i("GameVM", "New record on \(store.difficultyKey): \(finalScore), +\(lastOutcome.coinsAwarded) coins")
        }

        // The global board ranks lifetime mastery — best at every setting, each weighted
        // by how hard that setting really plays — so pushing the hard modes is the way
        // up. The per-difficulty board still ranks the raw run at that one setting.
        // (recordRun above has already folded this run into bestScores, so the weighted
        // total reflects it.)
        let globalLeaderboardID = "cylostack_leaderboard"
        let difficultyLeaderboardID = "cylostack_leaderboard_s\(store.speedLevel)k\(store.shrinkLevel)"
        GameCenterManager.shared.submitScore(store.totalWeightedScore, to: globalLeaderboardID)
        GameCenterManager.shared.submitScore(finalScore, to: difficultyLeaderboardID)

        withAnimation(.easeInOut(duration: 0.3)) {
            showGameOver = true
        }
    }
}

// GameCoordinator class to bridge SpriteKit delegate to SwiftUI ViewModel updates
class GameCoordinator: NSObject, GameSceneDelegate {
    var onScoreUpdated: ((Int, Int) -> Void)?
    var onPerfectHit: ((Int) -> Void)?
    var onGameOver: ((Int) -> Void)?

    func gameDidUpdateScore(score: Int, combo: Int) {
        onScoreUpdated?(score, combo)
    }

    func gameDidPerfectHit(combo: Int) {
        onPerfectHit?(combo)
    }

    func gameDidGameOver(finalScore: Int) {
        onGameOver?(finalScore)
    }
}
