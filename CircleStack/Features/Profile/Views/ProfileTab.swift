//
//  ProfileTab.swift
//  CircleStack
//
//  Created by Moein on 27/07/2026.
//

import SwiftUI
import PhotosUI

struct ProfileTab: View {
    @ObservedObject var store: PlayerStore

    @State private var photoSource: PhotoSource?
    @State private var showPhotoSourceDialog = false
    @State private var showEditProfileSheet = false

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 26) {
                avatar
                profileCard
                careerStatsCard
                coinsCard
                LeaderboardCardView()
                Color.clear.frame(height: 90) // clears the floating tab bar
            }
            .padding(.horizontal, 24)
            .padding(.top, 24)
        }
        .applyScrollBounceBehavior()
        .confirmationDialog("Profile photo", isPresented: $showPhotoSourceDialog) {
            Button("Choose from Library") { photoSource = .library }
            if UIImagePickerController.isSourceTypeAvailable(.camera) {
                Button("Take Photo") { photoSource = .camera }
            }
            if store.avatarData != nil {
                Button("Remove Photo", role: .destructive) { store.avatarData = nil }
            }
            Button("Cancel", role: .cancel) {}
        }
        .sheet(item: $photoSource) { source in
            Group {
                switch source {
                case .library:
                    PhotoLibraryPicker(onPick: store.setAvatar)
                case .camera:
                    SystemImagePicker(sourceType: .camera, onCapture: store.setAvatar)
                }
            }
            .ignoresSafeArea()
        }
        .sheet(isPresented: $showEditProfileSheet) {
            EditProfileView(store: store)
        }
    }

    enum PhotoSource: Int, Identifiable {
        case library, camera
        var id: Int { rawValue }
    }

    // MARK: - Avatar

    private var avatar: some View {
        VStack(spacing: 14) {
            Button {
                showPhotoSourceDialog = true
            } label: {
                ZStack {
                    Circle()
                        .fill(Color.white.opacity(0.07))
                        .frame(width: 116, height: 116)

                    if let image = store.avatarImage {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFill()
                            .frame(width: 116, height: 116)
                            .clipShape(Circle())
                    } else {
                        Image(systemName: "person.fill")
                            .font(.system(size: 44))
                            .foregroundColor(.white.opacity(0.35))
                    }

                    Circle()
                        .stroke(Color.white.opacity(0.18), lineWidth: 1)
                        .frame(width: 116, height: 116)

                    // Affordance in the corner, so it reads as tappable
                    Image(systemName: "camera.fill")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(.black)
                        .frame(width: 32, height: 32)
                        .background(Color.cyan)
                        .clipShape(Circle())
                        .offset(x: 42, y: 42)
                }
            }
            .buttonStyle(.plain)

            Text(store.displayName.isEmpty ? "Player" : store.displayName)
                .font(.system(size: 24, weight: .black, design: .rounded))
                .foregroundColor(.white)
        }
    }

    // MARK: - Profile Details Card & Edit Button

    private var profileCard: some View {
        VStack(spacing: 16) {
            HStack {
                Text("PERSONAL PROFILE")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundColor(.white.opacity(0.4))

                Spacer()

                Button(action: { showEditProfileSheet = true }) {
                    HStack(spacing: 6) {
                        Image(systemName: "square.and.pencil")
                            .font(.system(size: 13, weight: .bold))
                        Text(hasProfileDetails ? "Edit Profile" : "Set Up Profile")
                            .font(.system(size: 13, weight: .bold, design: .rounded))
                    }
                    .foregroundColor(.cyan)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .background(Color.cyan.opacity(0.15))
                    .cornerRadius(12)
                }
            }

            VStack(spacing: 12) {
                profileRow(icon: "person.fill", title: "Full Name", value: store.displayName.isEmpty ? "Not specified" : store.displayName)
                Divider().background(Color.white.opacity(0.08))
                profileRow(icon: "envelope.fill", title: "Email", value: store.email.isEmpty ? "Not specified" : store.email)
                Divider().background(Color.white.opacity(0.08))
                profileRow(icon: "calendar", title: "Age", value: store.age > 0 ? "\(store.age) years old" : "Not specified")
            }
            .padding(16)
            .background(Color.white.opacity(0.04))
            .cornerRadius(16)

            Text("All of this stays on your device. The game is offline — there is no account and nothing to sign in to.")
                .font(.system(size: 11, design: .rounded))
                .foregroundColor(.white.opacity(0.4))
                .multilineTextAlignment(.center)
                .padding(.top, 2)
        }
    }

    private var hasProfileDetails: Bool {
        !store.firstName.isEmpty || !store.lastName.isEmpty || !store.displayName.isEmpty
    }

    private func profileRow(icon: String, title: String, value: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 14))
                .foregroundColor(.cyan.opacity(0.8))
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundColor(.white.opacity(0.4))
                Text(value)
                    .font(.system(size: 14, weight: .medium, design: .rounded))
                    .foregroundColor(.white)
            }
            Spacer()
        }
    }

    // MARK: - Career Stats & Cumulative Scores

    private var careerStatsCard: some View {
        VStack(spacing: 16) {
            careerHeader
            masterPointsBox
            careerGrid
        }
        .padding(18)
        .background(Color.white.opacity(0.05))
        .cornerRadius(20)
        .overlay(
            RoundedRectangle(cornerRadius: 20)
                .stroke(Color.white.opacity(0.09), lineWidth: 1)
        )
    }

    private var careerHeader: some View {
        HStack {
            HStack(spacing: 8) {
                Image(systemName: "chart.bar.fill")
                    .foregroundColor(.cyan)
                    .font(.system(size: 15, weight: .semibold))
                Text("CAREER PERFORMANCE")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundColor(.white.opacity(0.4))
                    .tracking(1.2)
            }
            Spacer()
        }
    }

    private var masterPointsBox: some View {
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "sparkles")
                    .foregroundColor(.yellow)
                    .font(.system(size: 14))
                Text("TOTAL MASTER POINTS")
                    .font(.system(size: 11, weight: .heavy, design: .rounded))
                    .foregroundColor(.yellow)
            }

            Text("\(store.totalWeightedScore)")
                .font(.system(size: 36, weight: .black, design: .rounded).monospacedDigit())
                .foregroundColor(.white)

            Text("Your best at every setting, each weighted by how hard it plays — the tough modes count for far more")
                .font(.system(size: 10, design: .rounded))
                .foregroundColor(.white.opacity(0.5))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 10)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
        .padding(.horizontal, 12)
        .background(
            LinearGradient(
                colors: [Color.cyan.opacity(0.18), Color.blue.opacity(0.12)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
        .cornerRadius(16)
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(Color.cyan.opacity(0.3), lineWidth: 1)
        )
    }

    private var careerGrid: some View {
        HStack(spacing: 12) {
            statTile(title: "Level Sum", value: "\(store.totalRawScore)", icon: "circle.grid.cross.fill", color: .purple)
            statTile(title: "Single Best", value: "\(store.overallBest)", icon: "crown.fill", color: .yellow)
            statTile(title: "Games Played", value: "\(store.totalGames)", icon: "gamecontroller.fill", color: .green)
        }
    }

    private func statTile(title: String, value: String, icon: String, color: Color) -> some View {
        VStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 14))
                .foregroundColor(color)
            Text(value)
                .font(.system(size: 16, weight: .bold, design: .rounded).monospacedDigit())
                .foregroundColor(.white)
            Text(title)
                .font(.system(size: 9, weight: .bold, design: .rounded))
                .foregroundColor(.white.opacity(0.45))
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background(Color.white.opacity(0.04))
        .cornerRadius(12)
    }

    // MARK: - Coins

    private var coinsCard: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("Coins")
                    .font(.system(.subheadline, design: .rounded).weight(.bold))
                    .foregroundColor(.white)
                Text("One per record, five more every tenth")
                    .font(.system(size: 11, design: .rounded))
                    .foregroundColor(.white.opacity(0.45))
            }
            Spacer()
            CoinBadge(coins: store.coins)
        }
        .padding(18)
        .background(Color.white.opacity(0.05))
        .cornerRadius(18)
        .overlay(
            RoundedRectangle(cornerRadius: 18)
                .stroke(Color.white.opacity(0.09), lineWidth: 1)
        )
    }

}


