//
//  SplashView.swift
//  CircleStack
//
//  Created by Moein on 27/07/2026.
//

import SwiftUI

struct SplashView: View {
    @Binding var isFinished: Bool
    
    @State private var isAnimating = false
    @State private var rotation = 0.0
    @State private var opacity = 0.0
    @State private var hasTriggeredAd = false
    
    var body: some View {
        ZStack {
            // Ultra-dark background
            Color(hex: "#05050A")
                .edgesIgnoringSafeArea(.all)
            
            VStack(spacing: 36) {
                Spacer()
                
                // Pulsing, Glowing, Spinning 2.5D disc
                ZStack {
                    // Shadow below disc
                    Ellipse()
                        .fill(Color.black.opacity(0.5))
                        .frame(width: 130, height: 35)
                        .blur(radius: 5)
                        .offset(y: 42)
                    
                    // The same disc the game draws, so the splash is not advertising
                    // a shape the player never sees
                    DiscSwatch(material: DiscMaterial.all[1], hue: 0.52)
                        .frame(width: 150, height: 96)
                        .scaleEffect(isAnimating ? 1.05 : 0.92)
                    .shadow(color: Color(hex: "#00E5FF").opacity(0.35), radius: 25, x: 0, y: 8)
                }
                
                Spacer()
                
                // Logo & text fading in
                VStack(spacing: 12) {
                    Text("CYLOSTACK")
                        .font(.system(size: 32, weight: .black, design: .rounded))
                        .foregroundColor(.white)
                        .tracking(3)
                        
                    Text("APPLE DESIGN EXPERIMENT")
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .foregroundColor(Color(hex: "#00E5FF").opacity(0.8))
                        .tracking(2)
                }
                .opacity(opacity)
                .offset(y: isAnimating ? 0 : 15)
                
                Spacer()
            }
        }
        .onAppear {
            guard !hasTriggeredAd else { return }
            hasTriggeredAd = true

            // Rotation animation (slow)
            withAnimation(.linear(duration: 8.0).repeatForever(autoreverses: false)) {
                rotation = 360.0
            }
            
            // Pulse & slide up animation
            withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) {
                isAnimating = true
            }
            
            // Fade in logo
            withAnimation(.easeOut(duration: 0.8).delay(0.2)) {
                opacity = 1.0
            }
            
            // Fetch remote config in background, handle GDPR, then launch app!
            RemoteConfigManager.shared.fetchRemoteConfig()
            
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                AdMobManager.shared.requestGDPRConsentIfNeeded {
                    if RemoteConfigManager.shared.areAdsEnabled && RemoteConfigManager.shared.isAppOpenAdEnabled {
                        AdMobManager.shared.waitForAppOpenAdOrTimeout(maxWaitDuration: 4.0) { hasAd in
                            if hasAd {
                                AdMobManager.shared.showAppOpenAd {
                                    withAnimation(.easeOut(duration: 0.5)) {
                                        isFinished = false
                                    }
                                }
                            } else {
                                withAnimation(.easeOut(duration: 0.5)) {
                                    isFinished = false
                                }
                            }
                        }
                    } else {
                        withAnimation(.easeOut(duration: 0.5)) {
                            isFinished = false
                        }
                    }
                }
            }
        }
    }
}
