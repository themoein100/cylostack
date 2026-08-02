//
//  AppUpdateModal.swift
//  CircleStack
//
//  Created by Moein on 29/07/2026.
//

import SwiftUI

struct AppUpdateModal: View {
    @ObservedObject var remoteConfig = RemoteConfigManager.shared
    @Environment(\.colorScheme) var colorScheme

    var body: some View {
        ZStack {
            // Darkened backdrop
            Color.black.opacity(0.75)
                .ignoresSafeArea()
                .transition(.opacity)

            VStack(spacing: 20) {
                // Rocket Icon Badge
                ZStack {
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: [Color.blue.opacity(0.4), Color.purple.opacity(0.4)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 80, height: 80)
                        .blur(radius: 8)

                    Circle()
                        .fill(
                            LinearGradient(
                                colors: [Color.blue, Color.purple],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 68, height: 68)

                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 34, weight: .bold))
                        .foregroundColor(.white)
                }
                .padding(.top, 8)

                // Title & Version Badge
                VStack(spacing: 6) {
                    Text("UPDATE AVAILABLE")
                        .font(.system(size: 20, weight: .black, design: .rounded))
                        .foregroundColor(.white)

                    Text("Version \(remoteConfig.latestVersion)")
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundColor(.blue.opacity(0.9))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 4)
                        .background(Color.blue.opacity(0.2))
                        .cornerRadius(12)
                }

                // Description
                Text("A new version of CircleStack is available with exciting new features & improvements!")
                    .font(.system(size: 14, design: .rounded))
                    .foregroundColor(.white.opacity(0.8))
                    .multilineTextAlignment(.center)
                    .lineSpacing(4)
                    .padding(.horizontal, 8)

                // Action Buttons Stack
                VStack(spacing: 12) {
                    // 1. UPDATE NOW (Download App Store Link)
                    Button(action: {
                        let link = remoteConfig.appStoreURL.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !link.isEmpty,
                           let urlString = link.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
                           let url = URL(string: urlString),
                           UIApplication.shared.canOpenURL(url) {
                            UIApplication.shared.open(url)
                        } else {
                            // Fallback default App Store link if empty or invalid
                            if let fallbackURL = URL(string: "https://apps.apple.com") {
                                UIApplication.shared.open(fallbackURL)
                            }
                        }
                    }) {
                        HStack(spacing: 8) {
                            Image(systemName: "arrow.down.app.fill")
                                .font(.system(size: 16, weight: .bold))
                            Text("UPDATE NOW")
                                .font(.system(size: 15, weight: .black, design: .rounded))
                        }
                        .foregroundColor(.black)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(
                            LinearGradient(
                                colors: [Color(hex: "00FFCC"), Color(hex: "00CCFF")],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .cornerRadius(16)
                        .shadow(color: Color(hex: "00FFCC").opacity(0.4), radius: 10, y: 4)
                    }

                    // 2. LATER (Snooze 3 Days)
                    Button(action: {
                        withAnimation(.easeOut(duration: 0.25)) {
                            remoteConfig.snoozeUpdate(days: 3)
                        }
                    }) {
                        HStack(spacing: 6) {
                            Image(systemName: "clock.arrow.circlepath")
                                .font(.system(size: 14, weight: .semibold))
                            Text("Remind Me Later (3 Days)")
                                .font(.system(size: 14, weight: .bold, design: .rounded))
                        }
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(Color.white.opacity(0.12))
                        .cornerRadius(16)
                    }

                    // 3. CANCEL (Snooze 2 Days)
                    Button(action: {
                        withAnimation(.easeOut(duration: 0.25)) {
                            remoteConfig.snoozeUpdate(days: 2)
                        }
                    }) {
                        Text("Cancel (Remind in 2 Days)")
                            .font(.system(size: 13, weight: .semibold, design: .rounded))
                            .foregroundColor(.white.opacity(0.6))
                            .padding(.vertical, 4)
                    }

                    // 4. Privacy Policy Link (Optional)
                    if !remoteConfig.privacyURL.isEmpty {
                        Button(action: {
                            if let urlString = remoteConfig.privacyURL.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
                               let url = URL(string: urlString),
                               UIApplication.shared.canOpenURL(url) {
                                UIApplication.shared.open(url)
                            }
                        }) {
                            HStack(spacing: 4) {
                                Image(systemName: "lock.shield.fill")
                                    .font(.system(size: 11))
                                Text("Privacy Policy")
                                    .font(.system(size: 11, weight: .medium, design: .rounded))
                                    .underline()
                            }
                            .foregroundColor(.white.opacity(0.45))
                            .padding(.top, 4)
                        }
                    }
                }
                .padding(.top, 8)
            }
            .padding(24)
            .background(
                ZStack {
                    RoundedRectangle(cornerRadius: 28, style: .continuous)
                        .fill(Color(hex: "12131A"))

                    RoundedRectangle(cornerRadius: 28, style: .continuous)
                        .stroke(
                            LinearGradient(
                                colors: [Color.white.opacity(0.25), Color.blue.opacity(0.3)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 1.5
                        )
                }
            )
            .padding(.horizontal, 28)
            .shadow(color: .black.opacity(0.6), radius: 30, y: 15)
        }
    }
}
