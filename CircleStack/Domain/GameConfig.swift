//
//  GameConfig.swift
//  CircleStack
//
//  Created by Moein on 27/07/2026.
//

import SwiftUI
import SpriteKit

struct DiscSkin: Identifiable, Codable, Equatable {
    var id: String
    var name: String
    var primaryColorHex: String
    var secondaryColorHex: String // Darker color for 3D extrusion side
    var glowColorHex: String
    var requiredHighScore: Int
    
    var primaryColor: Color { Color(hex: primaryColorHex) }
    var secondaryColor: Color { Color(hex: secondaryColorHex) }
    var glowColor: Color { Color(hex: glowColorHex) }
    
    var skPrimaryColor: SKColor { SKColor(hex: primaryColorHex) }
    var skSecondaryColor: SKColor { SKColor(hex: secondaryColorHex) }
    var skGlowColor: SKColor { SKColor(hex: glowColorHex) }

    /// Where on the colour wheel a run using this skin starts.
    var baseHue: CGFloat { skPrimaryColor.hueComponent }
}

/// The three tones one disc is drawn with.
struct DiscPalette {
    let hue: CGFloat
    let top: SKColor
    let side: SKColor
    let glow: SKColor
}

/// Colours come from the disc's position in the stack, never from the player's
/// score: each disc steps a little further around the wheel than the one below.
enum NeonPalette {
    /// Smooth balanced rainbow ramp every 100 discs.
    static let hueStep: CGFloat = 1.0 / 100.0

    static func palette(index: Int, baseHue: CGFloat, material: DiscMaterial? = nil) -> DiscPalette {
        // Some materials are a colour in their own right — gold that came out green
        // is not gold. Those ignore the run hue entirely.
        if let fixed = material?.fixedTint {
            return DiscPalette(hue: baseHue, top: fixed.top, side: fixed.side, glow: fixed.glow)
        }

        let hue = wrap(baseHue + CGFloat(index) * hueStep)
        return DiscPalette(
            hue: hue,
            // A lit sign reads as a saturated face with a near-white core, so the top
            // stays bright and the side drops hard: the contrast is what sells it.
            top: SKColor(hue: hue, saturation: 0.74, brightness: 1.0, alpha: 1.0),
            side: SKColor(hue: hue, saturation: 1.0, brightness: 0.40, alpha: 1.0),
            glow: SKColor(hue: hue, saturation: 0.42, brightness: 1.0, alpha: 1.0)
        )
    }

    /// The hue the backdrop should follow. Fixed-tint materials still let the run
    /// hue drive the sky, otherwise every wooden run would sit on the same brown.
    static func backdropHue(index: Int, baseHue: CGFloat) -> CGFloat {
        wrap(baseHue + CGFloat(index) * hueStep)
    }

    /// The colour a decorative element in the far background takes: the same family
    /// as the stack but a step round the wheel, so the backdrop is never flat.
    static func accent(hue: CGFloat, shift: CGFloat) -> SKColor {
        SKColor(hue: wrap(hue + shift), saturation: 0.62, brightness: 1.0, alpha: 1.0)
    }

    /// Dark neon backdrop, harmonized between the selected theme base and the active stack hue.
    static func backdrop(hue: CGFloat, base: BgTheme) -> (top: SKColor, bottom: SKColor) {
        let neonTop = SKColor(hue: hue, saturation: 0.85, brightness: 0.32, alpha: 1.0)
        let neonBottom = SKColor(hue: wrap(hue + 0.10), saturation: 0.90, brightness: 0.08, alpha: 1.0)
        return (base.skTopColor.blended(with: neonTop, amount: 0.50),
                base.skBottomColor.blended(with: neonBottom, amount: 0.50))
    }

    private static func wrap(_ hue: CGFloat) -> CGFloat {
        let h = hue.truncatingRemainder(dividingBy: 1.0)
        return h < 0 ? h + 1.0 : h
    }
}

