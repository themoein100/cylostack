//
//  DiscMaterial.swift
//  CircleStack
//
//  Created by Moein on 28/07/2026.
//

import SpriteKit
import UIKit

/// What a disc is made of.
///
/// Every material is authored as a **greyscale** pattern and tinted at draw time by
/// whatever hue the current run rolled. That keeps the two ideas independent: the
/// run picks a colour, the material decides how the surface breaks that colour up.
/// A handful of materials opt out with `fixedTint` — gold has to look like gold, not
/// like whatever hue came up.
struct DiscMaterial: Identifiable, Equatable {
    let id: String
    let name: String
    let blurb: String
    let price: Int
    let pattern: Pattern
    /// When set, the material ignores the run hue and paints itself.
    let fixedTint: FixedTint?

    enum Pattern: String {
        case matte, gloss, wood, marble, brushed, carbon, ice, stone, ceramic, holo, circuit, lava
    }

    struct FixedTint: Equatable {
        let top: SKColor
        let side: SKColor
        let glow: SKColor
    }

    static func == (a: DiscMaterial, b: DiscMaterial) -> Bool { a.id == b.id }

    var isFree: Bool { price == 0 }

    static let all: [DiscMaterial] = [
        DiscMaterial(id: "matte", name: "Matte", blurb: "The classic flat finish.",
                     price: 0, pattern: .matte, fixedTint: nil),
        DiscMaterial(id: "gloss", name: "Plastic", blurb: "Injection-moulded shine.",
                     price: 0, pattern: .gloss, fixedTint: nil),
        DiscMaterial(id: "wood", name: "Oak", blurb: "Cut across the grain.",
                     price: 12, pattern: .wood,
                     fixedTint: FixedTint(top: SKColor(hex: "#C89B62"),
                                          side: SKColor(hex: "#6E4A24"),
                                          glow: SKColor(hex: "#E8C79A"))),
        DiscMaterial(id: "ceramic", name: "Ceramic", blurb: "Glazed and fired.",
                     price: 18, pattern: .ceramic, fixedTint: nil),
        DiscMaterial(id: "stone", name: "Concrete", blurb: "Poured and ground flat.",
                     price: 24, pattern: .stone,
                     fixedTint: FixedTint(top: SKColor(hex: "#B9BCC0"),
                                          side: SKColor(hex: "#5E6266"),
                                          glow: SKColor(hex: "#D6D9DD"))),
        DiscMaterial(id: "ice", name: "Ice", blurb: "Frozen clear through.",
                     price: 32, pattern: .ice, fixedTint: nil),
        DiscMaterial(id: "marble", name: "Marble", blurb: "Veined and polished.",
                     price: 40, pattern: .marble,
                     fixedTint: FixedTint(top: SKColor(hex: "#EFEFF2"),
                                          side: SKColor(hex: "#8D8E99"),
                                          glow: SKColor(hex: "#FFFFFF"))),
        DiscMaterial(id: "brushed", name: "Brushed Steel", blurb: "Spun under an abrasive.",
                     price: 50, pattern: .brushed,
                     fixedTint: FixedTint(top: SKColor(hex: "#C6CDD6"),
                                          side: SKColor(hex: "#5A6068"),
                                          glow: SKColor(hex: "#EEF3F8"))),
        DiscMaterial(id: "carbon", name: "Carbon", blurb: "Woven twill weave.",
                     price: 65, pattern: .carbon,
                     fixedTint: FixedTint(top: SKColor(hex: "#4A4E55"),
                                          side: SKColor(hex: "#1C1E22"),
                                          glow: SKColor(hex: "#8B93A0"))),
        DiscMaterial(id: "circuit", name: "Circuit", blurb: "Etched and traced.",
                     price: 80, pattern: .circuit, fixedTint: nil),
        DiscMaterial(id: "lava", name: "Magma", blurb: "Cooling crust, hot seams.",
                     price: 100, pattern: .lava,
                     fixedTint: FixedTint(top: SKColor(hex: "#FF7A2F"),
                                          side: SKColor(hex: "#5E1607"),
                                          glow: SKColor(hex: "#FFD08A"))),
        DiscMaterial(id: "holo", name: "Hologram", blurb: "Splits the light.",
                     price: 140, pattern: .holo, fixedTint: nil)
    ]

    static var freeIDs: Set<String> {
        Set(all.filter(\.isFree).map(\.id))
    }
}

// MARK: - Texture generation

