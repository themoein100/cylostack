//
//  GameOverModal.swift
//  CircleStack
//
//  Created by Moein on 27/07/2026.
//

import SwiftUI

struct GameOverModal: View {
    var score: Int
    var bestScore: Int
    var outcome: PlayerStore.RunOutcome
    var onReplay: () -> Void
    var onHome: () -> Void
    var onContinueWithAd: (() -> Void)? = nil
    var onContinueWithCoins: (() -> Void)? = nil
    var requiredAds: Int = 1
    var adsWatched: Int = 0
    var userCoins: Int = 0

    @ObservedObject private var adManager = AdMobManager.shared

    var isNewHighScore: Bool { outcome.isRecord }

    var body: some View {
        ZStack {
            // Light scrim only. Glass earns its look by sampling what is behind it, so
            // blacking the stack out first would leave a flat grey slab.
            Color.black.opacity(0.35)
                .ignoresSafeArea()

            card
        }
    }

    // MARK: - Card

    @ViewBuilder
    private var card: some View {
        if #available(iOS 26.0, *) {
            // A panel like this has no system equivalent, so `glassEffect` is the right
            // tool here — unlike the tab bar, which gets its glass from the system.
            // The container makes the panel and the buttons inside it resolve in one
            // pass, so they read as a single piece of glass instead of stacked blurs.
            GlassEffectContainer(spacing: 18) {
                content
                    .padding(32)
                    .frame(width: 320)
                    .glassEffect(.regular, in: .rect(cornerRadius: 28))
            }
        } else {
            content
                .padding(32)
                .frame(width: 320)
                .background(
                    RoundedRectangle(cornerRadius: 28)
                        .fill(Color(hex: "#12121E").opacity(0.85))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 28)
                        .stroke(Color.white.opacity(0.15), lineWidth: 1)
                )
                .shadow(radius: 30)
        }
    }

    private var content: some View {
        VStack(spacing: 28) {
            // Crown symbol
            ZStack {
                Circle()
                    .fill(isNewHighScore ? Color.yellow.opacity(0.15) : Color.white.opacity(0.08))
                    .frame(width: 72, height: 72)

                Image(systemName: isNewHighScore ? "crown.fill" : "flag.fill")
                    .foregroundColor(isNewHighScore ? .yellow : .white.opacity(0.8))
                    .font(.title)
            }

            VStack(spacing: 8) {
                Text(isNewHighScore ? "NEW HIGH SCORE!" : "GAME OVER")
                    .font(.system(.headline, design: .rounded))
                    .fontWeight(.black)
                    .foregroundColor(isNewHighScore ? .yellow : .red)
                    .tracking(1)

                Text("The tower lost its balance.")
                    .font(.system(.caption, design: .rounded))
                    .foregroundColor(.white.opacity(0.6))
            }

            // Score Summary
            HStack(spacing: 30) {
                VStack(spacing: 6) {
                    Text("FINAL SCORE")
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .foregroundColor(.white.opacity(0.5))
                    Text("\(score)")
                        .font(.system(.title, design: .rounded).monospacedDigit())
                        .fontWeight(.black)
                        .foregroundColor(.white)
                }

                Divider()
                    .frame(height: 40)
                    .background(Color.white.opacity(0.15))

                VStack(spacing: 6) {
                    Text("BEST RECORD")
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .foregroundColor(.white.opacity(0.5))
                    Text("\(max(score, bestScore))")
                        .font(.system(.title, design: .rounded).monospacedDigit())
                        .fontWeight(.black)
                        .foregroundColor(.yellow)
                }
            }
            .padding(.vertical, 16)
            .padding(.horizontal, 24)
            .background(Color.white.opacity(0.06))
            .cornerRadius(16)

            if outcome.coinsAwarded > 0 {
                HStack(spacing: 6) {
                    Image(systemName: "circle.hexagongrid.fill")
                        .font(.caption)
                        .foregroundColor(.yellow)
                    Text(outcome.bonusAwarded
                         ? "+\(outcome.coinsAwarded) coins — 10th record bonus!"
                         : "+\(outcome.coinsAwarded) coin")
                        .font(.system(.caption, design: .rounded).weight(.bold))
                        .foregroundColor(.yellow)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(Color.yellow.opacity(0.12))
                .clipShape(Capsule())
            }

            actions
        }
    }

    // MARK: - Actions

    @ViewBuilder
    private var actions: some View {
        VStack(spacing: 12) {
            // Rewarded Ad Revive Option
            if let onContinueWithAd = onContinueWithAd, requiredAds > 0 {
                Button(action: onContinueWithAd) {
                    HStack(spacing: 8) {
                        Image(systemName: "play.tv.fill")
                        Text(requiredAds == 1 ? "CONTINUE (WATCH 1 AD)" : "CONTINUE (WATCH 2 ADS - \(adsWatched)/2)")
                            .font(.system(.subheadline, design: .rounded).weight(.black))
                    }
                    .foregroundColor(.black)
                    .frame(maxWidth: .infinity)
                    .frame(height: 52)
                    .background(
                        LinearGradient(colors: [Color.yellow, Color.orange], startPoint: .leading, endPoint: .trailing)
                    )
                    .cornerRadius(16)
                    .shadow(color: Color.orange.opacity(0.4), radius: 10, x: 0, y: 4)
                }
            }

            // Coin Revive Option (Always available if player has >= 2 coins)
            if let onContinueWithCoins = onContinueWithCoins, userCoins >= 2 {
                Button(action: onContinueWithCoins) {
                    HStack(spacing: 8) {
                        Image(systemName: "circle.hexagongrid.fill")
                            .foregroundColor(.yellow)
                        Text("CONTINUE (2 COINS)")
                            .font(.system(.subheadline, design: .rounded).weight(.black))
                    }
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 52)
                    .background(Color.purple.opacity(0.8))
                    .cornerRadius(16)
                    .overlay(
                        RoundedRectangle(cornerRadius: 16)
                            .stroke(Color.yellow.opacity(0.5), lineWidth: 1.5)
                    )
                    .shadow(color: Color.purple.opacity(0.4), radius: 10, x: 0, y: 4)
                }
            }

            if #available(iOS 26.0, *) {
                Button(action: onReplay) {
                    Label("STACK AGAIN", systemImage: "arrow.counterclockwise")
                        .font(.system(.subheadline, design: .rounded).weight(.bold))
                        .frame(maxWidth: .infinity)
                        .frame(height: 52)
                }
                .buttonStyle(.glassProminent)
                .tint(Color(hex: "#00E5FF"))

                Button(action: onHome) {
                    Text("MAIN MENU")
                        .font(.system(.subheadline, design: .rounded).weight(.bold))
                        .frame(maxWidth: .infinity)
                        .frame(height: 52)
                }
                .buttonStyle(.glass)
            } else {
                Button(action: onReplay) {
                    HStack {
                        Image(systemName: "arrow.counterclockwise")
                        Text("STACK AGAIN")
                            .font(.system(.subheadline, design: .rounded))
                            .fontWeight(.bold)
                    }
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 52)
                    .background(Color(hex: "#00E5FF"))
                    .cornerRadius(16)
                    .shadow(color: Color(hex: "#00E5FF").opacity(0.3), radius: 8, x: 0, y: 4)
                }

                Button(action: onHome) {
                    Text("MAIN MENU")
                        .font(.system(.subheadline, design: .rounded))
                        .fontWeight(.bold)
                        .foregroundColor(.white.opacity(0.8))
                        .frame(maxWidth: .infinity)
                        .frame(height: 52)
                        .background(Color.white.opacity(0.08))
                        .cornerRadius(16)
                        .overlay(
                            RoundedRectangle(cornerRadius: 16)
                                .stroke(Color.white.opacity(0.1), lineWidth: 1)
                        )
                }
            }
        }
    }
}