struct BgTheme: Identifiable, Codable, Equatable {
    var id: String
    var name: String
    var topColorHex: String
    var bottomColorHex: String
    var requiredHighScore: Int
    
    var gradient: LinearGradient {
        LinearGradient(
            colors: [Color(hex: topColorHex), Color(hex: bottomColorHex)],
            startPoint: .top,
            endPoint: .bottom
        )
    }
    
    var skTopColor: SKColor { SKColor(hex: topColorHex) }
    var skBottomColor: SKColor { SKColor(hex: bottomColorHex) }
}

struct Achievement: Identifiable, Codable {
    var id: String
    var title: String
    var description: String
    var targetValue: Int
    var type: AchievementType
    
    enum AchievementType: String, Codable {
        case highScore
        case totalGames
        case comboStreak
    }
}

class GameConfig {
    static let baseWidth: CGFloat = 200.0
    static let baseThickness: CGFloat = 32.0 // thickness of discs, and how far each one lifts the stack
    static let perspectiveRatio: CGFloat = 0.65 // vertical scaling for top face

    /// Where a point on the ground plane lands on screen. The camera looks down at
    /// the stack, so depth is squashed by the same ratio the disc faces are.
    static func screenOffset(ground: CGPoint) -> CGPoint {
        CGPoint(x: ground.x, y: ground.y * perspectiveRatio)
    }

    /// The two directions a disc can slide in along, alternating disc by disc. They
    /// are the diagonals of the ground plane — perpendicular to each other down
    /// there, and on screen they run away-to-the-right and toward-the-right, so
    /// discs arrive at an angle instead of sliding flatly left and right.
    static let sweepAxes: [CGPoint] = [
        CGPoint(x: 0.7071, y: 0.7071),
        CGPoint(x: 0.7071, y: -0.7071)
    ]

    // Landing accuracy bands. Inside perfectTolerance the disc is snapped and
    // keeps its full width; anything wider gets sliced by the exact overlap error.
    static let perfectTolerance: CGFloat = 8.0
    static let goodTolerance: CGFloat = 22.0
    static let badTolerance: CGFloat = 45.0

    // Once the surviving overlap drops to this, the disc has nothing left to
    // stand on and the run ends.
    static let minDiscWidth: CGFloat = 8.0

    // Sweep motion of the incoming disc
    static let startSweepSpeed: CGFloat = 200.0
    static let sweepSpeedGrowth: CGFloat = 0.02 // per placed disc
    static let maxSweepSpeed: CGFloat = 560.0
    static let sweepRange: CGFloat = 240.0 // travel each side of the stack top, along the ground

    // Reward for a perfect streak: the disc starts growing back
    static let perfectRegrowCombo: Int = 3
    static let perfectRegrowAmount: CGFloat = 6.0

    // Camera. The view widens a little as the stack grows so the climb never feels
    // like it is racing up the screen.
    static let gameZoom: CGFloat = 1.10
    static let zoomGrowth: CGFloat = 0.004 // per placed disc
    static let maxGameZoom: CGFloat = 1.42
    static let maxShowcaseZoom: CGFloat = 2.0

    // Every skin and backdrop is available from the start: a skin sets the hue the
    // run *begins* on, and every disc after it shifts further around the wheel.
    static let skins: [DiscSkin] = [
        DiscSkin(id: "classic", name: "Classic Teal", primaryColorHex: "#00E5FF", secondaryColorHex: "#00838F", glowColorHex: "#00E5FF", requiredHighScore: 0),
        DiscSkin(id: "neon", name: "Neon Cyberpunk", primaryColorHex: "#FF007F", secondaryColorHex: "#880E4F", glowColorHex: "#FF007F", requiredHighScore: 0),
        DiscSkin(id: "gold", name: "Golden Royalty", primaryColorHex: "#FFD700", secondaryColorHex: "#B8860B", glowColorHex: "#FFD700", requiredHighScore: 0),
        DiscSkin(id: "ruby", name: "Ruby Flare", primaryColorHex: "#FF1744", secondaryColorHex: "#B71C1C", glowColorHex: "#FF1744", requiredHighScore: 0),
        DiscSkin(id: "holo", name: "Holographic Blue", primaryColorHex: "#7C4DFF", secondaryColorHex: "#311B92", glowColorHex: "#7C4DFF", requiredHighScore: 0)
    ]