/// Builds and caches one greyscale texture per pattern.
///
/// The patterns are drawn once and reused by every disc on screen: they are tinted
/// through `SKShapeNode.fillColor`, which multiplies the texture, so a single
/// greyscale sheet serves every colour a run can roll.
enum MaterialTexture {
    private static var faceCache: [String: SKTexture] = [:]
    private static var sideCache: [String: SKTexture] = [:]
    private static var faceImages: [String: UIImage] = [:]
    private static var sideImages: [String: UIImage] = [:]

    private static let faceSize = CGSize(width: 220, height: 220)
    private static let sideSize = CGSize(width: 220, height: 64)

    static func face(_ pattern: DiscMaterial.Pattern) -> SKTexture {
        if let cached = faceCache[pattern.rawValue] { return cached }
        let texture = SKTexture(image: faceImage(pattern))
        faceCache[pattern.rawValue] = texture
        return texture
    }

    /// The same sheets as UIKit images, so SwiftUI can draw a disc that matches the
    /// one in the scene exactly rather than approximating it.
    static func faceImage(_ pattern: DiscMaterial.Pattern) -> UIImage {
        if let cached = faceImages[pattern.rawValue] { return cached }
        let image = renderFace(pattern)
        faceImages[pattern.rawValue] = image
        return image
    }

    static func sideImage(_ pattern: DiscMaterial.Pattern) -> UIImage {
        if let cached = sideImages[pattern.rawValue] { return cached }
        let image = renderSide(pattern)
        sideImages[pattern.rawValue] = image
        return image
    }

    /// The side reuses the same character but with a left-to-right falloff baked in,
    /// which is what gives the extrusion its rounded read.
    static func side(_ pattern: DiscMaterial.Pattern) -> SKTexture {
        if let cached = sideCache[pattern.rawValue] { return cached }
        let texture = SKTexture(image: sideImage(pattern))
        sideCache[pattern.rawValue] = texture
        return texture
    }

    // MARK: Face

