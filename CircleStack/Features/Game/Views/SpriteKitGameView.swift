//
//  SpriteKitGameView.swift
//  CircleStack
//
//  Created by Moein on 27/07/2026.
//

import SwiftUI
import SpriteKit

struct SpriteKitGameView: UIViewRepresentable {
    let scene: GameScene
    
    func makeUIView(context: Context) -> SKView {
        let view = SKView()
        view.ignoresSiblingOrder = true
        view.showsFPS = false
        view.showsNodeCount = false
        
        scene.scaleMode = .aspectFill
        view.presentScene(scene)
        return view
    }
    
    func updateUIView(_ uiView: SKView, context: Context) {}
}
