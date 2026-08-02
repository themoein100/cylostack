//
//  OnboardingView.swift
//  CircleStack
//
//  Created by Moein on 28/07/2026.
//

import SwiftUI

/// Shown once, on the very first launch.
///
/// It asks one thing and takes no for an answer: the game is offline and nothing
/// here is required to play, so "Skip" is a first-class button rather than fine
/// print. Whatever is entered stays on the device.
struct OnboardingView: View {
    @ObservedObject var store: PlayerStore

    @State private var firstName = ""
    @State private var lastName = ""
    @State private var age = 0
    @State private var appeared = false

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(hex: "#0A0A14"), Color(hex: "#141428")],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer()

                VStack(spacing: 10) {
                    Text("CYLOSTACK")
                        .font(.system(size: 32, weight: .black, design: .rounded))
                        .foregroundColor(.white)
                        .tracking(2)

                    Text("Before you start")
                        .font(.system(.subheadline, design: .rounded))
                        .foregroundColor(.white.opacity(0.5))
                }

                PreviewDisc(material: DiscMaterial.all[1])
                    .frame(height: 130)
                    .padding(.vertical, 26)

                VStack(spacing: 12) {
                    HStack(spacing: 10) {
                        ProfileField(title: "First Name", placeholder: "First Name", text: $firstName)
                        ProfileField(title: "Last Name", placeholder: "Last Name", text: $lastName)
                    }
                    AgeField(age: $age)
                }
                .padding(.horizontal, 8)

                Text("Optional, kept on this device, and changeable any time in Profile.")
                    .font(.system(size: 11, design: .rounded))
                    .foregroundColor(.white.opacity(0.4))
                    .multilineTextAlignment(.center)
                    .padding(.top, 14)
                    .padding(.horizontal, 20)

                Spacer()

                VStack(spacing: 12) {
                    Button {
                        finish(saving: true)
                    } label: {
                        Text("START STACKING")
                            .font(.system(.headline, design: .rounded).weight(.bold))
                            .foregroundColor(.black)
                            .frame(maxWidth: .infinity)
                            .frame(height: 56)
                            .background(Color.cyan)
                            .cornerRadius(18)
                    }

                    Button {
                        finish(saving: false)
                    } label: {
                        Text("Skip")
                            .font(.system(.subheadline, design: .rounded).weight(.semibold))
                            .foregroundColor(.white.opacity(0.6))
                            .frame(maxWidth: .infinity)
                            .frame(height: 44)
                    }
                }
                .padding(.bottom, 20)
            }
            .padding(.horizontal, 28)
            .opacity(appeared ? 1 : 0)
            .offset(y: appeared ? 0 : 16)
        }
        .preferredColorScheme(.dark)
        .onAppear {
            withAnimation(.easeOut(duration: 0.45)) { appeared = true }
        }
    }

    private func finish(saving: Bool) {
        if saving {
            store.firstName = firstName.trimmingCharacters(in: .whitespacesAndNewlines)
            store.lastName = lastName.trimmingCharacters(in: .whitespacesAndNewlines)
            store.age = age
        }
        withAnimation(.easeInOut(duration: 0.35)) {
            store.hasOnboarded = true
        }
    }
}
