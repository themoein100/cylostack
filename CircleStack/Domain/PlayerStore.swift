//
//  PlayerStore.swift
//  CircleStack
//
//  Created by Moein on 28/07/2026.
//

import SwiftUI
import Combine

/// Everything the player accumulates: who they are, what they own, how hard they
/// like it, and how far they have got at each setting.
///
/// The game is entirely offline, so `UserDefaults` is the whole storage layer —
/// there is no account to sync to and nothing here leaves the device.
final class PlayerStore: ObservableObject {
    static let shared = PlayerStore()

    private let defaults = UserDefaults.standard

    // MARK: - Profile (every field optional by design)

    @Published var firstName: String { didSet { defaults.set(firstName, forKey: Key.firstName); updateDisplayName() } }
    @Published var lastName: String { didSet { defaults.set(lastName, forKey: Key.lastName); updateDisplayName() } }
    @Published var displayName: String { didSet { defaults.set(displayName, forKey: Key.name) } }
    @Published var email: String { didSet { defaults.set(email, forKey: Key.email) } }
    /// 0 means "not given" — the onboarding prompt can be skipped outright.
    @Published var age: Int { didSet { defaults.set(age, forKey: Key.age) } }
    @Published var avatarData: Data? { didSet { defaults.set(avatarData, forKey: Key.avatar) } }
    @Published var hasOnboarded: Bool { didSet { defaults.set(hasOnboarded, forKey: Key.onboarded) } }

    var avatarImage: UIImage? {
        avatarData.flatMap(UIImage.init(data:))
    }

    /// Stores a picked photo. Downscaled first: a full-resolution image in
    /// `UserDefaults` is a multi-megabyte read on every launch.
    func setAvatar(_ image: UIImage) {
        avatarData = image.scaledDown(to: 512).jpegData(compressionQuality: 0.85)
    }

    // MARK: - Currency

    @Published private(set) var coins: Int { didSet { defaults.set(coins, forKey: Key.coins) } }
    /// How many times the player has beaten their own record, ever. Drives the
    /// every-tenth bonus.
    @Published private(set) var recordsBeaten: Int { didSet { defaults.set(recordsBeaten, forKey: Key.records) } }
    @Published private(set) var coinAdClaimTimestamps: [Double] {
        didSet { defaults.set(coinAdClaimTimestamps, forKey: Key.coinAdClaims) }
    }

    var remainingCoinAdClaimsThisHour: Int {
        #if DEBUG
        return 999
        #else
        let now = Date().timeIntervalSince1970
        let recentClaims = coinAdClaimTimestamps.filter { now - $0 < 3600 }
        return max(0, 2 - recentClaims.count)
        #endif
    }

    var canEarnCoinFromAd: Bool {
        #if DEBUG
        return true
        #else
        return remainingCoinAdClaimsThisHour > 0
        #endif
    }

    func recordCoinAdClaim() {
        let now = Date().timeIntervalSince1970
        var updated = coinAdClaimTimestamps.filter { now - $0 < 3600 }
        updated.append(now)
        coinAdClaimTimestamps = updated
        coins += 1
        objectWillChange.send()
    }

    // MARK: - Ownership

    @Published private(set) var unlockedMaterialIDs: Set<String> {
        didSet { defaults.set(Array(unlockedMaterialIDs), forKey: Key.unlocked) }
    }
    @Published var selectedMaterialID: String { didSet { defaults.set(selectedMaterialID, forKey: Key.material) } }

    // MARK: - Difficulty

