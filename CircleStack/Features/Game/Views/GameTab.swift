//
//  GameTab.swift
//  CircleStack
//
//  Created by Moein on 27/07/2026.
//

import SwiftUI
import SpriteKit

struct GameTab: View {
    @ObservedObject var store: PlayerStore
    var selectedBg: BgTheme

    /// Mirrors the run state up to the container, which hides the tab bar while playing.
    @Binding var isRunActive: Bool

    @StateObject private var viewModel: GameViewModel
    @State private var showSettings = false

    // The revive and free-coin buttons are derived from these three singletons. Without
    // observing them the buttons keep their stale state when the Telegram panel toggles
    // ads, when an ad finishes loading, or when the device drops offline.
    @ObservedObject private var adManager = AdMobManager.shared
    @ObservedObject private var remoteConfig = RemoteConfigManager.shared
    @ObservedObject private var network = NetworkMonitor.shared

    init(store: PlayerStore, selectedBg: BgTheme, isRunActive: Binding<Bool>) {
        self.store = store
        self.selectedBg = selectedBg
        self._isRunActive = isRunActive
        self._viewModel = StateObject(wrappedValue: GameViewModel(store: store, selectedBg: selectedBg))
    }
    

    var body: some View {
        ZStack {
            if viewModel.isPlayingGame {
                runView
            } else {
                menuView
            }

            if viewModel.isFreeCoinAdLoading {
                freeCoinLoadingOverlay
            }

            if viewModel.showFreeCoinRewardDialog {
                freeCoinRewardDialog
            }
        }
        .onAppear {
            viewModel.setupGameScene()
            isRunActive = viewModel.isPlayingGame
        }
        .onDisappear { isRunActive = false }
        .onChange(of: viewModel.isPlayingGame) { playing in
            isRunActive = playing
        }
        .onChange(of: selectedBg) { newBg in
            viewModel.updateTheme(bg: newBg)
        }
    }

    // MARK: - Run

    private var runView: some View {
        ZStack {
            // Opaque floor under the scene. Without it the themed gradient behind the
            // tab shows around the edges for the length of the crossfade, which reads
            // as a coloured border flashing in as the run opens.
            Color.black.ignoresSafeArea()

            if let scene = viewModel.gameScene {
                SpriteKitGameView(scene: scene)
                    .ignoresSafeArea()
            }

            VStack(spacing: 14) {
                HStack {
                    Button(action: { viewModel.quitGame() }) {
                        Image(systemName: "xmark")
                            .font(.headline)
                            .foregroundColor(.white)
                            .padding(12)
                            .background(Color.white.opacity(0.1))
                            .clipShape(Circle())
                    }

                    Spacer()

                    if viewModel.currentCombo > 0 {
                        HStack(spacing: 4) {
                            Image(systemName: "bolt.fill")
                                .foregroundColor(.orange)
                            Text("COMBO x\(viewModel.currentCombo)")
                                .font(.system(.subheadline, design: .rounded))
                                .fontWeight(.bold)
                                .foregroundColor(.orange)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Color.orange.opacity(0.15))
                        .cornerRadius(12)
                        .transition(.scale.combined(with: .opacity))
                    }

                    Spacer()

                    // Balances the close button so the count stays centred
                    Color.clear.frame(width: 44, height: 44)
                }
                .padding(.horizontal, 20)
                .padding(.top, 12)

                // The count sits over open sky above the stack. Monospaced digits keep
                // it from twitching sideways as it rolls over. It steps aside for the
                // game-over card, which reports the score itself.
                if !viewModel.showGameOver {
                    Text("\(viewModel.currentScore)")
                        .font(.system(size: 72, weight: .heavy, design: .rounded).monospacedDigit())
                        .foregroundColor(.white)
                        // Neutral bloom, not a themed one: each run opens on its own
                        // hue, so anything tinted would clash as often as it matched.
                        .shadow(color: .white.opacity(0.35), radius: 20)
                        .shadow(color: .black.opacity(0.45), radius: 3, y: 2)
                        .transition(.opacity)
                }

                Spacer()
            }

            if viewModel.showGameOver {
                GameOverModal(
                    score: viewModel.finalGameScore,
                    bestScore: store.currentBest,
                    outcome: viewModel.lastOutcome,
                    onReplay: { viewModel.restartGame() },
                    onHome: { viewModel.quitGame() },
                    onContinueWithAd: viewModel.canShowAdReviveButton ? { viewModel.watchAdForRevive() } : nil,
                    onContinueWithCoins: viewModel.canReviveWithCoins ? { viewModel.reviveWithCoins() } : nil,
                    requiredAds: viewModel.requiredAdsForRevive,
                    adsWatched: viewModel.adsWatchedForRevive,
                    userCoins: store.coins
                )
                .transition(.scale.combined(with: .opacity))
            }
        }
        .transition(.opacity)
    }

