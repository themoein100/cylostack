//
//  ScoreTile.swift
//  CircleStack
//
//  Created by Moein on 27/07/2026.
//

import SwiftUI

struct ScoreTile: View {
    var title: String
    var value: String
    var color: Color
    
    var body: some View {
        VStack(spacing: 8) {
            Text(title)
                .font(.system(.caption, design: .rounded))
                .foregroundColor(.white.opacity(0.5))
            
            Text(value)
                .font(.system(.title2, design: .rounded))
                .fontWeight(.bold)
                .foregroundColor(color)
        }
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity)
        .background(Color.white.opacity(0.06))
        .cornerRadius(16)
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(Color.white.opacity(0.12), lineWidth: 1)
        )
    }
}