    /// Speed and shrink are coupled: a fast disc must carry meaningful miss
    /// penalties, so the player cannot exploit high speed with a forgiving shrink.
    /// Rule: |speed - shrink| <= 2  (i.e. minShrink = speed - 2, maxSpeed = shrink + 2)
    @Published var speedLevel: Int {
        didSet {
            defaults.set(speedLevel, forKey: Key.speed)
            // Pull shrink up if it has fallen too far below speed
            let floor = max(1, speedLevel - 2)
            if shrinkLevel < floor {
                shrinkLevel = floor
            }
        }
    }
    @Published var shrinkLevel: Int {
        didSet {
            defaults.set(shrinkLevel, forKey: Key.shrink)
            // Pull speed down if it has risen too far above shrink
            let ceiling = min(5, shrinkLevel + 2)
            if speedLevel > ceiling {
                speedLevel = ceiling
            }
        }
    }

    // MARK: - Records & stats

    @Published private(set) var bestScores: [String: Int] {
        didSet { defaults.set(bestScores, forKey: Key.bests) }
    }
    @Published private(set) var totalGames: Int { didSet { defaults.set(totalGames, forKey: Key.games) } }
    @Published private(set) var maxCombo: Int { didSet { defaults.set(maxCombo, forKey: Key.combo) } }
    @Published private(set) var lastScore: Int { didSet { defaults.set(lastScore, forKey: Key.last) } }
    @Published var lastRunHue: CGFloat { didSet { defaults.set(Double(lastRunHue), forKey: Key.lastHue) } }

    var themeAccentColor: Color {
        if let fixed = selectedMaterial.fixedTint {
            return Color(fixed.top)
        }
        let palette = NeonPalette.palette(index: 0, baseHue: lastRunHue, material: selectedMaterial)
        return Color(palette.top)
    }

    private init() {
        let fName = defaults.string(forKey: Key.firstName) ?? ""
        let lName = defaults.string(forKey: Key.lastName) ?? ""
        let dName = defaults.string(forKey: Key.name) ?? ""

        if fName.isEmpty && lName.isEmpty && !dName.isEmpty {
            let parts = dName.split(separator: " ", maxSplits: 1).map(String.init)
            self.firstName = parts.first ?? ""
            self.lastName = parts.count > 1 ? parts[1] : ""
            self.displayName = dName
        } else {
            self.firstName = fName
            self.lastName = lName
            let combined = [fName, lName].filter { !$0.isEmpty }.joined(separator: " ")
            self.displayName = combined.isEmpty ? dName : combined
        }

        email = defaults.string(forKey: Key.email) ?? ""
        age = defaults.integer(forKey: Key.age)
        avatarData = defaults.data(forKey: Key.avatar)
        hasOnboarded = defaults.bool(forKey: Key.onboarded)

        coins = defaults.integer(forKey: Key.coins)
        recordsBeaten = defaults.integer(forKey: Key.records)

        #if DEBUG
        // Reset hourly coin claim timer on every build/launch in DEBUG mode for fast testing
        defaults.removeObject(forKey: Key.coinAdClaims)
        coinAdClaimTimestamps = []
        #else
        coinAdClaimTimestamps = defaults.array(forKey: Key.coinAdClaims) as? [Double] ?? []
        #endif

        let stored = defaults.stringArray(forKey: Key.unlocked) ?? []
        unlockedMaterialIDs = Set(stored).union(DiscMaterial.freeIDs)
        selectedMaterialID = defaults.string(forKey: Key.material) ?? DiscMaterial.all[0].id

        // Levels are 1...5 and default to the middle of each axis.
        let storedSpeed = defaults.integer(forKey: Key.speed)
        let storedShrink = defaults.integer(forKey: Key.shrink)
        speedLevel = storedSpeed == 0 ? 3 : storedSpeed
        shrinkLevel = storedShrink == 0 ? 3 : storedShrink

        bestScores = defaults.dictionary(forKey: Key.bests) as? [String: Int] ?? [:]
        totalGames = defaults.integer(forKey: Key.games)
        maxCombo = defaults.integer(forKey: Key.combo)
        lastScore = defaults.integer(forKey: Key.last)
        gamesSinceRecord = defaults.integer(forKey: Key.dryStreak)
        let storedHue = defaults.double(forKey: Key.lastHue)
        lastRunHue = storedHue == 0 ? 0.52 : CGFloat(storedHue)

        migrateLegacyHighScoreIfNeeded()
    }

