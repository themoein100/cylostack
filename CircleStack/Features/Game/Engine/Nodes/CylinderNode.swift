//
//  CylinderNode.swift
//  CircleStack
//
//  Created by Moein on 27/07/2026.
//

import SpriteKit
import UIKit

// -------------------------------------------------------------
// MARK: - CylinderNode (2.5D Disc Node Custom Drawing)
// -------------------------------------------------------------
class CylinderNode: SKNode {
    private(set) var width: CGFloat
    private(set) var palette: DiscPalette
    private let material: DiscMaterial

    /// Where the disc stands on the ground plane, independent of how high up the
    /// stack it is. The scene turns this into a node position.
    var ground: CGPoint = .zero

    private var sideNode: SKShapeNode?
    private var topNode: SKShapeNode?
    private var shadowNode: SKShapeNode?

    init(width: CGFloat, material: DiscMaterial, palette: DiscPalette) {
        self.width = width
        self.material = material
        self.palette = palette
        super.init()

        drawCylinder()
    }

    required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func updateWidth(_ newWidth: CGFloat) {
        self.width = newWidth
        drawCylinder()
    }

    private func drawCylinder() {
        // Clean old nodes
        sideNode?.removeFromParent()
        topNode?.removeFromParent()
        shadowNode?.removeFromParent()

        let p = GameConfig.perspectiveRatio
        let thickness = GameConfig.baseThickness
        let a = width / 2.0
        let b = a * p

        // 1. Draw Drop Shadow (rendered below cylinder)
        let shadowPath = CGMutablePath()
        shadowPath.addEllipse(in: CGRect(x: -a, y: -b, width: width, height: b * 2.0))
        let shadow = SKShapeNode(path: shadowPath)
        shadow.fillColor = SKColor.black.withAlphaComponent(0.28)
        shadow.strokeColor = .clear
        shadow.position = CGPoint(x: 0, y: -thickness - 6.0)
        shadow.zPosition = -1
        addChild(shadow)
        self.shadowNode = shadow

        // 2. Draw Side Body (darker shade extrusion with 3D gradient)
        let sidePath = CGMutablePath()
        sidePath.move(to: CGPoint(x: -a, y: 0))
        sidePath.addLine(to: CGPoint(x: -a, y: -thickness))

        // Bottom semi-ellipse
        let k: CGFloat = 0.5522 * 2.0
        sidePath.addCurve(to: CGPoint(x: a, y: -thickness),
                          control1: CGPoint(x: -a, y: -thickness - b * k),
                          control2: CGPoint(x: a, y: -thickness - b * k))

        sidePath.addLine(to: CGPoint(x: a, y: 0))

        // Top semi-ellipse (facing down)
        sidePath.addCurve(to: CGPoint(x: -a, y: 0),
                          control1: CGPoint(x: a, y: -b * k),
                          control2: CGPoint(x: -a, y: -b * k))
        sidePath.closeSubpath()

        let side = SKShapeNode(path: sidePath)
        // The texture is greyscale and `fillColor` multiplies it, so one cached sheet
        // per material serves every colour a run can roll.
        side.fillTexture = MaterialTexture.side(material.pattern)
        side.fillColor = palette.top
        side.strokeColor = .clear
        side.zPosition = 1
        addChild(side)
        self.sideNode = side

        // 3. Draw Top Surface Face with a neon rim. The rim is the only glow a disc
        //    carries: a soft bloom spread around the silhouette reads as a smudge at
        //    stack scale, where dozens of them overlap.
        let topPath = CGMutablePath()
        topPath.addEllipse(in: CGRect(x: -a, y: -b, width: width, height: b * 2.0))
        let top = SKShapeNode(path: topPath)
        top.fillTexture = MaterialTexture.face(material.pattern)
        top.fillColor = palette.top
        top.strokeColor = SKColor.white.blended(with: palette.glow, amount: 0.82)
        top.lineWidth = 2.2
        top.zPosition = 2
        addChild(top)
        self.topNode = top
    }
    

    /// Short squash-and-stretch on impact. Owns the node's scale outright so it
    /// can never fight another scale animation.
    func playLandingSquash() {
        removeAction(forKey: "squash")
        setScale(1.0)
        let squash = SKAction.scaleX(to: 1.06, y: 0.86, duration: 0.06)
        let recover = SKAction.scaleX(to: 0.98, y: 1.04, duration: 0.07)
        let settle = SKAction.scaleX(to: 1.0, y: 1.0, duration: 0.07)
        settle.timingMode = .easeOut
        run(.sequence([squash, recover, settle]), withKey: "squash")
    }

    /// Ring of light that blooms outward from the disc on every landing.
    /// `strength` runs 0...1 — a sliced landing gets a modest pulse, a perfect
    /// one gets a wide flare.
    func playLandingHalo(color: SKColor, strength: CGFloat, rings: Int = 1) {
        guard let top = topNode, let path = top.path else { return }
        let duration = 0.32 + 0.2 * strength

        // Fire `rings` ripple rings, each staggered by 0.09 s so they pulse outward
        for i in 0 ..< max(1, rings) {
            let delay = Double(i) * 0.09
            // Outer rings shrink in size slightly for a focused ripple look
            let scaleFactor: CGFloat = 1.4 + 0.75 * strength - CGFloat(i) * 0.08
            let lineW: CGFloat = max(1.2, (2.0 + 2.5 * strength) - CGFloat(i) * 0.6)
            let glowW: CGFloat = max(1.0, 3.0 * strength - CGFloat(i) * 0.5)

            let ring = SKShapeNode(path: path)
            ring.fillColor = .clear
            ring.strokeColor = color
            ring.lineWidth = lineW
            ring.glowWidth = glowW
            ring.blendMode = .add
            ring.zPosition = 5
            ring.alpha = 0
            addChild(ring)

            let appear = SKAction.fadeIn(withDuration: 0)
            let grow = SKAction.scale(to: scaleFactor, duration: duration)
            grow.timingMode = .easeOut
            let fade = SKAction.fadeOut(withDuration: duration)
            ring.run(.sequence([
                .wait(forDuration: delay),
                appear,
                .group([grow, fade]),
                .removeFromParent()
            ]))
        }

        // A perfect landing also flashes the face itself
        guard strength >= 1.0 else { return }
        let flash = SKShapeNode(path: path)
        flash.fillColor = color.withAlphaComponent(0.55)
        flash.strokeColor = .clear
        flash.blendMode = .add
        flash.zPosition = 4
        addChild(flash)
        flash.run(.sequence([.fadeOut(withDuration: 0.28), .removeFromParent()]))
    }

    /// White-hot rim right where the blade went through, gone in a quarter second.
    func flashCutEdge() {
        guard let top = topNode, let path = top.path else { return }
        let edge = SKShapeNode(path: path)
        edge.fillColor = .clear
        edge.strokeColor = .white
        edge.lineWidth = 3.5
        edge.glowWidth = 3.0
        edge.blendMode = .add
        edge.zPosition = 6
        addChild(edge)
        edge.run(.sequence([.fadeOut(withDuration: 0.24), .removeFromParent()]))
    }

    /// Turns the disc into a free-falling body for the game-over drop.
    func attachFallingBody(velocity: CGVector, spin: CGFloat) {
        let body = SKPhysicsBody(circleOfRadius: max(10.0, width * 0.4))
        body.affectedByGravity = true
        body.allowsRotation = true
        body.linearDamping = 0.0
        body.categoryBitMask = 0
        body.collisionBitMask = 0
        body.contactTestBitMask = 0
        body.velocity = velocity
        body.angularVelocity = spin
        physicsBody = body
    }
}
