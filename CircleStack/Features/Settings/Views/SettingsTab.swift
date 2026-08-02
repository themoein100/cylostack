//
//  SettingsTab.swift
//  CircleStack
//
//  Created by Moein on 28/07/2026.
//

import SwiftUI

struct SettingsTab: View {
    @ObservedObject var store: PlayerStore
    @ObservedObject private var remoteConfig = RemoteConfigManager.shared

    var body: some View {
        ScrollView(showsIndicators: true) {
            VStack(spacing: 28) {
                header
                difficultySection
                recordsSection
                materialsSection
                // Legal lives in the app's Settings sheet, not in this tab — this tab
                // is only about how the game plays.
                Color.clear.frame(height: 90) // clears the floating tab bar
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
        }
        .applyScrollBounceBehavior()
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Game")
                    .font(.system(size: 30, weight: .black, design: .rounded))
                    .foregroundColor(.white)
                Text("Tune it, then go beat it")
                    .font(.system(.caption, design: .rounded))
                    .foregroundColor(.white.opacity(0.5))
            }
            Spacer()
            CoinBadge(coins: store.coins)
        }
    }

    // MARK: - Difficulty

    private var difficultySection: some View {
        Card(title: "Difficulty", subtitle: "Speed and shrink are linked — fast play needs real risk") {
            VStack(spacing: 22) {
                DifficultyDial(
                    title: "Disc speed",
                    valueName: store.settings.speedName,
                    level: $store.speedLevel,
                    icon: "speedometer",
                    allowedRange: 1...min(5, store.shrinkLevel + 2)
                )

                Divider().background(Color.white.opacity(0.08))

                DifficultyDial(
                    title: "Shrink rate",
                    valueName: store.settings.shrinkName,
                    level: $store.shrinkLevel,
                    icon: "arrow.down.right.and.arrow.up.left",
                    allowedRange: max(1, store.speedLevel - 2)...5
                )

                HStack(spacing: 6) {
                    Image(systemName: "trophy.fill")
                        .font(.caption2)
                        .foregroundColor(.yellow)
                    Text("Best here: \(store.currentBest)")
                        .font(.system(.caption, design: .rounded).weight(.semibold))
                        .foregroundColor(.white.opacity(0.75))
                    Spacer()
                }
            }
        }
    }

    // MARK: - Records

    private var recordsSection: some View {
        Card(title: "Records", subtitle: "Every combination keeps its own best") {
            VStack(spacing: 10) {
                HStack {
                    Text("SPEED")
                        .frame(width: 58, alignment: .leading)
                    ForEach(DifficultySettings.range, id: \.self) { shrink in
                        Text("\(shrink)")
                            .frame(maxWidth: .infinity)
                    }
                }
                .font(.system(size: 9, weight: .bold, design: .rounded))
                .foregroundColor(.white.opacity(0.4))

                ForEach(DifficultySettings.range, id: \.self) { speed in
                    HStack {
                        Text("\(speed)")
                            .font(.system(size: 11, weight: .bold, design: .rounded))
                            .foregroundColor(.white.opacity(0.4))
                            .frame(width: 58, alignment: .leading)

                        ForEach(DifficultySettings.range, id: \.self) { shrink in
                            let best = store.best(speed: speed, shrink: shrink)
                            let isCurrent = speed == store.speedLevel && shrink == store.shrinkLevel
                            Text(best == 0 ? "–" : "\(best)")
                                .font(.system(size: 13, weight: isCurrent ? .black : .semibold,
                                              design: .rounded).monospacedDigit())
                                .foregroundColor(best == 0 ? .white.opacity(0.22)
                                                 : (isCurrent ? .yellow : .white.opacity(0.8)))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 5)
                                .background(
                                    RoundedRectangle(cornerRadius: 7)
                                        .fill(isCurrent ? Color.yellow.opacity(0.14) : .clear)
                                )
                        }
                    }
                }

                Text("Rows are speed, columns are shrink rate.")
                    .font(.system(size: 10, design: .rounded))
                    .foregroundColor(.white.opacity(0.35))
                    .padding(.top, 2)
            }
        }
    }

    // MARK: - Materials

    private var materialsSection: some View {
        Card(title: "Discs", subtitle: "Earn coins by beating your own record") {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 12),
                                GridItem(.flexible(), spacing: 12)], spacing: 12) {
                ForEach(DiscMaterial.all) { material in
                    MaterialCard(
                        material: material,
                        isOwned: store.isUnlocked(material),
                        isSelected: store.selectedMaterialID == material.id,
                        canAfford: store.canAfford(material)
                    ) {
                        tap(material)
                    }
                }
            }
        }
    }

    private func tap(_ material: DiscMaterial) {
        if store.isUnlocked(material) {
            store.selectedMaterialID = material.id
            SoundManager.shared.playGood()
        } else if store.purchase(material) {
            SoundManager.shared.playPerfect()
        } else {
            SoundManager.shared.playBad()
        }
    }
}

