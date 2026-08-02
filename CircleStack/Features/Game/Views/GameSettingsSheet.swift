//
//  GameSettingsSheet.swift
//  CircleStack
//
//  Created by Moein on 28/07/2026.
//

import SwiftUI

/// Quick-access panel reachable from the game / menu screen.
/// Covers sound toggle and the coin earning guide.
struct GameSettingsSheet: View {
    @ObservedObject var store: PlayerStore
    @Environment(\.dismiss) private var dismiss
    
    // Mirror isMuted into a @State so Toggle binds reactively
    @State private var isMuted: Bool = SoundManager.shared.isMuted
    @State private var isHapticsOn: Bool = SoundManager.shared.isHapticsEnabled
    
    @ObservedObject private var gcManager = GameCenterManager.shared
    @ObservedObject private var remoteConfig = RemoteConfigManager.shared
    @State private var showLeaderboard = false
    
    var body: some View {
        NavigationView {
            ZStack {
                // Background
                LinearGradient(
                    colors: [Color(white: 0.08), Color(white: 0.04)],
                    startPoint: .top, endPoint: .bottom
                )
                .ignoresSafeArea()

                ScrollView(showsIndicators: false) {
                    VStack(spacing: 24) {
                        soundSection
                        leaderboardSection
                        if !remoteConfig.privacyURL.isEmpty {
                            legalSection
                        }
                        supportSection
                        coinGuideSection
                        Color.clear.frame(height: 20)
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 8)
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(action: { dismiss() }) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title2)
                            .foregroundStyle(Color.white.opacity(0.5))
                    }
                }
            }
        }
        .preferredColorScheme(.dark)
        .sheet(isPresented: $showLeaderboard) {
            GameCenterLeaderboardView(leaderboardID: "cylostack_leaderboard")
                .ignoresSafeArea()
        }
    }

    // MARK: - Sound Section

    private var soundSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            sectionHeader(icon: "speaker.wave.3.fill", title: "Audio", color: .cyan)

            settingsCard {
                VStack(spacing: 0) {
                    // Mute toggle row
                    HStack(spacing: 14) {
                        ZStack {
                            Circle()
                                .fill(isMuted ? Color.red.opacity(0.18) : Color.green.opacity(0.18))
                                .frame(width: 40, height: 40)
                            Image(systemName: isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                                .font(.system(size: 17, weight: .semibold))
                                .foregroundColor(isMuted ? .red : .green)
                        }

                        VStack(alignment: .leading, spacing: 2) {
                            Text("Game Sounds")
                                .font(.system(.body, design: .rounded).weight(.semibold))
                                .foregroundColor(.white)
                            Text(isMuted ? "All sounds off" : "Sounds enabled")
                                .font(.system(.caption, design: .rounded))
                                .foregroundColor(.white.opacity(0.45))
                        }

                        Spacer()

                        Toggle("", isOn: Binding(
                            get: { !isMuted },
                            set: { on in
                                isMuted = !on
                                SoundManager.shared.isMuted = isMuted
                                if !isMuted { SoundManager.shared.playGood() }
                            }
                        ))
                        .tint(Color.green)
                        .labelsHidden()
                    }
                    .padding(.vertical, 14)
                    .padding(.horizontal, 16)

                    Divider().background(Color.white.opacity(0.07)).padding(.horizontal, 16)

                    // Haptics toggle row
                    HStack(spacing: 14) {
                        ZStack {
                            Circle()
                                .fill(isHapticsOn ? Color.purple.opacity(0.18) : Color.white.opacity(0.07))
                                .frame(width: 40, height: 40)
                            Image(systemName: "hand.tap.fill")
                                .font(.system(size: 17, weight: .semibold))
                                .foregroundColor(isHapticsOn ? .purple : .white.opacity(0.35))
                        }

                        VStack(alignment: .leading, spacing: 2) {
                            Text("Haptics")
                                .font(.system(.body, design: .rounded).weight(.semibold))
                                .foregroundColor(.white)
                            Text(isHapticsOn ? "Vibration feedback on" : "Vibration off")
                                .font(.system(.caption, design: .rounded))
                                .foregroundColor(.white.opacity(0.45))
                        }

                        Spacer()

                        Toggle("", isOn: Binding(
                            get: { isHapticsOn },
                            set: { on in
                                isHapticsOn = on
                                SoundManager.shared.isHapticsEnabled = on
                            }
                        ))
                        .tint(Color.purple)
                        .labelsHidden()
                    }
                    .padding(.vertical, 14)
                    .padding(.horizontal, 16)
                }
            }
        }
    }

    // MARK: - Leaderboard Section

    private var leaderboardSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            sectionHeader(icon: "trophy.fill", title: "Rankings", color: .yellow)

            settingsCard {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 14) {
                        ZStack {
                            Circle()
                                .fill(gcManager.isAuthenticated ? Color.yellow.opacity(0.18) : Color.white.opacity(0.07))
                                .frame(width: 40, height: 40)
                            Image(systemName: "crown.fill")
                                .font(.system(size: 17, weight: .semibold))
                                .foregroundColor(gcManager.isAuthenticated ? .yellow : .white.opacity(0.35))
                        }

                        VStack(alignment: .leading, spacing: 2) {
                            Text("Leaderboards")
                                .font(.system(.body, design: .rounded).weight(.semibold))
                                .foregroundColor(.white)
                            Text(gcManager.isAuthenticated ? "Connected to Game Center" : "Sign in to compare scores")
                                .font(.system(.caption, design: .rounded))
                                .foregroundColor(.white.opacity(0.45))
                        }

                        Spacer()

                        if gcManager.isAuthenticated {
                            Button(action: {
                                SoundManager.shared.playGood()
                                showLeaderboard = true
                            }) {
                                Text("View")
                                    .font(.system(.subheadline, design: .rounded).weight(.bold))
                                    .foregroundColor(.black)
                                    .padding(.horizontal, 16)
                                    .padding(.vertical, 8)
                                    .background(Color.yellow)
                                    .cornerRadius(10)
                            }
                        } else {
                            Button(action: {
                                SoundManager.shared.playGood()
                                gcManager.authenticateLocalPlayer()
                            }) {
                                Text("Connect")
                                    .font(.system(.subheadline, design: .rounded).weight(.bold))
                                    .foregroundColor(.white)
                                    .padding(.horizontal, 16)
                                    .padding(.vertical, 8)
                                    .background(Color.white.opacity(0.15))
                                    .cornerRadius(10)
                            }
                        }
                    }
                    .padding(.vertical, 14)
                    .padding(.horizontal, 16)
                }
            }
        }
    }

    // MARK: - Legal Section

    /// Sits directly under Rankings: it belongs to the app, not to how the game plays,
    /// so this sheet is its one home. App Review looks for it here too.
    private var legalSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            sectionHeader(icon: "lock.shield.fill", title: "Legal", color: .blue)

            settingsCard {
                Button(action: {
                    SoundManager.shared.playGood()
                    if let url = URL(string: remoteConfig.privacyURL),
                       UIApplication.shared.canOpenURL(url) {
                        UIApplication.shared.open(url)
                    }
                }) {
                    HStack(spacing: 14) {
                        ZStack {
                            Circle()
                                .fill(Color.blue.opacity(0.18))
                                .frame(width: 40, height: 40)
                            Image(systemName: "lock.shield.fill")
                                .font(.system(size: 17, weight: .semibold))
                                .foregroundColor(.blue)
                        }

                        VStack(alignment: .leading, spacing: 2) {
                            Text("Privacy Policy")
                                .font(.system(.body, design: .rounded).weight(.semibold))
                                .foregroundColor(.white)
                            Text("How your data is handled")
                                .font(.system(.caption, design: .rounded))
                                .foregroundColor(.white.opacity(0.45))
                        }

                        Spacer()

                        Image(systemName: "chevron.right")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundColor(.white.opacity(0.25))
                    }
                    .padding(.vertical, 14)
                    .padding(.horizontal, 16)
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - Coin Guide Section

    private var coinGuideSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            sectionHeader(icon: "dollarsign.circle.fill", title: "How to Earn Coins", color: .yellow)

            settingsCard {
                VStack(spacing: 0) {
                    coinTip(
                        icon: "trophy.fill",
                        iconColor: .yellow,
                        title: "Beat Your Record",
                        description: "Every time you break your personal best score, you earn +1 coin.",
                        badge: "+1 🪙"
                    )

                    Divider().background(Color.white.opacity(0.07)).padding(.horizontal, 16)

                    coinTip(
                        icon: "star.fill",
                        iconColor: .orange,
                        title: "Every 10th Record",
                        description: "Break your record for the 10th, 20th, 30th... time and get a big bonus.",
                        badge: "+6 🪙"
                    )

                    Divider().background(Color.white.opacity(0.07)).padding(.horizontal, 16)

                    coinTip(
                        icon: "cart.fill",
                        iconColor: .cyan,
                        title: "Spend Wisely",
                        description: "Use your coins in the Shop to unlock premium disc materials.",
                        badge: "Shop"
                    )
                }
            }

            // Current coins display
            HStack(spacing: 8) {
                Image(systemName: "dollarsign.circle.fill")
                    .foregroundColor(.yellow)
                Text("You have")
                    .foregroundColor(.white.opacity(0.6))
                Text(formatCoins(store.coins))
                    .fontWeight(.bold)
                    .foregroundColor(.yellow)
                Text("coins")
                    .foregroundColor(.white.opacity(0.6))
                Spacer()
            }
            .font(.system(.subheadline, design: .rounded))
            .padding(.horizontal, 6)
        }
    }

    // MARK: - Support Section

    private var supportSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            sectionHeader(icon: "heart.fill", title: "Support the Game", color: .pink)

            settingsCard {
                VStack(spacing: 0) {
                    // Rate App
                    Button(action: {
                        SoundManager.shared.playGood()
                        rateOnAppStore()
                    }) {
                        HStack(spacing: 14) {
                            ZStack {
                                Circle()
                                    .fill(Color.pink.opacity(0.18))
                                    .frame(width: 40, height: 40)
                                Image(systemName: "star.fill")
                                    .font(.system(size: 17, weight: .semibold))
                                    .foregroundColor(.pink)
                            }

                            VStack(alignment: .leading, spacing: 2) {
                                Text("Rate on App Store")
                                    .font(.system(.body, design: .rounded).weight(.semibold))
                                    .foregroundColor(.white)
                                Text("Leave a review to support us")
                                    .font(.system(.caption, design: .rounded))
                                    .foregroundColor(.white.opacity(0.45))
                            }

                            Spacer()

                            Image(systemName: "chevron.right")
                                .font(.system(size: 14, weight: .bold))
                                .foregroundColor(.white.opacity(0.25))
                        }
                        .padding(.vertical, 14)
                        .padding(.horizontal, 16)
                    }
                    .buttonStyle(.plain)

                    Divider().background(Color.white.opacity(0.07)).padding(.horizontal, 16)

                    // Share App
                    Button(action: {
                        SoundManager.shared.playGood()
                        shareApp()
                    }) {
                        HStack(spacing: 14) {
                            ZStack {
                                Circle()
                                    .fill(Color.blue.opacity(0.18))
                                    .frame(width: 40, height: 40)
                                Image(systemName: "square.and.arrow.up.fill")
                                    .font(.system(size: 17, weight: .semibold))
                                    .foregroundColor(.blue)
                            }

                            VStack(alignment: .leading, spacing: 2) {
                                Text("Share with Friends")
                                    .font(.system(.body, design: .rounded).weight(.semibold))
                                    .foregroundColor(.white)
                                Text("Invite others to stack circles")
                                    .font(.system(.caption, design: .rounded))
                                    .foregroundColor(.white.opacity(0.45))
                            }

                            Spacer()

                            Image(systemName: "chevron.right")
                                .font(.system(size: 14, weight: .bold))
                                .foregroundColor(.white.opacity(0.25))
                        }
                        .padding(.vertical, 14)
                        .padding(.horizontal, 16)
                    }
                    .buttonStyle(.plain)

                    // The privacy link lives in Settings ▸ Legal only, so there is exactly
                    // one place in the app that owns it.
                }
            }
        }
    }

    // MARK: - Helpers

    private func sectionHeader(icon: String, title: String, color: Color) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .foregroundColor(color)
                .font(.system(size: 15, weight: .semibold))
            Text(title.uppercased())
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .foregroundColor(.white.opacity(0.55))
                .tracking(1.2)
        }
    }

    private func settingsCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Color.white.opacity(0.06))
                    .overlay(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .stroke(Color.white.opacity(0.08), lineWidth: 1)
                    )
            )
    }

    private func coinTip(icon: String, iconColor: Color, title: String, description: String, badge: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            ZStack {
                Circle()
                    .fill(iconColor.opacity(0.15))
                    .frame(width: 40, height: 40)
                Image(systemName: icon)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundColor(iconColor)
            }
            .padding(.top, 2)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(.subheadline, design: .rounded).weight(.semibold))
                    .foregroundColor(.white)
                Text(description)
                    .font(.system(.caption, design: .rounded))
                    .foregroundColor(.white.opacity(0.5))
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()

            Text(badge)
                .font(.system(.caption, design: .rounded).weight(.bold))
                .foregroundColor(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    Capsule()
                        .fill(iconColor.opacity(0.2))
                        .overlay(Capsule().stroke(iconColor.opacity(0.35), lineWidth: 1))
                )
                .padding(.top, 2)
        }
        .padding(.vertical, 14)
        .padding(.horizontal, 16)
    }

    // MARK: - App Store & Share Logic

    private func rateOnAppStore() {
        let appStoreLink = remoteConfig.appStoreURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if !appStoreLink.isEmpty {
            var reviewURLString = appStoreLink
            if !reviewURLString.contains("action=write-review") {
                reviewURLString += reviewURLString.contains("?") ? "&action=write-review" : "?action=write-review"
            }
            if let url = URL(string: reviewURLString), UIApplication.shared.canOpenURL(url) {
                UIApplication.shared.open(url)
                return
            }
        }
        // Fallback default if appStoreURL not configured yet
        if let fallbackURL = URL(string: "https://apps.apple.com") {
            UIApplication.shared.open(fallbackURL)
        }
    }

    private func shareApp() {
        let appStoreLink = remoteConfig.appStoreURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let linkToShare = appStoreLink.isEmpty ? "https://apps.apple.com" : appStoreLink
        
        let items: [Any]
        if let url = URL(string: linkToShare) {
            items = [url]
        } else {
            items = [linkToShare]
        }
        
        let av = UIActivityViewController(activityItems: items, applicationActivities: nil)
        
        guard let windowScene = UIApplication.shared.connectedScenes.first(where: { $0.activationState == .foregroundActive }) as? UIWindowScene ?? UIApplication.shared.connectedScenes.first as? UIWindowScene,
              let rootVC = windowScene.windows.first(where: { $0.isKeyWindow })?.rootViewController ?? windowScene.windows.first?.rootViewController else {
            return
        }
        
        var topVC = rootVC
        while let presented = topVC.presentedViewController {
            topVC = presented
        }
        
        if let popover = av.popoverPresentationController {
            popover.sourceView = topVC.view
            popover.sourceRect = CGRect(x: topVC.view.bounds.midX, y: topVC.view.bounds.midY, width: 0, height: 0)
            popover.permittedArrowDirections = []
        }
        
        topVC.present(av, animated: true)
    }
}
