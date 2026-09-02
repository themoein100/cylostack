//
//  SpriteKitGameView.swift
//  CircleStack
//
//  Created by Moein on 27/07/2026.
//

import SwiftUI
import SpriteKit

/// SpriteKit does not reliably receive `UIPress` events when embedded in a Mac
/// Catalyst SwiftUI hierarchy. A first-responder key command bridges Space to the
/// same guarded input path used by taps.
private final class GameSKView: SKView {
    override var canBecomeFirstResponder: Bool { true }

    override var keyCommands: [UIKeyCommand]? {
        [UIKeyCommand(input: " ", modifierFlags: [], action: #selector(placeDisc))]
    }

    @objc private func placeDisc() {
        (scene as? GameScene)?.placeActiveDiscFromPrimaryInput()
    }
}

struct SpriteKitGameView: UIViewRepresentable {
    let scene: GameScene
    
    func makeUIView(context: Context) -> SKView {
        let view = GameSKView()
        view.ignoresSiblingOrder = true
        view.showsFPS = false
        view.showsNodeCount = false
        
        scene.scaleMode = .aspectFill
        view.presentScene(scene)
        // The view joins the responder chain after construction, so request focus on
        // the next run-loop turn. This is needed for hardware keyboards on Catalyst.
        Task { @MainActor in
            view.becomeFirstResponder()
        }
        return view
    }
    
    func updateUIView(_ uiView: SKView, context: Context) {}
}
