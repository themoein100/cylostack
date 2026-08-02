//
//  GameCenterManager.swift
//  CircleStack
//
//  Created by Moein on 28/07/2026.
//

import GameKit
import SwiftUI
import Combine

class GameCenterManager: NSObject, ObservableObject {
    static let shared = GameCenterManager()

    @Published var isAuthenticated = false
    @Published var authViewController: UIViewController?

    override private init() {
        super.init()
    }

    /// Authenticates the local player with Apple Game Center.
    /// If the player is not signed in, it returns a view controller to present.
    func authenticateLocalPlayer() {
        let localPlayer = GKLocalPlayer.local
        
        localPlayer.authenticateHandler = { [weak self] viewController, error in
            guard let self = self else { return }
            
            if let viewController = viewController {
                // Store the view controller so the app can present the Game Center sign-in screen
                DispatchQueue.main.async {
                    self.authViewController = viewController
                }
            } else if localPlayer.isAuthenticated {
                // Player is successfully authenticated
                DispatchQueue.main.async {
                    self.isAuthenticated = true
                    self.authViewController = nil
                    self.syncProfileFromGameCenter()
                }
                Logger.shared.i("GameCenter", "Player authenticated successfully: \(localPlayer.displayName) (ID: \(localPlayer.gamePlayerID))")
            } else {
                // Authentication failed or was disabled
                DispatchQueue.main.async {
                    self.isAuthenticated = false
                    self.authViewController = nil
                }
                if let error = error {
                    Logger.shared.e("GameCenter", "Authentication error: \(error.localizedDescription)")
                } else {
                    Logger.shared.w("GameCenter", "Authentication failed without error (Game Center may be disabled in Settings)")
                }
            }
        }
    }

    /// Fetches the authenticated player's Game Center profile details (display name and avatar) and updates PlayerStore.
    func syncProfileFromGameCenter() {
        let localPlayer = GKLocalPlayer.local
        guard localPlayer.isAuthenticated else { return }

        let store = PlayerStore.shared
        let gcName = localPlayer.displayName

        DispatchQueue.main.async {
            if store.displayName.isEmpty || store.displayName == "Player" || store.firstName.isEmpty {
                store.displayName = gcName
                let nameComponents = gcName.components(separatedBy: " ")
                if nameComponents.count > 1 {
                    store.firstName = nameComponents.first ?? ""
                    store.lastName = nameComponents.dropFirst().joined(separator: " ")
                } else {
                    store.firstName = gcName
                }
                Logger.shared.i("GameCenter", "Synced display name from Game Center: \(gcName)")
            }
        }

        // Only adopt the Game Center photo when the player has not chosen one of their
        // own. Without this guard every launch overwrites their picture — and because
        // Game Center hands back a default grey silhouette (not nil) for accounts with
        // no photo, that overwrite looks exactly like the chosen photo being erased.
        guard store.avatarData == nil else {
            Logger.shared.i("GameCenter", "Keeping player's own avatar; skipping Game Center photo")
            return
        }

        localPlayer.loadPhoto(for: .normal) { image, error in
            if let image = image {
                DispatchQueue.main.async {
                    // Re-check on the main actor: the player may have set a photo while
                    // the async load was in flight.
                    guard store.avatarData == nil else { return }
                    store.setAvatar(image)
                    Logger.shared.i("GameCenter", "Synced avatar photo from Game Center")
                }
            }
        }
    }

    /// Submits a high score to a specific Game Center leaderboard.
    func submitScore(_ score: Int, to leaderboardID: String) {
        guard isAuthenticated else {
            Logger.shared.w("GameCenter", "Cannot submit score \(score): Player not authenticated.")
            return
        }

        Logger.shared.i("GameCenter", "Submitting score \(score) to leaderboard: \(leaderboardID)")

        GKLeaderboard.submitScore(score, context: 0, player: GKLocalPlayer.local, leaderboardIDs: [leaderboardID]) { error in
            if let error = error {
                Logger.shared.e("GameCenter", "Failed to submit score to \(leaderboardID): \(error.localizedDescription)")
            } else {
                Logger.shared.i("GameCenter", "Successfully submitted score \(score) to \(leaderboardID)")
            }
        }
    }

    // MARK: - Programmatic Leaderboards

    struct LeaderboardEntry: Identifiable {
        let id = UUID()
        let rank: Int
        let displayName: String
        let score: Int
        var avatarImage: UIImage?
    }

    @Published var topEntries: [LeaderboardEntry] = []
    @Published var isLoadingScores = false