    // MARK: - Difficulty helpers

    var difficultyKey: String { Self.key(speed: speedLevel, shrink: shrinkLevel) }

    static func key(speed: Int, shrink: Int) -> String { "s\(speed)k\(shrink)" }

    var currentBest: Int { bestScores[difficultyKey] ?? 0 }

    func best(speed: Int, shrink: Int) -> Int {
        bestScores[Self.key(speed: speed, shrink: shrink)] ?? 0
    }

    /// The best run at any setting — what the profile shows when it needs one number.
    var overallBest: Int { bestScores.values.max() ?? 0 }

    /// How much a run at a given setting is worth relative to the easiest one.
    ///
    /// Rather than trust the raw 1...5 dial numbers, this reads the *actual* run
    /// parameters — top sweep speed and miss penalty — so the reward tracks how hard a
    /// mode genuinely plays and stays correct if that tuning ever changes. It is
    /// normalised so the easiest setting (Crawl / Forgiving) is exactly 1.0; the
    /// hardest reachable one (Frantic / Merciless) lands near 7.4. The two axes
    /// multiply rather than add, on purpose: climbing the hard settings — not grinding
    /// a tall stack on the gentle ones — is what moves you up the global board.
    static func difficultyMultiplier(speed: Int, shrink: Int) -> Double {
        let mode = DifficultySettings(speedLevel: speed, shrinkLevel: shrink)
        let easiest = DifficultySettings(speedLevel: 1, shrinkLevel: 1)
        let speedFactor = Double(mode.maxSweepSpeed / easiest.maxSweepSpeed)
        let shrinkFactor = Double(mode.shrinkFactor / easiest.shrinkFactor)
        return speedFactor * shrinkFactor
    }

    /// The player's global ranking score: their best at every setting, each scaled by
    /// `difficultyMultiplier`, then summed. It rewards breadth (doing well across many
    /// settings) and, far more, depth on the hard ones. This is both the number shown
    /// as "Master Points" and the value submitted to the global Game Center
    /// leaderboard, so what the player sees is exactly what ranks them.
    var totalWeightedScore: Int {
        var total = 0.0
        for speed in 1...5 {
            for shrink in 1...5 {
                let score = best(speed: speed, shrink: shrink)
                guard score > 0 else { continue }
                total += Double(score) * Self.difficultyMultiplier(speed: speed, shrink: shrink)
            }
        }
        return Int(total.rounded())
    }

    /// Sum of raw best scores achieved across all difficulty levels.
    var totalRawScore: Int {
        bestScores.values.reduce(0, +)
    }

    var settings: DifficultySettings {
        DifficultySettings(speedLevel: speedLevel, shrinkLevel: shrinkLevel)
    }

    // MARK: - Recording a run

    struct RunOutcome {
        var isRecord = false
        var coinsAwarded = 0
        var bonusAwarded = false
    }

    /// Persists a new personal best the instant it is reached, mid-run, straight to
    /// `UserDefaults` (the `bestScores` `didSet`). A record can therefore never be lost
    /// to a quit, a background, or a crash before the run formally ends. It touches
    /// nothing but the stored best — games played, coins and the every-tenth bonus are
    /// all settled once, in `recordRun`, when the run is actually over.
    func recordLiveScore(_ score: Int) {
        guard score > (bestScores[difficultyKey] ?? 0) else { return }
        bestScores[difficultyKey] = score
        Logger.shared.i("Store", "Live record saved: \(score) on \(difficultyKey)")
    }

