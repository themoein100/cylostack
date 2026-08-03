//
//  LeaderboardCardView.swift
//  CircleStack
//
//  Created by Moein on 28/07/2026.
//

import SwiftUI

struct LeaderboardCardView: View {
    @ObservedObject private var gcManager = GameCenterManager.shared
    @State private var showFullLeaderboard = false

    var body: some View {
        VStack(spacing: 16) {
            // Header
            HStack {
                HStack(spacing: 8) {
                    Image(systemName: "trophy.fill")
                        .foregroundColor(.yellow)
                        .font(.system(size: 16, weight: .semibold))
                    Text("GLOBAL RANKINGS")
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .foregroundColor(.white.opacity(0.4))
                        .tracking(1.2)
                }
                
                Spacer()
                
                if gcManager.isAuthenticated {
                    Button(action: {
                        gcManager.fetchTopScores()
                    }) {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundColor(.cyan)
                    }
                    .disabled(gcManager.isLoadingScores)
                    .padding(.trailing, 8)
                }
                
                Button(action: {
                    showFullLeaderboard = true
                }) {
                    Text("Full List")
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .foregroundColor(.cyan)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Color.cyan.opacity(0.12))
                        .cornerRadius(8)
                }
            }
            
            // List of top players
            VStack(spacing: 0) {
                if !gcManager.isAuthenticated {
                    VStack(spacing: 12) {
                        Image(systemName: "gamecontroller.fill")
                            .font(.system(size: 28))
                            .foregroundColor(.white.opacity(0.15))
                        Text("Game Center Disconnected")
                            .font(.system(size: 13, weight: .bold, design: .rounded))
                            .foregroundColor(.white.opacity(0.6))
                        Text("Connect to see global real-time rankings")
                            .font(.system(size: 11, design: .rounded))
                            .foregroundColor(.white.opacity(0.35))
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 24)
                        
                        Button(action: {
                            gcManager.authenticateLocalPlayer()
                        }) {
                            Text("Connect Game Center")
                                .font(.system(size: 12, weight: .bold, design: .rounded))
                                .foregroundColor(.black)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 8)
                                .background(Color.cyan)
                                .cornerRadius(10)
                        }
                        .padding(.top, 4)
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 180)
                } else if gcManager.isLoadingScores && gcManager.topEntries.isEmpty {
                    VStack(spacing: 12) {
                        ProgressView()
                            .tint(.cyan)
                        Text("Loading leaderboards...")
                            .font(.system(size: 12, design: .rounded))
                            .foregroundColor(.white.opacity(0.4))
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 180)
                } else if gcManager.topEntries.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "xmark.seal.fill")
                            .font(.system(size: 24))
                            .foregroundColor(.white.opacity(0.2))
                        Text("No scores recorded yet")
                            .font(.system(size: 13, weight: .semibold, design: .rounded))
                            .foregroundColor(.white.opacity(0.5))
                        Text("Be the first to submit a high score!")
                            .font(.system(size: 11, design: .rounded))
                            .foregroundColor(.white.opacity(0.35))
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 150)
                } else {
                    VStack(spacing: 10) {
                        ForEach(gcManager.topEntries.prefix(5)) { entry in
                            LeaderboardRow(entry: entry)
                            
                            if entry.id != gcManager.topEntries.prefix(5).last?.id {
                                Divider()
                                    .background(Color.white.opacity(0.06))
                            }
                        }
                    }
                    .padding(14)
                    .background(Color.white.opacity(0.04))
                    .cornerRadius(18)
                }
            }
        }
        .onAppear {
            gcManager.fetchTopScores()
        }
        .sheet(isPresented: $showFullLeaderboard) {
            GameCenterLeaderboardView(leaderboardID: "cylostack_leaderboard")
                .ignoresSafeArea()
        }
    }
}

private struct LeaderboardRow: View {
    let entry: GameCenterManager.LeaderboardEntry

    var body: some View {
        HStack(spacing: 12) {
            // Rank Badge
            rankBadge(entry.rank)
            
            // Avatar
            if let avatar = entry.avatarImage {
                Image(uiImage: avatar)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 32, height: 32)
                    .clipShape(Circle())
                    .overlay(Circle().stroke(Color.white.opacity(0.12), lineWidth: 1))
            } else {
                ZStack {
                    Circle()
                        .fill(Color.white.opacity(0.08))
                        .frame(width: 32, height: 32)
                    Image(systemName: "person.fill")
                        .font(.system(size: 14))
                        .foregroundColor(.white.opacity(0.4))
                }
            }
            
            // Name
            Text(entry.displayName)
                .font(.system(size: 14, weight: .semibold, design: .rounded))
                .foregroundColor(.white)
                .lineLimit(1)
            
            Spacer()
            
            // Score
            Text("\(entry.score)")
                .font(.system(size: 16, weight: .bold, design: .rounded).monospacedDigit())
                .foregroundColor(rankColor(entry.rank))
        }
    }

    private func rankBadge(_ rank: Int) -> some View {
        ZStack {
            if rank <= 3 {
                Circle()
                    .fill(rankBadgeColor(rank).opacity(0.2))
                    .frame(width: 24, height: 24)
                
                Image(systemName: "trophy.fill")
                    .font(.system(size: 10))
                    .foregroundColor(rankBadgeColor(rank))
            } else {
                Circle()
                    .fill(Color.white.opacity(0.06))
                    .frame(width: 24, height: 24)
                
                Text("\(rank)")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundColor(.white.opacity(0.5))
            }
        }
    }

    private func rankBadgeColor(_ rank: Int) -> Color {
        switch rank {
        case 1:  return .yellow  // Gold
        case 2:  return .gray    // Silver
        case 3:  return .brown   // Bronze
        default: return .white.opacity(0.5)
        }
    }

    private func rankColor(_ rank: Int) -> Color {
        switch rank {
        case 1:  return .yellow
        case 2:  return .white.opacity(0.9)
        case 3:  return .orange.opacity(0.9)
        default: return .white.opacity(0.65)
        }
    }
}