// MARK: - Pieces

private struct Card<Content: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(.headline, design: .rounded).weight(.bold))
                    .foregroundColor(.white)
                Text(subtitle)
                    .font(.system(size: 11, design: .rounded))
                    .foregroundColor(.white.opacity(0.45))
            }
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background(Color.white.opacity(0.05))
        .cornerRadius(20)
        .overlay(
            RoundedRectangle(cornerRadius: 20)
                .stroke(Color.white.opacity(0.09), lineWidth: 1)
        )
    }
}

private struct DifficultyDial: View {
    let title: String
    let valueName: String
    @Binding var level: Int
    let icon: String
    var allowedRange: ClosedRange<Int> = 1...5

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.caption)
                    .foregroundColor(.cyan)
                Text(title)
                    .font(.system(.subheadline, design: .rounded).weight(.semibold))
                    .foregroundColor(.white)
                Spacer()
                Text(valueName)
                    .font(.system(.caption, design: .rounded).weight(.bold))
                    .foregroundColor(.cyan)
            }

            HStack(spacing: 8) {
                ForEach(DifficultySettings.range, id: \.self) { step in
                    let allowed = allowedRange.contains(step)
                    Button {
                        guard allowed else { return }
                        withAnimation(.spring(response: 0.28, dampingFraction: 0.75)) {
                            level = step
                        }
                        SoundManager.shared.playGood()
                    } label: {
                        ZStack {
                            Capsule()
                                .fill(step <= level
                                      ? (allowed ? Color.cyan : Color.orange.opacity(0.4))
                                      : Color.white.opacity(allowed ? 0.12 : 0.05))
                                .frame(height: 10)
                                .overlay(
                                    Capsule()
                                        .stroke(Color.white.opacity(step == level ? 0.9 : 0), lineWidth: 2)
                                )
                            if !allowed {
                                Image(systemName: "lock.fill")
                                    .font(.system(size: 7, weight: .bold))
                                    .foregroundColor(.white.opacity(0.35))
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .opacity(allowed ? 1.0 : 0.45)
                }
            }

            // Hint label when some steps are locked
            if allowedRange != 1...5 {
                HStack(spacing: 4) {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 9))
                    Text("Some levels locked — adjust the other dial first")
                        .font(.system(size: 10, design: .rounded))
                }
                .foregroundColor(.white.opacity(0.35))
            }
        }
    }
}



private struct MaterialCard: View {
    let material: DiscMaterial
    let isOwned: Bool
    let isSelected: Bool
    let canAfford: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 10) {
                DiscSwatch(material: material)
                    .frame(height: 58)

                VStack(spacing: 2) {
                    Text(material.name)
                        .font(.system(.subheadline, design: .rounded).weight(.bold))
                        .foregroundColor(.white)
                    Text(material.blurb)
                        .font(.system(size: 10, design: .rounded))
                        .foregroundColor(.white.opacity(0.45))
                        .lineLimit(1)
                }

                if isSelected {
                    Label("Equipped", systemImage: "checkmark")
                        .font(.system(size: 10, design: .rounded).weight(.bold))
                        .foregroundColor(.cyan)
                } else if isOwned {
                    Text("Tap to equip")
                        .font(.system(size: 10, design: .rounded).weight(.semibold))
                        .foregroundColor(.white.opacity(0.55))
                } else {
                    HStack(spacing: 4) {
                        Image(systemName: "circle.hexagongrid.fill")
                            .font(.system(size: 9))
                        Text("\(material.price)")
                            .font(.system(size: 11, design: .rounded).weight(.bold).monospacedDigit())
                    }
                    .foregroundColor(canAfford ? .yellow : .white.opacity(0.35))
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(Color.white.opacity(isSelected ? 0.10 : 0.04))
            .cornerRadius(16)
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .stroke(isSelected ? Color.cyan.opacity(0.7) : Color.white.opacity(0.08),
                            lineWidth: isSelected ? 1.5 : 1)
            )
            .opacity(isOwned || canAfford ? 1.0 : 0.55)
        }
        .buttonStyle(.plain)
    }
}