    /// Files a finished run and pays out. Pass `bestBeforeRun` — the best that stood
    /// *before* this run began — so the payout is judged correctly even though
    /// `recordLiveScore` may already have raised the stored best during play. A coin
    /// for every personal best, and five more on every tenth — the milestone is what
    /// makes a long grind feel like it is going somewhere.
    @discardableResult
    func recordRun(score: Int, bestBeforeRun: Int) -> RunOutcome {
        totalGames += 1
        lastScore = score

        // Safety net: the live path normally saved this already, but if the run ended
        // without any score update firing, make sure the best still reflects it.
        if score > (bestScores[difficultyKey] ?? 0) {
            bestScores[difficultyKey] = score
        }

        var outcome = RunOutcome()

        guard score > bestBeforeRun else {
            settleDrySpell()
            return outcome
        }

        // A record clears the slate: the drought is over.
        gamesSinceRecord = 0

        recordsBeaten += 1
        outcome.isRecord = true
        outcome.coinsAwarded = 1

        if recordsBeaten % 10 == 0 {
            outcome.coinsAwarded += 5
            outcome.bonusAwarded = true
        }

        coins += outcome.coinsAwarded
        return outcome
    }

    // MARK: - Dry spells
    //
    // What happens between records, and deliberately without any announcement.
    // Nothing in the UI reports either side of this — the balance simply moves,
    // the way a wallet does. Surfacing it would turn a slow background pressure
    // into a scoreboard the player optimises against.
    //
    // The two halves are one mechanism. A run of games with no record slowly
    // costs, and the longer that run gets the likelier it is to pay instead:
    // persistence is what earns the payout, and it usually arrives before the
    // cost bites. Over eight recordless games the expected balance is very
    // slightly negative — enough to keep the shop meaningful, not enough to
    // feel like a punishment.

    /// Games played since the last personal best.
    @Published private(set) var gamesSinceRecord: Int {
        didSet { defaults.set(gamesSinceRecord, forKey: Key.dryStreak) }
    }

    /// One coin every eighth recordless game.
    private static let dryStreakCost = 8

    private func settleDrySpell() {
        gamesSinceRecord += 1

        // The two are independent on purpose. An earlier version reset the
        // counter whenever the payout landed, which meant the charge almost
        // never arrived — even a player who never set a record drifted upward.
        // The countdown now runs regardless of luck.
        if rollLuckyPayout() {
            coins += 2
        }

        guard gamesSinceRecord % Self.dryStreakCost == 0 else { return }
        // Never below zero: a player with nothing left has nothing to lose, and
        // a negative balance would break every affordability check downstream.
        coins = max(0, coins - 1)
    }

    /// Rises with the length of the drought, so the players putting the most in
    /// are the ones most likely to get something back. Tuned so eight recordless
    /// games come out slightly negative overall — a drift, not a penalty.
    private func rollLuckyPayout() -> Bool {
        guard gamesSinceRecord >= 3 else { return false }
        let chance = min(0.06, 0.02 + 0.005 * Double(gamesSinceRecord - 3))
        return Double.random(in: 0..<1) < chance
    }

    func spendCoins(_ amount: Int) -> Bool {
        guard coins >= amount else { return false }
        coins -= amount
        objectWillChange.send()
        return true
    }

    func registerPerfect(combo: Int) {
        if combo > maxCombo { maxCombo = combo }
    }

    // MARK: - Shop

    func isUnlocked(_ material: DiscMaterial) -> Bool {
        unlockedMaterialIDs.contains(material.id)
    }

    func canAfford(_ material: DiscMaterial) -> Bool {
        coins >= material.price
    }

    /// Buys and equips in one step — nobody unlocks a disc they did not want to use.
    @discardableResult
    func purchase(_ material: DiscMaterial) -> Bool {
        guard !isUnlocked(material), coins >= material.price else { return false }
        coins -= material.price
        unlockedMaterialIDs.insert(material.id)
        selectedMaterialID = material.id
        return true
    }

    var selectedMaterial: DiscMaterial {
        DiscMaterial.all.first { $0.id == selectedMaterialID } ?? DiscMaterial.all[0]
    }

    // MARK: - Legacy