    // MARK: - Menu

    private var menuView: some View {
        VStack(spacing: 0) {
            // Header Bar
            HStack(alignment: .center) {
                Button(action: { showSettings = true }) {
                    Image(systemName: SoundManager.shared.isMuted ? "speaker.slash.fill" : "gearshape.fill")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(.white.opacity(0.7))
                        .padding(12)
                        .background(Color.white.opacity(0.1))
                        .clipShape(Circle())
                }

                Spacer()

                VStack(spacing: 4) {
                    Text("CYLOSTACK")
                        .font(.system(size: 28, weight: .black, design: .rounded))
                        .foregroundColor(.white)
                        .tracking(2)

                    Text("2.5D Casual Arcade")
                        .font(.system(.caption2, design: .rounded))
                        .foregroundColor(.white.opacity(0.5))
                        .tracking(1)
                }

                Spacer()

                CoinBadge(coins: store.coins)
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 24)

            // The real disc, in the material actually equipped — a flat circle here
            // would be advertising a game the player is not about to play.
            PreviewDisc(material: store.selectedMaterial, hue: store.lastRunHue)
                .id("\(store.selectedMaterial.id)-\(store.lastRunHue)")
                .frame(height: 150)
                .padding(.bottom, 26)

            HStack(spacing: 16) {
                ScoreTile(title: "Last Score", value: "\(store.lastScore)", color: .white.opacity(0.8))
                ScoreTile(title: "Best Here", value: "\(store.currentBest)", color: .yellow)
            }
            .padding(.horizontal, 24)

            HStack(spacing: 8) {
                Label(store.settings.speedName, systemImage: "speedometer")
                Text("·").foregroundColor(.white.opacity(0.3))
                Label(store.settings.shrinkName, systemImage: "arrow.down.right.and.arrow.up.left")
            }
            .font(.system(size: 11, design: .rounded).weight(.semibold))
            .foregroundColor(.white.opacity(0.5))
            .padding(.top, 14)

            Button(action: { viewModel.launchGame() }) {
                HStack(spacing: 12) {
                    Image(systemName: "play.fill")
                        .font(.title2)
                    Text("START STACKING")
                        .font(.system(.headline, design: .rounded))
                        .fontWeight(.bold)
                }
                .foregroundColor(.black)
                .frame(maxWidth: .infinity)
                .frame(height: 60)
                .background(store.themeAccentColor)
                .cornerRadius(20)
                .shadow(color: store.themeAccentColor.opacity(0.4), radius: 15, x: 0, y: 8)
                .padding(.horizontal, 24)
            }
            .keyboardShortcut(.space, modifiers: [])
            .padding(.top, 22)

            // Free Coin Rewarded Ad Card (Watch 2 ads for 1 coin, max 3 times/hr)
            freeCoinCard
                .padding(.horizontal, 24)
                .padding(.top, 16)

            Spacer()
        }
        .transition(.opacity)
        .sheet(isPresented: $showSettings) {
            GameSettingsSheet(store: store)
        }
    }

    private var freeCoinCard: some View {
        let claimsLeft = store.remainingCoinAdClaimsThisHour
        let isAdReady = AdMobManager.shared.isRewardedAdButtonVisible

        return HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(Color.yellow.opacity(0.2))
                    .frame(width: 42, height: 42)

                Image(systemName: "circle.hexagongrid.fill")
                    .font(.system(size: 20))
                    .foregroundColor(.yellow)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text("FREE COIN")
                    .font(.system(size: 13, weight: .black, design: .rounded))
                    .foregroundColor(.yellow)

                Text(viewModel.freeCoinAdProgress > 0 ? "Watch 1 more ad to claim +1 Coin!" : "Watch 2 ads to earn +1 Coin")
                    .font(.system(size: 11, design: .rounded))
                    .foregroundColor(.white.opacity(0.7))
            }

