//
//  ProfileField.swift
//  CircleStack
//
//  Created by Moein on 27/07/2026.
//

import SwiftUI

struct ProfileField: View {
    let title: String
    let placeholder: String
    @Binding var text: String
    var keyboard: UIKeyboardType = .default
    var autocapitalize: Bool = true

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .foregroundColor(.white.opacity(0.4))
                .frame(maxWidth: .infinity, alignment: .leading)

            TextField(placeholder, text: $text)
                .font(.system(.body, design: .rounded))
                .foregroundColor(.white)
                .keyboardType(keyboard)
                .textInputAutocapitalization(autocapitalize ? .words : .never)
                .autocorrectionDisabled(!autocapitalize)
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .background(Color.white.opacity(0.05))
                .cornerRadius(12)
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color.white.opacity(0.08), lineWidth: 1)
                )
        }
    }
}

struct AgeField: View {
    @Binding var age: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("AGE")
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .foregroundColor(.white.opacity(0.4))
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack {
                Text(age > 0 ? "\(age)" : "Not set")
                    .font(.system(.body, design: .rounded))
                    .foregroundColor(age > 0 ? .white : .white.opacity(0.35))
                Spacer()
                Stepper("", value: $age, in: 0...120)
                    .labelsHidden()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Color.white.opacity(0.05))
            .cornerRadius(12)
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Color.white.opacity(0.08), lineWidth: 1)
            )
        }
    }
}