    /// Earlier builds kept one global high score. Fold it into the current
    /// difficulty rather than throwing the player's history away.
    private func migrateLegacyHighScoreIfNeeded() {
        let legacy = defaults.integer(forKey: "circle_stack_high_score")
        guard legacy > 0 else { return }
        if legacy > (bestScores[difficultyKey] ?? 0) {
            bestScores[difficultyKey] = legacy
        }
        if totalGames == 0 {
            totalGames = defaults.integer(forKey: "circle_stack_total_games")
        }
        if maxCombo == 0 {
            maxCombo = defaults.integer(forKey: "circle_stack_max_combo")
        }
        defaults.removeObject(forKey: "circle_stack_high_score")
    }

    private func updateDisplayName() {
        let combined = [firstName, lastName].filter { !$0.isEmpty }.joined(separator: " ")
        if displayName != combined {
            displayName = combined
        }
    }

    private enum Key {
        static let firstName = "cs_first_name"
        static let lastName = "cs_last_name"
        static let name = "cs_name"
        static let email = "cs_email"
        static let age = "cs_age"
        static let avatar = "cs_avatar"
        static let onboarded = "cs_onboarded"
        static let coins = "cs_coins"
        static let records = "cs_records_beaten"
        static let coinAdClaims = "cs_coin_ad_claims"
        static let unlocked = "cs_unlocked_materials"
        static let material = "cs_selected_material"
        static let speed = "cs_speed_level"
        static let shrink = "cs_shrink_level"
        static let bests = "cs_best_scores"
        static let games = "cs_total_games"
        static let combo = "cs_max_combo"
        static let last = "cs_last_score"
        static let lastHue = "cs_last_run_hue"
        static let dryStreak = "cs_games_since_record"
    }
}

/// Turns the two 1...5 dials into the numbers the scene actually runs on.
struct DifficultySettings: Equatable {
    var speedLevel: Int
    var shrinkLevel: Int

    static let range = 1...5

    static let speedNames = ["Crawl", "Easy", "Normal", "Brisk", "Frantic"]
    static let shrinkNames = ["Forgiving", "Gentle", "Normal", "Harsh", "Merciless"]

    var speedName: String { Self.speedNames[clamped(speedLevel) - 1] }
    var shrinkName: String { Self.shrinkNames[clamped(shrinkLevel) - 1] }

    /// Sweep speed the disc starts a run at.
    var startSweepSpeed: CGFloat {
        [110.0, 155.0, 200.0, 260.0, 330.0][clamped(speedLevel) - 1]
    }

    /// How much faster it gets per placed disc.
    var sweepSpeedGrowth: CGFloat {
        [0.010, 0.015, 0.020, 0.026, 0.034][clamped(speedLevel) - 1]
    }

    var maxSweepSpeed: CGFloat {
        [340.0, 440.0, 560.0, 690.0, 840.0][clamped(speedLevel) - 1]
    }

    /// Multiplies the width lost on a miss. Below 1 the disc survives sloppy play;
    /// above 1 a single bad drop can end the run.
    var shrinkFactor: CGFloat {
        [0.55, 0.75, 1.0, 1.3, 1.65][clamped(shrinkLevel) - 1]
    }

    private func clamped(_ value: Int) -> Int {
        min(max(value, Self.range.lowerBound), Self.range.upperBound)
    }
}

/// Coin counts get long. Shorten them the way every store UI does, so the badge
/// never has to grow to fit.
func formatCoins(_ value: Int) -> String {
    switch value {
    case ..<1_000:
        return "\(value)"
    case ..<1_000_000:
        let thousands = Double(value) / 1_000
        return thousands < 10
            ? String(format: "%.1fK", thousands).replacingOccurrences(of: ".0K", with: "K")
            : "\(Int(thousands))K"
    default:
        let millions = Double(value) / 1_000_000
        return millions < 10
            ? String(format: "%.1fM", millions).replacingOccurrences(of: ".0M", with: "M")
            : "\(Int(millions))M"
    }
}
