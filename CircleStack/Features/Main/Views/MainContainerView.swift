//
//  MainContainerView.swift
//  CircleStack
//
//  Created by Moein on 27/07/2026.
//

import SwiftUI
import GameKit

struct MainContainerView: View {
    @StateObject private var store = PlayerStore.shared
    @StateObject private var gcManager = GameCenterManager.shared
    @ObservedObject private var remoteConfig = RemoteConfigManager.shared

    // UI control states
    @State private var selectedTab: AppTab = .play
    @State private var showSplash = true
    @State private var lastBackgroundTime: Date? = nil
    /// Raised by the game tab for the length of a run, so the bar can get out of the way.
    @State private var isRunActive = false
    @State private var tabResetID = UUID()

    enum AppTab: Hashable {
        case profile, play, settings
    }

    private var background: BgTheme { GameConfig.backgrounds[0] }

    var body: some View {
        ZStack {
            if #available(iOS 26.0, *) {
                glassTabs
            } else {
                legacyTabs
            }

            if showSplash {
                SplashView(isPresented: $showSplash)
                    .transition(.opacity)
            }

            // Onboarding sits above everything and only ever appears once
            if !store.hasOnboarded && !showSplash {
                OnboardingView(store: store)
                    .transition(.opacity)
            }

            // Remote App Update Modal
            if remoteConfig.isUpdateRequired && !showSplash {
                AppUpdateModal()
                    .transition(.opacity.combined(with: .scale(scale: 0.95)))
                    .zIndex(999)
            }
        }
        .animation(.easeInOut(duration: 0.3), value: remoteConfig.isUpdateRequired)
        .preferredColorScheme(.dark)
        .onAppear {
            gcManager.authenticateLocalPlayer()
        }
        .sheet(isPresented: Binding(
            get: { gcManager.authViewController != nil },
            set: { if !$0 { gcManager.authViewController = nil } }
        )) {
            if let authVC = gcManager.authViewController {
                ViewControllerRepresentable(viewController: authVC)
                    .ignoresSafeArea()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)) { _ in
            lastBackgroundTime = Date()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
            guard let lastBgTime = lastBackgroundTime else { return }
            let elapsed = Date().timeIntervalSince(lastBgTime)
            // Show splash and trigger App Open Ad if backgrounded for more than 30 seconds
            if elapsed >= 30.0 {
                if !showSplash {
                    withAnimation {
                        showSplash = true
                    }
                }
            }
            lastBackgroundTime = nil
        }
    }

    /// The themed gradient has to live inside each tab rather than behind the whole
    /// `TabView`: tab content is opaque, so anything painted behind it never shows.
    private func themed<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        ZStack {
            background.gradient.ignoresSafeArea()
            content()
        }
    }

    // MARK: - Tabs

    /// A plain `TabView` is what earns the real Liquid Glass bar: the system draws the
    /// material, the floating capsule, the selection morph and the scroll-edge
    /// behaviour, and it degrades correctly under Reduce Transparency and Increase
    /// Contrast. Painting `.glassEffect` onto a hand-built `HStack` would only ever be
    /// an impression of it, and Apple's guidance is to reach for that modifier for
    /// custom controls that have no system equivalent — a tab bar is not one.
    @available(iOS 26.0, *)
    private var glassTabs: some View {
        TabView(selection: $selectedTab) {
            Tab("Profile", systemImage: "person.fill", value: AppTab.profile) {
                profileTab
            }

            Tab("Play", systemImage: "gamecontroller.fill", value: AppTab.play) {
                // A run is full-screen and every tap is a placement, so the bar steps
                // aside rather than sitting under the stack waiting to be hit by
                // accident. This belongs on the tab's content, not on the TabView —
                // the bar reads the preference from whatever is currently on screen.
                playTab
                    .toolbarVisibility(isRunActive ? .hidden : .automatic, for: .tabBar)
            }

            Tab("Game", systemImage: "slider.horizontal.3", value: AppTab.settings) {
                settingsTab
            }
        }
        .tint(.cyan)
    }

    /// Pre-iOS 26 devices have no Liquid Glass to inherit, so they keep the hand-built
    /// floating bar this app shipped with.
    private var legacyTabs: some View {
        ZStack(alignment: .bottom) {
            Group {
                switch selectedTab {
                case .profile:  profileTab
                case .play:     playTab
                case .settings: settingsTab
                }
            }
            .id("\(selectedTab.hashValue)-\(tabResetID)")
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if !isRunActive {
                HStack(spacing: 8) {
                    TabBarButton(icon: "person.fill", title: "Profile",
                                 isSelected: selectedTab == .profile) { changeTab(to: .profile) }

                    TabBarButton(icon: "gamecontroller.fill", title: "Play",
                                 isSelected: selectedTab == .play) { changeTab(to: .play) }

                    TabBarButton(icon: "slider.horizontal.3", title: "Game",
                                 isSelected: selectedTab == .settings) { changeTab(to: .settings) }
                }
                .padding(.horizontal, 8)
                .frame(height: 60)
                .background(.ultraThinMaterial)
                .clipShape(Capsule())
                .overlay(
                    Capsule()
                        .stroke(Color.white.opacity(0.18), lineWidth: 1)
                )
                .shadow(color: Color.black.opacity(0.35), radius: 16, x: 0, y: 8)
                .padding(.horizontal, 24)
                .padding(.bottom, 16)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: isRunActive)
    }

    // MARK: - Tab content

    private var profileTab: some View {
        themed { ProfileTab(store: store) }
    }

    private var playTab: some View {
        themed {
            GameTab(store: store, selectedBg: background, isRunActive: $isRunActive)
        }
    }

    private var settingsTab: some View {
        themed { SettingsTab(store: store) }
    }

    private func changeTab(to tab: AppTab) {
        if selectedTab == tab {
            tabResetID = UUID()
            isRunActive = false
            return
        }
        isRunActive = false
        withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) {
            selectedTab = tab
            tabResetID = UUID()
        }
        SoundManager.shared.playGood()
    }
}

// MARK: - Helpers

struct ViewControllerRepresentable: UIViewControllerRepresentable {
    let viewController: UIViewController
    
    func makeUIViewController(context: Context) -> UIViewController {
        viewController
    }
    
    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {}
}
