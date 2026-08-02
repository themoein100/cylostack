//
//  TabBarButton.swift
//  CircleStack
//
//  Created by Moein on 27/07/2026.
//

import SwiftUI

struct TabBarButton: View {
    var icon: String
    var title: String
    var isSelected: Bool
    var action: () -> Void
    
    var body: some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: icon)
                    .font(.system(size: 18, weight: isSelected ? .bold : .medium))
                    .foregroundColor(isSelected ? .cyan : .white.opacity(0.5))
                
                Text(title)
                    .font(.system(size: 10, weight: isSelected ? .bold : .semibold, design: .rounded))
                    .foregroundColor(isSelected ? .white : .white.opacity(0.45))
            }
            .frame(maxWidth: .infinity)
            .frame(height: 48)
            .background(
                ZStack {
                    if isSelected {
                        Capsule()
                            .fill(Color.cyan.opacity(0.18))
                        Capsule()
                            .stroke(Color.cyan.opacity(0.35), lineWidth: 1)
                    }
                }
            )
        }
        .buttonStyle(.plain)
    }
}
