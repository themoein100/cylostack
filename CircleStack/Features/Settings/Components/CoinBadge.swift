//
//  CoinBadge.swift
//  CircleStack
//
//  Created by Moein on 27/07/2026.
//

import SwiftUI

struct CoinBadge: View {
    let coins: Int

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "circle.hexagongrid.fill")
                .font(.system(size: 13))
                .foregroundStyle(.yellow)
            Text(formatCoins(coins))
                .font(.system(.subheadline, design: .rounded).weight(.bold).monospacedDigit())
                .foregroundColor(.white)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(Color.yellow.opacity(0.14))
        .clipShape(Capsule())
        .overlay(Capsule().stroke(Color.yellow.opacity(0.3), lineWidth: 1))
    }
}