            Spacer()

            Button(action: { viewModel.watchAdForFreeCoin() }) {
                HStack(spacing: 4) {
                    Image(systemName: "play.tv.fill")
                    Text(claimsLeft == 0 ? "CLAIMED" : (viewModel.freeCoinAdProgress == 1 ? "AD 2/2" : "GET COIN"))
                        .font(.system(size: 12, weight: .black, design: .rounded))
                }
                .foregroundColor(.black)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(claimsLeft > 0 && isAdReady ? Color.yellow : Color.white.opacity(0.2))
                .cornerRadius(12)
            }
            .disabled(claimsLeft == 0 || !isAdReady)
        }
        .padding(14)
        .background(Color.white.opacity(0.06))
        .cornerRadius(18)
        .overlay(
            RoundedRectangle(cornerRadius: 18)
                .stroke(Color.yellow.opacity(0.25), lineWidth: 1)
        )
    }

    // MARK: - Free Coin Overlays

    private var freeCoinLoadingOverlay: some View {
        ZStack {
            Color.black.opacity(0.75)
                .ignoresSafeArea()

            VStack(spacing: 20) {
                ProgressView()
                    .progressViewStyle(CircularProgressViewStyle(tint: .yellow))
                    .scaleEffect(1.8)

                VStack(spacing: 6) {
                    Text("LOADING AD 2/2...")
                        .font(.system(size: 18, weight: .black, design: .rounded))
                        .foregroundColor(.yellow)

                    Text("Get ready for the final ad to earn your free coin!")
                        .font(.system(size: 12, design: .rounded))
                        .foregroundColor(.white.opacity(0.7))
                        .multilineTextAlignment(.center)
                }
            }
            .padding(30)
            .background(Color(hex: "#12121E").opacity(0.95))
            .cornerRadius(24)
            .overlay(
                RoundedRectangle(cornerRadius: 24)
                    .stroke(Color.yellow.opacity(0.4), lineWidth: 1.5)
            )
            .shadow(color: Color.yellow.opacity(0.3), radius: 20, x: 0, y: 10)
            .padding(.horizontal, 40)
        }
        .transition(.opacity)
    }

    private var freeCoinRewardDialog: some View {
        ZStack {
            Color.black.opacity(0.8)
                .ignoresSafeArea()

            VStack(spacing: 22) {
                ZStack {
                    Circle()
                        .fill(Color.yellow.opacity(0.2))
                        .frame(width: 70, height: 70)

                    Image(systemName: "circle.hexagongrid.fill")
                        .font(.system(size: 38))
                        .foregroundColor(.yellow)
                        .shadow(color: .yellow.opacity(0.6), radius: 10)
                }

                VStack(spacing: 8) {
                    Text("+1 COIN ADDED!")
                        .font(.system(size: 22, weight: .black, design: .rounded))
                        .foregroundColor(.white)

                    Text("Congratulations! You've completed both ads and earned 1 free coin.")
                        .font(.system(size: 13, design: .rounded))
                        .foregroundColor(.white.opacity(0.7))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 10)
                }

                Button(action: {
                    withAnimation(.easeOut(duration: 0.25)) {
                        viewModel.showFreeCoinRewardDialog = false
                    }
                    SoundManager.shared.playGood()
                }) {
                    Text("GREAT!")
                        .font(.system(size: 15, weight: .black, design: .rounded))
                        .foregroundColor(.black)
                        .frame(maxWidth: .infinity)
                        .frame(height: 50)
                        .background(Color.yellow)
                        .cornerRadius(16)
                        .shadow(color: Color.yellow.opacity(0.4), radius: 10, x: 0, y: 5)
                }
            }
            .padding(26)
            .background(Color(hex: "#141424"))
            .cornerRadius(28)
            .overlay(
                RoundedRectangle(cornerRadius: 28)
                    .stroke(Color.yellow.opacity(0.5), lineWidth: 1.5)
            )
            .shadow(color: Color.black.opacity(0.5), radius: 30, x: 0, y: 15)
            .padding(.horizontal, 36)
        }
        .transition(.scale(scale: 0.85).combined(with: .opacity))
    }
}
