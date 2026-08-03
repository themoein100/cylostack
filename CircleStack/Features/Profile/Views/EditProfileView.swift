//
//  EditProfileView.swift
//  CircleStack
//
//  Created by Moein on 28/07/2026.
//

import SwiftUI

struct EditProfileView: View {
    @ObservedObject var store: PlayerStore
    @Environment(\.presentationMode) private var presentationMode

    @State private var firstName: String = ""
    @State private var lastName: String = ""
    @State private var email: String = ""
    @State private var age: Int = 0

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color(hex: "#0A0A14"), Color(hex: "#141428")],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            VStack(spacing: 0) {
                // Header Bar
                HStack {
                    Button(action: { presentationMode.wrappedValue.dismiss() }) {
                        Image(systemName: "xmark")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundColor(.white.opacity(0.7))
                            .padding(10)
                            .background(Color.white.opacity(0.08))
                            .clipShape(Circle())
                    }

                    Spacer()

                    Text("Edit Profile")
                        .font(.system(size: 20, weight: .bold, design: .rounded))
                        .foregroundColor(.white)

                    Spacer()

                    Button(action: saveChanges) {
                        Text("Save")
                            .font(.system(size: 15, weight: .bold, design: .rounded))
                            .foregroundColor(.black)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                            .background(Color.cyan)
                            .cornerRadius(14)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 20)
                .padding(.bottom, 16)

                ScrollView(showsIndicators: false) {
                    VStack(spacing: 20) {
                        // Title header
                        VStack(spacing: 6) {
                            Image(systemName: "person.crop.circle.badge.checkmark")
                                .font(.system(size: 52))
                                .foregroundColor(.cyan)
                                .padding(.bottom, 4)

                            Text("Personal Details")
                                .font(.system(size: 22, weight: .heavy, design: .rounded))
                                .foregroundColor(.white)

                            Text("Update your name and information saved on this device.")
                                .font(.system(size: 12, design: .rounded))
                                .foregroundColor(.white.opacity(0.5))
                                .multilineTextAlignment(.center)
                                .padding(.horizontal, 20)
                        }
                        .padding(.vertical, 10)

                        // Input fields card
                        VStack(spacing: 16) {
                            if GameCenterManager.shared.isAuthenticated {
                                Button(action: {
                                    GameCenterManager.shared.syncProfileFromGameCenter()
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                                        firstName = store.firstName
                                        lastName = store.lastName
                                    }
                                }) {
                                    HStack(spacing: 8) {
                                        Image(systemName: "person.crop.circle.badge.plus")
                                            .font(.system(size: 14, weight: .bold))
                                        Text("Import from Game Center")
                                            .font(.system(size: 13, weight: .bold, design: .rounded))
                                    }
                                    .foregroundColor(.cyan)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 10)
                                    .background(Color.cyan.opacity(0.12))
                                    .cornerRadius(12)
                                }
                            }

                            ProfileField(title: "First Name", placeholder: "First Name", text: $firstName)
                            ProfileField(title: "Last Name", placeholder: "Last Name", text: $lastName)
                            ProfileField(title: "Email", placeholder: "Optional Email", text: $email, keyboard: .emailAddress, autocapitalize: false)
                            AgeField(age: $age)
                        }
                        .padding(20)
                        .background(Color.white.opacity(0.05))
                        .cornerRadius(20)
                        .overlay(
                            RoundedRectangle(cornerRadius: 20)
                                .stroke(Color.white.opacity(0.1), lineWidth: 1)
                        )

                        Spacer(minLength: 40)
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 10)
                }
            }
        }
        .preferredColorScheme(.dark)
        .onAppear {
            firstName = store.firstName
            lastName = store.lastName
            email = store.email
            age = store.age
        }
    }

    private func saveChanges() {
        store.firstName = firstName.trimmingCharacters(in: .whitespacesAndNewlines)
        store.lastName = lastName.trimmingCharacters(in: .whitespacesAndNewlines)
        store.email = email.trimmingCharacters(in: .whitespacesAndNewlines)
        store.age = age
        presentationMode.wrappedValue.dismiss()
    }
}
