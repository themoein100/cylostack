//
//  GameSceneDelegate.swift
//  CircleStack
//
//  Created by Moein on 27/07/2026.
//

import Foundation

protocol GameSceneDelegate: AnyObject {
    func gameDidUpdateScore(score: Int, combo: Int)
    func gameDidPerfectHit(combo: Int)
    func gameDidGameOver(finalScore: Int)
}