    private static func renderFace(_ pattern: DiscMaterial.Pattern) -> UIImage {
        let size = faceSize
        let format = UIGraphicsImageRendererFormat.default()
        format.opaque = true
        return UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            let cg = ctx.cgContext
            UIColor.white.setFill()
            cg.fill(CGRect(origin: .zero, size: size))

            switch pattern {
            case .matte:
                break // a flat sheet is the whole point

            case .gloss:
                sweep(cg, size: size, stops: [(0.0, 1.0), (0.32, 0.86), (0.5, 1.0), (0.72, 0.8), (1.0, 0.92)])

            case .wood:
                grain(cg, size: size)

            case .marble:
                veins(cg, size: size)

            case .brushed:
                brushed(cg, size: size)

            case .carbon:
                weave(cg, size: size)

            case .ice:
                shards(cg, size: size)

            case .stone:
                speckle(cg, size: size, density: 2600, spread: 0.30)

            case .ceramic:
                sweep(cg, size: size, stops: [(0.0, 1.0), (0.55, 0.9), (1.0, 0.97)])
                speckle(cg, size: size, density: 420, spread: 0.06)

            case .holo:
                bands(cg, size: size)

            case .circuit:
                traces(cg, size: size)

            case .lava:
                crust(cg, size: size)
            }
        }
    }

    private static func renderSide(_ pattern: DiscMaterial.Pattern) -> UIImage {
        let size = sideSize
        let format = UIGraphicsImageRendererFormat.default()
        format.opaque = true
        return UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            let cg = ctx.cgContext

            // Material character first...
            UIColor.white.setFill()
            cg.fill(CGRect(origin: .zero, size: size))
            switch pattern {
            case .wood:     verticalGrain(cg, size: size)
            case .brushed:  brushed(cg, size: size)
            case .carbon:   weave(cg, size: size)
            case .stone:    speckle(cg, size: size, density: 900, spread: 0.26)
            case .marble:   veins(cg, size: size)
            case .lava:     crust(cg, size: size)
            case .circuit:  speckle(cg, size: size, density: 200, spread: 0.12)
            case .holo:     bands(cg, size: size)
            default:        break
            }

            // ...then the lighting falloff that makes the rim read as curved.
            cg.setBlendMode(.multiply)
            let colors = [UIColor(white: 1.0, alpha: 1.0).cgColor,
                          UIColor(white: 0.62, alpha: 1.0).cgColor,
                          UIColor(white: 0.44, alpha: 1.0).cgColor] as CFArray
            if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                         colors: colors, locations: [0.0, 0.62, 1.0]) {
                cg.drawLinearGradient(gradient, start: .zero,
                                      end: CGPoint(x: size.width, y: 0), options: [])
            }
        }
    }

    // MARK: Pattern primitives

    private static func sweep(_ cg: CGContext, size: CGSize, stops: [(CGFloat, CGFloat)]) {
        let colors = stops.map { UIColor(white: $0.1, alpha: 1.0).cgColor } as CFArray
        let locations = stops.map { $0.0 }
        guard let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                        colors: colors, locations: locations) else { return }
        cg.drawLinearGradient(gradient,
                              start: CGPoint(x: 0, y: 0),
                              end: CGPoint(x: size.width, y: size.height),
                              options: [])
    }

    private static func grain(_ cg: CGContext, size: CGSize) {
        var generator = SeededRandom(seed: 7)
        var y: CGFloat = 0
        while y < size.height {
            let thickness = generator.next(in: 1.5...5.0)
            let shade = generator.next(in: 0.72...0.99)
            UIColor(white: shade, alpha: 1.0).setFill()
            // A slight wobble per row is what stops it reading as printed stripes.
            let wobble = generator.next(in: -3.0...3.0)
            cg.fill(CGRect(x: wobble, y: y, width: size.width + 6, height: thickness))
            y += thickness + generator.next(in: 0.5...2.5)
        }
        for _ in 0..<3 {
            let cx = generator.next(in: 0...size.width)
            let cy = generator.next(in: 0...size.height)
            UIColor(white: 0.66, alpha: 0.5).setStroke()
            let knot = UIBezierPath(ovalIn: CGRect(x: cx - 14, y: cy - 5, width: 28, height: 10))
            knot.lineWidth = 2
            knot.stroke()
        }
    }

    private static func verticalGrain(_ cg: CGContext, size: CGSize) {
        var generator = SeededRandom(seed: 11)
        var x: CGFloat = 0
        while x < size.width {
            let thickness = generator.next(in: 1.0...3.5)
            UIColor(white: generator.next(in: 0.74...1.0), alpha: 1.0).setFill()
            cg.fill(CGRect(x: x, y: 0, width: thickness, height: size.height))
            x += thickness + generator.next(in: 0.4...1.6)
        }
    }

    private static func veins(_ cg: CGContext, size: CGSize) {
        var generator = SeededRandom(seed: 23)
        for _ in 0..<7 {
            let path = UIBezierPath()
            var point = CGPoint(x: generator.next(in: -20...size.width),
                                y: generator.next(in: -20...20))
            path.move(to: point)
            while point.y < size.height + 20 {
                point = CGPoint(x: point.x + generator.next(in: -26...26),
                                y: point.y + generator.next(in: 18...36))
                path.addLine(to: point)
            }
            UIColor(white: generator.next(in: 0.66...0.86), alpha: 0.9).setStroke()
            path.lineWidth = generator.next(in: 1.0...3.5)
            path.lineJoinStyle = .round
            path.stroke()
        }
    }

    private static func brushed(_ cg: CGContext, size: CGSize) {
        var generator = SeededRandom(seed: 41)
        for _ in 0..<380 {
            let y = generator.next(in: 0...size.height)
            let shade = generator.next(in: 0.78...1.0)
            UIColor(white: shade, alpha: 0.55).setFill()
            cg.fill(CGRect(x: generator.next(in: -40...size.width), y: y,
                           width: generator.next(in: 40...size.width), height: 1))
        }
        sweep(cg, size: size, stops: [(0.0, 1.0), (0.45, 0.82), (0.55, 1.0), (1.0, 0.86)])
    }

    private static func weave(_ cg: CGContext, size: CGSize) {
        let cell: CGFloat = 11
        var row = 0
        var y: CGFloat = 0
        while y < size.height {
            var col = 0
            var x: CGFloat = 0
            while x < size.width {
                let lit = (row + col) % 2 == 0
                UIColor(white: lit ? 0.95 : 0.66, alpha: 1.0).setFill()
                cg.fill(CGRect(x: x, y: y, width: cell, height: cell))
                x += cell
                col += 1
            }
            y += cell
            row += 1
        }
    }

    private static func shards(_ cg: CGContext, size: CGSize) {
        var generator = SeededRandom(seed: 59)
        for _ in 0..<26 {
            let path = UIBezierPath()
            let origin = CGPoint(x: generator.next(in: 0...size.width),
                                 y: generator.next(in: 0...size.height))
            path.move(to: origin)
            for _ in 0..<3 {
                path.addLine(to: CGPoint(x: origin.x + generator.next(in: -46...46),
                                         y: origin.y + generator.next(in: -46...46)))
            }
            path.close()
            UIColor(white: generator.next(in: 0.84...1.0), alpha: 0.5).setFill()
            path.fill()
            UIColor(white: 1.0, alpha: 0.7).setStroke()
            path.lineWidth = 1
            path.stroke()
        }
    }

    private static func speckle(_ cg: CGContext, size: CGSize, density: Int, spread: CGFloat) {
        var generator = SeededRandom(seed: 71)
        for _ in 0..<density {
            let shade = 1.0 - generator.next(in: 0...spread)
            UIColor(white: shade, alpha: 1.0).setFill()
            let radius = generator.next(in: 0.6...2.2)
            cg.fillEllipse(in: CGRect(x: generator.next(in: 0...size.width),
                                      y: generator.next(in: 0...size.height),
                                      width: radius, height: radius))
        }
    }

    private static func bands(_ cg: CGContext, size: CGSize) {
        // Alternating light steps read as iridescence once the run hue tints them.
        let shades: [CGFloat] = [1.0, 0.72, 0.92, 0.58, 0.86, 0.66]
        let width: CGFloat = 16
        var index = 0
        var x = -size.height
        while x < size.width {
            UIColor(white: shades[index % shades.count], alpha: 1.0).setFill()
            let path = UIBezierPath()
            path.move(to: CGPoint(x: x, y: 0))
            path.addLine(to: CGPoint(x: x + width, y: 0))
            path.addLine(to: CGPoint(x: x + width + size.height, y: size.height))
            path.addLine(to: CGPoint(x: x + size.height, y: size.height))
            path.close()
            path.fill()
            x += width
            index += 1
        }
    }

    private static func traces(_ cg: CGContext, size: CGSize) {
        UIColor(white: 0.55, alpha: 1.0).setFill()
        cg.fill(CGRect(origin: .zero, size: size))

        var generator = SeededRandom(seed: 97)
        UIColor(white: 1.0, alpha: 1.0).setStroke()
        for _ in 0..<26 {
            let path = UIBezierPath()
            var point = CGPoint(x: generator.next(in: 0...size.width),
                                y: generator.next(in: 0...size.height))
            path.move(to: point)
            // Traces only ever turn at right angles, which is what makes them read
            // as etched copper rather than as scribble.
            for step in 0..<4 {
                let run = generator.next(in: 14...44)
                point = step % 2 == 0
                    ? CGPoint(x: point.x + run, y: point.y)
                    : CGPoint(x: point.x, y: point.y + run)
                path.addLine(to: point)
            }
            path.lineWidth = 2
            path.stroke()
        }
        for _ in 0..<40 {
            UIColor(white: 1.0, alpha: 1.0).setFill()
            cg.fillEllipse(in: CGRect(x: generator.next(in: 0...size.width),
                                      y: generator.next(in: 0...size.height),
                                      width: 4, height: 4))
        }
    }

    private static func crust(_ cg: CGContext, size: CGSize) {
        UIColor(white: 0.34, alpha: 1.0).setFill()
        cg.fill(CGRect(origin: .zero, size: size))

        var generator = SeededRandom(seed: 131)
        for _ in 0..<16 {
            let path = UIBezierPath()
            var point = CGPoint(x: generator.next(in: -10...size.width),
                                y: generator.next(in: -10...size.height))
            path.move(to: point)
            for _ in 0..<5 {
                point = CGPoint(x: point.x + generator.next(in: -34...34),
                                y: point.y + generator.next(in: -34...34))
                path.addLine(to: point)
            }
            UIColor(white: generator.next(in: 0.85...1.0), alpha: 1.0).setStroke()
            path.lineWidth = generator.next(in: 2.0...5.0)
            path.lineJoinStyle = .round
            path.stroke()
        }
    }
}

/// A tiny deterministic generator, so a material looks the same every launch.
/// `SystemRandomNumberGenerator` would re-roll the grain on every cold start.
private struct SeededRandom {
    private var state: UInt64

    init(seed: UInt64) { state = seed &* 6364136223846793005 &+ 1442695040888963407 }

    mutating func next(in range: ClosedRange<CGFloat>) -> CGFloat {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        let unit = CGFloat((state >> 33) % 100_000) / 100_000.0
        return range.lowerBound + unit * (range.upperBound - range.lowerBound)
    }
}
