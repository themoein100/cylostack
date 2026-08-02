//
//  SoundManager.swift
//  CircleStack
//
//  Created by Moein on 27/07/2026.
//

import AVFoundation
import UIKit

class SoundManager {
    static let shared = SoundManager()
    
    private var engine: AVAudioEngine?
    private var playerNodes: [AVAudioPlayerNode] = []
    private var activePlayerIndex = 0
    private let playerPoolSize = 6
    
    // Pre-synthesized buffers
    private var perfectBuffer: AVAudioPCMBuffer?
    private var goodBuffer: AVAudioPCMBuffer?
    private var badBuffer: AVAudioPCMBuffer?
    private var fallBuffer: AVAudioPCMBuffer?
    private var collapseBuffer: AVAudioPCMBuffer?
    
    // User Settings
    var isMuted: Bool {
        get { UserDefaults.standard.bool(forKey: "circle_stack_muted") }
        set { UserDefaults.standard.set(newValue, forKey: "circle_stack_muted") }
    }
    
    var isHapticsEnabled: Bool {
        get { !UserDefaults.standard.bool(forKey: "circle_stack_haptics_disabled") }
        set { UserDefaults.standard.set(!newValue, forKey: "circle_stack_haptics_disabled") }
    }
    
    private init() {
        configureAudioSession()
        setupAudioEngine()
        synthesizeBuffers()
        
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAppDidBecomeActive),
            name: UIApplication.didBecomeActiveNotification,
            object: nil
        )
    }
    
    @objc private func handleAppDidBecomeActive() {
        configureAudioSession()
    }
    
    func configureAudioSession() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.ambient, options: [.mixWithOthers])
            try session.setActive(true, options: [])
        } catch {
            Logger.shared.e("SoundManager", "Failed to configure ambient audio session: \(error.localizedDescription)")
        }
    }
    
    private func setupAudioEngine() {
        let engine = AVAudioEngine()
        self.engine = engine
        
        let format = AVAudioFormat(standardFormatWithSampleRate: 44100.0, channels: 1)!
        
        // Create a pool of player nodes so sounds can overlap
        for _ in 0..<playerPoolSize {
            let playerNode = AVAudioPlayerNode()
            engine.attach(playerNode)
            engine.connect(playerNode, to: engine.mainMixerNode, format: format)
            playerNodes.append(playerNode)
        }
        
        do {
            try engine.start()
        } catch {
            print("Failed to start audio engine: \(error)")
        }
    }
    
    // Synthesize procedural wave buffers
    private func synthesizeBuffers() {
        let sampleRate: Double = 44100.0
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        
        // 1. PERFECT Buffer (Arpeggiated beautiful major chord)
        perfectBuffer = makeBuffer(duration: 0.6, format: format) { time in
            // Play C5, E5, G5, C6 arpeggio/chime
            let C5 = 523.25
            let E5 = 659.25
            let G5 = 783.99
            let C6 = 1046.50
            
            var amplitude = 0.0
            let envelope = exp(-time * 5.0) // smooth exponential decay
            
            // Layer frequencies with phase offsets
            amplitude += sin(2.0 * .pi * C5 * time) * 0.25
            if time > 0.05 { amplitude += sin(2.0 * .pi * E5 * (time - 0.05)) * 0.25 }
            if time > 0.10 { amplitude += sin(2.0 * .pi * G5 * (time - 0.10)) * 0.25 }
            if time > 0.15 { amplitude += sin(2.0 * .pi * C6 * (time - 0.15)) * 0.25 }
            
            return Float(amplitude * envelope)
        }
        
        // 2. GOOD Buffer (Single high-pitch bubble pop)
        goodBuffer = makeBuffer(duration: 0.15, format: format) { time in
            let freq = 880.0 // A5
            let envelope = exp(-time * 25.0)
            return Float(sin(2.0 * .pi * freq * time) * 0.35 * envelope)
        }
        
        // 3. BAD Buffer (Dissonant double tone warning)
        badBuffer = makeBuffer(duration: 0.25, format: format) { time in
            let f1 = 220.0
            let f2 = 233.08 // Dissonant half-step
            let envelope = exp(-time * 8.0)
            return Float((sin(2.0 * .pi * f1 * time) + sin(2.0 * .pi * f2 * time)) * 0.2 * envelope)
        }
        
        // 4. FALL Buffer (Slide down frequency)
        fallBuffer = makeBuffer(duration: 0.5, format: format) { time in
            let startFreq = 600.0
            let endFreq = 150.0
            // Linear sweep frequency
            let freq = startFreq - (startFreq - endFreq) * (time / 0.5)
            let envelope = exp(-time * 3.0)
            return Float(sin(2.0 * .pi * freq * time) * 0.3 * envelope)
        }
        
        // 5. COLLAPSE Buffer (Low rumble / noise explosion)
        collapseBuffer = makeBuffer(duration: 0.8, format: format) { time in
            // Multi-frequency low-pass simulated rumble + white noise
            let envelope = exp(-time * 4.0)
            let freq1 = 60.0
            let freq2 = 45.0
            let noise = Double.random(in: -1.0...1.0) * 0.15
            let rumble = sin(2.0 * .pi * freq1 * time) * 0.4 + sin(2.0 * .pi * freq2 * time) * 0.4
            return Float((rumble + noise) * envelope)
        }
    }
    
    // Helper to generate custom buffer content
    private func makeBuffer(duration: Double, format: AVAudioFormat, generator: (Double) -> Float) -> AVAudioPCMBuffer? {
        let sampleRate = format.sampleRate
        let frameCount = AVAudioFrameCount(duration * sampleRate)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else { return nil }
        buffer.frameLength = frameCount
        
        guard let channelData = buffer.floatChannelData else { return nil }
        let data = channelData[0]
        
        for frame in 0..<Int(frameCount) {
            let time = Double(frame) / sampleRate
            data[frame] = generator(time)
        }
        
        return buffer
    }
    
    // Play buffer using player pool
    private func play(_ buffer: AVAudioPCMBuffer?) {
        guard let buffer = buffer, !isMuted else { return }
        
        // Select next player in pool to allow overlap
        let playerNode = playerNodes[activePlayerIndex]
        activePlayerIndex = (activePlayerIndex + 1) % playerPoolSize
        
        if playerNode.isPlaying {
            playerNode.stop()
        }
        
        playerNode.scheduleBuffer(buffer, at: nil, options: [], completionHandler: nil)
        playerNode.play()
    }
    
    // Public Trigger Interfaces
    func playPerfect() {
        Logger.shared.d("SoundManager", "Trigger perfect arpeggio chime")
        play(perfectBuffer)
        triggerHaptic(style: .heavy)
    }
    
    func playGood() {
        Logger.shared.d("SoundManager", "Trigger good bubble pop")
        play(goodBuffer)
        triggerHaptic(style: .medium)
    }
    
    func playBad() {
        Logger.shared.w("SoundManager", "Trigger bad dissonant warning")
        play(badBuffer)
        triggerHaptic(style: .light)
    }
    
    func playFall() {
        Logger.shared.i("SoundManager", "Trigger slide-down fall effect")
        play(fallBuffer)
        triggerHaptic(style: .soft)
    }
    
    func playCollapse() {
        Logger.shared.i("SoundManager", "Trigger low-frequency rumble collapse")
        play(collapseBuffer)
        // Double haptic impact
        triggerHaptic(style: .heavy)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            self.triggerHaptic(style: .heavy)
        }
    }
    
    private func triggerHaptic(style: UIImpactFeedbackGenerator.FeedbackStyle) {
        guard isHapticsEnabled else { return }
        let generator = UIImpactFeedbackGenerator(style: style)
        generator.prepare()
        generator.impactOccurred()
    }
}