    static let backgrounds: [BgTheme] = [
        BgTheme(id: "space", name: "Midnight Space", topColorHex: "#0A0A14", bottomColorHex: "#141428", requiredHighScore: 0),
        BgTheme(id: "aurora", name: "Green Aurora", topColorHex: "#051A15", bottomColorHex: "#0F2A38", requiredHighScore: 0),
        BgTheme(id: "sunset", name: "Neon Sunset", topColorHex: "#1F0A24", bottomColorHex: "#2C0C30", requiredHighScore: 0),
        BgTheme(id: "zen", name: "Zen Gray", topColorHex: "#1E2022", bottomColorHex: "#2B2D2F", requiredHighScore: 0)
    ]
    
    static let achievements: [Achievement] = [
        Achievement(id: "first_stack", title: "First Ascent", description: "Reach a score of 10", targetValue: 10, type: .highScore),
        Achievement(id: "stack_master", title: "Stack Master", description: "Reach a score of 30", targetValue: 30, type: .highScore),
        Achievement(id: "legendary", title: "Legendary Architect", description: "Reach a score of 50", targetValue: 50, type: .highScore),
        Achievement(id: "dedicated", title: "Dedicated Stacker", description: "Play 50 total games", targetValue: 50, type: .totalGames),
        Achievement(id: "perfect_streak", title: "Zen Harmony", description: "Get a combo of 7 Perfects", targetValue: 7, type: .comboStreak)
    ]
}

// Helper Color hex initializer
extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch hex.count {
        case 3: // RGB (12-bit)
            (a, r, g, b) = (255, (int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
        case 6: // RGB (24-bit)
            (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8: // ARGB (32-bit)
            (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default:
            (a, r, g, b) = (255, 0, 0, 0)
        }
        self.init(
            .sRGB,
            red: Double(r) / 255,
            green: Double(g) / 255,
            blue: Double(b) / 255,
            opacity: Double(a) / 255
        )
    }
}

extension SKColor {
    var hueComponent: CGFloat {
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        return h
    }

    /// Linear mix toward `other`; 0 keeps the receiver, 1 returns `other`.
    func blended(with other: SKColor, amount: CGFloat) -> SKColor {
        var r1: CGFloat = 0, g1: CGFloat = 0, b1: CGFloat = 0, a1: CGFloat = 0
        var r2: CGFloat = 0, g2: CGFloat = 0, b2: CGFloat = 0, a2: CGFloat = 0
        getRed(&r1, green: &g1, blue: &b1, alpha: &a1)
        other.getRed(&r2, green: &g2, blue: &b2, alpha: &a2)
        let t = max(0.0, min(1.0, amount))
        return SKColor(red: r1 + (r2 - r1) * t,
                       green: g1 + (g2 - g1) * t,
                       blue: b1 + (b2 - b1) * t,
                       alpha: a1 + (a2 - a1) * t)
    }

    convenience init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch hex.count {
        case 3: // RGB (12-bit)
            (a, r, g, b) = (255, (int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
        case 6: // RGB (24-bit)
            (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8: // ARGB (32-bit)
            (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default:
            (a, r, g, b) = (255, 0, 0, 0)
        }
        self.init(
            red: CGFloat(r) / 255.0,
            green: CGFloat(g) / 255.0,
            blue: CGFloat(b) / 255.0,
            alpha: CGFloat(a) / 255.0
        )
    }
}