    /// Fetches the top 10 players from the Game Center leaderboard.
    func fetchTopScores(leaderboardID: String = "cylostack_leaderboard") {
        guard isAuthenticated else {
            Logger.shared.w("GameCenter", "Cannot fetch scores: Player not authenticated.")
            DispatchQueue.main.async {
                self.topEntries = []
                self.isLoadingScores = false
            }
            return
        }

        DispatchQueue.main.async {
            self.isLoadingScores = true
        }

        GKLeaderboard.loadLeaderboards(IDs: [leaderboardID]) { [weak self] leaderboards, error in
            guard let self = self else { return }

            if let error = error {
                Logger.shared.e("GameCenter", "Failed to load leaderboard: \(error.localizedDescription)")
                DispatchQueue.main.async {
                    self.topEntries = []
                    self.isLoadingScores = false
                }
                return
            }

            guard let leaderboard = leaderboards?.first else {
                Logger.shared.w("GameCenter", "Leaderboard \(leaderboardID) not found.")
                DispatchQueue.main.async {
                    self.topEntries = []
                    self.isLoadingScores = false
                }
                return
            }

            leaderboard.loadEntries(for: .global, timeScope: .allTime, range: NSRange(location: 1, length: 10)) { [weak self] localPlayerEntry, entries, totalPlayerCount, error in
                guard let self = self else { return }

                if let error = error {
                    Logger.shared.e("GameCenter", "Failed to load entries: \(error.localizedDescription)")
                    DispatchQueue.main.async {
                        self.topEntries = []
                        self.isLoadingScores = false
                    }
                    return
                }

                guard let entries = entries, !entries.isEmpty else {
                    Logger.shared.i("GameCenter", "No entries returned from Game Center.")
                    
                    // If no entries in global list but we have the local player's entry, show just the local player!
                    if let localEntry = localPlayerEntry {
                        let localModel = LeaderboardEntry(
                            rank: localEntry.rank,
                            displayName: localEntry.player.displayName,
                            score: localEntry.score,
                            avatarImage: nil
                        )
                        
                        // Load photo for local player
                        localEntry.player.loadPhoto(for: .small) { [localModel] image, _ in
                            var entryWithPhoto = localModel
                            if let image = image {
                                entryWithPhoto.avatarImage = image
                            }
                            DispatchQueue.main.async {
                                self.topEntries = [entryWithPhoto]
                                self.isLoadingScores = false
                            }
                        }
                    } else {
                        DispatchQueue.main.async {
                            self.topEntries = []
                            self.isLoadingScores = false
                        }
                    }
                    return
                }

                var fetchedEntries: [LeaderboardEntry] = []
                let group = DispatchGroup()

                for entry in entries {
                    group.enter()
                    
                    let newEntry = LeaderboardEntry(
                        rank: entry.rank,
                        displayName: entry.player.displayName,
                        score: entry.score,
                        avatarImage: nil
                    )

                    entry.player.loadPhoto(for: .small) { image, _ in
                        var entryWithPhoto = newEntry
                        if let image = image {
                            entryWithPhoto.avatarImage = image
                        }
                        DispatchQueue.main.async {
                            fetchedEntries.append(entryWithPhoto)
                            group.leave()
                        }
                    }
                }

                group.notify(queue: .main) {
                    self.topEntries = fetchedEntries.sorted(by: { $0.rank < $1.rank })
                    self.isLoadingScores = false
                }
            }
        }
    }
}

/// A SwiftUI wrapper view to display the native Game Center Leaderboard dashboard.
struct GameCenterLeaderboardView: UIViewControllerRepresentable {
    let leaderboardID: String?
    @Environment(\.presentationMode) var presentationMode

    func makeUIViewController(context: Context) -> GKGameCenterViewController {
        let gkVC: GKGameCenterViewController
        if let leaderboardID = leaderboardID {
            gkVC = GKGameCenterViewController(leaderboardID: leaderboardID, playerScope: .global, timeScope: .allTime)
        } else {
            gkVC = GKGameCenterViewController(state: .leaderboards)
        }
        gkVC.gameCenterDelegate = context.coordinator
        return gkVC
    }

    func updateUIViewController(_ uiViewController: GKGameCenterViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    class Coordinator: NSObject, GKGameCenterControllerDelegate {
        var parent: GameCenterLeaderboardView

        init(_ parent: GameCenterLeaderboardView) {
            self.parent = parent
        }

        func gameCenterViewControllerDidFinish(_ gameCenterViewController: GKGameCenterViewController) {
            parent.presentationMode.wrappedValue.dismiss()
        }
    }
}
