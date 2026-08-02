//
//  GameScene+Effects.swift
//  CircleStack
//
//  Created by Moein on 27/07/2026.
//

import SpriteKit
import UIKit

extension GameScene {
    func shakeCamera(intensity: CGFloat, duration: TimeInterval) {
        let steps = 6
        let step = duration / Double(steps) / 2.0
        var actions: [SKAction] = []
        for i in 0..<steps {
            let decay = 1.0 - CGFloat(i) / CGFloat(steps)
            let offset = SKAction.moveBy(x: CGFloat.random(in: -intensity...intensity) * decay,
                                         y: CGFloat.random(in: -intensity...intensity) * decay,
                                         duration: step)
            actions.append(offset)
            actions.append(offset.reversed())
        }
        cameraNode.run(.sequence(actions), withKey: "shake")
    }

    func spawnPerfectParticles(atLocal position: CGPoint, width: CGFloat, color: SKColor) {
        let worldPos = towerNode.convert(position, to: self)

        let emitterL = SKEmitterNode()
        emitterL.particleTexture = createParticleTexture()
        emitterL.particleColorSequence = nil
        emitterL.particleColor = color
        emitterL.particleColorBlendFactor = 1.0
        emitterL.particleBlendMode = .add
        emitterL.zPosition = 80_000.0

        emitterL.position = CGPoint(x: worldPos.x - width / 2, y: worldPos.y)
        emitterL.numParticlesToEmit = 15
        emitterL.particleBirthRate = 100
        emitterL.particleLifetime = 0.4
        emitterL.particleSpeed = 60
        emitterL.particleSpeedRange = 20
        emitterL.emissionAngle = .pi
        emitterL.emissionAngleRange = 0.5
        emitterL.xAcceleration = -100
        emitterL.particleScale = 0.15
        emitterL.particleScaleSpeed = -0.3

        let emitterR = emitterL.copy() as! SKEmitterNode
        emitterR.position = CGPoint(x: worldPos.x + width / 2, y: worldPos.y)
        emitterR.emissionAngle = 0.0
        emitterR.xAcceleration = 100

        addChild(emitterL)
        addChild(emitterR)

        let cleanup = SKAction.sequence([.wait(forDuration: 0.5), .removeFromParent()])
        emitterL.run(cleanup)
        emitterR.run(cleanup)
    }

    func createParticleTexture() -> SKTexture {
        let texSize = CGSize(width: 12, height: 12)
        let renderer = UIGraphicsImageRenderer(size: texSize)
        let image = renderer.image { ctx in
            let colorSpace = CGColorSpaceCreateDeviceRGB()
            let colors = [UIColor.white.cgColor, UIColor.white.withAlphaComponent(0.0).cgColor] as CFArray
            if let gradient = CGGradient(colorsSpace: colorSpace, colors: colors, locations: [0.0, 1.0]) {
                let center = CGPoint(x: texSize.width / 2, y: texSize.height / 2)
                ctx.cgContext.drawRadialGradient(gradient, startCenter: center, startRadius: 0,
                                                 endCenter: center, endRadius: texSize.width / 2, options: [])
            }
        }
        return SKTexture(image: image)
    }
}
