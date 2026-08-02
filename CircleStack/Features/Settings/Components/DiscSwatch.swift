//
//  DiscSwatch.swift
//  CircleStack
//
//  Created by Moein on 28/07/2026.
//

import SwiftUI
import SpriteKit
import Combine

/// Draws the same 2.5D disc the scene draws, in UIKit.
///
/// Sharing one renderer is the point: a menu that previews a flat circle while the
/// game plays a textured cylinder is showing the player the wrong thing.
enum DiscRenderer {
    static func image(material: DiscMaterial, hue: CGFloat, width: CGFloat) -> UIImage {
        let p = GameConfig.perspectiveRatio
        let thickness = max(10.0, width * 0.16)
        let rx = width / 2.0
        let ry = rx * p
        let pad: CGFloat = 6.0

        let palette = NeonPalette.palette(index: 0, baseHue: hue, material: material)
        let size = CGSize(width: width + pad * 2, height: ry * 2 + thickness + pad * 2)
        let centre = CGPoint(x: size.width / 2, y: ry + pad)

        let format = UIGraphicsImageRendererFormat.default()
        format.opaque = false
        return UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            let cg = ctx.cgContext

            let sideRect = CGRect(x: centre.x - rx, y: centre.y - ry,
                                  width: rx * 2, height: ry * 2 + thickness)

            // Side wall: bottom cap plus the straight section between the two rims
            cg.saveGState()
            let wall = UIBezierPath(rect: CGRect(x: centre.x - rx, y: centre.y,
                                                 width: rx * 2, height: thickness))
            wall.append(UIBezierPath(ovalIn: CGRect(x: centre.x - rx, y: centre.y + thickness - ry,
                                                    width: rx * 2, height: ry * 2)))
            wall.addClip()
            MaterialTexture.sideImage(material.pattern).draw(in: sideRect)
            cg.setBlendMode(.multiply)
            UIColor(palette.side).setFill()
            cg.fill(sideRect)
            cg.restoreGState()

            // Top face
            cg.saveGState()
            let faceRect = CGRect(x: centre.x - rx, y: centre.y - ry, width: rx * 2, height: ry * 2)
            UIBezierPath(ovalIn: faceRect).addClip()
            MaterialTexture.faceImage(material.pattern).draw(in: faceRect)
            cg.setBlendMode(.multiply)
            UIColor(palette.top).setFill()
            cg.fill(faceRect)
            cg.restoreGState()

            // Rim, clean subtle outline
            let rim = UIBezierPath(ovalIn: faceRect)
            rim.lineWidth = 1.8
            UIColor(palette.glow).withAlphaComponent(0.65).setStroke()
            rim.stroke()
        }
    }
}

/// A single disc, sized to fit whatever space it is given.
struct DiscSwatch: View {
    let material: DiscMaterial
    var hue: CGFloat = 0.52

    var body: some View {
        GeometryReader { geo in
            let width = min(geo.size.width, geo.size.height * 1.7)
            Image(uiImage: DiscRenderer.image(material: material, hue: hue, width: width))
                .resizable()
                .scaledToFit()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// The play screen's hero disc: displays the selected material using the last played run color.
struct PreviewDisc: View {
    let material: DiscMaterial
    var hue: CGFloat = 0.52

    @State private var bob = false

    var body: some View {
        DiscSwatch(material: material, hue: hue)
            .offset(y: bob ? -6 : 6)
            .animation(.easeInOut(duration: 2.2).repeatForever(autoreverses: true), value: bob)
            .onAppear { bob = true }
    }
}

private extension UIColor {
    convenience init(_ color: SKColor) {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        color.getRed(&r, green: &g, blue: &b, alpha: &a)
        self.init(red: r, green: g, blue: b, alpha: a)
    }
}
