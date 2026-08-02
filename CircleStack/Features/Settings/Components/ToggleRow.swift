//
//  ToggleRow.swift
//  CircleStack
//
//  Created by Moein on 27/07/2026.
//

import SwiftUI

struct ToggleRow: View {
    var title: String
    var icon: String
    @Binding var isOn: Bool
    
    var body: some View {
        HStack {
            Image(systemName: icon)
                .foregroundColor(.white.opacity(0.7))
                .frame(width: 24)
            
            Text(title)
                .font(.system(.body, design: .rounded))
                .foregroundColor(.white)
            
            Spacer()
            
            Toggle("", isOn: $isOn)
                .labelsHidden()
                .toggleStyle(SwitchToggleStyle(tint: Color(hex: "#00E5FF")))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }
}
